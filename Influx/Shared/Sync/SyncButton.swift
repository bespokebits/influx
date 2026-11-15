import SwiftUI

/// The sync button in the timeline's bar: the Full Circle ring
/// (`RingMark`), showing iCloud sync's state. Tapping it syncs now, or
/// tries again after a failure, and opens the sync status panel.
struct SyncButton: View {
    let sync: Sync
    @State private var showsStatus = false

    var body: some View {
        let phase = sync.status.phase
        Button {
            sync.tapped()
            showsStatus = true
        } label: {
            RingMarkView(phase: phase.ring)
                .frame(width: 24, height: 24)
        }
        .accessibilityLabel("Sync")
        .accessibilityValue(phase.spoken)
        .accessibilityHint(phase.isFailed ? "Tries again and shows sync status" : "Syncs with your other devices now and shows sync status")
        .help(phase.spoken)
        .accessibilityIdentifier("sync-button")
        .popover(isPresented: $showsStatus) {
            SyncStatusView(sync: sync)
                .presentationCompactAdaptation(.popover)
        }
    }
}

extension SyncStatus.Phase {
    var mark: SlipsMark.Phase {
        switch self {
        case .starting: .starting
        case .syncing: .syncing
        case .synced: .synced
        case .failed: .failed
        }
    }

    var ring: RingMark.Phase {
        switch self {
        case .starting: .starting
        case .syncing: .syncing
        case .synced: .synced
        case .failed: .failed
        }
    }

    var spoken: String {
        switch self {
        case .starting: "Starting"
        case .syncing: "Syncing"
        case .synced: "Up to date"
        case .failed(let reason): "Couldn't sync. \(reason)"
        }
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// Draws `SlipsMark`, moving only while a phase is in motion: once a
/// phase settles, its timeline pauses and the last frame stays.
struct SlipsMarkView: View {
    let phase: SlipsMark.Phase
    /// Whether the first phase moves from the start, with the dots where
    /// the start-up leaves them, rather than showing as it already is.
    var entering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = Clock()
    /// When the phase whose motion has finished began, so a later run of
    /// the same phase moves again.
    @State private var settledSince: Date?

    var body: some View {
        let clock = clock.moved(to: phase, entering: entering, reduceMotion: reduceMotion)
        let settled = settledSince == clock.since
        TimelineView(.animation(paused: settled)) { context in
            Canvas { gc, size in
                let elapsed = settled ? .greatestFiniteMagnitude : context.date.timeIntervalSince(clock.since)
                Self.draw(SlipsMark.frame(clock.phase, elapsed: elapsed, from: clock.from, reduceMotion: reduceMotion),
                          in: &gc, size: size)
            }
        }
        .accessibilityHidden(true)
        .task(id: clock.since) {
            guard let settle = SlipsMark.settleTime(clock.phase) else { return }
            let since = clock.since
            let left = settle - Date.now.timeIntervalSince(since)
            if left > 0 { try? await Task.sleep(for: .seconds(left + 0.05)) }
            if !Task.isCancelled { settledSince = since }
        }
    }

    /// When the current phase began, and where the dots were then.
    @MainActor
    final class Clock {
        private(set) var phase: SlipsMark.Phase = .starting
        private(set) var since = Date.distantPast
        private(set) var from: [CGPoint]?
        private var started = false

        func moved(to next: SlipsMark.Phase, entering: Bool, reduceMotion: Bool) -> Clock {
            let now = Date.now
            if !started {
                // A window opened after launch shows the state as it is,
                // without replaying how it got there.
                started = true
                phase = next
                since = next == .starting || entering ? now : .distantPast
            } else if next != phase {
                let elapsed = now.timeIntervalSince(since)
                from = SlipsMark.frame(phase, elapsed: elapsed, from: from, reduceMotion: reduceMotion).dots.map(\.center)
                phase = next
                since = now
            }
            return self
        }
    }

    private static let sources = [0, 1, 3].map { Color.paint(Broadsheet.sourceColor($0)) }

    static func draw(_ frame: SlipsMark.Frame, in gc: inout GraphicsContext, size: CGSize) {
        gc.scaleBy(x: size.width / 24, y: size.height / 24)
        let ink = Color.paint(Broadsheet.ink), alarm = Color.paint(Broadsheet.alarm)

        if frame.trayOpacity > 0, frame.trayDrawn > 0 {
            let anchor = SlipsMark.trayAnchor
            let squash = CGAffineTransform(translationX: anchor.x, y: anchor.y + frame.trayOffset)
                .scaledBy(x: frame.trayScale.width, y: frame.trayScale.height)
                .translatedBy(x: -anchor.x, y: -anchor.y)
            let tray = Path(SlipsMark.trayPath()).trimmedPath(from: 0, to: frame.trayDrawn).applying(squash)
            gc.stroke(tray, with: .color(ink.opacity(frame.trayOpacity)),
                      style: StrokeStyle(lineWidth: SlipsMark.trayStroke, lineCap: .round, lineJoin: .round))
        }

        if frame.barOpacity > 0 {
            let top = SlipsMark.barTop, bottom = SlipsMark.barBottom
            let middle = CGPoint(x: (top.x + bottom.x) / 2, y: (top.y + bottom.y) / 2)
            let half = (bottom.y - top.y) / 2 * frame.barScale.height
            var bar = Path()
            bar.move(to: CGPoint(x: middle.x, y: middle.y - half))
            bar.addLine(to: CGPoint(x: middle.x, y: middle.y + half))
            gc.stroke(bar, with: .color(alarm.opacity(frame.barOpacity)),
                      style: StrokeStyle(lineWidth: SlipsMark.barWidth * frame.barScale.width, lineCap: .round))
        }

        if frame.pointScale > 0 {
            let r = SlipsMark.dotRadius * frame.pointScale
            gc.fill(Path(ellipseIn: CGRect(x: SlipsMark.point.x - r, y: SlipsMark.point.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(alarm))
        }

        for (i, dot) in frame.dots.enumerated() where dot.opacity > 0 && dot.radius > 0 {
            let color = dot.alarm > 0 ? sources[i].mix(with: alarm, by: Double(dot.alarm)) : sources[i]
            let r = dot.radius
            gc.fill(Path(ellipseIn: CGRect(x: dot.center.x - r, y: dot.center.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(color.opacity(dot.opacity)))
        }
    }
}

extension Color {
    /// A Broadsheet colour, light and dark.
    static func paint(_ color: PlatformColor) -> Color {
        #if canImport(UIKit)
        Color(uiColor: color)
        #else
        Color(nsColor: color)
        #endif
    }
}

/// Draws `RingMark`, moving only while a phase is in motion: once a
/// phase settles, its timeline pauses and the last frame stays.
struct RingMarkView: View {
    let phase: RingMark.Phase
    /// Whether the first phase moves from the start rather than showing
    /// as it already is.
    var entering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var clock = Clock()
    /// When the phase whose motion has finished began, so a later run of
    /// the same phase moves again.
    @State private var settledSince: Date?

    var body: some View {
        let clock = clock.moved(to: phase, entering: entering, reduceMotion: reduceMotion)
        let settled = settledSince == clock.since
        TimelineView(.animation(paused: settled)) { context in
            Canvas { gc, size in
                let elapsed = settled ? .greatestFiniteMagnitude : context.date.timeIntervalSince(clock.since)
                Self.draw(RingMark.frame(clock.phase, elapsed: elapsed, fromAngle: clock.fromAngle, reduceMotion: reduceMotion),
                          in: &gc, size: size)
            }
        }
        .accessibilityHidden(true)
        .task(id: clock.since) {
            guard let settle = RingMark.settleTime(clock.phase, reduceMotion: reduceMotion) else { return }
            let since = clock.since
            let left = settle - Date.now.timeIntervalSince(since)
            if left > 0 { try? await Task.sleep(for: .seconds(left + 0.05)) }
            if !Task.isCancelled { settledSince = since }
        }
    }

    /// When the current phase began, and where the chase had turned to then.
    @MainActor
    final class Clock {
        private(set) var phase: RingMark.Phase = .starting
        private(set) var since = Date.distantPast
        private(set) var fromAngle: Double = 0
        private var started = false

        func moved(to next: RingMark.Phase, entering: Bool, reduceMotion: Bool) -> Clock {
            let now = Date.now
            if !started {
                // A window opened after launch shows the state as it is,
                // without replaying how it got there.
                started = true
                phase = next
                since = next == .starting || entering ? now : .distantPast
            } else if next != phase {
                if phase == .starting || phase == .syncing {
                    fromAngle = RingMark.chaseAngle(now.timeIntervalSince(since), reduceMotion: reduceMotion)
                }
                phase = next
                since = now
            }
            return self
        }
    }

    private static let sources = [0, 1, 3].map { Color.paint(Broadsheet.sourceColor($0)) }

    static func color(_ tint: RingMark.Tint) -> Color {
        switch tint {
        case .ink: .paint(Broadsheet.ink)
        case .ink2: .paint(Broadsheet.ink2)
        case .alarm: .paint(Broadsheet.alarm)
        }
    }

    /// The circle, starting at the top and going clockwise.
    private static let circle = Path { path in
        path.addArc(center: RingMark.center, radius: RingMark.radius,
                    startAngle: .degrees(-90), endAngle: .degrees(270), clockwise: false)
    }

    private static func about(_ scale: CGSize) -> CGAffineTransform {
        let c = RingMark.center
        return CGAffineTransform(translationX: c.x, y: c.y).scaledBy(x: scale.width, y: scale.height)
            .translatedBy(x: -c.x, y: -c.y)
    }

    static func draw(_ frame: RingMark.Frame, in gc: inout GraphicsContext, size: CGSize) {
        gc.scaleBy(x: size.width / 24, y: size.height / 24)
        let line = StrokeStyle(lineWidth: RingMark.stroke, lineCap: .round, lineJoin: .round)
        let tint = color(frame.tint)

        if frame.trackOpacity > 0, frame.trackDrawn > 0 {
            gc.stroke(circle.trimmedPath(from: 0, to: frame.trackDrawn),
                      with: .color(Color.paint(Broadsheet.rule).opacity(frame.trackOpacity)), style: line)
        }

        for i in 0..<3 where frame.arcOpacities[i] > 0 && frame.arcLengths[i] > 0 {
            let start = -90 + frame.chaseAngle + RingMark.arcOffsets[i]
            let arc = Path { path in
                path.addArc(center: RingMark.center, radius: RingMark.radius, startAngle: .degrees(start),
                            endAngle: .degrees(start + Double(frame.arcLengths[i]) * 360), clockwise: false)
            }
            gc.stroke(arc, with: .color(sources[i].opacity(frame.arcOpacities[i])),
                      style: StrokeStyle(lineWidth: RingMark.arcStroke, lineCap: .round))
        }

        if frame.impressionOpacity > 0 {
            let scale = CGSize(width: frame.impressionScale, height: frame.impressionScale)
            gc.stroke(circle.applying(about(scale)), with: .color(tint.opacity(frame.impressionOpacity)), style: line)
        }

        if frame.ringOpacity > 0, frame.ringDrawn > 0 {
            gc.stroke(circle.trimmedPath(from: 0, to: frame.ringDrawn).applying(about(frame.ringScale)),
                      with: .color(tint.opacity(frame.ringOpacity)), style: line)
        }

        if frame.tickOpacity > 0, frame.tickDrawn > 0 {
            var tick = Path()
            tick.addLines(RingMark.tick)
            gc.stroke(tick.trimmedPath(from: 0, to: frame.tickDrawn), with: .color(tint.opacity(frame.tickOpacity)), style: line)
        }

        if frame.exclamationOpacity > 0, frame.exclamationScale > 0 {
            let pop = about(CGSize(width: frame.exclamationScale, height: frame.exclamationScale))
            var bar = Path()
            bar.move(to: RingMark.exclamationTop)
            bar.addLine(to: RingMark.exclamationBottom)
            gc.stroke(bar.applying(pop), with: .color(tint.opacity(frame.exclamationOpacity)), style: line)
            let r = RingMark.exclamationPointRadius, p = RingMark.exclamationPoint
            gc.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)).applying(pop),
                    with: .color(tint.opacity(frame.exclamationOpacity)))
        }
    }
}

/// The pull-to-refresh mark once the reader lets go: the refresh it
/// started, as the sync button draws it. While the reader pulls, iOS
/// draws the ring with layers instead (`PullRingView`), so a scroll event
/// changes no SwiftUI state.
struct PullRefreshMark: View {
    @Observable
    @MainActor
    final class Refresh {
        /// The refresh under way, or nil when there is none.
        var phase: RingMark.Phase?
    }

    let state: Refresh

    var body: some View {
        Group {
            if let phase = state.phase {
                RingMarkView(phase: phase, entering: true)
            }
        }
        .accessibilityHidden(true)
    }
}
