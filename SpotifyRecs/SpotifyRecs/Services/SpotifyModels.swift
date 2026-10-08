//
//  SpotifyModels.swift
//  SpotifyRecs
//
//  Only fields still returned in Development Mode after Spotify's Feb 2026 changes are relied on.
//  (popularity, followers, external_ids, etc. were removed; genres is treated as optional.)
//

import Foundation

struct SpotifyImage: Codable, Hashable {
    let url: URL
    let width: Int?
    let height: Int?
}

struct SpotifyArtistRef: Codable, Hashable {
    let id: String?
    let name: String
}

struct SpotifyArtist: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let genres: [String]?
    let images: [SpotifyImage]?
}

struct SpotifyAlbumRef: Codable, Hashable {
    let id: String?
    let name: String
    let images: [SpotifyImage]?
}

struct SpotifyTrack: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let uri: String
    let artists: [SpotifyArtistRef]
    let album: SpotifyAlbumRef?
    let durationMs: Int?
    let externalUrls: [String: URL]?

    enum CodingKeys: String, CodingKey {
        case id, name, uri, artists, album
        case durationMs = "duration_ms"
        case externalUrls = "external_urls"
    }

    var primaryArtist: String { artists.first?.name ?? "" }
    var spotifyURL: URL? { externalUrls?["spotify"] }

    /// Smallest image that is at least `minSize` pixels wide, else the largest available.
    func artworkURL(minSize: Int = 128) -> URL? {
        let images = (album?.images ?? []).sorted { ($0.width ?? 0) < ($1.width ?? 0) }
        return images.first(where: { ($0.width ?? 0) >= minSize })?.url ?? images.last?.url
    }
}

struct SpotifyPage<Item: Decodable>: Decodable {
    let items: [Item]
    let next: URL?
}

struct SpotifyPlayHistory: Decodable {
    let track: SpotifyTrack
}

struct SpotifySavedTrack: Decodable {
    let track: SpotifyTrack
}

struct SpotifySearchResponse: Decodable {
    struct Tracks: Decodable { let items: [SpotifyTrack] }
    let tracks: Tracks?
}

struct SpotifyPlaylist: Decodable {
    let id: String
    let name: String
    let externalUrls: [String: URL]?

    enum CodingKeys: String, CodingKey {
        case id, name
        case externalUrls = "external_urls"
    }

    var spotifyURL: URL? { externalUrls?["spotify"] }
}

/// Playlist entry from GET /playlists/{id}/items. The Feb 2026 API renamed `track` to `item`;
/// both are accepted.
struct SpotifyPlaylistEntry: Decodable {
    struct URIOnly: Decodable { let uri: String? }
    let item: URIOnly?
    let track: URIOnly?

    var uri: String? { (item ?? track)?.uri }
}

enum SpotifyTimeRange: String, CaseIterable {
    case shortTerm = "short_term"     // ~4 weeks
    case mediumTerm = "medium_term"   // ~6 months
    case longTerm = "long_term"       // ~1 year
}
