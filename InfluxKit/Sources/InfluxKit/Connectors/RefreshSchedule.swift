import Foundation

/// When each source is next fetched, from how its last fetch went and the
/// cadence it has now (`RefreshCadence`, ADR 0036). It only keeps time:
/// the app's loop asks it which sources are due, fetches them through
/// `Refresher`, and tells it each outcome.
///
/// - A source is due once its interval, jittered, has passed since its
///   last fetch. The interval is looked up when asked, so coming on screen
///   makes every source that is older than its on-screen interval due at
///   once, and going off screen stretches the rest.
/// - A failure backs off: the interval doubles with each failure in a
///   row, up to `RefreshCadence.longestBackoff`. A success ends it.
/// - A rate limit waits until the service's `Retry-After`, or the store's
///   pause when it gave none.
/// - A source being fetched is never due, so two fetches of it never
///   overlap here (and `Refresher` refuses a second one anyway).
///
/// A source never fetched is due at once.
public struct RefreshSchedule: Sendable {
    struct Entry: Sendable, Hashable {
        var fetchedAt: Date
        var failures: Int
        /// No fetch before this: a rate limit.
        var notBefore: Date?
        /// This wait's jitter, as a factor of the interval.
        var jitter: Double
    }

    private var entries: [String: Entry] = [:]
    private var fetching: Set<String> = []
    private let jitter: @Sendable () -> Double

    /// `jitter` gives each wait's factor of the interval; by default a
    /// random one within ±`RefreshCadence.jitter`. Tests fix it.
    public init(jitter: @escaping @Sendable () -> Double = RefreshSchedule.randomJitter) {
        self.jitter = jitter
    }

    @Sendable public static func randomJitter() -> Double {
        Double.random(in: (1 - RefreshCadence.jitter)...(1 + RefreshCadence.jitter))
    }

    /// When `id` is next due with this interval; nil when it has never been
    /// fetched, so it is due now. A source being fetched has no due date.
    public func dueAt(_ id: String, interval: TimeInterval) -> Date? {
        guard let entry = entries[id] else { return nil }
        let wait = RefreshCadence.wait(interval: interval, failures: entry.failures) * entry.jitter
        let due = entry.fetchedAt.addingTimeInterval(wait)
        return max(due, entry.notBefore ?? due)
    }

    /// Whether `id` should be fetched at `now`: it is not being fetched,
    /// and it is due by then or within `lead`, which lets a fetch take
    /// along a source that would wake the loop again a moment later.
    public func isDue(_ id: String, interval: TimeInterval, at now: Date, lead: TimeInterval = 0) -> Bool {
        guard !fetching.contains(id) else { return false }
        guard let due = dueAt(id, interval: interval) else { return true }
        return due <= now.addingTimeInterval(lead)
    }

    /// The sources due at `now`, with the cadence for `onScreen`, now
    /// marked as being fetched. Each must be ended with `finish`.
    /// `streaming` names the sources whose stream is live.
    public mutating func begin(_ sources: [Source], onScreen: Bool, streaming: Set<String> = [], at now: Date, lead: TimeInterval = 0) -> [Source] {
        let intervals = RefreshCadence.intervals(for: sources, onScreen: onScreen, streaming: streaming)
        let due = sources.filter { isDue($0.id, interval: intervals[$0.id] ?? RefreshCadence.slow, at: now, lead: lead) }
        fetching.formUnion(due.map(\.id))
        return due
    }

    /// The earliest time one of `sources` is due, or nil when every one of
    /// them is being fetched (or there are none).
    public func nextDue(_ sources: [Source], onScreen: Bool, streaming: Set<String> = [], after now: Date) -> Date? {
        let intervals = RefreshCadence.intervals(for: sources, onScreen: onScreen, streaming: streaming)
        return sources.filter { !fetching.contains($0.id) }
            .map { dueAt($0.id, interval: intervals[$0.id] ?? RefreshCadence.slow) ?? now }
            .min()
    }

    /// Records how fetching `id` went at `now`, whether it was begun here
    /// or fetched by another pass (a Refresh, signing in).
    public mutating func finish(_ id: String, _ outcome: Refresher.Outcome, at now: Date) {
        fetching.remove(id)
        var entry = entries[id] ?? Entry(fetchedAt: now, failures: 0, jitter: 1)
        entry.jitter = jitter()
        switch outcome {
        case .fetched, .reachedOldest:
            entry.fetchedAt = now
            entry.failures = 0
            entry.notBefore = nil
        case .failed(let error):
            entry.fetchedAt = now
            entry.failures += 1
            if case .rateLimited(let until) = error {
                entry.notBefore = until ?? now.addingTimeInterval(SourceFetchState.defaultRateLimitPause)
            } else {
                entry.notBefore = nil
            }
        case .waiting(let until):
            // Asked nothing; the service's pause stands.
            entry.notBefore = until
        case .alreadyRefreshing, .cancelled:
            // Another fetch has it, or this one stopped: wait an interval
            // rather than asking again straight away.
            entry.fetchedAt = now
        }
        entries[id] = entry
    }

    /// Records each of `outcomes`, by source ID.
    public mutating func finish(_ outcomes: [String: Refresher.Outcome], at now: Date) {
        for (id, outcome) in outcomes {
            finish(id, outcome, at: now)
        }
    }

    /// Ends `ids`' fetches that never reported, such as a pass that threw.
    public mutating func abandon(_ ids: some Sequence<String>) {
        fetching.subtract(ids)
    }

    /// Forgets every source not in `ids`: removed, or signed out.
    public mutating func keep(only ids: Set<String>) {
        entries = entries.filter { ids.contains($0.key) }
        fetching.formIntersection(ids)
    }

    /// How many failures in a row `id` has had, for tests and diagnostics.
    public func failures(of id: String) -> Int {
        entries[id]?.failures ?? 0
    }

    /// Whether `id` is being fetched.
    public func isFetching(_ id: String) -> Bool {
        fetching.contains(id)
    }
}
