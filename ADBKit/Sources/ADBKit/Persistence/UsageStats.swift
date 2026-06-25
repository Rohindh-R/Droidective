import Foundation

/// Per-feature usage tally, persisted to `usage.json`. Used to re-rank a role's
/// curated feature order on the Home launchpad by how the user actually works,
/// so "frequently used" becomes personal over time.
///
/// `CommandLog` is session-only (an in-memory actor), so cross-launch ranking
/// needs this durable store rather than the command log.
public struct UsageStat: Codable, Sendable, Equatable {
    public var count: Int
    public var lastUsed: Date

    public init(count: Int = 0, lastUsed: Date = .distantPast) {
        self.count = count
        self.lastUsed = lastUsed
    }
}

public struct UsageStats: Codable, Sendable, Equatable {
    /// Tally keyed by feature id.
    public var byFeature: [String: UsageStat]

    public init(byFeature: [String: UsageStat] = [:]) {
        self.byFeature = byFeature
    }

    public func count(for featureID: String) -> Int { byFeature[featureID]?.count ?? 0 }

    /// Record one user-initiated use of a feature at `date`.
    public mutating func record(_ featureID: String, at date: Date) {
        var stat = byFeature[featureID] ?? UsageStat()
        stat.count += 1
        stat.lastUsed = date
        byFeature[featureID] = stat
    }

    /// Re-rank `ids` (a curated, ordered list) by real usage: most-used first,
    /// most-recent use breaks count ties, and the original curated order is the
    /// stable fallback for unused or otherwise-tied features. The comparator is
    /// a total order (curated index is the final tiebreak), so the result is
    /// deterministic regardless of `sorted`'s stability guarantees.
    public func rank(_ ids: [String]) -> [String] {
        ids.enumerated()
            .sorted { lhs, rhs in
                let a = byFeature[lhs.element]
                let b = byFeature[rhs.element]
                let countA = a?.count ?? 0
                let countB = b?.count ?? 0
                if countA != countB { return countA > countB }
                if countA > 0, let lastA = a?.lastUsed, let lastB = b?.lastUsed, lastA != lastB {
                    return lastA > lastB
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
