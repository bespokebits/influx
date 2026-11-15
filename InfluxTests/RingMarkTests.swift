import CoreGraphics
import Testing
@testable import Influx

@Suite struct RingMarkTests {
    private let one = CGSize(width: 1, height: 1)

    @Test func aPullFillsTheRingInSecondaryInkUntilItIsFarEnough() {
        #expect(RingMark.pullFrame(0).trackOpacity == 0)
        for pull in stride(from: CGFloat(0.1), through: 0.9, by: 0.1) {
            let frame = RingMark.pullFrame(pull)
            #expect(frame.trackOpacity == 1 && frame.trackDrawn == 1)
            #expect(frame.ringDrawn == pull)
            #expect(frame.tint == .ink2)
            #expect(frame.ringScale == one)
        }
        #expect(RingMark.pullFrame(1.4).ringDrawn == 1)
        #expect(RingMark.pullFrame(1, armedFor: 0).tint == .ink)
    }

    @Test func farEnoughThumpsOnceAndRests() {
        let peak = (0...35).map { RingMark.pullFrame(1, armedFor: Double($0) / 100).ringScale.width }.max()!
        #expect(abs(peak - 1.18) < 0.01)
        #expect(RingMark.pullFrame(1, armedFor: RingMark.armLength).ringScale == one)
        #expect(RingMark.pullFrame(1, armedFor: 0.1, reduceMotion: true).ringScale == one)
    }

    @Test func startUpDrawsTheTrackThenTheChaseTakesOver() {
        let first = RingMark.frame(.starting, elapsed: 0)
        #expect(first.trackDrawn == 0)
        #expect(first.arcOpacities == [0, 0, 0])
        let later = RingMark.frame(.starting, elapsed: 1)
        #expect(later.trackDrawn == 1 && later.trackOpacity == 0)
        #expect(later.arcOpacities == [1, 1, 1])
    }

    @Test func syncingChasesThreeBreathingArcs() {
        var last = -1.0
        for t in stride(from: 0.0, to: RingMark.turn, by: 0.05) {
            let frame = RingMark.frame(.syncing, elapsed: t)
            #expect(frame.ringOpacity == 0 && frame.tickOpacity == 0)
            #expect(frame.arcOpacities == [1, 1, 1])
            for length in frame.arcLengths {
                #expect(length >= RingMark.shortArc - 0.0001 && length <= RingMark.longArc + 0.0001)
            }
            #expect(frame.chaseAngle > last)
            last = frame.chaseAngle
        }
        // The arcs breathe out of step with each other.
        let frame = RingMark.frame(.syncing, elapsed: 0.3)
        #expect(Set(frame.arcLengths).count == 3)
    }

    @Test func syncedClosesTheRingStampsItAndRestsOnATick() {
        let start = RingMark.frame(.synced, elapsed: 0.05, fromAngle: 200)
        #expect(start.chaseAngle == 200)
        #expect(start.arcOpacities.allSatisfy { $0 > 0 && $0 < 1 })
        let stamped = (40...85).map { RingMark.frame(.synced, elapsed: Double($0) / 100).ringScale.width }.max()!
        #expect(stamped > 1.15)
        let done = RingMark.frame(.synced, elapsed: RingMark.settleTime(.synced)!)
        #expect(done.tint == .ink)
        #expect(done.ringDrawn == 1 && done.ringOpacity == 1 && done.ringScale == one)
        #expect(done.tickDrawn == 1 && done.tickOpacity == 1)
        #expect(done.arcOpacities == [0, 0, 0])
        #expect(done.impressionOpacity == 0)
        #expect(done.exclamationOpacity == 0)
    }

    @Test func failedTurnsTheRingRedAndPopsAnExclamationMark() {
        let squashed = RingMark.frame(.failed, elapsed: 0.15)
        #expect(squashed.ringScale.height > 1 && squashed.ringScale.width < 1)
        let done = RingMark.frame(.failed, elapsed: RingMark.settleTime(.failed)!)
        #expect(done.tint == .alarm)
        #expect(done.ringDrawn == 1 && done.ringScale == one)
        #expect(done.exclamationScale == 1 && done.exclamationOpacity == 1)
        #expect(done.tickOpacity == 0)
        #expect(done.arcOpacities == [0, 0, 0])
    }

    @Test func reduceMotionNeverTurnsStampsOrSquashes() {
        for phase in [RingMark.Phase.starting, .syncing, .synced, .failed] {
            for t in stride(from: 0.0, to: 3, by: 0.05) {
                let frame = RingMark.frame(phase, elapsed: t, reduceMotion: true)
                #expect(frame.chaseAngle == 0)
                #expect(frame.ringScale == one)
                #expect(frame.impressionOpacity == 0)
                #expect(frame.exclamationScale == 0 || frame.exclamationScale == 1)
            }
        }
        // The arcs stay put and light up one after another.
        let lit = (0..<36).map { RingMark.frame(.syncing, elapsed: Double($0) / 20, reduceMotion: true).arcOpacities }
        for i in 0..<3 {
            #expect(lit.map { $0[i] }.max()! > 0.95)
            #expect(lit.map { $0[i] }.min()! >= 0.25 - 0.0001)
        }
        let done = RingMark.frame(.synced, elapsed: RingMark.settleTime(.synced, reduceMotion: true)!, reduceMotion: true)
        #expect(done.tickOpacity == 1 && done.ringDrawn == 1)
    }
}
