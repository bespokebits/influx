import Foundation

/// Where sync records are kept away from the device: iCloud in the app,
/// `InMemorySyncServer` in tests. Everything above this is platform-free,
/// so the whole of sync runs in `swift test` on Linux and the CloudKit
/// adapter in the app has nothing to decide.
public protocol SyncServer: Sendable {
    /// Saves records and deletes the named ones, in one request where the
    /// server allows it. A record saved with `systemFields` from an older
    /// version than the server holds is rejected, and the server's copy
    /// comes back in `conflicts`.
    func modify(saving: [OutgoingSyncRecord], deleting: [String]) async throws -> SyncModifyResult

    /// Changes since `token`, or everything on the first call.
    func fetchChanges(since token: Data?) async throws -> SyncFetchResult
}

public struct SyncModifyResult: Sendable, Hashable {
    public var saved: [SavedSyncRecord] = []
    /// Records the server already didn't have; a deletion of one is done.
    public var deleted: [String] = []
    /// The server's copy of a record whose save was rejected, to merge.
    public var conflicts: [FetchedSyncRecord] = []
    /// Records the server has no row for, so their saved fields are stale
    /// and they must be sent again as new.
    public var unknown: [String] = []

    public init(saved: [SavedSyncRecord] = [], deleted: [String] = [], conflicts: [FetchedSyncRecord] = [], unknown: [String] = []) {
        self.saved = saved
        self.deleted = deleted
        self.conflicts = conflicts
        self.unknown = unknown
    }
}

public struct SyncFetchResult: Sendable, Hashable {
    public var changed: [FetchedSyncRecord] = []
    public var deleted: [String] = []
    /// Where to carry on from next time.
    public var token: Data?
    /// True when the server says everything it had is gone (CloudKit's
    /// zone deleted, or a new iCloud account): sync starts over.
    public var wasReset = false

    public init(changed: [FetchedSyncRecord] = [], deleted: [String] = [], token: Data? = nil, wasReset: Bool = false) {
        self.changed = changed
        self.deleted = deleted
        self.token = token
        self.wasReset = wasReset
    }
}

/// Moves records between a store and a `SyncServer`: sends what the store
/// has pending, merges what comes back, and sends again what the merge kept.
/// One pass at a time; `sync()` while a pass runs waits for it and runs
/// another, so a change made during a pass isn't left behind.
public actor SyncCoordinator {
    private let store: InfluxStore
    private let server: any SyncServer
    /// The iCloud container `server` stands for. State the store saved for
    /// another one isn't used: sync starts over.
    private let container: String
    /// How many rounds of "send, merge, send what won" one pass runs before
    /// giving up. Two devices settle in one or two; more means something
    /// disagrees in a loop, and a pass that never ends would spend the
    /// reader's battery on it.
    private let maxRounds: Int
    private var pass: Task<Void, any Error>?
    /// Whether this coordinator has merged again what an earlier build
    /// kept unread, which it does once, before its first pass.
    private var didReadKept = false

    public init(store: InfluxStore, server: any SyncServer, container: String = "iCloud.example.influx", maxRounds: Int = 4) {
        self.store = store
        self.server = server
        self.container = container
        self.maxRounds = maxRounds
    }

    /// Fetches what's new, sends what's pending, and settles conflicts.
    public func sync() async throws {
        // A pass running now may have read the store before this caller's
        // change, so wait for it and then run another.
        while let running = pass {
            _ = try? await running.value
            if pass == nil { break }
            pass = nil
        }
        let pass = Task { try await onePass() }
        self.pass = pass
        defer { self.pass = nil }
        try await pass.value
    }

    private func onePass() async throws {
        if !didReadKept {
            _ = try await store.readKeptSyncRecords()
            didReadKept = true
        }
        try await fetch()
        for _ in 0..<maxRounds {
            guard try await send() else { return }
        }
    }

    private func fetch() async throws {
        var token = try await store.syncEngineState(for: container)
        while true {
            let result = try await server.fetchChanges(since: token)
            if result.wasReset {
                try await store.resetSync(uploadingEverything: true)
                token = nil
                continue
            }
            _ = try await store.mergeSyncRecords(result.changed, deletions: result.deleted)
            guard let next = result.token else { return }
            try await store.saveSyncEngineState(next, for: container)
            if next == token { return }
            token = next
            if result.changed.isEmpty, result.deleted.isEmpty { return }
        }
    }

    /// Sends everything pending; returns whether a merge left more to send.
    private func send() async throws -> Bool {
        let pending = try await store.pendingSyncChanges()
        guard !pending.isEmpty else { return false }
        var saving: [OutgoingSyncRecord] = []
        var deleting: [String] = []
        for change in pending {
            if change.isDeletion {
                deleting.append(change.name)
            } else if let record = try await store.syncRecordToSend(named: change.name) {
                saving.append(record)
            }
        }
        guard !saving.isEmpty || !deleting.isEmpty else { return false }
        let result = try await server.modify(saving: saving, deleting: deleting)
        try await store.didSaveSyncRecords(result.saved)
        try await store.didDeleteSyncRecords(named: result.deleted)
        try await store.forgetSyncSystemFields(named: result.unknown)
        let merged = try await store.mergeSyncRecords(result.conflicts)
        return !merged.toSend.isEmpty || !result.unknown.isEmpty
    }
}
