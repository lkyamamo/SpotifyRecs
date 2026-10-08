//
//  PreferenceModel.swift
//  SpotifyRecs
//
//  Stage 1 learning: a logistic-regression model over hand-built features, trained on the
//  user's thumbs up/down. Each genre gets its own model whose prior is a global model
//  trained on all feedback, so a few ratings nudge the defaults rather than replace them.
//

import Foundation

typealias FeatureVector = [String: Double]

enum Feature {
    static let bias = "bias"
    /// Last.fm similar-artist graph: how strongly the user's top artists point at this artist.
    static let artistSimilarity = "artist_similarity"
    /// Cosine overlap between the artist's tags and the user's tag profile.
    static let tagAffinity = "tag_affinity"
    /// How strongly the artist is tagged with the requested genre.
    static let genreStrength = "genre_strength"
    /// Position in the genre's Last.fm charts.
    static let genreRank = "genre_rank"
    /// Last.fm similar-track graph from the user's top tracks.
    static let trackSimilarity = "track_similarity"
    /// 1 when the user already listens to this artist.
    static let knownArtist = "known_artist"

    static let tagPrefix = "tag:"

    static func tag(_ name: String) -> String { tagPrefix + name }

    static func tagName(_ key: String) -> String? {
        key.hasPrefix(tagPrefix) ? String(key.dropFirst(tagPrefix.count)) : nil
    }

    /// Plain-language description of what a positive weight change on this feature means.
    static func learnedDescription(_ key: String, positive: Bool) -> String? {
        switch key {
        case artistSimilarity: positive ? "Sticks close to artists you already love" : "Ventures further from your usual artists"
        case tagAffinity: positive ? "Matches your overall style closely" : "Less tied to your overall style"
        case genreStrength: positive ? "Prefers core examples of the genre" : "Open to genre-adjacent picks"
        case genreRank: positive ? "Leans toward the genre’s biggest songs" : "Leans toward lesser-known songs"
        case trackSimilarity: positive ? "Favors songs like your top tracks" : "Less weight on your top tracks"
        case knownArtist: positive ? "Likes deeper cuts from artists you know" : "Prefers brand-new artists"
        default: nil
        }
    }
}

struct PreferenceModel: Codable, Equatable {
    var weights: [String: Double]

    /// Hand-tuned starting point used before any feedback exists.
    static let `default` = PreferenceModel(weights: [
        Feature.bias: -1.5,
        Feature.artistSimilarity: 2.5,
        Feature.tagAffinity: 1.5,
        Feature.genreStrength: 1.5,
        Feature.genreRank: 1.0,
        Feature.trackSimilarity: 2.0,
        Feature.knownArtist: -0.3,
    ])

    func logit(_ features: FeatureVector) -> Double {
        features.reduce(0) { $0 + (weights[$1.key] ?? 0) * $1.value }
    }

    func probability(_ features: FeatureVector) -> Double {
        1 / (1 + exp(-logit(features)))
    }

    // MARK: Training

    struct Example {
        let features: FeatureVector
        let liked: Bool
    }

    struct TrainingConfig {
        var learningRate = 0.05
        var epochs = 30
        /// Pull toward the prior; higher = more conservative.
        var regularization = 0.05
    }

    /// Stochastic gradient descent on log-loss, starting from and regularized toward `prior`.
    /// Classes are re-weighted so a run of dislikes doesn't just drag every score down.
    static func train(_ examples: [Example], prior: PreferenceModel, config: TrainingConfig = .init()) -> PreferenceModel {
        guard !examples.isEmpty else { return prior }
        let positives = Double(examples.filter(\.liked).count)
        let negatives = Double(examples.count) - positives
        let total = Double(examples.count)
        let positiveWeight = positives > 0 ? total / (2 * positives) : 1
        let negativeWeight = negatives > 0 ? total / (2 * negatives) : 1

        var model = prior
        for _ in 0..<config.epochs {
            for example in examples {
                let error = (example.liked ? 1 : 0) - model.probability(example.features)
                let classWeight = example.liked ? positiveWeight : negativeWeight
                for (key, value) in example.features {
                    let current = model.weights[key] ?? 0
                    let pull = config.regularization * (current - (prior.weights[key] ?? 0))
                    model.weights[key] = current + config.learningRate * (classWeight * error * value - pull)
                }
            }
        }
        return model
    }

    // MARK: Explanations

    /// How much each feature's learned weight change moves this track's score, largest first.
    func learnedContributions(_ features: FeatureVector, relativeTo reference: PreferenceModel) -> [(key: String, delta: Double)] {
        features
            .map { key, value in (key, ((weights[key] ?? 0) - (reference.weights[key] ?? 0)) * value) }
            .filter { $0.0 != Feature.bias }
            .sorted { abs($0.1) > abs($1.1) }
    }

    /// Tags whose weights moved most from the reference, as (tag, change).
    func learnedTags(relativeTo reference: PreferenceModel, limit: Int = 5) -> (liked: [String], disliked: [String]) {
        let deltas = weights.compactMap { key, weight -> (String, Double)? in
            guard let tag = Feature.tagName(key) else { return nil }
            return (tag, weight - (reference.weights[key] ?? 0))
        }
        return (
            deltas.filter { $0.1 > 0.1 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0),
            deltas.filter { $0.1 < -0.1 }.sorted { $0.1 < $1.1 }.prefix(limit).map(\.0)
        )
    }

    /// Non-tag features whose weights moved notably, described in plain language.
    func learnedHabits(relativeTo reference: PreferenceModel, threshold: Double = 0.25) -> [String] {
        weights.compactMap { key, weight -> (String, Double)? in
            guard Feature.tagName(key) == nil, key != Feature.bias else { return nil }
            let delta = weight - (reference.weights[key] ?? 0)
            return abs(delta) >= threshold ? (key, delta) : nil
        }
        .sorted { abs($0.1) > abs($1.1) }
        .compactMap { Feature.learnedDescription($0.0, positive: $0.1 > 0) }
    }
}
