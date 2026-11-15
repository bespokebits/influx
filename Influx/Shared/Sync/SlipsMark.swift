import CoreGraphics
import Foundation

/// The sync button's mark, the In tray with three source dots, as
/// plain geometry on a 24-point grid: where everything is a given time
/// into a phase. The button draws whatever this says, so the motion can be
/// tested without a screen.
///
/// - Start-up: the tray draws itself and the dots fly in, then circle.
/// - Syncing: the dots circle above the tray, one just behind the other.
/// - Synced: the dots drop into the tray one after another, and the tray
///   gives as it catches them. They rest there.
/// - Failed: the dots stack into a column, fuse into the bar of a "!", and
///   a fourth dot lands below. The tray goes.
enum SlipsMark {
    enum Phase: Equatable {
        case starting, syncing, synced, failed
    }

    struct Dot: Equatable {
        var center: CGPoint
        var radius: CGFloat
        /// 0 is the dot's own source colour, 1 the error colour.
        var alarm: CGFloat
        var opacity: CGFloat
    }

    struct Frame: Equatable {
        /// How much of the tray's outline is drawn, 0 to 1.
        var trayDrawn: CGFloat
        var trayOpacity: CGFloat
        /// The tray's squash as it catches the dots, about its base.
        var trayScale: CGSize
        /// How far the tray sinks as it breathes while the dots circle.
        var trayOffset: CGFloat
        var dots: [Dot]
        /// The bar of the "!", from (12, 3.5) to (12, 11.5).
        var barOpacity: CGFloat
        var barScale: CGSize
        /// The dot of the "!".
        var pointScale: CGFloat
    }

    /// The tray, as an outline on the 24-point grid.
    static func trayPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 3.5, y: 14))
        path.addLine(to: CGPoint(x: 8.1, y: 14))
        path.addLine(to: CGPoint(x: 9.7, y: 16.4))
        path.addLine(to: CGPoint(x: 14.3, y: 16.4))
        path.addLine(to: CGPoint(x: 15.9, y: 14))
        path.addLine(to: CGPoint(x: 20.5, y: 14))
        path.addLine(to: CGPoint(x: 20.5, y: 18.6))
        path.addQuadCurve(to: CGPoint(x: 18.9, y: 20.2), control: CGPoint(x: 20.5, y: 20.2))
        path.addLine(to: CGPoint(x: 5.1, y: 20.2))
        path.addQuadCurve(to: CGPoint(x: 3.5, y: 18.6), control: CGPoint(x: 3.5, y: 20.2))
        path.closeSubpath()
        return path
    }

    static let trayStroke: CGFloat = 1.5
    static let dotRadius: CGFloat = 1.9
    /// The "!" bar is as wide as a dot.
    static let barWidth: CGFloat = 3.8
    static let barTop = CGPoint(x: 12, y: 3.5)
    static let barBottom = CGPoint(x: 12, y: 11.5)
    static let point = CGPoint(x: 12, y: 18.4)
    /// The tray squashes about the middle of its base.
    static let trayAnchor = CGPoint(x: 12, y: 20)

    /// Where the dots circle: around (12, 10), 6.5 out, spread 55° apart.
    static let orbitCenter = CGPoint(x: 12, y: 10)
    static let orbitRadius: CGFloat = 6.5
    static let spread: [Double] = [-55, 0, 55]
    /// Resting in the tray.
    static let restingCenters = [CGPoint(x: 8, y: 17.1), CGPoint(x: 12, y: 17.1), CGPoint(x: 16, y: 17.1)]
    /// Stacked into the "!" bar.
    static let columnCenters = [CGPoint(x: 12, y: 3.5), CGPoint(x: 12, y: 7.5), CGPoint(x: 12, y: 11.5)]

    /// One turn of the circling.
    static func turn(reduceMotion: Bool) -> Double { reduceMotion ? 3 : 1.15 }
    /// When the start-up's fly-in hands over to circling.
    static let introLength = 1.15

    /// How long a phase moves before it holds still; nil for the phases
    /// that keep moving.
    static func settleTime(_ phase: Phase) -> Double? {
        switch phase {
        case .starting, .syncing: nil
        case .synced: 1.0
        case .failed: 1.5
        }
    }

    /// The mark `elapsed` seconds into `phase`, which began with the dots
    /// at `from` (the previous phase's last positions; nil at launch).
    static func frame(_ phase: Phase, elapsed t: Double, from: [CGPoint]? = nil, reduceMotion: Bool = false) -> Frame {
        let from = from ?? orbitCenters(at: 0)
        var frame = Frame(trayDrawn: 1, trayOpacity: 1, trayScale: CGSize(width: 1, height: 1), trayOffset: 0,
                          dots: from.map { Dot(center: $0, radius: dotRadius, alarm: 0, opacity: 1) },
                          barOpacity: 0, barScale: CGSize(width: 1, height: 1), pointScale: 0)
        let turn = turn(reduceMotion: reduceMotion)
        switch phase {
        case .starting:
            frame.trayDrawn = easeInOut(progress(t, start: 0, length: 0.6))
            let circling = max(0, t - introLength)
            let orbit = orbitCenters(at: circling / turn, stagger: circling > 0)
            let flyFrom: [CGVector] = [CGVector(dx: -14, dy: 6), CGVector(dx: 0, dy: -12), CGVector(dx: 14, dy: 6)]
            for i in 0..<3 {
                let p = progress(t, start: 0.18 + 0.12 * Double(i), length: 0.7)
                let start = CGPoint(x: orbit[i].x + flyFrom[i].dx, y: orbit[i].y + flyFrom[i].dy)
                frame.dots[i].center = mix(start, orbit[i], reduceMotion ? easeOut(p) : backOut(p))
                frame.dots[i].radius = dotRadius * max(0, reduceMotion ? easeOut(p) : backOut(p))
                frame.dots[i].opacity = min(1, p / 0.6)
            }

        case .syncing:
            let orbit = orbitCenters(at: t / turn, stagger: true)
            // From wherever the dots were, into the circle.
            let lift = reduceMotion ? easeOut(progress(t, start: 0, length: 0.45)) : backOut(progress(t, start: 0, length: 0.45))
            for i in 0..<3 {
                frame.dots[i].center = mix(from[i], orbit[i], lift)
            }
            frame.trayOffset = reduceMotion ? 0 : (1 - cos(t / turn * 2 * .pi)) / 2

        case .synced:
            for i in 0..<3 {
                let p = progress(t, start: 0.07 * Double(i), length: 0.5)
                frame.dots[i].center = mix(from[i], restingCenters[i], reduceMotion ? easeOut(p) : backOut(p))
                frame.dots[i].radius = dotRadius * (1 - 0.1 * min(1, p))
            }
            if !reduceMotion {
                let squash = catchCurve(progress(t, start: 0.38, length: 0.5))
                frame.trayScale = CGSize(width: 1 + 0.06 * squash, height: 1 - 0.18 * squash)
            }

        case .failed:
            frame.trayOpacity = 1 - easeOut(progress(t, start: 0, length: 0.3))
            for i in 0..<3 {
                let p = progress(t, start: 0.06 * Double(i), length: 0.45)
                frame.dots[i].center = mix(from[i], columnCenters[i], reduceMotion ? easeOut(p) : backOut(p))
                frame.dots[i].alarm = progress(t, start: 0.45, length: 0.25)
                frame.dots[i].opacity = 1 - progress(t, start: 0.8, length: 0.15)
            }
            frame.barOpacity = progress(t, start: 0.7, length: 0.15)
            if !reduceMotion {
                let fuse = progress(t, start: 0.7, length: 0.35)
                let squash = catchCurve(fuse)
                frame.barScale = CGSize(width: 1 + 0.25 * squash, height: 1 - 0.2 * squash)
            }
            let p = progress(t, start: 1.0, length: 0.45)
            frame.pointScale = reduceMotion ? easeOut(p) : backOut(p)
        }
        return frame
    }

    /// The three dots on the circle, `turns` turns round. Staggered, each
    /// runs a little behind the one before.
    static func orbitCenters(at turns: Double, stagger: Bool = false) -> [CGPoint] {
        (0..<3).map { i in
            let lag = stagger ? 0.07 * Double(i) : 0
            let eased = easedTurns(max(0, turns - lag))
            let angle = (spread[i] + 360 * eased) * .pi / 180
            // 0° is straight up; angles run clockwise, as on screen.
            return CGPoint(x: orbitCenter.x + orbitRadius * sin(angle),
                           y: orbitCenter.y - orbitRadius * cos(angle))
        }
    }

    // MARK: Easing

    /// Whole turns stay whole; within a turn, the dots speed up and ease off.
    private static func easedTurns(_ turns: Double) -> Double {
        let whole = floor(turns)
        return whole + easeInOutTurn(turns - whole)
    }

    private static func progress(_ t: Double, start: Double, length: Double) -> CGFloat {
        CGFloat(min(1, max(0, (t - start) / length)))
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, _ p: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p)
    }

    private static func easeInOutTurn(_ p: Double) -> Double {
        p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
    }

    private static func easeInOut(_ p: CGFloat) -> CGFloat {
        CGFloat(easeInOutTurn(Double(p)))
    }

    private static func easeOut(_ p: CGFloat) -> CGFloat {
        1 - (1 - p) * (1 - p)
    }

    /// Overshoots a little, then settles: a spring without the wobble.
    private static func backOut(_ p: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.9, c3 = c1 + 1
        let q = p - 1
        return 1 + c3 * q * q * q + c1 * q * q
    }

    /// 0 → 1 → 0, quick in, slower out: a catch.
    private static func catchCurve(_ p: CGFloat) -> CGFloat {
        guard p > 0, p < 1 else { return 0 }
        return p < 0.35 ? easeOut(p / 0.35) : 1 - easeInOut((p - 0.35) / 0.65)
    }
}
