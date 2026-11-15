// A rich feed's post has Influx's own bookmark, as an article has (ADR
// 0031): the row's icon and menu flip it, with no account signed in, and
// nothing else applies to the post.
import Foundation
import Testing
import InfluxKit
@testable import Influx

@MainActor
@Suite struct RichPostBookmarkActions {
    private let rich = Source(id: "sammy:reader@example.com:feed", kind: .sammyFeed, accountID: "reader@example.com",
                              title: "Posts", colorIndex: 0, itemKind: .post)

    private func richPost(_ n: Int) -> Item {
        Item(sourceID: rich.id, remoteID: "urn:uuid:7bba3b0c-0000-8000-8000-00000000000\(n)", kind: .post,
             mergeKey: "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-00000000000\(n)",
             authorName: "Example Author", authorHandle: "", body: "Rich post \(n)", url: "https://www.example.com/posts/\(n)",
             publishedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// The unit-test host's app: an empty store, no account signed in.
    private func app(with items: [Item]) async throws -> AppModel {
        let app = AppModel.launch()
        try await app.store.save(sources: [rich])
        try await app.store.insert(items)
        return app
    }

    @Test func theRowsBookmarkIsInfluxsOwn() async throws {
        let app = try await app(with: [richPost(1)])
        let interactions = RowInteractions(app: app)
        var row = try #require(try await app.store.rows().first)
        #expect(RowAction.available(for: row) == [.bookmark])

        #expect(await interactions.toggle(.bookmark, on: row) == nil)
        row = try #require(try await app.store.rows().first)
        #expect(row.viewer == Item.Viewer(bookmarked: true))
        #expect(ItemAction.bookmark.title(for: row) == "Remove Bookmark")
        #expect(try await app.store.rows(inView: SavedView.bookmarksID).map(\.mergeKey) == [row.mergeKey])

        // Nothing else applies, and nothing else changes.
        #expect(await interactions.toggle(.like, on: row) == nil)
        #expect(await interactions.toggle(.boost, on: row) == nil)
        #expect(try await app.store.rows().first?.viewer == Item.Viewer(bookmarked: true))

        #expect(await interactions.toggle(.bookmark, on: row) == nil)
        #expect(try await app.store.rows().first?.viewer == Item.Viewer())
        #expect(try await app.store.rows(inView: SavedView.bookmarksID).isEmpty)
    }

    /// In a thread view: a rich post the store holds has the bookmark, and
    /// one only seen there has no action.
    @Test func aThreadPostHasTheBookmarkWhenStored() async throws {
        let app = try await app(with: [richPost(1)])
        let interactions = RowInteractions(app: app)
        #expect(await interactions.ownBookmark(of: richPost(1)) == Item.Viewer())
        var shown: Item.Viewer?
        let notice = await interactions.toggle(.bookmark, on: richPost(1)) { shown = $0 }
        #expect(notice == nil && shown == Item.Viewer(bookmarked: true))
        #expect(await interactions.ownBookmark(of: richPost(1)) == Item.Viewer(bookmarked: true))
        #expect(try await app.store.rows(inView: SavedView.bookmarksID).count == 1)
        #expect(await interactions.ownBookmark(of: richPost(2)) == nil)
    }
}
