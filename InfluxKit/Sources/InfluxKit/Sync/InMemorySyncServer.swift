import Foundation
import Synchronization

/// A sync server in memory, standing in for iCloud in tests and previews.
/// It keeps the parts of CloudKit's behaviour the merge rules have to cope
/// with: a change tag per record, a save rejected when the tag is stale,
/// and a change token that only returns what happened after it.
public final class InMemorySyncServer: SyncServer {
    private struct Stored {
        var record: SyncRecord
        var tag: Int
        /// Where this version sits in the server's history.
        var version: Int
    }

    private struct State {
        var records: [String: Stored] = [:]
        /// Deletions, by the version they happened at, so a device that
        /// fetched before one hears about it.
        var deletions: [Int: String] = [:]
        var version = 0
        var wasReset = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Tells the next fetch that everything the server had is gone, as
    /// CloudKit does for a deleted zone or a new iCloud account.
    public func reset() {
        state.withLock {
            $0 = State(wasReset: true)
        }
    }

    /// What the server holds, for tests to check.
    public func records() -> [SyncRecord] {
        state.withLock { $0.records.values.map(\.record).sorted { $0.name < $1.name } }
    }

    public func modify(saving: [OutgoingSyncRecord], deleting: [String]) async throws -> SyncModifyResult {
        state.withLock { state in
            var result = SyncModifyResult()
            for outgoing in saving {
                let name = outgoing.record.name
                let sentTag = outgoing.systemFields.flatMap { Int(String(decoding: $0, as: UTF8.self)) }
                if let current = state.records[name] {
                    guard sentTag == current.tag else {
                        result.conflicts.append(FetchedSyncRecord(record: current.record, systemFields: Self.fields(current.tag)))
                        continue
                    }
                } else if sentTag != nil {
                    // The server's row has gone since this device saved it.
                    result.unknown.append(name)
                    continue
                }
                state.version += 1
                let tag = (state.records[name]?.tag ?? 0) + 1
                state.records[name] = Stored(record: outgoing.record, tag: tag, version: state.version)
                result.saved.append(SavedSyncRecord(name: name, version: outgoing.version, systemFields: Self.fields(tag)))
            }
            for name in deleting {
                state.version += 1
                state.records[name] = nil
                state.deletions[state.version] = name
                result.deleted.append(name)
            }
            return result
        }
    }

    public func fetchChanges(since token: Data?) async throws -> SyncFetchResult {
        state.withLock { state in
            if state.wasReset {
                state.wasReset = false
                return SyncFetchResult(wasReset: true)
            }
            let since = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            let changed = state.records.values
                .filter { $0.version > since }
                .sorted { $0.version < $1.version }
                .map { FetchedSyncRecord(record: $0.record, systemFields: Self.fields($0.tag)) }
            let deleted = state.deletions
                .filter { $0.key > since }
                .sorted { $0.key < $1.key }
                .map(\.value)
            return SyncFetchResult(changed: changed, deleted: deleted, token: Data(String(state.version).utf8))
        }
    }

    private static func fields(_ tag: Int) -> Data {
        Data(String(tag).utf8)
    }
}
