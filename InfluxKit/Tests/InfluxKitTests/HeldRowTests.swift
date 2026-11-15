import Foundation
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private func row(_ key: String, at minutes: Double) -> TimelineRow {
    TimelineRow(
        id: 1, kind: .post, mergeKey: key, sourceID: "s", sourceTitle: "Source", colorIndex: 0,
        authorName: "Ana Ruiz", authorHandle: "@ana", title: nil, body: "Text", url: nil,
        publishedAt: t0, sortDate: t0.addingTimeInterval(minutes * 60), boostedBy: [], replyToHandle: nil,
        linkCard: nil, media: [], quote: nil, isRead: false, viewer: nil, links: []
    )
}

/// Which row the timeline holds still when its rows change.
@Suite struct HeldRows {
    /// Eight rows a minute apart, with "c", "d" and "e" on the screen.
    let rows = ["a", "b", "c", "d", "e", "f", "g", "h"].enumerated().map { row($1, at: Double($0)) }
    let visible = 2..<5

    /// The row to hold once the rows named in `moved` have gone to `minute`
    /// and those in `gone` have left.
    private func held(moved: Set<String> = [], to minute: Double = -30, gone: Set<String> = []) -> String? {
        var now: [String: TimelineRow] = [:]
        for shown in rows where !gone.contains(shown.mergeKey) {
            now[shown.mergeKey] = moved.contains(shown.mergeKey) ? row(shown.mergeKey, at: minute) : shown
        }
        return HeldRow.choose(in: rows, visible: visible) { now[$0] }.map { rows[$0].mergeKey }
    }

    @Test func theTopRowIsHeldWhenItStayed() {
        #expect(held() == "c")
        // Rows going elsewhere change its index, not where it is.
        #expect(held(gone: ["a", "h"]) == "c")
        #expect(held(moved: ["a", "e"]) == "c")
    }

    @Test func aTopRowThatMovedGivesWayToTheNextThatStayed() {
        #expect(held(moved: ["c"]) == "d")
        #expect(held(moved: ["c"], to: 90) == "d")
        #expect(held(moved: ["c", "d"]) == "e")
    }

    @Test func aTopRowThatHasGoneGivesWayToo() {
        #expect(held(gone: ["c"]) == "d")
    }

    @Test func withNothingLeftOnTheScreenTheNearestRowBelowIsHeldThenTheNearestAbove() {
        #expect(held(moved: ["c", "d", "e"]) == "f")
        #expect(held(moved: ["c", "d", "e", "f"], gone: ["g"]) == "h")
        #expect(held(moved: ["c", "d", "e", "f", "g", "h"]) == "b")
        #expect(held(moved: ["c", "d", "e"], gone: ["b", "f", "g", "h"]) == "a")
    }

    @Test func noRowIsHeldWhenNoneStayed() {
        #expect(held(gone: Set(rows.map(\.mergeKey))) == nil)
        #expect(HeldRow.choose(in: [], visible: 0..<0) { _ in nil } == nil)
    }
}

/// The same between two pretend devices, as it went wrong on a phone
/// (influx-dev #125): the row at the top of the reader's screen was one
/// that sync then moved hours up the timeline. The screen went with it, and
/// the reader's next pause there was saved as the place for every device.
@Suite struct MovedRowsOnScreen {
    private let moved = "post:boosted"

    /// One post, as a device sees it when someone boosts it at `minute`.
    private func boosted(at minute: Double, by booster: String) -> Item {
        let date = simStart.addingTimeInterval(minute * 60)
        return Item(
            sourceID: "mastodon:@me@example.social:home", remoteID: "boost-\(booster)", kind: .post, mergeKey: moved,
            authorName: "Ana Ruiz", authorHandle: "@ana", body: "Boosted",
            publishedAt: simStart.addingTimeInterval(-3_600), fetchedAt: date, sortDate: date, boostedBy: booster
        )
    }

    @Test func aTopRowThatSyncMovesDoesNotTakeTheReaderBack() async throws {
        let server = InMemorySyncServer()
        let clock = SimClock()
        let mac = try SimDevice("mac", server: server, clock: clock)
        let phone = try SimDevice("phone", server: server, clock: clock)
        try await mac.fetch(0..<20)
        try await phone.fetch(0..<20)

        // The Mac sees a post first, boosted between minutes 5 and 6, and
        // tells iCloud where it put it.
        try await mac.store.insert([boosted(at: 5.5, by: "Ben")])
        try await mac.sync()
        // The phone hasn't heard. It sees the post when someone else boosts
        // it at minute 30, and puts it there, with the posts that follow.
        try await phone.store.insert([boosted(at: 30, by: "Cal")])
        try await phone.fetch(31..<40)
        #expect(phone.screen.rows[20].mergeKey == moved)

        // The reader reads down to the post after it, which is saved as the
        // place, with the boosted post still at the top of the screen,
        // mostly scrolled past.
        clock.advance(by: 5)
        phone.scroll(to: 21)
        try await phone.pause()
        phone.screen.top = 20
        #expect(try await phone.storedPlace()?.mergeKey == simKey(31))

        // Sync settles on the Mac's position, and the post goes there.
        try await phone.sync()
        #expect(phone.screen.rows.firstIndex { $0.mergeKey == moved } == 6)
        // The reader is still where they were, on the rows that stayed.
        #expect(phone.screen.rows[phone.screen.top + 1].mergeKey == simKey(31))
        #expect(try await phone.storedPlace()?.mergeKey == simKey(31))

        // And reading on from there is what every device takes.
        clock.advance(by: 5)
        phone.scroll(to: phone.screen.top + 2)
        try await phone.pause()
        try await phone.sync()
        try await mac.sync()
        #expect(try await mac.storedPlace()?.mergeKey == simKey(32))
    }
}
