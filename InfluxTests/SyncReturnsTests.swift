// Coming back to the Mac app: when it waits for the synced place behind the
// "Syncing in Progress" screen (influx-dev #109).
#if os(macOS)
import AppKit
import Testing
@testable import Influx

@MainActor
@Suite struct SyncReturnsTests {
    private final class Harness {
        let app = NotificationCenter()
        let workspace = NotificationCenter()
        let distributed = NotificationCenter()
        var isActive = true
        var now = ContinuousClock.now
        var returns: [(away: Duration, waitingForNetwork: Bool)] = []
        var leavings = 0
    }

    private func watching() -> (SyncReturns, Harness) {
        let h = Harness()
        let returns = SyncReturns(appCenter: h.app, workspaceCenter: h.workspace, distributedCenter: h.distributed,
                                  isActive: { h.isActive }, now: { h.now }, wentAway: { h.leavings += 1 }) { away, waiting in
            h.returns.append((away, waiting))
        }
        returns.start()
        return (returns, h)
    }

    @Test func switchingBackSaysHowLongItWasAway() {
        let (watcher, h) = watching()
        h.app.post(name: NSApplication.didResignActiveNotification, object: nil)
        h.now = h.now.advanced(by: .seconds(45))
        h.app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(h.returns.count == 1)
        #expect(h.returns.first?.away == .seconds(45))
        #expect(h.returns.first?.waitingForNetwork == false)
        // Becoming active at launch, never having been away, is no time away.
        h.app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #expect(h.returns.last?.away == .zero)
        _ = watcher
    }

    @Test func wakingInFrontShowsTheScreenAndWaitsForTheNetwork() {
        let (watcher, h) = watching()
        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        h.workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil)
        h.distributed.post(name: SyncReturns.screenUnlocked, object: nil)
        #expect(h.returns.count == 3)
        #expect(h.returns.allSatisfy { $0.away == SyncReturns.always && $0.waitingForNetwork })
        _ = watcher
    }

    /// The place is saved and sent as the reader leaves, not after the
    /// pause that follows a scroll (influx-dev #125).
    @Test func switchingAwayAndSleepingSayTheReaderLeft() {
        let (watcher, h) = watching()
        h.app.post(name: NSApplication.didResignActiveNotification, object: nil)
        #expect(h.leavings == 1)
        h.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(h.leavings == 2)
        // Coming back isn't leaving.
        h.app.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(h.leavings == 2)
        _ = watcher
    }

    /// In the background, switching back to Influx says instead.
    @Test func wakingBehindAnotherAppWaitsForTheSwitchBack() {
        let (watcher, h) = watching()
        h.isActive = false
        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(h.returns.isEmpty)
        _ = watcher
    }

    @Test func reopeningTheWindowShowsTheScreenButLaunchingDoesntAgain() {
        let (watcher, h) = watching()
        watcher.windowOpened()
        #expect(h.returns.isEmpty)
        watcher.windowOpened()
        #expect(h.returns.count == 1)
        #expect(h.returns.first?.away == SyncReturns.always)
    }

    @Test func startingTwiceWatchesOnce() {
        let (watcher, h) = watching()
        watcher.start()
        h.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(h.returns.count == 1)
    }

    /// The gate takes "always" as long enough to show.
    @Test func alwaysIsLongerThanAnyWait() {
        let gate = SyncingGate(settle: .zero, defaults: nil)
        gate.cameBack(after: SyncReturns.always)
        #expect(gate.isShowing)
        gate.syncFinished(.synced)
    }
}
#endif
