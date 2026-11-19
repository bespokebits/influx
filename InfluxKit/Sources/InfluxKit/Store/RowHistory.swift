import Foundation
import GRDB

// Why each row sits where it does (influx-dev#285, ADR 0043). A row's
// position is fixed when it is first stored, by one of three rules (its own
// time, below the reader's line, or a position from iCloud), and can move
// later when another device's position wins. Before this record nothing
// said which rule placed a row, so a row that showed up late on one device
// could not be explained from the device. The store writes each event in
// the same transaction as the change it describes, so the history can't
// say something happened that didn't. It stays on the device, and goes
// with the row's last item.

/// One thing that happened to a row's position on this device.
public struct RowEvent: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The row was first stored here, and placed.
        case placed
        /// Another copy of the post arrived and joined the row without
        /// moving it.
        case joined
        /// A position from iCloud won over the one held here, and the row
        /// moved.
        case moved
    }

    /// The rule that placed a new row.
    public enum How: String, Codable, Sendable, CaseIterable {
        /// By its own time: its date, never later than its fetch.
        case ownTime
        /// Directly below the reader's line (ADR 0041).
        case belowLine
        /// At a position another device gave through iCloud, which arrived
        /// before the row did.
        case iCloud
    }

    /// What brought the item.
    public enum Via: String, Codable, Sendable, CaseIterable {
        /// A source's first fetch, whose items keep their own dates.
        case firstFetch
        /// A fetch of the source's newer items.
        case refresh
        /// A page of older items, fetched going back.
        case olderPage
        /// A stream: a Mastodon home stream or a rich feed's change stream.
        case stream
        /// An account's bookmark list.
        case bookmarks
        /// Stored directly, as the seed feed does.
        case direct
    }

    public var id: Int64?
    public var mergeKey: String
    /// When it happened, on this device's clock.
    public var at: Date
    public var kind: Kind
    /// Where the row sits after it.
    public var sortDate: Date
    /// The copy that arrived (`placed`, `joined`).
    public var sourceID: String?
    public var remoteID: String?
    public var publishedAt: Date?
    public var fetchedAt: Date?
    public var via: Via?
    public var how: How?
    /// The row's line when it was placed, whether or not it held the row:
    /// the view, which of its marker, place and last row on screen was
    /// furthest, and where that was.
    public var lineView: String?
    public var lineBound: String?
    public var lineDate: Date?
    /// Where the row sat before it moved (`moved`).
    public var previous: Date?
    /// Whether this device offered the row's position to iCloud.
    public var offered: Bool

    public static let databaseTableName = "rowEvent"

    public init(id: Int64? = nil, mergeKey: String, at: Date, kind: Kind, sortDate: Date, sourceID: String? = nil,
                remoteID: String? = nil, publishedAt: Date? = nil, fetchedAt: Date? = nil, via: Via? = nil, how: How? = nil,
                lineView: String? = nil, lineBound: String? = nil, lineDate: Date? = nil, previous: Date? = nil,
                offered: Bool = false) {
        self.id = id
        self.mergeKey = mergeKey
        self.at = at
        self.kind = kind
        self.sortDate = sortDate
        self.sourceID = sourceID
        self.remoteID = remoteID
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.via = via
        self.how = how
        self.lineView = lineView
        self.lineBound = lineBound
        self.lineDate = lineDate
        self.previous = previous
        self.offered = offered
    }

    /// The event as text, times to the millisecond in UTC like the sync
    /// journal's.
    public var line: String {
        var parts = ["\(SyncJournal.stamp(at)) \(kind.rawValue) \(mergeKey) at \(SyncJournal.stamp(sortDate))"]
        if let how { parts.append("by \(how.rawValue)") }
        if let previous { parts.append("from \(SyncJournal.stamp(previous))") }
        if let sourceID { parts.append("copy \(sourceID)/\(remoteID ?? "?")") }
        if let via { parts.append("via \(via.rawValue)") }
        if let publishedAt { parts.append("published \(SyncJournal.stamp(publishedAt))") }
        if let fetchedAt { parts.append("fetched \(SyncJournal.stamp(fetchedAt))") }
        if let lineDate {
            parts.append("line \(lineView ?? "?") \(lineBound ?? "?") at \(SyncJournal.stamp(lineDate))")
        } else if kind == .placed {
            parts.append("no line")
        }
        if offered { parts.append("offered to iCloud") }
        return parts.joined(separator: ", ")
    }

    /// Whether the event says something out of the ordinary: a row placed
    /// anywhere but by its own time, or one that moved. Diagnostics list
    /// these, and only count the rest.
    public var isNotable: Bool {
        kind == .moved || (kind == .placed && how != .ownTime)
    }
}

/// Everything this device knows about why one row sits where it does.
public struct RowHistory: Sendable, Hashable {
    /// One stored copy of the post.
    public struct Copy: Sendable, Hashable {
        public var sourceID: String
        public var sourceTitle: String?
        public var sourceKind: String?
        public var remoteID: String
        public var url: String?
        public var publishedAt: Date
        public var fetchedAt: Date
        /// Whether the row is shown from this copy.
        public var isShown: Bool
    }

    public var mergeKey: String
    /// Where the row sits now; nil when it has no position.
    public var sortDate: Date?
    public var copies: [Copy]
    /// What happened to the row here, oldest first. Empty for a row stored
    /// before the history was kept.
    public var events: [RowEvent]
    /// Whether a position for the row is waiting to go to iCloud from here.
    public var positionWaitingToSend: Bool
    /// Whether iCloud has a position record for the row that this device
    /// knows of.
    public var positionInICloud: Bool

    /// The history as text, for copying.
    public var text: String {
        var lines = ["Row \(mergeKey)", "Sits at \(sortDate.map(SyncJournal.stamp) ?? "nowhere")"]
        lines.append("Position in iCloud: \(positionInICloud ? "yes" : "not known here"); waiting to send: \(positionWaitingToSend ? "yes" : "no")")
        lines.append("")
        lines.append("Copies (\(copies.count))")
        for copy in copies {
            var parts = ["\(copy.isShown ? "* " : "  ")\(copy.sourceTitle ?? copy.sourceID) [\(copy.sourceKind ?? "?")] \(copy.remoteID)"]
            parts.append("published \(SyncJournal.stamp(copy.publishedAt))")
            parts.append("fetched \(SyncJournal.stamp(copy.fetchedAt))")
            lines.append(parts.joined(separator: ", "))
            if let url = copy.url { lines.append("    \(url)") }
        }
        lines.append("")
        lines.append(events.isEmpty ? "History: none kept (stored before this build kept it)" : "History (\(events.count))")
        lines += events.map(\.line)
        return lines.joined(separator: "\n")
    }
}

enum RowEvents {
    static func record(_ event: RowEvent, _ db: Database) throws {
        // The migrations before the table exists can place rows too.
        guard try db.tableExists(RowEvent.databaseTableName) else { return }
        try event.insert(db)
    }

    /// Drops the history of rows whose items have all gone.
    static func pruneOrphans(_ db: Database) throws {
        guard try db.tableExists(RowEvent.databaseTableName) else { return }
        try db.execute(sql: "DELETE FROM rowEvent WHERE mergeKey NOT IN (SELECT mergeKey FROM item)")
    }
}

extension InfluxStore {
    /// Why the row `mergeKey` sits where it does: its copies, its position
    /// and what happened to it on this device. `shownItemID` is the item
    /// the timeline shows the row from (`TimelineRow.id`), which can be a
    /// preferred copy rather than the one that made the row; without it,
    /// the copy that made the row is marked.
    public func rowHistory(mergeKey: String, shownItemID: Int64? = nil) async throws -> RowHistory {
        try await writer.read { db in
            let sortDate = try Date.fetchOne(db, sql: "SELECT sortDate FROM timelinePosition WHERE mergeKey = ?", arguments: [mergeKey])
            let shownID = try shownItemID
                ?? Int64.fetchOne(db, sql: "SELECT itemID FROM timelinePosition WHERE mergeKey = ?", arguments: [mergeKey])
            let items = try Item.filter(Column("mergeKey") == mergeKey).order(Column("fetchedAt"), Column("id")).fetchAll(db)
            let sources = try Dictionary(Source.fetchAll(db, keys: Array(Set(items.map(\.sourceID)))).map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first })
            let copies = items.map { item in
                RowHistory.Copy(sourceID: item.sourceID, sourceTitle: sources[item.sourceID]?.title,
                                sourceKind: sources[item.sourceID]?.kind.rawValue, remoteID: item.remoteID,
                                url: item.url, publishedAt: item.publishedAt, fetchedAt: item.fetchedAt,
                                isShown: item.id != nil && item.id == shownID)
            }
            let events = try RowEvent.filter(Column("mergeKey") == mergeKey).order(Column("id")).fetchAll(db)
            let state = try SyncRecordState.fetchOne(db, key: SyncRecord.name(type: .timelinePosition, key: mergeKey))
            return RowHistory(mergeKey: mergeKey, sortDate: sortDate, copies: copies, events: events,
                              positionWaitingToSend: state?.pending != nil, positionInICloud: state?.systemFields != nil)
        }
    }

    /// The row events since `start`, oldest first.
    public func rowEvents(since start: Date) async throws -> [RowEvent] {
        try await writer.read { db in
            try RowEvent.filter(Column("at") >= start).order(Column("id")).fetchAll(db)
        }
    }
}
