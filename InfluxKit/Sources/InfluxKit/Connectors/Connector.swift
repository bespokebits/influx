import Foundation

/// The integration with one kind of service: RSS, Bluesky, Mastodon or
/// Sammy. One value serves one account (RSS has none), and turns its
/// sources into items for the store. Connectors never write to the store themselves; `Refresher`
/// does, so every connector's pages land the same way.
public protocol Connector: Sendable {
    /// Whether this connector fetches `source`.
    func handles(_ source: Source) -> Bool

    /// The sources the account offers: its home feed, lists and custom
    /// feeds. RSS has no account, so its subscriptions are added by URL
    /// instead and this returns none.
    func availableSources() async throws -> [Source]

    /// One page of `source`, newer or older than `request.cursor`. Failures
    /// are thrown as `ConnectorError`, so they show as a quiet state on the
    /// source.
    func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage

    /// The post actions the service supports.
    var supportedActions: Set<ConnectorAction> { get }

    /// Sends an action back to the service and returns what the reader
    /// has done to the post now, as far as the service says.
    func perform(_ action: ConnectorAction, on item: ItemReference) async throws -> Item.Viewer

    /// The conversation around a post: what it answers, and the replies.
    /// Fetched when the reader opens it, never stored.
    func thread(of item: ItemReference) async throws -> PostThread

    /// Whether `thread(of:)` has a thread for `item`, a post in a thread
    /// view: every post where the service has threads, and on a rich feed
    /// only a post that names one. None by default.
    func offersThread(of item: ItemReference) -> Bool

    /// What the reader has done to a post, as the service has it now.
    func viewer(of item: ItemReference) async throws -> Item.Viewer

    /// The posts the account has bookmarked, most recently bookmarked
    /// first, as items of `home`, the account's home source. Posts
    /// in `storedRemoteIDs` need no lookups, as for `fetch`.
    func bookmarks(for home: Source, now: Date, storedRemoteIDs: Set<String>) async throws -> BookmarkList
}

extension Connector {
    public func availableSources() async throws -> [Source] { [] }
    public var supportedActions: Set<ConnectorAction> { [] }
    public func perform(_ action: ConnectorAction, on item: ItemReference) async throws -> Item.Viewer {
        throw ConnectorError.unsupported
    }
    public func thread(of item: ItemReference) async throws -> PostThread {
        throw ConnectorError.unsupported
    }
    public func offersThread(of item: ItemReference) -> Bool { false }
    public func viewer(of item: ItemReference) async throws -> Item.Viewer {
        throw ConnectorError.unsupported
    }
    public func bookmarks(for home: Source, now: Date, storedRemoteIDs: Set<String>) async throws -> BookmarkList {
        throw ConnectorError.unsupported
    }
}

/// An account's bookmarked posts, as its service lists them.
public struct BookmarkList: Sendable, Hashable {
    public var items: [Item]
    /// Whether `items` is the whole list. Only then is a bookmark missing
    /// from it taken as removed; a list cut short at the page limit
    /// unmarks nothing.
    public var isComplete: Bool

    public init(items: [Item], isComplete: Bool) {
        self.items = items
        self.isComplete = isComplete
    }
}

/// Where a connector continues paging from. Its meaning belongs to the
/// connector that made it (a Mastodon status ID, a Bluesky cursor, an RSS
/// feed's ETag); everyone else only stores it and hands it back.
public struct Cursor: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public enum FetchDirection: String, Codable, Sendable {
    /// Items newer than the cursor, or the newest page when there is none.
    case newer
    /// Items older than the cursor, for filling the gap back to the
    /// last-read marker.
    case older
}

public struct FetchRequest: Sendable, Hashable {
    public var direction: FetchDirection
    /// The cursor the source's last page returned for this direction; nil
    /// asks for the newest page.
    public var cursor: Cursor?
    /// Items from before this are past the retention window and
    /// are dropped, so a connector can stop paging here.
    public var notBefore: Date
    /// The fetch time every item in the page is stamped with.
    public var now: Date
    /// The `remoteID`s of the source's items already in the store. The store
    /// keeps the first copy of an item, so a connector can skip the extra
    /// lookups (link cards, image sizes) for these.
    public var storedRemoteIDs: Set<String>
    /// The date of the newest item of the source in the store
    /// (`InfluxStore.newestItemDate(sourceID:)`), or nil when it has none:
    /// where a catch-up read begins (`FetchedPage.catchUpFrom`).
    public var newestStored: Date?
    /// Whether the page comes from a stream rather than a fetch, for the
    /// row history (`RowEvent.Via`).
    public var isStream = false

    public init(direction: FetchDirection, cursor: Cursor?, notBefore: Date, now: Date, storedRemoteIDs: Set<String> = [],
                newestStored: Date? = nil) {
        self.direction = direction
        self.cursor = cursor
        self.notBefore = notBefore
        self.now = now
        self.storedRemoteIDs = storedRemoteIDs
        self.newestStored = newestStored
    }
}

/// One page of items from one source.
public struct FetchedPage: Sendable, Hashable {
    /// In any order; the store places them.
    public var items: [Item]
    /// The cursor for the next `.newer` fetch. A page with nothing new hands
    /// back the cursor it was asked with.
    public var newer: Cursor?
    /// The cursor for the next `.older` fetch, or nil when there is nothing
    /// older (always nil for RSS, which can't page back).
    public var older: Cursor?
    /// The source's new address, when the service says it has moved for
    /// good (a feed's permanent redirect). The Refresher updates the source.
    public var movedTo: String?
    /// For a rich feed's page: each post's identities, `{canonicalId} ∪
    /// aliases`, by its merge key, so the store can show it in one row with
    /// the other copies of the same post (ADR 0014, 0031). Empty for every
    /// other source.
    public var identities: [String: [String]]
    /// For an RSS feed's page: the icon the feed or its site declares, which
    /// is every article's picture. The store gives it to the source's
    /// stored articles too, including those no longer in the feed. Nil when
    /// only a guess is known, which never replaces a stored icon.
    public var articleIcon: String?
    /// Set on a page of a catch-up read, which reads a feed's whole window
    /// past the items the source has (ADR 0031 § Since reads): the
    /// `FetchRequest.newestStored` of the fetch that began it. Such a page
    /// holds days of older posts the reader never had, so of its items the
    /// store doesn't have, it keeps only those dated after this and those
    /// that join a row the timeline already has (`InfluxStore.record`). Nil
    /// for every other page, whose new items are all stored.
    public var catchUpFrom: Date?

    public init(items: [Item], identities: [String: [String]] = [:], newer: Cursor?, older: Cursor?, movedTo: String? = nil,
                articleIcon: String? = nil, catchUpFrom: Date? = nil) {
        self.items = items
        self.identities = identities
        self.newer = newer
        self.older = older
        self.movedTo = movedTo
        self.articleIcon = articleIcon
        self.catchUpFrom = catchUpFrom
    }
}

/// A post action a reader takes on a post.
public enum ConnectorAction: String, Codable, Sendable, CaseIterable {
    case like, unlike
    case boost, unboost
    case bookmark, unbookmark
}

/// Names an item to the service it came from (`InfluxStore.itemReference`).
public struct ItemReference: Sendable, Hashable {
    public var sourceID: String
    public var remoteID: String
    /// `Item.actionRef`: what the connector stored to act on the post.
    public var actionRef: String?
    /// `Item.viewer`: what an undo needs to find the record it removes.
    public var viewer: Item.Viewer?

    public init(sourceID: String, remoteID: String, actionRef: String? = nil, viewer: Item.Viewer? = nil) {
        self.sourceID = sourceID
        self.remoteID = remoteID
        self.actionRef = actionRef
        self.viewer = viewer
    }

    /// How to name `item`, e.g. a post in a thread, to its connector.
    public init(_ item: Item) {
        self.init(sourceID: item.sourceID, remoteID: item.remoteID, actionRef: item.actionRef, viewer: item.viewer)
    }
}

/// A post with the conversation around it, as a thread view shows it. The
/// items are named after the source the post was opened from, so their
/// `ItemReference`s act through the same connector; none of them is stored.
public struct PostThread: Sendable, Hashable {
    /// The posts the post answers, the first post of the conversation first.
    public var ancestors: [Item]
    public var post: Item
    /// Every reply the service sent, in conversation order: each one comes
    /// straight after the post it answers, or after that post's earlier
    /// replies.
    public var replies: [Reply]

    /// What the service says is missing from the thread, at most one of
    /// each position and reason; empty when it knows of nothing missing,
    /// and always empty from a service that doesn't say. A gap doesn't
    /// say where in its list it falls.
    public var gaps: [Gap]

    public struct Reply: Sendable, Hashable {
        public var item: Item
        /// 1 for a reply to the post, 2 for a reply to that reply, and so on.
        public var depth: Int

        public init(item: Item, depth: Int) {
            self.item = item
            self.depth = depth
        }
    }

    /// Posts the service knows belong in the thread and didn't send.
    public struct Gap: Sendable, Hashable {
        public enum Position: String, Sendable, Hashable {
            /// Among the posts the post answers.
            case ancestors
            /// Among the posts after it.
            case replies
        }

        public enum Reason: String, Sendable, Hashable, CaseIterable {
            /// Removed by its author.
            case deleted
            /// Private, blocked or unreachable.
            case unavailable
            /// Past what the service collects, or not fetched.
            case notCollected
            /// A reason this build doesn't know.
            case other
        }

        public var position: Position
        public var reason: Reason

        public init(position: Position, reason: Reason) {
            self.position = position
            self.reason = reason
        }
    }

    public init(ancestors: [Item], post: Item, replies: [Reply], gaps: [Gap] = []) {
        self.ancestors = ancestors
        self.post = post
        self.replies = replies
        self.gaps = gaps
    }
}

extension PostThread {
    /// What the thread view says where posts are missing, at one edge of
    /// its lists: above the first earlier post, or below the last later
    /// one, since a gap doesn't say where in its list it falls. It says
    /// "some posts", never how many.
    public struct MissingNote: Sendable, Hashable {
        public var position: Gap.Position
        /// Each reason once, in a fixed order, whatever order the service
        /// sent them in.
        public var reasons: [Gap.Reason]

        public init(position: Gap.Position, reasons: [Gap.Reason]) {
            self.position = position
            self.reasons = reasons
        }

        public var heading: String {
            position == .ancestors ? "Earlier posts missing" : "Later posts missing"
        }

        /// One sentence per reason.
        public var sentences: [String] {
            reasons.map { Self.sentence(position, $0) }
        }

        static func sentence(_ position: Gap.Position, _ reason: Gap.Reason) -> String {
            switch (position, reason) {
            case (.ancestors, .deleted): "Some earlier posts were deleted by their authors."
            case (.ancestors, .unavailable): "Some earlier posts are private, blocked or unreachable."
            case (.ancestors, .notCollected): "The conversation starts further back than was collected."
            case (.ancestors, .other): "Some earlier posts are missing."
            case (.replies, .deleted): "Some later posts were deleted by their authors."
            case (.replies, .unavailable): "Some later posts are private, blocked or unreachable."
            case (.replies, .notCollected): "The thread goes on past what was collected."
            case (.replies, .other): "Some later posts are missing."
            }
        }
    }

    /// The note for the posts missing at `position`, or nil when the
    /// service knows of none there.
    public func missingNote(at position: Gap.Position) -> MissingNote? {
        let here = Set(gaps.filter { $0.position == position }.map(\.reason))
        guard !here.isEmpty else { return nil }
        return MissingNote(position: position, reasons: Gap.Reason.allCases.filter(here.contains))
    }

    /// Where the whole thread can be read: the opened post's own web page,
    /// with the site to name it by (its host, without `www.`). Nil when
    /// the post has no http or https address.
    public var wholeThread: (url: URL, site: String)? {
        guard let string = post.url, let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", var host = url.host(), !host.isEmpty else { return nil }
        host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return (url, host)
    }
}
