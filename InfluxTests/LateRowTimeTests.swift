import Foundation
import Testing
import InfluxKit
@testable import Influx

/// A row that arrived after the reader had passed its time sits below
/// their line (ADR 0041) and shows both times: "Sun 5:11 PM → 5:19 PM" (#261).
@Suite struct LateRowTimes {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let type = Typography(scale: 1)

    private func item(_ id: String, at date: Date, fetched: Date) -> Item {
        Item(sourceID: "social", remoteID: id, kind: .post, mergeKey: "social/\(id)", authorName: "Ana",
             authorHandle: "@ana@example.social", body: id, publishedAt: date, fetchedAt: fetched)
    }

    private func refresh(_ store: InfluxStore, _ items: [Item], at now: Date) async throws {
        let state = try await store.fetchState(sourceID: "social")
        let request = FetchRequest(direction: .newer, cursor: state?.newerCursor, notBefore: now.addingTimeInterval(-7 * 86_400), now: now)
        let page = FetchedPage(items: items, newer: Cursor(rawValue: "n\(now.timeIntervalSince1970)"), older: Cursor(rawValue: "o"))
        _ = try await store.record(page, for: request, sourceID: "social")
    }

    /// Posts a and c, then b, dated between them, arriving after the
    /// reader has read down to c.
    private func rows() async throws -> [String: TimelineRow] {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "social", kind: .mastodonHome, title: "Social", colorIndex: 1)])
        try await refresh(store, [item("a", at: t0 + 600, fetched: t0 + 1_810), item("c", at: t0 + 1_800, fetched: t0 + 1_810)], at: t0 + 1_810)
        let c = try #require(try await store.rows().first { $0.body == "c" })
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (c.sortDate, c.mergeKey)))
        try await refresh(store, [item("b", at: t0 + 1_200, fetched: t0 + 2_400)], at: t0 + 2_400)
        return Dictionary(uniqueKeysWithValues: try await store.rows().map { ($0.body, $0) })
    }

    @Test func aLateRowShowsWhereItSitsAfterItsOwnTime() async throws {
        let rows = try await rows()
        let b = try #require(rows["b"]), c = try #require(rows["c"])
        let received = try #require(RowText.receivedDate(b))
        #expect(abs(received.timeIntervalSince(c.sortDate)) < 0.01)
        #expect(RowText.shownDate(b) == t0 + 1_200)
        let time = RowText.time(b, type).string
        #expect(time == " · \(RowText.shownDate(b).formatted(.dateTime.weekday(.abbreviated).hour().minute())) → \(received.formatted(.dateTime.hour().minute()))")
        #expect(RowText.accessibilityLabel(b).contains("received \(received.formatted(.dateTime.hour().minute()))"))
    }

    @Test func aRowAtItsOwnTimeShowsOneTime() async throws {
        let rows = try await rows()
        for body in ["a", "c"] {
            let row = try #require(rows[body])
            #expect(RowText.receivedDate(row) == nil)
            #expect(!RowText.time(row, type).string.contains("→"))
            #expect(!RowText.accessibilityLabel(row).contains("received"))
        }
    }

    @Test func bothTimesShareTheHeaderAtTheDefaultSize() async throws {
        let b = try #require(try await rows()["b"])
        let environment = RowEnvironment(width: 390, scale: 3, dark: false, typography: type)
        let geometry = RowLayout.geometry(for: b, in: environment)
        #expect(geometry.received == nil)
        #expect(geometry.time.width >= RowLayout.singleLineWidth(RowText.time(b, type)))
    }

    /// At a large text size the received time takes a line of its own, so
    /// neither time is cut.
    @Test func aNarrowHeaderGivesTheReceivedTimeItsOwnLine() async throws {
        let b = try #require(try await rows()["b"])
        let large = Typography(scale: 2.5)
        let environment = RowEnvironment(width: 390, scale: 3, dark: false, typography: large)
        let geometry = RowLayout.geometry(for: b, in: environment)
        let received = try #require(geometry.received)
        #expect(received.minY > geometry.header.maxY && received.maxY < geometry.body.minY)
        #expect(geometry.time.width >= RowLayout.singleLineWidth(RowText.time(b, large, withReceived: false)))
        #expect(!RowText.time(b, large, withReceived: false).string.contains("→"))
        #expect(received.maxX <= environment.width - RowLayout.inset)
        let line = try #require(RowText.receivedLine(b, large))
        #expect(line.string.hasPrefix("→ "))
        #expect(received.height >= Broadsheet.lineHeight(large.meta))
    }

    @Test func aReceivedTimeOnAnotherDayCarriesItsDay() {
        let posted = t0, sameDay = t0 + 480
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: posted)!
        #expect(RowText.receivedText(sameDay, posted: posted) == sameDay.formatted(.dateTime.hour().minute()))
        #expect(RowText.receivedText(nextDay, posted: posted) == nextDay.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
    }
}
