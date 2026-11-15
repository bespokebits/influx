import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Mastodon connector for one signed-in account: its home timeline and
/// its lists, each a source.
public struct MastodonConnector: Connector {
    /// `@user@instance`, as `MastodonMapper.accountID` makes it.
    public let accountID: String
    private let client: MastodonClient
    /// The dot colour new sources from this account start with.
    private let colorIndex: Int
    private let resolver: MediaResolver

    public init(accountID: String, instance: URL, accessToken: String, colorIndex: Int = 0, http: any HTTPClient = URLSession.shared, resolver: MediaResolver? = nil) {
        self.accountID = accountID
        self.client = MastodonClient(instance: instance, accessToken: accessToken, http: http)
        self.colorIndex = colorIndex
        self.resolver = resolver ?? MediaResolver(client: http)
    }

    public func handles(_ source: Source) -> Bool {
        source.accountID == accountID && (source.kind == .mastodonHome || source.kind == .mastodonList)
    }

    public func availableSources() async throws -> [Source] {
        let lists = try await client.lists()
        return [MastodonMapper.homeSource(accountID: accountID, colorIndex: colorIndex)]
            + lists.map { MastodonMapper.listSource($0, accountID: accountID, colorIndex: colorIndex) }
    }

    /// `.newer` without a cursor gets the newest page; with one it gets the
    /// page straight after it (`min_id`), so catching up never skips a
    /// status however long the reader was away. `.older` pages back with
    /// `max_id` until the retention window ends.
    public func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage {
        let page: MastodonClient.Page
        switch (request.direction, request.cursor) {
        case (_, nil): page = .newest
        case (.newer, let cursor?): page = .after(cursor.rawValue)
        case (.older, let cursor?): page = .before(cursor.rawValue)
        }

        let result: MastodonClient.TimelinePage
        switch source.kind {
        case .mastodonHome:
            result = try await client.homeTimeline(page)
        case .mastodonList:
            guard let listID = Self.listID(of: source) else { throw ConnectorError.notFound }
            result = try await client.listTimeline(listID: listID, page)
        default:
            throw ConnectorError.unsupported
        }

        // Cursors come from every status in the page, including any the
        // mapper leaves out, so a page of hidden statuses still moves on.
        let ids = result.statuses.map(\.id)
        let newest = ids.max(by: Self.isOrdered)
        let oldest = result.statuses.min { Self.isOrdered($0.id, $1.id) }

        let newer = newest.map(Cursor.init) ?? (request.direction == .newer ? request.cursor : nil)
        var older: Cursor?
        if let oldest, result.older != nil, oldest.createdAt >= request.notBefore {
            older = Cursor(rawValue: oldest.id)
        }

        let items = await self.items(from: result.statuses, sourceID: source.id, fetchedAt: request.now, stored: request.storedRemoteIDs)
        return FetchedPage(items: items, newer: newer, older: older)
    }

    /// How many pages of bookmarks a fetch reads, 40 to a page. A longer
    /// list is read only that far, and counts as incomplete.
    static let maxBookmarkPages = 10

    public func bookmarks(for home: Source, now: Date, storedRemoteIDs: Set<String>) async throws -> BookmarkList {
        var statuses: [Mastodon.Status] = []
        var page = MastodonClient.Page.newest
        var isComplete = false
        for _ in 0..<Self.maxBookmarkPages {
            let result = try await client.bookmarks(page)
            statuses += result.statuses
            guard let older = result.older else {
                isComplete = true
                break
            }
            page = older
        }
        let items = await self.items(from: statuses, sourceID: home.id, fetchedAt: now, stored: storedRemoteIDs)
        return BookmarkList(items: items, isComplete: isComplete)
    }

    /// Where the account's home stream is, or nil when the instance has
    /// none (`MastodonClient.userStreamURL`).
    public func userStreamURL() async throws(ConnectorError) -> URL? {
        try await client.userStreamURL()
    }

    /// Opens the account's home stream at `url` (`MastodonClient.openUserStream`).
    public func openUserStream(at url: URL, with transport: any MastodonStreamTransport) -> AsyncThrowingStream<MastodonStreamFrame, any Error> {
        client.openUserStream(at: url, with: transport)
    }

    /// Streamed statuses as items of the home source, mapped and looked up
    /// exactly as a fetched page's are, so a streamed post and the same post
    /// fetched later are one row (ADR 0014).
    public func streamedItems(_ statuses: [Mastodon.Status], home: Source, now: Date, stored: Set<String>) async -> [Item] {
        await items(from: statuses, sourceID: home.id, fetchedAt: now, stored: stored)
    }

    /// The statuses as items of `sourceID`, in order, with their lookups
    /// done. The store keeps its first copy, so a stored status needs none.
    private func items(from statuses: [Mastodon.Status], sourceID: String, fetchedAt: Date, stored: Set<String>) async -> [Item] {
        let host = client.instance.host() ?? ""
        return await withTaskGroup(of: (Int, Item).self) { group in
            for (index, status) in statuses.enumerated() {
                guard let item = MastodonMapper.item(from: status, source: sourceID, instanceHost: host, fetchedAt: fetchedAt) else { continue }
                if stored.contains(item.remoteID) {
                    group.addTask { (index, item) }
                    continue
                }
                group.addTask { [resolver] in (index, await MastodonMapper.completing(item, from: status, with: resolver)) }
            }
            var completed: [(Int, Item)] = []
            for await entry in group { completed.append(entry) }
            return completed.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public var supportedActions: Set<ConnectorAction> { Set(ConnectorAction.allCases) }

    /// Acts on the post itself, never a boost of it (`Item.actionRef`).
    public func perform(_ action: ConnectorAction, on item: ItemReference) async throws -> Item.Viewer {
        let status = try await client.act(action, onStatus: item.actionRef ?? item.remoteID)
        // The instance can answer before its own counters catch up, so the
        // action just taken is trusted over what the answer says about it.
        return MastodonMapper.viewer(status.reblog ?? status).applying(action)
    }

    public func viewer(of item: ItemReference) async throws -> Item.Viewer {
        let status = try await client.status(item.actionRef ?? item.remoteID)
        return MastodonMapper.viewer(status.reblog ?? status)
    }

    public func offersThread(of item: ItemReference) -> Bool { true }

    /// The status with its context: everything it answers, and its replies.
    /// Statuses the reader's filters hide are left out, but their replies
    /// keep their depth.
    public func thread(of item: ItemReference) async throws -> PostThread {
        let id = item.actionRef ?? item.remoteID
        async let fetchedStatus = client.status(id)
        async let fetchedContext = client.context(id)
        let (status, context) = try await (fetchedStatus, fetchedContext)
        let host = client.instance.host() ?? ""
        let now = Date()
        let map: @Sendable (Mastodon.Status) -> Item? = { status in
            MastodonMapper.item(from: status, source: item.sourceID, instanceHost: host, fetchedAt: now)
        }
        guard let post = map(status) else { throw ConnectorError.notFound }

        var depths = [status.id: 0]
        var replies: [(Mastodon.Status, Int)] = []
        for reply in context.descendants {
            let depth = (reply.inReplyToId.flatMap { depths[$0] } ?? 0) + 1
            depths[reply.id] = depth
            replies.append((reply, depth))
        }

        // Sizes and cards, looked up together; each keeps its place.
        let all = context.ancestors.map { ($0, 0) } + [(status, 0)] + replies
        let completed = await withTaskGroup(of: (Int, Item?).self) { group in
            for (index, (status, _)) in all.enumerated() {
                group.addTask { [resolver] in
                    guard let item = map(status) else { return (index, nil) }
                    return (index, await MastodonMapper.completing(item, from: status, with: resolver))
                }
            }
            var items = [Item?](repeating: nil, count: all.count)
            for await (index, item) in group { items[index] = item }
            return items
        }
        let ancestors = context.ancestors.count
        return PostThread(
            ancestors: completed[..<ancestors].compactMap { $0 },
            post: completed[ancestors] ?? post,
            replies: zip(completed[(ancestors + 1)...], replies).compactMap { item, reply in
                item.map { PostThread.Reply(item: $0, depth: reply.1) }
            }
        )
    }

    /// The list ID at the end of a list source's ID.
    static func listID(of source: Source) -> String? {
        let prefix = "mastodon:\(source.accountID ?? ""):list:"
        guard source.id.hasPrefix(prefix) else { return nil }
        let id = source.id.dropFirst(prefix.count)
        return id.isEmpty ? nil : String(id)
    }

    /// Mastodon status IDs are decimal strings that grow over time; compare
    /// them as numbers, not as text.
    static func isOrdered(_ a: String, _ b: String) -> Bool {
        a.count != b.count ? a.count < b.count : a < b
    }
}
