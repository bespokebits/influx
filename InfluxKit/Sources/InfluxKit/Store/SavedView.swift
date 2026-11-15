import Foundation
import GRDB

/// A named timeline over chosen sources. The All view, every source,
/// isn't stored: it is always there and can't be changed, and its ID is
/// `SavedView.allID`. Bookmarks, every bookmarked post, is built in
/// the same way, as `SavedView.bookmarksID`. A Bluesky custom feed is a source like any other, so a
/// view can hold one.
public struct SavedView: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    /// The All view's ID, which its last-read marker is stored under.
    public static let allID = ReadingPosition.allViewID
    /// The Bookmarks view's ID. Saved views' IDs are UUIDs, so it can't
    /// clash with one.
    public static let bookmarksID = "bookmarks"

    /// Whether `id` names a view that is always there and isn't stored.
    public static func isBuiltIn(_ id: String) -> Bool {
        id == allID || id == bookmarksID
    }

    /// Stable across devices, so its marker and filters sync with it.
    public var id: String
    public var name: String
    /// The sources it shows. A source removed later just drops out.
    public var sourceIDs: [String]
    /// Its place in the view list, smallest first.
    public var sortIndex: Int
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, sourceIDs: [String], sortIndex: Int, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.sourceIDs = sourceIDs
        self.sortIndex = sortIndex
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "savedView"
}

/// A keyword or regular expression whose matching rows are hidden, in every
/// view or in one. See `TimelineFilter` for how each matches.
public struct ContentFilter: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Match: String, Codable, Sendable, CaseIterable {
        /// A word or phrase, ignoring case and accents.
        case keyword
        /// A regular expression, ignoring case.
        case regex
    }

    /// Stable across devices, so it syncs.
    public var id: String
    public var pattern: String
    public var match: Match
    /// The one view it applies to (a saved view, or `SavedView.allID` for
    /// the All view alone); nil for every view.
    public var viewID: String?
    /// Switched off, it hides nothing but is kept.
    public var isEnabled: Bool
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, pattern: String, match: Match, viewID: String? = nil,
                isEnabled: Bool = true, updatedAt: Date = Date()) {
        self.id = id
        self.pattern = pattern
        self.match = match
        self.viewID = viewID
        self.isEnabled = isEnabled
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "contentFilter"

    /// Whether it applies in the view `viewID`.
    public func applies(in viewID: String) -> Bool {
        self.viewID == nil || self.viewID == viewID
    }

    /// Whether the pattern can be saved: not blank, and for a regular
    /// expression, one that compiles.
    public var isValid: Bool {
        switch match {
        case .keyword: !pattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .regex: TimelineFilter.expression(pattern) != nil
        }
    }
}
