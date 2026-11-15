import QuartzCore
import Testing
@testable import Influx

/// The hitch counter must see late frames while scrolling, so a zero from
/// a perf run means smooth scrolling, not a blind counter.
@Suite struct HitchTallyTests {
    private let frame = 1.0 / 120

    /// One second of on-time frames at 120 Hz, scrolled throughout, with
    /// the frames listed in `late` arriving that much late instead.
    private func scroll(late: [Int: Double] = [:]) -> HitchTally {
        var tally = HitchTally()
        var time = 100.0
        for index in 0..<120 {
            let delta = frame + (late[index] ?? 0)
            tally.frame(from: time, to: time + delta, expected: frame, lastScroll: time, excluded: false)
            time += delta
        }
        return tally
    }

    @Test func onTimeFramesAreNotHitches() {
        let tally = scroll()
        #expect(tally.hitchSeconds == 0)
        #expect(abs(tally.scrollSeconds - 1) < 0.001)
    }

    @Test func lateFrameCountsItsLateness() {
        let tally = scroll(late: [60: 0.025])
        #expect(abs(tally.hitchSeconds - 0.025) < 0.0001)
        #expect(abs(tally.worstFrame - (frame + 0.025)) < 0.0001)
        #expect(tally.ratio > 20)
    }

    /// A stall longer than the scroll window must still count: the view
    /// scrolled just before the frame began.
    @Test func longStallMidScrollCounts() {
        var tally = HitchTally()
        tally.frame(from: 100, to: 100.3, expected: frame, lastScroll: 99.999, excluded: false)
        #expect(abs(tally.hitchSeconds - (0.3 - frame)) < 0.0001)
        #expect(abs(tally.worstFrame - 0.3) < 0.0001)
    }

    @Test func framesAfterScrollingStopsAreIgnored() {
        var tally = HitchTally()
        tally.frame(from: 101, to: 101.05, expected: frame, lastScroll: 100, excluded: false)
        #expect(tally.scrollSeconds == 0)
        #expect(tally.hitchSeconds == 0)
    }

    @Test func excludedFramesAreShownApart() {
        var tally = HitchTally()
        tally.frame(from: 100, to: 100.05, expected: frame, lastScroll: 100, excluded: true)
        #expect(tally.hitchSeconds == 0)
        #expect(abs(tally.worstExcluded - 0.05) < 0.0001)
    }
}
