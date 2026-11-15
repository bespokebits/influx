// What the app does with a report from the sync framework before the
// store's rules take over.
import Foundation
import InfluxKit
import Testing
@testable import Influx

/// A newer Influx on another device can save a type of record this build
/// has no name for. It goes to the store, which keeps it for the build that
/// reads it (ADR 0029), and the framework is told it was kept, so it moves
/// on past it.
@Test func aRecordOfATypeThisBuildHasNoNameForGoesToTheStoreToKeep() async throws {
    let store = try InfluxStore.inMemory()
    let suite = "SyncBoundaryTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fields = Data("fields".utf8).base64EncodedString()
    let payload = Data(#"{"v":1}"#.utf8).base64EncodedString()
    let report = """
        {"saved": [], "deleted": [], "unknown": [], "removed": [], "wasReset": false,
         "fetched": [{"name": "Widget.0a1b", "type": "Widget", "key": "w1", "payload": "\(payload)", "systemFields": "\(fields)"}]}
        """

    let applied = SyncBoundary.apply(Data(report.utf8), to: store, defaults: defaults)
    #expect(applied.kept)
    #expect(!applied.sourcesChanged)
    let line = try #require(try await store.syncJournal().last)
    #expect(line.message.contains("1 couldn't be read by this version of Influx (Widget (from a newer version) 1)"))
    #expect(defaults.string(forKey: "InfluxSyncLastMerge")?.contains("merged 0 of 1 fetched, 0 removed, 1 kept unread") == true)
}
