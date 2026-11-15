import Foundation
import GRDB
import Synchronization

/// A timeline that is on a screen, as the store knows it: the view it
/// shows and the last row the reader can see there. A new row that would
/// land at or above that row goes directly below it instead (ADR 0041), so
/// nothing arrives above the viewport or between two rows on screen.
///
/// InfluxKit has no UI, so the timeline says what it shows: `show(downTo:)`
/// whenever its last row on screen changes, and `close()` when it leaves
/// the screen for good. It is kept in memory only, and goes with the
/// timeline that holds it.
public final class TimelineOnScreen: Sendable {
    private let viewID: String
    private let timelines: OnScreenTimelines

    init(viewID: String, timelines: OnScreenTimelines) {
        self.viewID = viewID
        self.timelines = timelines
    }

    /// Says that the last row with any part on the screen is the one at
    /// `position` (`TimelineRow.sortDate`); nil when no row is shown.
    public func show(downTo position: Date?) {
        timelines.set(position.map { ScreenBottom(viewID: viewID, position: $0) }, for: ObjectIdentifier(self))
    }

    /// The timeline has left the screen.
    public func close() {
        timelines.set(nil, for: ObjectIdentifier(self))
    }

    deinit {
        timelines.set(nil, for: ObjectIdentifier(self))
    }
}

/// The last row on screen in one view.
struct ScreenBottom: Sendable, Hashable {
    var viewID: String
    var position: Date
}

/// What every timeline on a screen shows last, for one store.
final class OnScreenTimelines: Sendable {
    private let shown = Mutex<[ObjectIdentifier: ScreenBottom]>([:])

    func set(_ bottom: ScreenBottom?, for timeline: ObjectIdentifier) {
        shown.withLock { $0[timeline] = bottom }
    }

    var bottoms: [ScreenBottom] {
        shown.withLock { Array($0.values) }
    }
}

/// Where the rows of one stored page may go (ADR 0041). A new row is placed
/// by its own time unless that is at or above its line, and then directly
/// below the line.
///
/// A row's line is the furthest along of three things, over every view
/// that shows the row: the view's last-read marker (what the reader has
/// read), its reading place when that row is stored here (where the view
/// opens), and the last row on a screen showing the view now. The views
/// that show a row are All, each saved view that includes its source, and
/// Bookmarks when it arrives bookmarked. A view that doesn't show the row
/// never holds it down.
///
/// It is read once for a page: the markers, the places and the saved
/// views, none of which grows with the timeline.
struct PlacementLine {
    /// The furthest of each view's marker, place and last row on screen.
    private let furthest: [String: Date]
    /// The sources of each saved view that has such a point.
    private let views: [(id: String, sourceIDs: Set<String>)]
    /// The merge keys among the page's that have Influx's own bookmark.
    private let ownBookmarks: Set<String>
    private let sourceKinds: [String: Source.Kind]
    /// Each source's line, once worked out; nil inside for none.
    private var lines: [String: Date?] = [:]
    /// The last position given directly below each line, so the rows held
    /// there go a millisecond apart, in the order they are placed.
    private var lastBelow: [Date: Date] = [:]

    init(_ db: Database, onScreen: [ScreenBottom], placing items: [Item], sourceKinds: [String: Source.Kind]) throws {
        var furthest: [String: Date] = [:]
        func reach(_ viewID: String, _ position: Date) {
            furthest[viewID] = max(furthest[viewID] ?? position, position)
        }
        // A marker always carries this store's date for its row.
        for row in try Row.fetchAll(db, sql: "SELECT viewID, sortDate FROM lastReadMarker") {
            reach(row["viewID"], row["sortDate"])
        }
        // A place whose row isn't here names somewhere this device hasn't
        // caught up to: the rows on the way to it keep their own times.
        for row in try Row.fetchAll(db, sql: """
            SELECT readingPlace.viewID, timelinePosition.sortDate FROM readingPlace
            JOIN timelinePosition ON timelinePosition.mergeKey = readingPlace.mergeKey
            """) {
            reach(row["viewID"], row["sortDate"])
        }
        for bottom in onScreen {
            reach(bottom.viewID, bottom.position)
        }
        self.furthest = furthest
        self.sourceKinds = sourceKinds
        guard !furthest.isEmpty else {
            views = []
            ownBookmarks = []
            return
        }
        views = try SavedView.fetchAll(db).filter { furthest[$0.id] != nil }.map { ($0.id, Set($0.sourceIDs)) }
        if furthest[SavedView.bookmarksID] != nil {
            ownBookmarks = try Set(String.fetchAll(db, SQLRequest<String>(literal: """
                SELECT mergeKey FROM articleBookmark WHERE isBookmarked = 1 AND mergeKey IN \(Array(Set(items.map(\.mergeKey))))
                """)))
        } else {
            ownBookmarks = []
        }
    }

    /// Where a new row would go, and the line it goes below when that is
    /// not its own time.
    struct Position {
        var date: Date
        var below: Date?
    }

    /// Where a new row shown from `item` goes: its own time, or directly
    /// below its line when that is later.
    mutating func position(of item: Item) -> Position {
        guard let line = line(of: item) else { return Position(date: item.placement) }
        let below = (lastBelow[line] ?? line).addingTimeInterval(0.001)
        return item.placement < below ? Position(date: below, below: line) : Position(date: item.placement)
    }

    /// Says that a row was placed at `position`, so the next row held
    /// below the same line goes after it.
    mutating func placed(at position: Position) {
        guard let line = position.below else { return }
        lastBelow[line] = position.date
    }

    private mutating func line(of item: Item) -> Date? {
        let line: Date?
        if let known = lines[item.sourceID] {
            line = known
        } else {
            var points = views.filter { $0.sourceIDs.contains(item.sourceID) }.compactMap { furthest[$0.id] }
            if let all = furthest[SavedView.allID] { points.append(all) }
            line = points.max()
            lines[item.sourceID] = .some(line)
        }
        guard isInBookmarks(item), let bookmarks = furthest[SavedView.bookmarksID] else { return line }
        return max(line ?? bookmarks, bookmarks)
    }

    /// Whether the Bookmarks view shows `item` as it arrives
    /// (`InfluxStore.inBookmarks`).
    private func isInBookmarks(_ item: Item) -> Bool {
        if item.viewer?.bookmarked == true { return true }
        guard item.kind == .article || sourceKinds[item.sourceID] == .sammyFeed else { return false }
        return ownBookmarks.contains(item.mergeKey)
    }
}
