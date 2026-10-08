//
//  SpotifyAuth.swift
//  SpotifyRecs
//

import AuthenticationServices
import Foundation
import Observation
import UIKit

struct SpotifyToken: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

enum SpotifyAuthError: LocalizedError {
    case missingClientID
    case cancelled
    case stateMismatch
    case noAuthorizationCode(String?)
    case tokenRequestFailed(Int, String)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .missingClientID: "SPOTIFY_CLIENT_ID is not set. See Secrets.example.xcconfig."
        case .cancelled: "Sign-in was cancelled."
        case .stateMismatch: "Sign-in response did not match the request. Please try again."
        case .noAuthorizationCode(let error): "Spotify did not return an authorization code (\(error ?? "unknown error"))."
        case .tokenRequestFailed(let status, let body): "Token request failed (\(status)): \(body)"
        case .notSignedIn: "You are not signed in to Spotify."
        }
    }
}

/// Spotify Authorization Code + PKCE flow. No client secret is ever stored in the app.
@MainActor
@Observable
final class SpotifyAuth: NSObject {
    private(set) var isSignedIn = false

    @ObservationIgnored private var token: SpotifyToken?
    @ObservationIgnored private var refreshTask: Task<SpotifyToken, Error>?
    @ObservationIgnored private let keychain = KeychainStore(service: "lky.SpotifyRecs")
    @ObservationIgnored private let urlSession: URLSession

    private static let tokenAccount = "spotify-token"
    private nonisolated static let tokenURL = URL(string: "https://accounts.spotify.com/api/token")!

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        super.init()
        token = keychain.load(SpotifyToken.self, for: Self.tokenAccount)
        isSignedIn = token != nil
    }

    func signIn() async throws {
        guard !AppConfig.spotifyClientID.isEmpty else { throw SpotifyAuthError.missingClientID }

        let verifier = PKCE.makeCodeVerifier()
        let state = PKCE.makeState()

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: AppConfig.spotifyClientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: AppConfig.spotifyRedirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.codeChallenge(for: verifier)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: AppConfig.spotifyScopes.joined(separator: " ")),
        ]

        let callbackURL = try await presentAuthSession(url: components.url!)
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == state else {
            throw SpotifyAuthError.stateMismatch
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyAuthError.noAuthorizationCode(items.first(where: { $0.name == "error" })?.value)
        }

        let newToken = try await requestToken(params: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": AppConfig.spotifyRedirectURI,
            "client_id": AppConfig.spotifyClientID,
            "code_verifier": verifier,
        ], previousRefreshToken: nil)
        store(newToken)
    }

    func signOut() {
        refreshTask?.cancel()
        refreshTask = nil
        token = nil
        keychain.delete(Self.tokenAccount)
        isSignedIn = false
    }

    /// Returns a valid access token, refreshing it if needed. Concurrent callers share one refresh.
    func validAccessToken() async throws -> String {
        guard let current = token else { throw SpotifyAuthError.notSignedIn }
        if !current.isExpired { return current.accessToken }

        if let refreshTask { return try await refreshTask.value.accessToken }

        let task = Task { [urlSession] in
            try await Self.performRequest(urlSession: urlSession, params: [
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": AppConfig.spotifyClientID,
            ], previousRefreshToken: current.refreshToken)
        }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let refreshed = try await task.value
            store(refreshed)
            return refreshed.accessToken
        } catch SpotifyAuthError.tokenRequestFailed(let status, let body) where status == 400 || status == 401 {
            // Refresh token revoked or expired — force a fresh sign-in.
            signOut()
            throw SpotifyAuthError.tokenRequestFailed(status, body)
        }
    }

    private func store(_ newToken: SpotifyToken) {
        token = newToken
        try? keychain.save(newToken, for: Self.tokenAccount)
        isSignedIn = true
    }

    private func requestToken(params: [String: String], previousRefreshToken: String?) async throws -> SpotifyToken {
        try await Self.performRequest(urlSession: urlSession, params: params, previousRefreshToken: previousRefreshToken)
    }

    private nonisolated static func performRequest(
        urlSession: URLSession,
        params: [String: String],
        previousRefreshToken: String?
    ) async throws -> SpotifyToken {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SpotifyAuthError.tokenRequestFailed(status, String(decoding: data, as: UTF8.self))
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        // Spotify may omit refresh_token on refresh; keep the previous one in that case.
        guard let refresh = decoded.refresh_token ?? previousRefreshToken else {
            throw SpotifyAuthError.tokenRequestFailed(status, "Missing refresh token")
        }
        return SpotifyToken(
            accessToken: decoded.access_token,
            refreshToken: refresh,
            expiresAt: Date().addingTimeInterval(decoded.expires_in)
        )
    }

    private func presentAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: AppConfig.spotifyRedirectScheme
            ) { callbackURL, error in
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                } else if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(throwing: SpotifyAuthError.cancelled)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}

extension SpotifyAuth: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
        }
    }
}
