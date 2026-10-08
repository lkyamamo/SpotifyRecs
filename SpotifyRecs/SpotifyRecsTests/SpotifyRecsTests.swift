//
//  SpotifyRecsTests.swift
//  SpotifyRecsTests
//
//  Created by Logan Yamamoto on 7/24/24.
//

import SwiftData
import XCTest
@testable import SpotifyRecs

final class MatchKeyTests: XCTestCase {
    func testArtistNormalization() {
        XCTAssertEqual(MatchKey.artist("The Beatles"), MatchKey.artist("beatles"))
        XCTAssertEqual(MatchKey.artist("Beyoncé"), MatchKey.artist("Beyonce"))
        XCTAssertEqual(MatchKey.artist("Simon & Garfunkel"), MatchKey.artist("Simon and Garfunkel"))
    }

    func testTitleNormalization() {
        XCTAssertEqual(MatchKey.title("Something - Remastered 2009"), "something")
        XCTAssertEqual(MatchKey.title("Song (feat. Someone)"), "song")
        XCTAssertEqual(MatchKey.title("Song [Live]"), "song")
        XCTAssertEqual(MatchKey.title("Song ft. Someone"), "song")
    }
}

final class PKCETests: XCTestCase {
    func testChallengeIsBase64URLEncodedSHA256() {
        // Expected value computed independently: base64url(sha256(verifier)) without padding.
        let verifier = "dBjftJeZ4CVP-mA92QOJMTlUWLM2jfZ1k6cT0y8G4LY"
        XCTAssertEqual(PKCE.codeChallenge(for: verifier), "PqfuHArWHGUrPfhNb8A8hTlszr1qg82EOCBQCA1_HR0")
    }

    func testVerifierIsURLSafeAndLongEnough() {
        let verifier = PKCE.makeCodeVerifier()
        XCTAssertGreaterThanOrEqual(verifier.count, 43)
        XCTAssertLessThanOrEqual(verifier.count, 128)
        XCTAssertNil(verifier.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }
}

final class LastFMDecodingTests: XCTestCase {
    private struct Wrapper: Decodable {
        struct Container: Decodable { let artist: FlexibleArray<Artist> }
        struct Artist: Decodable { let name: String; let match: FlexibleDouble }
        let similarartists: Container
    }

    func testDecodesArrayWithStringNumbers() throws {
        let json = #"{"similarartists":{"artist":[{"name":"A","match":"0.5"},{"name":"B","match":1}]}}"#
        let decoded = try JSONDecoder().decode(Wrapper.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.similarartists.artist.values.map(\.name), ["A", "B"])
        XCTAssertEqual(decoded.similarartists.artist.values.map(\.match.value), [0.5, 1])
    }

    func testDecodesSingleObjectAndMissingKey() throws {
        let single = #"{"similarartists":{"artist":{"name":"A","match":"0.5"}}}"#
        XCTAssertEqual(try JSONDecoder().decode(Wrapper.self, from: Data(single.utf8)).similarartists.artist.values.count, 1)

        let missing = #"{"similarartists":{}}"#
        XCTAssertEqual(try JSONDecoder().decode(Wrapper.self, from: Data(missing.utf8)).similarartists.artist.values.count, 0)
    }
}


// MARK: - Helpers

private func makeArtist(_ name: String, genres: [String] = []) -> SpotifyArtist {
    SpotifyArtist(id: name, name: name, genres: genres, images: nil)
}

private func makeTrack(_ title: String, by artist: String) -> SpotifyTrack {
    SpotifyTrack(
        id: "\(artist)-\(title)", name: title, uri: "spotify:track:\(artist)-\(title)",
        artists: [SpotifyArtistRef(id: artist, name: artist)], album: nil, durationMs: nil, externalUrls: nil
    )
}

private func tags(_ pairs: (String, Double)...) -> [LastFMTag] {
    pairs.map { LastFMTag(name: $0.0, weight: $0.1) }
}

/// Deterministic RNG for exploration tests.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func sampleProfile() -> ListeningProfile {
    TasteAnalyzer().buildProfile(
        topArtists: [.shortTerm: [makeArtist("Radiohead", genres: ["art rock"]), makeArtist("Portishead")]],
        topTracks: [.shortTerm: [makeTrack("Reckoner", by: "Radiohead")]],
        recentlyPlayed: [makeTrack("Roads", by: "Portishead")],
        savedTracks: [makeTrack("Teardrop", by: "Massive Attack")]
    )
}

// MARK: - Taste analysis

final class TasteAnalyzerTests: XCTestCase {
    func testProfileWeightsAndKnownSets() {
        let profile = sampleProfile()
        XCTAssertEqual(profile.seedArtists.first?.name, "Radiohead")
        XCTAssertTrue(profile.knownArtistKeys.contains(MatchKey.artist("Massive Attack")), "saved-track artists count as known")
        XCTAssertTrue(profile.knownTrackKeys.contains(MatchKey.track(title: "Roads", artist: "Portishead")))
    }

    func testArtistSimilarityRewardsBreadth() {
        let similarity = TasteAnalyzer().artistSimilarity(similar: [
            "Radiohead": [LastFMSimilarArtist(name: "Thom Yorke", match: 0.9), LastFMSimilarArtist(name: "Beach House", match: 0.5)],
            "Portishead": [LastFMSimilarArtist(name: "Beach House", match: 0.6)],
        ], profile: sampleProfile())

        XCTAssertEqual(similarity.values.map(\.score).max(), 1)
        XCTAssertEqual(similarity[MatchKey.artist("Beach House")]?.becauseOf.count, 2)
    }

    func testTagAffinity() {
        let analyzer = TasteAnalyzer()
        let user = ["trip-hop": 1.0, "electronic": 0.5]
        let close = analyzer.tagAffinity(user: user, candidate: tags(("trip-hop", 1)))
        let far = analyzer.tagAffinity(user: user, candidate: tags(("country", 1)))
        XCTAssertGreaterThan(close.score, far.score)
        XCTAssertEqual(far.score, 0)
    }
}

// MARK: - Learning

final class PreferenceModelTests: XCTestCase {
    private let melodic: FeatureVector = [Feature.bias: 1, Feature.genreStrength: 1, Feature.tag("melodic dubstep"): 1]
    private let heavy: FeatureVector = [Feature.bias: 1, Feature.genreStrength: 1, Feature.tag("brostep"): 1]

    func testNoExamplesKeepsPrior() {
        XCTAssertEqual(PreferenceModel.train([], prior: .default), .default)
    }

    func testLearnsTagPreferencesFromFeedback() {
        let examples = [
            PreferenceModel.Example(features: melodic, liked: true),
            PreferenceModel.Example(features: melodic, liked: true),
            PreferenceModel.Example(features: heavy, liked: false),
            PreferenceModel.Example(features: heavy, liked: false),
        ]
        let model = PreferenceModel.train(examples, prior: .default)

        XCTAssertEqual(PreferenceModel.default.probability(melodic), PreferenceModel.default.probability(heavy), accuracy: 1e-9)
        XCTAssertGreaterThan(model.probability(melodic), model.probability(heavy) + 0.2)

        let learned = model.learnedTags(relativeTo: .default)
        XCTAssertEqual(learned.liked, ["melodic dubstep"])
        XCTAssertEqual(learned.disliked, ["brostep"])
    }

    func testLearnsHabitsAndExplainsContributions() {
        let deepCut: FeatureVector = [Feature.bias: 1, Feature.knownArtist: 1]
        let newArtist: FeatureVector = [Feature.bias: 1, Feature.knownArtist: 0]
        let examples = Array(repeating: PreferenceModel.Example(features: deepCut, liked: true), count: 4)
            + Array(repeating: PreferenceModel.Example(features: newArtist, liked: false), count: 4)
        let model = PreferenceModel.train(examples, prior: .default)

        XCTAssertTrue(model.learnedHabits(relativeTo: .default).contains("Likes deeper cuts from artists you know"))
        XCTAssertEqual(model.learnedContributions(deepCut, relativeTo: .default).first?.key, Feature.knownArtist)
    }

    func testRegularizationKeepsSingleRatingModest() {
        let model = PreferenceModel.train([PreferenceModel.Example(features: heavy, liked: false)], prior: .default)
        let delta = (model.weights[Feature.tag("brostep")] ?? 0)
        XCTAssertLessThan(delta, 0)
        XCTAssertGreaterThan(delta, -1.5, "one dislike should nudge, not obliterate")
    }
}

// MARK: - Exploration

final class ExplorationSelectorTests: XCTestCase {
    private func scored(_ count: Int, artists: Int? = nil) -> [ExplorationSelector.Scored] {
        (0..<count).map { index in
            let artist = "Artist\(artists.map { index % $0 } ?? index)"
            let candidate = GenreCandidate(title: "Song\(index)", artist: artist,
                                           features: [Feature.tag("tag\(index % 7)"): 1], baseReason: "")
            return ExplorationSelector.Scored(candidate: candidate, probability: 1 - Double(index) / Double(count))
        }
    }

    func testExploitIsTopRankedAndExploreComesFromTheRest() {
        let selector = ExplorationSelector(batchSize: 10, explorationShare: 0.2)
        var rng = SplitMix64(state: 42)
        let lists = selector.shortlists(scored(100), observedTags: [], using: &rng)

        XCTAssertEqual(lists.exploit.first?.candidate.title, "Song0")
        XCTAssertEqual(lists.exploit.count, 12)  // 8 needed × 1.6 headroom
        XCTAssertEqual(lists.explore.count, 4)   // 2 needed × 2 headroom
        let exploitTitles = Set(lists.exploit.map(\.candidate.title))
        XCTAssertTrue(lists.explore.allSatisfy { !exploitTitles.contains($0.candidate.title) })
    }

    func testNoveltyFavorsUnseenTags() {
        let selector = ExplorationSelector()
        let candidate = GenreCandidate(title: "A", artist: "B",
                                       features: [Feature.tag("seen"): 1, Feature.tag("new"): 1], baseReason: "")
        XCTAssertEqual(selector.novelty(candidate, observedTags: ["seen"]), 0.5)
    }

    func testDiversifyCapsPerArtist() {
        let selector = ExplorationSelector(maxPerArtist: 2)
        XCTAssertEqual(selector.diversify(scored(10, artists: 1), cap: 2).count, 2)
    }
}

// MARK: - Genre candidates

final class GenreCandidateBuilderTests: XCTestCase {
    private func context() -> TasteContext {
        let profile = sampleProfile()
        return TasteContext(
            profile: profile,
            userTags: ["trip-hop": 1, "electronic": 1],
            artistSimilarity: [MatchKey.artist("Burial"): ArtistSimilarity(score: 0.9, becauseOf: ["Portishead"])],
            similarTracks: [
                MatchKey.track(title: "Reckoner", artist: "Radiohead"): [
                    LastFMTrack(name: "Archangel", artist: "Burial", match: 0.8),
                    LastFMTrack(name: "Some Ballad", artist: "Pop Singer", match: 0.9),  // not dubstep
                ],
            ]
        )
    }

    func testBuildsGenreCandidatesWithFeatures() {
        let candidates = GenreCandidateBuilder(genreTag: "dubstep", genreName: "Dubstep", context: context()).build(
            tagTopTracks: [
                LastFMTrack(name: "Scary Monsters", artist: "Skrillex", match: 1),
                LastFMTrack(name: "Roads", artist: "Portishead", match: 0.9),  // already known
            ],
            tagTopArtists: [LastFMRankedArtist(name: "Skrillex", rankWeight: 1)],
            artistTags: [
                MatchKey.artist("Burial"): tags(("dubstep", 1), ("electronic", 0.8), ("ambient", 0.5)),
                MatchKey.artist("Skrillex"): tags(("dubstep", 1), ("brostep", 0.9)),
                MatchKey.artist("Pop Singer"): tags(("pop", 1)),
            ],
            artistTopTracks: [:],
            excludedTrackKeys: []
        )

        let titles = Set(candidates.map(\.title))
        XCTAssertEqual(titles, ["Scary Monsters", "Archangel"])

        let archangel = candidates.first { $0.title == "Archangel" }!
        XCTAssertEqual(archangel.features[Feature.artistSimilarity], 0.9)
        XCTAssertEqual(archangel.features[Feature.trackSimilarity], 1)
        XCTAssertEqual(archangel.features[Feature.tagAffinity], 1)
        XCTAssertNil(archangel.features[Feature.tag("dubstep")], "the genre tag itself isn't a feature")
        XCTAssertNotNil(archangel.features[Feature.tag("ambient")])
        XCTAssertTrue(archangel.baseReason.contains("Reckoner"))

        let skrillex = candidates.first { $0.title == "Scary Monsters" }!
        XCTAssertEqual(skrillex.features[Feature.genreRank], 1)
        XCTAssertEqual(skrillex.features[Feature.tag("brostep")], 0.9)
    }

    func testExcludedTracksAreSkipped() {
        let candidates = GenreCandidateBuilder(genreTag: "dubstep", genreName: "Dubstep", context: context()).build(
            tagTopTracks: [LastFMTrack(name: "Scary Monsters", artist: "Skrillex", match: 1)],
            tagTopArtists: [],
            artistTags: [:],
            artistTopTracks: [:],
            excludedTrackKeys: [MatchKey.track(title: "Scary Monsters", artist: "Skrillex")]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testBestMatchRequiresSameArtist() {
        let results = [makeTrack("Space Song", by: "Cover Band"), makeTrack("Space Song - Remastered", by: "Beach House")]
        XCTAssertEqual(GenreRecommender.bestMatch(title: "Space Song", artist: "Beach House", in: results)?.artists.first?.name, "Beach House")
        XCTAssertNil(GenreRecommender.bestMatch(title: "Space Song", artist: "Beach House", in: [makeTrack("Space Song", by: "Cover Band")]))
    }
}

// MARK: - Genre names

final class GenreNamesTests: XCTestCase {
    func testVariants() {
        XCTAssertTrue(GenreNames.variants(for: "Jrock").contains("j-rock"))
        XCTAssertTrue(GenreNames.variants(for: "drum n bass").contains("drum and bass"))
        XCTAssertTrue(GenreNames.variants(for: "DnB").contains("drum and bass"))
        XCTAssertEqual(GenreNames.variants(for: "Indie  Rock").first, "indie rock")
        XCTAssertTrue(GenreNames.variants(for: "jazz").allSatisfy { !$0.contains("-") })
    }

    func testDisplayNamesAndTags() {
        XCTAssertEqual(GenreNames.displayName("jrock"), "J-Rock")
        XCTAssertEqual(GenreNames.displayName("dubstep"), "Dubstep")
        XCTAssertFalse(GenreNames.isGenreTag("80s"))
        XCTAssertFalse(GenreNames.isGenreTag("female vocalists"))
        XCTAssertTrue(GenreNames.isGenreTag("shoegaze"))
        XCTAssertTrue(GenreCandidateBuilder.sameTag("J-Rock", "jrock"))
    }
}

// MARK: - Stored feedback

@MainActor
final class FeedbackStoreTests: XCTestCase {
    private func makeStore() throws -> FeedbackStore {
        let container = try ModelContainer(
            for: GenrePreference.self, ShownTrack.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return FeedbackStore(context: ModelContext(container))
    }

    private func rec(_ title: String, tag: String) -> Recommendation {
        Recommendation(track: makeTrack(title, by: "Artist \(title)"),
                       features: [Feature.bias: 1, Feature.tag(tag): 1],
                       score: 0.5, isExploration: false, explanation: "")
    }

    func testFeedbackRemovalsStatsAndTraining() throws {
        let store = try makeStore()
        let liked = rec("A", tag: "melodic dubstep")
        let disliked = rec("B", tag: "brostep")
        let removed = rec("C", tag: "riddim")
        store.recordBatch([liked, disliked, removed], genreKey: "dubstep")

        XCTAssertEqual(store.toggleFeedback(1, for: liked, genreKey: "dubstep"), 1)
        XCTAssertEqual(store.toggleFeedback(-1, for: disliked, genreKey: "dubstep"), -1)
        XCTAssertEqual(store.toggleFeedback(-1, for: disliked, genreKey: "dubstep"), 0, "tapping again clears")
        store.toggleFeedback(-1, for: disliked, genreKey: "dubstep")

        store.markAdded(trackIDs: [liked.id, removed.id], genreKey: "dubstep")
        let newDislikes = store.recordRemovals(currentPlaylistURIs: [liked.track.uri], genreKey: "dubstep")
        XCTAssertEqual(newDislikes, 1)
        XCTAssertEqual(store.track(genreKey: "dubstep", trackID: removed.id)?.feedbackSource, .removedFromPlaylist)

        let stats = store.batchStats(genreKey: "dubstep")
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.first?.liked, 1)
        XCTAssertEqual(stats.first?.disliked, 2)

        let model = store.trainedModels(genreKey: "dubstep").genre
        XCTAssertGreaterThan(model.weights[Feature.tag("melodic dubstep")] ?? 0, 0)
        XCTAssertLessThan(model.weights[Feature.tag("riddim")] ?? 0, 0)
        XCTAssertEqual(store.observedTags(), ["melodic dubstep", "brostep", "riddim"])
    }
}
