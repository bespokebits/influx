// The item menu and the Item menu's current row.
import CoreGraphics
import Foundation
import Testing
import InfluxKit
@testable import Influx

@Suite struct ItemMenus {
    private func row(_ item: Item, source: Source.Kind = .mastodonHome) async throws -> TimelineRow {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: item.sourceID, kind: source, accountID: "a", title: "S", colorIndex: 0)])
        try await store.insert([item])
        return try #require(try await store.rows().first)
    }

    private func post(url: String? = "https://example.social/@ana/1") -> Item {
        Item(sourceID: "m", remoteID: "1", kind: .post, mergeKey: "https://example.social/1",
             authorName: "Ana", authorHandle: "@ana@example.social", body: "Hello there", url: url,
             publishedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
             viewer: Item.Viewer())
    }

    private func article(url: String? = "https://blog.example/post") -> Item {
        var item = post(url: url)
        item.kind = .article
        item.title = "A title"
        item.body = "The summary."
        item.authorHandle = ""
        item.viewer = nil
        return item
    }

    @Test func postsOfferEverything() async throws {
        let row = try await row(post())
        #expect(ItemAction.available(for: row) == ItemAction.allCases)
        guard case .link(let url) = ItemMenu.original(of: row) else {
            Issue.record("a post's original isn't its link")
            return
        }
        #expect(url.absoluteString == "https://example.social/@ana/1")
        #expect(ItemMenu.text(of: row) == "Hello there")
    }

    @Test func postsFromAServiceWithoutThreadsOfferNoThread() async throws {
        let row = try await row(post(), source: .sammyFeed)
        #expect(ItemAction.available(for: row) == ItemAction.allCases.filter { $0 != .openThread })
        #expect(ItemMenu.unavailable(.openThread) == "This item has no thread to open.")
    }

    @Test func aRichPostThatNamesAThreadOffersIt() async throws {
        var item = post()
        item.actionRef = "thread:contract-thread-1"
        item.viewer = nil
        let row = try await row(item, source: .sammyFeed)
        // Its thread, its original and Influx's own bookmark.
        #expect(ItemAction.available(for: row) == ItemAction.allCases)
        #expect(ItemAction.bookmark.title(for: row) == "Bookmark")
    }

    @Test func articlesOpenTheirPageAndAreMarkedRead() async throws {
        let row = try await row(article(), source: .rss)
        #expect(ItemAction.available(for: row) == [.openOriginal, .bookmark, .copyLink, .copyText, .share])
        // The same open as a tap on the article, which marks it read.
        guard case .article(_, let url) = ItemMenu.original(of: row) else {
            Issue.record("an article's original doesn't open the article")
            return
        }
        #expect(url.absoluteString == "https://blog.example/post")
        #expect(ItemMenu.text(of: row) == "A title\n\nThe summary.")
    }

    @Test func itemsWithoutAWebLinkCannotBeOpenedCopiedOrShared() async throws {
        for url in [nil, "at://did:plc:abc/app.bsky.feed.post/1"] {
            let row = try await row(article(url: url), source: .rss)
            #expect(ItemAction.available(for: row) == [.bookmark, .copyText])
            #expect(ItemMenu.original(of: row) == nil)
        }
    }

    @Test func bookmarkSaysWhatItWillDo() async throws {
        var item = post()
        #expect(ItemAction.bookmark.title(for: try await row(item)) == "Bookmark")
        item.viewer = Item.Viewer(bookmarked: true)
        #expect(ItemAction.bookmark.title(for: try await row(item)) == "Remove Bookmark")
        // A post fetched before viewer state was kept has no icons, and no
        // bookmark in its menu.
        item.viewer = nil
        #expect(!ItemAction.available(for: try await row(item)).contains(.bookmark))
    }

    @Test func theMenuGroupsOpensThenTheBookmarkThenCopying() {
        #expect(ItemAction.grouped(ItemAction.allCases) == [
            [.openOriginal, .openThread, .openAuthor], [.bookmark], [.copyLink, .copyText, .share],
        ])
        #expect(ItemAction.grouped([.copyText]) == [[.copyText]])
    }

    @Test func voiceOverCanOpenAPostsOriginal() async throws {
        let names = RowHit.accessibilityActions(for: try await row(post())).map(\.name)
        #expect(names.contains("Open original"))
        // Articles already offer "Open article", which is the same.
        let articleNames = RowHit.accessibilityActions(for: try await row(article(), source: .rss)).map(\.name)
        #expect(articleNames.contains("Open article") && !articleNames.contains("Open original"))
    }
}

/// The Item menu acts on the row last chosen while it's on screen, and on
/// the row at the top of the screen otherwise.
@MainActor
@Test func theItemMenuActsOnTheChosenRowWhileItIsOnScreen() async throws {
    let store = try InfluxStore.inMemory()
    try await SeedFeed.load(into: store, count: 100)
    let expected = try await store.rows(inView: SavedView.allID).count
    let timeline = TimelineController(store: store)
    let surface = StillSurface()
    timeline.surface = surface
    timeline.start()
    timeline.use(RowEnvironment(width: 390, scale: 2, dark: false, typography: Typography()))
    for _ in 0..<500 where timeline.model.count != expected {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(timeline.model.count == expected)
    let model = timeline.model
    defer { timeline.stop() }

    surface.viewportTop = model.offsets[20]
    #expect(timeline.currentRow?.mergeKey == model.rows[20].mergeKey)

    // The last row on screen.
    let last = model.row(at: model.offsets[20] + surface.viewportHeight - 1)
    try #require(last != 20)
    let chosen = model.frame(ofRow: last)
    #expect(timeline.choose(at: CGPoint(x: chosen.midX, y: chosen.minY + 1))?.mergeKey == model.rows[last].mergeKey)
    #expect(timeline.currentRow?.mergeKey == model.rows[last].mergeKey)
    #expect(timeline.visibleFrame(of: model.rows[last])?.minY == chosen.minY)

    // Scrolled away from it, the menu acts on the top row again.
    surface.viewportTop = model.offsets[last + 20]
    #expect(timeline.currentRow?.mergeKey == model.rows[last + 20].mergeKey)
    #expect(timeline.visibleFrame(of: model.rows[last]) == nil)

    // Below the last row there's nothing to choose.
    #expect(timeline.choose(at: CGPoint(x: 10, y: model.totalHeight + 10)) == nil)
}

/// A viewport that moves only when the test moves it.
@MainActor
private final class StillSurface: TimelineSurface {
    var viewportTop: CGFloat = 0
    let viewportHeight: CGFloat = 600
    let isScrolling = false
    let isReaderInput = false

    func setViewportTop(_ y: CGFloat, animated: Bool) {}
    func show(_ keys: [String], reload: Bool, reconfigure: [String]) async {}
    func refreshCell(_ key: String) {}
    func showUnread(_ count: Int) {}
    func flash(_ frame: CGRect) {}
}
