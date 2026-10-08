//
//  LastFMAPI.swift
//  SpotifyRecs
//
//  Read-only Last.fm methods (API key only, no user auth). Docs: https://www.last.fm/api
//

import Foundation

struct LastFMSimilarArtist: Hashable {
    let name: String
    let match: Double  // 0...1
}

struct LastFMTrack: Hashable {
    let name: String
    let artist: String
    let match: Double  // 0...1 for similar tracks; rank-derived for top tracks
}

struct LastFMTag: Hashable {
    let name: String
    let weight: Double  // Last.fm "count", normalized 0...1
}

enum LastFMError: LocalizedError {
    case api(Int, String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .api(let code, let message): "Last.fm error \(code): \(message)"
        case .http(let status): "Last.fm request failed (\(status))."
        }
    }
}

struct LastFMTagInfo: Hashable {
    let name: String
    /// Number of distinct users who applied the tag — a proxy for how much data exists.
    let reach: Double
}

/// An artist from a tag's chart, with rank turned into a 1.0 → 0.3 weight.
struct LastFMRankedArtist: Hashable {
    let name: String
    let rankWeight: Double
}

protocol LastFMProviding: Sendable {
    func similarArtists(to artist: String, limit: Int) async throws -> [LastFMSimilarArtist]
    func similarTracks(to track: String, artist: String, limit: Int) async throws -> [LastFMTrack]
    func topTracks(for artist: String, limit: Int) async throws -> [LastFMTrack]
    func topTags(for artist: String) async throws -> [LastFMTag]
    func tagInfo(_ tag: String) async throws -> LastFMTagInfo
    func tagTopArtists(_ tag: String, limit: Int) async throws -> [LastFMRankedArtist]
    /// `match` holds the rank weight (1.0 for #1, sliding to 0.3).
    func tagTopTracks(_ tag: String, limit: Int) async throws -> [LastFMTrack]
}

final class LastFMAPI: LastFMProviding, @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession
    private let baseURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func similarArtists(to artist: String, limit: Int = 30) async throws -> [LastFMSimilarArtist] {
        struct Response: Decodable {
            struct Container: Decodable { let artist: FlexibleArray<Artist> }
            struct Artist: Decodable { let name: String; let match: FlexibleDouble }
            let similarartists: Container
        }
        let response: Response = try await call("artist.getsimilar", ["artist": artist, "limit": String(limit), "autocorrect": "1"])
        return response.similarartists.artist.values.map { LastFMSimilarArtist(name: $0.name, match: $0.match.value) }
    }

    func similarTracks(to track: String, artist: String, limit: Int = 20) async throws -> [LastFMTrack] {
        struct Response: Decodable {
            struct Container: Decodable { let track: FlexibleArray<Track> }
            struct Track: Decodable { let name: String; let match: FlexibleDouble; let artist: ArtistName }
            let similartracks: Container
        }
        let response: Response = try await call("track.getsimilar", [
            "track": track, "artist": artist, "limit": String(limit), "autocorrect": "1",
        ])
        return response.similartracks.track.values.map {
            LastFMTrack(name: $0.name, artist: $0.artist.name, match: $0.match.value)
        }
    }

    func topTracks(for artist: String, limit: Int = 5) async throws -> [LastFMTrack] {
        struct Response: Decodable {
            struct Container: Decodable { let track: FlexibleArray<Track> }
            struct Track: Decodable { let name: String; let artist: ArtistName }
            let toptracks: Container
        }
        let response: Response = try await call("artist.gettoptracks", ["artist": artist, "limit": String(limit), "autocorrect": "1"])
        let tracks = response.toptracks.track.values
        // Turn rank into a 1.0 → 0.5 weight so an artist's biggest song leads.
        return tracks.enumerated().map { index, track in
            let weight = 1.0 - 0.5 * Double(index) / Double(max(tracks.count - 1, 1))
            return LastFMTrack(name: track.name, artist: track.artist.name, match: weight)
        }
    }

    func topTags(for artist: String) async throws -> [LastFMTag] {
        struct Response: Decodable {
            struct Container: Decodable { let tag: FlexibleArray<Tag> }
            struct Tag: Decodable { let name: String; let count: FlexibleDouble }
            let toptags: Container
        }
        let response: Response = try await call("artist.gettoptags", ["artist": artist, "autocorrect": "1"])
        return response.toptags.tag.values.prefix(15).compactMap { tag in
            let weight = tag.count.value / 100
            return weight > 0 ? LastFMTag(name: tag.name.lowercased(), weight: weight) : nil
        }
    }

    func tagInfo(_ tag: String) async throws -> LastFMTagInfo {
        struct Response: Decodable {
            struct Tag: Decodable { let name: String; let reach: FlexibleDouble? }
            let tag: Tag
        }
        let response: Response = try await call("tag.getinfo", ["tag": tag])
        return LastFMTagInfo(name: response.tag.name.lowercased(), reach: response.tag.reach?.value ?? 0)
    }

    func tagTopArtists(_ tag: String, limit: Int = 100) async throws -> [LastFMRankedArtist] {
        struct Response: Decodable {
            struct Container: Decodable { let artist: FlexibleArray<Artist> }
            struct Artist: Decodable { let name: String }
            let topartists: Container
        }
        let response: Response = try await call("tag.gettopartists", ["tag": tag, "limit": String(limit)])
        let artists = response.topartists.artist.values
        return artists.enumerated().map { index, artist in
            LastFMRankedArtist(name: artist.name, rankWeight: Self.rankWeight(index, of: artists.count))
        }
    }

    func tagTopTracks(_ tag: String, limit: Int = 150) async throws -> [LastFMTrack] {
        struct Response: Decodable {
            struct Container: Decodable { let track: FlexibleArray<Track> }
            struct Track: Decodable { let name: String; let artist: ArtistName }
            let tracks: Container
        }
        let response: Response = try await call("tag.gettoptracks", ["tag": tag, "limit": String(limit)])
        let tracks = response.tracks.track.values
        return tracks.enumerated().map { index, track in
            LastFMTrack(name: track.name, artist: track.artist.name, match: Self.rankWeight(index, of: tracks.count))
        }
    }

    private static func rankWeight(_ index: Int, of count: Int) -> Double {
        guard count > 1 else { return 1 }
        return 1 - 0.7 * Double(index) / Double(count - 1)
    }

    // MARK: Transport

    private struct ArtistName: Decodable { let name: String }
    private struct ErrorBody: Decodable { let error: Int; let message: String }

    private func call<T: Decodable>(_ method: String, _ params: [String: String], retriesLeft: Int = 2) async throws -> T {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "format", value: "json"),
        ] + params.map { URLQueryItem(name: $0.key, value: $0.value) }

        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // Last.fm reports errors as {"error": n, "message": "..."}, sometimes with HTTP 200.
        if let error = try? JSONDecoder().decode(ErrorBody.self, from: data) {
            // 29 = rate limit exceeded, 8/16 = temporary backend errors
            if [8, 16, 29].contains(error.error), retriesLeft > 0 {
                try await Task.sleep(for: .seconds(1))
                return try await call(method, params, retriesLeft: retriesLeft - 1)
            }
            throw LastFMError.api(error.error, error.message)
        }
        guard (200..<300).contains(status) else { throw LastFMError.http(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Caching

/// Wraps a provider with an in-memory cache. Artist tags and charts barely change within a
/// session, and many genres share the same artists, so this saves a lot of rate-limited calls.
final class CachedLastFM: LastFMProviding, @unchecked Sendable {
    private let base: LastFMProviding
    private let cache = ResponseCache()

    init(_ base: LastFMProviding) {
        self.base = base
    }

    func similarArtists(to artist: String, limit: Int) async throws -> [LastFMSimilarArtist] {
        try await cache.value(for: "sa|\(artist.lowercased())|\(limit)") { try await self.base.similarArtists(to: artist, limit: limit) }
    }

    func similarTracks(to track: String, artist: String, limit: Int) async throws -> [LastFMTrack] {
        try await cache.value(for: "st|\(MatchKey.track(title: track, artist: artist))|\(limit)") {
            try await self.base.similarTracks(to: track, artist: artist, limit: limit)
        }
    }

    func topTracks(for artist: String, limit: Int) async throws -> [LastFMTrack] {
        try await cache.value(for: "tt|\(artist.lowercased())|\(limit)") { try await self.base.topTracks(for: artist, limit: limit) }
    }

    func topTags(for artist: String) async throws -> [LastFMTag] {
        try await cache.value(for: "tg|\(artist.lowercased())") { try await self.base.topTags(for: artist) }
    }

    func tagInfo(_ tag: String) async throws -> LastFMTagInfo {
        try await cache.value(for: "ti|\(tag)") { try await self.base.tagInfo(tag) }
    }

    func tagTopArtists(_ tag: String, limit: Int) async throws -> [LastFMRankedArtist] {
        try await cache.value(for: "ta|\(tag)|\(limit)") { try await self.base.tagTopArtists(tag, limit: limit) }
    }

    func tagTopTracks(_ tag: String, limit: Int) async throws -> [LastFMTrack] {
        try await cache.value(for: "tr|\(tag)|\(limit)") { try await self.base.tagTopTracks(tag, limit: limit) }
    }
}

private actor ResponseCache {
    private var storage: [String: Any] = [:]

    func value<T>(for key: String, fetch: @Sendable () async throws -> T) async throws -> T {
        if let cached = storage[key] as? T { return cached }
        let fresh = try await fetch()
        storage[key] = fresh
        return fresh
    }
}

// MARK: - Last.fm JSON quirks

/// Last.fm returns a bare object instead of an array when there's exactly one result,
/// and an empty string or missing key when there are none.
struct FlexibleArray<Element: Decodable>: Decodable {
    let values: [Element]

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let array = try? container.decode([Element].self) {
            values = array
        } else if let single = try? container.decode(Element.self) {
            values = [single]
        } else {
            values = []
        }
    }
}

extension KeyedDecodingContainer {
    /// Treat a missing key as an empty list, so synthesized decoders don't fail on empty results.
    func decode<T>(_ type: FlexibleArray<T>.Type, forKey key: Key) throws -> FlexibleArray<T> {
        try decodeIfPresent(type, forKey: key) ?? FlexibleArray(values: [])
    }
}

extension FlexibleArray {
    init(values: [Element]) { self.values = values }
}

/// Numbers sometimes arrive as JSON strings ("0.83") and sometimes as numbers (0.83).
struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self) {
            value = Double(string) ?? 0
        } else {
            value = 0
        }
    }
}
