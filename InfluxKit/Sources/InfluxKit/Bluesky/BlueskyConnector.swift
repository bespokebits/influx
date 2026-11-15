import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Bluesky connector for one signed-in account: its Following feed and
/// the custom feeds it has saved, read through the account's PDS.
public struct BlueskyConnector: Connector {
    public let account: BlueskyAccount
    private let resolver: MediaResolver
    /// How many pages a `.newer` fetch reads back to reach what it already
    /// has. Posts beyond that, after a long time away, are not fetched.
    static let maxNewerPages = 10

    /// `resolver` sizes the images the app view gives no size for; by
    /// default it fetches with `http`.
    public init(account: BlueskyAccount, http: any HTTPClient = URLSession.shared, resolver: MediaResolver? = nil) {
        self.account = account
        self.resolver = resolver ?? MediaResolver(client: http)
    }

    public static func followingSourceID(did: String) -> String {
        "bluesky:\(did):following"
    }

    public static func feedSourceID(did: String, feed uri: String) -> String {
        "bluesky:\(did):feed:\(uri)"
    }

    /// The custom feed's `at://` URI, from its source ID.
    static func feedURI(_ source: Source) -> String? {
        guard let did = source.accountID else { return nil }
        let prefix = "bluesky:\(did):feed:"
        guard source.id.hasPrefix(prefix) else { return nil }
        return String(source.id.dropFirst(prefix.count))
    }

    public func handles(_ source: Source) -> Bool {
        (source.kind == .blueskyFollowing || source.kind == .blueskyFeed) && source.accountID == account.accountID
    }

    public func availableSources() async throws -> [Source] {
        let did = account.accountID
        let following = Source(id: Self.followingSourceID(did: did), kind: .blueskyFollowing, accountID: did, title: "Following", colorIndex: 0)
        let feeds = try await account.savedFeeds().map {
            Source(id: Self.feedSourceID(did: did, feed: $0.uri), kind: .blueskyFeed, accountID: did, title: $0.displayName, colorIndex: 0)
        }
        return [following] + feeds
    }

    /// `.older` follows the app view's own cursor. The app view can't page
    /// forward, so `.newer` reads the Following feed from the top until it
    /// reaches the newest post it fetched before (its cursor is that post's
    /// date), and reads a custom feed's first page.
    public func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage {
        let load: @Sendable (String?) async throws -> FeedPage
        switch source.kind {
        case .blueskyFollowing:
            load = { [account] in try await account.timeline(cursor: $0) }
        case .blueskyFeed:
            guard let uri = Self.feedURI(source) else { throw ConnectorError.notFound }
            load = { [account] in try await account.feed(uri, cursor: $0) }
        default:
            throw ConnectorError.unsupported
        }

        switch request.direction {
        case .older:
            let page = try await load(request.cursor?.rawValue)
            let mapped = BlueskyMapping.mapped(page, sourceID: source.id, fetchedAt: request.now)
            let older = Self.older(page, mapped.map(\.item), request, ordered: source.kind == .blueskyFollowing)
            return FetchedPage(items: await complete(mapped, request), newer: nil, older: older)

        case .newer:
            let since = request.cursor.flatMap { ATDate.parse($0.rawValue) }
            var all: [BlueskyMapping.Mapped] = []
            var cursor: String?
            var last: (page: FeedPage, items: [Item])?
            for _ in 0..<Self.maxNewerPages {
                let page = try await load(cursor)
                let pageMapped = BlueskyMapping.mapped(page, sourceID: source.id, fetchedAt: request.now)
                let mapped = pageMapped.map(\.item)
                all += pageMapped
                last = (page, mapped)
                // Only the Following feed is in date order. A custom feed
                // can rank old posts above new ones, so it reads one page.
                guard source.kind == .blueskyFollowing, let since, let next = page.cursor,
                      let oldest = mapped.map(\.sortDate).min(), oldest > since, oldest >= request.notBefore else {
                    break
                }
                cursor = next
            }
            // A page can come back older than the cursor (the newest post
            // was deleted), and the cursor must not move back for it.
            let newestDate = (all.map(\.item.sortDate) + [since].compactMap { $0 }).max()
            let newest = newestDate.map { $0 == since ? request.cursor : Cursor(rawValue: ATDate.format($0)) } ?? request.cursor
            let older = last.flatMap { Self.older($0.page, $0.items, request, ordered: source.kind == .blueskyFollowing) }
            return FetchedPage(items: await complete(all, request), newer: newest, older: older)
        }
    }

    public var supportedActions: Set<ConnectorAction> { Set(ConnectorAction.allCases) }

    /// How many pages of bookmarks a fetch reads, 100 to a page. A longer
    /// list is read only that far, and counts as incomplete.
    static let maxBookmarkPages = 5

    public func bookmarks(for home: Source, now: Date, storedRemoteIDs: Set<String>) async throws -> BookmarkList {
        var mapped: [BlueskyMapping.Mapped] = []
        var cursor: String?
        var isComplete = false
        for _ in 0..<Self.maxBookmarkPages {
            let page = try await account.bookmarks(cursor: cursor)
            mapped += page.posts.compactMap { BlueskyMapping.mapped($0, sourceID: home.id, fetchedAt: now) }
            guard let next = page.cursor else {
                isComplete = true
                break
            }
            cursor = next
        }
        let request = FetchRequest(direction: .newer, cursor: nil, notBefore: .distantPast, now: now, storedRemoteIDs: storedRemoteIDs)
        return BookmarkList(items: await complete(mapped, request), isComplete: isComplete)
    }

    static let likes = "app.bsky.feed.like"
    static let reposts = "app.bsky.feed.repost"

    /// Likes and boosts are records in the reader's repository: making one
    /// keeps its URI in the viewer state, and undoing deletes it.
    /// Bookmarks are kept by the app view.
    public func perform(_ action: ConnectorAction, on item: ItemReference) async throws -> Item.Viewer {
        guard let post = BlueskyMapping.ActionRef(item.actionRef) else { throw ConnectorError.notFound }
        var viewer = item.viewer ?? Item.Viewer()
        let subject: [String: any Sendable] = ["subject": ["uri": post.uri, "cid": post.cid]]
        switch action {
        case .like:
            viewer.likeRef = try await account.createRecord(collection: Self.likes, record: subject).uri
        case .boost:
            viewer.boostRef = try await account.createRecord(collection: Self.reposts, record: subject).uri
        case .unlike:
            if let like = try await ownRecord(viewer.likeRef, of: post, \.like) {
                try await account.deleteRecord(like, collection: Self.likes)
            }
        case .unboost:
            if let repost = try await ownRecord(viewer.boostRef, of: post, \.repost) {
                try await account.deleteRecord(repost, collection: Self.reposts)
            }
        case .bookmark:
            try await account.bookmark(uri: post.uri, cid: post.cid)
        case .unbookmark:
            try await account.removeBookmark(uri: post.uri)
        }
        return viewer.applying(action)
    }

    public func viewer(of item: ItemReference) async throws -> Item.Viewer {
        guard let post = BlueskyMapping.ActionRef(item.actionRef) else { throw ConnectorError.notFound }
        return BlueskyMapping.viewer(try await account.viewer(ofPost: post.uri))
    }

    /// The reader's like or repost of `post`: the one stored, or, when
    /// nothing was stored, the one the app view knows of; nil when there
    /// is none, so there is nothing to undo.
    private func ownRecord(_ stored: String?, of post: BlueskyMapping.ActionRef, _ field: KeyPath<ViewerState, String?>) async throws -> String? {
        if let stored { return stored }
        return try await account.viewer(ofPost: post.uri)?[keyPath: field]
    }

    public func offersThread(of item: ItemReference) -> Bool { true }

    /// The post's thread from the app view: the chain of posts it answers,
    /// and replies a few levels deep.
    public func thread(of item: ItemReference) async throws -> PostThread {
        guard let ref = BlueskyMapping.ActionRef(item.actionRef) else { throw ConnectorError.notFound }
        guard case .post(let view, let parent, let children) = try await account.postThread(ref.uri).thread else {
            throw ConnectorError.notFound
        }
        let now = Date()
        var ancestors: [PostView] = []
        var above = parent
        while case .post(let view, let next, _)? = above {
            ancestors.insert(view, at: 0)
            above = next
        }
        var replies: [(PostView, Int)] = []
        func walk(_ nodes: [ThreadNode], depth: Int) {
            for case .post(let view, _, let children) in nodes {
                replies.append((view, depth))
                walk(children, depth: depth + 1)
            }
        }
        walk(children, depth: 1)

        let all = ancestors.map { ($0, 0) } + [(view, 0)] + replies
        let mapped = all.map { BlueskyMapping.mapped($0.0, sourceID: item.sourceID, fetchedAt: now) }
        let completed = await withTaskGroup(of: (Int, Item?).self) { group in
            for (index, entry) in mapped.enumerated() {
                group.addTask { [resolver] in
                    guard let entry else { return (index, nil) }
                    return (index, entry.lookups.isEmpty ? entry.item : await BlueskyMapping.completing(entry, with: resolver))
                }
            }
            var items = [Item?](repeating: nil, count: all.count)
            for await (index, item) in group { items[index] = item }
            return items
        }
        guard let post = completed[ancestors.count] else { throw ConnectorError.notFound }
        return PostThread(
            ancestors: completed[..<ancestors.count].compactMap { $0 },
            post: post,
            replies: zip(completed[(ancestors.count + 1)...], replies).compactMap { item, reply in
                item.map { PostThread.Reply(item: $0, depth: reply.1) }
            }
        )
    }

    /// The items with their lookups done, in order. The store keeps its
    /// first copy of an item, so one it already has needs none.
    private func complete(_ mapped: [BlueskyMapping.Mapped], _ request: FetchRequest) async -> [Item] {
        await withTaskGroup(of: (Int, Item).self) { group in
            for (index, entry) in mapped.enumerated() {
                if entry.lookups.isEmpty || request.storedRemoteIDs.contains(entry.item.remoteID) {
                    group.addTask { (index, entry.item) }
                } else {
                    group.addTask { [resolver] in (index, await BlueskyMapping.completing(entry, with: resolver)) }
                }
            }
            var completed: [(Int, Item)] = []
            for await entry in group { completed.append(entry) }
            return completed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Where paging back continues after `page`: nowhere once the feed ends,
    /// or, for a feed in date order, once its oldest post is past the
    /// retention window. A ranked custom feed can put recent posts after a
    /// page of old ones, so it keeps the server's cursor until the server
    /// stops giving one; `Refresher` drops the posts that are too old.
    private static func older(_ page: FeedPage, _ items: [Item], _ request: FetchRequest, ordered: Bool) -> Cursor? {
        guard let next = page.cursor else { return nil }
        if ordered, let oldest = items.map(\.sortDate).min(), oldest < request.notBefore { return nil }
        return Cursor(rawValue: next)
    }
}
