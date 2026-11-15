// The "Syncing in Progress" screen: one of six animations, picked at random,
// over the timeline until the catch-up sync lands (see SyncingGate). Each
// is drawn from the time alone, so it starts on the first frame and needs
// nothing loaded: Canvas and SwiftUI, no images, no media frameworks.
import SwiftUI

/// The screen while the gate holds, and the note under the bar after it
/// lifts on this device's own place.
struct SyncingOverlay: View {
    let gate: SyncingGate
    @State private var note: SyncingGate.Lift?

    var body: some View {
        ZStack(alignment: .top) {
            if gate.isShowing {
                SyncingScreen(scene: gate.scene)
                    .transition(.opacity)
            }
            if let note, let text = Self.text(for: note) {
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.paint(Broadsheet.ink))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.paint(Broadsheet.wash)))
                    .overlay(Capsule().strokeBorder(Color.paint(Broadsheet.rule), lineWidth: 1))
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityIdentifier("syncing-note")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.35), value: gate.isShowing)
        .animation(.easeOut(duration: 0.25), value: note)
        // Only the screen itself takes touches; the note doesn't.
        .allowsHitTesting(gate.isShowing)
        .onChange(of: gate.lifted) { _, lifted in
            note = lifted
            guard let lifted else { return }
            Task {
                try? await Task.sleep(for: .seconds(3))
                if note == lifted { note = nil }
            }
        }
    }

    /// What the note says after the screen lifted, or nil when it needs no
    /// word: a sync that landed brought the place, and one still on its way
    /// at the limit is just slow, so the screen lifts quietly and the place
    /// it brings is followed when it lands, unless the reader moved first.
    static func text(for lift: SyncingGate.Lift) -> String? {
        #if os(iOS)
        let device = "this iPhone"
        #else
        let device = "this Mac"
        #endif
        switch lift {
        case .synced, .slow: return nil
        case .offline: return "Offline · where \(device) left off"
        case .failed: return "Couldn’t sync · where \(device) left off"
        }
    }
}

struct SyncingScreen: View {
    let scene: SyncingScene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// When the animation started, or nil while it holds still. At launch
    /// it holds on its resting frame until the timeline's first rows are
    /// drawn underneath, so it doesn't take frames from them, then moves on
    /// from that frame.
    @State private var start: Date?

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || start == nil)) { context in
            let t = rest + (reduceMotion ? 0 : start.map { max(0, context.date.timeIntervalSince($0)) } ?? 0)
            content(at: t)
        }
        .task {
            // The rows are "shown" once placed, on every run, and "drawn" a
            // frame or so later, which only perf runs mark; a quarter of a
            // second after shown stands in for drawn. Coming back, they're
            // long shown, and the animation starts at once.
            let began = ContinuousClock.now
            var shownAt: ContinuousClock.Instant?
            let longShown = LaunchClock.has("shown")
            while !longShown, ContinuousClock.now - began < .seconds(1), !LaunchClock.has("drawn") {
                if shownAt == nil, LaunchClock.has("shown") { shownAt = .now }
                if let shownAt, ContinuousClock.now - shownAt >= .milliseconds(250) { break }
                // Gone already: the screen lifted before the rows drew.
                do { try await Task.sleep(for: .milliseconds(30)) } catch { return }
            }
            start = Date()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paint(Broadsheet.paper))
        .contentShape(Rectangle())
        .ignoresSafeArea()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Syncing in Progress")
        .accessibilityIdentifier("syncing-screen")
    }

    /// The moment the scene holds on while waiting, and with Reduce Motion.
    private var rest: Double {
        #if os(macOS)
        scene.wideRestTime
        #else
        scene.restTime
        #endif
    }

    @ViewBuilder
    private func content(at t: Double) -> some View {
        let palette = SyncingPalette()
        #if os(macOS)
        // The Mac lays each scene out for its window.
        WideSyncingScene(scene: scene, t: t, palette: palette)
        #else
        if scene == .masthead {
            MastheadScene(t: t, palette: palette)
        } else {
            VStack(spacing: 28) {
                Canvas { g, _ in draw(&g, t: t, palette: palette) }
                    .frame(width: scene.figure.width, height: scene.figure.height)
                VStack(spacing: 8) {
                    Text("Syncing in Progress")
                        .font(.system(size: 28, weight: .medium, design: .serif))
                    Text(scene.caption)
                        .font(.system(size: 15))
                        .foregroundStyle(palette.ink2)
                }
                .multilineTextAlignment(.center)
            }
            .foregroundStyle(palette.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Text("Influx")
                    .font(.system(size: 15, design: .serif).italic())
                    .foregroundStyle(palette.ink2)
                    .padding(.bottom, 44)
            }
        }
        #endif
    }

    private func draw(_ g: inout GraphicsContext, t: Double, palette: SyncingPalette) {
        switch scene {
        case .inTray: SyncingScenes.inTray(&g, t: t, c: palette)
        case .confluence: SyncingScenes.confluence(&g, t: t, c: palette)
        case .pressRun: SyncingScenes.pressRun(&g, t: t, c: palette)
        case .ribbon: SyncingScenes.ribbon(&g, t: t, c: palette)
        case .threeSlips: SyncingScenes.threeSlips(&g, t: t, c: palette)
        case .masthead: break
        }
    }
}

extension SyncingScene {
    /// The line under "Syncing in Progress".
    var caption: String {
        switch self {
        case .inTray, .threeSlips: "Catching up with your other devices"
        case .confluence: "Everything flowing in, one place to read it"
        case .pressRun: "Marking where you left off"
        case .ribbon: "Picking up where you stopped reading"
        case .masthead: "Finding where you left off"
        }
    }

    /// The size the animation is drawn at, in points.
    var figure: CGSize {
        switch self {
        case .inTray, .threeSlips: CGSize(width: 200, height: 200)
        case .confluence: CGSize(width: 200, height: 240)
        case .pressRun: CGSize(width: 220, height: 270)
        case .ribbon: CGSize(width: 250, height: 300)
        case .masthead: CGSize(width: 300, height: 200)
        }
    }

    /// The moment shown still when Reduce Motion is on: everything in place.
    var restTime: Double {
        switch self {
        case .inTray: 1.6
        case .confluence: 0.3
        case .pressRun: 2.5
        case .ribbon: 2.7
        case .masthead: 1.2
        case .threeSlips: 3.1
        }
    }
}

/// The Broadsheet colours the scenes draw in, light and dark.
struct SyncingPalette {
    let paper = Color.paint(Broadsheet.paper)
    let ink = Color.paint(Broadsheet.ink)
    let ink2 = Color.paint(Broadsheet.ink2)
    let rule = Color.paint(Broadsheet.rule)
    let wash = Color.paint(Broadsheet.wash)
    /// The source colours, as the sync mark has them.
    let bluesky = Color.paint(Broadsheet.sourceColor(0))
    let mastodon = Color.paint(Broadsheet.sourceColor(1))
    let rss = Color.paint(Broadsheet.sourceColor(6))
    /// The marked row and the bookmark.
    let accent = Color.paint(Broadsheet.sourceColor(3))
}

/// Timing helpers: every scene is a loop, and each part of it a stretch
/// of that loop, eased.
enum SyncingMotion {
    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    /// How far `p` is through the stretch from `a` to `b`, 0 to 1.
    static func stretch(_ p: Double, _ a: Double, _ b: Double) -> Double { clamp((p - a) / (b - a)) }

    /// How far through its loop of `period` seconds a part is at `t`,
    /// 0 to 1; a part that starts `delay` in holds its first frame until then.
    static func loop(_ t: Double, _ period: Double, delay: Double = 0) -> Double {
        let u = t - delay
        guard u > 0 else { return 0 }
        return u.truncatingRemainder(dividingBy: period) / period
    }

    static func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
    static func easeOutQuint(_ x: Double) -> Double { 1 - pow(1 - x, 5) }
    static func easeIn(_ x: Double) -> Double { x * x * x }
    static func easeInOut(_ x: Double) -> Double { x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2 }
    /// Overshoots a little and settles back, like something landing.
    static func backOut(_ x: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    /// Up from 0 at `a` to 1 at `peak` and back to 0 at `b`.
    static func bump(_ p: Double, _ a: Double, _ peak: Double, _ b: Double) -> Double {
        guard p > a, p < b else { return 0 }
        return p < peak ? stretch(p, a, peak) : 1 - stretch(p, peak, b)
    }
}

/// The five scenes drawn on a Canvas. The In tray, Confluence and Three
/// slips are drawn on the app icon's 100-unit grid at twice that size.
enum SyncingScenes {
    typealias M = SyncingMotion

    // MARK: In tray

    /// The icon comes to life: the slips drop into the tray one after
    /// another, it gives as they land, and they lift away to fall again.
    static func inTray(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        g.scaleBy(x: 2, y: 2)
        let period = 2.6
        let slips: [(rect: CGRect, angle: Double, color: Color, delay: Double)] = [
            (CGRect(x: 30, y: 13, width: 40, height: 10), -8, c.mastodon, 0),
            (CGRect(x: 27, y: 27, width: 46, height: 10), 6, c.bluesky, 0.22),
            (CGRect(x: 30, y: 41, width: 40, height: 10), -3, c.rss, 0.44),
        ]
        for slip in slips {
            let p = M.loop(t, period, delay: slip.delay)
            var y = -78 * (1 - M.backOut(M.stretch(p, 0, 0.34)))
            var opacity = M.stretch(p, 0, 0.10)
            if p > 0.82 {
                let k = M.stretch(p, 0.82, 1)
                y = 14 * k
                opacity = 1 - k
            }
            g.drawLayer { layer in
                layer.opacity = opacity
                layer.translateBy(x: slip.rect.midX, y: slip.rect.midY)
                layer.rotate(by: .degrees(slip.angle))
                layer.translateBy(x: 0, y: y)
                let local = CGRect(x: -slip.rect.width / 2, y: -slip.rect.height / 2,
                                   width: slip.rect.width, height: slip.rect.height)
                layer.fill(Path(roundedRect: local, cornerRadius: 2), with: .color(slip.color))
            }
        }
        let p = M.loop(t, period)
        let bob = 1.6 * M.bump(p, 0.30, 0.36, 0.44) + 1.0 * M.bump(p, 0.44, 0.52, 0.60)
        g.translateBy(x: 0, y: bob)
        g.fill(trayPath(top: 57), with: .color(c.ink))
    }

    /// The icon's tray, its rim at `top`, on the 100-unit grid.
    static func trayPath(top: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 16, y: top))
        path.addLine(to: CGPoint(x: 34, y: top))
        path.addLine(to: CGPoint(x: 38, y: top + 8))
        path.addLine(to: CGPoint(x: 62, y: top + 8))
        path.addLine(to: CGPoint(x: 66, y: top))
        path.addLine(to: CGPoint(x: 84, y: top))
        path.addLine(to: CGPoint(x: 84, y: top + 23))
        path.addQuadCurve(to: CGPoint(x: 77, y: top + 30), control: CGPoint(x: 84, y: top + 30))
        path.addLine(to: CGPoint(x: 23, y: top + 30))
        path.addQuadCurve(to: CGPoint(x: 16, y: top + 23), control: CGPoint(x: 16, y: top + 30))
        path.closeSubpath()
        return path
    }

    // MARK: Confluence

    /// Three streams of dots in the source colours run down and meet in
    /// the tray: everything flowing in.
    static func confluence(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        g.scaleBy(x: 2, y: 2)
        let streams: [(path: Path, color: Color, period: Double)] = [
            (stream(from: CGPoint(x: 14, y: 0), c1: CGPoint(x: 14, y: 44), c2: CGPoint(x: 50, y: 44)), c.rss, 0.9),
            (stream(from: CGPoint(x: 50, y: 0), c1: CGPoint(x: 44, y: 30), c2: CGPoint(x: 56, y: 56)), c.bluesky, 1.1),
            (stream(from: CGPoint(x: 86, y: 0), c1: CGPoint(x: 86, y: 44), c2: CGPoint(x: 50, y: 44)), c.mastodon, 1.0),
        ]
        for stream in streams {
            g.stroke(stream.path, with: .color(stream.color.opacity(0.35)), lineWidth: 0.6)
            // The dots run forward along the stream, a dot every 9 units.
            let phase = 18 - (t.truncatingRemainder(dividingBy: stream.period) / stream.period) * 18
            g.stroke(stream.path, with: .color(stream.color),
                     style: StrokeStyle(lineWidth: 3.2, lineCap: .round, dash: [0.01, 8.99], dashPhase: phase))
        }
        // The tray swells a little as they pour in.
        let swell = 1 + 0.03 * (0.5 - 0.5 * cos(2 * .pi * t / 1.8))
        g.translateBy(x: 0, y: 114)
        g.scaleBy(x: 1, y: swell)
        g.translateBy(x: 0, y: -114)
        g.fill(trayPath(top: 84), with: .color(c.ink))
    }

    private static func stream(from start: CGPoint, c1: CGPoint, c2: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addCurve(to: CGPoint(x: 50, y: 92), control1: c1, control2: c2)
        return path
    }

    // MARK: Press run

    /// A broadsheet page prints line by line under a roller, then the row
    /// the reader is on gets marked.
    static func pressRun(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        let period = 3.2
        let sheet = CGRect(x: 0, y: 0, width: 220, height: 270)
        g.fill(Path(sheet), with: .color(c.wash))
        g.stroke(Path(sheet.insetBy(dx: 0.5, dy: 0.5)), with: .color(c.rule), lineWidth: 1)
        g.clip(to: Path(sheet))

        for line in pressLines(c) {
            let p = M.loop(t, period, delay: line.delay)
            let width = line.rect.width * M.easeOut(M.stretch(p, 0, 0.14))
            let opacity = 1 - M.stretch(p, 0.86, 1)
            g.fill(Path(CGRect(x: line.rect.minX, y: line.rect.minY, width: width, height: line.rect.height)),
                   with: .color(line.color.opacity(opacity)))
        }

        let p = M.loop(t, period)
        // The mark around the reader's row, drawn out from the left.
        let markWidth = 200 * M.easeOut(M.stretch(p, 0.64, 0.72))
        let markOpacity = M.stretch(p, 0.64, 0.72) * (1 - M.stretch(p, 0.88, 1))
        for y in [144.0, 155.0] {
            g.fill(Path(CGRect(x: 10, y: y - 0.75, width: markWidth, height: 1.5)), with: .color(c.accent.opacity(markOpacity)))
        }
        // The source dot pops in beside it.
        let pin: Double
        if p < 0.68 { pin = 0 }
        else if p < 0.76 { pin = 1.3 * M.easeOut(M.stretch(p, 0.68, 0.76)) }
        else { pin = 1.3 - 0.3 * M.stretch(p, 0.76, 0.82) }
        let r = 4 * pin
        g.fill(Path(ellipseIn: CGRect(x: 8 - r, y: 149.5 - r, width: 2 * r, height: 2 * r)),
               with: .color(c.bluesky.opacity(1 - M.stretch(p, 0.88, 1))))
        // The roller sweeps down the page as it prints.
        let rollerY = -6 + 270 * M.easeInOut(M.stretch(p, 0, 0.62))
        let rollerOpacity = M.stretch(p, 0, 0.06) * (1 - M.stretch(p, 0.62, 0.70))
        g.fill(Path(CGRect(x: 0, y: rollerY, width: 220, height: 4)), with: .color(c.ink.opacity(rollerOpacity)))
    }

    private static func pressLines(_ c: SyncingPalette) -> [(rect: CGRect, color: Color, delay: Double)] {
        var lines: [(rect: CGRect, color: Color, delay: Double)] = [
            (CGRect(x: 53, y: 18, width: 114, height: 9), c.ink, 0),
            (CGRect(x: 18, y: 34, width: 184, height: 1), c.ink, 0.05),
            (CGRect(x: 18, y: 37, width: 184, height: 1), c.ink, 0.08),
            (CGRect(x: 18, y: 47, width: 169, height: 6), c.ink, 0.16),
            (CGRect(x: 18, y: 60, width: 129, height: 6), c.ink, 0.22),
        ]
        let columns: [(x: CGFloat, widths: [CGFloat], delay: Double)] = [
            (18, [1, 0.94, 1, 0.82, 1, 0.90, 1, 0.64], 0.30),
            (117, [1, 0.88, 1, 0.96, 1, 0.78, 1, 0.86], 0.78),
        ]
        for column in columns {
            for (i, width) in column.widths.enumerated() {
                lines.append((rect: CGRect(x: column.x, y: 78 + CGFloat(i) * 10, width: 85 * width, height: 3),
                              color: c.ink2, delay: column.delay + 0.06 * Double(i)))
            }
        }
        return lines
    }

    // MARK: Ribbon

    /// A timeline runs past, slows to a stop on a row, and a bookmark
    /// drops onto it: the reader's place, found.
    static func ribbon(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        let p = M.loop(t, 3.4)
        let fadeOut = 1 - M.stretch(p, 0.90, 1)
        let band = CGRect(x: -12, y: 127, width: 274, height: 46)
        let bandOpacity = M.stretch(p, 0.58, 0.68) * fadeOut
        g.fill(Path(band), with: .color(c.wash.opacity(bandOpacity)))
        for y in [band.minY, band.maxY - 1] {
            g.fill(Path(CGRect(x: band.minX, y: y, width: band.width, height: 1)), with: .color(c.rule.opacity(bandOpacity)))
        }

        let window = CGRect(x: 0, y: 0, width: 250, height: 300)
        let offset = -333 * M.easeOutQuint(M.stretch(p, 0, 0.56))
        let rowsOpacity = M.stretch(p, 0, 0.06) * fadeOut
        g.drawLayer { layer in
            layer.clip(to: Path(window))
            layer.opacity = rowsOpacity
            let dots = [c.mastodon, c.rss, c.bluesky]
            let order = [1, 0, 2, 1, 1, 0, 2, 0, 1, 2, 0, 1, 2, 2, 0, 1]
            let first: [CGFloat] = [88, 72, 94, 66, 80, 90, 70, 84, 76, 92, 68, 86, 74, 90, 64, 82]
            let second: [CGFloat] = [56, 64, 48, 70, 52, 60, 44, 66, 58, 50, 62, 46, 68, 54, 60, 48]
            for i in 0..<16 {
                let top = CGFloat(i) * 46 + offset
                guard top > -46, top < window.maxY else { continue }
                layer.fill(Path(ellipseIn: CGRect(x: 0, y: top + 19, width: 8, height: 8)), with: .color(dots[order[i]]))
                layer.fill(Path(roundedRect: CGRect(x: 20, y: top + 16, width: 230 * first[i] / 100, height: 5), cornerRadius: 1),
                           with: .color(c.ink))
                layer.fill(Path(roundedRect: CGRect(x: 20, y: top + 27, width: 230 * second[i] / 100, height: 3), cornerRadius: 1),
                           with: .color(c.ink2.opacity(0.7)))
                layer.fill(Path(CGRect(x: 0, y: top + 45, width: 250, height: 1)), with: .color(c.rule))
            }
            // The rows fade in and out at the window's top and bottom.
            layer.fill(Path(CGRect(x: 0, y: 0, width: 250, height: 66)),
                       with: .linearGradient(Gradient(colors: [c.paper, c.paper.opacity(0)]),
                                             startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: 66)))
            layer.fill(Path(CGRect(x: 0, y: 234, width: 250, height: 66)),
                       with: .linearGradient(Gradient(colors: [c.paper.opacity(0), c.paper]),
                                             startPoint: CGPoint(x: 0, y: 234), endPoint: CGPoint(x: 0, y: 300)))
        }

        guard p >= 0.55 else { return }
        let drop = -70 * (1 - M.backOut(M.stretch(p, 0.55, 0.66)))
        var bookmark = Path()
        bookmark.move(to: CGPoint(x: 0, y: 0))
        bookmark.addLine(to: CGPoint(x: 18, y: 0))
        bookmark.addLine(to: CGPoint(x: 18, y: 40))
        bookmark.addLine(to: CGPoint(x: 9, y: 32))
        bookmark.addLine(to: CGPoint(x: 0, y: 40))
        bookmark.closeSubpath()
        g.translateBy(x: 234, y: 116 + drop)
        g.fill(bookmark, with: .color(c.accent.opacity(fadeOut)))
    }

    // MARK: Three slips

    /// The sync mark at full size: the tray draws itself, the dots circle
    /// twice and drop into it one after another, and rest.
    static func threeSlips(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        g.scaleBy(x: 2, y: 2)
        let p = M.loop(t, 3.6)
        let fadeOut = 1 - M.stretch(p, 0.92, 1)

        var tray = Path()
        tray.move(to: CGPoint(x: 20, y: 62))
        tray.addLine(to: CGPoint(x: 20, y: 80))
        tray.addQuadCurve(to: CGPoint(x: 24, y: 84), control: CGPoint(x: 20, y: 84))
        tray.addLine(to: CGPoint(x: 76, y: 84))
        tray.addQuadCurve(to: CGPoint(x: 80, y: 80), control: CGPoint(x: 80, y: 84))
        tray.addLine(to: CGPoint(x: 80, y: 62))
        let drawn = M.easeOut(M.stretch(p, 0, 0.18))
        g.stroke(tray.trimmedPath(from: 0, to: drawn), with: .color(c.ink.opacity(fadeOut)),
                 style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        let center = CGPoint(x: 50, y: 36)
        let turn = 4 * Double.pi * M.easeInOut(M.stretch(p, 0, 0.55))
        let dots: [(angle: Double, color: Color, falls: Double, depth: Double)] = [
            (-Double.pi / 2, c.bluesky, 0.55, 52),
            (Double.pi * 5 / 6, c.rss, 0.58, 31),
            (Double.pi / 6, c.mastodon, 0.61, 31),
        ]
        let grow = M.easeOut(M.stretch(p, 0, 0.08))
        for dot in dots {
            let angle = dot.angle + turn
            let x = center.x + 14 * cos(angle)
            let y = center.y + 14 * sin(angle) + fall(p, from: dot.falls, depth: dot.depth)
            let r = 4.6 * grow
            g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)),
                   with: .color(dot.color.opacity(fadeOut)))
        }
    }

    /// How far a dot that drops at `start` has fallen at `p`: down `depth`,
    /// a small bounce, and still.
    static func fall(_ p: Double, from start: Double, depth: Double) -> Double {
        if p < start { return 0 }
        if p < start + 0.11 { return depth * M.easeIn(M.stretch(p, start, start + 0.11)) }
        if p < start + 0.15 { return depth - 2.5 * M.easeOut(M.stretch(p, start + 0.11, start + 0.15)) }
        if p < start + 0.19 { return depth - 2.5 + 2.5 * M.easeIn(M.stretch(p, start + 0.15, start + 0.19)) }
        return depth
    }
}

/// "Influx" inks in letter by letter under the day's date, over a rule
/// that runs like a press, with the source dots pulsing beneath.
private struct MastheadScene: View {
    typealias M = SyncingMotion
    let t: Double
    let palette: SyncingPalette
    private static let letters = Array("Influx")

    var body: some View {
        VStack(spacing: 14) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(2.2)
                .foregroundStyle(palette.ink2)
            Rectangle().fill(palette.ink).frame(height: 1)
            HStack(spacing: -1.5) {
                ForEach(Self.letters.indices, id: \.self) { i in
                    let p = M.loop(t, 3.0, delay: 0.08 * Double(i))
                    let k = M.easeOut(M.stretch(p, 0, 0.22))
                    let fade = M.stretch(p, 0.86, 1)
                    Text(String(Self.letters[i]))
                        .font(.system(size: 76, weight: .semibold, design: .serif))
                        .opacity(k * (1 - fade))
                        .offset(y: 10 * (1 - k))
                        .blur(radius: 6 * (1 - k) + 2 * fade)
                }
            }
            VStack(spacing: 3) {
                Rectangle().fill(palette.ink).frame(height: 1)
                let p = M.loop(t, 1.5)
                Rectangle().fill(palette.rule).frame(height: 3)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(palette.ink)
                            .frame(width: 300 * M.easeInOut(M.stretch(p, 0, 0.7)), height: 3)
                            .opacity(1 - M.stretch(p, 0.7, 1))
                    }
                Rectangle().fill(palette.ink).frame(height: 1)
            }
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { i in
                    let color = [palette.rss, palette.bluesky, palette.mastodon][i]
                    let p = M.loop(t, 1.5, delay: 0.18 * Double(i))
                    let v = M.easeInOut(p < 0.4 ? M.stretch(p, 0, 0.4) : 1 - M.stretch(p, 0.4, 1))
                    Circle().fill(color)
                        .frame(width: 7, height: 7)
                        .scaleEffect(0.6 + 0.4 * v)
                        .opacity(0.35 + 0.65 * v)
                }
            }
            .padding(.top, 4)
        }
        .frame(width: 300)
        .foregroundStyle(palette.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            VStack(spacing: 6) {
                Text("Syncing in Progress")
                    .font(.system(size: 20, design: .serif).italic())
                Text(SyncingScene.masthead.caption)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.ink2)
            }
            .foregroundStyle(palette.ink)
            .padding(.bottom, 64)
        }
    }
}
