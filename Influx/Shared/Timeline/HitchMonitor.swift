// Scroll diagnostics: an on-screen hitch counter, shown when the debug
// setting is on (AppSettings.showScrollDiagnostics). Every display-link frame that
// arrives more than half a frame late while the timeline is scrolling counts
// its lateness as hitch time. The ratio is hitch milliseconds per second of
// scrolling: under 5 is good, over 10 is bad (Apple's guidance).
import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@MainActor
final class HitchMonitor: NSObject {
    var rows = 0
    var layoutMilliseconds = 0.0
    /// Rows shown blank because prefetch hadn't reached them.
    var misses = 0
    var note = ""

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var lastScroll: CFTimeInterval = 0
    private var lastReport: CFTimeInterval = 0
    private var tally = HitchTally()
    private var excludeUntil: CFTimeInterval = 0
    /// True during a live window resize; its frames are not scrolling.
    var isResizing = false
    private var frameRate = 0.0
    private let onUpdate: (String) -> Void

    init(onUpdate: @escaping (String) -> Void) {
        self.onUpdate = onUpdate
        super.init()
    }

    #if canImport(UIKit)
    func start() {
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    #else
    func start(in view: NSView) {
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }
    #endif

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// Call on every scroll position change.
    func noteScroll() {
        lastScroll = CACurrentMediaTime()
    }

    /// Keeps the next frames out of the scroll figures, for work that isn't
    /// scrolling (a relayout, an append). Its worst frame is shown separately.
    func exclude(for seconds: CFTimeInterval = 0.5) {
        excludeUntil = max(excludeUntil, CACurrentMediaTime() + seconds)
    }

    func reset() {
        tally = HitchTally()
        report(force: true)
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        let expected = link.targetTimestamp - link.timestamp
        guard lastTimestamp > 0, expected > 0 else { return }
        frameRate = 1 / expected
        tally.frame(from: lastTimestamp, to: now, expected: expected, lastScroll: lastScroll,
                    excluded: isResizing || now < excludeUntil)
        report(force: false)
    }

    private func report(force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastReport > 0.25 else { return }
        lastReport = now
        var text = String(format: "%.0f Hz · %ld rows · layout %.0f ms · misses %ld\nhitch %.1f ms/s · worst %.0f ms · scrolled %.0f s",
                          frameRate, rows, layoutMilliseconds, misses, tally.ratio, tally.worstFrame * 1000, tally.scrollSeconds)
        if tally.worstExcluded > 0 { text += String(format: "\nresize/append worst %.0f ms (not counted)", tally.worstExcluded * 1000) }
        if !note.isEmpty { text += "\n" + note }
        onUpdate(text)
    }
}

/// The hitch figures, one display-link frame at a time.
struct HitchTally {
    private(set) var hitchSeconds = 0.0
    private(set) var scrollSeconds = 0.0
    private(set) var worstFrame = 0.0
    private(set) var worstExcluded = 0.0

    /// Hitch milliseconds per second of scrolling.
    var ratio: Double { scrollSeconds > 0 ? hitchSeconds * 1000 / scrollSeconds : 0 }

    /// Counts the frame from `previous` to `now`. It is scrolling if the view
    /// scrolled shortly before the frame began, so a long stall mid-fling
    /// still counts, however late the next frame arrives.
    mutating func frame(from previous: CFTimeInterval, to now: CFTimeInterval, expected: CFTimeInterval,
                        lastScroll: CFTimeInterval, excluded: Bool) {
        let delta = now - previous
        let late = delta > expected * 1.5
        if excluded {
            if late { worstExcluded = max(worstExcluded, delta) }
        } else if previous - lastScroll < 0.1 {
            scrollSeconds += delta
            if late {
                hitchSeconds += delta - expected
                worstFrame = max(worstFrame, delta)
            }
        }
    }
}
