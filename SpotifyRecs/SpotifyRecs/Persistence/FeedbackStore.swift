//
//  FeedbackStore.swift
//  SpotifyRecs
//
//  Queries and updates over stored feedback, plus training the per-genre models.
//

import Foundation
import SwiftData

struct BatchStat: Identifiable, Hashable {
    let id: UUID
    let index: Int
    let date: Date
    let shown: Int
    let liked: Int
    let disliked: Int

    var rated: Int { liked + disliked }
    /// Share of rated songs that were liked; nil when nothing in the batch was rated.
    var likeRate: Double? { rated > 0 ? Double(liked) / Double(rated) : nil }
}

@MainActor
struct FeedbackStore {
    let context: ModelContext

    // MARK: Reading

    func shownTracks(genreKey: String) -> [ShownTrack] {
        let descriptor = FetchDescriptor<ShownTrack>(
            predicate: #Predicate { $0.genreKey == genreKey },
            sortBy: [SortDescriptor(\.shownAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func allRatedTracks() -> [ShownTrack] {
        let descriptor = FetchDescriptor<ShownTrack>(
            predicate: #Predicate { $0.feedback != 0 },
            sortBy: [SortDescriptor(\.shownAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func track(genreKey: String, trackID: String) -> ShownTrack? {
        var descriptor = FetchDescriptor<ShownTrack>(
            predicate: #Predicate { $0.genreKey == genreKey && $0.trackID == trackID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: Models

    /// Global model (all genres' feedback) → genre model (this genre's feedback, regularized toward global).
    func trainedModels(genreKey: String) -> (global: PreferenceModel, genre: PreferenceModel) {
        let rated = allRatedTracks()
        let global = PreferenceModel.train(rated.map(Self.example), prior: .default,
                                           config: .init(regularization: 0.1))
        let genre = PreferenceModel.train(rated.filter { $0.genreKey == genreKey }.map(Self.example), prior: global)
        return (global, genre)
    }

    func observedTags() -> Set<String> {
        Set(allRatedTracks().flatMap { $0.features.keys.compactMap(Feature.tagName) })
    }

    private static func example(_ track: ShownTrack) -> PreferenceModel.Example {
        PreferenceModel.Example(features: track.features, liked: track.feedback > 0)
    }

    // MARK: Writing

    func recordBatch(_ recommendations: [Recommendation], genreKey: String) {
        let batchID = UUID()
        for rec in recommendations where track(genreKey: genreKey, trackID: rec.track.id) == nil {
            context.insert(ShownTrack(genreKey: genreKey, recommendation: rec, batchID: batchID))
        }
        try? context.save()
    }

    /// Sets feedback, or clears it when the same value is chosen again. Returns the new value.
    @discardableResult
    func toggleFeedback(_ value: Int, for rec: Recommendation, genreKey: String) -> Int {
        guard let stored = track(genreKey: genreKey, trackID: rec.track.id) else { return 0 }
        stored.feedback = stored.feedback == value ? 0 : value
        stored.feedbackSource = stored.feedback == 0 ? nil : .thumb
        try? context.save()
        return stored.feedback
    }

    func markAdded(trackIDs: Set<String>, genreKey: String) {
        for track in shownTracks(genreKey: genreKey) where trackIDs.contains(track.trackID) {
            track.addedToPlaylist = true
        }
        try? context.save()
    }

    /// Songs the app added to the playlist that are no longer there count as dislikes.
    /// Returns how many new dislikes were recorded.
    @discardableResult
    func recordRemovals(currentPlaylistURIs: Set<String>, genreKey: String) -> Int {
        var count = 0
        for track in shownTracks(genreKey: genreKey)
        where track.addedToPlaylist && !currentPlaylistURIs.contains(track.uri) {
            track.addedToPlaylist = false
            if track.feedback != -1 {
                track.feedback = -1
                track.feedbackSource = .removedFromPlaylist
                count += 1
            }
        }
        try? context.save()
        return count
    }

    func deleteGenre(_ genre: GenrePreference) {
        for track in shownTracks(genreKey: genre.key) { context.delete(track) }
        context.delete(genre)
        try? context.save()
    }

    // MARK: Stats

    func batchStats(genreKey: String) -> [BatchStat] {
        let grouped = Dictionary(grouping: shownTracks(genreKey: genreKey), by: \.batchID)
        return grouped
            .map { id, tracks in
                (id, tracks.map(\.shownAt).min() ?? .now, tracks)
            }
            .sorted { $0.1 < $1.1 }
            .enumerated()
            .map { index, entry in
                BatchStat(
                    id: entry.0,
                    index: index + 1,
                    date: entry.1,
                    shown: entry.2.count,
                    liked: entry.2.filter { $0.feedback > 0 }.count,
                    disliked: entry.2.filter { $0.feedback < 0 }.count
                )
            }
    }
}
