//
//  TasteAnalyzer.swift
//  SpotifyRecs
//
//  Pure functions that turn Spotify listening history and Last.fm data into taste signals.
//

import Foundation

struct TasteAnalyzer {
    /// How much each Spotify time range counts toward a seed's weight.
    var rangeWeights: [SpotifyTimeRange: Double] = [.shortTerm: 1.0, .mediumTerm: 0.8, .longTerm: 0.5]

    // MARK: Profile from Spotify

    func buildProfile(
        topArtists: [SpotifyTimeRange: [SpotifyArtist]],
        topTracks: [SpotifyTimeRange: [SpotifyTrack]],
        recentlyPlayed: [SpotifyTrack],
        savedTracks: [SpotifyTrack]
    ) -> ListeningProfile {
        var artistWeights: [String: (name: String, weight: Double, genres: Set<String>)] = [:]
        for (range, artists) in topArtists {
            let rangeWeight = rangeWeights[range] ?? 0.5
            for (rank, artist) in artists.enumerated() {
                let key = MatchKey.artist(artist.name)
                var entry = artistWeights[key] ?? (artist.name, 0, [])
                entry.weight += rangeWeight * rankDecay(rank, of: artists.count)
                entry.genres.formUnion(artist.genres ?? [])
                artistWeights[key] = entry
            }
        }

        var trackWeights: [String: (title: String, artist: String, weight: Double)] = [:]
        func addTrack(_ track: SpotifyTrack, weight: Double) {
            let key = MatchKey.track(title: track.name, artist: track.primaryArtist)
            var entry = trackWeights[key] ?? (track.name, track.primaryArtist, 0)
            entry.weight += weight
            trackWeights[key] = entry
        }
        for (range, tracks) in topTracks {
            let rangeWeight = rangeWeights[range] ?? 0.5
            for (rank, track) in tracks.enumerated() {
                addTrack(track, weight: rangeWeight * rankDecay(rank, of: tracks.count))
            }
        }
        // Repeated recent plays are a strong "right now" signal.
        for track in recentlyPlayed { addTrack(track, weight: 0.15) }

        // Artists that show up a lot in top tracks but not top artists still count as seeds.
        for entry in trackWeights.values {
            let key = MatchKey.artist(entry.artist)
            var artist = artistWeights[key] ?? (entry.artist, 0, [])
            artist.weight += entry.weight * 0.25
            artistWeights[key] = artist
        }

        let allTracks = topTracks.values.flatMap { $0 } + recentlyPlayed + savedTracks
        let knownArtists = Set(artistWeights.keys)
            .union(savedTracks.flatMap(\.artists).map { MatchKey.artist($0.name) })

        return ListeningProfile(
            seedArtists: artistWeights.values
                .map { WeightedArtist(name: $0.name, weight: $0.weight, genres: $0.genres.sorted()) }
                .sorted { $0.weight > $1.weight },
            seedTracks: trackWeights.values
                .map { WeightedTrack(title: $0.title, artist: $0.artist, weight: $0.weight) }
                .sorted { $0.weight > $1.weight },
            knownArtistKeys: knownArtists,
            knownTrackKeys: Set(allTracks.map { MatchKey.track(title: $0.name, artist: $0.primaryArtist) }),
            knownSpotifyTrackIDs: Set(allTracks.map(\.id))
        )
    }

    /// 1.0 for rank 0, sliding linearly to 0.3 for the last item.
    private func rankDecay(_ rank: Int, of count: Int) -> Double {
        guard count > 1 else { return 1 }
        return 1 - 0.7 * Double(rank) / Double(count - 1)
    }

    // MARK: Collaborative artist similarity (Last.fm)

    /// How strongly the user's seed artists point at each other artist, normalized so the best is 1.0.
    /// Known artists are included; callers decide how to treat them.
    /// - Parameter similar: Last.fm similar artists keyed by seed artist name.
    func artistSimilarity(similar: [String: [LastFMSimilarArtist]], profile: ListeningProfile) -> [String: ArtistSimilarity] {
        let seedWeights = Dictionary(profile.seedArtists.map { ($0.name, $0.weight) }, uniquingKeysWith: max)
        var scores: [String: (score: Double, sources: [(String, Double)])] = [:]

        for (seed, candidates) in similar {
            let seedWeight = seedWeights[seed] ?? 0
            for candidate in candidates {
                let key = MatchKey.artist(candidate.name)
                let contribution = seedWeight * candidate.match
                var entry = scores[key] ?? (0, [])
                entry.score += contribution
                entry.sources.append((seed, contribution))
                scores[key] = entry
            }
        }

        // Being recommended by several different seeds is a strong signal — reward breadth.
        let boosted = scores.mapValues { entry in
            (entry, entry.score * (1 + 0.15 * Double(entry.sources.count - 1)))
        }
        let maxScore = boosted.values.map(\.1).max() ?? 1
        return boosted.mapValues { entry, score in
            ArtistSimilarity(
                score: maxScore > 0 ? score / maxScore : 0,
                becauseOf: entry.sources.sorted { $0.1 > $1.1 }.map(\.0)
            )
        }
    }

    // MARK: Metadata / tag affinity

    /// Builds a weighted tag vector for the user from seed artists' Last.fm tags and Spotify genres.
    func userTagProfile(seedTags: [String: [LastFMTag]], profile: ListeningProfile) -> [String: Double] {
        var vector: [String: Double] = [:]
        for artist in profile.seedArtists {
            for tag in seedTags[artist.name] ?? [] where !Self.ignoredTags.contains(tag.name) {
                vector[tag.name, default: 0] += artist.weight * tag.weight
            }
            for genre in artist.genres {
                vector[genre.lowercased(), default: 0] += artist.weight * 0.5
            }
        }
        return vector
    }

    /// Cosine similarity between the user's tag vector and a candidate's tags.
    func tagAffinity(user: [String: Double], candidate: [LastFMTag]) -> (score: Double, shared: [String]) {
        let candidateVector = Dictionary(
            candidate.filter { !Self.ignoredTags.contains($0.name) }.map { ($0.name, $0.weight) },
            uniquingKeysWith: max
        )
        guard !user.isEmpty, !candidateVector.isEmpty else { return (0, []) }

        var dot = 0.0
        var shared: [(String, Double)] = []
        for (tag, weight) in candidateVector {
            if let userWeight = user[tag] {
                dot += weight * userWeight
                shared.append((tag, weight * userWeight))
            }
        }
        let userNorm = sqrt(user.values.reduce(0) { $0 + $1 * $1 })
        let candidateNorm = sqrt(candidateVector.values.reduce(0) { $0 + $1 * $1 })
        let score = dot / (userNorm * candidateNorm)
        return (min(max(score, 0), 1), shared.sorted { $0.1 > $1.1 }.map(\.0))
    }

    /// Tags that describe listening context rather than sound.
    static let ignoredTags: Set<String> = [
        "seen live", "favorites", "favourite", "favorite", "my favorite", "love", "awesome",
        "beautiful", "albums i own", "under 2000 listeners", "spotify", "best", "cool",
    ]
}
