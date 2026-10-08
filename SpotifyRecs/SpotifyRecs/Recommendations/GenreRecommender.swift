//
//  GenreRecommender.swift
//  SpotifyRecs
//
//  Network orchestration: loads the shared taste context once, then builds genre batches.
//

import Foundation

enum RecommendationStage: String, Sendable {
    case readingHistory = "Reading your Spotify history…"
    case learningTaste = "Learning your taste from Last.fm…"
    case checkingPlaylist = "Checking your playlist for removed songs…"
    case exploringGenre = "Exploring the genre on Last.fm…"
    case comparingArtists = "Comparing artists to your taste…"
    case resolvingOnSpotify = "Matching songs on Spotify…"
}

enum RecommendationError: LocalizedError {
    case notEnoughHistory
    case nothingFound(String)

    var errorDescription: String? {
        switch self {
        case .notEnoughHistory:
            "Spotify doesn’t have enough listening history for this account yet. Listen for a bit and try again."
        case .nothingFound(let genre):
            "Couldn’t find new \(genre) songs for you. You may have already seen most of what Last.fm has for this tag."
        }
    }
}

/// Loads the genre-independent taste context: Spotify history plus Last.fm neighbors of your favorites.
struct TasteContextLoader: Sendable {
    let spotify: SpotifyProviding
    let lastFM: LastFMProviding
    let limiter: RateLimiter
    var seedArtistCount = 10
    var seedTrackCount = 8

    func load(progress: @escaping @Sendable (RecommendationStage) async -> Void) async throws -> TasteContext {
        await progress(.readingHistory)
        let analyzer = TasteAnalyzer()

        async let artists = concurrentMap(SpotifyTimeRange.allCases, limit: 3) { range in
            (range, try await spotify.topArtists(range: range, limit: 50))
        }
        async let tracks = concurrentMap(SpotifyTimeRange.allCases, limit: 3) { range in
            (range, try await spotify.topTracks(range: range, limit: 50))
        }
        // History and library are nice-to-have; don't fail the whole run without them.
        async let recent = try? spotify.recentlyPlayed(limit: 50)
        async let saved = try? spotify.savedTracks(maxCount: 200)

        let profile = analyzer.buildProfile(
            topArtists: Dictionary(uniqueKeysWithValues: try await artists),
            topTracks: Dictionary(uniqueKeysWithValues: try await tracks),
            recentlyPlayed: await recent ?? [],
            savedTracks: await saved ?? []
        )
        guard !profile.seedArtists.isEmpty || !profile.seedTracks.isEmpty else {
            throw RecommendationError.notEnoughHistory
        }

        await progress(.learningTaste)
        let seedArtists = Array(profile.seedArtists.prefix(seedArtistCount))
        let seedTracks = Array(profile.seedTracks.prefix(seedTrackCount))

        async let similarArtists = concurrentMap(seedArtists, limit: 4) { seed in
            await limiter.wait()
            return (seed.name, (try? await lastFM.similarArtists(to: seed.name, limit: 50)) ?? [])
        }
        async let similarTracks = concurrentMap(seedTracks, limit: 4) { seed in
            await limiter.wait()
            return (seed.key, (try? await lastFM.similarTracks(to: seed.title, artist: seed.artist, limit: 30)) ?? [])
        }
        async let seedTags = concurrentMap(seedArtists, limit: 4) { seed in
            await limiter.wait()
            return (seed.name, (try? await lastFM.topTags(for: seed.name)) ?? [])
        }

        return TasteContext(
            profile: profile,
            userTags: analyzer.userTagProfile(
                seedTags: Dictionary(try await seedTags, uniquingKeysWith: { a, _ in a }),
                profile: profile
            ),
            artistSimilarity: analyzer.artistSimilarity(
                similar: Dictionary(try await similarArtists, uniquingKeysWith: { a, _ in a }),
                profile: profile
            ),
            similarTracks: Dictionary(try await similarTracks, uniquingKeysWith: { a, _ in a })
        )
    }
}

struct GenreRecommender: Sendable {
    let spotify: SpotifyProviding
    let lastFM: LastFMProviding
    let limiter: RateLimiter
    var selector = ExplorationSelector()
    var artistsToTag = 35
    var artistsForTopTracks = 12

    struct Request {
        let genreTag: String
        let genreName: String
        let context: TasteContext
        /// The genre's trained model and the untrained default (used to explain what changed).
        let model: PreferenceModel
        let reference: PreferenceModel
        let excludedTrackKeys: Set<String>
        let excludedTrackIDs: Set<String>
        /// Tags that appear in any rated song, used to find novel exploration picks.
        let observedTags: Set<String>
    }

    func recommend(
        _ request: Request,
        progress: @escaping @Sendable (RecommendationStage) async -> Void
    ) async throws -> [Recommendation] {
        let context = request.context

        // 1. The genre's own charts.
        await progress(.exploringGenre)
        async let chartArtists = rateLimited { try await lastFM.tagTopArtists(request.genreTag, limit: 100) }
        async let chartTracks = rateLimited { try await lastFM.tagTopTracks(request.genreTag, limit: 150) }
        let tagTopArtists = (try? await chartArtists) ?? []
        let tagTopTracks = (try? await chartTracks) ?? []

        // 2. Tags for the most promising artists: charted artists, your similar artists, chart-track artists.
        await progress(.comparingArtists)
        var priority: [String: (name: String, score: Double)] = [:]
        func consider(_ name: String, _ score: Double) {
            let key = MatchKey.artist(name)
            let similarity = context.artistSimilarity[key]?.score ?? 0
            let total = score + 1.5 * similarity
            if total > (priority[key]?.score ?? -1) { priority[key] = (name, total) }
        }
        tagTopArtists.forEach { consider($0.name, $0.rankWeight) }
        tagTopTracks.prefix(80).forEach { consider($0.artist, $0.match * 0.5) }
        context.similarTracks.values.flatMap { $0 }.forEach { consider($0.artist, $0.match * 0.5) }

        let toTag = priority.values.sorted { $0.score > $1.score }.prefix(artistsToTag).map(\.name)
        let artistTags = Dictionary(try await concurrentMap(Array(toTag), limit: 4) { name in
            (MatchKey.artist(name), (try? await rateLimited { try await lastFM.topTags(for: name) }) ?? [])
        }, uniquingKeysWith: { a, _ in a })

        // 3. Deeper catalog for genre artists closest to your taste.
        let genreArtists = toTag.filter { name in
            (artistTags[MatchKey.artist(name)] ?? []).contains { GenreCandidateBuilder.sameTag($0.name, request.genreTag) && $0.weight >= 0.3 }
        }
        let closest = genreArtists
            .sorted { (context.artistSimilarity[MatchKey.artist($0)]?.score ?? 0) > (context.artistSimilarity[MatchKey.artist($1)]?.score ?? 0) }
            .prefix(artistsForTopTracks)
        let artistTopTracks = Dictionary(try await concurrentMap(Array(closest), limit: 4) { name in
            (MatchKey.artist(name), (try? await rateLimited { try await lastFM.topTracks(for: name, limit: 5) }) ?? [])
        }, uniquingKeysWith: { a, _ in a })

        // 4. Features → model scores → exploit/explore shortlists.
        let candidates = GenreCandidateBuilder(genreTag: request.genreTag, genreName: request.genreName, context: context)
            .build(
                tagTopTracks: tagTopTracks,
                tagTopArtists: tagTopArtists,
                artistTags: artistTags,
                artistTopTracks: artistTopTracks,
                excludedTrackKeys: request.excludedTrackKeys
            )
        let scored = candidates.map { ExplorationSelector.Scored(candidate: $0, probability: request.model.probability($0.features)) }
        var rng = SystemRandomNumberGenerator()
        let lists = selector.shortlists(scored, observedTags: request.observedTags, using: &rng)

        // 5. Resolve on Spotify and assemble the batch.
        await progress(.resolvingOnSpotify)
        let exploit = try await resolve(lists.exploit)
        let explore = try await resolve(lists.explore)

        var seenIDs = context.profile.knownSpotifyTrackIDs.union(request.excludedTrackIDs)
        var perArtist: [String: Int] = [:]
        func take(_ items: [(ExplorationSelector.Scored, SpotifyTrack)], count: Int, exploration: Bool) -> [Recommendation] {
            var picked: [Recommendation] = []
            for (item, track) in items where picked.count < count {
                let artistKey = MatchKey.artist(item.candidate.artist)
                guard (perArtist[artistKey] ?? 0) < selector.maxPerArtist, seenIDs.insert(track.id).inserted else { continue }
                perArtist[artistKey, default: 0] += 1
                picked.append(Recommendation(
                    track: track,
                    features: item.candidate.features,
                    score: item.probability,
                    isExploration: exploration,
                    explanation: explanation(for: item, model: request.model, reference: request.reference)
                ))
            }
            return picked
        }
        var batch = take(exploit, count: selector.exploitCount, exploration: false)
        batch += take(explore, count: selector.batchSize - batch.count, exploration: true)
        if batch.count < selector.batchSize {  // not enough exploration picks resolved — top up
            batch += take(exploit, count: selector.batchSize - batch.count, exploration: false)
        }
        guard !batch.isEmpty else { throw RecommendationError.nothingFound(request.genreName) }
        return batch
    }

    private func resolve(_ items: [ExplorationSelector.Scored]) async throws -> [(ExplorationSelector.Scored, SpotifyTrack)] {
        try await concurrentMap(items, limit: 4) { item -> (ExplorationSelector.Scored, SpotifyTrack)? in
            let results = (try? await spotify.searchTrack(title: item.candidate.title, artist: item.candidate.artist, limit: 5)) ?? []
            return Self.bestMatch(title: item.candidate.title, artist: item.candidate.artist, in: results).map { (item, $0) }
        }
        .compactMap { $0 }
    }

    private func explanation(for item: ExplorationSelector.Scored, model: PreferenceModel, reference: PreferenceModel) -> String {
        let learned = model.learnedContributions(item.candidate.features, relativeTo: reference)
            .filter { abs($0.delta) >= 0.15 }
            .prefix(2)
            .map { key, delta in
                let name = Feature.tagName(key) ?? Self.shortLabel(key)
                return (delta > 0 ? "↑ " : "↓ ") + name
            }
        return ([item.candidate.baseReason] + learned).joined(separator: " · ")
    }

    private static func shortLabel(_ key: String) -> String {
        switch key {
        case Feature.artistSimilarity: "close to your artists"
        case Feature.tagAffinity: "your style"
        case Feature.genreStrength: "core genre"
        case Feature.genreRank: "genre hit"
        case Feature.trackSimilarity: "like your top tracks"
        case Feature.knownArtist: "artist you know"
        default: key
        }
    }

    private func rateLimited<T>(_ work: () async throws -> T) async throws -> T {
        await limiter.wait()
        return try await work()
    }

    /// Finds the Spotify track matching a Last.fm (title, artist) pair. Requires the same artist,
    /// so covers and karaoke versions are rejected.
    static func bestMatch(title: String, artist: String, in results: [SpotifyTrack]) -> SpotifyTrack? {
        let artistKey = MatchKey.artist(artist)
        let titleKey = MatchKey.title(title)
        let sameArtist = results.filter { track in
            track.artists.contains { MatchKey.artist($0.name) == artistKey }
        }
        return sameArtist.first { MatchKey.title($0.name) == titleKey }
            ?? sameArtist.first { MatchKey.title($0.name).hasPrefix(titleKey) || titleKey.hasPrefix(MatchKey.title($0.name)) }
    }
}

extension LastFMTrack {
    var key: String { MatchKey.track(title: name, artist: artist) }
}

extension TasteContext {
    /// Genres the user already gravitates to, for quick-pick suggestions.
    func suggestedGenres(limit: Int = 10) -> [String] {
        userTags
            .filter { GenreNames.isGenreTag($0.key) }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}
