import Foundation
import GRDB

/// One thing Influx reads from: an account's home feed, a Mastodon list, a
/// Bluesky custom feed, or an RSS feed.
public struct Source: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rss
        case mastodonHome
        case mastodonList
        case blueskyFollowing
        case blueskyFeed
        /// One feed of a Sammy account, read with the account's token as
        /// JSON Feed articles or as rich posts (`SammyFeedConnector`).
        case sammyFeed

        /// Whether the service can show every post's thread: what it
        /// answers and its replies. A Sammy feed has a thread only for a
        /// rich post that names one (`TimelineRow.hasThread`, ADR 0031).
        public var hasThreads: Bool {
            switch self {
            case .mastodonHome, .mastodonList, .blueskyFollowing, .blueskyFeed: true
            case .rss, .sammyFeed: false
            }
        }
    }

    /// Stable across devices, so synced state can refer to it, e.g.
    /// `rss:https://example.com/feed` or `mastodon:@me@example.social:home`.
    public var id: String
    public var kind: Kind
    /// The account the source belongs to; nil for RSS.
    public var accountID: String?
    public var title: String
    /// The feed URL for RSS and Sammy feeds; nil for social sources.
    public var url: String?
    /// Index into the app's source-dot palette.
    public var colorIndex: Int
    /// What the source's items are, as its service listed it: posts or
    /// articles. Nil when unknown, as for every source but a Sammy feed
    /// listed by a server that classifies its feeds (ADR 0031).
    ///
    /// It only chooses what to ask for and how far back to fetch. It never
    /// makes a response readable: what a page is comes from the page. It
    /// syncs as an optional field without a new payload version (ADR 0029):
    /// a build from before ignores it, and one that saves over it leaves
    /// it nil, which reads the feed as safely as before, only asking for
    /// either format.
    public var itemKind: Item.Kind?

    public init(id: String, kind: Kind, accountID: String? = nil, title: String, url: String? = nil, colorIndex: Int, itemKind: Item.Kind? = nil) {
        self.id = id
        self.kind = kind
        self.accountID = accountID
        self.title = title
        self.url = url
        self.colorIndex = colorIndex
        self.itemKind = itemKind
    }

    public static let databaseTableName = "source"

    enum CodingKeys: String, CodingKey {
        case id, kind, accountID, title, url, colorIndex, itemKind
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
        title = try container.decode(String.self, forKey: .title)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
        // A kind a later build adds reads as unknown, not as a source this
        // build can't read.
        itemKind = (try? container.decodeIfPresent(Item.Kind.self, forKey: .itemKind)) ?? nil
    }
}

/// A post or an article as one source produced it. Several items can stand
/// for the same post (a boost, or the same post from two sources); they share
/// a `mergeKey` and show as one merged post.
public struct Item: Codable, Sendable, Hashable, Identifiable, FetchableRecord, MutablePersistableRecord {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case post
        case article
    }

    /// Assigned by the store, in insertion order.
    public var id: Int64?
    public var sourceID: String
    /// The service's own ID for this item within its source.
    public var remoteID: String
    public var kind: Kind
    /// What makes two items the same post: the post's canonical URI (an
    /// `at://` URI or a Mastodon status URL), or an article's GUID or link.
    public var mergeKey: String
    public var authorName: String
    public var authorHandle: String
    /// The author's profile picture; for an article, its feed's icon. Nil
    /// when there is none, and the row draws a monogram.
    public var authorAvatar: String?
    /// Articles have a headline; posts do not.
    public var title: String?
    public var body: String
    public var url: String?
    public var publishedAt: Date
    public var fetchedAt: Date
    /// When the source put the item in its timeline, as the service reports
    /// it: the publish date, or the boost's own date for a boost. It is
    /// stored as the service sent it; where the row sits is decided once,
    /// from `placement`.
    public var sortDate: Date
    /// Who boosted it, when this item is a boost.
    public var boostedBy: String?
    /// Who boosted it, as an ID that means the same account whichever of
    /// the reader's accounts saw the boost (a Bluesky DID, a Mastodon
    /// profile URL), so one person's boost seen twice names them once.
    /// Nil on items stored before it was recorded; their name stands in.
    public var boostedByID: String?
    /// The booster's profile picture, when this item is a boost.
    public var boostedByAvatar: String?
    /// The handle a reply answers, for the "Replying to @x" chip.
    public var replyToHandle: String?
    public var linkCard: LinkCard?
    /// The post's images and videos, in the service's order. Each has its
    /// pixel size, so the row's height is final before it is shown;
    /// media whose size couldn't be learned is left out.
    public var media: [Media]
    /// What the connector needs to act on the post, when that isn't
    /// `remoteID`: a boost's actions target the boosted post, and a Bluesky
    /// like needs its URI and CID. Opaque to everyone but the connector.
    public var actionRef: String?
    /// The post this one quotes, one level deep.
    public var quote: Quote?
    /// Whether the reader has liked, boosted or bookmarked the post; nil
    /// for articles and anything else no action applies to.
    public var viewer: Viewer?
    /// The links in `body`: web links, mentions and hashtags, each with
    /// where it sits in the text and where it goes.
    public var links: [Link] = []

    /// A run of `body` that links somewhere. Offsets count UTF-16 code
    /// units, as `NSAttributedString` does.
    public struct Link: Codable, Sendable, Hashable {
        public var start: Int
        public var length: Int
        public var url: String

        public init(start: Int, length: Int, url: String) {
            self.start = start
            self.length = length
            self.url = url
        }
    }

    /// When the reader last changed `viewer` from this device. A fetch
    /// that started before then can't undo the change (`InfluxStore.insert`).
    public var viewerChangedAt: Date?

    /// When the fetch that last set `viewer` began. A fetch that began
    /// earlier is older news and can't overwrite it, however late it
    /// finishes (`InfluxStore.insert`). Nil before the first fetch that
    /// carried viewer state.
    public var viewerFetchedAt: Date?

    /// When the complete bookmark list that last settled `viewer.bookmarked`
    /// began. It vouches for the bookmark only, so an older fetch still
    /// brings its likes and boosts but keeps this bookmark.
    public var viewerBookmarkFetchedAt: Date?

    /// True for a post stored only because the account's bookmark list
    /// holds it, not because a timeline brought it: it shows in
    /// Bookmarks but in no other view. A timeline fetching the same post
    /// later clears it (`InfluxStore.insert`).
    public var onlyInBookmarks: Bool = false

    /// The post's own ID on its service, for a copy filed under the merge
    /// key of its bridged copy on another service (ADR 0014); nil when
    /// `mergeKey` is its own.
    public var postKey: String?

    /// A short score the row shows beside its title, such as a review
    /// score; nil for almost everything. Optional, so an item stored
    /// without one, or by a build that didn't know it, still reads.
    public var badge: Badge?

    /// A score shown beside an article's title in a small capsule coloured
    /// by its tone. It is named for what it shows, not for whoever scored
    /// it: any feed that scores its posts can fill it in.
    public struct Badge: Codable, Sendable, Hashable {
        /// How the score reads. Kept as text, so a tone a later build adds
        /// still decodes here, and is drawn without a tone's colour.
        public struct Tone: RawRepresentable, Codable, Sendable, Hashable {
            public var rawValue: String
            public init(rawValue: String) { self.rawValue = rawValue }

            public static let favorable = Tone(rawValue: "favorable")
            public static let mixed = Tone(rawValue: "mixed")
            public static let unfavorable = Tone(rawValue: "unfavorable")
            /// The tones this build knows how to colour.
            public static let known: [Tone] = [.favorable, .mixed, .unfavorable]
        }

        /// What the capsule says, such as "74".
        public var text: String
        public var tone: Tone

        public init(text: String, tone: Tone) {
            self.text = text
            self.tone = tone
        }

        /// What VoiceOver reads for it: "Score 74, favorable".
        public var spoken: String { "Score \(text), \(tone.rawValue)" }
    }

    /// What the signed-in reader has done to a post on its service.
    public struct Viewer: Codable, Sendable, Hashable {
        public var liked: Bool
        public var boosted: Bool
        public var bookmarked: Bool
        /// The reader's own like and boost, where the service needs them to
        /// undo one (a Bluesky record URI). Opaque to everyone but the
        /// connector.
        public var likeRef: String?
        public var boostRef: String?
        /// True for a post stored before Influx kept viewer state: it shows
        /// as nothing done until the service is asked, which happens
        /// before the reader's first action on it or at its next refetch.
        public var unconfirmed: Bool?

        public init(liked: Bool = false, boosted: Bool = false, bookmarked: Bool = false, likeRef: String? = nil, boostRef: String? = nil) {
            self.liked = liked
            self.boosted = boosted
            self.bookmarked = bookmarked
            self.likeRef = likeRef
            self.boostRef = boostRef
        }

        /// The three things a reader can switch on and off for a post.
        public enum Toggle: String, Sendable, CaseIterable {
            case like, boost, bookmark
        }

        public func isOn(_ toggle: Toggle) -> Bool {
            switch toggle {
            case .like: liked
            case .boost: boosted
            case .bookmark: bookmarked
            }
        }

        /// The action that flips `toggle`: an undo when it is on.
        public func action(_ toggle: Toggle) -> ConnectorAction {
            switch toggle {
            case .like: liked ? .unlike : .like
            case .boost: boosted ? .unboost : .boost
            case .bookmark: bookmarked ? .unbookmark : .bookmark
            }
        }

        /// The state once `action` has gone through, before the service
        /// has answered. An undo forgets the record it undoes.
        public func applying(_ action: ConnectorAction) -> Viewer {
            var next = self
            switch action {
            case .like: next.liked = true
            case .unlike: next.liked = false; next.likeRef = nil
            case .boost: next.boosted = true
            case .unboost: next.boosted = false; next.boostRef = nil
            case .bookmark: next.bookmarked = true
            case .unbookmark: next.bookmarked = false
            }
            return next
        }

        /// This state with `toggle` (its flag and record) taken from
        /// `other`, and the other toggles left as they are.
        public func taking(_ toggle: Toggle, from other: Viewer) -> Viewer {
            var next = self
            switch toggle {
            case .like: next.liked = other.liked; next.likeRef = other.likeRef
            case .boost: next.boosted = other.boosted; next.boostRef = other.boostRef
            case .bookmark: next.bookmarked = other.bookmarked
            }
            return next
        }
    }

    public struct LinkCard: Codable, Sendable, Hashable {
        public var url: String
        public var site: String
        public var title: String
        /// The page's own description, as plain text; nil on cards stored
        /// before it was kept, and when the page gives none.
        public var summary: String?
        /// The page's preview image, always an `.image` with its size.
        public var image: Media?

        public init(url: String, site: String, title: String, summary: String? = nil, image: Media? = nil) {
            self.url = url
            self.site = site
            self.title = title
            self.summary = summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.image = image
        }
    }

    /// An image or video shown in a row.
    public struct Media: Codable, Sendable, Hashable {
        public enum Kind: String, Codable, Sendable {
            /// A still image.
            case image
            /// A short silent loop, served as video (Mastodon's gifv).
            case gif
            /// A video with sound; it starts muted.
            case video
        }

        public var kind: Kind
        /// The image, or the video stream (mp4 or HLS). A rich post's is a
        /// `SammyMediaReference`, never a URL: its bytes are read through
        /// a grant that expires.
        public var url: String
        /// A still to show before a gif or video plays, or instead of it.
        public var previewURL: String?
        /// In pixels; always above zero.
        public var width: Int
        public var height: Int
        public var altText: String?
        /// A video's or GIF's length, when its service says; optional, so
        /// media stored before it was kept still reads.
        public var durationMs: Int?

        /// Nil unless both sides are above zero, so every stored media has
        /// a size.
        public init?(kind: Kind, url: String, previewURL: String? = nil, width: Int, height: Int, altText: String? = nil,
                     durationMs: Int? = nil) {
            guard width > 0, height > 0, !url.isEmpty else { return nil }
            self.kind = kind
            self.url = url
            self.previewURL = previewURL
            self.width = width
            self.height = height
            self.altText = altText?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.durationMs = durationMs
        }

        /// Width divided by height.
        public var aspect: Double { Double(width) / Double(height) }
    }

    /// A quoted post, as much of it as a quote card shows. Quotes inside it
    /// are not kept.
    public struct Quote: Codable, Sendable, Hashable {
        /// The quoted post's merge key, so tapping the card can open it.
        public var mergeKey: String
        public var url: String?
        public var authorName: String
        public var authorHandle: String
        public var body: String
        /// The quoted post's first picture (a video's still), sized; nil
        /// when it has none or on quotes stored before it was kept.
        public var image: Media?
        /// Set only on a quote of a post the source can't show; absent
        /// from the stored JSON otherwise, so quotes stored before it read
        /// as they were.
        private var unavailable: Bool?

        public init(mergeKey: String, url: String?, authorName: String, authorHandle: String, body: String, image: Media? = nil) {
            self.mergeKey = mergeKey
            self.url = url
            self.authorName = authorName
            self.authorHandle = authorHandle
            self.body = body
            self.image = image
        }

        /// A quote of a post the source can't show (deleted, private,
        /// blocked or unreachable): all that is known is where it was, and
        /// not always that. It has no author, text or picture.
        public static func unavailable(url: String?) -> Quote {
            var quote = Quote(mergeKey: url ?? "", url: url, authorName: "", authorHandle: "", body: "")
            quote.unavailable = true
            return quote
        }

        /// Whether this quotes a post the source can't show, so its card
        /// says so instead of showing an author and text.
        public var isUnavailable: Bool { unavailable == true }
    }

    public init(
        sourceID: String, remoteID: String, kind: Kind, mergeKey: String,
        authorName: String, authorHandle: String, authorAvatar: String? = nil, title: String? = nil, body: String,
        url: String? = nil, publishedAt: Date, fetchedAt: Date, sortDate: Date? = nil,
        boostedBy: String? = nil, boostedByID: String? = nil, boostedByAvatar: String? = nil, replyToHandle: String? = nil,
        linkCard: LinkCard? = nil, media: [Media] = [], actionRef: String? = nil, quote: Quote? = nil,
        viewer: Viewer? = nil, links: [Link] = [], badge: Badge? = nil
    ) {
        self.sourceID = sourceID
        self.remoteID = remoteID
        self.kind = kind
        self.mergeKey = mergeKey
        self.authorName = authorName
        self.authorHandle = authorHandle
        self.authorAvatar = authorAvatar
        self.title = title
        self.body = body
        self.url = url
        self.publishedAt = publishedAt
        self.fetchedAt = fetchedAt
        self.sortDate = sortDate ?? publishedAt
        self.boostedBy = boostedBy
        self.boostedByID = boostedByID
        self.boostedByAvatar = boostedByAvatar
        self.replyToHandle = replyToHandle
        self.linkCard = linkCard
        self.media = media
        self.actionRef = actionRef
        self.quote = quote
        self.viewer = viewer
        self.links = links
        self.badge = badge
    }

    public static let databaseTableName = "item"

    /// Where the item would place a new row: its sort date, but never later
    /// than when it was fetched, so a date in the future can't hold a row
    /// below everything that arrives after it.
    var placement: Date { min(sortDate, fetchedAt) }

    /// Where the item's age counts from for retention: the later
    /// of its publish and sort dates, so a fresh boost of an old post lasts
    /// as long as the boost, but never later than when it was fetched, so a
    /// feed dated in the future can't outstay the window. `prune` runs the
    /// same expression in SQL.
    var retainedFrom: Date { min(max(publishedAt, sortDate), fetchedAt) }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

/// The point in a saved view that the reader has caught up to: the newest
/// row they have scrolled past. It only moves forward. It names the row by
/// sort date and merge key, which mean the same thing on every device; row
/// IDs are local to one store.
public struct LastReadMarker: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var viewID: String
    public var sortDate: Date
    public var mergeKey: String
    public var updatedAt: Date

    public init(viewID: String, sortDate: Date, mergeKey: String, updatedAt: Date) {
        self.viewID = viewID
        self.sortDate = sortDate
        self.mergeKey = mergeKey
        self.updatedAt = updatedAt
    }

    public static let databaseTableName = "lastReadMarker"

    /// Whether this marker is further along than `other`. Two markers at
    /// the same sort date are ordered by merge key, so every device picks
    /// the same one. Merge keys compare byte by byte in UTF-8, as SQLite
    /// orders the timeline; Swift's own string order differs for some
    /// Unicode keys.
    public func isAhead(of other: LastReadMarker) -> Bool {
        if sortDate != other.sortDate {
            return sortDate > other.sortDate
        }
        return other.mergeKey.utf8.lexicographicallyPrecedes(mergeKey.utf8)
    }
}

/// Where the reader is in a saved view: the row at the top of their screen
/// when they last stopped scrolling, on any device. Unlike
/// the last-read marker it moves both ways, so going back up to an older
/// post on one device takes the others there too. The last device moved
/// wins. The marker still says what has been read.
public struct ReadingPlace: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var viewID: String
    public var mergeKey: String
    /// The row's date as the device that set the place had it: where to go
    /// on a device that doesn't have the row.
    public var sortDate: Date
    /// When the reader moved there, by the clock of the device they were
    /// on. For the journal: no rule compares it.
    public var updatedAt: Date
    /// Which move of the shared place this is: one more than the place it
    /// replaced. Of two places, the one with more moves behind it was made
    /// knowing more; with the same number, neither device knew of the
    /// other's, and the one further along stands. 0 on places from before
    /// moves were counted.
    public var move: Int
    /// The install of Influx the reader was on when they moved there: a
    /// random name each install makes for itself. Nil on places from
    /// before it was kept.
    public var device: String?

    public init(viewID: String, mergeKey: String, sortDate: Date, updatedAt: Date, move: Int = 0, device: String? = nil) {
        self.viewID = viewID
        self.mergeKey = mergeKey
        self.sortDate = sortDate
        self.updatedAt = updatedAt
        self.move = move
        self.device = device
    }

    /// What tells one shared place from another: the row, and which move
    /// put the place there.
    public struct Identity: Sendable, Hashable {
        public var move: Int
        public var mergeKey: String

        public init(move: Int, mergeKey: String) {
            self.move = move
            self.mergeKey = mergeKey
        }
    }

    public var identity: Identity { Identity(move: move, mergeKey: mergeKey) }

    /// Whether this place is further along the timeline than `other`, by
    /// the dates the two carry and then by merge key, as rows are ordered.
    public func isFurtherAlong(than other: ReadingPlace) -> Bool {
        if sortDate != other.sortDate {
            return sortDate > other.sortDate
        }
        return other.mergeKey.utf8.lexicographicallyPrecedes(mergeKey.utf8)
    }

    /// Whether this place stands over `other` when two devices hold
    /// different ones: the one with more moves behind it, and of two with
    /// the same number, the one further along.
    public func supersedes(_ other: ReadingPlace) -> Bool {
        move != other.move ? move > other.move : isFurtherAlong(than: other)
    }

    public static let databaseTableName = "readingPlace"
}

/// The last reading place a view had that iCloud had too: the one this
/// device took from it, or sent it. A move made here since was made
/// knowing that place and nothing later, so a place that arrives and is
/// later than it was made without knowing of the move here.
struct ReadingPlaceBase: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var viewID: String
    var mergeKey: String
    var sortDate: Date
    var move: Int

    init(_ place: ReadingPlace) {
        viewID = place.viewID
        mergeKey = place.mergeKey
        sortDate = place.sortDate
        move = place.move
    }

    var place: ReadingPlace {
        ReadingPlace(viewID: viewID, mergeKey: mergeKey, sortDate: sortDate, updatedAt: .distantPast, move: move)
    }

    static let databaseTableName = "readingPlaceBase"
}

/// What the reader had seen of the shared reading place when they moved.
public enum PlaceKnowledge: Sendable, Hashable {
    /// Whatever place is current: a move made by something that has just
    /// read the place, and in tests.
    case current
    /// The last shared place that was on this device's screen before the
    /// reader moved, or nil when none had been.
    case seen(ReadingPlace.Identity?)

    func includes(_ place: ReadingPlace) -> Bool {
        switch self {
        case .current: true
        case .seen(let seen): seen == place.identity
        }
    }
}

/// What came of moving the reading place.
public enum ReadingPlaceMove: Sendable, Hashable {
    /// The move stands: this is the shared place now.
    case moved(ReadingPlace)
    /// The place was already on that row.
    case unchanged(ReadingPlace)
    /// The move stays on this device; `current` is still the shared place.
    case stayedLocal(current: ReadingPlace)

    /// Whether the shared place changed.
    public var changed: Bool {
        if case .moved = self { true } else { false }
    }
}

/// A last-read marker from another device that names a row this store
/// doesn't have yet, kept until the row arrives.
struct PendingLastReadMarker: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var viewID: String
    var mergeKey: String
    var updatedAt: Date
    /// The row's date as the device that set the marker had it, so the
    /// timelines know how far back to fetch to bring the row here. Nil on
    /// markers set aside before it was kept.
    var sortDate: Date?

    static let databaseTableName = "pendingLastReadMarker"
}

/// Read or unread for one article, keyed by its merge key so the state means
/// the same thing on every device. Kept when an article is marked unread
/// again, so the change syncs.
struct ArticleReadState: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var mergeKey: String
    var isRead: Bool
    var updatedAt: Date

    static let databaseTableName = "articleReadState"

    /// Whether this change should replace `other`: the later one wins, and
    /// at the same instant "read" wins, so every device ends up agreeing
    /// whatever order the changes arrive in.
    func supersedes(_ other: ArticleReadState) -> Bool {
        (updatedAt, isRead ? 1 : 0) > (other.updatedAt, other.isRead ? 1 : 0)
    }
}

/// Whether the reader bookmarked one article or rich feed's post: Influx's
/// own bookmark (`OwnBookmarks.swift`). An RSS feed has no service to keep
/// bookmarks, and a rich feed's post is bookmarked here, not on its
/// service, so Influx keeps them, keyed by merge key like read state, and
/// syncs them. Kept when the bookmark is removed, so the removal syncs.
struct ArticleBookmark: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    var mergeKey: String
    var isBookmarked: Bool
    var updatedAt: Date

    static let databaseTableName = "articleBookmark"

    /// Whether this change should replace `other`: the later one wins, and
    /// at the same instant the bookmark wins, so every device agrees
    /// whatever order the changes arrive in.
    func supersedes(_ other: ArticleBookmark) -> Bool {
        (updatedAt, isBookmarked ? 1 : 0) > (other.updatedAt, other.isBookmarked ? 1 : 0)
    }
}
