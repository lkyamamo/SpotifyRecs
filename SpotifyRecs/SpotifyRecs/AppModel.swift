//
//  AppModel.swift
//  SpotifyRecs
//
//  Shared services and the session's taste context (loaded once, reused by every genre).
//

import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let auth: SpotifyAuth
    @ObservationIgnored let spotify: SpotifyAPI
    @ObservationIgnored let lastFM: LastFMProviding
    /// One limiter for all Last.fm traffic (~5 requests/second).
    @ObservationIgnored let lastFMLimiter = RateLimiter(minimumInterval: .milliseconds(200))

    private(set) var tasteContext: TasteContext?
    @ObservationIgnored private var contextTask: Task<TasteContext, Error>?

    init(auth: SpotifyAuth) {
        self.auth = auth
        spotify = SpotifyAPI { try await auth.validAccessToken() }
        lastFM = CachedLastFM(LastFMAPI(apiKey: AppConfig.lastFMAPIKey))
    }

    var suggestedGenres: [String] { tasteContext?.suggestedGenres() ?? [] }

    /// Returns the cached taste context, loading it if needed. Concurrent callers share one load.
    func loadTasteContext(
        forceRefresh: Bool = false,
        progress: @escaping @Sendable (RecommendationStage) async -> Void = { _ in }
    ) async throws -> TasteContext {
        if forceRefresh {
            tasteContext = nil
            contextTask = nil
        }
        if let tasteContext { return tasteContext }
        if let contextTask { return try await contextTask.value }

        let loader = TasteContextLoader(spotify: spotify, lastFM: lastFM, limiter: lastFMLimiter)
        let task = Task { try await loader.load(progress: progress) }
        contextTask = task
        do {
            let context = try await task.value
            tasteContext = context
            contextTask = nil
            return context
        } catch {
            contextTask = nil
            throw error
        }
    }

    func recommender() -> GenreRecommender {
        GenreRecommender(spotify: spotify, lastFM: lastFM, limiter: lastFMLimiter)
    }

    func resolveGenre(_ input: String) async throws -> String {
        try await GenreResolver(lastFM: lastFM).resolve(input)
    }

    func signOut() {
        tasteContext = nil
        contextTask = nil
        auth.signOut()
    }
}
