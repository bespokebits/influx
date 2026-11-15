import Foundation
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private func row(_ key: String, body: String = "Text", boostedBy: [String] = []) -> TimelineRow {
    TimelineRow(
        id: 1, kind: .post, mergeKey: key, sourceID: "s", sourceTitle: "Source", colorIndex: 0,
        authorName: "Ana Ruiz", authorHandle: "@ana", title: nil, body: body, url: nil,
        publishedAt: t0, sortDate: t0, boostedBy: boostedBy, replyToHandle: nil,
        linkCard: nil, media: [], quote: nil, isRead: false, viewer: nil, links: []
    )
}

@Suite struct TimelineDiffs {
    @Test func firstLoadInsertsEverythingAndAppendsNothing() {
        let diff = TimelineDiff(from: [], to: [row("a"), row("b")])
        #expect(diff.inserted == [0, 1])
        #expect(diff.appendedAtEnd == 0)
        #expect(diff.removed.isEmpty)
    }

    @Test func newerRowsCountAsAppended() {
        let diff = TimelineDiff(from: [row("a"), row("b")], to: [row("a"), row("b"), row("c"), row("d")])
        #expect(diff.inserted == [2, 3])
        #expect(diff.appendedAtEnd == 2)
    }

    @Test func rowsPlacedAmongOlderOnesAreInsertedNotAppended() {
        let diff = TimelineDiff(from: [row("a"), row("c")], to: [row("a"), row("b"), row("c"), row("d")])
        #expect(diff.inserted == [1, 3])
        #expect(diff.appendedAtEnd == 1)
    }

    @Test func aNewBoostChangesTheRowWithoutReplacingIt() {
        let diff = TimelineDiff(from: [row("a")], to: [row("a", boostedBy: ["Sam Okafor"])])
        #expect(diff.inserted.isEmpty)
        #expect(diff.changed == [0])
    }

    @Test func goneRowsAreRemoved() {
        let diff = TimelineDiff(from: [row("a"), row("b"), row("c")], to: [row("a"), row("c")])
        #expect(diff.removed == ["b"])
        #expect(diff.isEmpty == false)
        #expect(TimelineDiff(from: [row("a")], to: [row("a")]).isEmpty)
    }

    @Test func swappingUnchangedRowsIsAChange() {
        let diff = TimelineDiff(from: [row("a"), row("b"), row("c")], to: [row("b"), row("a"), row("c")])
        #expect(diff.reordered)
        #expect(diff.isEmpty == false)
        #expect(diff.inserted.isEmpty && diff.changed.isEmpty && diff.removed.isEmpty)
        // Inserts and removals alone don't reorder what is kept.
        #expect(TimelineDiff(from: [row("a"), row("b"), row("c")], to: [row("a"), row("x"), row("c")]).reordered == false)
    }
}

@Suite struct SeedBatches {
    @Test func newerBatchesFollowTheDateAndNeverCollide() async throws {
        let store = try InfluxStore.inMemory()
        try await SeedFeed.load(into: store, count: 100)
        let last = try #require(try await store.rows().last)
        let first = SeedFeed.newer(count: 20, after: last.sortDate, batch: 1)
        let second = SeedFeed.newer(count: 20, after: last.sortDate, batch: 2)
        #expect(first.allSatisfy { $0.sortDate > last.sortDate })
        let before = try await store.rows().count
        #expect(try await store.insert(first) == 20)
        #expect(try await store.insert(second) == 20)
        // Every item is a row of its own: the "N newer" pill counts rows.
        #expect(try await store.rows().count == before + 40)
        #expect(try await store.rows().suffix(5).allSatisfy { $0.sortDate > last.sortDate })
    }
}
