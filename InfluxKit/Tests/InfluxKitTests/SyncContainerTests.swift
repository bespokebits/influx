import Foundation
import GRDB
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
private let old = "iCloud.example.flux"
private let new = "iCloud.example.influx"

private let rss = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 3)
private let mastodon = Source(id: "mastodon:@me@example.social:home", kind: .mastodonHome, accountID: "@me@example.social", title: "Mastodon", colorIndex: 1)

/// An iCloud container in memory that notes the change token of every
/// fetch and every record it is sent.
private final class Container: SyncServer, @unchecked Sendable {
    let server = InMemorySyncServer()
    private let lock = NSLock()
    private var _fetchedSince: [Data?] = []
    private var _sent: [String] = []

    var fetchedSince: [Data?] { lock.withLock { _fetchedSince } }
    var sent: [String] { lock.withLock { _sent } }

    func modify(saving: [OutgoingSyncRecord], deleting: [String]) async throws -> SyncModifyResult {
        lock.withLock { _sent += saving.map(\.record.name) }
        return try await server.modify(saving: saving, deleting: deleting)
    }

    func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        lock.withLock { _fetchedSince.append(token) }
        return try await server.fetchChanges(since: token)
    }
}

@Suite struct SyncContainers {
    /// A store that has synced its sources with `old`.
    private func syncedWithOld() async throws -> (InfluxStore, Container) {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss, mastodon], at: t0)
        let container = Container()
        try await SyncCoordinator(store: store, server: container, container: old).sync()
        #expect(try await store.pendingSyncChanges().isEmpty)
        #expect(container.server.records().count == 2)
        return (store, container)
    }

    @Test func anotherContainerGetsEverythingAndIsFetchedFromTheStart() async throws {
        let (store, _) = try await syncedWithOld()
        let renamed = Container()
        try await SyncCoordinator(store: store, server: renamed, container: new).sync()

        // Fetched from the beginning, not from the old container's token.
        #expect(renamed.fetchedSince.first == .some(nil))
        // Everything here went up, though none of it had changed since.
        #expect(Set(renamed.sent) == Set([rss, mastodon].map { SyncRecord.name(type: .source, key: $0.id) }))
        #expect(renamed.server.records().map(\.key).sorted() == [mastodon.id, rss.id])
        #expect(try await store.pendingSyncChanges().isEmpty)
        let journal = try await store.syncJournal().map(\.message)
        #expect(journal.contains { $0.contains("the saved sync state was for \(old), not \(new), so sync starts over") })

        // The state is the new container's from now on.
        #expect(try await store.syncEngineState(for: new) != nil)
    }

    @Test func theSameContainerCarriesOnFromItsState() async throws {
        let (store, container) = try await syncedWithOld()
        #expect(container.fetchedSince.count == 1)
        let token = try #require(try await store.syncEngineState(for: old))
        try await SyncCoordinator(store: store, server: container, container: old).sync()

        // The second pass carried on from the saved token, never from the
        // start, and sent nothing.
        let fetched = container.fetchedSince
        #expect(fetched.count > 1)
        #expect(fetched.dropFirst().first == .some(token))
        #expect(fetched.dropFirst().allSatisfy { $0 != nil })
        #expect(container.sent.count == 2)
        #expect(try await store.syncJournal().allSatisfy { !$0.message.contains("started over") })
    }

    @Test func stateFromBeforeTheContainerWasRecordedStartsOver() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss], at: t0)
        try await SyncCoordinator(store: store, server: Container(), container: new).sync()
        // As a store from before kept it: the engine's bytes alone.
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE syncEngineState SET data = ? WHERE id = 1", arguments: [Data(#"{"token":"7"}"#.utf8)])
        }
        #expect(try await store.syncEngineState(for: new) == nil)
        #expect(try await store.pendingSyncChanges().map(\.name).contains(SyncRecord.name(type: .source, key: rss.id)))
        let journal = try await store.syncJournal().map(\.message)
        #expect(journal.contains { $0.contains("an unrecorded container, not \(new)") })
    }

    @Test func aStoreThatNeverSyncedJustStarts() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss], at: t0)
        #expect(try await store.syncEngineState(for: new) == nil)
        #expect(try await store.syncJournal().allSatisfy { !$0.message.contains("started over") })
        try await store.saveSyncEngineState(Data("state".utf8), for: new)
        #expect(try await store.syncEngineState(for: new) == Data("state".utf8))
    }
}
