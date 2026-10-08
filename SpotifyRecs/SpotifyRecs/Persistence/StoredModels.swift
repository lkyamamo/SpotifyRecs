//
//  StoredModels.swift
//  SpotifyRecs
//
//  On-device storage (SwiftData). Nothing here leaves the phone.
//

import Foundation
import SwiftData

/// A genre the user asked for, e.g. "Dubstep" → Last.fm tag "dubstep".
@Model
final class GenrePreference {
    @Attribute(.unique) var key: String
    var displayName: String
    var lastFMTag: String
    /// The "recs · <Genre>" Spotify playlist, once created or found.
    var playlistID: String?
    var createdAt: Date
    var lastRunAt: Date?

    init(key: String, displayName: String, lastFMTag: String) {
        self.key = key
        self.displayName = displayName
        self.lastFMTag = lastFMTag
        self.createdAt = .now
    }

    var playlistName: String { "recs · \(displayName)" }
}

enum FeedbackSource: String, Codable {
    case thumb
    case removedFromPlaylist
}

/// A track shown in a genre batch, with the features it was scored on and any feedback.
@Model
final class ShownTrack {
    var genreKey: String
    var trackID: String
    var uri: String
    var title: String
    var artist: String
    var batchID: UUID
    var shownAt: Date
    var featuresData: Data
    /// -1 disliked, 0 no feedback, 1 liked.
    var feedback: Int
    var feedbackSourceRaw: String?
    var addedToPlaylist: Bool
    var wasExploration: Bool

    init(genreKey: String, recommendation: Recommendation, batchID: UUID) {
        self.genreKey = genreKey
        self.trackID = recommendation.track.id
        self.uri = recommendation.track.uri
        self.title = recommendation.track.name
        self.artist = recommendation.track.primaryArtist
        self.batchID = batchID
        self.shownAt = .now
        self.featuresData = (try? JSONEncoder().encode(recommendation.features)) ?? Data()
        self.feedback = 0
        self.addedToPlaylist = false
        self.wasExploration = recommendation.isExploration
    }

    var features: FeatureVector {
        (try? JSONDecoder().decode(FeatureVector.self, from: featuresData)) ?? [:]
    }

    var feedbackSource: FeedbackSource? {
        get { feedbackSourceRaw.flatMap(FeedbackSource.init(rawValue:)) }
        set { feedbackSourceRaw = newValue?.rawValue }
    }

    var trackKey: String { MatchKey.track(title: title, artist: artist) }
}
