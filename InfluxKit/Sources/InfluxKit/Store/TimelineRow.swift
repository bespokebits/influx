import Foundation
import GRDB

/// One row of the timeline: everything row layout needs, and nothing else.
/// A merged post is one row, whichever source saw it first.
public struct TimelineRow: Sendable, Hashable, Identifiable {
    /// The local ID of the item the row is shown from.
    public let id: Int64
    public let kind: Item.Kind
    /// What the row stands for on every device; last-read markers and read
    /// state refer to it.
    public let mergeKey: String
    public let sourceID: String
    public let sourceTitle: String
    public let colorIndex: Int
    public let authorName: String
    public let authorHandle: String
    public let title: String?
    public let body: String
    public let url: String?
    public let publishedAt: Date
    /// Where the row sits: fixed when its merge group was first stored, and
    /// never moved after.
    public let sortDate: Date
    /// Everyone who boosted it, earliest boost first.
    public let boostedBy: [String]
    public let replyToHandle: String?
    public let linkCard: Item.LinkCard?
    /// The post's images and videos, each with its pixel size.
    public let media: [Item.Media]
    public let quote: Item.Quote?
    /// Articles only: whether the reader has read it.
    public let isRead: Bool
    /// What the reader has done to the post, from the item the row is
    /// shown from; nil when no action applies. A row that keeps its own
    /// bookmark (`keepsOwnBookmark`) has only that bookmark, which Influx
    /// keeps itself.
    public let viewer: Item.Viewer?
    /// Where the links in `body` sit and go.
    public let links: [Item.Link]
    /// The author's profile picture, or an article's feed icon.
    public var authorAvatar: String? = nil
    /// The first booster's profile picture.
    public var boosterAvatar: String? = nil
    /// When the row's own item says it happened: when it was posted, or
    /// boosted, but never after it was fetched. The row shows this time;
    /// it differs from `sortDate` when the row arrived late and was placed
    /// below the reader's line instead (ADR 0041).
    public var postedAt: Date? = nil
    /// The score shown beside the title, for a feed that sends one.
    public var badge: Item.Badge? = nil
    /// Whether the post's thread can be opened, which its service decides
    /// (`Source.Kind.hasThreads`), and on a rich feed the post itself, by
    /// naming one in any of its copies (ADR 0031). Never for an article.
    public var hasThread: Bool = true
    /// For a rich post, the stored copy whose thread opens: the row's own
    /// item when it names one, else another rich copy of the post that
    /// does. Nil for every other row, whose thread opens from `id`.
    public var threadItemID: Int64? = nil
    /// A rich feed's post (ADR 0031): its only action is Influx's own
    /// bookmark, and a tap on it opens its original page, even where it
    /// has a thread.
    public var isRich: Bool = false
}

extension TimelineRow {
    /// Whether Influx keeps the row's bookmark itself, keyed by its merge
    /// key and synced through iCloud, rather than the post's service:
    /// an article's, since an RSS feed has no service (ADR 0018), and a
    /// rich feed's post's, since the reader wants it kept here (ADR 0031).
    /// The bookmark is then the row's one action. A row joined from
    /// several copies is shown from its rich copy when it has one, so that
    /// copy's rule holds for it.
    public var keepsOwnBookmark: Bool { Item.keepsOwnBookmark(kind: kind, sourceKind: isRich ? .sammyFeed : nil) }
}

extension TimelineRow {
    /// The most of a body a row shows, in UTF-16 code units. A row is drawn
    /// into one bitmap (ADR 0008), so its height must stay bounded: a
    /// Mastodon instance can allow posts of 100,000 characters, and so can
    /// a rich feed (ADR 0031). The item keeps the whole text; the row shows
    /// the start and an ellipsis, and the post's own page has the rest.
    public static let bodyLimit = 2_000

    /// `body` cut to `bodyLimit` at the last space or line break in its
    /// final tenth (else at the limit, never inside a character), with an
    /// ellipsis, and the links that still fit whole.
    static func bounded(_ body: String, _ links: [Item.Link]) -> (String, [Item.Link]) {
        guard body.utf16.count > bodyLimit else { return (body, links) }
        // The last whole character that fits.
        var end = body.startIndex
        var units = 0
        while end < body.endIndex, units + body[end].utf16.count <= bodyLimit {
            units += body[end].utf16.count
            end = body.index(after: end)
        }
        if let space = body[..<end].lastIndex(where: \.isWhitespace),
           body.utf16.distance(from: body.startIndex, to: space) >= bodyLimit * 9 / 10 {
            end = space
        }
        // Trailing space only: the start stays put, so link offsets do.
        var kept = body[..<end]
        while let last = kept.last, last.isWhitespace { kept = kept.dropLast() }
        let length = kept.utf16.count
        return (kept + "…", links.filter { $0.start + $0.length <= length })
    }
}

extension TimelineRow: FetchableRecord {
    /// Boost names are joined with the unit separator, which no display
    /// name contains.
    static let boosterSeparator = "\u{1F}"

    public init(row: Row) throws {
        id = row["id"]
        kind = row["kind"]
        mergeKey = row["mergeKey"]
        sourceID = row["sourceID"]
        sourceTitle = row["sourceTitle"]
        colorIndex = row["colorIndex"]
        authorName = row["authorName"]
        authorHandle = row["authorHandle"]
        title = row["title"]
        let fullBody: String = row["body"]
        url = row["url"]
        publishedAt = row["publishedAt"]
        sortDate = row["sortDate"]
        postedAt = row["postedAt"]
        let boosters: String? = row["boosters"]
        boostedBy = boosters.map { $0.components(separatedBy: Self.boosterSeparator) } ?? []
        replyToHandle = row["replyToHandle"]
        let card: String? = row["linkCard"]
        linkCard = try card.map { try JSONDecoder().decode(Item.LinkCard.self, from: Data($0.utf8)) }
        let media: String? = row["media"]
        self.media = try media.map { try JSONDecoder().decode([Item.Media].self, from: Data($0.utf8)) } ?? []
        let quoted: String? = row["quote"]
        quote = try quoted.map { try JSONDecoder().decode(Item.Quote.self, from: Data($0.utf8)) }
        isRead = row["isRead"]
        let viewer: String? = row["viewer"]
        let sourceKind = Source.Kind(rawValue: row["sourceKind"] as String)
        if Item.keepsOwnBookmark(kind: kind, sourceKind: sourceKind) {
            self.viewer = Item.Viewer(bookmarked: row["articleBookmarked"])
        } else {
            self.viewer = try viewer.map { try JSONDecoder().decode(Item.Viewer.self, from: Data($0.utf8)) }
        }
        let links: String? = row["links"]
        // Most posts have no links; skip the decoder for them.
        authorAvatar = row["authorAvatar"]
        boosterAvatar = row["boosterAvatar"]
        let allLinks = try links.flatMap { $0 == "[]" ? nil : try JSONDecoder().decode([Item.Link].self, from: Data($0.utf8)) } ?? []
        (body, self.links) = Self.bounded(fullBody, allLinks)
        // Read leniently: a badge this build can't read is no badge, never
        // a row that fails.
        let badge: String? = row["badge"]
        self.badge = badge.flatMap { try? JSONDecoder().decode(Item.Badge.self, from: Data($0.utf8)) }
        isRich = kind == .post && sourceKind == .sammyFeed
        threadItemID = isRich ? row["threadItemID"] : nil
        hasThread = kind == .post && (sourceKind?.hasThreads == true || threadItemID != nil)
    }
}

extension Item.Kind: DatabaseValueConvertible {}
