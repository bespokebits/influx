import Foundation
import GRDB

// The sync engine's saved state belongs to the iCloud container it came
// from: its change token, and the server's fields the store keeps for each
// record, mean nothing to another container. So the store records which
// container the state is for, and when the build syncs with another one
// (the app's container changed with its rename, ADR 0032), sync starts
// over: everything here goes up to the new container, and everything there
// comes down from the beginning.
//
// The container is kept beside the state in the one row the store already
// has for it, so recording it needs no new column.

/// The engine's state as the store keeps it: the bytes the engine gave, and
/// the container they are for.
struct SavedSyncEngineState: Codable, Sendable, Hashable {
    /// Named so the engine's own JSON, which a store from before kept
    /// bare, never reads as one of these.
    var influxContainer: String
    var influxEngineState: Data

    /// What a stored row holds. Nil for a row from before the store
    /// recorded the container: its container is unknown.
    static func decode(_ row: Data) -> SavedSyncEngineState? {
        try? JSONDecoder().decode(Self.self, from: row)
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

extension InfluxStore {
    /// The sync engine's saved state (`CKSyncEngine.State.Serialization`)
    /// for `container`, or nil before the first sync and after a reset.
    ///
    /// State saved for another container, or saved before the store
    /// recorded which, isn't used: sync starts over first, as
    /// `resetSync(uploadingEverything: true)` does, so everything here is
    /// sent to `container` and everything there is fetched from scratch.
    public func syncEngineState(for container: String, at now: Date = Date()) async throws -> Data? {
        try await writer.write { db -> Data? in
            guard let row = try Data.fetchOne(db, sql: "SELECT data FROM syncEngineState WHERE id = 1") else { return nil }
            let saved = SavedSyncEngineState.decode(row)
            if let saved, saved.influxContainer == container { return saved.influxEngineState }
            try SyncJournal.note(db, .sync, """
                the saved sync state was for \(saved?.influxContainer ?? "an unrecorded container"), \
                not \(container), so sync starts over
                """, at: now)
            try SyncWork.reset(uploadingEverything: true, db, at: now)
            return nil
        }
    }

    /// Saves the sync engine's state, as the state for `container`.
    public func saveSyncEngineState(_ data: Data, for container: String) async throws {
        let row = try SavedSyncEngineState(influxContainer: container, influxEngineState: data).encoded()
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO syncEngineState (id, data) VALUES (1, ?)", arguments: [row])
        }
    }
}
