import Foundation
import InfluxKit

/// The waiting side of fetching (ADR 0036), for `Feeds` and `Accounts`:
/// keeps their `RefreshSchedule`, knows whether the app is on screen, and
/// sleeps until the next source is due or something wakes it (coming on
/// screen, a new source). The cadence itself is InfluxKit's
/// `RefreshCadence`; the fetching stays with the owner.
@MainActor
final class RefreshTimer {
    /// Sources due within this of the one that woke the loop go with it,
    /// so the loop doesn't wake again a moment later for each.
    static let lead: TimeInterval = 5
    /// The shortest sleep, so nothing can make the loop spin.
    static let shortestSleep: TimeInterval = 1
    /// The longest, with nothing due: no sources yet.
    static let longestSleep: TimeInterval = 60 * 60

    private(set) var onScreen = false
    /// Sources whose stream is live, which poll only as a safety net.
    private(set) var streaming: Set<String> = []
    private var schedule = RefreshSchedule()
    private var sleeper: Task<Void, Never>?

    /// Says whether the reader can see the app. Coming on screen wakes the
    /// loop, which then fetches every source older than its on-screen
    /// interval; going off screen only stretches the next wait.
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != self.onScreen else { return }
        self.onScreen = onScreen
        if onScreen { wake() }
    }

    /// Says whether `id`'s stream is live. When it drops, the source polls
    /// at its own interval again, so the loop wakes to look.
    func setStreaming(_ id: String, _ live: Bool) {
        guard live != streaming.contains(id) else { return }
        if live {
            streaming.insert(id)
        } else {
            streaming.remove(id)
            wake()
        }
    }

    /// Ends the current sleep now.
    func wake() {
        sleeper?.cancel()
    }

    /// Sleeps until one of `sources` is due, `also` comes, or `wake()`.
    func sleep(until sources: [Source], or also: Date? = nil) async {
        let now = Date()
        let next = [schedule.nextDue(sources, onScreen: onScreen, streaming: streaming, after: now), also].compactMap(\.self).min()
        let wait = min(max(next.map { $0.timeIntervalSince(now) } ?? Self.longestSleep, Self.shortestSleep), Self.longestSleep)
        let sleeper = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(wait)) }
        self.sleeper = sleeper
        await withTaskCancellationHandler {
            await sleeper.value
        } onCancel: {
            sleeper.cancel()
        }
        if self.sleeper == sleeper { self.sleeper = nil }
    }

    /// The sources due now, marked as being fetched; `finish` each.
    func begin(_ sources: [Source]) -> [Source] {
        schedule.begin(sources, onScreen: onScreen, streaming: streaming, at: Date(), lead: Self.lead)
    }

    /// Records the outcomes of fetching `begun`, and ends any of them that
    /// gave none (the pass failed).
    func finish(_ outcomes: [String: Refresher.Outcome], begun: [Source]) {
        schedule.finish(outcomes, at: Date())
        schedule.abandon(begun.map(\.id))
    }

    /// Records what a pass begun elsewhere fetched: a Refresh, signing in,
    /// sources arriving by sync. A source it found already being fetched
    /// is left to that fetch.
    func record(_ outcomes: [String: Refresher.Outcome]) {
        schedule.finish(outcomes.filter { $0.value != .alreadyRefreshing }, at: Date())
    }

    /// Forgets the sources not in `ids`.
    func keep(only ids: Set<String>) {
        schedule.keep(only: ids)
        streaming.formIntersection(ids)
    }
}
