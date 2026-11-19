import Foundation
import Testing
@testable import InfluxKit

/// Each row keeps a history of why it sits where it does: the rule that
/// placed it, the line that held it, the copies that joined it, and the
/// positions from iCloud that moved it (influx-dev#285).
@Suite struct RowHistories {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    private func item(_ source: String, _ id: String, at date: Date, fetched: Date, key: String? = nil) -> Item {
        Item(sourceID: source, remoteID: id, kind: .post, mergeKey: key ?? "\(source)/\(id)",
             authorName: source, authorHandle: "", body: id, url: "https://example.com/\(id)", publishedAt: date, fetchedAt: fetched)
    }

    private func store() async throws -> InfluxStore {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [
            Source(id: "social", kind: .mastodonHome, title: "Social", colorIndex: 0),
            Source(id: "other", kind: .mastodonHome, title: "Other", colorIndex: 1),
        ])
        return store
    }

    private func refresh(_ store: InfluxStore, _ source: String, _ items: [Item], at now: Date) async throws {
        let state = try await store.fetchState(sourceID: source)
        let request = FetchRequest(direction: .newer, cursor: state?.newerCursor, notBefore: now.addingTimeInterval(-7 * 86_400), now: now)
        let page = FetchedPage(items: items, newer: Cursor(rawValue: "n\(now.timeIntervalSince1970)"), older: Cursor(rawValue: "o"))
        _ = try await store.record(page, for: request, sourceID: source)
    }

    private func events(_ store: InfluxStore, _ key: String) async throws -> [RowEvent] {
        try await store.rowHistory(mergeKey: key).events
    }

    @Test func aFirstFetchPlacesByOwnTimeWithNoLine() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0, fetched: t0 + 60)], at: t0 + 60)
        let event = try #require(try await events(store, "social/a").first)
        #expect(event.kind == .placed)
        #expect(event.how == .ownTime)
        #expect(event.via == .firstFetch)
        #expect(event.lineDate == nil)
        #expect(event.sortDate == t0)
        #expect(event.fetchedAt == t0 + 60)
        #expect(!event.offered)
        #expect(!event.isNotable)
    }

    @Test func aLateRowSaysWhichMarkerHeldIt() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0 + 600, fetched: t0 + 700)], at: t0 + 700)
        let a = try #require(try await store.rows().first)
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (a.sortDate, a.mergeKey)))
        // b was written before a, but arrives after the reader read a.
        try await refresh(store, "social", [item("social", "b", at: t0 + 300, fetched: t0 + 10_000)], at: t0 + 10_000)
        let event = try #require(try await events(store, "social/b").first)
        #expect(event.how == .belowLine)
        #expect(event.via == .refresh)
        #expect(event.lineView == SavedView.allID)
        #expect(event.lineBound == "marker")
        #expect(event.lineDate == a.sortDate)
        #expect(event.sortDate == a.sortDate.addingTimeInterval(0.001))
        #expect(event.publishedAt == t0 + 300)
        #expect(event.fetchedAt == t0 + 10_000)
        #expect(event.offered)
        #expect(event.isNotable)
        #expect(event.line.contains("by belowLine"))
        #expect(event.line.contains("line all marker at"))
    }

    @Test func aRowOnScreenSaysTheScreenHeldIt() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0 + 600, fetched: t0 + 700)], at: t0 + 700)
        let a = try #require(try await store.rows().first)
        let screen = store.timelineOnScreen(viewID: SavedView.allID)
        screen.show(downTo: a.sortDate)
        try await refresh(store, "social", [item("social", "b", at: t0 + 300, fetched: t0 + 900)], at: t0 + 900)
        let event = try #require(try await events(store, "social/b").first)
        #expect(event.how == .belowLine)
        #expect(event.lineBound == "screen")
        screen.close()
    }

    @Test func aRowAfterTheLineRecordsTheLineThatDidNotHoldIt() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0 + 600, fetched: t0 + 700)], at: t0 + 700)
        let a = try #require(try await store.rows().first)
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (a.sortDate, a.mergeKey)))
        try await refresh(store, "social", [item("social", "b", at: t0 + 800, fetched: t0 + 900)], at: t0 + 900)
        let event = try #require(try await events(store, "social/b").first)
        #expect(event.how == .ownTime)
        #expect(event.lineDate == a.sortDate)
        #expect(!event.isNotable)
    }

    @Test func aCopyFromAnotherSourceJoinsWithoutMoving() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0, fetched: t0 + 60, key: "post:a")], at: t0 + 60)
        try await refresh(store, "other", [item("other", "a2", at: t0, fetched: t0 + 3_600, key: "post:a")], at: t0 + 3_600)
        let history = try await store.rowHistory(mergeKey: "post:a")
        #expect(history.events.map(\.kind) == [.placed, .joined])
        #expect(history.events[1].sourceID == "other")
        #expect(history.events[1].sortDate == t0)
        #expect(history.copies.map(\.sourceID) == ["social", "other"])
        #expect(history.copies.map(\.isShown) == [true, false])
        #expect(history.copies[1].fetchedAt == t0 + 3_600)
        #expect(history.sortDate == t0)
        // A row shown from a preferred copy marks that copy.
        let shownOther = try await store.rowHistory(mergeKey: "post:a", shownItemID: try await itemID(store, "other", "a2"))
        #expect(shownOther.copies.map(\.isShown) == [false, true])
    }

    private func itemID(_ store: InfluxStore, _ source: String, _ remoteID: String) async throws -> Int64 {
        try #require(try await store.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT id FROM item WHERE sourceID = ? AND remoteID = ?", arguments: [source, remoteID])
        })
    }

    @Test func aJoiningCopySaysOfferedOnlyWhenItQueuedAnOffer() async throws {
        let store = try await store()
        // a is placed at its fetch time, before its date, so it is offered.
        try await refresh(store, "social", [item("social", "a", at: t0 + 3_600, fetched: t0 + 60, key: "post:a")], at: t0 + 60)
        // A copy that would place the row elsewhere finds the offer already queued.
        try await refresh(store, "other", [item("other", "a2", at: t0 + 3_600, fetched: t0 + 900, key: "post:a")], at: t0 + 900)
        let events = try await events(store, "post:a")
        #expect(events.map(\.kind) == [.placed, .joined])
        #expect(events[0].offered)
        #expect(!events[1].offered)
    }

    private func position(_ key: String, sortDate: Date, placedAt: Date) throws -> FetchedSyncRecord {
        let payload = try SyncCoding.encode(TimelinePositionPayload(mergeKey: key, sortDate: sortDate, placedAt: placedAt),
                                            for: .timelinePosition)
        return FetchedSyncRecord(record: SyncRecord(type: .timelinePosition, key: key, payload: payload), systemFields: Data("1".utf8))
    }

    @Test func aPositionFromICloudThatArrivedFirstPlacesTheRow() async throws {
        let store = try await store()
        _ = try await store.mergeSyncRecords([position("post:a", sortDate: t0 + 500, placedAt: t0 + 600)])
        try await store.insert([item("social", "a", at: t0, fetched: t0 + 1_000, key: "post:a")])
        let history = try await store.rowHistory(mergeKey: "post:a")
        #expect(history.events.first?.how == .iCloud)
        #expect(history.events.first?.via == .direct)
        #expect(history.sortDate == t0 + 500)
        #expect(history.positionInICloud)
    }

    @Test func aPositionFromICloudThatWinsLaterMovesTheRow() async throws {
        let store = try await store()
        try await store.insert([item("social", "a", at: t0 + 3_600, fetched: t0 + 900, key: "post:a")])
        // Another device stored the row earlier, at its own fetch time.
        _ = try await store.mergeSyncRecords([position("post:a", sortDate: t0 + 600, placedAt: t0 + 600)])
        let history = try await store.rowHistory(mergeKey: "post:a")
        #expect(history.events.map(\.kind) == [.placed, .moved])
        #expect(history.events[1].previous == t0 + 900)
        #expect(history.events[1].sortDate == t0 + 600)
        #expect(history.events[1].isNotable)
    }

    @Test func aStreamedRowSaysItCameFromAStream() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0, fetched: t0 + 60)], at: t0 + 60)
        let source = try #require(try await store.source(id: "social"))
        _ = try await Refresher(store: store).recordStreamed([item("social", "b", at: t0 + 120, fetched: t0 + 130)], for: source,
                                                             now: t0 + 130, advancing: { $0 })
        #expect(try await events(store, "social/b").first?.via == .stream)
    }

    @Test func theHistoryGoesWithTheRowsLastItem() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0, fetched: t0)], at: t0)
        #expect(try await store.rowEvents(since: .distantPast).count == 1)
        try await store.prune(now: t0 + 400 * 86_400)
        #expect(try await store.rowEvents(since: .distantPast).isEmpty)
    }

    @Test func theTextNamesEveryCopyAndEvent() async throws {
        let store = try await store()
        try await refresh(store, "social", [item("social", "a", at: t0, fetched: t0 + 60)], at: t0 + 60)
        let text = try await store.rowHistory(mergeKey: "social/a").text
        #expect(text.contains("Row social/a"))
        #expect(text.contains("* Social [mastodonHome] a"))
        #expect(text.contains("https://example.com/a"))
        #expect(text.contains("placed social/a"))
    }
}
