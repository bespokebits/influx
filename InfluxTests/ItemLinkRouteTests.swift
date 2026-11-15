import Foundation
import Testing
import InfluxKit
@testable import Influx

/// The link back to an item, from Sammy: a bookmark opens Bookmarks at its
/// row, an item no longer bookmarked opens as a tap on its row would, and
/// anything else falls back to Bookmarks.
@MainActor
@Suite(.serialized) struct ItemLinkRoutes {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let rss = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 0)

    private func article(_ name: String) -> Item {
        Item(sourceID: rss.id, remoteID: name, kind: .article, mergeKey: "https://example.com/\(name)",
             authorName: "Example", authorHandle: "example.com", title: "Article \(name)", body: "Summary",
             url: "https://example.com/\(name)", publishedAt: t0, fetchedAt: t0)
    }

    private func post() -> Item {
        Item(sourceID: "m", remoteID: "1", kind: .post, mergeKey: "https://example.social/1",
             authorName: "Ana", authorHandle: "@ana@example.social", body: "Hello", url: "https://example.social/@ana/1",
             publishedAt: t0, fetchedAt: t0, viewer: Item.Viewer())
    }

    /// What a timeline was asked to do.
    @MainActor
    private final class Recorder: ItemMenuTarget {
        var taken: [TimelineItems.Request] = []
        func performOnCurrentRow(_ action: ItemAction) {}
        func take(_ request: TimelineItems.Request) { taken.append(request) }
    }

    /// Runs `body` with the remembered view put back after, since `Views`
    /// keeps its choice in the defaults.
    private func keepingSelection(_ body: () async throws -> Void) async rethrows {
        let key = "InfluxSelectedView"
        let before = UserDefaults.standard.string(forKey: key)
        defer {
            if let before { UserDefaults.standard.set(before, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        try await body()
    }

    @Test func thisBuildRegistersItsOwnScheme() throws {
        let types = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(schemes.contains(ItemLinkRoute.scheme))
        // Tests run the Test build, which must not take the App Store build's links.
        #expect(!schemes.contains(ItemLink.scheme))
    }

    @Test func aBookmarkOpensBookmarksAtItsRow() async throws {
        try await keepingSelection {
            let store = try InfluxStore.inMemory()
            try await store.save(sources: [rss])
            try await store.insert([article("a"), article("b")])
            try await store.setArticle(mergeKey: "https://example.com/b", bookmarked: true)
            let views = Views(store: store)
            views.selectedID = SavedView.allID
            let items = TimelineItems(), old = Recorder()
            items.attach(old)

            let url = ItemLink(key: "https://example.com/b").url(scheme: "dev.bespokebits.influx.example")
            #expect(await ItemLinkRoute.open(url, store: store, views: views, items: items, scheme: "dev.bespokebits.influx.example"))
            #expect(views.selectedID == SavedView.bookmarksID)
            // The timeline showing is about to go; Bookmarks' goes to the row.
            #expect(old.taken.isEmpty)
            let bookmarks = Recorder()
            items.attach(bookmarks)
            #expect(bookmarks.taken == [.reveal("https://example.com/b")])
        }
    }

    @Test func aBookmarkWhileInBookmarksGoesToItsRowAtOnce() async throws {
        try await keepingSelection {
            let store = try InfluxStore.inMemory()
            try await store.save(sources: [rss])
            try await store.insert([article("a")])
            try await store.setArticle(mergeKey: "https://example.com/a", bookmarked: true)
            let views = Views(store: store)
            views.selectedID = SavedView.bookmarksID
            let items = TimelineItems(), timeline = Recorder()
            items.attach(timeline)

            let url = ItemLink(key: "https://example.com/a").url(scheme: "dev.bespokebits.influx.example")
            #expect(await ItemLinkRoute.open(url, store: store, views: views, items: items, scheme: "dev.bespokebits.influx.example"))
            #expect(timeline.taken == [.reveal("https://example.com/a")])
            #expect(items.waiting == nil)
        }
    }

    @Test func anItemNoLongerBookmarkedOpensAsATapOnItsRow() async throws {
        try await keepingSelection {
            let store = try InfluxStore.inMemory()
            try await store.save(sources: [rss])
            try await store.insert([article("a"), article("b")])
            try await store.setArticle(mergeKey: "https://example.com/b", bookmarked: true, at: t0)
            try await store.setArticle(mergeKey: "https://example.com/b", bookmarked: false, at: t0.addingTimeInterval(1))
            let views = Views(store: store)
            views.selectedID = SavedView.allID
            let items = TimelineItems(), timeline = Recorder()
            items.attach(timeline)

            let url = ItemLink(key: "https://example.com/b").url(scheme: "dev.bespokebits.influx.example")
            #expect(await ItemLinkRoute.open(url, store: store, views: views, items: items, scheme: "dev.bespokebits.influx.example"))
            guard case .open(let row) = try #require(timeline.taken.first) else {
                Issue.record("not opened")
                return
            }
            #expect(row.mergeKey == "https://example.com/b")
            #expect(views.selectedID == SavedView.allID)
            guard case .article(_, let page) = RowHit.opening(row) else {
                Issue.record("an article's tap opens its page")
                return
            }
            #expect(page.absoluteString == "https://example.com/b")
        }
    }

    @Test func aBookmarkThatIsGoneOpensBookmarksWithANotice() async throws {
        try await keepingSelection {
            let store = try InfluxStore.inMemory()
            try await store.save(sources: [rss])
            let views = Views(store: store)
            views.selectedID = SavedView.allID
            let items = TimelineItems(), old = Recorder()
            items.attach(old)

            let url = ItemLink(key: "https://example.com/gone").url(scheme: "dev.bespokebits.influx.example")
            #expect(await ItemLinkRoute.open(url, store: store, views: views, items: items, scheme: "dev.bespokebits.influx.example"))
            #expect(views.selectedID == SavedView.bookmarksID)
            // The timeline showing is about to go; Bookmarks' shows it.
            #expect(old.taken.isEmpty)
            let bookmarks = Recorder()
            items.attach(bookmarks)
            #expect(bookmarks.taken == [.notice(ItemLinkRoute.goneNotice)])
        }
    }

    @Test func aBookmarkNotStoredHereOpensBookmarks() async throws {
        try await keepingSelection {
            let store = try InfluxStore.inMemory()
            try await store.setArticle(mergeKey: "https://example.com/elsewhere", bookmarked: true)
            let views = Views(store: store)
            views.selectedID = SavedView.allID
            let items = TimelineItems(), timeline = Recorder()
            items.attach(timeline)

            let url = ItemLink(key: "https://example.com/elsewhere").url(scheme: "dev.bespokebits.influx.example")
            #expect(await ItemLinkRoute.open(url, store: store, views: views, items: items, scheme: "dev.bespokebits.influx.example"))
            #expect(views.selectedID == SavedView.bookmarksID)
            #expect(timeline.taken.isEmpty)
            #expect(items.waiting == nil)
        }
    }

    @Test func signInCallbacksAndOtherLinksAreLeftAlone() async throws {
        try await keepingSelection {
            let store = try InfluxStore.inMemory()
            let views = Views(store: store)
            views.selectedID = SavedView.allID
            let items = TimelineItems(), timeline = Recorder()
            items.attach(timeline)
            for address in [
                "dev.bespokebits.influx:/oauth/sammy?code=c&state=s",
                "dev.bespokebits.influx://oauth/mastodon?code=c&state=s",
                "dev.bespokebits.influx://item?ref=short",
                "https://example.com/item?ref=\(ItemLink(key: "k").ref)",
            ] {
                #expect(await !ItemLinkRoute.open(URL(string: address)!, store: store, views: views, items: items, scheme: ItemLink.scheme))
            }
            #expect(views.selectedID == SavedView.allID)
            #expect(timeline.taken.isEmpty)
        }
    }

    @Test func aRequestBeforeAnyTimelineWaitsForTheFirst() {
        let items = TimelineItems()
        items.send(.notice("Hello"))
        #expect(items.waiting == .notice("Hello"))
        let timeline = Recorder()
        items.attach(timeline)
        #expect(timeline.taken == [.notice("Hello")])
        #expect(items.waiting == nil)
    }

    @Test func aPostOpensItsThreadWhereItsServiceHasThreads() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "m", kind: .mastodonHome, accountID: "a", title: "S", colorIndex: 0)])
        try await store.insert([post()])
        let row = try #require(try await store.rows().first)
        guard case .thread(let opened) = RowHit.opening(row) else {
            Issue.record("a post's tap opens its thread")
            return
        }
        #expect(opened.mergeKey == "https://example.social/1")
    }
}
