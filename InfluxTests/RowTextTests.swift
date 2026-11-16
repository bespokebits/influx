import Foundation
import Testing
import InfluxKit
@testable import Influx

/// A boost sits at the time it was boosted. Its header shows when the post
/// was written, then a rocket and when it was boosted (#270).
@Suite struct RowTextTimes {
    private let written = Date(timeIntervalSince1970: 1_800_000_000)
    private let boosted = Date(timeIntervalSince1970: 1_800_090_000)

    private func row(boostedBy: String?, sortDate: Date) async throws -> TimelineRow {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "m", kind: .mastodonHome, title: "Mastodon", colorIndex: 0)])
        try await store.insert([Item(
            sourceID: "m", remoteID: "1", kind: .post, mergeKey: "https://example.social/1",
            authorName: "Ana", authorHandle: "@ana@example.social", body: "Hello",
            publishedAt: written, fetchedAt: boosted.addingTimeInterval(5), sortDate: sortDate, boostedBy: boostedBy
        )])
        return try #require(try await store.rows().first)
    }

    @Test func boostShowsWhenItWasPostedThenBoosted() async throws {
        let row = try await row(boostedBy: "Ben", sortDate: boosted)
        let header = RowText.header(row, Typography(scale: 1)).string
        let day = Date.FormatStyle.dateTime.weekday(.abbreviated).hour().minute()
        #expect(header.hasSuffix("\(written.formatted(day)) 🚀 \(boosted.formatted(day))"))
        #expect(!header.contains("→"))
        #expect(RowText.contextLine(row) == "Boosted by Ben")
    }

    @Test func plainPostShowsWhenItWasWritten() async throws {
        let row = try await row(boostedBy: nil, sortDate: written)
        let header = RowText.header(row, Typography(scale: 1)).string
        #expect(header.hasSuffix(written.formatted(.dateTime.weekday(.abbreviated).hour().minute())))
        #expect(RowText.contextLine(row) == nil)
    }

    /// A row that arrives late, dated above what the reader has read, goes
    /// below it (ADR 0041), and still shows when it was posted, then an
    /// arrow and where it sits (#261).
    @Test func aLateRowHeldBelowWhatWasReadShowsWhenItWasPosted() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "rss", kind: .rss, title: "Feed", url: "https://example.com/feed", colorIndex: 0)])
        func refresh(_ id: String, posted: Date, at now: Date) async throws {
            let cursor = try await store.fetchState(sourceID: "rss")?.newerCursor
            let request = FetchRequest(direction: .newer, cursor: cursor, notBefore: now.addingTimeInterval(-86_400), now: now)
            let item = Item(sourceID: "rss", remoteID: id, kind: .article, mergeKey: "https://example.com/\(id)",
                            authorName: "Feed", authorHandle: "", body: id, publishedAt: posted, fetchedAt: now)
            _ = try await store.record(FetchedPage(items: [item], newer: Cursor(rawValue: id), older: nil), for: request, sourceID: "rss")
        }
        try await refresh("new", posted: boosted, at: boosted + 60)
        let read = try #require(try await store.rows().last)
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (read.sortDate, read.mergeKey)))
        try await refresh("late", posted: written, at: boosted + 120)
        let late = try #require(try await store.rows().last)
        #expect(late.body == "late")
        #expect(late.sortDate > read.sortDate)
        let header = RowText.header(late, Typography(scale: 1)).string
        let received = RowText.laterText(late.sortDate, after: written)
        #expect(header.hasSuffix("\(written.formatted(.dateTime.weekday(.abbreviated).hour().minute())) → \(received)"))
    }
}

/// The notice over the timeline names a feed that has kept failing, or
/// says how many have.
@Suite struct FailingFeedsNoticeText {
    private let since = Date(timeIntervalSince1970: 1_800_000_000)

    private func feed(_ id: String, _ title: String) -> Source {
        Source(id: id, kind: .rss, title: title, url: "https://example.com/\(id)", colorIndex: 0)
    }

    private func states(_ ids: String...) -> [String: SourceFetchState] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            var state = SourceFetchState(sourceID: id)
            state.problem = .offline
            state.problemSince = since
            return (id, state)
        })
    }

    @Test func oneFeedIsNamed() {
        let day = since.formatted(.dateTime.month(.abbreviated).day())
        #expect(FailingFeedsNotice.text([feed("a", "Six Colors")], states: states("a")) == "“Six Colors” not updating since \(day)")
    }

    @Test func severalAreCounted() {
        let day = since.formatted(.dateTime.month(.abbreviated).day())
        #expect(FailingFeedsNotice.text([feed("a", "A"), feed("b", "B")], states: states("a", "b")) == "2 feeds not updating since \(day)")
    }
}

/// A handle on its own line breaks at its dots and server "@", not mid-word.
@Suite struct RowTextHandles {
    @Test func breaksAfterDotsAndBeforeTheServer() {
        #expect(RowText.breakable("@ana@example.social") == "@ana\u{200B}@example.\u{200B}social")
        #expect(RowText.breakable("@ana.bsky.social") == "@ana.\u{200B}bsky.\u{200B}social")
    }
}
