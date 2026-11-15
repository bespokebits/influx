// Captures the sync status panel for the design review in this folder.
//
// Not part of the test suite. For a capture run, copy this file into
// `InfluxTests/`, run the app tests for the platform, collect the images
// from the folder it prints, and delete the copy (see ../README.md).
//
// A dev or test build has no iCloud container, so it never shows the sync
// button. This shows the real `SyncStatusView` over a `Sync` that is never
// started: nothing here loads the sync framework or reaches iCloud. On the
// iPhone the panel is in the system's own popover, hanging from a stand-in
// for the sync button, for screenshots of the simulator. On the Mac the
// panel is drawn alone, in this process: nothing here captures the screen
// or a window, and nothing may, since that asks the person at the Mac for
// screen recording.
import Foundation
import InfluxKit
import SwiftUI
import Testing
@testable import Influx
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

#if canImport(UIKit)

@MainActor
@Observable
private final class CaptureStage {
    var showsPanel = false
    /// The panel as the app has it, or the mock-up of another placement.
    var mockUp = false
}

/// Paper, with a stand-in for the sync button at the top right: the same
/// mark, opening the same panel the same way, without the tap that would
/// start a sync. iPhone only.
private struct PanelHost: View {
    let sync: Sync
    @Bindable var stage: CaptureStage

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.paint(Broadsheet.paper)
                .ignoresSafeArea()
            Button {} label: {
                SlipsMarkView(phase: sync.status.phase.mark)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.glass)
            .popover(isPresented: $stage.showsPanel) {
                if stage.mockUp {
                    QuietCopyPanel(sync: sync)
                        .presentationCompactAdaptation(.popover)
                } else {
                    SyncStatusView(sync: sync)
                        .presentationCompactAdaptation(.popover)
                }
            }
            .padding(.trailing, 16)
        }
    }
}

#endif

/// A mock-up for the review, not in the app: the panel as `SyncStatusView`
/// draws it for a device that is up to date, with Sync Now as its one
/// button and Copy Diagnostics as a quiet line under a rule. Its button
/// does nothing.
private struct QuietCopyPanel: View {
    let sync: Sync

    var body: some View {
        let status = sync.status
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SlipsMarkView(phase: status.phase.mark)
                    .frame(width: 28, height: 28)
                Text("Up to date")
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(Color.paint(Broadsheet.ink))
            }

            VStack(alignment: .leading, spacing: 6) {
                if let last = status.lastSynced {
                    Text("Last synced \(Text(last, style: .relative)) ago")
                }
                Text("Nothing waiting to send")
                Text("Since Influx opened: \(status.sent) changes sent, \(status.received) received")
            }
            .font(.callout)
            .foregroundStyle(Color.paint(Broadsheet.ink2))

            Button("Sync Now") {}

            Divider()
            Button {} label: {
                Label("Copy Diagnostics", systemImage: "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(Color.paint(Broadsheet.ink2))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
    }
}

@MainActor
@Test func captureTheSyncPanel() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "sync-panel-capture")
    try? FileManager.default.removeItem(at: folder)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    print("sync panel capture: \(folder.path)")

    // A device that synced a moment ago, with nothing waiting.
    let sync = Sync(store: try InfluxStore.inMemory(), containerID: "iCloud.com.example.influx")
    sync.status.finished(failure: nil, began: .now)
    sync.status.tally(sent: 4, received: 12)
    sync.status.waiting = 0
    // The mark circles for a moment before it rests.
    try await Task.sleep(for: .seconds(2))
    #expect(sync.status.phase == .synced)

    // The panel has had the copy button, and with it state of its own to
    // say "Copied", since the commit that added it.
    let hasCopy = MemoryLayout<SyncStatusView>.size > MemoryLayout<Sync>.size
    try await capture(sync: sync, hasCopy: hasCopy, into: folder)
    note("done", in: folder)
}

/// Says which state is on screen, for whoever is taking screenshots.
@MainActor
private func note(_ state: String, in folder: URL) {
    try? "\(state)\n".write(to: folder.appending(path: "status.txt"), atomically: true, encoding: .utf8)
}

#if canImport(UIKit)

@MainActor
private func capture(sync: Sync, hasCopy: Bool, into folder: URL) async throws {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = try #require(scenes.first { $0.activationState == .foregroundActive } ?? scenes.first)
    let stage = CaptureStage()
    let window = UIWindow(windowScene: scene)
    window.rootViewController = UIHostingController(rootView: PanelHost(sync: sync, stage: stage))
    window.makeKeyAndVisible()
    defer { window.isHidden = true }

    var pressWorks = true
    for style in [UIUserInterfaceStyle.light, .dark] {
        let name = style == .dark ? "dark" : "light"
        window.overrideUserInterfaceStyle = style
        try await Task.sleep(for: .milliseconds(500))
        stage.showsPanel = true
        try await Task.sleep(for: .seconds(2))
        try shot(of: window).write(to: folder.appending(path: "ios-\(name).png"))
        // Held, so a screenshot of the simulator can be taken too.
        note("ios-\(name)", in: folder)
        try await Task.sleep(for: .seconds(holdSeconds))

        if hasCopy, pressWorks {
            // Someone outside taps Copy Diagnostics; the pasteboard says
            // when. The label reads "Copied" for two seconds after.
            let before = UIPasteboard.general.changeCount
            note("ios-\(name)-press", in: folder)
            let deadline = ContinuousClock.now + .seconds(pressSeconds)
            while UIPasteboard.general.changeCount == before, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            if UIPasteboard.general.changeCount != before {
                try await Task.sleep(for: .milliseconds(450))
                try shot(of: window).write(to: folder.appending(path: "ios-\(name)-copied.png"))
                note("ios-\(name)-copied", in: folder)
                try await Task.sleep(for: .seconds(3))
            } else {
                pressWorks = false
            }
        }
        stage.showsPanel = false
        try await Task.sleep(for: .seconds(1))

        stage.mockUp = true
        stage.showsPanel = true
        try await Task.sleep(for: .seconds(2))
        try shot(of: window).write(to: folder.appending(path: "ios-\(name)-mockup.png"))
        note("ios-\(name)-mockup", in: folder)
        try await Task.sleep(for: .seconds(holdSeconds))
        stage.showsPanel = false
        stage.mockUp = false
        try await Task.sleep(for: .seconds(1))
    }
}

private let holdSeconds = 30
private let pressSeconds = 150

/// The window as the render server draws it, popover and glass included.
@MainActor
private func shot(of window: UIWindow) throws -> Data {
    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    return try #require(image.pngData())
}

#else

/// The panel alone, on the colour of a plain window. On the Mac the
/// pictures are drawn in this process from the views themselves, with no
/// screen or window capture, so the popover the app shows the panel in (its
/// shape, its arrow and the blur behind it) is not in them.
private struct PanelAlone: View {
    let sync: Sync
    let mockUp: Bool

    var body: some View {
        Group {
            if mockUp {
                QuietCopyPanel(sync: sync)
            } else {
                SyncStatusView(sync: sync)
            }
        }
        // As tall as its lines need at the panel's width, as in the popover.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@MainActor
private func capture(sync: Sync, hasCopy: Bool, into folder: URL) async throws {
    let looks: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    for (look, appearance) in looks {
        for mockUp in [false, true] {
            let name = mockUp ? "\(look)-mockup" : look
            let panel = PanelAlone(sync: sync, mockUp: mockUp)
            let size = NSHostingController(rootView: panel).sizeThatFits(in: NSSize(width: 300, height: 2_000))
            let view = NSHostingView(rootView: panel)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = view
            // On screen for a moment, so the views are laid out and drawn
            // as they would be in the app.
            window.orderFrontRegardless()
            try await Task.sleep(for: .seconds(1))
            note("mac-\(name)", in: folder)
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appending(path: "mac-\(name).png"))
            window.close()
        }
    }
}

#endif
