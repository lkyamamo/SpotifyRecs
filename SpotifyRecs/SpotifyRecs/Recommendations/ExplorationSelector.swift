//
//  ExplorationSelector.swift
//  SpotifyRecs
//
//  Most of each batch is the model's best guesses ("exploit"); a share is deliberately less
//  certain picks ("explore") so the model learns about parts of the genre it hasn't seen.
//

import Foundation

struct ExplorationSelector {
    var batchSize = 20
    var explorationShare = 0.2
    var maxPerArtist = 2
    /// How far down the ranking exploration picks may come from.
    var explorePoolSize = 60

    var exploreCount: Int { Int((Double(batchSize) * explorationShare).rounded()) }
    var exploitCount: Int { batchSize - exploreCount }

    struct Scored {
        let candidate: GenreCandidate
        let probability: Double
    }

    /// Returns two ordered shortlists, each longer than needed so that songs which fail to
    /// match on Spotify can be skipped.
    func shortlists<R: RandomNumberGenerator>(
        _ scored: [Scored],
        observedTags: Set<String>,
        using rng: inout R
    ) -> (exploit: [Scored], explore: [Scored]) {
        let ranked = diversify(scored.sorted { $0.probability > $1.probability }, cap: maxPerArtist)
        let exploitLength = min(ranked.count, Int(Double(exploitCount) * 1.6))
        let exploit = Array(ranked.prefix(exploitLength))

        // Sample from the rest, favoring songs the model is unsure about or whose tags it has never seen.
        var pool = Array(ranked.dropFirst(exploitLength).prefix(explorePoolSize))
        var explore: [Scored] = []
        while explore.count < exploreCount * 2, !pool.isEmpty {
            let weights = pool.map { item in
                (0.2 + item.probability) * (1 + novelty(item.candidate, observedTags: observedTags))
            }
            let index = weightedIndex(weights, using: &rng)
            explore.append(pool.remove(at: index))
        }
        return (exploit, explore)
    }

    /// Fraction of the candidate's tags that never appeared in any rated song.
    func novelty(_ candidate: GenreCandidate, observedTags: Set<String>) -> Double {
        let tags = candidate.features.keys.compactMap(Feature.tagName)
        guard !tags.isEmpty else { return 1 }
        return Double(tags.filter { !observedTags.contains($0) }.count) / Double(tags.count)
    }

    func diversify(_ sorted: [Scored], cap: Int) -> [Scored] {
        var perArtist: [String: Int] = [:]
        return sorted.filter { item in
            let key = MatchKey.artist(item.candidate.artist)
            perArtist[key, default: 0] += 1
            return perArtist[key]! <= cap
        }
    }

    private func weightedIndex<R: RandomNumberGenerator>(_ weights: [Double], using rng: inout R) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return Int.random(in: 0..<weights.count, using: &rng) }
        var threshold = Double.random(in: 0..<total, using: &rng)
        for (index, weight) in weights.enumerated() {
            threshold -= weight
            if threshold < 0 { return index }
        }
        return weights.count - 1
    }
}
