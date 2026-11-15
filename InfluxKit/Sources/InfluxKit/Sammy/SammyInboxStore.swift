import Foundation
import GRDB

/// One bookmark for one Sammy account in the outbox (Bookmarks to Sammy
/// Inbox). Local only, never synced: the device that made the bookmark is
/// the only one that sends it.
public struct SammyOutboxEntry: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public enum Status: String, Codable, Sendable, Hashable {
        /// Still to send.
        case waiting
        /// Sammy has it.
        case sent
        /// Given up on, for `dropReason`.
        case dropped
    }

    /// Why a bookmark was given up on, for the account screen to say.
    public enum DropReason: String, Codable, Sendable, Hashable {
        /// It didn't reach Sammy within `SammyInboxOutbox.expiry`.
        case expired
        /// Sammy refused it (a 4xx it will never accept).
        case refused
    }

    public var key: String
    public var accountID: String
    public var kind: SammyCapture.Kind
    public var title: String
    public var from: String
    public var url: String
    public var bookmarkedAt: Date
    public var queuedAt: Date
    /// Sends that failed and are retried, for the backoff.
    public var attempts: Int
    /// Not sent before this; nil means at the next chance.
    public var nextAttemptAt: Date?
    public var status: Status
    public var dropReason: DropReason?
    /// When it was sent or dropped.
    public var settledAt: Date?

    public static let databaseTableName = "sammyOutbox"

    enum CodingKeys: String, CodingKey {
        case key, accountID, kind, title, from = "fromLabel", url, bookmarkedAt, queuedAt, attempts, nextAttemptAt, status, dropReason, settledAt
    }

    init(_ capture: SammyCapture, accountID: String, at now: Date) {
        key = capture.key
        self.accountID = accountID
        kind = capture.kind
        title = capture.title
        from = capture.from
        url = capture.url
        bookmarkedAt = capture.bookmarkedAt
        queuedAt = now
        attempts = 0
        nextAttemptAt = nil
        status = .waiting
    }

    public var capture: SammyCapture {
        SammyCapture(key: key, kind: kind, title: title, from: from, url: url, bookmarkedAt: bookmarkedAt)
    }
}

/// A Sammy account whose token was refused (401) while a bookmark was
/// being sent. The token itself is never stored here, only its SHA-256,
/// which is only compared with the token stored for the account now.
struct SammyRefusal: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var accountID: String
    var tokenHash: String
    var refusedAt: Date

    static let databaseTableName = "sammyRefusal"

    static func hash(_ token: String) -> String { RecordNameHash.hex(Array(token.utf8)) }
}

extension SammyCapture.Kind: DatabaseValueConvertible {}
extension SammyOutboxEntry.Status: DatabaseValueConvertible {}
extension SammyOutboxEntry.DropReason: DatabaseValueConvertible {}

/// What the account screen shows under Bookmarks to Sammy Inbox.
public struct SammyInboxSummary: Sendable, Hashable {
    /// The switch, as synced.
    public var isOn = false
    /// Bookmarks still to send from this device.
    public var waiting = 0
    /// Sent since the date the summary was asked from.
    public var sent = 0
    /// Given up on lately (kept for `SammyInboxOutbox.expiry`), by reason.
    public var expired = 0
    public var refused = 0

    public init(isOn: Bool = false, waiting: Int = 0, sent: Int = 0, expired: Int = 0, refused: Int = 0) {
        self.isOn = isOn
        self.waiting = waiting
        self.sent = sent
        self.expired = expired
        self.refused = refused
    }
}

extension InfluxStore {
    // MARK: The switch

    /// The synced setting that holds an account's Bookmarks to Sammy Inbox
    /// switch: set ("on") when it is on, unset when off, the default.
    public static func sammyInboxSettingKey(_ accountID: String) -> String {
        "sammyInbox:" + accountID
    }

    static let sammyInboxOn = Data("on".utf8)

    /// Whether Bookmarks to Sammy Inbox is on for `accountID`.
    public func isSammyInboxOn(_ accountID: String) async throws -> Bool {
        try await setting(Self.sammyInboxSettingKey(accountID)) == Self.sammyInboxOn
    }

    /// The Sammy accounts with Bookmarks to Sammy Inbox on.
    public func sammyInboxAccounts() async throws -> [String] {
        try await writer.read { db in try Self.sammyInboxAccounts(db) }
    }

    static func sammyInboxAccounts(_ db: Database) throws -> [String] {
        let prefix = sammyInboxSettingKey("")
        return try SyncedSetting
            .filter(Column("key").like(prefix + "%"))
            .fetchAll(db)
            .filter { $0.value == sammyInboxOn }
            .map { String($0.key.dropFirst(prefix.count)) }
            .sorted()
    }

    /// Switches Bookmarks to Sammy Inbox on or off for `accountID`, a
    /// synced setting, so the same on every device. Switching it off drops
    /// the bookmarks still waiting to go to that account, in the same
    /// write.
    public func setSammyInbox(_ accountID: String, on: Bool, at now: Date = Date()) async throws {
        let key = Self.sammyInboxSettingKey(accountID)
        let value: Data? = on ? Self.sammyInboxOn : nil
        try await writer.write { db in
            if !on {
                try SammyOutboxEntry
                    .filter(Column("accountID") == accountID && Column("status") == SammyOutboxEntry.Status.waiting)
                    .deleteAll(db)
            }
            guard try SyncedSetting.fetchOne(db, key: key)?.value != value else { return }
            try SyncedSetting(key: key, value: value).upsert(db)
            try SyncLog.recordChange(db, .setting, key: key, at: now)
        }
    }

    // MARK: The outbox

    /// Queues `capture` for each of `accountIDs`. A bookmark already
    /// waiting or sent for an account is left as it is; one dropped before
    /// is queued afresh.
    @discardableResult
    public func queueCapture(_ capture: SammyCapture, for accountIDs: [String], at now: Date = Date()) async throws -> [SammyOutboxEntry] {
        try await writer.write { db in
            var queued: [SammyOutboxEntry] = []
            for accountID in accountIDs {
                if let existing = try SammyOutboxEntry.fetchOne(db, key: ["key": capture.key, "accountID": accountID]),
                   existing.status != .dropped {
                    if existing.status == .waiting { queued.append(existing) }
                    continue
                }
                let entry = SammyOutboxEntry(capture, accountID: accountID, at: now)
                try entry.upsert(db)
                queued.append(entry)
            }
            return queued
        }
    }

    /// Removes the bookmark `key` from the outbox wherever it is still
    /// waiting: its bookmark was removed before it was sent. One already
    /// sent stays sent; its task stays in Sammy.
    public func cancelCaptures(key: String) async throws {
        try await writer.write { db in
            _ = try SammyOutboxEntry
                .filter(Column("key") == key && Column("status") == SammyOutboxEntry.Status.waiting)
                .deleteAll(db)
        }
    }

    /// Every bookmark still waiting, oldest first.
    public func waitingCaptures() async throws -> [SammyOutboxEntry] {
        try await writer.read { db in
            try SammyOutboxEntry
                .filter(Column("status") == SammyOutboxEntry.Status.waiting)
                .order(Column("queuedAt"), Column("key"))
                .fetchAll(db)
        }
    }

    /// The waiting entry for `key` and `accountID`, if any.
    public func waitingCapture(key: String, accountID: String) async throws -> SammyOutboxEntry? {
        try await writer.read { db in
            try SammyOutboxEntry.fetchOne(db, key: ["key": key, "accountID": accountID]).flatMap { $0.status == .waiting ? $0 : nil }
        }
    }

    /// Changes a waiting entry, if it is still waiting: a switch-off or an
    /// unbookmark may have removed it while it was being sent.
    func updateWaitingCapture(key: String, accountID: String, _ change: @escaping @Sendable (inout SammyOutboxEntry) -> Void) async throws {
        try await writer.write { db in
            guard var entry = try SammyOutboxEntry.fetchOne(db, key: ["key": key, "accountID": accountID]), entry.status == .waiting else { return }
            change(&entry)
            try entry.update(db)
        }
    }

    /// Deletes a waiting entry.
    func deleteWaitingCapture(key: String, accountID: String) async throws {
        try await writer.write { db in
            _ = try SammyOutboxEntry
                .filter(Column("key") == key && Column("accountID") == accountID && Column("status") == SammyOutboxEntry.Status.waiting)
                .deleteAll(db)
        }
    }

    /// Clears the backoff of `accountID`'s waiting bookmarks, so the next
    /// pass sends them: a new session has arrived.
    public func wakeCaptures(accountID: String) async throws {
        try await writer.write { db in
            try db.execute(literal: """
                UPDATE \(sql: SammyOutboxEntry.databaseTableName) SET nextAttemptAt = NULL
                WHERE accountID = \(accountID) AND status = \(SammyOutboxEntry.Status.waiting.rawValue)
                """)
        }
    }

    /// Drops every bookmark waiting since before `cutoff`, as expired, and
    /// forgets sent and dropped ones settled before it. Returns how many
    /// expired.
    @discardableResult
    func expireCaptures(queuedBefore cutoff: Date, at now: Date) async throws -> Int {
        try await writer.write { db in
            try SammyOutboxEntry
                .filter(Column("status") != SammyOutboxEntry.Status.waiting && Column("settledAt") < cutoff)
                .deleteAll(db)
            try db.execute(literal: """
                UPDATE \(sql: SammyOutboxEntry.databaseTableName)
                SET status = \(SammyOutboxEntry.Status.dropped.rawValue), dropReason = \(SammyOutboxEntry.DropReason.expired.rawValue),
                    settledAt = \(now), nextAttemptAt = NULL
                WHERE status = \(SammyOutboxEntry.Status.waiting.rawValue) AND queuedAt < \(cutoff)
                """)
            return db.changesCount
        }
    }

    /// What the account screen shows for `accountID`: the switch, what is
    /// waiting, what was sent since `since`, and what was given up on.
    public func sammyInboxSummary(_ accountID: String, since: Date) async throws -> SammyInboxSummary {
        try await writer.read { db in try Self.sammyInboxSummary(accountID, since: since, db) }
    }

    /// The same, delivered again after each change.
    public func observeSammyInboxSummary(_ accountID: String, since: Date) -> AsyncValueObservation<SammyInboxSummary> {
        ValueObservation
            .tracking { db in try Self.sammyInboxSummary(accountID, since: since, db) }
            .removeDuplicates()
            .values(in: writer)
    }

    static func sammyInboxSummary(_ accountID: String, since: Date, _ db: Database) throws -> SammyInboxSummary {
        var summary = SammyInboxSummary()
        summary.isOn = try SyncedSetting.fetchOne(db, key: sammyInboxSettingKey(accountID))?.value == sammyInboxOn
        let rows = try Row.fetchAll(db, sql: """
            SELECT status, dropReason, COUNT(*) AS n FROM \(SammyOutboxEntry.databaseTableName)
            WHERE accountID = ? AND (status != 'sent' OR settledAt >= ?)
            GROUP BY status, dropReason
            """, arguments: [accountID, since])
        for row in rows {
            let count: Int = row["n"]
            switch (SammyOutboxEntry.Status(rawValue: row["status"]), SammyOutboxEntry.DropReason(rawValue: row["dropReason"] ?? "")) {
            case (.waiting, _): summary.waiting += count
            case (.sent, _): summary.sent += count
            case (.dropped, .expired): summary.expired += count
            case (.dropped, _): summary.refused += count
            case (nil, _): break
            }
        }
        return summary
    }

    // MARK: Refused tokens

    /// Records that Sammy refused `token`, the one stored for `accountID`,
    /// so the account asks to be signed in again, across relaunches, until
    /// a different token is stored for it.
    public func recordSammyRefusal(accountID: String, token: String, at now: Date = Date()) async throws {
        try await writer.write { db in
            try SammyRefusal(accountID: accountID, tokenHash: SammyRefusal.hash(token), refusedAt: now).upsert(db)
        }
    }

    /// The accounts with a refusal recorded, whose stored token is wanted
    /// to tell whether it still stands.
    public func sammyRefusalAccounts() async throws -> [String] {
        try await writer.read { db in try String.fetchAll(db, sql: "SELECT accountID FROM \(SammyRefusal.databaseTableName) ORDER BY accountID") }
    }

    /// The accounts whose refused token is still the one stored for them,
    /// given each account's stored token (nil when it has none). A refusal
    /// whose account now holds another token, or none, is forgotten.
    public func stillRefusedSammyAccounts(storedTokens: [String: String?]) async throws -> Set<String> {
        try await writer.write { db in
            var still: Set<String> = []
            for refusal in try SammyRefusal.fetchAll(db) {
                if let token = storedTokens[refusal.accountID] ?? nil, SammyRefusal.hash(token) == refusal.tokenHash {
                    still.insert(refusal.accountID)
                } else if storedTokens.keys.contains(refusal.accountID) {
                    try refusal.delete(db)
                }
            }
            return still
        }
    }

    /// Forgets the refusal of `accountID`: signed out, or signed in again.
    public func clearSammyRefusal(accountID: String) async throws {
        try await writer.write { db in _ = try SammyRefusal.deleteOne(db, key: accountID) }
    }

    /// Whether the item `mergeKey` is bookmarked here, as far as this
    /// device knows: an article's bookmark; for a post, Influx's own
    /// bookmark (a rich feed's post's) or any stored copy's viewer state,
    /// since a post joined from several copies is in Bookmarks while any
    /// of them is bookmarked. Nil when the store holds none of these, as
    /// for a post only seen in a thread.
    public func isBookmarked(mergeKey: String, kind: SammyCapture.Kind) async throws -> Bool? {
        try await writer.read { db in
            let own = try ArticleBookmark.fetchOne(db, key: mergeKey)?.isBookmarked
            switch kind {
            case .article:
                return own
            case .post:
                let viewers = try String.fetchAll(db, sql: "SELECT viewer FROM item WHERE mergeKey = ? AND viewer IS NOT NULL", arguments: [mergeKey])
                let states = viewers.compactMap { try? JSONDecoder().decode(Item.Viewer.self, from: Data($0.utf8)) }
                if own == true || states.contains(where: \.bookmarked) { return true }
                return own == nil && states.isEmpty ? nil : false
            }
        }
    }
}
