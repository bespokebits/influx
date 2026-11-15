import Foundation
import Testing
@testable import InfluxKit

// A rich feed's post has Influx's own bookmark, kept and synced as an
// article's is (ADR 0018, 0031): its row's one action, shown in Bookmarks,
// kept past the retention window while it lasts, and on every device.

private let now = RichFixtures.now
private let day: TimeInterval = 24 * 60 * 60
private let rich = RichFixtures.source(.post)
private let mastodon = MastodonMapper.homeSource(accountID: "@reader@example.social", colorIndex: 2)

private func richKey(_ n: Int) -> String {
    "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-\(String(format: "%012d", n))"
}

/// A rich post as the store keeps one: no viewer state.
private func richPost(_ n: Int, at offset: TimeInterval = 0) -> Item {
    Item(sourceID: rich.id, remoteID: "urn:uuid:7bba3b0c-0000-8000-8000-\(String(format: "%012d", n))", kind: .post, mergeKey: richKey(n),
         authorName: "Example Author", authorHandle: "", body: "Rich post \(n)", url: "https://www.example.com/author/posts/\(n)",
         publishedAt: now.addingTimeInterval(offset), fetchedAt: now.addingTimeInterval(offset))
}

private func nativePost() -> Item {
    Item(sourceID: mastodon.id, remoteID: "1", kind: .post, mergeKey: "https://example.social/users/ada/statuses/1",
         authorName: "Ada", authorHandle: "@ada@example.social", body: "Native", url: "https://example.social/@ada/1",
         publishedAt: now, fetchedAt: now, viewer: Item.Viewer())
}

private func store() async throws -> InfluxStore {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [rich, mastodon], at: now)
    return store
}

@Suite struct RichPostBookmarks {
    @Test func aRichPostsOnlyActionIsInfluxsOwnBookmark() async throws {
        let store = try await store()
        try await store.insert([richPost(1), nativePost()])
        let rows = try await store.rows()
        let row = try #require(rows.first { $0.sourceID == rich.id })
        #expect(row.isRich && row.keepsOwnBookmark)
        #expect(row.viewer == Item.Viewer())
        let native = try #require(rows.first { $0.sourceID == mastodon.id })
        #expect(!native.keepsOwnBookmark)

        #expect(try await store.keepsOwnBookmark(richPost(1)))
        #expect(try await !store.keepsOwnBookmark(nativePost()))
    }

    @Test func aBookmarkedRichPostIsInBookmarksAndKeptUntilTheBookmarkGoes() async throws {
        let store = try await store()
        try await store.insert([richPost(1, at: -8 * day), richPost(2, at: -8 * day)])

        #expect(try await store.toggleOwnBookmark(mergeKey: richKey(1), at: now))
        let bookmarks = try await store.rows(inView: SavedView.bookmarksID)
        #expect(bookmarks.map(\.mergeKey) == [richKey(1)])
        #expect(bookmarks.first?.viewer == Item.Viewer(bookmarked: true))
        // Posts go after 7 days, but not a bookmarked one.
        #expect(try await store.prune(now: now) == 1)
        #expect(try await store.rows().map(\.mergeKey) == [richKey(1)])

        #expect(try await !store.toggleOwnBookmark(mergeKey: richKey(1), at: now))
        #expect(try await store.rows(inView: SavedView.bookmarksID).isEmpty)
        #expect(try await store.prune(now: now) == 1)
        #expect(try await store.rows().isEmpty)
    }

    /// What Bookmarks to Sammy Inbox checks before each send.
    @Test func theInboxSeesARichPostsOwnBookmark() async throws {
        let store = try await store()
        try await store.insert([richPost(1)])
        #expect(try await store.isBookmarked(mergeKey: richKey(1), kind: .post) == nil)
        try await store.toggleOwnBookmark(mergeKey: richKey(1), at: now)
        #expect(try await store.isBookmarked(mergeKey: richKey(1), kind: .post) == true)
        try await store.toggleOwnBookmark(mergeKey: richKey(1), at: now)
        #expect(try await store.isBookmarked(mergeKey: richKey(1), kind: .post) == false)
    }

    /// A thread view offers the bookmark on a rich post only when the store
    /// holds it, so Bookmarks can show it.
    @Test func aThreadPostHasItsOwnBookmarkOnlyWhenStored() async throws {
        let store = try await store()
        try await store.insert([richPost(1), nativePost()])
        #expect(try await store.ownBookmark(of: richPost(1)) == Item.Viewer())
        try await store.toggleOwnBookmark(mergeKey: richKey(1), at: now)
        #expect(try await store.ownBookmark(of: richPost(1)) == Item.Viewer(bookmarked: true))
        // Only in the thread: no bookmark to show anywhere.
        #expect(try await store.ownBookmark(of: richPost(2)) == nil)
        // A Mastodon post's bookmark is its service's.
        #expect(try await store.ownBookmark(of: nativePost()) == nil)
        // A rich thread post joined to a stored Mastodon copy, with no rich
        // copy stored: Bookmarks would show the Mastodon copy, so the own
        // bookmark couldn't be removed there.
        var joined = richPost(3)
        joined.mergeKey = nativePost().mergeKey
        #expect(try await store.ownBookmark(of: joined) == nil)
    }
}

/// Two devices on one stand-in iCloud.
private struct Pair {
    let server = InMemorySyncServer()
    let mac: InfluxStore
    let phone: InfluxStore
    private let macSync: SyncCoordinator
    private let phoneSync: SyncCoordinator

    init() throws {
        mac = try InfluxStore.inMemory()
        phone = try InfluxStore.inMemory()
        macSync = SyncCoordinator(store: mac, server: server)
        phoneSync = SyncCoordinator(store: phone, server: server)
    }

    func settle() async throws {
        for _ in 0..<2 {
            try await macSync.sync()
            try await phoneSync.sync()
        }
    }
}

@Suite struct SyncedRichPostBookmarks {
    @Test func aRichPostBookmarkedOnOneDeviceIsInBookmarksOnBoth() async throws {
        let pair = try Pair()
        for store in [pair.mac, pair.phone] {
            try await store.save(sources: [rich], at: now)
            try await store.insert([richPost(1)])
        }
        try await pair.mac.toggleOwnBookmark(mergeKey: richKey(1))
        try await pair.settle()
        #expect(try await pair.phone.rows(inView: SavedView.bookmarksID).map(\.mergeKey) == [richKey(1)])
        #expect(try await pair.phone.rows().first?.viewer == Item.Viewer(bookmarked: true))

        try await pair.phone.toggleOwnBookmark(mergeKey: richKey(1))
        try await pair.settle()
        #expect(try await pair.mac.rows(inView: SavedView.bookmarksID).isEmpty)
        #expect(try await pair.mac.rows().first?.viewer == Item.Viewer())
    }

    /// A bookmark that reaches a device before the post does applies when
    /// the feed brings the post.
    @Test func aBookmarkForARichPostNotFetchedYetShowsWhenItArrives() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rich], at: now)
        try await pair.phone.save(sources: [rich], at: now)
        try await pair.mac.insert([richPost(1)])
        try await pair.mac.toggleOwnBookmark(mergeKey: richKey(1))
        try await pair.settle()
        #expect(try await pair.phone.rows(inView: SavedView.bookmarksID).isEmpty)
        try await pair.phone.insert([richPost(1)])
        #expect(try await pair.phone.rows(inView: SavedView.bookmarksID).map(\.mergeKey) == [richKey(1)])
    }
}
