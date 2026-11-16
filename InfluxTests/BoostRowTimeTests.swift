import Foundation
import Testing
import InfluxKit
@testable import Influx

/// A boosted row shows when its post was written, then a rocket and when it
/// was boosted: "Sun 8:46 PM 🚀 9:58 PM" (#270). The late arrow is only for
/// a row placed after its boost too.
@Suite struct BoostRowTimes {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let type = Typography(scale: 1)
    private let clock = Date.FormatStyle.dateTime.hour().minute()
    private let day = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()

    private func boost(_ id: String, written: Date, boosted: Date, fetched: Date, by booster: String = "Ben",
                       source: String = "social", boosterID: String? = nil) -> Item {
        Item(sourceID: source, remoteID: id, kind: .post, mergeKey: "social/\(id)", authorName: "Ana",
             authorHandle: "@ana@example.social", body: id, publishedAt: written, fetchedAt: fetched, sortDate: boosted,
             boostedBy: booster, boostedByID: boosterID ?? "https://example.social/@\(booster)")
    }

    private func post(_ id: String, at date: Date, fetched: Date) -> Item {
        Item(sourceID: "social", remoteID: id, kind: .post, mergeKey: "social/\(id)", authorName: "Ana",
             authorHandle: "@ana@example.social", body: id, publishedAt: date, fetchedAt: fetched)
    }

    private func store() async throws -> InfluxStore {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [
            Source(id: "social", kind: .mastodonHome, title: "Social", colorIndex: 1),
            Source(id: "rich", kind: .sammyFeed, title: "Rich", colorIndex: 2),
        ])
        return store
    }

    private func refresh(_ store: InfluxStore, _ items: [Item], at now: Date) async throws {
        let state = try await store.fetchState(sourceID: "social")
        let request = FetchRequest(direction: .newer, cursor: state?.newerCursor, notBefore: now.addingTimeInterval(-7 * 86_400), now: now)
        let page = FetchedPage(items: items, newer: Cursor(rawValue: "n\(now.timeIntervalSince1970)"), older: Cursor(rawValue: "o"))
        _ = try await store.record(page, for: request, sourceID: "social")
    }

    @Test func aBoostShowsWhenItWasWrittenThenARocketAndTheBoost() async throws {
        let store = try await store()
        let written = t0, boosted = t0 + 4_320
        try await store.insert([boost("a", written: written, boosted: boosted, fetched: boosted + 5)])
        let row = try #require(try await store.rows().first)
        #expect(RowText.boostDate(row) == boosted)
        #expect(RowText.receivedDate(row) == nil)
        #expect(RowText.time(row, type).string == " · \(written.formatted(day)) 🚀 \(boosted.formatted(clock))")
        #expect(RowText.contextLine(row) == "Boosted by Ben")
        #expect(RowText.accessibilityLabel(row).contains("boosted \(boosted.formatted(clock))"))
    }

    @Test func aBoostWithinAMinuteOfItsPostShowsOneTime() async throws {
        let store = try await store()
        try await store.insert([boost("a", written: t0, boosted: t0 + 30, fetched: t0 + 40)])
        let row = try #require(try await store.rows().first)
        #expect(RowText.boostDate(row) == nil)
        #expect(RowText.time(row, type).string == " · \(t0.formatted(day))")
    }

    /// A boost that arrives after the reader has passed its boost time
    /// sits below their line (ADR 0041): rocket, then the late arrow.
    @Test func aLateBoostShowsTheBoostThenWhereItSits() async throws {
        let store = try await store()
        try await refresh(store, [post("a", at: t0 + 600, fetched: t0 + 1_810), post("c", at: t0 + 1_800, fetched: t0 + 1_810)], at: t0 + 1_810)
        let c = try #require(try await store.rows().first { $0.body == "c" })
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (c.sortDate, c.mergeKey)))
        try await refresh(store, [boost("b", written: t0, boosted: t0 + 1_200, fetched: t0 + 2_400)], at: t0 + 2_400)
        let b = try #require(try await store.rows().first { $0.body == "b" })
        let received = try #require(RowText.receivedDate(b))
        #expect(RowText.boostDate(b) == t0 + 1_200)
        let line = try #require(RowText.laterLine(b, type)).string
        #expect(line == "🚀 \((t0 + 1_200).formatted(clock)) → \(received.formatted(clock))")
    }

    /// One person's boost reaching a rich post's row again from its bridged
    /// copy, under the bridge's ID, is named once.
    @Test func aBoosterSeenInTwoCopiesIsNamedOnce() async throws {
        let store = try await store()
        try await store.insert([
            boost("a", written: t0, boosted: t0 + 600, fetched: t0 + 610, by: "Bob", source: "rich", boosterID: "https://x.example/bob"),
            boost("a", written: t0, boosted: t0 + 620, fetched: t0 + 630, by: "Bob", boosterID: "https://bridge.example/users/bob"),
        ])
        let row = try #require(try await store.rows().first)
        #expect(row.boostedBy == ["Bob"])
        #expect(RowText.contextLine(row) == "Boosted by Bob")
        // The bridged copy dates the boost: a rich repost has no time of its own.
        #expect(RowText.boostDate(row) == t0 + 620)
    }
}
