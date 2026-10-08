//
//  SpotifyAPI.swift
//  SpotifyRecs
//

import Foundation

enum SpotifyAPIError: LocalizedError {
    case http(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(403, _):
            "Spotify refused the request (403). In Development Mode your Spotify account must be added under User Management in the developer dashboard."
        case .http(let status, let body): "Spotify request failed (\(status)): \(body)"
        case .invalidResponse: "Unexpected response from Spotify."
        }
    }
}

/// The Spotify operations the recommendation pipeline depends on (mockable in tests).
protocol SpotifyProviding: Sendable {
    func topArtists(range: SpotifyTimeRange, limit: Int) async throws -> [SpotifyArtist]
    func topTracks(range: SpotifyTimeRange, limit: Int) async throws -> [SpotifyTrack]
    func recentlyPlayed(limit: Int) async throws -> [SpotifyTrack]
    func savedTracks(maxCount: Int) async throws -> [SpotifyTrack]
    func searchTrack(title: String, artist: String, limit: Int) async throws -> [SpotifyTrack]
}

final class SpotifyAPI: SpotifyProviding, @unchecked Sendable {
    private let baseURL = URL(string: "https://api.spotify.com/v1/")!
    private let session: URLSession
    private let accessToken: @Sendable () async throws -> String

    init(session: URLSession = .shared, accessToken: @escaping @Sendable () async throws -> String) {
        self.session = session
        self.accessToken = accessToken
    }

    // MARK: Reading listening history

    func topArtists(range: SpotifyTimeRange, limit: Int = 50) async throws -> [SpotifyArtist] {
        let page: SpotifyPage<SpotifyArtist> = try await get("me/top/artists", query: [
            "time_range": range.rawValue, "limit": String(min(limit, 50)),
        ])
        return page.items
    }

    func topTracks(range: SpotifyTimeRange, limit: Int = 50) async throws -> [SpotifyTrack] {
        let page: SpotifyPage<SpotifyTrack> = try await get("me/top/tracks", query: [
            "time_range": range.rawValue, "limit": String(min(limit, 50)),
        ])
        return page.items
    }

    func recentlyPlayed(limit: Int = 50) async throws -> [SpotifyTrack] {
        let page: SpotifyPage<SpotifyPlayHistory> = try await get("me/player/recently-played", query: [
            "limit": String(min(limit, 50)),
        ])
        return page.items.map(\.track)
    }

    func savedTracks(maxCount: Int = 200) async throws -> [SpotifyTrack] {
        var tracks: [SpotifyTrack] = []
        var offset = 0
        while tracks.count < maxCount {
            let page: SpotifyPage<SpotifySavedTrack> = try await get("me/tracks", query: [
                "limit": "50", "offset": String(offset),
            ])
            tracks += page.items.map(\.track)
            guard page.next != nil, !page.items.isEmpty else { break }
            offset += page.items.count
        }
        return Array(tracks.prefix(maxCount))
    }

    // MARK: Search (limit max is 10 in Development Mode)

    func searchTrack(title: String, artist: String, limit: Int = 5) async throws -> [SpotifyTrack] {
        let response: SpotifySearchResponse = try await get("search", query: [
            "q": "track:\(title) artist:\(artist)",
            "type": "track",
            "limit": String(min(limit, 10)),
        ])
        return response.tracks?.items ?? []
    }

    // MARK: Playlists

    func createPlaylist(name: String, description: String) async throws -> SpotifyPlaylist {
        try await send("me/playlists", method: "POST", body: [
            "name": name, "description": description, "public": false,
        ])
    }

    /// The current user's playlists (owned and followed), up to `maxCount`.
    func myPlaylists(maxCount: Int = 500) async throws -> [SpotifyPlaylist] {
        var playlists: [SpotifyPlaylist] = []
        var offset = 0
        while playlists.count < maxCount {
            let page: SpotifyPage<SpotifyPlaylist> = try await get("me/playlists", query: [
                "limit": "50", "offset": String(offset),
            ])
            playlists += page.items
            guard page.next != nil, !page.items.isEmpty else { break }
            offset += page.items.count
        }
        return playlists
    }

    func playlistItemURIs(id: String) async throws -> Set<String> {
        var uris: Set<String> = []
        var offset = 0
        while true {
            let page: SpotifyPage<SpotifyPlaylistEntry> = try await get("playlists/\(id)/items", query: [
                "limit": "100", "offset": String(offset),
            ])
            uris.formUnion(page.items.compactMap(\.uri))
            guard page.next != nil, !page.items.isEmpty else { break }
            offset += page.items.count
        }
        return uris
    }

    func addToPlaylist(id: String, uris: [String]) async throws {
        for start in stride(from: 0, to: uris.count, by: 100) {
            let chunk = Array(uris[start..<min(start + 100, uris.count)])
            struct Snapshot: Decodable { let snapshot_id: String? }
            let _: Snapshot = try await send("playlists/\(id)/items", method: "POST", body: ["uris": chunk])
        }
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await perform(URLRequest(url: components.url!))
    }

    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any]) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private func perform<T: Decodable>(_ request: URLRequest, retriesLeft: Int = 2) async throws -> T {
        var request = request
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SpotifyAPIError.invalidResponse }

        if http.statusCode == 429, retriesLeft > 0 {
            let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1
            try await Task.sleep(for: .seconds(min(wait, 10)))
            return try await perform(request, retriesLeft: retriesLeft - 1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SpotifyAPIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
