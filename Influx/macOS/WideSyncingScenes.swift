// The "Syncing in Progress" scenes as the Mac draws them: the iPhone's six,
// laid out for a window rather than a phone (influx-dev #109). Each is drawn
// on one Canvas, on a 1280 × 756 grid scaled to fit the window, from the
// time alone, like the iPhone's.
import SwiftUI

/// One scene, filling the window.
struct WideSyncingScene: View {
    let scene: SyncingScene
    let t: Double
    let palette: SyncingPalette

    /// The grid every scene is drawn on.
    static let grid = CGSize(width: 1280, height: 756)

    var body: some View {
        Canvas { g, size in
            if scene == .pressRun {
                // The page lies on a desk the size of the window.
                g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(palette.wash))
            }
            let s = min(size.width / Self.grid.width, size.height / Self.grid.height, 1.25)
            g.translateBy(x: (size.width - Self.grid.width * s) / 2, y: (size.height - Self.grid.height * s) / 2)
            g.scaleBy(x: s, y: s)
            let c = palette
            switch scene {
            case .inTray: WideSyncingScenes.inTray(&g, t: t, c: c)
            case .confluence: WideSyncingScenes.confluence(&g, t: t, c: c)
            case .pressRun: WideSyncingScenes.pressRun(&g, t: t, c: c)
            case .ribbon: WideSyncingScenes.ribbon(&g, t: t, c: c)
            case .masthead: WideSyncingScenes.masthead(&g, t: t, c: c)
            case .threeSlips: WideSyncingScenes.threeSlips(&g, t: t, c: c)
            }
        }
    }
}

extension SyncingScene {
    /// The moment the Mac shows still when Reduce Motion is on.
    var wideRestTime: Double {
        switch self {
        case .inTray: 1.6
        case .confluence: 0.3
        case .pressRun: 3.4
        case .ribbon: 3.4
        case .masthead: 1.4
        case .threeSlips: 3.6
        }
    }
}

enum WideSyncingScenes {
    typealias M = SyncingMotion

    // MARK: Words

    static func text(_ g: inout GraphicsContext, _ string: String, size: CGFloat, weight: Font.Weight = .regular,
                     design: Font.Design = .default, italic: Bool = false, tracking: CGFloat = 0,
                     color: Color, at point: CGPoint, anchor: UnitPoint = .center) {
        var text = Text(string).font(.system(size: size, weight: weight, design: design)).tracking(tracking)
        if italic { text = text.italic() }
        g.draw(text.foregroundStyle(color), at: point, anchor: anchor)
    }

    /// "Syncing in Progress" and the scene's line under it, centred on `y`.
    static func title(_ g: inout GraphicsContext, _ scene: SyncingScene, y: CGFloat, c: SyncingPalette) {
        text(&g, "Syncing in Progress", size: 44, weight: .medium, design: .serif, tracking: -0.4, color: c.ink,
             at: CGPoint(x: 640, y: y))
        text(&g, scene.caption, size: 17, color: c.ink2, at: CGPoint(x: 640, y: y + 44))
    }

    static func footer(_ g: inout GraphicsContext, y: CGFloat, c: SyncingPalette) {
        text(&g, "Influx", size: 16, design: .serif, italic: true, color: c.ink2, at: CGPoint(x: 640, y: y))
    }

    // MARK: In tray

    /// The iPhone's In tray, three times the icon: the slips drop straight
    /// into the tray one after another.
    static func inTray(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        g.drawLayer { layer in
            layer.translateBy(x: 490, y: 100)
            layer.scaleBy(x: 1.5, y: 1.5)
            SyncingScenes.inTray(&layer, t: t, c: c)
        }
        title(&g, .inTray, y: 474, c: c)
        footer(&g, y: 712, c: c)
    }

    // MARK: Confluence

    /// Three wide rivers of dots cross the window and meet in the tray.
    static func confluence(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        let end = CGPoint(x: 640, y: 505)
        let streams: [(path: Path, color: Color, period: Double)] = [
            (river(from: CGPoint(x: 0, y: 150), c1: CGPoint(x: 300, y: 150), c2: CGPoint(x: 420, y: 300),
                   mid: CGPoint(x: 520, y: 380), c3: CGPoint(x: 640, y: 440), end: end), c.rss, 1.0),
            (river(from: CGPoint(x: 640, y: 56), c1: CGPoint(x: 590, y: 170), c2: CGPoint(x: 700, y: 250),
                   mid: CGPoint(x: 640, y: 360), c3: CGPoint(x: 630, y: 450), end: end), c.bluesky, 1.25),
            (river(from: CGPoint(x: 1280, y: 190), c1: CGPoint(x: 980, y: 190), c2: CGPoint(x: 860, y: 320),
                   mid: CGPoint(x: 760, y: 390), c3: CGPoint(x: 640, y: 440), end: end), c.mastodon, 1.1),
        ]
        for stream in streams {
            g.stroke(stream.path, with: .color(stream.color.opacity(0.09)),
                     style: StrokeStyle(lineWidth: 14, lineCap: .round))
            g.stroke(stream.path, with: .color(stream.color.opacity(0.4)), lineWidth: 1)
            // A dot every 16 points, running down to the tray.
            let phase = 32 - (t.truncatingRemainder(dividingBy: stream.period) / stream.period) * 32
            g.stroke(stream.path, with: .color(stream.color),
                     style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [0.01, 15.99], dashPhase: phase))
        }
        g.drawLayer { layer in
            let swell = 1 + 0.04 * (0.5 - 0.5 * cos(2 * .pi * t / 1.8))
            layer.translateBy(x: 520, y: 476 + 30 * 2.4)
            layer.scaleBy(x: 2.4, y: 2.4 * swell)
            layer.translateBy(x: 0, y: -87)
            layer.fill(SyncingScenes.trayPath(top: 57), with: .color(c.ink))
        }
        title(&g, .confluence, y: 616, c: c)
    }

    /// A curve to `mid`, smoothly on to `end`.
    private static func river(from start: CGPoint, c1: CGPoint, c2: CGPoint, mid: CGPoint, c3: CGPoint, end: CGPoint) -> Path {
        var path = Path()
        path.move(to: start)
        path.addCurve(to: mid, control1: c1, control2: c2)
        // The first control mirrors the last, as SVG's "S" does.
        let mirrored = CGPoint(x: 2 * mid.x - c2.x, y: 2 * mid.y - c2.y)
        path.addCurve(to: end, control1: mirrored, control2: c3)
        return path
    }

    // MARK: Press run

    /// A whole front page: the masthead, the headline, and five columns that
    /// print under a roller sweeping across, then the reader's line marked.
    static func pressRun(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        let period = 4.4
        let sheet = CGRect(x: 150, y: 88, width: 980, height: 580)
        let left = sheet.minX + 40, width = sheet.width - 80
        g.drawLayer { layer in
            layer.addFilter(.shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 12))
            layer.fill(Path(sheet), with: .color(c.paper))
        }
        g.stroke(Path(sheet.insetBy(dx: 0.5, dy: 0.5)), with: .color(c.rule), lineWidth: 1)
        g.drawLayer { page in
            page.clip(to: Path(sheet))
            text(&page, "Influx", size: 60, weight: .semibold, design: .serif, tracking: -1, color: c.ink,
                 at: CGPoint(x: 640, y: sheet.minY + 58))
            page.fill(Path(CGRect(x: left, y: sheet.minY + 98, width: width, height: 1)), with: .color(c.ink))
            let date = Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            text(&page, date.uppercased(), size: 11, weight: .semibold, tracking: 1.8, color: c.ink2,
                 at: CGPoint(x: left, y: sheet.minY + 110), anchor: .leading)
            text(&page, "EDITION FOR THIS MAC", size: 11, weight: .semibold, tracking: 1.8, color: c.ink2,
                 at: CGPoint(x: left + width, y: sheet.minY + 110), anchor: .trailing)
            page.fill(Path(CGRect(x: left, y: sheet.minY + 122, width: width, height: 1)), with: .color(c.ink))
            page.fill(Path(CGRect(x: left, y: sheet.minY + 126, width: width, height: 3)), with: .color(c.ink))
            text(&page, "Syncing in Progress", size: 52, weight: .medium, design: .serif, tracking: -0.6, color: c.ink,
                 at: CGPoint(x: left, y: sheet.minY + 174), anchor: .leading)
            text(&page, "Catching up with your other devices, then marking where you left off", size: 20,
                 design: .serif, italic: true, color: c.ink2, at: CGPoint(x: left, y: sheet.minY + 218), anchor: .leading)
            page.fill(Path(CGRect(x: left, y: sheet.minY + 238, width: width, height: 1)), with: .color(c.rule))

            // Five columns, printed right behind the roller as it sweeps
            // across, and all lifted together at the end of the run.
            let p = M.loop(t, period)
            let fade = 1 - M.stretch(p, 0.90, 1)
            let rollerX = sheet.minX - 8 + (sheet.width + 8) * M.easeInOut(M.stretch(p, 0, 0.60))
            let gap: CGFloat = 26
            let column = (width - 4 * gap) / 5
            let widths: [CGFloat] = [1, 0.94, 1, 0.88, 1, 0.72, 1, 0.96, 1, 0.84, 1, 0.64, 1, 0.9, 1, 0.78]
            let top = sheet.minY + 256
            for k in 0..<5 {
                let x = left + CGFloat(k) * (column + gap)
                for (i, share) in widths.enumerated() {
                    let full = column * (k == 4 && i > 12 ? share * 0.5 : share)
                    let inked = min(full, max(0, rollerX - x))
                    guard inked > 0 else { continue }
                    page.fill(Path(CGRect(x: x, y: top + CGFloat(i) * 14, width: inked, height: 3)),
                              with: .color(c.ink2.opacity(fade)))
                }
            }

            // The reader's line: the third column's seventh.
            let lineX = left + 2 * (column + gap), lineY = top + 6 * 14 + 1.5
            let mark = M.stretch(p, 0.64, 0.72)
            let markWidth = (column + 34) * M.easeOut(mark)
            for y in [lineY - 6.5, lineY + 5] {
                page.fill(Path(CGRect(x: lineX - 10, y: y, width: markWidth, height: 1.5)),
                          with: .color(c.accent.opacity(mark * fade)))
            }
            let pin: Double
            if p < 0.68 { pin = 0 }
            else if p < 0.75 { pin = 1.35 * M.easeOut(M.stretch(p, 0.68, 0.75)) }
            else { pin = 1.35 - 0.35 * M.stretch(p, 0.75, 0.80) }
            let r = 4.5 * pin
            page.fill(Path(ellipseIn: CGRect(x: lineX - 17.5 - r, y: lineY - r, width: 2 * r, height: 2 * r)),
                      with: .color(c.bluesky.opacity(fade)))
            // "You were here", on a tab beside it.
            let tag = M.stretch(p, 0.72, 0.78) * fade
            if tag > 0 {
                let label = page.resolve(Text("YOU WERE HERE").font(.system(size: 11, weight: .semibold)).tracking(1.2)
                    .foregroundStyle(c.accent))
                let size = label.measure(in: CGSize(width: 400, height: 40))
                let x = lineX + column + 30 - 6 * (1 - tag)
                let capsule = CGRect(x: x, y: lineY - size.height / 2 - 4, width: size.width + 20, height: size.height + 8)
                page.drawLayer { tab in
                    tab.opacity = tag
                    tab.fill(Path(roundedRect: capsule, cornerRadius: capsule.height / 2), with: .color(c.paper))
                    tab.stroke(Path(roundedRect: capsule, cornerRadius: capsule.height / 2), with: .color(c.accent), lineWidth: 1.5)
                    tab.draw(label, at: CGPoint(x: capsule.midX, y: capsule.midY), anchor: .center)
                }
            }
            // The roller, sweeping across the page as it prints.
            let roller = M.stretch(p, 0, 0.04) * (1 - M.stretch(p, 0.60, 0.64))
            page.fill(Path(CGRect(x: rollerX, y: sheet.minY, width: 6, height: sheet.height)), with: .color(c.ink.opacity(roller)))
        }
    }

    // MARK: Ribbon

    /// The iPhone and the Mac side by side: the bookmark on the phone's row
    /// lifts and flies across, and the Mac's timeline runs on to that row.
    static func ribbon(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        let p = M.loop(t, 4.8)
        let fade = 1 - M.stretch(p, 0.90, 1)
        let dots = [c.rss, c.bluesky, c.mastodon]
        let order = [1, 0, 2, 1, 1, 0, 2, 0, 1, 1, 0, 2, 2, 0, 1, 2]
        let first: [CGFloat] = [88, 72, 94, 66, 80, 90, 70, 84, 76, 92, 68, 86, 74, 90, 64, 82]
        let second: [CGFloat] = [56, 64, 48, 70, 52, 60, 44, 66, 58, 50, 62, 46, 68, 54, 60, 48]

        // The iPhone, on the row the reader left it.
        let phone = CGRect(x: 170, y: 90, width: 220, height: 440)
        let phoneShape = Path(roundedRect: phone, cornerRadius: 34)
        g.drawLayer { layer in
            layer.clip(to: phoneShape)
            let band = CGRect(x: phone.minX, y: phone.minY + 224, width: phone.width, height: 46)
            let held = 1 - 0.65 * M.stretch(p, 0.40, 0.60)
            layer.fill(Path(band), with: .color(c.wash.opacity(held)))
            for y in [band.minY, band.maxY - 1] {
                layer.fill(Path(CGRect(x: band.minX, y: y, width: band.width, height: 1)), with: .color(c.rule.opacity(held)))
            }
            for row in 0..<8 {
                let i = row + 5
                let top = phone.minY + 40 + CGFloat(row) * 46
                let x = phone.minX + 18, w: CGFloat = phone.width - 36 - 17
                layer.fill(Path(ellipseIn: CGRect(x: x, y: top + 19.5, width: 7, height: 7)), with: .color(dots[order[i]]))
                layer.fill(Path(CGRect(x: x + 17, y: top + 16, width: w * first[i] / 100, height: 4)), with: .color(c.ink))
                layer.fill(Path(CGRect(x: x + 17, y: top + 25, width: w * second[i] / 100, height: 3)), with: .color(c.ink2.opacity(0.7)))
                layer.fill(Path(CGRect(x: x, y: top + 45, width: phone.width - 36, height: 1)), with: .color(c.rule))
            }
        }
        g.stroke(phoneShape, with: .color(c.ink2), lineWidth: 1.5)
        text(&g, "IPHONE", size: 11, weight: .semibold, tracking: 1.8, color: c.ink2, at: CGPoint(x: phone.midX, y: 555))

        // The Mac's timeline runs on and stops with that row in the band.
        let mac = CGRect(x: 560, y: 90, width: 550, height: 440)
        let band = CGRect(x: mac.minX, y: mac.minY + 168, width: mac.width, height: 56)
        let found = M.stretch(p, 0.54, 0.64) * fade
        g.fill(Path(band), with: .color(c.wash.opacity(found)))
        for y in [band.minY, band.maxY - 1] {
            g.fill(Path(CGRect(x: band.minX, y: y, width: band.width, height: 1)), with: .color(c.rule.opacity(found)))
        }
        let offset = -336 * M.easeOutQuint(M.stretch(p, 0.18, 0.56))
        g.drawLayer { layer in
            layer.clip(to: Path(mac))
            layer.opacity = fade
            for i in 0..<16 {
                let top = mac.minY + CGFloat(i) * 56 + offset
                guard top > mac.minY - 56, top < mac.maxY else { continue }
                let x = mac.minX + 28, w = mac.width - 56 - 23
                layer.fill(Path(ellipseIn: CGRect(x: x, y: top + 23.5, width: 9, height: 9)), with: .color(dots[order[i]]))
                layer.fill(Path(CGRect(x: x + 23, y: top + 14, width: w * 0.22, height: 3)), with: .color(c.ink2.opacity(0.55)))
                layer.fill(Path(CGRect(x: x + 23, y: top + 24, width: w * first[i] / 100, height: 5)), with: .color(c.ink))
                layer.fill(Path(CGRect(x: x + 23, y: top + 36, width: w * second[i] / 100, height: 4)), with: .color(c.ink2.opacity(0.7)))
                layer.fill(Path(CGRect(x: x, y: top + 55, width: mac.width - 56, height: 1)), with: .color(c.rule))
            }
            // The rows fade in and out at the top and bottom.
            layer.fill(Path(CGRect(x: mac.minX, y: mac.minY, width: mac.width, height: 70)),
                       with: .linearGradient(Gradient(colors: [c.paper, c.paper.opacity(0)]),
                                             startPoint: CGPoint(x: 0, y: mac.minY), endPoint: CGPoint(x: 0, y: mac.minY + 70)))
            layer.fill(Path(CGRect(x: mac.minX, y: mac.maxY - 70, width: mac.width, height: 70)),
                       with: .linearGradient(Gradient(colors: [c.paper.opacity(0), c.paper]),
                                             startPoint: CGPoint(x: 0, y: mac.maxY - 70), endPoint: CGPoint(x: 0, y: mac.maxY)))
        }
        for x in [mac.minX, mac.maxX - 1] {
            g.fill(Path(CGRect(x: x, y: mac.minY, width: 1, height: mac.height)), with: .color(c.rule))
        }
        text(&g, "THIS MAC", size: 11, weight: .semibold, tracking: 1.8, color: c.ink2, at: CGPoint(x: mac.midX, y: 555))

        // The bookmark's way across, dotted.
        var trail = Path()
        trail.move(to: CGPoint(x: 360, y: 330))
        trail.addQuadCurve(to: CGPoint(x: 1089, y: 274), control: CGPoint(x: 730, y: 40))
        let trailOpacity = 0.6 * M.stretch(p, 0.12, 0.24) * (1 - M.stretch(p, 0.70, 0.84))
        g.stroke(trail, with: .color(c.accent.opacity(trailOpacity)),
                 style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 7]))

        // The bookmark: lifts off the phone, arcs over, and lands.
        let across = M.easeInOut(M.stretch(p, 0.12, 0.56))
        let x = 1080 - 730 * (1 - across)
        let y: Double
        if p < 0.12 { y = 56 }
        else if p < 0.34 { y = 56 - 206 * M.easeOut(M.stretch(p, 0.12, 0.34)) }
        else if p < 0.56 { y = -150 + 150 * M.easeIn(M.stretch(p, 0.34, 0.56)) }
        else if p < 0.60 { y = -8 * M.easeOut(M.stretch(p, 0.56, 0.60)) }
        else { y = -8 + 8 * M.easeIn(M.stretch(p, 0.60, 0.64)) }
        var bookmark = Path()
        bookmark.move(to: CGPoint(x: 0, y: 0))
        bookmark.addLine(to: CGPoint(x: 20, y: 0))
        bookmark.addLine(to: CGPoint(x: 20, y: 44))
        bookmark.addLine(to: CGPoint(x: 10, y: 35))
        bookmark.addLine(to: CGPoint(x: 0, y: 44))
        bookmark.closeSubpath()
        g.fill(bookmark.offsetBy(dx: x, dy: 252 + y), with: .color(c.accent.opacity(fade)))

        title(&g, .ribbon, y: 626, c: c)
    }

    // MARK: Masthead

    /// The masthead across the window: "Influx" inks in letter by letter,
    /// a rule runs under it with the three dots riding its head, and the
    /// edition's columns print faintly below.
    static func masthead(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        let left: CGFloat = 120, width: CGFloat = 1040
        let date = Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        text(&g, date.uppercased(), size: 12, weight: .semibold, tracking: 2.4, color: c.ink2,
             at: CGPoint(x: left, y: 72), anchor: .leading)
        text(&g, "EDITION FOR THIS MAC", size: 12, weight: .semibold, tracking: 2.4, color: c.ink2,
             at: CGPoint(x: left + width, y: 72), anchor: .trailing)
        g.fill(Path(CGRect(x: left, y: 92, width: width, height: 1)), with: .color(c.ink))

        // "Influx", each letter inking in after the last.
        // Each letter sits where it sits in the whole word, measured by
        // its prefix, so the word keeps its own spacing and kerning.
        let word = Array("Influx")
        let font = Font.system(size: 220, weight: .semibold, design: .serif)
        let bounds = CGSize(width: 2000, height: 400)
        var edges: [CGFloat] = [0]
        for n in 1...word.count {
            edges.append(g.resolve(Text(String(word.prefix(n))).font(font)).measure(in: bounds).width)
        }
        let letters = word.map { g.resolve(Text(String($0)).font(font).foregroundStyle(c.ink)) }
        let start = 640 - edges[word.count] / 2
        for (i, letter) in letters.enumerated() {
            let p = M.loop(t, 3.6, delay: 0.09 * Double(i))
            let k = M.easeOut(M.stretch(p, 0, 0.20))
            let gone = M.stretch(p, 0.86, 1)
            let point = CGPoint(x: start + edges[i], y: 205 + 18 * (1 - k))
            g.drawLayer { layer in
                layer.opacity = k * (1 - gone)
                let blur = 10 * (1 - k) + 3 * gone
                if blur > 0.1 { layer.addFilter(.blur(radius: blur)) }
                layer.draw(letter, at: point, anchor: .leading)
            }
        }

        // The running rule, the source dots riding its head.
        g.fill(Path(CGRect(x: left, y: 318, width: width, height: 1)), with: .color(c.ink))
        g.fill(Path(CGRect(x: left, y: 323, width: width, height: 4)), with: .color(c.rule))
        let run = M.loop(t, 1.8)
        let head = width * M.easeInOut(M.stretch(run, 0, 0.7))
        let running = 1 - M.stretch(run, 0.7, 1)
        g.fill(Path(CGRect(x: left, y: 323, width: head, height: 4)), with: .color(c.ink.opacity(running)))
        for (i, color) in [c.rss, c.bluesky, c.mastodon].enumerated() {
            let cx = left + head - 12 - 18 * CGFloat(i)
            guard cx > left else { continue }
            g.fill(Path(ellipseIn: CGRect(x: cx - 6, y: 319, width: 12, height: 12)), with: .color(color.opacity(running)))
        }
        g.fill(Path(CGRect(x: left, y: 331, width: width, height: 1)), with: .color(c.ink))

        text(&g, "Syncing in Progress", size: 38, design: .serif, italic: true, color: c.ink, at: CGPoint(x: 640, y: 380))
        text(&g, SyncingScene.masthead.caption, size: 16, color: c.ink2, at: CGPoint(x: 640, y: 418))

        // The edition underneath, printing faintly.
        let gap: CGFloat = 28
        let column = (width - 5 * gap) / 6
        let widths: [CGFloat] = [1, 0.92, 1, 0.84, 1, 0.96, 0.70]
        for k in 0..<6 {
            for (i, share) in widths.enumerated() {
                let p = M.loop(t, 3.6, delay: 0.5 + 0.12 * Double(k) + 0.05 * Double(i))
                let inked = column * share * M.easeOut(M.stretch(p, 0, 0.24))
                let opacity = 0.22 * M.stretch(p, 0, 0.24) * (1 - M.stretch(p, 0.86, 1))
                g.fill(Path(CGRect(x: left + CGFloat(k) * (column + gap), y: 456 + CGFloat(i) * 14, width: inked, height: 3)),
                       with: .color(c.ink.opacity(opacity)))
            }
        }
    }

    // MARK: Three slips

    /// The sync mark across the window: rings ripple out, the dots circle
    /// twice trailing tails, and drop into the tray one after another.
    static func threeSlips(_ g: inout GraphicsContext, t: Double, c: SyncingPalette) {
        let center = CGPoint(x: 640, y: 250)
        for i in 0..<3 {
            let p = M.loop(t, 3.2, delay: 1.05 * Double(i))
            guard p > 0 else { continue }
            let r = 700 * (0.12 + 0.88 * M.easeOut(p))
            let opacity = 0.9 * M.stretch(p, 0, 0.10) * (1 - p)
            g.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(c.ink2.opacity(opacity)), lineWidth: 1)
        }
        let radius: CGFloat = 110
        g.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)),
                 with: .color(c.rule), style: StrokeStyle(lineWidth: 1, dash: [2, 6]))

        let p = M.loop(t, 4.2)
        let fade = 1 - M.stretch(p, 0.92, 1)
        var tray = Path()
        tray.move(to: CGPoint(x: 500, y: 380))
        tray.addLine(to: CGPoint(x: 500, y: 455))
        tray.addQuadCurve(to: CGPoint(x: 515, y: 470), control: CGPoint(x: 500, y: 470))
        tray.addLine(to: CGPoint(x: 765, y: 470))
        tray.addQuadCurve(to: CGPoint(x: 780, y: 455), control: CGPoint(x: 780, y: 470))
        tray.addLine(to: CGPoint(x: 780, y: 380))
        g.stroke(tray.trimmedPath(from: 0, to: M.easeOut(M.stretch(p, 0, 0.16))), with: .color(c.ink.opacity(fade)),
                 style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))

        let turn = 4 * Double.pi * M.easeInOut(M.stretch(p, 0, 0.55))
        let grow = M.easeOut(M.stretch(p, 0, 0.08))
        let tails = M.stretch(p, 0.06, 0.14) * (1 - M.stretch(p, 0.46, 0.54))
        let dots: [(angle: Double, color: Color, falls: Double, depth: Double)] = [
            (-Double.pi / 2, c.bluesky, 0.55, 308),
            (Double.pi * 5 / 6, c.rss, 0.58, 143),
            (Double.pi / 6, c.mastodon, 0.61, 143),
        ]
        for dot in dots {
            let angle = dot.angle + turn
            // The tail, fading behind the way it turns.
            for (k, (r, opacity)) in [(11.0, 0.45), (9.0, 0.3), (7.0, 0.18), (5.0, 0.1)].enumerated() {
                let a = angle - Double(k + 1) * Double.pi / 20
                let point = CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
                g.fill(Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(dot.color.opacity(opacity * tails)))
            }
            let x = center.x + radius * cos(angle)
            let y = center.y + radius * sin(angle) + fall(p, from: dot.falls, depth: dot.depth)
            let r = 14 * grow
            g.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)), with: .color(dot.color.opacity(fade)))
        }
        title(&g, .threeSlips, y: 554, c: c)
        footer(&g, y: 714, c: c)
    }

    /// How far a dot that drops at `start` has fallen at `p`: down `depth`,
    /// a bounce, and still.
    static func fall(_ p: Double, from start: Double, depth: Double) -> Double {
        if p < start { return 0 }
        if p < start + 0.11 { return depth * M.easeIn(M.stretch(p, start, start + 0.11)) }
        if p < start + 0.15 { return depth - 14 * M.easeOut(M.stretch(p, start + 0.11, start + 0.15)) }
        if p < start + 0.19 { return depth - 14 + 14 * M.easeIn(M.stretch(p, start + 0.15, start + 0.19)) }
        return depth
    }
}
