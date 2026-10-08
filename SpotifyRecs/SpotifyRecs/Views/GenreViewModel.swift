//
//  GenreViewModel.swift
//  SpotifyRecs
//

import Foundation
import Observation

@MainActor
@Observable
final class GenreViewModel {
    enum State {
        case idle
        case loading(RecommendationStage)
        case loaded
        case failed(String)
    }

    struct Insights {
        var likedTags: [String] = []
        var dislikedTags: [String] = []
        var habits: [String] = []
        var ratedCount = 0
        var stats: [BatchStat] = []
    }

    let genre: GenrePreference
    private(set) var state: State = .idle
    private(set) var recommendations: [Recommendation] = []
    private(set) var feedback: [String: Int] = [:]
    private(set) var insights = Insights()
    private(set) var isAddingToPlaylist = false
    private(set) var statusMessage: String?
    var errorMessage: String?

    @ObservationIgnored private let app: AppModel
    @ObservationIgnored private let store: FeedbackStore

    init(genre: GenrePreference, app: AppModel, store: FeedbackStore) {
        self.genre = genre
        self.app = app
        self.store = store
        refreshInsights()
    }

    var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    // MARK: Generating

    func generate() async {
        guard !isLoading else { return }
        statusMessage = nil
        let progress: @Sendable (RecommendationStage) async -> Void = { [weak self] stage in
            await MainActor.run { self?.state = .loading(stage) }
        }
        state = .loading(.readingHistory)

        do {
            let context = try await app.loadTasteContext(progress: progress)

            await progress(.checkingPlaylist)
            let removed = await syncPlaylistRemovals()

            let models = store.trainedModels(genreKey: genre.key)
            let shown = store.shownTracks(genreKey: genre.key)
            let request = GenreRecommender.Request(
                genreTag: genre.lastFMTag,
                genreName: genre.displayName,
                context: context,
                model: models.genre,
                reference: .default,
                excludedTrackKeys: Set(shown.map(\.trackKey)),
                excludedTrackIDs: Set(shown.map(\.trackID)),
                observedTags: store.observedTags()
            )
            let recs = try await app.recommender().recommend(request, progress: progress)

            store.recordBatch(recs, genreKey: genre.key)
            genre.lastRunAt = .now
            recommendations = recs
            feedback = [:]
            state = .loaded
            if removed > 0 {
                statusMessage = "Learned from \(removed) song\(removed == 1 ? "" : "s") you removed from the playlist."
            }
            refreshInsights()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Songs removed from the "recs · <Genre>" playlist count as dislikes.
    private func syncPlaylistRemovals() async -> Int {
        guard let playlistID = genre.playlistID else { return 0 }
        do {
            let uris = try await app.spotify.playlistItemURIs(id: playlistID)
            return store.recordRemovals(currentPlaylistURIs: uris, genreKey: genre.key)
        } catch SpotifyAPIError.http(404, _) {
            genre.playlistID = nil  // playlist was deleted; a new one is created on next add
            return 0
        } catch {
            return 0  // non-fatal; try again next run
        }
    }

    // MARK: Feedback

    func setFeedback(_ value: Int, for rec: Recommendation) {
        feedback[rec.id] = store.toggleFeedback(value, for: rec, genreKey: genre.key)
        refreshInsights()
    }

    func refreshInsights() {
        let models = store.trainedModels(genreKey: genre.key)
        let tags = models.genre.learnedTags(relativeTo: .default)
        insights = Insights(
            likedTags: tags.liked,
            dislikedTags: tags.disliked,
            habits: models.genre.learnedHabits(relativeTo: .default),
            ratedCount: store.shownTracks(genreKey: genre.key).filter { $0.feedback != 0 }.count,
            stats: store.batchStats(genreKey: genre.key)
        )
    }

    // MARK: Playlist

    /// Adds this batch (minus disliked songs) to "recs · <Genre>", creating it if needed.
    func addToPlaylist() async {
        let toAdd = recommendations.filter { (feedback[$0.id] ?? 0) >= 0 }
        guard !toAdd.isEmpty, !isAddingToPlaylist else { return }
        isAddingToPlaylist = true
        defer { isAddingToPlaylist = false }

        do {
            var created = false
            let playlistID: String
            if let existing = genre.playlistID {
                playlistID = existing
            } else if let found = try await app.spotify.myPlaylists().first(where: { $0.name == genre.playlistName }) {
                playlistID = found.id
            } else {
                playlistID = try await app.spotify.createPlaylist(
                    name: genre.playlistName,
                    description: "\(genre.displayName) picks from SpotifyRecs. Remove songs you don’t like — the app learns from it."
                ).id
                created = true
            }
            genre.playlistID = playlistID

            let existingURIs = created ? [] : try await app.spotify.playlistItemURIs(id: playlistID)
            let newURIs = toAdd.map(\.track.uri).filter { !existingURIs.contains($0) }
            if !newURIs.isEmpty {
                try await app.spotify.addToPlaylist(id: playlistID, uris: newURIs)
            }
            store.markAdded(trackIDs: Set(toAdd.map(\.id)), genreKey: genre.key)

            statusMessage = "Added \(newURIs.count) songs to \(genre.playlistName)."
                + (created ? " New playlist — drag it into your “recs” folder in Spotify (the API can’t manage folders)." : "")
        } catch SpotifyAPIError.http(404, _) {
            genre.playlistID = nil
            errorMessage = "The playlist was deleted in Spotify. Tap Add again to create a new one."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
