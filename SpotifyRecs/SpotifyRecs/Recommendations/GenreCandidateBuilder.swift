//
//  GenreCandidateBuilder.swift
//  SpotifyRecs
//
//  Pure step that turns fetched Last.fm data into genre track candidates with feature vectors.
//

import Foundation

struct GenreCandidate: Hashable {
    let title: String
    let artist: String
    var features: FeatureVector
    var baseReason: String

    var key: String { MatchKey.track(title: title, artist: artist) }
}

struct GenreCandidateBuilder {
    let genreTag: String
    let genreName: String
    let context: TasteContext
    var analyzer = TasteAnalyzer()
    /// Artists below this genre strength are treated as outside the genre.
    var minimumGenreStrength = 0.2
    var maxTagFeatures = 8

    /// - Parameters:
    ///   - artistTags: Last.fm tags keyed by `MatchKey.artist(name)`.
    ///   - artistTopTracks: Last.fm top tracks keyed by `MatchKey.artist(name)`.
    ///   - excludedTrackKeys: Tracks already shown for this genre or otherwise blocked.
    func build(
        tagTopTracks: [LastFMTrack],
        tagTopArtists: [LastFMRankedArtist],
        artistTags: [String: [LastFMTag]],
        artistTopTracks: [String: [LastFMTrack]],
        excludedTrackKeys: Set<String>
    ) -> [GenreCandidate] {
        let genreArtistRank = Dictionary(
            tagTopArtists.map { (MatchKey.artist($0.name), $0.rankWeight) }, uniquingKeysWith: max
        )
        let chartedArtists = Set(tagTopTracks.map { MatchKey.artist($0.artist) })
        let maxSeedWeight = context.profile.seedArtists.first?.weight ?? 1
        let seedWeightByKey = Dictionary(
            context.profile.seedArtists.map { ($0.key, $0.weight / maxSeedWeight) }, uniquingKeysWith: max
        )
        let seedTracksByKey = Dictionary(context.profile.seedTracks.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        func genreStrength(_ artistKey: String) -> Double {
            let tagged = (artistTags[artistKey] ?? [])
                .filter { Self.sameTag($0.name, genreTag) }
                .map(\.weight).max() ?? 0
            let charted = genreArtistRank[artistKey] != nil || chartedArtists.contains(artistKey) ? 0.5 : 0
            return max(tagged, charted)
        }

        var tracks: [String: Accumulator] = [:]
        func add(_ track: LastFMTrack, update: (inout Accumulator) -> Void) {
            var acc = tracks[track.key] ?? Accumulator(title: track.name, artist: track.artist)
            update(&acc)
            tracks[track.key] = acc
        }

        // Source 1: the genre's chart.
        for track in tagTopTracks {
            add(track) { $0.genreRank = max($0.genreRank, track.match) }
        }
        // Source 2: top songs of genre artists close to the user's taste.
        for (artistKey, artistTracks) in artistTopTracks {
            let artistRank = genreArtistRank[artistKey] ?? 0.3
            for track in artistTracks {
                add(track) { $0.genreRank = max($0.genreRank, artistRank * track.match * 0.5) }
            }
        }
        // Source 3: songs similar to the user's top tracks — only those inside the genre.
        let maxSeedTrackWeight = context.profile.seedTracks.first?.weight ?? 1
        for (seedKey, similars) in context.similarTracks {
            guard let seed = seedTracksByKey[seedKey] else { continue }
            for track in similars where genreStrength(MatchKey.artist(track.artist)) >= minimumGenreStrength {
                let contribution = seed.weight / maxSeedTrackWeight * track.match
                add(track) { acc in
                    acc.trackSimilarity += contribution
                    if contribution > (acc.bestSeed?.1 ?? 0) { acc.bestSeed = (seed, contribution) }
                }
            }
        }

        var candidates: [GenreCandidate] = []
        var rawAffinity: [Double] = []
        for (key, acc) in tracks {
            guard !context.profile.knownTrackKeys.contains(key), !excludedTrackKeys.contains(key) else { continue }
            let artistKey = MatchKey.artist(acc.artist)
            let strength = genreStrength(artistKey)
            guard strength >= minimumGenreStrength || acc.genreRank > 0 else { continue }

            let isKnown = context.profile.knownArtistKeys.contains(artistKey)
            let similarity = context.artistSimilarity[artistKey]
            let tags = artistTags[artistKey] ?? []

            var features: FeatureVector = [
                Feature.bias: 1,
                Feature.artistSimilarity: max(similarity?.score ?? 0, isKnown ? (seedWeightByKey[artistKey] ?? 0.3) : 0),
                Feature.genreStrength: strength,
                Feature.genreRank: acc.genreRank,
                Feature.trackSimilarity: acc.trackSimilarity,
                Feature.knownArtist: isKnown ? 1 : 0,
            ]
            for tag in tags.filter({ !Self.sameTag($0.name, genreTag) && !TasteAnalyzer.ignoredTags.contains($0.name) })
                .prefix(maxTagFeatures) {
                features[Feature.tag(tag.name)] = tag.weight
            }

            rawAffinity.append(analyzer.tagAffinity(user: context.userTags, candidate: tags).score)
            candidates.append(GenreCandidate(
                title: acc.title,
                artist: acc.artist,
                features: features,
                baseReason: reason(acc: acc, similarity: similarity, isKnown: isKnown)
            ))
        }

        // Rescale relative signals so the strongest candidate is 1.0.
        let maxAffinity = rawAffinity.max() ?? 0
        let maxTrackSimilarity = candidates.map { $0.features[Feature.trackSimilarity] ?? 0 }.max() ?? 0
        for index in candidates.indices {
            candidates[index].features[Feature.tagAffinity] = maxAffinity > 0 ? rawAffinity[index] / maxAffinity : 0
            if maxTrackSimilarity > 0 {
                candidates[index].features[Feature.trackSimilarity, default: 0] /= maxTrackSimilarity
            }
        }
        return candidates.sorted { $0.key < $1.key }  // deterministic order
    }

    private struct Accumulator {
        var title: String
        var artist: String
        var genreRank = 0.0
        var trackSimilarity = 0.0
        var bestSeed: (WeightedTrack, Double)?
    }

    private func reason(acc: Accumulator, similarity: ArtistSimilarity?, isKnown: Bool) -> String {
        if let seed = acc.bestSeed?.0 {
            return "Similar to “\(seed.title)” by \(seed.artist)"
        }
        if isKnown {
            return "A \(genreName) side of an artist you know"
        }
        if let similarity, similarity.score >= 0.2, let first = similarity.becauseOf.first {
            return "Fans of \(first) like this artist"
        }
        if acc.genreRank >= 0.6 {
            return "One of the top \(genreName) songs on Last.fm"
        }
        return "Popular in \(genreName)"
    }

    /// "j-rock" == "jrock" == "j rock"
    static func sameTag(_ lhs: String, _ rhs: String) -> Bool {
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        return squash(lhs) == squash(rhs)
    }
}
