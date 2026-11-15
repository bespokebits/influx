// Whether the Mac app's windows can be seen, for how often sources are
// fetched (ADR 0036).
#if os(macOS)
import AppKit
import Testing
@testable import Influx

@MainActor
@Suite struct ScreenPresenceTests {
    private final class Harness {
        let center = NotificationCenter()
        var visible = true
        var said: [Bool] = []
    }

    private func watching() -> (ScreenPresence, Harness) {
        let h = Harness()
        let presence = ScreenPresence(center: h.center, isOnScreen: { h.visible }) { h.said.append($0) }
        presence.start()
        return (presence, h)
    }

    @Test func startingSaysWhatItIsNow() {
        let (presence, h) = watching()
        #expect(h.said == [true])
        presence.start()
        #expect(h.said == [true])
    }

    @Test func aWindowCoveredOrMinimisedGoesOffScreenAndBack() {
        let (presence, h) = watching()
        h.visible = false
        h.center.post(name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        h.visible = true
        h.center.post(name: NSWindow.didDeminiaturizeNotification, object: nil)
        #expect(h.said == [true, false, true])
        _ = presence
    }

    @Test func onlyAChangeIsSaid() {
        let (presence, h) = watching()
        for name in ScreenPresence.changes {
            h.center.post(name: name, object: nil)
        }
        #expect(h.said == [true])
        _ = presence
    }

    @Test func aClosingWindowIsLookedAtAgainOnTheNextTurn() async {
        let (presence, h) = watching()
        // Still visible while it says it will close.
        h.center.post(name: NSWindow.willCloseNotification, object: nil)
        h.visible = false
        for _ in 0..<10 { await Task.yield() }
        #expect(h.said == [true, false])
        _ = presence
    }
}
#endif
