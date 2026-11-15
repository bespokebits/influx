import Foundation
import GRDB

// The sync journal: what this device did with the reader's place, and what
// iCloud sent it, kept for days so that a timeline that opened in the wrong
// place can be explained afterwards. The logs before it were the last 40 and
// 60 lines in the app's defaults, which the sync poll filled in under two
// minutes, so by the time a bad open was noticed they no longer held it.
//
// The store writes its own lines in the same transaction as the change they
// describe, so the journal can't say something happened that didn't. The app
// adds what only it knows: what the timeline did, and when the app came and
// went.

/// One line of the sync journal.
public struct SyncJournalEntry: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    /// What a line is about.
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The app starting, leaving the screen and coming back.
        case app
        /// The reading place or last-read marker saved on this device.
        case place
        /// What arrived from iCloud, and which side won.
        case merge
        /// What iCloud took from this device, and sync starting over.
        case sync
        /// What the timeline did: following a place, holding its top row.
        case timeline
    }

    public var id: Int64?
    public var at: Date
    public var kind: Kind
    public var message: String

    public static let databaseTableName = "syncJournal"

    /// The line as the journal's text shows it.
    public var line: String {
        "\(SyncJournal.stamp(at)) \(kind.rawValue): \(message)"
    }
}

enum SyncJournal {
    /// How long a line is kept, and the most lines kept whatever their age.
    static let keptFor: TimeInterval = 7 * 86_400
    static let limit = 20_000
    /// Old lines go once in this many writes, not on every one.
    static let pruneEvery: Int64 = 200

    static func note(_ db: Database, _ kind: SyncJournalEntry.Kind, _ message: String, at now: Date = Date()) throws {
        // The migrations before v20 record synced changes too, before the
        // table exists.
        guard try db.tableExists(SyncJournalEntry.databaseTableName) else { return }
        try SyncJournalEntry(id: nil, at: now, kind: kind, message: message).insert(db)
        let id = db.lastInsertedRowID
        guard id % pruneEvery == 0 else { return }
        try db.execute(
            sql: "DELETE FROM syncJournal WHERE at < ? OR id <= ?",
            arguments: [now.addingTimeInterval(-keptFor), id - Int64(limit)]
        )
    }

    /// A time to the millisecond, in UTC: places are compared by their
    /// stamps, and two moves are often less than a second apart.
    static func stamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    /// A reading place in a line: its row, which move of the shared place
    /// it is, and when the reader moved there.
    static func describe(_ place: ReadingPlace?) -> String {
        guard let place else { return "none" }
        return "\(place.mergeKey), move \(place.move), moved \(stamp(place.updatedAt))"
    }

    static func describe(_ marker: LastReadMarker?) -> String {
        guard let marker else { return "none" }
        return "\(marker.mergeKey) at \(stamp(marker.sortDate))"
    }
}

extension InfluxStore {
    /// Adds a line to the sync journal. Never fails: a journal that can't
    /// be written must not stop what it describes.
    public func noteInJournal(_ kind: SyncJournalEntry.Kind, _ message: String, at now: Date = Date()) async {
        _ = try? await writer.write { db in try SyncJournal.note(db, kind, message, at: now) }
    }

    /// The journal's lines since `date`, oldest first, the newest `limit`
    /// of them.
    public func syncJournal(since date: Date = .distantPast, limit: Int = 3_000) async throws -> [SyncJournalEntry] {
        try await writer.read { db in
            try SyncJournalEntry
                .filter(Column("at") >= date)
                .order(Column("at").desc, Column("id").desc)
                .limit(limit)
                .fetchAll(db)
                .reversed()
        }
    }
}
