// The text Copy Diagnostics puts on the clipboard: what sync did lately,
// for explaining a timeline that opened in the wrong place.
import Foundation
import InfluxKit
import Testing
@testable import Influx

@Test func diagnosticsHoldTheJournalAndICloudsEvents() async throws {
    let store = try InfluxStore.inMemory()
    let now = Date()
    await store.noteInJournal(.timeline, "follow: place post:a from another device", at: now.addingTimeInterval(-60))
    // Older than the two days a copy goes back.
    await store.noteInJournal(.timeline, "follow: place post:old", at: now.addingTimeInterval(-3 * 86_400))
    let suite = "SyncDiagnosticsTests-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(["2026-11-09T20:00:00Z sent 2 records, 0 failed"], forKey: "InfluxSyncEvents")
    defaults.set(["top": "post:a", "rows": 9], forKey: "InfluxTimelineProbe")

    let text = await Sync.diagnostics(from: store, header: ["Influx 0.1.0 (1) · abc1234, iOS"], now: now, defaults: defaults)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines.first?.hasPrefix("Influx sync diagnostics, copied ") == true)
    #expect(lines.contains("Influx 0.1.0 (1) · abc1234, iOS"))
    #expect(lines.contains("Journal, last 48 hours (1 line)"))
    #expect(lines.contains { $0.hasSuffix("timeline: follow: place post:a from another device") })
    #expect(!text.contains("post:old"))
    #expect(lines.contains("2026-11-09T20:00:00Z sent 2 records, 0 failed"))
    #expect(text.contains("\"top\" : \"post:a\""))
}
