#if os(macOS)
import AppKit
import Testing
@testable import Influx

// A notched mouse wheel moves the Mac timeline further per notch than
// AppKit's default, and a trackpad's precise scrolls move exactly as before.
// Serialized so the timed runs never overlap.
@MainActor @Suite(.serialized)
struct WheelScrollTests {
    @Test func aWheelNotchMovesFurtherThanAppKitsDefault() async throws {
        let plain = try await moved(by: wheel(lines: -3), in: NSScrollView())
        let timeline = try await moved(by: wheel(lines: -3), in: TimelineScrollView())
        print("INFLUX-PERF wheel: 3 lines move \(plain) pt by default, \(timeline) pt in the timeline")
        #expect(timeline >= 3 * TimelineScrollView.wheelLineScroll - 1)
        #expect(timeline >= plain * 2)
    }

    @Test func aTrackpadScrollMovesTheSameAsAppKitsDefault() async throws {
        let plain = try await moved(by: pixels(-120), in: NSScrollView())
        let timeline = try await moved(by: pixels(-120), in: TimelineScrollView())
        #expect(plain > 0)
        #expect(timeline == plain)
    }

    /// Wheels through the sample timeline for a few seconds, a three-line
    /// notch at a time as a quick spin would, and prints the hitch counter.
    /// The Test configuration is a debug build, so its figure is a
    /// pessimistic bound on the real one.
    @Test func wheelScrollingTheSampleTimeline() async throws {
        let travelled = try await scrollSampleTimeline(label: "wheel scroll", every: .milliseconds(66)) { try wheel(lines: -3) }
        #expect(travelled.points >= CGFloat(travelled.events) * 3 * TimelineScrollView.wheelLineScroll * 0.9)
    }

    /// The same distance per second as the wheel run, as a trackpad sends
    /// it: a small precise step every frame or so, to tell hitches that come
    /// from the speed apart from ones the wheel's bigger steps add.
    @Test func trackpadScrollingTheSampleTimelineAtTheSameSpeed() async throws {
        let travelled = try await scrollSampleTimeline(label: "trackpad scroll", every: .milliseconds(8)) { try pixels(-15) }
        #expect(travelled.points > 0)
    }

    // MARK: -

    /// Sends `event` every `interval` for 8 s through the sample timeline
    /// and prints the hitch counter as a INFLUX-PERF line.
    private func scrollSampleTimeline(label: String, every interval: Duration,
                                      event: () throws -> NSEvent) async throws -> (events: Int, points: CGFloat) {
        UserDefaults.standard.register(defaults: ["InfluxShowScrollDiagnostics": true])
        defer { UserDefaults.standard.register(defaults: ["InfluxShowScrollDiagnostics": false]) }
        let controller = TimelineViewController(app: .sample(count: 2_000), viewID: "all",
                                                jumps: TimelineJumps(), items: TimelineItems())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer {
            controller.tearDown()
            window.close()
        }
        let scrollView = controller.scrollView
        try await wait("the sample timeline to load") {
            (scrollView.documentView?.frame.height ?? 0) > scrollView.contentSize.height * 50
        }
        controller.setViewportTop(0, animated: false)
        try await Task.sleep(for: .seconds(1))
        // Only the scrolling frames count.
        controller.resetDiagnostics()

        let start = scrollView.contentView.bounds.minY
        let clock = ContinuousClock()
        let end = clock.now + .seconds(8)
        var events = 0
        while clock.now < end {
            scrollView.scrollWheel(with: try event())
            events += 1
            try await Task.sleep(for: interval)
        }
        try await Task.sleep(for: .milliseconds(500))
        let travelled = scrollView.contentView.bounds.minY - start
        let report = controller.diagnosticsText ?? ""
        print("INFLUX-PERF \(label): \(events) events, \(Int(travelled)) pt · \(report.replacingOccurrences(of: "\n", with: " · "))")
        #expect(report.contains("hitch"))
        return (events, travelled)
    }

    private func wheel(lines: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                         wheel1: lines, wheel2: 0, wheel3: 0))
        let wheel = try #require(NSEvent(cgEvent: event))
        #expect(!wheel.hasPreciseScrollingDeltas)
        return wheel
    }

    private func pixels(_ points: Int32) throws -> NSEvent {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                         wheel1: points, wheel2: 0, wheel3: 0))
        let scroll = try #require(NSEvent(cgEvent: event))
        #expect(scroll.hasPreciseScrollingDeltas)
        return scroll
    }

    /// How far one event scrolls a tall document, in points.
    private func moved(by event: NSEvent, in scrollView: NSScrollView) async throws -> CGFloat {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        scrollView.frame = window.contentView!.bounds
        scrollView.hasVerticalScroller = true
        scrollView.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 400, height: 100_000))
        window.contentView!.addSubview(scrollView)
        window.orderFront(nil)
        let start = scrollView.contentView.bounds.minY
        scrollView.scrollWheel(with: event)
        // Wheel steps may animate; let them settle.
        try await Task.sleep(for: .milliseconds(400))
        return scrollView.contentView.bounds.minY - start
    }

    private func wait(_ what: String, until condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(100)) }
        try #require(condition(), "timed out waiting for \(what)")
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
#endif
