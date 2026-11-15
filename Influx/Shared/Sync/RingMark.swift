import CoreGraphics
import Foundation

/// The sync button's mark and the pull-to-refresh mark ("Full Circle",
/// bespokebits/influx-dev#254): a hairline progress ring on a 24-point
/// grid, as plain geometry a given time into a phase. The views draw
/// whatever this says, so the motion can be tested without a screen.
///
/// - Pull: a faint track, and the ring filling clockwise from the top as
///   the reader pulls. Far enough to refresh, it turns ink and thumps once.
/// - Start-up: the track draws round, then the chase fades in.
/// - Syncing: three short arcs in the source colours chase each other
///   round, each breathing longer and shorter.
/// - Synced: the arcs go, the ring closes in ink and stamps down like a
///   postmark, a tick draws inside, and a faint impression spreads out.
///   The resting button is that ring and tick: up to date.
/// - Failed: the ring turns the error colour, squashes like a dropped
///   ball, and an exclamation mark pops in.
///
/// With Reduce Motion nothing turns, stamps or squashes: the arcs stay put
/// and light up in turn, and the tick and the exclamation mark fade in.
enum RingMark {
    enum Phase: Equatable {
        case starting, syncing, synced, failed
    }

    /// The colour of the ring and the marks inside it.
    enum Tint: Equatable {
        /// Ink, the resting and finished colour.
        case ink
        /// Secondary ink, while a pull is not yet far enough.
        case ink2
        case alarm
    }

    struct Frame: Equatable {
        /// The faint full circle behind a pull: how much is drawn, from the top.
        var trackDrawn: CGFloat = 0
        var trackOpacity: CGFloat = 0
        /// The ring: how much is drawn clockwise from the top.
        var ringDrawn: CGFloat = 0
        var ringOpacity: CGFloat = 0
        /// The ring's stamp or squash, about the centre, in screen axes.
        var ringScale = CGSize(width: 1, height: 1)
        var tint: Tint = .ink
        /// How far the chase has turned, in degrees clockwise.
        var chaseAngle: Double = 0
        /// Each arc's length, as a share of the circle.
        var arcLengths: [CGFloat] = [0, 0, 0]
        var arcOpacities: [CGFloat] = [0, 0, 0]
        /// The tick: how much is drawn, from its short end.
        var tickDrawn: CGFloat = 0
        var tickOpacity: CGFloat = 0
        var exclamationScale: CGFloat = 0
        var exclamationOpacity: CGFloat = 0
        /// The impression the stamp leaves, spreading out from the ring.
        var impressionScale: CGFloat = 1
        var impressionOpacity: CGFloat = 0
    }

    static let center = CGPoint(x: 12, y: 12)
    static let radius: CGFloat = 8
    static let stroke: CGFloat = 1.5
    /// The chasing arcs are a little heavier than the ring.
    static let arcStroke: CGFloat = 1.9
    static let tick = [CGPoint(x: 8.3, y: 12.3), CGPoint(x: 10.9, y: 14.9), CGPoint(x: 15.9, y: 9.6)]
    static let exclamationTop = CGPoint(x: 12, y: 7.8)
    static let exclamationBottom = CGPoint(x: 12, y: 12.8)
    static let exclamationPoint = CGPoint(x: 12, y: 16)
    static let exclamationPointRadius: CGFloat = 1
    /// Where each arc starts, a third of the circle apart, before the chase turns them.
    static let arcOffsets: [Double] = [0, 120, 240]

    /// One turn of the chase, and one breath of each arc.
    static let turn = 1.2
    /// The arcs breathe between these shares of the circle.
    static let shortArc: CGFloat = 5 / circumference
    static let longArc: CGFloat = 14 / circumference
    /// With Reduce Motion the arcs keep one length and light up in turn.
    static let stillArc: CGFloat = 12 / circumference
    static let stillCycle = 1.8
    static let circumference: CGFloat = 2 * .pi * 8

    /// How long the start-up's track takes to draw round.
    static let introLength = 0.6
    /// The thump when a pull goes far enough to refresh.
    static let armLength = 0.35

    /// When a phase's motion ends and its last frame can stay; nil for
    /// one that keeps moving.
    static func settleTime(_ phase: Phase, reduceMotion: Bool = false) -> Double? {
        switch phase {
        case .starting, .syncing: nil
        case .synced: reduceMotion ? 0.4 : 1.25
        case .failed: reduceMotion ? 0.4 : 0.65
        }
    }

    /// The frame `t` seconds into `phase`. `fromAngle` is where the chase
    /// had turned to when the phase began, so the arcs fade out where
    /// they were.
    static func frame(_ phase: Phase, elapsed t: Double, fromAngle: Double = 0, reduceMotion: Bool = false) -> Frame {
        var f = Frame()
        switch phase {
        case .starting:
            if !reduceMotion {
                f.trackDrawn = easeOut(progress(t, start: 0, length: introLength))
                // The track gives way to the chase as it fades in.
                f.trackOpacity = 1 - progress(t, start: 0.3, length: 0.5)
            }
            chase(&f, t, reduceMotion: reduceMotion, opacity: reduceMotion ? 1 : progress(t, start: 0.3, length: 0.5))
        case .syncing:
            chase(&f, t, reduceMotion: reduceMotion, opacity: 1)
        case .synced:
            fadeArcs(&f, t, fromAngle: fromAngle, reduceMotion: reduceMotion)
            f.tint = .ink
            f.ringOpacity = 1
            f.tickDrawn = 1
            if reduceMotion {
                f.ringDrawn = 1
                f.tickOpacity = progress(t, start: 0, length: 0.4)
            } else {
                f.ringDrawn = easeOut(progress(t, start: 0, length: 0.45))
                let scale = stamp(progress(t, start: 0.4, length: 0.45))
                f.ringScale = CGSize(width: scale, height: scale)
                f.tickDrawn = easeOut(progress(t, start: 0.5, length: 0.3))
                f.tickOpacity = t >= 0.5 ? 1 : 0
                let spread = progress(t, start: 0.55, length: 0.7)
                if spread > 0, spread < 1 {
                    f.impressionScale = 1 + 0.7 * easeOut(spread)
                    f.impressionOpacity = 0.5 * (1 - easeOut(spread))
                }
            }
        case .failed:
            fadeArcs(&f, t, fromAngle: fromAngle, reduceMotion: reduceMotion)
            f.tint = .alarm
            f.ringDrawn = 1
            f.ringOpacity = 1
            if reduceMotion {
                f.exclamationScale = 1
                f.exclamationOpacity = progress(t, start: 0, length: 0.4)
            } else {
                f.ringScale = squash(progress(t, start: 0, length: 0.6))
                let pop = progress(t, start: 0.3, length: 0.35)
                f.exclamationScale = pop > 0 ? 0.3 + 0.7 * backOut(pop) : 0
                f.exclamationOpacity = pop
            }
        }
        return f
    }

    /// The frame while the reader pulls: `pull` from 0 to 1, where 1
    /// refreshes on letting go. `armedFor` is how long the pull has been
    /// far enough, nil before it is.
    static func pullFrame(_ pull: CGFloat, armedFor: Double? = nil, reduceMotion: Bool = false) -> Frame {
        var f = Frame()
        let pull = min(1, max(0, pull))
        f.trackDrawn = 1
        f.trackOpacity = pull > 0 ? 1 : 0
        f.ringDrawn = pull
        f.ringOpacity = min(1, pull * 20)
        f.tint = armedFor == nil ? .ink2 : .ink
        if let armedFor, !reduceMotion {
            let scale = stamp(progress(armedFor, start: 0, length: armLength))
            f.ringScale = CGSize(width: scale, height: scale)
        }
        return f
    }

    /// Where the chase has turned to `t` seconds into a chasing phase.
    static func chaseAngle(_ t: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : (t / turn).truncatingRemainder(dividingBy: 1) * 360
    }

    private static func chase(_ f: inout Frame, _ t: Double, reduceMotion: Bool, opacity: CGFloat) {
        f.chaseAngle = chaseAngle(t, reduceMotion: reduceMotion)
        if reduceMotion {
            // Each arc lights up in turn, a third of a cycle apart.
            let delays = [0.0, -1.2, -0.6]
            f.arcLengths = [stillArc, stillArc, stillArc]
            f.arcOpacities = delays.map { opacity * lightUp(t + $0) }
        } else {
            f.arcLengths = (0..<3).map { i in
                let breath = ((t + 0.4 * Double(i)) / turn).truncatingRemainder(dividingBy: 1)
                let toward = breath < 0.5 ? breath * 2 : (1 - breath) * 2
                return shortArc + (longArc - shortArc) * easeInOut(CGFloat(toward))
            }
            f.arcOpacities = [opacity, opacity, opacity]
        }
    }

    /// The arcs fading out where the chase left them, over 0.2 s.
    private static func fadeArcs(_ f: inout Frame, _ t: Double, fromAngle: Double, reduceMotion: Bool) {
        let left = 1 - progress(t, start: 0, length: 0.2)
        guard left > 0 else { return }
        f.chaseAngle = fromAngle
        f.arcLengths = Array(repeating: reduceMotion ? stillArc : shortArc, count: 3)
        f.arcOpacities = [left, left, left]
    }

    /// One arc's brightness with Reduce Motion: up from a quarter to full
    /// over the first third of its cycle, back down over the second.
    private static func lightUp(_ t: Double) -> CGFloat {
        var p = (t / stillCycle).truncatingRemainder(dividingBy: 1)
        if p < 0 { p += 1 }
        switch p {
        case ..<(1.0 / 3): return 0.25 + 0.75 * CGFloat(p * 3)
        case ..<(2.0 / 3): return 1 - 0.75 * CGFloat((p - 1.0 / 3) * 3)
        default: return 0.25
        }
    }

    /// The postmark thump: up to 1.18 by 35 %, back to 1.
    private static func stamp(_ p: CGFloat) -> CGFloat {
        guard p > 0, p < 1 else { return 1 }
        return p < 0.35 ? 1 + 0.18 * easeOut(p / 0.35) : 1 + 0.18 * (1 - easeOut((p - 0.35) / 0.65))
    }

    /// The dropped-ball squash: tall and narrow, then wide, then round.
    private static func squash(_ p: CGFloat) -> CGSize {
        let keys: [(CGFloat, CGSize)] = [
            (0, CGSize(width: 1, height: 1)), (0.25, CGSize(width: 0.88, height: 1.14)),
            (0.55, CGSize(width: 1.06, height: 0.95)), (1, CGSize(width: 1, height: 1)),
        ]
        for (a, b) in zip(keys, keys.dropFirst()) where p <= b.0 {
            let k = easeOut((p - a.0) / (b.0 - a.0))
            return CGSize(width: a.1.width + (b.1.width - a.1.width) * k,
                          height: a.1.height + (b.1.height - a.1.height) * k)
        }
        return CGSize(width: 1, height: 1)
    }

    private static func progress(_ t: Double, start: Double, length: Double) -> CGFloat {
        CGFloat(min(1, max(0, (t - start) / length)))
    }

    private static func easeOut(_ p: CGFloat) -> CGFloat { 1 - (1 - p) * (1 - p) * (1 - p) }

    private static func easeInOut(_ p: CGFloat) -> CGFloat { p * p * (3 - 2 * p) }

    /// Past 1 and back, for the exclamation mark's pop.
    private static func backOut(_ p: CGFloat) -> CGFloat {
        let c1: CGFloat = 2.2, c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }
}
