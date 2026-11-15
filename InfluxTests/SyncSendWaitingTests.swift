// Sending what's waiting as the app is put away: how long it waits for
// iCloud to have everything (influx-dev #125).
import Foundation
import InfluxKit
import Testing
@testable import Influx

@Test func waitingForTheOutboxEndsWhenItEmptiesOrAtTheLimit() async throws {
    let store = try InfluxStore.inMemory()
    // Nothing to send: no wait.
    #expect(await Sync.outboxEmptied(in: store, within: .seconds(5)))

    try await store.setSetting("test", to: Data([1]))
    // Never confirmed, as offline: gives up at the limit.
    #expect(await Sync.outboxEmptied(in: store, within: .milliseconds(200), poll: .milliseconds(20)) == false)

    let change = try #require(try await store.pendingSyncChanges().first)
    let record = try #require(try await store.syncRecordToSend(named: change.name))
    let confirming = Task {
        try await Task.sleep(for: .milliseconds(100))
        try await store.didSaveSyncRecords([SavedSyncRecord(name: change.name, version: record.version, systemFields: Data())])
    }
    #expect(await Sync.outboxEmptied(in: store, within: .seconds(10), poll: .milliseconds(20)))
    try await confirming.value
}
