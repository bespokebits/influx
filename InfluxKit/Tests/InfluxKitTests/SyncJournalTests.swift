import Foundation
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

/// A reading place as it arrives from another device.
private func placeFromICloud(_ mergeKey: String, movedAt: Date, move: Int) throws -> FetchedSyncRecord {
    let payload = ReadingPlacePayload(viewID: "all", mergeKey: mergeKey, sortDate: movedAt, updatedAt: movedAt, move: move)
    return FetchedSyncRecord(
        record: SyncRecord(type: .readingPlace, key: "all", payload: try SyncCoding.encode(payload, for: .readingPlace)),
        systemFields: Data()
    )
}

/// The sync journal says what happened to the reader's place, so a timeline
/// that opened in the wrong one can be explained afterwards.
@Suite struct SyncJournalTests {
    @Test func aPlaceSetHereSaysWhyAndWhenItReachedICloud() async throws {
        let store = try InfluxStore.inMemory()
        try await store.moveReadingPlace(viewID: "all", to: (t0, "post:a"), at: t0, because: "the scroll paused, row 3 of 9")
        let set = try #require(try await store.syncJournal().last)
        #expect(set.kind == .place)
        #expect(set.message.contains("post:a"))
        #expect(set.message.contains("the scroll paused, row 3 of 9"))
        #expect(set.message.contains("was none"))

        // Saving the same row again changes nothing, and says nothing.
        try await store.moveReadingPlace(viewID: "all", to: (t0, "post:a"), at: t0.addingTimeInterval(5))
        #expect(try await store.syncJournal().count == 1)

        let change = try #require(try await store.pendingSyncChanges().first { $0.type == .readingPlace })
        let record = try #require(try await store.syncRecordToSend(named: change.name))
        try await store.didSaveSyncRecords([SavedSyncRecord(name: change.name, version: record.version, systemFields: Data())])
        let sent = try #require(try await store.syncJournal().last)
        #expect(sent.kind == .sync)
        #expect(sent.message.contains("ReadingPlace 1"))
        #expect(sent.message.contains("post:a"))
        #expect(!sent.message.contains("still to go"))
    }

    @Test func aMoveMadeWhileAnEarlierOneWentUpIsNotSaidToHaveReachedICloud() async throws {
        let store = try InfluxStore.inMemory()
        try await store.moveReadingPlace(viewID: "all", to: (t0, "post:a"), at: t0)
        let change = try #require(try await store.pendingSyncChanges().first { $0.type == .readingPlace })
        let record = try #require(try await store.syncRecordToSend(named: change.name))

        // The reader moves on before iCloud answers for the first place.
        try await store.moveReadingPlace(viewID: "all", to: (t0.addingTimeInterval(60), "post:b"), at: t0.addingTimeInterval(60))
        try await store.didSaveSyncRecords([SavedSyncRecord(name: change.name, version: record.version, systemFields: Data())])
        let sent = try #require(try await store.syncJournal().last)
        #expect(sent.kind == .sync)
        #expect(sent.message.contains("an earlier place of all"))
        #expect(sent.message.contains("the place here is now post:b"))
        #expect(sent.message.contains("still to go"))
        #expect(try await store.pendingSyncChanges().contains { $0.type == .readingPlace })
    }

    @Test func aPlaceFromICloudSaysWhichSideWon() async throws {
        let store = try InfluxStore.inMemory()
        try await store.moveReadingPlace(viewID: "all", to: (t0, "post:a"), at: t0)
        let record = try #require(try await store.syncRecordToSend(named: SyncRecord.name(type: .readingPlace, key: "all")))
        try await store.didSaveSyncRecords([SavedSyncRecord(name: record.record.name, version: record.version, systemFields: Data())])

        // The move after ours, made on another device: it stands.
        _ = try await store.mergeSyncRecords([try placeFromICloud("post:b", movedAt: t0.addingTimeInterval(60), move: 2)])
        var lines = try await store.syncJournal().filter { $0.kind == .merge }.map(\.message)
        let took = try #require(lines.first { $0.hasPrefix("place of all") })
        #expect(took.contains("took it"))
        #expect(took.contains("ours was post:a, move 1"))
        #expect(took.contains("now post:b, move 2"))
        #expect(lines.contains { $0.hasPrefix("merged 1 record: ReadingPlace 1") && $0.contains("0 of ours won") })

        // An earlier move arriving late: ours stays and goes up again.
        _ = try await store.mergeSyncRecords([try placeFromICloud("post:c", movedAt: t0.addingTimeInterval(120), move: 1)])
        lines = try await store.syncJournal().filter { $0.kind == .merge }.map(\.message)
        let kept = try #require(lines.last { $0.hasPrefix("place of all") })
        #expect(kept.contains("kept ours"))
        #expect(kept.contains("now post:b"))
        #expect(lines.last?.contains("1 of ours won") == true)
    }

    @Test func aMoveThatStaysOnThisDeviceSaysWhy() async throws {
        let store = try InfluxStore.inMemory()
        _ = try await store.mergeSyncRecords([try placeFromICloud("post:m", movedAt: t0.addingTimeInterval(600), move: 4)])
        let move = try await store.moveReadingPlace(viewID: "all", to: (t0, "post:a"), at: t0, knowing: .seen(nil),
                                                    because: "the scroll paused, row 3 of 9")
        #expect(!move.changed)
        let line = try #require(try await store.syncJournal().last { $0.kind == .place })
        #expect(line.message.contains("stays on this device"))
        #expect(line.message.contains("post:m, move 4"))
        #expect(line.message.contains("the scroll paused, row 3 of 9"))
    }

    @Test func linesAreStampedToTheMillisecond() async throws {
        let store = try InfluxStore.inMemory()
        await store.noteInJournal(.timeline, "follow: place post:a", at: t0.addingTimeInterval(0.25))
        let line = try #require(try await store.syncJournal().first?.line)
        #expect(line == "2026-10-26T07:33:20.250Z timeline: follow: place post:a")
    }

    @Test func oldLinesGoAndACopyTakesTheNewest() async throws {
        let store = try InfluxStore.inMemory()
        let now = t0.addingTimeInterval(30 * 86_400)
        // Past the week the journal keeps; the 200th write clears them.
        for n in 1..<SyncJournal.pruneEvery {
            await store.noteInJournal(.app, "old \(n)", at: t0)
        }
        #expect(try await store.syncJournal().count == Int(SyncJournal.pruneEvery) - 1)
        await store.noteInJournal(.app, "new 1", at: now)
        #expect(try await store.syncJournal().map(\.message) == ["new 1"])

        await store.noteInJournal(.app, "new 2", at: now.addingTimeInterval(1))
        await store.noteInJournal(.app, "new 3", at: now.addingTimeInterval(2))
        // The newest two, oldest first.
        #expect(try await store.syncJournal(limit: 2).map(\.message) == ["new 2", "new 3"])
        #expect(try await store.syncJournal(since: now.addingTimeInterval(2)).map(\.message) == ["new 3"])
    }
}
