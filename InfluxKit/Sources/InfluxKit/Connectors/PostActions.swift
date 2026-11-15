import Foundation
import Synchronization

/// The reader's likes, boosts and bookmarks. A tap shows at once: the new
/// state goes into the store first, then to the service, and the store
/// keeps whatever the service answers, or goes back to how it was if the
/// service refuses.
public final class PostActions: Sendable {
    public let store: InfluxStore
    /// Toggles being sent, by post and toggle. A second tap on the same
    /// toggle waits for nothing and does nothing: sending an undo before
    /// the service has the first change could undo the wrong thing.
    /// Alongside, the latest state of every post acted on, so a like sent
    /// while a bookmark is still going keeps the bookmark, and a post that
    /// is only in a thread is the same post on every page that shows it.
    private let state = Mutex(State())

    private struct State {
        var sending: Set<Sending> = []
        var known: [Post: Item.Viewer] = [:]
        /// When each `known` state was set, so an older fetch can't undo it.
        var knownAt: [Post: Date] = [:]
    }

    /// A post as one account sees it: viewer state belongs to the account,
    /// so the same post read through another account is another post here.
    /// A source with no account stands for itself.
    private struct Post: Hashable {
        var owner: String
        var mergeKey: String
    }

    private struct Sending: Hashable {
        var toggle: Item.Viewer.Toggle
        var post: Post
    }

    public init(store: InfluxStore) {
        self.store = store
    }

    /// The post's current state: the store's when it holds the post, else
    /// the latest this has seen, else what `item` came with.
    public func viewer(of item: Item) async throws -> Item.Viewer {
        let post = try await self.post(item)
        let stored = try await store.viewer(mergeKey: item.mergeKey, sourceID: item.sourceID)
        return state.withLock { stored ?? $0.known[post] } ?? item.viewer ?? Item.Viewer()
    }

    /// Flips `toggle` on `item`, a stored item or a post in a thread, and
    /// returns the post's new state; nil when the same toggle is still
    /// being sent. The toggle's current state comes from the store or from
    /// earlier actions, not from `item`, which may be stale. Only `toggle`
    /// changes: other toggles of the same post sent meanwhile keep their
    /// own outcome. Throws what the connector threw, after putting `toggle`
    /// back.
    @discardableResult
    public func toggle(_ toggle: Item.Viewer.Toggle, on item: Item, with connector: any Connector, now: Date = Date()) async throws -> Item.Viewer? {
        let post = try await self.post(item)
        let key = Sending(toggle: toggle, post: post)
        guard state.withLock({ $0.sending.insert(key).inserted }) else { return nil }
        defer { _ = state.withLock { $0.sending.remove(key) } }

        // No other change to this toggle is in flight, so the store (or,
        // for a post it doesn't hold, the latest seen) has its true state.
        let stored = try await store.viewer(mergeKey: item.mergeKey, sourceID: item.sourceID)
        var before = state.withLock { current in
            let base = current.known[post] ?? stored ?? item.viewer ?? Item.Viewer()
            return stored.map { base.taking(toggle, from: $0) } ?? base
        }
        if before.unconfirmed == true {
            // Stored before Influx kept viewer state: ask before acting, so a
            // like isn't sent twice or an undo sent for nothing.
            let current = try await connector.viewer(of: ItemReference(item))
            state.withLock { $0.known[post] = current; $0.knownAt[post] = now }
            try await store.updateViewer(mergeKey: item.mergeKey, sourceID: item.sourceID, at: now) { $0.unconfirmed == true ? current : $0 }
            before = current
        }
        let action = before.action(toggle)
        var reference = ItemReference(item)
        reference.viewer = before
        // An account last seen signed out will most likely refuse: showing
        // the change first would only take it back, and in Bookmarks a row
        // that leaves and returns moves the page. Its answer shows instead.
        let showsFirst = try await store.fetchState(sourceID: item.sourceID)?.problem != .signedOut
        if showsFirst {
            _ = try await settle(toggle, as: before.applying(action), on: item, as: post, at: now)
        }
        do {
            let after = try await connector.perform(action, on: reference)
            return try await settle(toggle, as: after, on: item, as: post, at: max(now, Date()))
        } catch {
            if showsFirst {
                _ = try? await settle(toggle, as: before, on: item, as: post, at: max(now, Date()))
            }
            throw error
        }
    }

    /// The post's thread, with each post's viewer state as it stands: the
    /// thread's fresh state is kept, in the store and here, unless the
    /// reader changed a post after the fetch began.
    public func thread(of item: Item, with connector: any Connector) async throws -> PostThread {
        let started = Date()
        var thread = try await connector.thread(of: ItemReference(item))
        func reconciled(_ fetched: Item) async throws -> Item {
            // Filed as the store files it, so a bridged post's actions
            // reach its stored copies.
            var fetched = try await store.joined(fetched)
            guard let viewer = fetched.viewer else { return fetched }
            fetched.fetchedAt = started
            try await store.applyFetchedViewer(of: fetched)
            let post = try await self.post(fetched)
            state.withLock { current in
                guard (current.knownAt[post] ?? .distantPast) < started else { return }
                current.known[post] = viewer
                current.knownAt[post] = started
            }
            fetched.viewer = try await self.viewer(of: fetched)
            return fetched
        }
        var ancestors: [Item] = []
        for ancestor in thread.ancestors { ancestors.append(try await reconciled(ancestor)) }
        thread.ancestors = ancestors
        thread.post = try await reconciled(thread.post)
        var replies: [PostThread.Reply] = []
        for reply in thread.replies { replies.append(PostThread.Reply(item: try await reconciled(reply.item), depth: reply.depth)) }
        thread.replies = replies
        return thread
    }

    private func post(_ item: Item) async throws -> Post {
        let accountID = try await store.source(id: item.sourceID)?.accountID
        return Post(owner: accountID.map { "account \($0)" } ?? "source \(item.sourceID)", mergeKey: item.mergeKey)
    }

    /// Sets `toggle` to how it is in `viewer`, in memory and in the store,
    /// and returns the post's whole state.
    private func settle(_ toggle: Item.Viewer.Toggle, as viewer: Item.Viewer, on item: Item, as post: Post, at now: Date) async throws -> Item.Viewer {
        let inMemory = state.withLock { current -> Item.Viewer in
            let next = (current.known[post] ?? item.viewer ?? Item.Viewer()).taking(toggle, from: viewer)
            current.known[post] = next
            current.knownAt[post] = max(now, current.knownAt[post] ?? now)
            return next
        }
        let stored = try await store.updateViewer(mergeKey: item.mergeKey, sourceID: item.sourceID, at: now) { $0.taking(toggle, from: viewer) }
        guard let stored else { return inMemory }
        // The store may know of other toggles' changes (a refetch) that
        // this hadn't seen; keep the two the same.
        state.withLock { $0.known[post] = stored }
        return stored
    }
}
