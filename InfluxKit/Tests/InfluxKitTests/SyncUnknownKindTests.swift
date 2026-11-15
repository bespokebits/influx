import Foundation
import GRDB
import Testing
@testable import InfluxKit

/// What a build does with a synced source of a kind it doesn't know, as an
/// older build does with one a newer build added. It keeps the record as it
/// arrived, and the build that knows the kind reads it when it starts sync
/// (ADR 0029).
@Suite struct SyncUnknownKindTests {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func record(kind: String, id: String) throws -> FetchedSyncRecord {
        let payload: [String: Any] = [
            "source": ["id": id, "kind": kind, "accountID": "s1@sammy.example", "title": "Movies", "url": "https://sammy.example/api/v1/feeds/f1", "colorIndex": 2],
            "modifiedAt": now.timeIntervalSinceReferenceDate,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return FetchedSyncRecord(record: SyncRecord(type: .source, key: id, payload: data), systemFields: Data("fields".utf8))
    }

    @Test func aSourceOfAKindThisBuildDoesNotKnowIsKeptAsItArrivedAndNotSentBack() async throws {
        let store = try InfluxStore.inMemory()
        let unknown = try record(kind: "someFutureKind", id: "future:1")
        let result = try await store.mergeSyncRecords([unknown], at: now)
        #expect(try await store.sources().isEmpty)
        #expect(result.changed.isEmpty)
        #expect(result.toSend.isEmpty)
        #expect(result.unread == 1)
        #expect(try await store.pendingSyncChanges().isEmpty)
        #expect(try await store.syncRecordToSend(named: unknown.record.name) == nil)
        // It says nothing of being from a later version, so a change here
        // to the same record would still go up.
        let kept = try await store.writer.read { try UnreadSyncRecord.fetchAll($0) }
        #expect(kept.map(\.payload) == [unknown.record.payload])
        #expect(kept.map(\.isNewer) == [false])
    }

    /// The device updates to a build that knows the kind: the source the
    /// build before it kept is there once sync starts.
    @Test func aSourceKeptByABuildThatDidNotKnowItsKindIsReadByOneThatDoes() async throws {
        let store = try InfluxStore.inMemory()
        let id = SammyFeedConnector.sourceID(accountID: "s1@sammy.example", feedID: "f1")
        // It arrives a minute after the other device added it.
        let arrived = try record(kind: "someFutureKind", id: id)
        _ = try await store.mergeSyncRecords([arrived], at: now.addingTimeInterval(60))
        #expect(try await store.sources().isEmpty)
        // The store says nothing of its own about a thing it couldn't read.
        #expect(try await store.writer.read { try SyncRecordState.fetchCount($0) } == 0)

        // The update: the same record is now of a kind the build knows.
        let readable = try record(kind: "sammyFeed", id: id)
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE unreadSyncRecord SET payload = ? WHERE recordName = ?", arguments: [readable.record.payload, arrived.record.name])
        }
        let result = try await store.readKeptSyncRecords(at: now.addingTimeInterval(3_600))
        #expect(result.changed == [.source])
        #expect(result.toSend.isEmpty)
        #expect(try await store.sources().map(\.id) == [id])
        #expect(try await store.writer.read { try UnreadSyncRecord.fetchCount($0) } == 0)
        // Read, not changed here: nothing goes back up, and the server's
        // fields that came with it are kept for the next change.
        #expect(try await store.pendingSyncChanges().isEmpty)
        let state = try #require(try await store.writer.read { try SyncRecordState.fetchOne($0, key: arrived.record.name) })
        #expect(state.systemFields == arrived.systemFields)
        #expect(state.modifiedAt == now)
    }

    @Test func aSammyFeedFromAnotherDeviceIsReadAndKept() async throws {
        let store = try InfluxStore.inMemory()
        let id = SammyFeedConnector.sourceID(accountID: "s1@sammy.example", feedID: "f1")
        let result = try await store.mergeSyncRecords([try record(kind: "sammyFeed", id: id)], at: now)
        #expect(result.changed.contains(.source))
        let source = try #require(try await store.sources().first)
        #expect(source.id == id)
        #expect(source.kind == .sammyFeed)
        #expect(source.accountID == "s1@sammy.example")
        #expect(source.url == "https://sammy.example/api/v1/feeds/f1")
    }

    @Test func theSammyFeedKindIsStoredAsAPermanentName() throws {
        #expect(Source.Kind.sammyFeed.rawValue == "sammyFeed")
        let source = Source(id: "sammy:s1@sammy.example:feed:f1", kind: .sammyFeed, accountID: "s1@sammy.example", title: "Movies", colorIndex: 0)
        let encoded = try #require(String(data: try SyncCoding.encode(SourcePayload(source: source, modifiedAt: now), for: .source), encoding: .utf8))
        #expect(encoded.contains("\"kind\":\"sammyFeed\""))
    }
}
