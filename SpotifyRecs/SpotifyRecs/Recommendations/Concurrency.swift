//
//  Concurrency.swift
//  SpotifyRecs
//

import Foundation

/// Maps over `items` with at most `limit` tasks in flight, preserving input order.
func concurrentMap<T: Sendable, R: Sendable>(
    _ items: [T],
    limit: Int,
    _ transform: @escaping @Sendable (T) async throws -> R
) async throws -> [R] {
    try await withThrowingTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0..<min(limit, items.count) {
            let index = next
            group.addTask { (index, try await transform(items[index])) }
            next += 1
        }
        while let (index, result) = try await group.next() {
            results[index] = result
            if next < items.count {
                let index = next
                group.addTask { (index, try await transform(items[index])) }
                next += 1
            }
        }
        return results.compactMap { $0 }
    }
}

/// Spaces out request starts to respect an API's rate limit.
actor RateLimiter {
    private let minimumInterval: Duration
    private var nextSlot = ContinuousClock.now

    init(minimumInterval: Duration) {
        self.minimumInterval = minimumInterval
    }

    func wait() async {
        let now = ContinuousClock.now
        let slot = max(now, nextSlot)
        nextSlot = slot + minimumInterval
        if slot > now { try? await Task.sleep(until: slot, clock: .continuous) }
    }
}
