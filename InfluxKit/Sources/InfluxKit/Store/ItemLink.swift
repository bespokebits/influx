import Foundation
import GRDB

/// The link back to one item, which another app opens (Sammy's "Open in
/// Influx" on a task made from a bookmark): `<scheme>://item?ref=<ref>`.
/// `ref` is the unpadded base64url SHA-256 of the item's merge key, the
/// one id that is the same on every device. A custom scheme isn't
/// reserved, so another app could claim it too: the link carries nothing
/// readable, and Influx finds the item by hashing the keys it holds.
public struct ItemLink: Sendable, Hashable {
    /// The scheme the App Store build registers. Other builds register
    /// their own bundle ID, so they never take its links.
    public static let scheme = "dev.bespokebits.influx"
    /// A SHA-256 digest in unpadded base64url.
    public static let refLength = 43

    public let ref: String

    /// The link to the item whose merge key is `key`.
    public init(key: String) {
        ref = Self.ref(forKey: key)
    }

    /// The link `url` names, or nil for anything but exactly
    /// `<scheme>://item?ref=<43 base64url characters>`: no path, port,
    /// user, fragment or other query item, and no percent-encoding. The
    /// sign-in callbacks that come back on the same scheme
    /// (`…:/oauth/sammy`, `…://oauth/mastodon`) are not links.
    public init?(_ url: URL, scheme: String = ItemLink.scheme) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == scheme.lowercased(),
              parts.percentEncodedHost == "item",
              parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil, parts.port == nil,
              parts.percentEncodedPath.isEmpty, parts.percentEncodedFragment == nil,
              let query = parts.percentEncodedQuery, query.hasPrefix("ref=") else { return nil }
        let ref = query.dropFirst("ref=".count)
        guard ref.utf8.count == Self.refLength, ref.utf8.allSatisfy(Self.isBase64URL) else { return nil }
        self.ref = String(ref)
    }

    /// `key`'s ref, byte for byte what Sammy makes of the key it was sent:
    /// Node's `createHash("sha256").update(key).digest("base64url")`, which
    /// hashes the key's UTF-8.
    public static func ref(forKey key: String) -> String {
        RecordNameHash.digest(key.utf8).base64URLEncoded
    }

    public func url(scheme: String = ItemLink.scheme) -> URL {
        URL(string: "\(scheme)://item?ref=\(ref)")!
    }

    private static func isBase64URL(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"): true
        default: false
        }
    }
}

/// Where an `ItemLink` leads on this device.
public enum ItemLinkTarget: Sendable, Hashable {
    /// Bookmarked and stored here: Bookmarks shows this row.
    case bookmark(TimelineRow)
    /// The item is stored here but no longer bookmarked: open it as a tap
    /// on this row would, while the item lasts.
    case row(TimelineRow)
    /// Bookmarked, but the item isn't stored here: pruned, or this device
    /// hasn't fetched it yet.
    case bookmarked
    /// Neither the item nor its bookmark is here. A post bookmarked on
    /// another device that this one hasn't fetched yet looks the same:
    /// a Mastodon or Bluesky post's bookmark comes from the service, not
    /// from sync.
    case gone
}

extension InfluxStore {
    /// Where `link` leads: the stored item whose merge key hashes to its
    /// ref, looked for among the bookmarks first, then among every item.
    public func target(of link: ItemLink) async throws -> ItemLinkTarget {
        try await writer.read { db in
            let bookmarked = try SQLRequest<String>(literal: "SELECT mergeKey FROM item WHERE \(Self.inBookmarks)").fetchSet(db)
                .union(String.fetchAll(db, sql: "SELECT mergeKey FROM articleBookmark WHERE isBookmarked = 1"))
            let matches = { (key: String?) in key.map { ItemLink.ref(forKey: $0) == link.ref } ?? false }
            // A copy that joined a row stored first under another copy's key
            // keeps its own key in `postKey` (rich/native and Bridgy copies),
            // and the bookmark may have been sent from a device that stored
            // that copy first: match either key, then use the row's.
            let stored = try Row.fetchAll(db, sql: "SELECT DISTINCT mergeKey, postKey FROM item")
            if let match = stored.first(where: { matches($0["mergeKey"]) || matches($0["postKey"]) }) {
                let key: String = match["mergeKey"]
                if bookmarked.contains(key), let row = try Self.rowsRequest(.bookmarked, mergeKey: key).fetchOne(db) {
                    return .bookmark(row)
                }
                // Bookmark-only copies too: a post first stored from the
                // bookmark list stays stored after its bookmark is removed.
                if let row = try Self.rowsRequest(.all, mergeKey: key, bookmarkOnlyCopies: true).fetchOne(db) {
                    return .row(row)
                }
            }
            if bookmarked.contains(where: matches) { return .bookmarked }
            return .gone
        }
    }
}
