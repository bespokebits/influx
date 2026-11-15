import Foundation

/// What a sync record carries. The raw value is the CloudKit record type.
public enum SyncRecordType: String, Codable, Sendable, CaseIterable {
    /// A source: an RSS subscription, or an account's feed or list. Synced
    /// sources are what make an account show up on another device; its
    /// credentials never travel. Last writer wins.
    case source = "Source"
    /// A saved view's last-read marker. The furthest one wins.
    case lastReadMarker = "LastReadMarker"
    /// An article's read or unread state. Last writer wins, a tie goes to read.
    case articleReadState = "ArticleReadState"
    /// Where a merge group sits in the timeline. The first one stored in
    /// iCloud wins, so every device places the row, and compares markers,
    /// the same way.
    case timelinePosition = "TimelinePosition"
    /// One app setting. Last writer wins.
    case setting = "Setting"
    /// A saved view: its name, sources and place in the list. Last writer
    /// wins; deleting it deletes its filters and marker everywhere.
    case savedView = "SavedView"
    /// A keyword or regex filter. Last writer wins.
    case contentFilter = "ContentFilter"
    /// Where the reader is in a saved view: the row at the top of the
    /// screen. Moves both ways, and the last device moved wins.
    case readingPlace = "ReadingPlace"
    /// Whether an article is bookmarked. Last writer wins,
    /// a tie goes to bookmarked.
    case articleBookmark = "ArticleBookmark"

    /// Whether a deletion goes up as a tombstone, a record that says when
    /// it was deleted, rather than as a CloudKit deletion, which carries no
    /// time. For the last-writer-wins types, so a deletion and a change
    /// made on two devices settle by which came later, whichever reaches
    /// iCloud first.
    var deletesByTombstone: Bool {
        switch self {
        case .source, .setting, .savedView, .contentFilter: true
        case .lastReadMarker, .articleReadState, .articleBookmark, .timelinePosition, .readingPlace: false
        }
    }

    /// The version of this type's payload that this build writes, sent
    /// with every record as `v`. A record without one is version 1.
    ///
    /// A new optional field needs no new version: a build from before
    /// ignores it. Raise the version when a build from before would get a
    /// record wrong by reading it, or spoil it by saving over it. Such a
    /// build keeps a record with a higher version as it arrived, sends
    /// nothing over it, and reads it once it has updated (ADR 0029).
    ///
    /// `.source` is still 1 with `Source.itemKind` in it: a build from
    /// before reads the source as it did, and one that saves over it drops
    /// the field, which is nil, "unknown", and reads the feed safely
    /// (ADR 0031).
    var payloadVersion: Int {
        switch self {
        case .source, .lastReadMarker, .articleReadState, .timelinePosition, .setting,
             .savedView, .contentFilter, .readingPlace, .articleBookmark: 1
        }
    }
}

/// One record as it travels to and from iCloud: a type, the key it is
/// stored under on every device, and its fields as JSON. The CloudKit
/// adapter keeps the payload opaque; only the store reads it.
public struct SyncRecord: Sendable, Hashable {
    /// The CloudKit record name: the type and a hash of the key, so it is
    /// the same on every device, fits CloudKit's 255-character limit and
    /// uses only characters CloudKit allows, whatever the key is (feed URLs
    /// and merge keys can be long, and can hold anything).
    public var name: String
    public var type: SyncRecordType
    public var key: String
    public var payload: Data

    public init(type: SyncRecordType, key: String, payload: Data) {
        self.name = Self.name(type: type, key: key)
        self.type = type
        self.key = key
        self.payload = payload
    }

    public static func name(type: SyncRecordType, key: String) -> String {
        "\(type.rawValue).\(RecordNameHash.hex(key.utf8))"
    }
}

/// A local change waiting to go to iCloud.
public struct PendingSyncChange: Sendable, Hashable {
    public var name: String
    public var type: SyncRecordType
    public var isDeletion: Bool
}

/// A record to save to iCloud, built from the store as it is now.
public struct OutgoingSyncRecord: Sendable, Hashable {
    public var record: SyncRecord
    /// The server's fields from the last time this record was saved or
    /// fetched (for CloudKit, the archived system fields with the change
    /// tag), or nil for a record the server has never confirmed.
    public var systemFields: Data?
    /// Which local change this is. Passed back to `didSaveSyncRecords`, so
    /// a change made while this one was in flight stays pending.
    public var version: Int64
}

/// A record the server confirmed saving.
public struct SavedSyncRecord: Sendable, Hashable {
    public var name: String
    public var version: Int64
    public var systemFields: Data

    public init(name: String, version: Int64, systemFields: Data) {
        self.name = name
        self.version = version
        self.systemFields = systemFields
    }
}

/// A record from the server: a fetched change, or the server's copy when a
/// save conflicted.
public struct FetchedSyncRecord: Sendable, Hashable {
    public var record: SyncRecord
    public var systemFields: Data

    public init(record: SyncRecord, systemFields: Data) {
        self.record = record
        self.systemFields = systemFields
    }
}

/// A record from the server of a type this build has no name for, as a
/// newer Influx on another device can save. It is kept as it arrived
/// (`UnreadSyncRecord`).
public struct UnknownSyncRecord: Sendable, Hashable {
    public var name: String
    public var type: String
    public var key: String
    public var payload: Data
    public var systemFields: Data

    public init(name: String, type: String, key: String, payload: Data, systemFields: Data) {
        self.name = name
        self.type = type
        self.key = key
        self.payload = payload
        self.systemFields = systemFields
    }
}

// MARK: Payloads

/// The JSON each record type carries. Dates use Foundation's default
/// encoding, which round-trips exactly.
struct SourcePayload: Codable, Hashable {
    var source: Source
    var modifiedAt: Date
}

struct LastReadMarkerPayload: Codable, Hashable {
    var viewID: String
    var mergeKey: String
    /// The sending device's date for the row, used only to stop two devices
    /// that order rows differently from resending to each other forever.
    var sortDate: Date
    var updatedAt: Date
}

struct ReadingPlacePayload: Codable, Hashable {
    var viewID: String
    var mergeKey: String
    /// The sending device's date for the row.
    var sortDate: Date
    var updatedAt: Date
    /// Which move of the shared place this is. Missing from records made
    /// before moves were counted, which count as move 0.
    var move: Int?
    /// The install the reader was on (`ReadingPlace.device`).
    var device: String?
}

struct ArticleReadStatePayload: Codable, Hashable {
    var mergeKey: String
    var isRead: Bool
    var updatedAt: Date
}

struct ArticleBookmarkPayload: Codable, Hashable {
    var mergeKey: String
    var isBookmarked: Bool
    var updatedAt: Date
}

struct TimelinePositionPayload: Codable, Hashable {
    var mergeKey: String
    var sortDate: Date
    /// When the device whose position this is first stored the row: the
    /// earliest store wins. Missing from records made before
    /// it was added, which lose to any device's own.
    var placedAt: Date?
}

struct SavedViewPayload: Codable, Hashable {
    var view: SavedView
    var modifiedAt: Date
}

struct ContentFilterPayload: Codable, Hashable {
    var filter: ContentFilter
    var modifiedAt: Date
}

struct SettingPayload: Codable, Hashable {
    var key: String
    /// Nil once the setting is cleared.
    var value: Data?
    var modifiedAt: Date
}

/// What a deleted record of a last-writer-wins type carries instead of its
/// fields. It stays in iCloud, so a device that comes back with an older
/// change takes the deletion, and one with a newer change replaces it.
struct SyncTombstone: Codable, Hashable {
    var deletedAt: Date
}

enum SyncCoding {
    /// A payload as it travels: its fields, and `v`, the version of the
    /// record type's payload (`SyncRecordType.payloadVersion`).
    static func encode<Payload: Encodable>(_ payload: Payload, for type: SyncRecordType) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(Versioned(payload: payload, version: type.payloadVersion))
    }

    static func decode<Payload: Decodable>(_ type: Payload.Type, from data: Data) -> Payload? {
        try? JSONDecoder().decode(type, from: data)
    }

    /// The version a payload says it is: 1 when it doesn't say, as records
    /// from before versions were sent don't, or when it isn't JSON at all.
    static func version(of data: Data) -> Int {
        (try? JSONDecoder().decode(Version.self, from: data))?.v ?? 1
    }

    private struct Version: Decodable {
        var v: Int?
    }

    private enum VersionKey: String, CodingKey {
        case v
    }

    /// Writes the payload's own fields and `v` into one JSON object.
    private struct Versioned<Payload: Encodable>: Encodable {
        var payload: Payload
        var version: Int

        func encode(to encoder: any Encoder) throws {
            try payload.encode(to: encoder)
            var container = encoder.container(keyedBy: VersionKey.self)
            try container.encode(version, forKey: .v)
        }
    }
}
