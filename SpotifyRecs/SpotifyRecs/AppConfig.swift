//
//  AppConfig.swift
//  SpotifyRecs
//

import Foundation

/// Values injected at build time from `Config.xcconfig` / `Secrets.xcconfig` via Info.plist.
enum AppConfig {
    static let spotifyClientID = infoValue("SpotifyClientID")
    static let lastFMAPIKey = infoValue("LastFMAPIKey")

    /// Must exactly match a Redirect URI registered in the Spotify developer dashboard.
    static let spotifyRedirectScheme = "spotifyrecs"
    static let spotifyRedirectURI = "\(spotifyRedirectScheme)://callback"

    static let spotifyScopes = [
        "user-top-read",
        "user-read-recently-played",
        "user-library-read",
        "playlist-modify-private",
    ]

    static var missingKeys: [String] {
        var missing: [String] = []
        if spotifyClientID.isEmpty { missing.append("SPOTIFY_CLIENT_ID") }
        if lastFMAPIKey.isEmpty { missing.append("LASTFM_API_KEY") }
        return missing
    }

    private static func infoValue(_ key: String) -> String {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String ?? ""
        // An unset xcconfig variable leaves the literal "$(VAR)" behind in some setups.
        return value.hasPrefix("$(") ? "" : value.trimmingCharacters(in: .whitespaces)
    }
}
