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

private func marker(_ key: String, at minutes: Double) -> LastReadMarker {
    LastReadMarker(viewID: ReadingPosition.allViewID, sortDate: t0.addingTimeInterval(minutes * 60), mergeKey: key, updatedAt: t0)
}

@Suite struct ReadingPositions {
    let rows = [row("a", at: 0), row("b", at: 1), row("c", at: 2), row("d", at: 3)]

    @Test func opensOnTheRowAfterTheMarker() {
        #expect(ReadingPosition.firstRow(after: marker("b", at: 1), in: rows) == 2)
        #expect(ReadingPosition.firstRow(after: marker("a", at: 0), in: rows) == 1)
    }

    @Test func aPrunedMarkerRowStillFindsItsPlace() {
        #expect(ReadingPosition.firstRow(after: marker("gone", at: 1.5), in: rows) == 2)
        #expect(ReadingPosition.firstRow(after: marker("older", at: -10), in: rows) == 0)
    }

    @Test func nothingAfterTheLastRow() {
        #expect(ReadingPosition.firstRow(after: marker("d", at: 3), in: rows) == nil)
        #expect(ReadingPosition.firstRow(after: marker("a", at: 0), in: []) == nil)
    }

    @Test func rowsWithTheSameDateOrderByKeyBytes() {
        // "é" is C3 A9 in UTF-8, so it sorts after "z" in the store.
        let tied = [row("z", at: 0), row("é", at: 0)]
        #expect(ReadingPosition.firstRow(after: marker("z", at: 0), in: tied) == 1)
        #expect(ReadingPosition.firstRow(after: marker("é", at: 0), in: tied) == nil)
    }

    @Test func agreesWithTheStoreOrder() async throws {
        let store = try InfluxStore.inMemory()
        try await SeedFeed.load(into: store, count: 200)
        let stored = try await store.rows()
        let read = stored[120]
        try await store.moveLastReadMarker(viewID: ReadingPosition.allViewID, to: (read.sortDate, read.mergeKey))
        let saved = try #require(try await store.lastReadMarker(viewID: ReadingPosition.allViewID))
        #expect(ReadingPosition.firstRow(after: saved, in: stored) == 121)
    }
}

/// How a device's rows stand for a place set on another device.
@Suite struct PlacesOnAnotherDevicesRows {
    let rows = [row("a", at: 0), row("b", at: 1), row("d", at: 3)]

    private func place(_ key: String, at minutes: Double) -> ReadingPlace {
        ReadingPlace(viewID: ReadingPosition.allViewID, mergeKey: key, sortDate: t0.addingTimeInterval(minutes * 60), updatedAt: t0)
    }

    @Test func aPlacesOwnRowStandsForIt() throws {
        let found = try #require(ReadingPosition.find(place("b", at: 1), in: rows))
        #expect(found.index == 1)
        #expect(found.standing == .ownRow)
    }

    @Test func theNextRowStandsInForAPostThatIsNotHere() throws {
        let found = try #require(ReadingPosition.find(place("c", at: 2), in: rows))
        #expect(found.index == 2)
        #expect(found.standing == .standIn)
    }

    @Test func aPlaceBeyondTheLastRowHasNotBeenReached() throws {
        let found = try #require(ReadingPosition.find(place("e", at: 4), in: rows))
        #expect(found.index == 2)
        #expect(found.standing == .pastTheEnd)
        #expect(ReadingPosition.find(place("e", at: 4), in: []) == nil)
    }

    @Test func furtherAlongGoesByDateThenKey() {
        #expect(place("b", at: 1).isFurtherAlong(than: place("a", at: 0)))
        #expect(!place("a", at: 0).isFurtherAlong(than: place("b", at: 1)))
        #expect(place("b", at: 1).isFurtherAlong(than: place("a", at: 1)))
        #expect(!place("a", at: 1).isFurtherAlong(than: place("a", at: 1)))
    }
}
