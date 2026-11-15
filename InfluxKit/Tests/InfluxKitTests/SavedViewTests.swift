import Foundation
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private let rss = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 3)
private let mastodon = Source(id: "mastodon:@me@example.social:home", kind: .mastodonHome, accountID: "@me@example.social", title: "Mastodon", colorIndex: 1)
private let feed = Source(id: "bluesky:did:plc:me:feed:at://did:plc:x/app.bsky.feed.generator/cats", kind: .blueskyFeed, accountID: "did:plc:me", title: "Cats", colorIndex: 0)

private func post(_ remoteID: String, in source: Source = mastodon, body: String? = nil, at offset: TimeInterval) -> Item {
    Item(
        sourceID: source.id, remoteID: remoteID, kind: .post, mergeKey: "post:\(remoteID)",
        authorName: "Ana Ruiz", authorHandle: "@ana", body: body ?? "Post \(remoteID)",
        publishedAt: t0.addingTimeInterval(offset), fetchedAt: t0.addingTimeInterval(offset)
    )
}

private func row(body: String, title: String? = nil, card: String? = nil, quote: String? = nil) -> TimelineRow {
    TimelineRow(
        id: 1, kind: title == nil ? .post : .article, mergeKey: "k", sourceID: "s", sourceTitle: "Source", colorIndex: 0,
        authorName: "Ana Ruiz", authorHandle: "@ana", title: title, body: body, url: nil,
        publishedAt: t0, sortDate: t0, boostedBy: [], replyToHandle: nil,
        linkCard: card.map { Item.LinkCard(url: "https://example.com", site: "example.com", title: $0) }, media: [],
        quote: quote.map { Item.Quote(mergeKey: "q", url: nil, authorName: "Bo", authorHandle: "@bo", body: $0) },
        isRead: false, viewer: nil, links: []
    )
}

private func hides(_ pattern: String, _ match: ContentFilter.Match = .keyword, in row: TimelineRow) -> Bool {
    TimelineFilter([ContentFilter(pattern: pattern, match: match)]).hides(row)
}

private func store() async throws -> InfluxStore {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [rss, mastodon, feed])
    return store
}

@Suite struct Keywords {
    @Test func matchWholeWordsIgnoringCaseAndAccents() {
        #expect(hides("cat", in: row(body: "My CAT! is asleep")))
        #expect(hides("cafe", in: row(body: "Off to the Café")))
        #expect(hides("café", in: row(body: "off to the cafe")))
        #expect(!hides("cat", in: row(body: "A category of things")))
        #expect(!hides("cat", in: row(body: "bobcats")))
        #expect(hides("cat", in: row(body: "cat")))
    }

    @Test func phrasesMatchWordsInOrder() {
        #expect(hides("world cup", in: row(body: "The World Cup final")))
        #expect(!hides("world cup", in: row(body: "A cup for the world")))
    }

    @Test func punctuationAtAnEndNeedsNoBoundary() {
        #expect(hides("#swift", in: row(body: "Loving #swift today")))
        #expect(hides("#swift", in: row(body: "Loving #SwiftUI today")) == false)
        #expect(hides("@ana", in: row(body: "cc @ana.")))
    }

    @Test func lookAtHeadlinesCardsAndQuotes() {
        #expect(hides("election", in: row(body: "Summary", title: "Election night")))
        #expect(hides("election", in: row(body: "Look", card: "Election results")))
        #expect(hides("election", in: row(body: "This", quote: "About the election")))
        #expect(!hides("ana", in: row(body: "Nothing here")), "authors aren't text the filter reads")
    }

    @Test func blankKeywordsHideNothing() {
        #expect(!hides("   ", in: row(body: "Anything")))
        #expect(TimelineFilter([ContentFilter(pattern: " ", match: .keyword)]).isEmpty)
    }
}

@Suite struct RegularExpressions {
    @Test func matchIgnoringCase() {
        #expect(hides("crypto(currency)?", .regex, in: row(body: "New CRYPTOCURRENCY launch")))
        #expect(hides("^rt\\b", .regex, in: row(body: "RT this")))
        #expect(!hides("^rt\\b", .regex, in: row(body: "Start here")))
    }

    @Test func anInvalidPatternHidesNothingAndIsntValid() {
        let filter = ContentFilter(pattern: "(unclosed", match: .regex)
        #expect(!filter.isValid)
        #expect(TimelineFilter([filter]).isEmpty)
        #expect(!hides("(unclosed", .regex, in: row(body: "(unclosed")))
        #expect(ContentFilter(pattern: "(closed)", match: .regex).isValid)
    }

    @Test func aRunawayPatternGivesUpWithinItsBudget() {
        // Exponential backtracking: every "a" doubles the work of failing.
        let filter = TimelineFilter([ContentFilter(pattern: "(a+)+$", match: .regex)])
        let rows = (0..<20).map { _ in row(body: String(repeating: "a", count: 60) + "!") }
        let clock = ContinuousClock()
        var kept: [TimelineRow] = []
        let elapsed = clock.measure { kept = filter.apply(to: rows) }
        #expect(kept.count == rows.count)
        // The budget, plus slack for a slow CI machine.
        #expect(elapsed < TimelineFilter.expressionBudget * 10)
        // Cheap patterns still match within it.
        #expect(hides("a+!$", .regex, in: rows[0]))
    }

    @Test func switchedOffFiltersHideNothing() {
        let off = ContentFilter(pattern: "cat", match: .keyword, isEnabled: false)
        #expect(!TimelineFilter([off]).hides(row(body: "cat")))
    }
}

@Suite struct SavedViews {
    @Test func aViewShowsOnlyItsSources() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10), post("b", in: feed, at: 20), post("c", in: rss, at: 30)])
        let view = SavedView(name: "Social", sourceIDs: [mastodon.id, feed.id], sortIndex: 0, updatedAt: t0)
        try await store.save(view: view)
        #expect(try await store.rows(inView: view.id).map(\.body) == ["Post a", "Post b"])
        #expect(try await store.rows(inView: SavedView.allID).map(\.body) == ["Post a", "Post b", "Post c"])
        #expect(try await store.rows(inView: "gone").isEmpty)
    }

    @Test func bookmarksShowsEveryBookmarkedPostAndTracksChanges() async throws {
        let store = try await store()
        var saved = post("b", in: feed, at: 20)
        saved.viewer = Item.Viewer(bookmarked: true)
        var liked = post("c", at: 30)
        liked.viewer = Item.Viewer(liked: true)
        try await store.insert([post("a", at: 10), saved, liked])
        #expect(try await store.rows(inView: SavedView.bookmarksID).map(\.body) == ["Post b"])

        try await store.setViewer(Item.Viewer(bookmarked: true), mergeKey: "post:a", sourceID: mastodon.id)
        try await store.setViewer(Item.Viewer(), mergeKey: "post:b", sourceID: feed.id)
        #expect(try await store.rows(inView: SavedView.bookmarksID).map(\.body) == ["Post a"])
    }

    @Test func bookmarksCantBeDeleted() async throws {
        let store = try await store()
        var saved = post("a", at: 10)
        saved.viewer = Item.Viewer(bookmarked: true)
        try await store.insert([saved])
        try await store.deleteView(id: SavedView.bookmarksID)
        #expect(try await store.rows(inView: SavedView.bookmarksID).count == 1)
    }

    @Test func viewsListInOrder() async throws {
        let store = try await store()
        try await store.save(view: SavedView(id: "2", name: "Reading", sourceIDs: [rss.id], sortIndex: 1, updatedAt: t0))
        try await store.save(view: SavedView(id: "1", name: "Social", sourceIDs: [], sortIndex: 0, updatedAt: t0))
        #expect(try await store.savedViews().map(\.name) == ["Social", "Reading"])
    }

    @Test func eachViewKeepsItsOwnMarker() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10), post("b", in: rss, at: 20), post("c", at: 30), post("d", in: rss, at: 40)])
        let social = SavedView(name: "Social", sourceIDs: [mastodon.id], sortIndex: 0, updatedAt: t0)
        try await store.save(view: social)
        try await store.moveLastReadMarker(viewID: SavedView.allID, to: (t0.addingTimeInterval(40), "post:d"))
        try await store.moveLastReadMarker(viewID: social.id, to: (t0.addingTimeInterval(10), "post:a"))

        let all = try #require(try await store.lastReadMarker(viewID: SavedView.allID))
        let mine = try #require(try await store.lastReadMarker(viewID: social.id))
        #expect(ReadingPosition.firstRow(after: all, in: try await store.rows(inView: SavedView.allID)) == nil)
        let socialRows = try await store.rows(inView: social.id)
        #expect(ReadingPosition.firstRow(after: mine, in: socialRows).map { socialRows[$0].mergeKey } == "post:c")
    }

    @Test func quickChangesBothLand() async throws {
        let store = try await store()
        let view = SavedView(name: "Mixed", sourceIDs: [], sortIndex: 0, updatedAt: t0)
        try await store.save(view: view)
        // Started together, from the same old copy as the screen has.
        async let first: Void = store.updateView(id: view.id) { $0.sourceIDs.append(mastodon.id) }
        async let second: Void = store.updateView(id: view.id) { $0.sourceIDs.append(rss.id) }
        async let third: Void = store.updateView(id: view.id) { $0.name = "Both" }
        _ = try await (first, second, third)
        let stored = try #require(try await store.savedViews().first)
        #expect(Set(stored.sourceIDs) == [mastodon.id, rss.id])
        #expect(stored.name == "Both")
        try await store.updateView(id: "gone") { $0.name = "Nothing" }
        #expect(try await store.savedViews().count == 1)
    }

    @Test func deletingAViewTakesItsFiltersAndMarker() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10)])
        let view = SavedView(name: "Social", sourceIDs: [mastodon.id], sortIndex: 0, updatedAt: t0)
        try await store.save(view: view)
        try await store.save(filter: ContentFilter(id: "own", pattern: "x", match: .keyword, viewID: view.id))
        try await store.save(filter: ContentFilter(id: "everywhere", pattern: "y", match: .keyword))
        try await store.moveLastReadMarker(viewID: view.id, to: (t0.addingTimeInterval(10), "post:a"))

        try await store.deleteView(id: view.id)
        #expect(try await store.savedViews().isEmpty)
        #expect(try await store.filters().map(\.id) == ["everywhere"])
        #expect(try await store.lastReadMarker(viewID: view.id) == nil)
    }
}

@Suite struct BookmarkLists {
    private func bookmarked(_ remoteID: String, at offset: TimeInterval) -> Item {
        var item = post(remoteID, at: offset)
        item.viewer = Item.Viewer(bookmarked: true)
        item.onlyInBookmarks = true
        return item
    }

    @Test func aPostOnlyInTheListShowsInBookmarksAlone() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10)])
        try await store.storeBookmarks([bookmarked("a", at: 10), bookmarked("old", at: -30 * 24 * 60 * 60)],
                                       isComplete: true, in: mastodon.id, fetchedAt: t0.addingTimeInterval(20))
        #expect(try await store.rows(inView: SavedView.bookmarksID).map(\.body) == ["Post old", "Post a"])
        #expect(try await store.rows(inView: SavedView.allID).map(\.body) == ["Post a"])
        // The timeline's own copy takes the bookmark.
        #expect(try await store.rows(inView: SavedView.allID).first?.viewer?.bookmarked == true)
        let social = SavedView(name: "Social", sourceIDs: [mastodon.id], sortIndex: 0, updatedAt: t0)
        try await store.save(view: social)
        #expect(try await store.rows(inView: social.id).map(\.body) == ["Post a"])
        // Nor is it pruned for its age.
        #expect(try await store.prune(now: t0) == 0)
    }

    @Test func aTimelineFetchingThePostLaterShowsItEverywhere() async throws {
        let store = try await store()
        try await store.storeBookmarks([bookmarked("a", at: 10)], isComplete: true, in: mastodon.id, fetchedAt: t0.addingTimeInterval(20))
        #expect(try await store.rows(inView: SavedView.allID).isEmpty)
        try await store.insert([post("a", at: 10)])
        #expect(try await store.rows(inView: SavedView.allID).map(\.body) == ["Post a"])
    }

    @Test func aBookmarkMissingFromACompleteListWasRemovedElsewhere() async throws {
        let store = try await store()
        var kept = post("kept", at: 10)
        kept.viewer = Item.Viewer(bookmarked: true)
        var timeline = post("timeline", at: 20)
        timeline.viewer = Item.Viewer(liked: true, bookmarked: true)
        try await store.insert([kept, timeline])
        try await store.storeBookmarks([bookmarked("kept", at: 10), bookmarked("only", at: 5)], isComplete: true, in: mastodon.id, fetchedAt: t0.addingTimeInterval(30))

        // Short of the whole list, nothing is taken as removed.
        try await store.storeBookmarks([bookmarked("kept", at: 10)], isComplete: false, in: mastodon.id, fetchedAt: t0.addingTimeInterval(40))
        #expect(try await store.rows(inView: SavedView.bookmarksID).map(\.body) == ["Post only", "Post kept"])

        try await store.storeBookmarks([bookmarked("kept", at: 10)], isComplete: true, in: mastodon.id, fetchedAt: t0.addingTimeInterval(50))
        #expect(try await store.rows(inView: SavedView.bookmarksID).map(\.body) == ["Post kept"])
        #expect(try await store.viewer(mergeKey: "post:timeline", sourceID: mastodon.id) == Item.Viewer(liked: true))
        // The copy only the list held goes with its bookmark.
        #expect(try await store.remoteIDs(sourceID: mastodon.id) == ["kept", "timeline"])
    }

    @Test func aRateLimitHoldsBackTheListAndTheTimeline() async throws {
        struct Limited: Connector {
            func handles(_ source: Source) -> Bool { true }
            func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage { throw ConnectorError.unsupported }
            func bookmarks(for home: Source, now: Date, storedRemoteIDs: Set<String>) async throws -> BookmarkList {
                throw ConnectorError.rateLimited(retryAfter: t0.addingTimeInterval(600))
            }
        }
        struct Listing: Connector {
            func handles(_ source: Source) -> Bool { true }
            func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage { throw ConnectorError.unsupported }
            func bookmarks(for home: Source, now: Date, storedRemoteIDs: Set<String>) async throws -> BookmarkList {
                var item = post("a", in: home, at: 10)
                item.viewer = Item.Viewer(bookmarked: true)
                return BookmarkList(items: [item], isComplete: true)
            }
        }
        let store = try await store()
        let refresher = Refresher(store: store)
        #expect(try await refresher.refreshBookmarks(of: mastodon, with: Limited(), now: t0) == nil)
        #expect(try await store.fetchState(sourceID: mastodon.id)?.retryAfter == t0.addingTimeInterval(600))
        #expect(try await refresher.refreshBookmarks(of: mastodon, with: Listing(), now: t0.addingTimeInterval(60)) == nil)
        #expect(try await refresher.refreshBookmarks(of: mastodon, with: Listing(), now: t0.addingTimeInterval(700)) == 1)
        #expect(try await store.rows(inView: SavedView.bookmarksID).map(\.body) == ["Post a"])
    }

    @Test func aTimelineFetchThatBeganBeforeTheListCantBringABookmarkBack() async throws {
        let store = try await store()
        var item = post("a", at: 0)
        item.viewer = Item.Viewer(bookmarked: true)
        try await store.insert([item])
        // The whole list, fetched from +20, no longer has it.
        try await store.storeBookmarks([], isComplete: true, in: mastodon.id, fetchedAt: t0.addingTimeInterval(20))
        #expect(try await store.viewer(mergeKey: "post:a", sourceID: mastodon.id) == Item.Viewer())
        // A timeline page fetched from +10 lands after it, still bookmarked.
        item.fetchedAt = t0.addingTimeInterval(10)
        try await store.insert([item])
        #expect(try await store.viewer(mergeKey: "post:a", sourceID: mastodon.id) == Item.Viewer())
        #expect(try await store.rows(inView: SavedView.bookmarksID).isEmpty)
    }

    @Test func theListVouchesForTheBookmarkAloneNotLikes() async throws {
        let store = try await store()
        var item = post("a", at: 0)
        item.viewer = Item.Viewer(bookmarked: true)
        try await store.insert([item])
        try await store.storeBookmarks([], isComplete: true, in: mastodon.id, fetchedAt: t0.addingTimeInterval(20))
        // A thread fetch from +10 lands after the list: its like (and the
        // record an undo needs) still counts, its bookmark doesn't.
        var thread = item
        thread.viewer = Item.Viewer(liked: true, bookmarked: true, likeRef: "like/1")
        thread.fetchedAt = t0.addingTimeInterval(10)
        try await store.applyFetchedViewer(of: thread)
        #expect(try await store.viewer(mergeKey: "post:a", sourceID: mastodon.id) == Item.Viewer(liked: true, likeRef: "like/1"))
        // A copy from another of the account's sources, fetched from +10 too, agrees.
        let list = Source(id: "mastodon:@me@example.social:list:1", kind: .mastodonList, accountID: "@me@example.social", title: "List", colorIndex: 2)
        try await store.save(sources: [list])
        var copy = post("a", in: list, at: 0)
        copy.viewer = thread.viewer
        copy.fetchedAt = t0.addingTimeInterval(10)
        try await store.insert([copy])
        #expect(try await store.viewer(mergeKey: "post:a", sourceID: list.id) == Item.Viewer(liked: true, likeRef: "like/1"))
    }

    @Test func aBookmarkMadeHereAfterTheFetchBeganStays() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10)])
        try await store.setViewer(Item.Viewer(bookmarked: true), mergeKey: "post:a", sourceID: mastodon.id, at: t0.addingTimeInterval(60))
        try await store.storeBookmarks([], isComplete: true, in: mastodon.id, fetchedAt: t0.addingTimeInterval(30))
        #expect(try await store.rows(inView: SavedView.bookmarksID).map(\.body) == ["Post a"])
    }
}

@Suite struct Filters {
    @Test func filtersApplyToEveryViewOrToOne() async throws {
        let store = try await store()
        try await store.insert([
            post("a", body: "Cats are great", at: 10),
            post("b", body: "Dogs are great", at: 20),
            post("c", body: "Birds are great", at: 30),
        ])
        let social = SavedView(name: "Social", sourceIDs: [mastodon.id], sortIndex: 0, updatedAt: t0)
        try await store.save(view: social)
        try await store.save(filter: ContentFilter(pattern: "cats", match: .keyword))
        try await store.save(filter: ContentFilter(pattern: "^dogs", match: .regex, viewID: social.id))
        try await store.save(filter: ContentFilter(pattern: "birds", match: .keyword, viewID: SavedView.allID))

        #expect(try await store.rows(inView: SavedView.allID).map(\.body) == ["Dogs are great"])
        #expect(try await store.rows(inView: social.id).map(\.body) == ["Birds are great"])
        // The unfiltered rows are still there for anything that asks.
        #expect(try await store.rows().count == 3)
    }

    @Test func addingAFilterRemovesRowsInPlace() async throws {
        let store = try await store()
        try await store.insert([
            post("a", body: "One", at: 10),
            post("b", body: "Spoiler ahead", at: 20),
            post("c", body: "Three", at: 30),
        ])
        var iterator = store.observeRows(inView: SavedView.allID).makeAsyncIterator()
        let before = try #require(try await iterator.next())
        #expect(before.count == 3)

        try await store.save(filter: ContentFilter(id: "f", pattern: "spoiler", match: .keyword))
        let after = try #require(try await iterator.next())
        #expect(after.map(\.body) == ["One", "Three"])
        // Only the matching row goes: every other row is unchanged and in
        // the same order, so the timeline anchors on them without a jump.
        let diff = TimelineDiff(from: before, to: after)
        #expect(diff.removed == ["post:b"])
        #expect(diff.inserted.isEmpty && diff.changed.isEmpty && !diff.reordered)

        // Switching it off brings the row back where it was.
        try await store.save(filter: ContentFilter(id: "f", pattern: "spoiler", match: .keyword, isEnabled: false))
        let restored = try #require(try await iterator.next())
        #expect(restored == before)
    }

    @Test func changingAViewsSourcesIsObserved() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10), post("b", in: rss, at: 20)])
        var view = SavedView(name: "Mixed", sourceIDs: [mastodon.id], sortIndex: 0, updatedAt: t0)
        try await store.save(view: view)
        var iterator = store.observeRows(inView: view.id).makeAsyncIterator()
        #expect(try await iterator.next()?.map(\.body) == ["Post a"])
        view.sourceIDs.append(rss.id)
        try await store.save(view: view)
        #expect(try await iterator.next()?.map(\.body) == ["Post a", "Post b"])
    }

    @Test func filteringTwoThousandRowsIsFast() async throws {
        let store = try InfluxStore.inMemory()
        try await SeedFeed.load(into: store, count: 2_000)
        for (index, word) in ["election", "crypto", "spoiler", "football", "weather"].enumerated() {
            try await store.save(filter: ContentFilter(id: "k\(index)", pattern: word, match: .keyword))
        }
        try await store.save(filter: ContentFilter(id: "r", pattern: "\\b(nft|web3)s?\\b", match: .regex))
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { _ = try await store.rows(inView: SavedView.allID) }
        // The same budget as reading the unfiltered rows, generous for CI.
        #expect(elapsed < .milliseconds(250))
    }
}
