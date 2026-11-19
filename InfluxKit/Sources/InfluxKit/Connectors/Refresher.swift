import Foundation

/// The one path from a connector into the store: fetch a page, keep what is
/// inside the retention window, and store it with the source's new cursors,
/// or record the failure as the source's quiet state.
public struct Refresher: Sendable {
    public enum Outcome: Sendable, Hashable {
        /// The page was stored; `newItems` of it weren't stored before.
        case fetched(newItems: Int)
        /// The source asked us to wait (a rate limit), so nothing was sent.
        case waiting(until: Date)
        /// There is nothing older to fetch.
        case reachedOldest
        /// The fetch failed; the source now shows `error` as its problem.
        case failed(ConnectorError)
        /// The task was cancelled before the page was stored; nothing was
        /// recorded.
        case cancelled
        /// Another refresh of the source was already running, so this one
        /// did nothing.
        case alreadyRefreshing
    }

    public let store: InfluxStore

    public init(store: InfluxStore) {
        self.store = store
    }

    /// Fetches one page of `source` with `connector` and stores it. Throws
    /// only when the store itself fails; connector failures come back as
    /// `.failed` and are recorded on the source. One source is refreshed
    /// once at a time per store: a refresh that overlaps another of the
    /// same source returns `.alreadyRefreshing`.
    public func refresh(_ source: Source, with connector: any Connector, direction: FetchDirection = .newer, now: Date = Date()) async throws -> Outcome {
        guard store.beginRefresh(of: source.id) else { return .alreadyRefreshing }
        defer { store.endRefresh(of: source.id) }
        do {
            return try await refreshOnce(source, with: connector, direction: direction, now: now)
        } catch is CancellationError {
            // The store gives up on a cancelled task's reads and writes too.
            return .cancelled
        }
    }

    private func refreshOnce(_ source: Source, with connector: any Connector, direction: FetchDirection, now: Date) async throws -> Outcome {
        if Task.isCancelled {
            return .cancelled
        }
        let state = try await store.fetchState(sourceID: source.id) ?? SourceFetchState(sourceID: source.id)
        if let until = state.retryAfter, until > now {
            return .waiting(until: until)
        }
        let cursor: Cursor?
        switch direction {
        case .newer:
            cursor = state.newerCursor
        case .older:
            guard let older = state.olderCursor, !state.reachedOldest else { return .reachedOldest }
            cursor = older
        }
        var request = Self.request(for: source, direction: direction, cursor: cursor, now: now)
        request.storedRemoteIDs = try await store.remoteIDs(sourceID: source.id)
        request.newestStored = try await store.newestItemDate(sourceID: source.id)

        let page: FetchedPage
        do {
            page = try await connector.fetch(request, from: source)
        } catch is CancellationError {
            return .cancelled
        } catch {
            if Task.isCancelled {
                return .cancelled
            }
            let failure = error as? ConnectorError ?? .badResponse(String(describing: error))
            try await store.recordFailure(failure, sourceID: source.id, at: now)
            return .failed(failure)
        }

        // A page that arrives after cancellation is dropped too, so a
        // cancelled refresh never moves the cursors.
        if Task.isCancelled {
            return .cancelled
        }
        let kept = Self.inWindow(page, for: source, request: request)
        // An unchanged answer (a 304, or a page with nothing in it) writes
        // nothing, so nothing observing the store wakes for it: a source
        // fetched every 30 seconds would otherwise redraw that often.
        if Self.isUnchanged(kept, state: state, direction: direction, now: now) {
            return .fetched(newItems: 0)
        }
        return .fetched(newItems: try await store.record(kept, for: request, sourceID: source.id))
    }

    /// Whether storing `page` would change nothing but the state's times,
    /// and those were recorded recently enough
    /// (`SourceFetchState.needsRecording`).
    static func isUnchanged(_ page: FetchedPage, state: SourceFetchState, direction: FetchDirection, now: Date) -> Bool {
        guard page.items.isEmpty, page.movedTo == nil, page.articleIcon == nil else { return false }
        return !state.needsRecording(state.recording(page, direction: direction, at: now), at: now)
    }

    /// Fetches `sources` a few at a time and returns each one's outcome by
    /// source ID. One source failing doesn't stop the others.
    public func refreshAll(_ sources: [Source], with connector: any Connector, direction: FetchDirection = .newer, maxConcurrent: Int = 6, now: Date = Date()) async throws -> [String: Outcome] {
        try await withThrowingTaskGroup(of: (String, Outcome).self) { group in
            var outcomes: [String: Outcome] = [:]
            var pending = sources[...]
            func startNext() {
                guard let source = pending.popFirst() else { return }
                group.addTask { (source.id, try await refresh(source, with: connector, direction: direction, now: now)) }
            }
            for _ in 0..<max(1, maxConcurrent) {
                startNext()
            }
            while let (id, outcome) = try await group.next() {
                outcomes[id] = outcome
                startNext()
            }
            return outcomes
        }
    }

    /// Pages `source` back until it holds an item from at or before `date`
    /// (the reader's place), it has nothing older, or `maxPages` pages have
    /// come. A device that started fetching recently has only the newest
    /// page; without this, the rows after the reader's place differ from
    /// another device's, and so do the unread counts. Returns how many
    /// pages were fetched.
    @discardableResult
    public func fillGap(of source: Source, with connector: any Connector, backTo date: Date, maxPages: Int = 10, now: Date = Date()) async throws -> Int {
        let notBefore = now.addingTimeInterval(-Self.retention(for: source))
        var pages = 0
        while pages < maxPages, !Task.isCancelled {
            guard let oldest = try await store.oldestItemDate(sourceID: source.id, notBefore: notBefore), oldest > max(date, notBefore) else { break }
            guard case .fetched = try await refresh(source, with: connector, direction: .older, now: now) else { break }
            pages += 1
            // A page that reached no further back has nothing more to give.
            // (Its new-item count can't tell: a bookmark copy it turns into
            // a timeline row isn't new.)
            guard let reached = try await store.oldestItemDate(sourceID: source.id, notBefore: notBefore), reached < oldest else { break }
        }
        return pages
    }

    /// Fetches the account's bookmark list with `connector` and stores it
    /// under `home`, the account's home source. Bookmarks are kept
    /// whatever their age, so nothing is dropped for the retention window.
    /// Returns how many items were new, or nil when the fetch failed, was
    /// cancelled or had to wait. It waits while the home source is asked
    /// to (a rate limit is the account's), and a rate limit it meets is
    /// recorded on the home source so the timeline waits too; any other
    /// failure stays quiet, since the timeline's own refresh shows the
    /// account's problems.
    @discardableResult
    public func refreshBookmarks(of home: Source, with connector: any Connector, now: Date = Date()) async throws -> Int? {
        if let until = try await store.fetchState(sourceID: home.id)?.retryAfter, until > now {
            return nil
        }
        let stored = try await store.remoteIDs(sourceID: home.id)
        let list: BookmarkList
        do {
            list = try await connector.bookmarks(for: home, now: now, storedRemoteIDs: stored)
        } catch let error as ConnectorError {
            if case .rateLimited = error, !Task.isCancelled {
                try await store.recordFailure(error, sourceID: home.id, at: now)
            }
            return nil
        } catch {
            return nil
        }
        if Task.isCancelled {
            return nil
        }
        let items = list.items.map { item in
            var item = item
            item.onlyInBookmarks = true
            // The list says so, whatever the post's own state came as.
            var viewer = item.viewer ?? Item.Viewer()
            viewer.bookmarked = true
            item.viewer = viewer
            return item
        }
        return try await store.storeBookmarks(items, isComplete: list.isComplete, in: home.id, fetchedAt: now)
    }

    /// Stores a page fetched for `request` outside `refresh`, such as the
    /// first page of a feed just added, and returns how many items were
    /// new. While a refresh of the source is running the page is dropped,
    /// since that refresh fetches it anyway, and so is a page whose request
    /// the source's cursor has moved past since.
    @discardableResult
    public func record(_ page: FetchedPage, for source: Source, request: FetchRequest) async throws -> Int {
        guard store.beginRefresh(of: source.id) else { return 0 }
        defer { store.endRefresh(of: source.id) }
        return try await store.record(Self.inWindow(page, for: source, request: request), for: request, sourceID: source.id)
    }

    /// What `recordStreamed` did.
    public enum StreamedOutcome: Sendable, Hashable {
        /// Stored; this many items were new.
        case stored(newItems: Int)
        /// A fetch of the source is under way; nothing was stored.
        case busy
        /// The source has never been fetched, so a stream can't add to it
        /// yet: its first page fixes where paging back starts.
        case notFetchedYet
    }

    /// Stores items a stream sent for `source` as a page of it, through the
    /// same path as a fetched page: the window, the merge with other copies
    /// of each post (ADR 0014), and new rows below the reader's line (ADR 0041).
    /// `advancing` gives the source's next newer cursor from its current
    /// one: the stream's newest item once its statuses are known to follow
    /// on from the cursor, otherwise the same cursor. Like a fetch, it never
    /// overlaps a fetch of the same source.
    public func recordStreamed(_ items: [Item], for source: Source, now: Date = Date(),
                               advancing: @Sendable (Cursor?) -> Cursor?) async throws -> StreamedOutcome {
        guard store.beginRefresh(of: source.id) else { return .busy }
        defer { store.endRefresh(of: source.id) }
        guard let state = try await store.fetchState(sourceID: source.id), state.hasFetchedItems else { return .notFetchedYet }
        var request = Self.request(for: source, direction: .newer, cursor: state.newerCursor, now: now)
        request.isStream = true
        let page = Self.inWindow(FetchedPage(items: items, newer: advancing(state.newerCursor), older: state.olderCursor), for: source, request: request)
        if Self.isUnchanged(page, state: state, direction: .newer, now: now) {
            return .stored(newItems: 0)
        }
        return .stored(newItems: try await store.record(page, for: request, sourceID: source.id))
    }

    /// Items from before `request.notBefore` are dropped, and so is each
    /// item older than its own kind is kept (`InfluxStore.retention(for:)`),
    /// counting ages as `prune` does, so nothing stored here is pruned
    /// straight away: a Sammy feed not yet known to hold posts is fetched
    /// for the article window, and the posts it turns out to hold are
    /// still kept for 7 days only.
    private static func inWindow(_ page: FetchedPage, for source: Source, request: FetchRequest) -> FetchedPage {
        var kept = page
        kept.items = page.items.filter { item in
            item.sourceID == source.id && item.retainedFrom >= request.notBefore
                && item.retainedFrom >= request.now.addingTimeInterval(-InfluxStore.retention(for: item.kind))
        }
        return kept
    }

    /// The request for `source`, with the retention window it is kept for.
    public static func request(for source: Source, direction: FetchDirection, cursor: Cursor?, now: Date) -> FetchRequest {
        FetchRequest(direction: direction, cursor: cursor, notBefore: now.addingTimeInterval(-retention(for: source)), now: now)
    }

    /// How far back a source is fetched: as long as the items it holds are
    /// kept (`InfluxStore.retention(for:)`). RSS feeds hold articles and
    /// social sources posts. A Sammy feed holds posts when its list said
    /// so (`Source.itemKind`); one listed as articles, or not classified,
    /// is fetched for the longer article window.
    static func retention(for source: Source) -> TimeInterval {
        switch source.kind {
        case .rss:
            InfluxStore.retention(for: .article)
        case .sammyFeed:
            InfluxStore.retention(for: source.itemKind == .post ? .post : .article)
        case .mastodonHome, .mastodonList, .blueskyFollowing, .blueskyFeed:
            InfluxStore.retention(for: .post)
        }
    }
}
