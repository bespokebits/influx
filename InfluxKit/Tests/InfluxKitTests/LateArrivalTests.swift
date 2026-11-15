import Foundation
import Testing
@testable import InfluxKit

/// Once a source has given items, a row a refresh brings goes by its own
/// time, unless that is at or above its line: the furthest the reader has
/// read to or is in any view that shows the row, and the last row on a
/// screen. Then it goes directly below the line (ADR 0041). Rows still show
/// their own time.
@Suite struct LateArrivals {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let news = SavedView(id: "news", name: "News", sourceIDs: ["feed"], sortIndex: 0)
    private let friends = SavedView(id: "friends", name: "Friends", sourceIDs: ["social"], sortIndex: 1)

    private func item(_ source: String, _ id: String, at date: Date, fetched: Date, bookmarked: Bool = false) -> Item {
        Item(sourceID: source, remoteID: id, kind: source == "feed" ? .article : .post, mergeKey: "\(source)/\(id)",
             authorName: source, authorHandle: "", body: id, publishedAt: date, fetchedAt: fetched,
             viewer: bookmarked ? Item.Viewer(liked: false, boosted: false, bookmarked: true) : nil)
    }

    private func store() async throws -> InfluxStore {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [
            Source(id: "feed", kind: .rss, title: "Feed", url: "https://example.com/feed", colorIndex: 0),
            Source(id: "social", kind: .mastodonHome, title: "Social", colorIndex: 1),
        ])
        return store
    }

    private func refresh(_ store: InfluxStore, _ source: String, _ items: [Item], at now: Date, direction: FetchDirection = .newer) async throws {
        let state = try await store.fetchState(sourceID: source)
        let cursor = direction == .newer ? state?.newerCursor : state?.olderCursor
        let request = FetchRequest(direction: direction, cursor: cursor, notBefore: now.addingTimeInterval(-7 * 86_400), now: now)
        let page = FetchedPage(items: items, newer: Cursor(rawValue: "n\(now.timeIntervalSince1970)"), older: Cursor(rawValue: "o"))
        _ = try await store.record(page, for: request, sourceID: source)
    }

    /// A store where each source has given an item: the article x at the
    /// start, and the posts a, b and c, 10, 20 and 30 minutes on.
    private func timeline() async throws -> InfluxStore {
        let store = try await store()
        try await refresh(store, "feed", [item("feed", "x", at: t0, fetched: t0 + 60)], at: t0 + 60)
        try await refresh(store, "social", [
            item("social", "a", at: t0 + 600, fetched: t0 + 1_810),
            item("social", "b", at: t0 + 1_200, fetched: t0 + 1_810),
            item("social", "c", at: t0 + 1_800, fetched: t0 + 1_810),
        ], at: t0 + 1_810)
        return store
    }

    private func row(_ store: InfluxStore, _ body: String) async throws -> TimelineRow {
        try #require(try await store.rows().first { $0.body == body })
    }

    /// The reader has read down to the row `body` in `viewID`.
    private func read(_ store: InfluxStore, to body: String, in viewID: String = SavedView.allID) async throws {
        let row = try await row(store, body)
        #expect(try await store.moveLastReadMarker(viewID: viewID, to: (row.sortDate, row.mergeKey)))
    }

    /// The reader stopped with the row `body` at the top of the screen.
    private func stop(_ store: InfluxStore, at body: String, in viewID: String = SavedView.allID) async throws {
        let row = try await row(store, body)
        _ = try await store.moveReadingPlace(viewID: viewID, to: (row.sortDate, row.mergeKey))
    }

    private func bodies(_ store: InfluxStore) async throws -> [String] {
        try await store.rows().map { $0.body ?? "" }
    }

    private func offeredPositions(_ store: InfluxStore) async throws -> [String] {
        try await store.pendingSyncChanges().filter { $0.type == .timelinePosition }.map(\.name).sorted()
    }

    // MARK: What keeps its own date whatever the reader has read

    @Test func aSourcesFirstItemsKeepTheirOwnDates() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0 + 600, fetched: t0 + 900)], at: t0 + 900)
        try await read(store, to: "a")
        try await refresh(store, "feed", [item("feed", "x", at: t0 + 300, fetched: t0 + 1_000)], at: t0 + 1_000)
        #expect(try await bodies(store) == ["x", "a"])
    }

    @Test func olderPagesKeepTheirOwnDates() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "b", at: t0 + 600, fetched: t0 + 610)], at: t0 + 610)
        try await read(store, to: "b")
        try await refresh(store, "social", [item("social", "a", at: t0, fetched: t0 + 700)], at: t0 + 700, direction: .older)
        #expect(try await bodies(store) == ["a", "b"])
    }

    // MARK: By its own time, below the line

    /// The report: an article dated before a post that arrived first read
    /// below it. Unread rows read in time order.
    @Test func aLateArticleTheReaderHasntReachedGoesByItsOwnTime() async throws {
        let store = try await timeline()
        try await read(store, to: "x")
        // Posted before every post, fetched after them all.
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "y", "a", "b", "c"])
        let late = try await row(store, "y")
        #expect(late.sortDate == t0 + 300)
        #expect(late.postedAt == t0 + 300)
        // At its publish date, where every device puts it: nothing to offer.
        #expect(try await offeredPositions(store).isEmpty)
    }

    @Test func withNothingReadAndNoScreenALateRowGoesByItsOwnTime() async throws {
        let store = try await timeline()
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "y", "a", "b", "c"])
    }

    /// A row whose own time is above what the reader has read goes directly
    /// below it, not at the bottom of the timeline, and shows its own time.
    @Test func aLateArticleTheReaderHasReadPastGoesDirectlyBelowWhatTheyRead() async throws {
        let store = try await timeline()
        try await read(store, to: "a")
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "a", "y", "b", "c"])
        let late = try await row(store, "y")
        #expect(late.sortDate == (t0 + 600).addingTimeInterval(0.001))
        #expect(late.postedAt == t0 + 300)
        // Not where another device would put it, so this device says where.
        #expect(try await offeredPositions(store) == [SyncRecord.name(type: .timelinePosition, key: "feed/y")])
    }

    /// A row dated the same millisecond as the line's row is not below it
    /// by its own time: merge keys would decide, and could put it above.
    @Test func aRowDatedWithTheLineGoesBelowIt() async throws {
        let store = try await timeline()
        try await read(store, to: "a")
        try await refresh(store, "feed", [
            item("feed", "y", at: t0 + 600, fetched: t0 + 1_900),
            item("feed", "z", at: (t0 + 600).addingTimeInterval(0.0004), fetched: t0 + 1_900),
        ], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "a", "y", "z", "b", "c"])
    }

    /// A feed that was down for a day comes back with a day of articles.
    /// Those dated above what the reader has read go below it together, in
    /// the order of their own times; the rest go by their own times. None
    /// lands above the reader, and all of them are unread.
    @Test func manyLateRowsNeverInterleaveAboveWhatTheReaderHasRead() async throws {
        let store = try await timeline()
        try await read(store, to: "b")
        // 300 articles, every 5 minutes, from a day before the start to an
        // hour after it; given newest first, as a feed gives them.
        let articles = (0..<300).map { index in
            item("feed", String(format: "n%03d", index), at: t0 + 3_600 - 300 * Double(299 - index), fetched: t0 + 4_000)
        }
        try await refresh(store, "feed", articles.reversed(), at: t0 + 4_000)

        let rows = try await store.rows()
        let marker = try #require(try await store.lastReadMarker(viewID: SavedView.allID))
        let read = rows.filter { !ReadingPosition.isAfter($0, marker) }
        #expect(read.map(\.body) == ["x", "a", "b"])
        let unread = rows.filter { ReadingPosition.isAfter($0, marker) }
        #expect(unread.count == 301)
        // Dated at or before b: below it, oldest first, and above c.
        let late = articles.filter { $0.publishedAt <= t0 + 1_200 }.map(\.body)
        #expect(late.count == 292)
        #expect(unread.prefix(late.count).map(\.body) == late)
        #expect(unread.prefix(late.count).allSatisfy { $0.sortDate > t0 + 1_200 && $0.sortDate < t0 + 1_201 })
        // Dated after b: by their own times, around c.
        let onTime = unread.dropFirst(late.count)
        #expect(onTime.map(\.sortDate) == onTime.map { $0.postedAt ?? .distantPast })
        #expect(onTime.map(\.sortDate) == onTime.map(\.sortDate).sorted())
        #expect(onTime.contains { $0.body == "c" })
    }

    /// The reading place is where a view opens, and counts when it is
    /// beyond the marker, as after a jump to the newest rows.
    @Test func aReadingPlaceBeyondTheMarkerHoldsALateRow() async throws {
        let store = try await timeline()
        try await read(store, to: "x")
        try await stop(store, at: "b")
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "a", "b", "y", "c"])
    }

    /// Going back up doesn't unread anything: the marker still holds.
    @Test func aReadingPlaceBehindTheMarkerDoesntLowerTheLine() async throws {
        let store = try await timeline()
        try await read(store, to: "b")
        try await stop(store, at: "x")
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "a", "b", "y", "c"])
    }

    /// A place another device set on a row this device doesn't have says
    /// this device hasn't caught up: the rows on the way to it are not
    /// late, and keep their own times.
    @Test func aReadingPlaceWhoseRowIsntHereHoldsNothing() async throws {
        let store = try await timeline()
        try await read(store, to: "x")
        _ = try await store.moveReadingPlace(viewID: SavedView.allID, to: (t0 + 5_000, "social/elsewhere"))
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "y", "a", "b", "c"])
    }

    /// A marker that waited for its row is placed when the row arrives,
    /// where this rule put the row.
    @Test func aMarkerWaitingForALateRowGoesWhereTheRowWent() async throws {
        let store = try await timeline()
        try await read(store, to: "a")
        // Another device read to y, which isn't here yet.
        #expect(try await !store.moveLastReadMarker(viewID: SavedView.allID, to: (t0 + 300, "feed/y")))
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "a", "y", "b", "c"])
        let marker = try #require(try await store.lastReadMarker(viewID: SavedView.allID))
        #expect(marker.mergeKey == "feed/y")
        #expect(marker.sortDate == (try await row(store, "y")).sortDate)
    }

    // MARK: Each view has its own place

    /// The furthest the reader has read in any view that shows the row
    /// holds it: here the saved view of the feed alone, not All.
    @Test func theFurthestReadViewThatShowsTheRowHoldsIt() async throws {
        let store = try await timeline()
        try await store.save(view: news)
        try await refresh(store, "feed", [item("feed", "z", at: t0 + 900, fetched: t0 + 1_850)], at: t0 + 1_850)
        try await read(store, to: "x")
        try await read(store, to: "z", in: news.id)
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "a", "z", "y", "b", "c"])
        #expect(try await store.rows(inView: news.id).map(\.body) == ["x", "z", "y"])
    }

    /// A view that doesn't show the row never holds it down, however far
    /// its reader has read.
    @Test func aViewThatDoesntShowTheRowDoesntHoldIt() async throws {
        let store = try await timeline()
        try await store.save(view: friends)
        try await read(store, to: "x")
        try await read(store, to: "c", in: friends.id)
        try await stop(store, at: "c", in: friends.id)
        let screen = store.timelineOnScreen(viewID: friends.id)
        screen.show(downTo: t0 + 1_800)
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "y", "a", "b", "c"])
        screen.close()
    }

    /// Bookmarks shows a row that arrives bookmarked, by its service or
    /// with Influx's own bookmark, and no other.
    @Test func bookmarksHoldsOnlyRowsThatArriveBookmarked() async throws {
        let store = try await timeline()
        try await read(store, to: "x")
        try await read(store, to: "b", in: SavedView.bookmarksID)
        try await store.setArticle(mergeKey: "feed/own", bookmarked: true)
        try await refresh(store, "social", [
            item("social", "plain", at: t0 + 300, fetched: t0 + 1_900),
            item("social", "kept", at: t0 + 400, fetched: t0 + 1_900, bookmarked: true),
        ], at: t0 + 1_900)
        try await refresh(store, "feed", [
            item("feed", "own", at: t0 + 200, fetched: t0 + 1_950),
            item("feed", "other", at: t0 + 100, fetched: t0 + 1_950),
        ], at: t0 + 1_950)
        // "kept" and "own" share the place just below b, a millisecond on.
        let rows = try await store.rows()
        #expect(rows.map(\.body).filter { $0 != "kept" && $0 != "own" } == ["x", "other", "plain", "a", "b", "c"])
        let below = (t0 + 1_200).addingTimeInterval(0.001)
        #expect(rows.filter { $0.body == "kept" || $0.body == "own" }.map(\.sortDate) == [below, below])
    }

    // MARK: What is on screen

    /// A row never arrives above the last row on a screen, or between two
    /// rows on it: it goes directly below, as the next row out of view.
    @Test func aLateRowGoesDirectlyBelowTheLastRowOnScreen() async throws {
        let store = try await timeline()
        let screen = store.timelineOnScreen(viewID: SavedView.allID)
        screen.show(downTo: t0 + 600)
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "a", "y", "b", "c"])

        // A reader at the bottom sees what they always did: late rows land
        // below the newest row.
        screen.show(downTo: t0 + 1_800)
        try await refresh(store, "feed", [
            item("feed", "w", at: t0 + 700, fetched: t0 + 2_000),
            item("feed", "v", at: t0 + 100, fetched: t0 + 2_000),
        ], at: t0 + 2_000)
        #expect(try await bodies(store) == ["x", "a", "y", "b", "c", "v", "w"])

        // A timeline that shows no rows holds nothing.
        screen.show(downTo: nil)
        try await refresh(store, "feed", [item("feed", "u", at: t0 + 200, fetched: t0 + 2_100)], at: t0 + 2_100)
        #expect(try await bodies(store) == ["x", "u", "a", "y", "b", "c", "v", "w"])
    }

    /// The screen counts with what has been read: whichever is further.
    @Test func theScreenAndWhatIsReadHoldTogether() async throws {
        let store = try await timeline()
        try await read(store, to: "b")
        // The reader went back up to the top.
        let screen = store.timelineOnScreen(viewID: SavedView.allID)
        screen.show(downTo: t0 + 600)
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "a", "b", "y", "c"])
        screen.close()
    }

    /// With no timeline on a screen (at launch, a fetch in the background
    /// with no timeline open), only what has been read holds a row. A
    /// timeline that closed, or went without closing, holds nothing.
    @Test func aTimelineThatHasGoneHoldsNothing() async throws {
        let store = try await timeline()
        var screen: TimelineOnScreen? = store.timelineOnScreen(viewID: SavedView.allID)
        screen?.show(downTo: t0 + 1_800)
        screen?.close()
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        #expect(try await bodies(store) == ["x", "y", "a", "b", "c"])

        screen = store.timelineOnScreen(viewID: SavedView.allID)
        screen?.show(downTo: t0 + 1_800)
        screen = nil
        try await refresh(store, "feed", [item("feed", "z", at: t0 + 400, fetched: t0 + 2_000)], at: t0 + 2_000)
        #expect(try await bodies(store) == ["x", "y", "z", "a", "b", "c"])
    }

    /// Two timelines on screen at once, as in two windows: each holds the
    /// rows its view shows.
    @Test func everyTimelineOnScreenHoldsItsOwnRows() async throws {
        let store = try await timeline()
        try await store.save(view: friends)
        let all = store.timelineOnScreen(viewID: SavedView.allID)
        let side = store.timelineOnScreen(viewID: friends.id)
        all.show(downTo: t0 + 600)
        side.show(downTo: t0 + 1_800)
        try await refresh(store, "feed", [item("feed", "y", at: t0 + 300, fetched: t0 + 1_900)], at: t0 + 1_900)
        try await refresh(store, "social", [item("social", "late", at: t0 + 400, fetched: t0 + 1_950)], at: t0 + 1_950)
        #expect(try await bodies(store) == ["x", "a", "y", "b", "c", "late"])
        all.close()
        side.close()
    }
}
