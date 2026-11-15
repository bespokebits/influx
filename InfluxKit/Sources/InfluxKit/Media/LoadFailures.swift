import Foundation

/// Image loads that failed, and when each may be tried again. A failure is
/// usually passing (a timeout, a dropped connection, a Mac just woken from
/// sleep), so a failed image is tried again after a wait that doubles each
/// time, up to `longestWait`, rather than given up on for the session.
public struct LoadFailures: Sendable {
    /// The wait after the first failure.
    public static let firstWait: Duration = .seconds(5)
    /// The wait never grows past this, so an image that comes back is shown
    /// within a few minutes.
    public static let longestWait: Duration = .seconds(300)

    private struct Failure: Sendable {
        var count: Int
        var retryAt: ContinuousClock.Instant
    }

    private var failures: [String: Failure] = [:]

    public init() {}

    /// Whether the last load of `key` failed.
    public func contains(_ key: String) -> Bool {
        failures[key] != nil
    }

    /// How long until `key` may be loaded again: zero once its wait is
    /// over, nil when it hasn't failed.
    public func wait(for key: String, now: ContinuousClock.Instant) -> Duration? {
        guard let failure = failures[key] else { return nil }
        return max(.zero, failure.retryAt - now)
    }

    /// Notes a failed load of `key`, which doubles its wait.
    public mutating func record(_ key: String, now: ContinuousClock.Instant) {
        let count = (failures[key]?.count ?? 0) + 1
        failures[key] = Failure(count: count, retryAt: now + Self.waitAfter(count))
    }

    /// Forgets `key`'s failures, after a load of it worked.
    public mutating func clear(_ key: String) {
        failures[key] = nil
    }

    /// The wait after `count` failures in a row.
    static func waitAfter(_ count: Int) -> Duration {
        let doublings = min(max(count - 1, 0), 16)
        return min(firstWait * (1 << doublings), longestWait)
    }
}
