import Foundation
import GRDB

// Influx's own bookmark: the one Influx keeps and syncs itself, for the
// items no service keeps one for. An article's (ADR 0018) and a rich
// feed's post's (ADR 0031). It is a record of its own, keyed by the
// item's merge key (`ArticleBookmark`), so it reaches the reader's other
// devices through iCloud and still applies to a copy stored later.

extension Item {
    /// Whether Influx keeps the bookmark of an item of `kind` from a source
    /// of `sourceKind`, rather than the post's service: an article, and a
    /// rich feed's post. Its bookmark is then its only action.
    public static func keepsOwnBookmark(kind: Kind, sourceKind: Source.Kind?) -> Bool {
        kind == .article || (kind == .post && sourceKind == .sammyFeed)
    }
}

extension InfluxStore {
    /// Whether Influx keeps `item`'s bookmark itself, as for a post in a
    /// thread fetched from a rich feed. The item's source decides, so an
    /// item of a source that has gone keeps none.
    public func keepsOwnBookmark(_ item: Item) async throws -> Bool {
        if item.kind == .article { return true }
        return try await writer.read { db in
            Item.keepsOwnBookmark(kind: item.kind, sourceKind: try Source.fetchOne(db, key: item.sourceID)?.kind)
        }
    }

    /// `item`'s own bookmark, as a viewer state that holds only it, when
    /// Influx keeps the item's bookmark and the store holds a copy of it
    /// that keeps one too (an article, or a rich feed's post, with its
    /// merge key); nil otherwise. A post only seen in a thread has none
    /// until it is stored: Bookmarks shows stored items, and the reader's
    /// other devices only get the key, so a bookmark of it would show
    /// nowhere. Nor does one whose only stored copy is a Mastodon or
    /// Bluesky post it joined: Bookmarks would show that copy, with its
    /// service's bookmark, and the own bookmark could not be removed there.
    public func ownBookmark(of item: Item) async throws -> Item.Viewer? {
        try await writer.read { db in
            let sourceKind = try Source.fetchOne(db, key: item.sourceID)?.kind
            guard Item.keepsOwnBookmark(kind: item.kind, sourceKind: sourceKind) else { return nil }
            let stored = try Bool.fetchOne(db, sql: """
                SELECT EXISTS (
                    SELECT 1 FROM item JOIN source ON source.id = item.sourceID
                    WHERE item.mergeKey = ?
                        AND (item.kind = ? OR (item.kind = ? AND source.kind = ?))
                )
                """, arguments: [item.mergeKey, Item.Kind.article.rawValue, Item.Kind.post.rawValue, Source.Kind.sammyFeed.rawValue]) ?? false
            guard stored else { return nil }
            return Item.Viewer(bookmarked: try ArticleBookmark.fetchOne(db, key: item.mergeKey)?.isBookmarked ?? false)
        }
    }
}
