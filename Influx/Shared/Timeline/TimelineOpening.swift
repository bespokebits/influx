// What a timeline opens with, read before its view exists. The app starts
// the read as soon as the store opens, so it runs alongside the shell's
// setup instead of after it. Given the environment the timeline will most
// likely have, it also lays out the rows around where the timeline opens
// and draws the first screen of them, so the view only has to show them.
import CoreGraphics
import Foundation
import InfluxKit
import os
#if canImport(UIKit)
import UIKit
#endif

struct TimelineOpening: Sendable {
    var marker: LastReadMarker?
    /// Where the reader was last, on any device: the timeline opens there
    /// when it has one, and on the first row after the marker otherwise.
    var place: ReadingPlace?
    var rows: [TimelineRow]
    /// The opening window laid out, and its first screen drawn, ahead.
    var prepared: Prepared?

    struct Prepared: Sendable {
        /// What it was laid out for; used only if the view matches.
        var environment: RowEnvironment
        /// The opening window's rows as read; a later read may differ.
        var rows: [TimelineRow]
        /// One per row in `rows`.
        var geometries: [RowGeometry]
        var images: [RowImage]
    }

    /// The environment a full-screen timeline will have, and the height of
    /// its screen, or nil where that can't be told ahead: the Mac's window,
    /// and an iPhone's first launch.
    static func expectedEnvironment(defaults: UserDefaults = .standard) -> (RowEnvironment, CGFloat)? {
        #if os(iOS)
        // No window or scene exists this early in launch, and iOS reaches
        // the screen only through one, so the last launch's timeline stands
        // in. If anything differs now, the timeline lays out as usual.
        guard let data = defaults.data(forKey: LastScreen.key),
              let last = try? JSONDecoder().decode(LastScreen.self, from: data) else { return nil }
        return (RowEnvironment(width: last.width, scale: last.scale, dark: last.dark,
                               typography: Typography(scale: last.textScale)),
                last.height)
        #else
        return nil
        #endif
    }

    #if os(iOS)
    /// Keeps the full-screen timeline's environment for the next launch's
    /// `expectedEnvironment`. Writes only when it changed.
    static func remember(_ environment: RowEnvironment, screenHeight: CGFloat, defaults: UserDefaults = .standard) {
        let screen = LastScreen(width: environment.width, height: screenHeight, scale: environment.scale,
                                dark: environment.dark, textScale: environment.typography.scale)
        guard let data = try? JSONEncoder().encode(screen), data != defaults.data(forKey: LastScreen.key) else { return }
        defaults.set(data, forKey: LastScreen.key)
    }

    private struct LastScreen: Codable {
        static let key = "timelineLastScreen"
        var width: CGFloat
        var height: CGFloat
        var scale: CGFloat
        var dark: Bool
        var textScale: CGFloat
    }
    #endif

    /// How many rows either side of the opening row are laid out and shown
    /// first, before the rest: enough to fill the screen and scroll a little.
    static let windowRadius = 40

    /// The row a timeline opens with at the top of the screen; the rule is
    /// InfluxKit's, with the rest of the reading place's.
    static func openingRow(in rows: [TimelineRow], place: ReadingPlace?, marker: LastReadMarker?) -> Int? {
        ReadingPosition.openingRow(in: rows, place: place, marker: marker)
    }

    /// The rows shown first: those around the opening row, or the newest.
    static func window(in rows: [TimelineRow], place: ReadingPlace?, marker: LastReadMarker?) -> Range<Int> {
        let center = openingRow(in: rows, place: place, marker: marker) ?? rows.count - 1
        return max(0, center - windowRadius)..<min(rows.count, center + windowRadius + 1)
    }

    /// Reads the marker, place and rows at once, off the main thread, and prepares
    /// the opening window for `expected` if given.
    static func read(from store: InfluxStore, viewID: String = SavedView.allID,
                     expected: (RowEnvironment, CGFloat)? = nil) -> Pending {
        let pending = Pending(viewID: viewID)
        pending.task = Task.detached(priority: .userInitiated) { [result = pending.result] in
            async let marker = try? store.lastReadMarker(viewID: viewID)
            async let place = try? store.readingPlace(viewID: viewID)
            async let rows = try? store.rows(inView: viewID)
            var opening = await TimelineOpening(marker: marker, place: place, rows: rows ?? [])
            LaunchClock.mark("read")
            if case let (environment, screenHeight)? = expected, !opening.rows.isEmpty {
                opening.prepared = await prepare(opening, environment: environment, screenHeight: screenHeight)
                LaunchClock.mark("prepared")
            }
            let finished = opening
            result.withLock { $0 = finished }
            return finished
        }
        return pending
    }

    /// A read under way. Its result can be taken without waiting once it's
    /// done, so a view that finds it ready opens in the same main-thread
    /// turn instead of waiting for another one.
    final class Pending: @unchecked Sendable {
        /// The saved view it read.
        let viewID: String
        fileprivate let result = OSAllocatedUnfairLock<TimelineOpening?>(initialState: nil)
        /// Set once, before the pending read is handed out.
        fileprivate var task: Task<TimelineOpening, Never>?

        fileprivate init(viewID: String) {
            self.viewID = viewID
        }

        var ready: TimelineOpening? { result.withLock { $0 } }

        var value: TimelineOpening {
            get async { await task!.value }
        }
    }

    /// Lays out the window and draws the rows the first screen will show:
    /// down from the opening row, or up from the newest at the bottom.
    private static func prepare(_ opening: TimelineOpening, environment: RowEnvironment,
                                screenHeight: CGFloat) async -> Prepared {
        let window = window(in: opening.rows, place: opening.place, marker: opening.marker)
        let rows = Array(opening.rows[window])
        let geometries = RowLayout.geometries(for: rows, in: environment)
        let start = openingRow(in: rows, place: opening.place, marker: opening.marker) ?? rows.count
        var first: [Int] = []
        var height: CGFloat = 0
        var index = start
        while index < rows.count, height < screenHeight {
            first.append(index)
            height += geometries[index].height
            index += 1
        }
        // Near the end the view clamps to the bottom, showing rows above.
        index = start - 1
        while index >= 0, height < screenHeight {
            first.append(index)
            height += geometries[index].height
            index -= 1
        }
        let images = await withTaskGroup(of: RowImage?.self) { group in
            for index in first {
                let row = rows[index], geometry = geometries[index]
                group.addTask { RowRenderer.render(row, geometry: geometry, in: environment) }
            }
            var images: [RowImage] = []
            for await image in group { if let image { images.append(image) } }
            return images
        }
        return Prepared(environment: environment, rows: rows, geometries: geometries, images: images)
    }
}
