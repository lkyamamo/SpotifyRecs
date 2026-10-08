//
//  RecommendationModels.swift
//  SpotifyRecs
//

import Foundation

/// Normalizes names so "The Beatles" / "beatles" and "Song (2011 Remaster)" / "song" compare equal.
enum MatchKey {
    static func artist(_ name: String) -> String {
        var key = clean(name)
        if key.hasPrefix("the ") { key.removeFirst(4) }
        return key
    }

    static func title(_ name: String) -> String {
        var title = name.lowercased()
        // Drop " - Remastered 2011", " - Live", etc.
        if let range = title.range(of: " - ") { title = String(title[..<range.lowerBound]) }
        // Drop "(feat. X)", "[Remix]", etc.
        title = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s.*$"#, with: "", options: .regularExpression)
        return clean(title)
    }

    static func track(title: String, artist: String) -> String {
        "\(self.artist(artist))|\(self.title(title))"
    }

    private static func clean(_ string: String) -> String {
        let folded = string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
        let scalars = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return String(scalars).split(separator: " ").joined(separator: " ")
    }
}

struct WeightedArtist: Hashable {
    let name: String
    let weight: Double
    /// Spotify genres if the API still returns them; often empty in Development Mode.
    let genres: [String]

    var key: String { MatchKey.artist(name) }
}

struct WeightedTrack: Hashable {
    let title: String
    let artist: String
    let weight: Double

    var key: String { MatchKey.track(title: title, artist: artist) }
}

/// Everything we know about the user's taste, derived from Spotify listening data.
struct ListeningProfile {
    var seedArtists: [WeightedArtist]
    var seedTracks: [WeightedTrack]
    /// Artists the user clearly already knows (by MatchKey.artist).
    var knownArtistKeys: Set<String>
    /// Tracks the user has played or saved (by MatchKey.track).
    var knownTrackKeys: Set<String>
    var knownSpotifyTrackIDs: Set<String>
}

struct ArtistSimilarity: Hashable {
    /// Collaborative signal from the Last.fm similar-artist graph, normalized 0...1.
    let score: Double
    /// Seed artists that pointed to this one, strongest first.
    let becauseOf: [String]
}

/// Genre-independent taste data, loaded once per session and shared by every genre.
struct TasteContext {
    let profile: ListeningProfile
    /// Weighted tag vector built from the user's seed artists.
    let userTags: [String: Double]
    let artistSimilarity: [String: ArtistSimilarity]
    /// Last.fm similar tracks per seed track (keyed by `WeightedTrack.key`).
    let similarTracks: [String: [LastFMTrack]]
}

struct Recommendation: Identifiable, Hashable {
    let track: SpotifyTrack
    let features: FeatureVector
    /// Model's estimated probability that the user likes this track.
    let score: Double
    let isExploration: Bool
    let explanation: String

    var id: String { track.id }
}
