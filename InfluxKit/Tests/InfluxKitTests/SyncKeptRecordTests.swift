import Foundation
import GRDB
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

/// A payload's JSON with its version changed, as a later Influx would send.
private func payload<Payload: Encodable>(_ payload: Payload, for type: SyncRecordType, version: Int) throws -> Data {
    var fields = try #require(try JSONSerialization.jsonObject(with: try SyncCoding.encode(payload, for: type)) as? [String: Any])
    fields["v"] = version
    return try JSONSerialization.data(withJSONObject: fields)
}

private func setting(_ value: String, at offset: TimeInterval, version: Int = 1) throws -> FetchedSyncRecord {
    let fields = SettingPayload(key: "theme", value: Data(value.utf8), modifiedAt: t0.addingTimeInterval(offset))
    return FetchedSyncRecord(
        record: SyncRecord(type: .setting, key: "theme", payload: try payload(fields, for: .setting, version: version)),
        systemFields: Data("fields".utf8)
    )
}

private let settingName = SyncRecord.name(type: .setting, key: "theme")

extension InfluxStore {
    fileprivate func keptRecords() async throws -> [UnreadSyncRecord] {
        try await writer.read { try UnreadSyncRecord.order(Column("recordName")).fetchAll($0) }
    }

    /// Puts a record in the store as a build that couldn't read it kept it.
    fileprivate func keep(_ fetched: FetchedSyncRecord, isNewer: Bool) async throws {
        try await writer.write { db in
            try UnreadSyncRecord(
                recordName: fetched.record.name, type: fetched.record.type.rawValue, key: fetched.record.key,
                payload: fetched.record.payload, systemFields: fetched.systemFields, isNewer: isNewer, receivedAt: t0
            ).upsert(db)
        }
    }
}

/// Every payload says which version of its type's fields it is, and a
/// record this build can't read is kept until a build that can merges it
/// (ADR 0029).
@Suite struct SyncKeptRecords {
    @Test func everyRecordSentSaysItsVersion() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 3)])
        try await store.moveReadingPlace(viewID: "all", to: (t0, "post:a"), at: t0)
        try await store.setSetting("theme", to: Data("dark".utf8), at: t0)
        try await store.setSetting("gone", to: Data("x".utf8), at: t0)

        // The setting's record reaches iCloud, and is then deleted here, so
        // it goes up as a tombstone.
        let gone = SyncRecord.name(type: .setting, key: "gone")
        let sent = try #require(try await store.syncRecordToSend(named: gone))
        try await store.didSaveSyncRecords([SavedSyncRecord(name: gone, version: sent.version, systemFields: Data("fields".utf8))])
        try await store.writer.write { db in
            try SyncedSetting.deleteOne(db, key: "gone")
            try SyncLog.recordDeletion(db, .setting, key: "gone", at: t0.addingTimeInterval(1))
        }

        let pending = try await store.pendingSyncChanges()
        #expect(Set(pending.map(\.type)) == [.source, .readingPlace, .setting])
        for change in pending {
            let record = try #require(try await store.syncRecordToSend(named: change.name))
            let fields = try #require(try JSONSerialization.jsonObject(with: record.record.payload) as? [String: Any])
            #expect(fields["v"] as? Int == change.type.payloadVersion, "\(change.type)")
        }
    }

    @Test func aPayloadWithoutAVersionIsVersionOne() {
        #expect(SyncCoding.version(of: Data(#"{"key":"theme","modifiedAt":0}"#.utf8)) == 1)
        #expect(SyncCoding.version(of: Data(#"{"key":"theme","modifiedAt":0,"v":3}"#.utf8)) == 3)
        #expect(SyncCoding.version(of: Data("not JSON".utf8)) == 1)
    }

    /// A later version isn't read even though its fields decode: nothing
    /// changes here, and the record is kept as it came.
    @Test func aLaterVersionOfARecordIsKeptAsItArrived() async throws {
        let store = try InfluxStore.inMemory()
        _ = try await store.mergeSyncRecords([try setting("dark", at: 0)], at: t0)
        let later = try setting("sepia", at: 60, version: 2)
        let result = try await store.mergeSyncRecords([later], at: t0.addingTimeInterval(61))
        #expect(result.unread == 1)
        #expect(result.changed.isEmpty)
        #expect(result.toSend.isEmpty)
        #expect(try await store.setting("theme") == Data("dark".utf8))

        let kept = try #require(try await store.keptRecords().first)
        #expect(kept.recordName == settingName)
        #expect(kept.payload == later.record.payload)
        #expect(kept.isNewer)
        let line = try #require(try await store.syncJournal().last { $0.kind == .merge })
        #expect(line.message.contains("1 couldn't be read by this version of Influx (Setting (from a newer version) 1)"))

        // The same build reads it no better the next time it starts.
        #expect(try await store.readKeptSyncRecords().changed.isEmpty)
        #expect(try await store.keptRecords().count == 1)
    }

    /// This build would save its own older form over a record it can't
    /// read, so a change here to such a record waits for the update.
    @Test func nothingIsSentOverARecordFromALaterVersion() async throws {
        let store = try InfluxStore.inMemory()
        _ = try await store.mergeSyncRecords([try setting("dark", at: 0)], at: t0)
        _ = try await store.mergeSyncRecords([try setting("sepia", at: 60, version: 2)], at: t0.addingTimeInterval(61))

        try await store.setSetting("theme", to: Data("light".utf8), at: t0.addingTimeInterval(120))
        try await store.setSetting("size", to: Data("large".utf8), at: t0.addingTimeInterval(120))
        // Only the other setting goes.
        #expect(try await store.pendingSyncChanges().map(\.name) == [SyncRecord.name(type: .setting, key: "size")])
        #expect(try await store.syncRecordToSend(named: settingName) == nil)
        #expect(try store.blocking.pendingBatch(limit: 10).map(\.change.name) == [SyncRecord.name(type: .setting, key: "size")])

        // The record changes in iCloud to one this build reads, later than
        // the change here: it is taken, and nothing is kept or waiting.
        _ = try await store.mergeSyncRecords([try setting("paper", at: 180)], at: t0.addingTimeInterval(181))
        #expect(try await store.setting("theme") == Data("paper".utf8))
        #expect(try await store.keptRecords().isEmpty)
    }

    /// After the update, the kept record merges by its type's rule against
    /// what changed here while it was kept: here, the later change wins.
    @Test(arguments: [true, false])
    func aKeptRecordMergesByItsRuleOnceThisBuildReadsIt(keptIsLater: Bool) async throws {
        let store = try InfluxStore.inMemory()
        _ = try await store.mergeSyncRecords([try setting("dark", at: 0)], at: t0)
        try await store.setSetting("theme", to: Data("light".utf8), at: t0.addingTimeInterval(120))
        // What the build before this one kept, in a version this one reads.
        try await store.keep(try setting("sepia", at: keptIsLater ? 180 : 60), isNewer: true)
        #expect(try await store.pendingSyncChanges().isEmpty)

        let result = try await store.readKeptSyncRecords(at: t0.addingTimeInterval(600))
        #expect(try await store.keptRecords().isEmpty)
        if keptIsLater {
            #expect(result.changed == [.setting])
            #expect(try await store.setting("theme") == Data("sepia".utf8))
            #expect(try await store.pendingSyncChanges().isEmpty)
        } else {
            #expect(result.toSend.map(\.name) == [settingName])
            #expect(try await store.setting("theme") == Data("light".utf8))
            // Sent on top of the version that was kept.
            let record = try #require(try await store.syncRecordToSend(named: settingName))
            #expect(record.systemFields == Data("fields".utf8))
        }
        #expect(try await store.syncJournal().contains { $0.message.contains("read 1 of 1 record an earlier version of Influx kept") })
    }

    @Test func aRecordOfATypeThisBuildHasNoNameForIsKept() async throws {
        let store = try InfluxStore.inMemory()
        let widget = UnknownSyncRecord(name: "Widget.0a1b", type: "Widget", key: "w1", payload: Data(#"{"v":1}"#.utf8), systemFields: Data("fields".utf8))
        let result = try await store.mergeSyncRecords([], unknown: [widget], at: t0)
        #expect(result.unread == 1)
        #expect(try await store.keptRecords().map(\.type) == ["Widget"])
        #expect(try await store.pendingSyncChanges().isEmpty)
        // This build still has no name for it.
        _ = try await store.readKeptSyncRecords()
        #expect(try await store.keptRecords().count == 1)

        // Deleted in iCloud: nothing left to read.
        _ = try await store.mergeSyncRecords([], deletions: ["Widget.0a1b"], at: t0)
        #expect(try await store.keptRecords().isEmpty)
    }

    /// A record that only fails to decode doesn't hold a change back. Once
    /// iCloud has taken the change, the kept copy is of a record that is
    /// no longer there, and reading it later would undo the change.
    @Test func aKeptRecordGoesOnceICloudTakesAChangeMadeOverIt() async throws {
        let store = try InfluxStore.inMemory()
        _ = try await store.mergeSyncRecords([try setting("dark", at: 0)], at: t0)
        // What an earlier build kept: readable by this one, and older than
        // the change about to be made here.
        try await store.keep(try setting("sepia", at: 60), isNewer: false)
        try await store.setSetting("theme", to: Data("light".utf8), at: t0.addingTimeInterval(120))
        let record = try #require(try await store.syncRecordToSend(named: settingName))
        try await store.didSaveSyncRecords([SavedSyncRecord(name: settingName, version: record.version, systemFields: Data("saved".utf8))])
        #expect(try await store.keptRecords().isEmpty)

        let read = try await store.readKeptSyncRecords(at: t0.addingTimeInterval(600))
        #expect(read.toSend.isEmpty)
        #expect(try await store.pendingSyncChanges().isEmpty)
        // The server's fields are the ones that came with the save.
        let state = try #require(try await store.writer.read { try SyncRecordState.fetchOne($0, key: settingName) })
        #expect(state.systemFields == Data("saved".utf8))
    }

    /// The same for a deletion iCloud confirmed: the kept copy must not
    /// bring the thing back.
    @Test func aKeptRecordGoesOnceICloudDeletesTheRecord() async throws {
        let store = try InfluxStore.inMemory()
        try await store.moveReadingPlace(viewID: "all", to: (t0, "post:a"), at: t0)
        let name = SyncRecord.name(type: .readingPlace, key: "all")
        let sent = try #require(try await store.syncRecordToSend(named: name))
        try await store.didSaveSyncRecords([SavedSyncRecord(name: name, version: sent.version, systemFields: Data("fields".utf8))])
        let place = ReadingPlacePayload(viewID: "all", mergeKey: "post:b", sortDate: t0, updatedAt: t0, move: 5, device: "another")
        try await store.keep(FetchedSyncRecord(
            record: SyncRecord(type: .readingPlace, key: "all", payload: try SyncCoding.encode(place, for: .readingPlace)),
            systemFields: Data("fields".utf8)
        ), isNewer: false)

        // Its view is deleted here, and iCloud deletes the record.
        try await store.writer.write { db in
            try ReadingPlace.deleteOne(db, key: "all")
            try SyncLog.recordDeletion(db, .readingPlace, key: "all", at: t0.addingTimeInterval(60))
        }
        #expect(try await store.pendingSyncChanges().map(\.isDeletion) == [true])
        try await store.didDeleteSyncRecords(named: [name])
        #expect(try await store.keptRecords().isEmpty)
        _ = try await store.readKeptSyncRecords(at: t0.addingTimeInterval(600))
        #expect(try await store.readingPlace(viewID: "all") == nil)
    }

    /// And for a record iCloud turns out not to have any more.
    @Test func aKeptRecordGoesWhenICloudNoLongerHasTheRecord() async throws {
        let store = try InfluxStore.inMemory()
        try await store.keep(try setting("sepia", at: 60), isNewer: false)
        try await store.forgetSyncSystemFields(named: [settingName])
        #expect(try await store.keptRecords().isEmpty)
    }

    /// Starting over forgets what was kept, as it does everything else
    /// iCloud sent: it all comes again.
    @Test func startingSyncOverForgetsWhatWasKept() async throws {
        let store = try InfluxStore.inMemory()
        _ = try await store.mergeSyncRecords([try setting("sepia", at: 60, version: 2)], at: t0)
        #expect(try await store.keptRecords().count == 1)
        try await store.resetSync(uploadingEverything: true, at: t0)
        #expect(try await store.keptRecords().isEmpty)
    }

    /// The coordinator reads what was kept before its first pass.
    @Test func syncStartsByReadingWhatWasKept() async throws {
        let store = try InfluxStore.inMemory()
        try await store.keep(try setting("sepia", at: 60), isNewer: true)
        let sync = SyncCoordinator(store: store, server: InMemorySyncServer())
        try await sync.sync()
        #expect(try await store.setting("theme") == Data("sepia".utf8))
        #expect(try await store.keptRecords().isEmpty)
    }
}
