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

/// Diagnostics list each row that went anywhere but its own time, and only
/// count the rest (ADR 0043).
@Test func diagnosticsListLateAndMovedRowsAndCountTheRest() {
    let t = Date(timeIntervalSince1970: 1_793_000_000)
    let events = [
        RowEvent(mergeKey: "post:a", at: t, kind: .placed, sortDate: t, via: .refresh, how: .ownTime),
        RowEvent(mergeKey: "post:b", at: t, kind: .placed, sortDate: t, via: .refresh, how: .ownTime),
        RowEvent(mergeKey: "post:c", at: t, kind: .placed, sortDate: t + 1, via: .stream, how: .belowLine,
                 lineView: "all", lineBound: "marker", lineDate: t, offered: true),
        RowEvent(mergeKey: "post:a", at: t + 5, kind: .moved, sortDate: t - 60, previous: t),
    ]
    let lines = Sync.rowHistory(events)
    #expect(lines[0] == "Row history, last 48 hours: 4 events; by own time or joined: 2 placed via refresh")
    #expect(lines[1] == "Placed below the line, from iCloud, or moved (2)")
    #expect(lines[2].contains("placed post:c"))
    #expect(lines[2].contains("line all marker at"))
    #expect(lines[3].contains("moved post:a"))
}

/// Row Details names the row's times, its copies and its history.
@Test func rowDetailsHoldTheRowsTimesCopiesAndHistory() async throws {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [Source(id: "social", kind: .mastodonHome, title: "Social", colorIndex: 0)])
    let t = Date(timeIntervalSince1970: 1_793_000_000)
    try await store.insert([Item(sourceID: "social", remoteID: "a", kind: .post, mergeKey: "post:a", authorName: "A",
                                 authorHandle: "", body: "a", publishedAt: t, fetchedAt: t + 60)])
    let row = try #require(try await store.rows().first)
    let text = await RowDetailsScreen.details(of: row, in: store, now: t + 120)
    #expect(text.contains("Shown from Social (social)"))
    #expect(text.contains("Row post:a"))
    #expect(text.contains("* Social [mastodonHome] a"))
    #expect(text.contains("placed post:a"))
    #expect(text.contains("Sync journal lines naming this row"))
}

/// Row Details takes only the journal lines that name the row's key as a
/// whole, not a longer key it begins.
@Test func rowDetailsMatchJournalKeysWhole() {
    let key = "https://example.com/posts/1"
    #expect(RowDetailsScreen.names("follow: place https://example.com/posts/1, move 3", key))
    #expect(RowDetailsScreen.names("marker \(key) at 2026-11-18T21:00:00Z", key))
    #expect(RowDetailsScreen.names(key, key))
    #expect(!RowDetailsScreen.names("follow: place https://example.com/posts/10, move 3", key))
    #expect(!RowDetailsScreen.names("follow: place https://example.com/posts/10 then https://example.com/posts/1x", key))
}
