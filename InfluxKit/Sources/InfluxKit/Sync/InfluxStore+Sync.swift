import Foundation
import GRDB

// The store's side of iCloud sync. The store
// records every synced change as it is written, builds the records to send,
// and merges what arrives, so the merge rules live here and run in tests on
// Linux. The CloudKit adapter in the app only moves records, as opaque
// payloads, between this and `CKSyncEngine`.

/// The result of merging records from iCloud.
public struct SyncMergeResult: Sendable, Hashable {
    /// Local changes that won over what arrived, to send again.
    public var toSend: [PendingSyncChange] = []
    /// The kinds of record that changed here, e.g. `.source` when a feed
    /// was added on another device, so the app can refresh what shows them.
    public var changed: Set<SyncRecordType> = []
    /// How many records this build couldn't read, and kept to read after
    /// an update.
    public var unread = 0
}

extension InfluxStore {
    /// Every local change waiting to go to iCloud.
    public func pendingSyncChanges() async throws -> [PendingSyncChange] {
        try await writer.read { db in
            try SyncLog.pending(db)
        }
    }

    /// The local changes waiting to go to iCloud, delivered again after
    /// every write that changes them, so the sync engine hears of new ones.
    public func observePendingSyncChanges() -> AsyncValueObservation<[PendingSyncChange]> {
        ValueObservation
            .tracking { db in try SyncLog.pending(db) }
            .removeDuplicates()
            .values(in: writer)
    }

    /// The record to save for a pending change, as the store has it now;
    /// nil when there is nothing to save (it was sent already, it is a
    /// deletion CloudKit makes, or what it described has gone). A deletion
    /// of a last-writer-wins type is saved as a tombstone.
    public func syncRecordToSend(named name: String) async throws -> OutgoingSyncRecord? {
        try await writer.write { db in try SyncWork.record(named: name, db) }
    }

    /// Records saves the server confirmed. A change made after the saved
    /// version stays pending.
    public func didSaveSyncRecords(_ saved: [SavedSyncRecord]) async throws {
        try await writer.write { db in try SyncWork.didSave(saved, db) }
    }

    /// Records deletions the server confirmed, or found already done. A
    /// record saved again since stays pending.
    public func didDeleteSyncRecords(named names: [String]) async throws {
        try await writer.write { db in try SyncWork.didDelete(names, db) }
    }

    /// Forgets the server's fields for records the server no longer has
    /// (CloudKit's `unknownItem`), so they are sent again as new.
    public func forgetSyncSystemFields(named names: [String]) async throws {
        try await writer.write { db in try SyncWork.forgetSystemFields(names, db) }
    }

    /// Merges records that arrived from iCloud, and deletions, by each
    /// type's rule (`SyncRecordType`). Also takes the server's copy of a
    /// record whose save conflicted. Nothing merged here is sent back,
    /// except local changes that win, which the result lists.
    ///
    /// A record this build can't read is kept as it arrived, and so is one
    /// in `unknown`, whose type this build has no name for: a newer Influx
    /// on another device saved it, and this one reads it once it has
    /// updated (`readKeptSyncRecords`).
    public func mergeSyncRecords(_ records: [FetchedSyncRecord], unknown: [UnknownSyncRecord] = [], deletions: [String] = [],
                                 at now: Date = Date()) async throws -> SyncMergeResult {
        try await writer.write { db in try SyncWork.merge(records, unknown: unknown, deletions: deletions, db, at: now) }
    }

    /// Merges again the records an earlier build of Influx on this device
    /// kept because it couldn't read them. Called as sync starts, once a
    /// launch: only an update changes what a build can read. One still
    /// unreadable stays kept.
    public func readKeptSyncRecords(at now: Date = Date()) async throws -> SyncMergeResult {
        try await writer.write { db in try SyncWork.readKept(db, at: now) }
    }

    /// Starts sync over: forgets everything the store knew about iCloud,
    /// and the engine's state, as when the reader signs out of iCloud or
    /// into another account. With `uploadingEverything`, every synced
    /// thing stored here is queued to go up, so a new account gets this
    /// device's sources and read state.
    public func resetSync(uploadingEverything: Bool, at now: Date = Date()) async throws {
        try await writer.write { db in try SyncWork.reset(uploadingEverything: uploadingEverything, db, at: now) }
    }

    // The sync engine's own state, and the container it is for, are in
    // SyncEngineState.swift.

    // MARK: Settings

    /// A synced setting's value, as the app encoded it; nil when unset.
    public func setting(_ key: String) async throws -> Data? {
        try await writer.read { db in
            try SyncedSetting.fetchOne(db, key: key)?.value
        }
    }

    /// Sets or clears a synced setting. The latest change on any device wins.
    public func setSetting(_ key: String, to value: Data?, at now: Date = Date()) async throws {
        try await writer.write { db in
            guard try SyncedSetting.fetchOne(db, key: key)?.value != value else { return }
            try SyncedSetting(key: key, value: value).upsert(db)
            try SyncLog.recordChange(db, .setting, key: key, at: now)
        }
    }
}

// MARK: Records

/// What the store knows about one record's sync.
struct SyncRecordState: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var recordName: String
    var type: SyncRecordType
    var key: String
    /// When the record last changed, here or on the device whose change was
    /// taken: the clock last-writer-wins compares. Never moves backwards.
    var modifiedAt: Date
    /// The server's fields, from the last save or fetch; nil until the
    /// server has confirmed the record.
    var systemFields: Data?
    /// Set while a local change waits to go up: a new number for every
    /// change, so a save confirmed for an older one doesn't clear it.
    var pending: Int64?
    /// Whether the record is deleted here: a pending deletion, or for the
    /// types that delete by tombstone (`deletesByTombstone`), also one
    /// already sent or taken from another device.
    var isDeleted: Bool

    /// Whether the pending change goes up as a CloudKit deletion, rather
    /// than a save.
    var goesAsDeletion: Bool { isDeleted && !type.deletesByTombstone }

    static let databaseTableName = "syncRecord"
}

/// A record from iCloud that this build couldn't read, as it arrived: its
/// type isn't one this build knows, its payload is a later version
/// (`SyncRecordType.payloadVersion`), or its fields don't decode, as a
/// source of a kind added since doesn't. Kept until a build that can read
/// it merges it, the record changes in iCloud to one this build can read,
/// or it is deleted there.
struct UnreadSyncRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var recordName: String
    /// The CloudKit record type, which may not be a `SyncRecordType` here.
    var type: String
    var key: String
    var payload: Data
    var systemFields: Data
    /// Whether the record says it is from a later version of Influx: a
    /// type or a payload version this build doesn't have. Nothing is sent
    /// over such a record (`SyncLog.pending`): this build would save its
    /// own older form on top of it.
    var isNewer: Bool
    var receivedAt: Date

    static let databaseTableName = "unreadSyncRecord"
}

/// A position iCloud agreed for a merge group this store has no row for:
/// the row takes it when it arrives.
struct PendingTimelinePosition: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var mergeKey: String
    var sortDate: Date
    var receivedAt: Date

    static let databaseTableName = "pendingTimelinePosition"
}

/// One synced setting, encoded by the app.
struct SyncedSetting: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var key: String
    var value: Data?

    static let databaseTableName = "syncedSetting"
}

// MARK: Recording local changes

enum SyncLog {
    /// The name this install made for itself (`ReadingPlace.device`).
    static func device(_ db: Database) throws -> String? {
        try String.fetchOne(db, sql: "SELECT name FROM syncDevice WHERE id = 1")
    }

    /// Queues a local change to `key` to go up on the next sync.
    static func recordChange(_ db: Database, _ type: SyncRecordType, key: String, isDeleted: Bool = false, at now: Date) throws {
        let name = SyncRecord.name(type: type, key: key)
        let existing = try SyncRecordState.fetchOne(db, key: name)
        // Never behind the change it replaces, even if this device's clock
        // is, so a newer change always wins last-writer-wins.
        let modifiedAt = existing.map { max(now, $0.modifiedAt.addingTimeInterval(0.001)) } ?? now
        try queue(db, type, key: key, isDeleted: isDeleted, changedAt: modifiedAt, systemFields: existing?.systemFields)
    }

    /// Queues `key` to go up, as last changed at `changedAt`.
    private static func queue(_ db: Database, _ type: SyncRecordType, key: String, isDeleted: Bool = false, changedAt modifiedAt: Date,
                              systemFields: Data? = nil) throws {
        let name = SyncRecord.name(type: type, key: key)
        try SyncRecordState(
            recordName: name, type: type, key: key, modifiedAt: modifiedAt,
            systemFields: systemFields, pending: try nextVersion(db), isDeleted: isDeleted
        ).upsert(db)
    }

    /// The time given to a thing this store has no record of changing: it
    /// loses to any copy that says when it changed.
    static let unknownChangeTime = Date(timeIntervalSince1970: 0)

    /// Queues the deletion of a record iCloud may have; a key that was never
    /// recorded has nothing to delete.
    static func recordDeletion(_ db: Database, _ type: SyncRecordType, key: String, at now: Date) throws {
        guard try SyncRecordState.exists(db, key: SyncRecord.name(type: type, key: key)) else { return }
        try recordChange(db, type, key: key, isDeleted: true, at: now)
    }

    /// Queues this device's position for a merge group, unless iCloud
    /// already has one or one is queued: the first position stored wins.
    static func offerPosition(_ db: Database, mergeKey: String, at now: Date) throws {
        guard try !SyncRecordState.exists(db, key: SyncRecord.name(type: .timelinePosition, key: mergeKey)) else { return }
        try recordChange(db, .timelinePosition, key: mergeKey, at: now)
    }

    /// Queues every source, marker, reading place, article state, setting,
    /// saved view and filter, for a first sync, as changed at `now`.
    /// Positions aren't, as each is offered when a row is stored.
    static func enqueueEverything(_ db: Database, at now: Date) throws {
        try queueEverything(db) { _, _ in now }
        try offerPlacedPositions(db, at: now)
    }

    /// Queues everything again after sync started over, each thing as last
    /// changed when `before`, the records from before, says it was.
    /// Stamping them all as changed now would let this device's copy of
    /// something, however old, beat a newer one in iCloud, and bring back
    /// what another device deleted.
    ///
    /// A thing with no record from before goes as `unknownChangeTime`,
    /// except a position, which is offered as placed now: the earliest
    /// position wins, so an unknown one must be the weakest claim.
    static func enqueueEverything(_ db: Database, after before: [SyncRecordState], at now: Date) throws {
        let changed = Dictionary(before.map { ($0.recordName, $0.modifiedAt) }) { first, _ in first }
        try queueEverything(db) { type, key in
            changed[SyncRecord.name(type: type, key: key)] ?? unknownChangeTime
        }
        // A deletion that went as a tombstone goes again: iCloud may have
        // lost it, and another device's copy would bring the thing back.
        for state in before where state.isDeleted && state.type.deletesByTombstone {
            guard try !SyncRecordState.exists(db, key: state.recordName) else { continue }
            try queue(db, state.type, key: state.key, isDeleted: true, changedAt: state.modifiedAt)
        }
        for key in try placedPositionKeys(db) {
            try queue(db, .timelinePosition, key: key, changedAt: changed[SyncRecord.name(type: .timelinePosition, key: key)] ?? now)
        }
    }

    private static func queueEverything(_ db: Database, changedAt: (SyncRecordType, String) -> Date) throws {
        func queueAll(_ type: SyncRecordType, _ sql: String) throws {
            for key in try String.fetchAll(db, sql: sql) {
                try queue(db, type, key: key, changedAt: changedAt(type, key))
            }
        }
        try queueAll(.source, "SELECT id FROM source")
        try queueAll(.lastReadMarker, "SELECT viewID FROM lastReadMarker")
        // From v14; v8 runs this before the table exists.
        if try db.tableExists(ReadingPlace.databaseTableName) {
            try queueAll(.readingPlace, "SELECT viewID FROM readingPlace")
        }
        try queueAll(.articleReadState, "SELECT mergeKey FROM articleReadState")
        // From v15; earlier migrations run this before the table exists.
        if try db.tableExists(ArticleBookmark.databaseTableName) {
            try queueAll(.articleBookmark, "SELECT mergeKey FROM articleBookmark")
        }
        try queueAll(.setting, "SELECT key FROM syncedSetting")
        try queueAll(.savedView, "SELECT id FROM savedView")
        try queueAll(.contentFilter, "SELECT id FROM contentFilter")
    }

    /// Offers this device's position for every row that isn't simply at its
    /// publish date and has no position record yet, for a first sync.
    static func offerPlacedPositions(_ db: Database, at now: Date) throws {
        for key in try placedPositionKeys(db) {
            try offerPosition(db, mergeKey: key, at: now)
        }
    }

    /// The rows that aren't simply at their publish date, which is where
    /// every device would put them without being told. By the position
    /// held, so a row that arrived late and went below the reader's line
    /// (ADR 0041) counts.
    private static func placedPositionKeys(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT timelinePosition.mergeKey FROM timelinePosition
            JOIN item ON item.id = timelinePosition.itemID
            WHERE timelinePosition.sortDate != item.publishedAt
            """)
    }

    /// What waits to go up, oldest change first. A change to a record that
    /// iCloud has in a later version waits for this device to update, and
    /// isn't listed until then (`UnreadSyncRecord.isNewer`).
    static func pending(_ db: Database) throws -> [PendingSyncChange] {
        try SyncRecordState
            .filter(Column("pending") != nil)
            .filter(sql: "recordName NOT IN (SELECT recordName FROM unreadSyncRecord WHERE isNewer)")
            .order(Column("pending"))
            .fetchAll(db)
            .map { PendingSyncChange(name: $0.recordName, type: $0.type, isDeletion: $0.goesAsDeletion) }
    }

    /// A number for a new local change, never given out before, even for
    /// a change since sent: a save confirmed late for an old number must
    /// not clear a newer change that reused it. Kept in `syncVersion` from
    /// v11; the migrations before it count from the outbox.
    static func nextVersion(_ db: Database) throws -> Int64 {
        let fromOutbox = try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(pending), 0) + 1 FROM syncRecord") ?? 1
        guard try db.tableExists("syncVersion") else { return fromOutbox }
        let last = try Int64.fetchOne(db, sql: "SELECT last FROM syncVersion WHERE id = 1") ?? 0
        let next = max(fromOutbox, last + 1)
        try db.execute(sql: "INSERT INTO syncVersion (id, last) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET last = excluded.last", arguments: [next])
        return next
    }

    /// The payload for a record as the store has it now, or nil if what it
    /// describes has gone.
    static func payload(for state: SyncRecordState, _ db: Database) throws -> Data? {
        switch state.type {
        case .source:
            return try Source.fetchOne(db, key: state.key).map {
                try SyncCoding.encode(SourcePayload(source: $0, modifiedAt: state.modifiedAt), for: state.type)
            }
        case .lastReadMarker:
            return try LastReadMarker.fetchOne(db, key: state.key).map {
                try SyncCoding.encode(LastReadMarkerPayload(viewID: $0.viewID, mergeKey: $0.mergeKey, sortDate: $0.sortDate, updatedAt: $0.updatedAt), for: state.type)
            }
        case .readingPlace:
            // The record's clock still goes with it, for versions from
            // before moves were counted, which take the latest.
            return try ReadingPlace.fetchOne(db, key: state.key).map {
                try SyncCoding.encode(ReadingPlacePayload(viewID: $0.viewID, mergeKey: $0.mergeKey, sortDate: $0.sortDate,
                                                       updatedAt: state.modifiedAt, move: $0.move, device: $0.device), for: state.type)
            }
        case .articleReadState:
            return try ArticleReadState.fetchOne(db, key: state.key).map {
                try SyncCoding.encode(ArticleReadStatePayload(mergeKey: $0.mergeKey, isRead: $0.isRead, updatedAt: $0.updatedAt), for: state.type)
            }
        case .articleBookmark:
            return try ArticleBookmark.fetchOne(db, key: state.key).map {
                try SyncCoding.encode(ArticleBookmarkPayload(mergeKey: $0.mergeKey, isBookmarked: $0.isBookmarked, updatedAt: $0.updatedAt), for: state.type)
            }
        case .timelinePosition:
            return try PositionClaim.current(state.key, state: state, db).map {
                try SyncCoding.encode(TimelinePositionPayload(mergeKey: state.key, sortDate: $0.sortDate, placedAt: $0.placedAt), for: state.type)
            }
        case .setting:
            return try SyncedSetting.fetchOne(db, key: state.key).map {
                try SyncCoding.encode(SettingPayload(key: $0.key, value: $0.value, modifiedAt: state.modifiedAt), for: state.type)
            }
        case .savedView:
            return try SavedView.fetchOne(db, key: state.key).map {
                try SyncCoding.encode(SavedViewPayload(view: $0, modifiedAt: state.modifiedAt), for: state.type)
            }
        case .contentFilter:
            return try ContentFilter.fetchOne(db, key: state.key).map {
                try SyncCoding.encode(ContentFilterPayload(filter: $0, modifiedAt: state.modifiedAt), for: state.type)
            }
        }
    }
}

// MARK: Positions

/// A position for a row, and when the device it came from first stored the
/// row: the earliest wins.
struct PositionClaim: Hashable {
    var sortDate: Date
    var placedAt: Date

    func isEarlier(than other: PositionClaim) -> Bool {
        (placedAt, sortDate) < (other.placedAt, other.sortDate)
    }

    /// This device's claim on a row: the position it holds, placed when
    /// its first copy was fetched, or at `state`'s time (the claim it
    /// adopted or offered) when that is earlier. Nil when the row isn't
    /// stored here.
    ///
    /// The position is always the one held, never one worked out again
    /// from the item's dates. A row that arrived late can sit below the
    /// reader's line, not at its own date (ADR 0041; at the bottom of the
    /// timeline under ADR 0022). Claiming the date sent iCloud a position
    /// this device never gave the row, and the next merge of that record
    /// moved the row up to it, hours above the reader (influx-dev #125).
    static func current(_ mergeKey: String, state: SyncRecordState?, _ db: Database) throws -> PositionClaim? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT timelinePosition.sortDate AS held, item.fetchedAt AS fetchedAt
            FROM timelinePosition LEFT JOIN item ON item.id = timelinePosition.itemID
            WHERE timelinePosition.mergeKey = ?
            """, arguments: [mergeKey]) else { return nil }
        var placedAt = state?.modifiedAt ?? .distantFuture
        if let fetchedAt: Date = row["fetchedAt"] { placedAt = min(placedAt, fetchedAt) }
        return PositionClaim(sortDate: row["held"], placedAt: placedAt)
    }
}

// MARK: Merging what arrives

enum SyncMerge {
    /// What merging one record decided.
    private enum Outcome {
        /// The record as it arrived is now the state here; `modifiedAt` is
        /// its last-writer-wins clock.
        case tookRemote(modifiedAt: Date)
        /// A tombstone at least as late as any change here: the record is
        /// deleted here too.
        case tookRemoteDeletion(modifiedAt: Date)
        /// This device's state wins and goes up again.
        case keptLocal
        /// A position here was placed earlier than the one that arrived, so
        /// it wins and goes up again, stamped with when it was placed.
        case keptLocalPosition(placedAt: Date)
        /// A position waiting for its row was placed earlier than the one
        /// that arrived, and stays; this device can't send it without the
        /// row, so only the server fields are kept.
        case keptWaiting
        /// The record couldn't be read, e.g. from a newer version of Influx;
        /// only its server fields are kept.
        case unreadable
    }

    static func merge(_ fetched: FetchedSyncRecord, _ db: Database, at now: Date, into result: inout SyncMergeResult) throws {
        let record = fetched.record
        // A name that doesn't match its key isn't one this store made.
        guard record.name == SyncRecord.name(type: record.type, key: record.key) else { return }
        let state = try SyncRecordState.fetchOne(db, key: record.name)
        // What this device held before, for the journal.
        let before = try Position.held(record.type, key: record.key, db)

        // A later version of this type's payload isn't read, even where
        // its fields would decode: they may not mean what they did.
        let isNewer = SyncCoding.version(of: record.payload) > record.type.payloadVersion
        let outcome: Outcome
        if isNewer {
            outcome = .unreadable
        } else if record.type.deletesByTombstone, let tombstone = SyncCoding.decode(SyncTombstone.self, from: record.payload) {
            outcome = try mergeTombstone(tombstone, record: record, local: state, db, at: now)
        } else {
            switch record.type {
            case .source:
                outcome = try mergeSource(record, local: state, db)
            case .lastReadMarker:
                outcome = try mergeMarker(record, db)
            case .readingPlace:
                outcome = try mergePlace(record, local: state, db)
            case .articleReadState:
                outcome = try mergeArticleReadState(record, db)
            case .articleBookmark:
                outcome = try mergeArticleBookmark(record, db)
            case .timelinePosition:
                outcome = try mergePosition(record, local: state, db, at: now)
            case .setting:
                outcome = try mergeSetting(record, local: state, db)
            case .savedView:
                outcome = try lastWriterWins(record, local: state, SavedViewPayload.self, key: \.view.id, modifiedAt: \.modifiedAt) {
                    try $0.view.upsert(db)
                }
            case .contentFilter:
                outcome = try lastWriterWins(record, local: state, ContentFilterPayload.self, key: \.filter.id, modifiedAt: \.modifiedAt) {
                    try $0.filter.upsert(db)
                }
            }
        }

        var updated = state ?? SyncRecordState(
            recordName: record.name, type: record.type, key: record.key, modifiedAt: now,
            systemFields: nil, pending: nil, isDeleted: false
        )
        updated.systemFields = fetched.systemFields
        switch outcome {
        case .tookRemote(let modifiedAt):
            updated.modifiedAt = modifiedAt
            updated.pending = nil
            updated.isDeleted = false
            result.changed.insert(record.type)
        case .tookRemoteDeletion(let modifiedAt):
            updated.modifiedAt = modifiedAt
            updated.pending = nil
            updated.isDeleted = true
            result.changed.insert(record.type)
        case .keptLocal, .keptLocalPosition:
            if case .keptLocalPosition(let placedAt) = outcome {
                updated.modifiedAt = placedAt
            }
            if updated.pending == nil {
                updated.pending = try SyncLog.nextVersion(db)
            }
            result.toSend.append(PendingSyncChange(name: record.name, type: record.type, isDeletion: updated.goesAsDeletion))
        case .unreadable, .keptWaiting:
            break
        }
        if case .unreadable = outcome {
            // Nothing is known here of a record this build can't read but
            // what is kept, the server's fields with it. State made for it
            // now would say the thing last changed here, at this moment,
            // and win over the record when a build that reads it merges it.
            if state != nil {
                try updated.upsert(db)
            }
            try UnreadSyncRecord(
                recordName: record.name, type: record.type.rawValue, key: record.key, payload: record.payload,
                systemFields: fetched.systemFields, isNewer: isNewer, receivedAt: now
            ).upsert(db)
            result.unread += 1
        } else {
            try updated.upsert(db)
            // Whatever was kept under this name is behind what just merged.
            try UnreadSyncRecord.deleteOne(db, key: record.name)
        }
        if let before {
            let decision: String
            switch outcome {
            case .tookRemote: decision = "took it"
            case .tookRemoteDeletion: decision = "deleted here too"
            case .keptLocal, .keptLocalPosition: decision = "kept ours, which goes up again"
            case .keptWaiting: decision = "kept the one waiting"
            case .unreadable: decision = "couldn't read it"
            }
            let after = try Position.held(record.type, key: record.key, db)
            try SyncJournal.note(db, .merge, """
                \(before.name) of \(record.key) from iCloud: \(decision); ours was \(before.text), \
                now \(after?.text ?? "none")
                """, at: now)
        }
    }

    /// The reading place or marker a view holds, as the journal shows it;
    /// nil for the record types whose merges are only counted.
    private struct Position {
        var name: String
        var text: String

        static func held(_ type: SyncRecordType, key: String, _ db: Database) throws -> Position? {
            switch type {
            case .readingPlace:
                Position(name: "place", text: SyncJournal.describe(try ReadingPlace.fetchOne(db, key: key)))
            case .lastReadMarker:
                Position(name: "marker", text: SyncJournal.describe(try LastReadMarker.fetchOne(db, key: key)))
            default:
                nil
            }
        }
    }

    static func mergeDeletion(of name: String, _ db: Database, at now: Date, into result: inout SyncMergeResult) throws {
        try UnreadSyncRecord.deleteOne(db, key: name)
        guard var state = try SyncRecordState.fetchOne(db, key: name) else { return }
        if state.pending != nil, !state.isDeleted {
            // Changed here since: the change wins and goes up as a new record.
            state.systemFields = nil
            try state.upsert(db)
            result.toSend.append(PendingSyncChange(name: name, type: state.type, isDeletion: false))
            return
        }
        try removeLocal(state.type, key: state.key, db, at: now)
        try state.delete(db)
        result.changed.insert(state.type)
    }

    /// A tombstone: the later of it and the change here wins. A change made
    /// here after the deletion, or a later deletion, goes up again over it,
    /// so iCloud keeps the latest time for an edit elsewhere to lose to.
    private static func mergeTombstone(_ tombstone: SyncTombstone, record: SyncRecord, local: SyncRecordState?, _ db: Database, at now: Date) throws -> Outcome {
        if let local, local.modifiedAt > tombstone.deletedAt {
            return .keptLocal
        }
        try removeLocal(record.type, key: record.key, db, at: now)
        return .tookRemoteDeletion(modifiedAt: tombstone.deletedAt)
    }

    /// Deletes what a record of `type` describes here, for a deletion from
    /// another device.
    private static func removeLocal(_ type: SyncRecordType, key: String, _ db: Database, at now: Date) throws {
        switch type {
        case .source:
            try Source.deleteOne(db, key: key)
            try InfluxStore.deleteEmptyPositions(db, at: now)
        case .lastReadMarker:
            // Its saved view was deleted on another device.
            try LastReadMarker.deleteOne(db, key: key)
            try PendingLastReadMarker.filter(Column("viewID") == key).deleteAll(db)
        case .readingPlace:
            try ReadingPlace.deleteOne(db, key: key)
            try ReadingPlaceBase.deleteOne(db, key: key)
        case .articleReadState, .articleBookmark:
            break
        case .timelinePosition:
            // Aged out on another device. A row here keeps its place.
            try PendingTimelinePosition.deleteOne(db, key: key)
        case .setting:
            try SyncedSetting.deleteOne(db, key: key)
        case .savedView:
            // With its filters and marker, as deleting it here would.
            try InfluxStore.deleteView(id: key, db)
        case .contentFilter:
            try ContentFilter.deleteOne(db, key: key)
        }
    }

    /// Last writer wins, by the time each device changed the source.
    private static func mergeSource(_ record: SyncRecord, local: SyncRecordState?, _ db: Database) throws -> Outcome {
        guard let payload = SyncCoding.decode(SourcePayload.self, from: record.payload), payload.source.id == record.key else {
            return .unreadable
        }
        if let local, local.modifiedAt > payload.modifiedAt {
            return .keptLocal
        }
        try payload.source.upsert(db)
        return .tookRemote(modifiedAt: payload.modifiedAt)
    }

    /// The furthest marker wins, by this device's order of rows. Two
    /// devices whose positions aren't agreed yet can order the same rows
    /// differently, and then each can think its own marker is ahead. That
    /// is settled by the dates the senders used: whichever marker is ahead
    /// in the sender's order is the one both keep, so exactly one device
    /// resends and the other takes the arriving marker even though its own
    /// order puts it behind. Their orders agree once positions sync, and
    /// then a marker only ever moves forward again.
    private static func mergeMarker(_ record: SyncRecord, _ db: Database) throws -> Outcome {
        guard let payload = SyncCoding.decode(LastReadMarkerPayload.self, from: record.payload), payload.viewID == record.key else {
            return .unreadable
        }
        let remoteModified = payload.updatedAt
        let asSent = LastReadMarker(viewID: payload.viewID, sortDate: payload.sortDate, mergeKey: payload.mergeKey, updatedAt: payload.updatedAt)
        guard let localDate = try Date.fetchOne(db, sql: "SELECT sortDate FROM timelinePosition WHERE mergeKey = ?", arguments: [payload.mergeKey]) else {
            // Its row isn't here yet, and may never be (aged out, or never
            // fetched), so compare by the sender's date for it: a marker
            // here that is further along goes up, as the sending device
            // compares them the same way. Otherwise `insert` places the
            // arriving one when its row arrives.
            if let local = try LastReadMarker.fetchOne(db, key: payload.viewID), local.mergeKey != payload.mergeKey, local.isAhead(of: asSent) {
                return .keptLocal
            }
            try PendingLastReadMarker(viewID: payload.viewID, mergeKey: payload.mergeKey, updatedAt: payload.updatedAt, sortDate: payload.sortDate).upsert(db)
            return .tookRemote(modifiedAt: remoteModified)
        }
        let arriving = LastReadMarker(viewID: payload.viewID, sortDate: localDate, mergeKey: payload.mergeKey, updatedAt: payload.updatedAt)
        if try InfluxStore.advance(db, to: arriving) {
            return .tookRemote(modifiedAt: remoteModified)
        }
        guard let local = try LastReadMarker.fetchOne(db, key: payload.viewID), local.mergeKey != payload.mergeKey else {
            return .tookRemote(modifiedAt: remoteModified)
        }
        // Behind in this device's order, but the orders differ: compare
        // them again in the sender's order, where only one of the two can
        // be ahead.
        let localAsSent = try Date.fetchOne(db, sql: "SELECT sortDate FROM timelinePosition WHERE mergeKey = ?", arguments: [local.mergeKey]) ?? local.sortDate
        if LastReadMarker(viewID: local.viewID, sortDate: localAsSent, mergeKey: local.mergeKey, updatedAt: local.updatedAt).isAhead(of: asSent) {
            return .keptLocal
        }
        try arriving.upsert(db)
        return .tookRemote(modifiedAt: remoteModified)
    }

    /// The later change wins, and at the same instant "read" wins.
    private static func mergeArticleReadState(_ record: SyncRecord, _ db: Database) throws -> Outcome {
        guard let payload = SyncCoding.decode(ArticleReadStatePayload.self, from: record.payload), payload.mergeKey == record.key else {
            return .unreadable
        }
        let arriving = ArticleReadState(mergeKey: payload.mergeKey, isRead: payload.isRead, updatedAt: payload.updatedAt)
        if let current = try ArticleReadState.fetchOne(db, key: payload.mergeKey), current.supersedes(arriving) {
            return .keptLocal
        }
        try arriving.upsert(db)
        return .tookRemote(modifiedAt: payload.updatedAt)
    }

    /// The later change wins, and at the same instant the bookmark wins.
    private static func mergeArticleBookmark(_ record: SyncRecord, _ db: Database) throws -> Outcome {
        guard let payload = SyncCoding.decode(ArticleBookmarkPayload.self, from: record.payload), payload.mergeKey == record.key else {
            return .unreadable
        }
        let arriving = ArticleBookmark(mergeKey: payload.mergeKey, isBookmarked: payload.isBookmarked, updatedAt: payload.updatedAt)
        if let current = try ArticleBookmark.fetchOne(db, key: payload.mergeKey), current.supersedes(arriving) {
            return .keptLocal
        }
        try arriving.upsert(db)
        return .tookRemote(modifiedAt: payload.updatedAt)
    }

    /// The position iCloud has is the first one stored, and it wins: the
    /// row moves to it, with any marker on the row.
    /// The position placed earliest wins: this device's own (when it first
    /// stored the row), the one it holds, or the one that arrived. The row
    /// moves to it, with any marker on it. Earliest rather than first
    /// uploaded, so a device that stored the row hours before it could
    /// reach iCloud still wins over one that fetched it later.
    private static func mergePosition(_ record: SyncRecord, local: SyncRecordState?, _ db: Database, at now: Date) throws -> Outcome {
        guard let payload = SyncCoding.decode(TimelinePositionPayload.self, from: record.payload), payload.mergeKey == record.key else {
            return .unreadable
        }
        let remote = PositionClaim(sortDate: payload.sortDate, placedAt: payload.placedAt ?? .distantFuture)
        guard let held = try Date.fetchOne(db, sql: "SELECT sortDate FROM timelinePosition WHERE mergeKey = ?", arguments: [payload.mergeKey]) else {
            // No row here yet. A position already waiting for it, taken
            // from an earlier-placed claim (the state's time), stays: the
            // direct fetch and the engine can deliver versions out of order.
            if let waiting = try PendingTimelinePosition.fetchOne(db, key: payload.mergeKey), let local,
               PositionClaim(sortDate: waiting.sortDate, placedAt: local.modifiedAt).isEarlier(than: remote) {
                return .keptWaiting
            }
            try PendingTimelinePosition(mergeKey: payload.mergeKey, sortDate: payload.sortDate, receivedAt: now).upsert(db)
            return .tookRemote(modifiedAt: payload.placedAt ?? now)
        }
        let here = try PositionClaim.current(payload.mergeKey, state: local, db)
        let winner = here.map { remote.isEarlier(than: $0) || remote == $0 ? remote : $0 } ?? remote
        if winner.sortDate != held {
            try db.execute(sql: "UPDATE timelinePosition SET sortDate = ? WHERE mergeKey = ?", arguments: [winner.sortDate, payload.mergeKey])
            try db.execute(sql: "UPDATE lastReadMarker SET sortDate = ? WHERE mergeKey = ?", arguments: [winner.sortDate, payload.mergeKey])
        }
        return winner == remote ? .tookRemote(modifiedAt: payload.placedAt ?? now) : .keptLocalPosition(placedAt: winner.placedAt)
    }

    /// The reading place (ADR 0028). No clock is compared.
    ///
    /// With nothing waiting to go up here, the place that arrives was made
    /// knowing this one, or settled by this rule elsewhere: the one with
    /// more moves behind it stands, and of two with the same number, the
    /// one further along, so every device ends on the same place.
    ///
    /// A move made here that iCloud hasn't had yet is different: the place
    /// here waits to go up, and is not the last one iCloud and this device
    /// both had. A place that arrives then, and is news (not this device's
    /// own coming back, and later than that last shared place), was made
    /// without knowing of the move here, as the move here was made without
    /// knowing of it. The one further along stands: reading on is never
    /// undone by a device that hadn't seen it. If that is the place here,
    /// it becomes the move after the one that arrived, and goes up again.
    /// If it isn't, the move made here stays on this device.
    private static func mergePlace(_ record: SyncRecord, local: SyncRecordState?, _ db: Database) throws -> Outcome {
        guard let payload = SyncCoding.decode(ReadingPlacePayload.self, from: record.payload), payload.viewID == record.key else {
            return .unreadable
        }
        let theirs = ReadingPlace(viewID: payload.viewID, mergeKey: payload.mergeKey, sortDate: payload.sortDate,
                                  updatedAt: payload.updatedAt, move: payload.move ?? 0, device: payload.device)
        func take() throws -> Outcome {
            try theirs.upsert(db)
            try ReadingPlaceBase(theirs).upsert(db)
            return .tookRemote(modifiedAt: theirs.updatedAt)
        }
        guard var ours = try ReadingPlace.fetchOne(db, key: theirs.viewID), ours.identity != theirs.identity else {
            return try take()
        }
        let base = try ReadingPlaceBase.fetchOne(db, key: theirs.viewID)?.place
        // The place here can also wait to go up without anyone having
        // moved: it stood over an older one that arrived, and is being
        // sent again. It is still the place iCloud had, so that is not a
        // move, and the ordinary rule below applies.
        let movedHere = local?.pending != nil && !(local?.isDeleted ?? false) && base?.identity != ours.identity
        if movedHere {
            let isOurs = try theirs.device != nil && theirs.device == SyncLog.device(db)
            guard !isOurs, base.map({ theirs.supersedes($0) }) ?? true else { return .keptLocal }
            guard try furtherAlong(ours, than: theirs, db) else { return try take() }
            if ours.move <= theirs.move {
                ours.move = theirs.move + 1
                try ours.upsert(db)
            }
            return .keptLocal
        }
        guard theirs.supersedes(ours) else { return .keptLocal }
        return try take()
    }

    /// Whether `place` is further along the timeline than `other`. A place
    /// carries its row's date as the device that set it had it; where this
    /// device has the row, its own date for it is the one the rows here
    /// are ordered by.
    static func furtherAlong(_ place: ReadingPlace, than other: ReadingPlace, _ db: Database) throws -> Bool {
        func here(_ place: ReadingPlace) throws -> ReadingPlace {
            var place = place
            if let date = try Date.fetchOne(db, sql: "SELECT sortDate FROM timelinePosition WHERE mergeKey = ?", arguments: [place.mergeKey]) {
                place.sortDate = date
            }
            return place
        }
        return try here(place).isFurtherAlong(than: here(other))
    }

    /// Last writer wins, by the time each device made its change; a record
    /// that can't be read, or whose key doesn't match, changes nothing.
    private static func lastWriterWins<Payload: Decodable>(
        _ record: SyncRecord, local: SyncRecordState?, _ type: Payload.Type,
        key: KeyPath<Payload, String>, modifiedAt: KeyPath<Payload, Date>,
        store: (Payload) throws -> Void
    ) throws -> Outcome {
        guard let payload = SyncCoding.decode(type, from: record.payload), payload[keyPath: key] == record.key else {
            return .unreadable
        }
        if let local, local.modifiedAt > payload[keyPath: modifiedAt] {
            return .keptLocal
        }
        try store(payload)
        return .tookRemote(modifiedAt: payload[keyPath: modifiedAt])
    }

    /// Last writer wins, as for sources.
    private static func mergeSetting(_ record: SyncRecord, local: SyncRecordState?, _ db: Database) throws -> Outcome {
        guard let payload = SyncCoding.decode(SettingPayload.self, from: record.payload), payload.key == record.key else {
            return .unreadable
        }
        if let local, local.modifiedAt > payload.modifiedAt {
            return .keptLocal
        }
        try SyncedSetting(key: payload.key, value: payload.value).upsert(db)
        return .tookRemote(modifiedAt: payload.modifiedAt)
    }
}

/// The store's sync work, shared by the async calls and the blocking ones
/// (`InfluxStore.BlockingSync`).
enum SyncWork {
    static func record(named name: String, _ db: Database) throws -> OutgoingSyncRecord? {
        guard let state = try SyncRecordState.fetchOne(db, key: name), let version = state.pending else {
            return nil
        }
        // iCloud has a later version of this record than this build
        // reads: the change here waits for an update.
        guard try UnreadSyncRecord.filter(key: name).filter(Column("isNewer") == true).isEmpty(db) else {
            return nil
        }
        if state.isDeleted {
            guard state.type.deletesByTombstone else { return nil }
            return OutgoingSyncRecord(
                record: SyncRecord(type: state.type, key: state.key, payload: try SyncCoding.encode(SyncTombstone(deletedAt: state.modifiedAt), for: state.type)),
                systemFields: state.systemFields, version: version
            )
        }
        guard let payload = try SyncLog.payload(for: state, db) else {
            // Gone without a deletion, e.g. a position whose row was
            // removed before it was sent: nothing to send.
            if state.systemFields == nil {
                try state.delete(db)
            } else {
                try db.execute(sql: "UPDATE syncRecord SET pending = NULL WHERE recordName = ?", arguments: [name])
            }
            return nil
        }
        return OutgoingSyncRecord(
            record: SyncRecord(type: state.type, key: state.key, payload: payload),
            systemFields: state.systemFields, version: version
        )
    }
    static func didSave(_ saved: [SavedSyncRecord], _ db: Database) throws {
        for record in saved {
            try db.execute(sql: """
                UPDATE syncRecord SET systemFields = ?, pending = CASE WHEN pending = ? THEN NULL ELSE pending END
                WHERE recordName = ?
                """, arguments: [record.systemFields, record.version, record.name])
        }
        guard !saved.isEmpty else { return }
        // iCloud now has what this device sent under these names. A copy
        // kept of what it had before is of a record that is gone, and
        // reading it later would undo the change.
        _ = try UnreadSyncRecord.filter(keys: saved.map(\.name)).deleteAll(db)
        let states = try SyncRecordState.filter(keys: saved.map(\.name)).fetchAll(db)
        var line = "iCloud took \(tally(states.map(\.type)))"
        // Which places went. Only the place held now is stored: when a
        // newer move still waits, the one iCloud took was an earlier one,
        // and the line must not say the place held now reached iCloud.
        for state in states where state.type == .readingPlace {
            let held = try ReadingPlace.fetchOne(db, key: state.key)
            // With nothing newer waiting, the place here is the one iCloud
            // now has too.
            if state.pending == nil, let held {
                try ReadingPlaceBase(held).upsert(db)
            }
            let place = SyncJournal.describe(held)
            line += state.pending == nil
                ? "; place of \(state.key) \(place)"
                : "; an earlier place of \(state.key), the place here is now \(place) and still to go"
        }
        try SyncJournal.note(db, .sync, line)
    }

    /// "3 records: LastReadMarker 1, ReadingPlace 2".
    static func tally(_ types: [SyncRecordType]) -> String {
        let counts = Dictionary(grouping: types, by: \.rawValue).mapValues(\.count)
        let each = counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "\(types.count) record\(types.count == 1 ? "" : "s")\(each.isEmpty ? "" : ": \(each)")"
    }

    static func didDelete(_ names: [String], _ db: Database) throws {
        _ = try SyncRecordState.filter(keys: names).filter(Column("isDeleted") == true).deleteAll(db)
        // A copy kept of a record iCloud no longer has would bring it back.
        _ = try UnreadSyncRecord.filter(keys: names).deleteAll(db)
    }

    static func forgetSystemFields(_ names: [String], _ db: Database) throws {
        _ = try SyncRecordState.filter(keys: names).updateAll(db, Column("systemFields").set(to: nil))
        _ = try UnreadSyncRecord.filter(keys: names).deleteAll(db)
    }

    static func merge(_ records: [FetchedSyncRecord], unknown: [UnknownSyncRecord] = [], deletions: [String], _ db: Database,
                      at now: Date) throws -> SyncMergeResult {
        var result = SyncMergeResult()
        for fetched in records {
            try SyncMerge.merge(fetched, db, at: now, into: &result)
        }
        for record in unknown {
            try UnreadSyncRecord(
                recordName: record.name, type: record.type, key: record.key, payload: record.payload,
                systemFields: record.systemFields, isNewer: true, receivedAt: now
            ).upsert(db)
            result.unread += 1
        }
        for name in deletions {
            try SyncMerge.mergeDeletion(of: name, db, at: now, into: &result)
        }
        if !records.isEmpty || !deletions.isEmpty || !unknown.isEmpty {
            var kept = ""
            if result.unread > 0 {
                let which = try unreadTally(db, in: records.map(\.record.name) + unknown.map(\.name))
                kept = """
                    ; \(result.unread) couldn't be read by this version of Influx (\(which)) and \
                    \(result.unread == 1 ? "is" : "are") kept to read after an update
                    """
            }
            try SyncJournal.note(db, .merge, """
                merged \(tally(records.map(\.record.type))) and \(deletions.count) deletion\(deletions.count == 1 ? "" : "s") \
                from iCloud; \(result.toSend.count) of ours won and go up again\(kept)
                """, at: now)
        }
        return result
    }

    /// "Source 1, Widget (from a newer version) 2": the kept records among
    /// `names`, by type, for the journal.
    private static func unreadTally(_ db: Database, in names: [String]) throws -> String {
        let kept = try UnreadSyncRecord.filter(keys: names).fetchAll(db)
        let counts = Dictionary(grouping: kept) { "\($0.type)\($0.isNewer ? " (from a newer version)" : "")" }.mapValues(\.count)
        return counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    /// Merges the kept records again (`InfluxStore.readKeptSyncRecords`).
    /// One this build reads now merges by its type's rule, against
    /// whatever changed here while it was kept, and is no longer kept.
    static func readKept(_ db: Database, at now: Date) throws -> SyncMergeResult {
        var result = SyncMergeResult()
        let kept = try UnreadSyncRecord.order(Column("receivedAt"), Column("recordName")).fetchAll(db)
        for unread in kept {
            // Still a type this build has no name for.
            guard let type = SyncRecordType(rawValue: unread.type) else { continue }
            let record = SyncRecord(type: type, key: unread.key, payload: unread.payload)
            guard record.name == unread.recordName else { continue }
            try SyncMerge.merge(FetchedSyncRecord(record: record, systemFields: unread.systemFields), db, at: now, into: &result)
        }
        let read = kept.count - (try UnreadSyncRecord.fetchCount(db))
        if read > 0 {
            try SyncJournal.note(db, .merge, """
                read \(read) of \(kept.count) record\(kept.count == 1 ? "" : "s") an earlier version of Influx kept; \
                \(result.toSend.count) of ours won and go up
                """, at: now)
        }
        return result
    }

    /// Forgets what the store knew of iCloud: the server's fields for
    /// every record, what waited for a row, what was kept unread, and the
    /// engine's state, so the next fetch brings everything again.
    ///
    /// With `uploadingEverything`, what the store knew of its own data
    /// stays: when each thing last changed, which deletions it sent, and
    /// the reading place it and iCloud both had. Everything goes up
    /// again with those, and merges with what comes down by the usual
    /// rules (`SyncLog.enqueueEverything(_:after:at:)`).
    static func reset(uploadingEverything: Bool, _ db: Database, at now: Date) throws {
        let before = try SyncRecordState.fetchAll(db)
        try SyncRecordState.deleteAll(db)
        // What was kept comes again with everything else.
        try UnreadSyncRecord.deleteAll(db)
        try PendingTimelinePosition.deleteAll(db)
        try db.execute(sql: "DELETE FROM syncEngineState")
        if uploadingEverything {
            try SyncLog.enqueueEverything(db, after: before, at: now)
        } else {
            try ReadingPlaceBase.deleteAll(db)
        }
        try SyncJournal.note(db, .sync, """
            sync started over\(uploadingEverything ? ", everything here queued to go up, each with when it last changed" : "")
            """, at: now)
    }
}

extension InfluxStore {
    /// The sync calls the CloudKit framework needs answered on its own
    /// thread, which waits for them. They wait only on the store's queue.
    /// The async calls can't be waited on that way: the framework calls
    /// from Swift concurrency's thread pool, and a pool thread that blocks
    /// until a task finishes deadlocks once every pool thread does it,
    /// since none is left to run the tasks. Never call
    /// these on the main thread.
    public var blocking: BlockingSync { BlockingSync(writer: writer) }

    public struct BlockingSync: Sendable {
        let writer: any DatabaseWriter

        /// Up to `limit` pending changes, each with the record to save, or
        /// nil for a deletion or a change with nothing to send, read in one
        /// transaction.
        public func pendingBatch(limit: Int) throws -> [(change: PendingSyncChange, record: OutgoingSyncRecord?)] {
            try writer.write { db in
                try SyncLog.pending(db).prefix(limit).map { change in
                    (change: change, record: change.isDeletion ? nil : try SyncWork.record(named: change.name, db))
                }
            }
        }

        public func didSaveSyncRecords(_ saved: [SavedSyncRecord]) throws {
            try writer.write { db in try SyncWork.didSave(saved, db) }
        }

        public func didDeleteSyncRecords(named names: [String]) throws {
            try writer.write { db in try SyncWork.didDelete(names, db) }
        }

        public func forgetSyncSystemFields(named names: [String]) throws {
            try writer.write { db in try SyncWork.forgetSystemFields(names, db) }
        }

        public func mergeSyncRecords(_ records: [FetchedSyncRecord], unknown: [UnknownSyncRecord] = [], deletions: [String] = [],
                                     at now: Date = Date()) throws -> SyncMergeResult {
            try writer.write { db in try SyncWork.merge(records, unknown: unknown, deletions: deletions, db, at: now) }
        }

        public func resetSync(uploadingEverything: Bool, at now: Date = Date()) throws {
            try writer.write { db in try SyncWork.reset(uploadingEverything: uploadingEverything, db, at: now) }
        }
    }
}
