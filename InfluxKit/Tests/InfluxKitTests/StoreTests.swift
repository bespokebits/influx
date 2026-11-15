import Foundation
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private let rss = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 3)
private let mastodon = Source(id: "mastodon:@me@example.social:home", kind: .mastodonHome, accountID: "@me@example.social", title: "Mastodon", colorIndex: 1)
private let bluesky = Source(id: "bluesky:did:plc:me:following", kind: .blueskyFollowing, accountID: "did:plc:me", title: "Bluesky", colorIndex: 0)

private func post(_ remoteID: String, in source: Source = mastodon, key: String? = nil, at offset: TimeInterval, boostedBy: String? = nil) -> Item {
    Item(
        sourceID: source.id, remoteID: remoteID, kind: .post, mergeKey: key ?? "post:\(remoteID)",
        authorName: "Ana Ruiz", authorHandle: "@ana", body: "Post \(remoteID)",
        publishedAt: t0.addingTimeInterval(offset), fetchedAt: t0.addingTimeInterval(offset),
        boostedBy: boostedBy
    )
}

private func article(_ remoteID: String, at offset: TimeInterval) -> Item {
    Item(
        sourceID: rss.id, remoteID: remoteID, kind: .article, mergeKey: "https://example.com/\(remoteID)",
        authorName: "Example", authorHandle: "example.com", title: "Article \(remoteID)", body: "Summary",
        url: "https://example.com/\(remoteID)",
        publishedAt: t0.addingTimeInterval(offset), fetchedAt: t0.addingTimeInterval(offset)
    )
}

private func store(with sources: [Source] = [rss, mastodon, bluesky]) async throws -> InfluxStore {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: sources)
    return store
}

@Suite struct Items {
    @Test func rowsAreOldestFirst() async throws {
        let store = try await store()
        try await store.insert([post("b", at: 20), article("a", at: 10), post("c", at: 30)])
        let rows = try await store.rows()
        #expect(rows.map(\.body) == ["Summary", "Post b", "Post c"])
        #expect(rows.map(\.kind) == [.article, .post, .post])
    }

    @Test func equalDatesSortByMergeKeyOnEveryDevice() async throws {
        let first = try await store(), second = try await store()
        try await first.insert([post("x", at: 10), post("y", at: 10)])
        try await second.insert([post("y", at: 10), post("x", at: 10)])
        #expect(try await first.rows().map(\.body) == ["Post x", "Post y"])
        #expect(try await second.rows().map(\.body) == ["Post x", "Post y"])
    }

    @Test func markerFollowsTimelineOrderForUnicodeKeys() async throws {
        let store = try await store()
        // A decomposed "é" sorts before "f" byte by byte, but after it in
        // Swift's string order.
        let accented = "e\u{301}"
        try await store.insert([post("a", key: accented, at: 10), post("b", key: "f", at: 10)])
        let rows = try await store.rows()
        #expect(rows.map(\.mergeKey) == [accented, "f"])
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey)))
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey)))
        #expect(try await !store.moveLastReadMarker(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey)))
    }

    @Test func storedItemsAreNeverRewritten() async throws {
        let store = try await store()
        #expect(try await store.insert([post("a", at: 10)]) == 1)
        var edited = post("a", at: 10)
        edited.body = "Edited"
        #expect(try await store.insert([edited, post("b", at: 20)]) == 1)
        #expect(try await store.rows().map(\.body) == ["Post a", "Post b"])
    }

    @Test func positionDoesNotDependOnFetchTimeOrBatchOrder() async throws {
        func item(_ remoteID: String, in source: Source, key: String, at offset: TimeInterval, fetched: TimeInterval, boostedBy: String? = nil) -> Item {
            Item(
                sourceID: source.id, remoteID: remoteID, kind: .post, mergeKey: key,
                authorName: "Ana Ruiz", authorHandle: "@ana", body: key,
                publishedAt: t0.addingTimeInterval(10), fetchedAt: t0.addingTimeInterval(fetched),
                sortDate: t0.addingTimeInterval(offset), boostedBy: boostedBy
            )
        }
        let first = try await store(), second = try await store()
        // A boost of an earlier post, the earlier post itself, and another
        // post, fetched at different times and listed in different orders
        // on two devices.
        try await first.insert([
            item("o", in: mastodon, key: "post", at: 10, fetched: 60),
            item("b", in: bluesky, key: "post", at: 30, fetched: 70, boostedBy: "Sam Okafor"),
            item("x", in: mastodon, key: "other", at: 20, fetched: 80),
        ])
        try await second.insert([
            item("b", in: bluesky, key: "post", at: 30, fetched: 35, boostedBy: "Sam Okafor"),
            item("x", in: mastodon, key: "other", at: 20, fetched: 900),
            item("o", in: mastodon, key: "post", at: 10, fetched: 9_000),
        ])
        let shape: (TimelineRow) -> String = { "\($0.mergeKey) \($0.sortDate.timeIntervalSince1970) \($0.sourceID) \($0.boostedBy)" }
        let firstRows = try await first.rows().map(shape)
        #expect(firstRows == (try await second.rows().map(shape)))
        #expect(try await first.rows().map(\.mergeKey) == ["post", "other"])
    }

    @Test func futureDatedItemsArePlacedWhenFetched() async throws {
        let store = try await store()
        let future = Item(
            sourceID: rss.id, remoteID: "future", kind: .article, mergeKey: "future",
            authorName: "Example", authorHandle: "example.com", title: "Dated next year", body: "Summary",
            publishedAt: t0.addingTimeInterval(1_000_000), fetchedAt: t0.addingTimeInterval(50)
        )
        try await store.insert([future])
        try await store.insert([post("later", at: 60)])
        let rows = try await store.rows()
        #expect(rows.map(\.mergeKey) == ["future", "post:later"])
        #expect(rows[0].sortDate == t0.addingTimeInterval(50))
        #expect(rows[0].publishedAt == t0.addingTimeInterval(1_000_000))

        // Reading past the future-dated row doesn't stop the marker moving on.
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey)))
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey)))
        #expect(try await store.lastReadMarker(viewID: "all")?.mergeKey == "post:later")
    }

    @Test func linkCardsMediaAndQuotesRoundTrip() async throws {
        let store = try await store()
        var item = post("a", at: 10)
        item.linkCard = .init(url: "https://site.example/", site: "site.example", title: "A page")
        item.media = [Item.Media(kind: .video, url: "https://files.example/v.mp4", previewURL: "https://files.example/v.jpg", width: 1600, height: 1200, altText: "A clip")!]
        item.replyToHandle = "@sam"
        item.quote = .init(mergeKey: "post:q", url: "https://example.social/q", authorName: "Sam", authorHandle: "@sam", body: "Quoted")
        try await store.insert([item])
        let row = try #require(try await store.rows().first)
        #expect(row.linkCard == item.linkCard)
        #expect(row.media == item.media)
        #expect(row.media.first?.aspect == 4.0 / 3.0)
        #expect(row.quote == item.quote)
        #expect(row.replyToHandle == "@sam")
        #expect(row.sourceTitle == "Mastodon")
        #expect(row.colorIndex == 1)
    }

    @Test func unavailableQuotesRoundTripAndOlderQuotesReadAsBefore() async throws {
        let store = try await store()
        var item = post("u", at: 10)
        item.quote = .unavailable(url: "https://example.social/@gone/1")
        try await store.insert([item])
        let quote = try #require(try await store.rows().first?.quote)
        #expect(quote.isUnavailable)
        #expect(quote.url == "https://example.social/@gone/1")

        // A quote stored before unavailable quotes were kept has no such
        // key, and one written now leaves it out unless it is set.
        let older = #"{"mergeKey":"post:q","url":"https://example.social/q","authorName":"Sam","authorHandle":"@sam","body":"Quoted"}"#
        let decoded = try JSONDecoder().decode(Item.Quote.self, from: Data(older.utf8))
        #expect(!decoded.isUnavailable)
        #expect(decoded.authorName == "Sam")
        let written = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!written.contains("unavailable"))
    }

    @Test func deletingASourceDeletesItsItems() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10), article("b", at: 20)])
        try await store.delete(sourceID: mastodon.id)
        #expect(try await store.rows().map(\.kind) == [.article])
    }
}

@Suite struct MergedPosts {
    @Test func onePostFromTwoSourcesIsOneRow() async throws {
        let store = try await store()
        try await store.insert([
            post("m1", in: mastodon, key: "same", at: 10),
            post("other", at: 15),
            post("b1", in: bluesky, key: "same", at: 20, boostedBy: "Sam Okafor"),
        ])
        let rows = try await store.rows()
        #expect(rows.count == 2)
        #expect(rows[0].sourceID == mastodon.id)
        #expect(rows[0].boostedBy == ["Sam Okafor"])
    }

    @Test func laterBoostsNeverMoveTheRow() async throws {
        let store = try await store()
        try await store.insert([post("1", key: "p", at: 10), post("2", at: 20)])
        let before = try await store.rows().map(\.id)
        try await store.insert([
            post("3", in: bluesky, key: "p", at: 30, boostedBy: "Grace Liu"),
            post("4", key: "p", at: 40, boostedBy: "Tom Lindqvist"),
        ])
        let after = try await store.rows()
        #expect(after.map(\.id) == before)
        #expect(after[0].boostedBy == ["Grace Liu", "Tom Lindqvist"])
    }

    @Test func lateEarlierCopiesNeverMoveTheRow() async throws {
        let store = try await store()
        try await store.insert([post("boost", in: bluesky, key: "shared", at: 30, boostedBy: "Sam Okafor"), post("x", at: 20)])
        let before = try #require(try await store.rows().first { $0.mergeKey == "shared" })
        // The original post, dated before the boost, turns up on a later fetch.
        try await store.insert([post("original", in: mastodon, key: "shared", at: 10)])
        let rows = try await store.rows()
        #expect(rows.map(\.mergeKey) == ["post:x", "shared"])
        let after = try #require(rows.last)
        #expect(after.id == before.id)
        #expect(after.sortDate == before.sortDate)
        #expect(after.sourceID == bluesky.id)
    }

    @Test func rowKeepsItsPlaceWhenItsFirstCopyGoes() async throws {
        let store = try await store()
        try await store.insert([post("boost", in: bluesky, key: "shared", at: 30, boostedBy: "Sam Okafor")])
        try await store.insert([post("original", in: mastodon, key: "shared", at: 10)])
        try await store.delete(sourceID: bluesky.id)
        let row = try #require(try await store.rows().first)
        #expect(row.sourceID == mastodon.id)
        #expect(row.sortDate == t0.addingTimeInterval(30))

        // Once every copy has gone, the group starts again from scratch.
        try await store.delete(sourceID: mastodon.id)
        try await store.save(sources: [mastodon])
        try await store.insert([post("original", in: mastodon, key: "shared", at: 10)])
        #expect(try await store.rows().first?.sortDate == t0.addingTimeInterval(10))
    }

    @Test func scopeLimitsRowsAndBoosters() async throws {
        let store = try await store()
        try await store.insert([
            post("m1", in: mastodon, key: "same", at: 10),
            post("b1", in: bluesky, key: "same", at: 20, boostedBy: "Sam Okafor"),
            article("a", at: 30),
        ])
        let blueskyOnly = try await store.rows(in: .sources([bluesky.id]))
        #expect(blueskyOnly.count == 1)
        #expect(blueskyOnly[0].sourceID == bluesky.id)
        #expect(blueskyOnly[0].boostedBy == ["Sam Okafor"])
        let mastodonOnly = try await store.rows(in: .sources([mastodon.id]))
        #expect(mastodonOnly.map(\.boostedBy) == [[]])
    }
}

@Suite struct Observation {
    @Test func observationDeliversAppends() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10)])
        var iterator = store.observeRows().makeAsyncIterator()
        let first = try await iterator.next()
        #expect(first?.map(\.body) == ["Post a"])
        try await store.insert([post("b", at: 20)])
        let second = try await iterator.next()
        #expect(second?.map(\.body) == ["Post a", "Post b"])
    }

    @Test func observationDeliversEachMoveOfTheMarker() async throws {
        let store = try await store()
        try await store.insert([post("a", at: 10), post("b", at: 20)])
        var iterator = store.observeLastReadMarker(viewID: "all").makeAsyncIterator()
        let none = try await iterator.next()
        #expect(none == .some(nil))
        try await store.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(10), "post:a"))
        #expect(try await iterator.next()??.mergeKey == "post:a")
        try await store.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(20), "post:b"))
        #expect(try await iterator.next()??.mergeKey == "post:b")
    }
}

@Suite struct ReadState {
    @Test func lastReadMarkerOnlyMovesForward() async throws {
        let store = try await store()
        try await store.insert([post("z", at: 10), post("a", at: 20), post("b", at: 20), post("c", at: 20)])
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(20), "post:b")))
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(10), "post:z")) == false)
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(20), "post:a")) == false)
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(20), "post:c")))
        let marker = try #require(try await store.lastReadMarker(viewID: "all"))
        #expect(marker.mergeKey == "post:c")
        #expect(try await store.lastReadMarker(viewID: "other") == nil)
    }

    @Test func syncedMarkersUseTheReceivingTimelinesPlaces() async throws {
        let day: TimeInterval = 24 * 60 * 60
        let first = try await store(), second = try await store()
        let original = post("original", in: mastodon, key: "shared", at: 0)
        let boost = post("boost", in: bluesky, key: "shared", at: 3 * day, boostedBy: "Sam Okafor")
        // The first device saw the boost first, the second the original.
        try await first.insert([boost])
        try await first.insert([original])
        try await second.insert([original])
        try await second.insert([boost])
        try await second.insert([post("between", at: day)])

        let sent = try #require(try await first.rows().first { $0.mergeKey == "shared" })
        #expect(sent.sortDate == t0.addingTimeInterval(3 * day))
        try await second.moveLastReadMarker(viewID: "all", to: (sent.sortDate, sent.mergeKey))
        #expect(try await second.lastReadMarker(viewID: "all")?.sortDate == t0)

        // The row after it on the second device is still unread there.
        let between = try #require(try await second.rows().last)
        #expect(between.mergeKey == "post:between")
        #expect(try await second.moveLastReadMarker(viewID: "all", to: (between.sortDate, between.mergeKey)))
    }

    @Test func markersSyncedBeforeTheirRowArriveMoveOntoIt() async throws {
        let day: TimeInterval = 24 * 60 * 60
        let store = try await store()
        // The marker names a boost three days after the original, but this
        // device has neither yet.
        try await store.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(3 * day), "shared"))
        try await store.insert([post("original", in: mastodon, key: "shared", at: 0), post("between", at: day)])
        #expect(try await store.lastReadMarker(viewID: "all")?.sortDate == t0)
        let between = try #require(try await store.rows().last)
        #expect(try await store.moveLastReadMarker(viewID: "all", to: (between.sortDate, between.mergeKey)))
    }

    @Test func pendingMarkersNeverUndoProgressWhicheverArrivesFirst() async throws {
        let markerFirst = try await store(), rowFirst = try await store()
        let late = post("a", key: "a", at: 10)
        for store in [markerFirst, rowFirst] {
            try await store.insert([post("b", key: "b", at: 20)])
            try await store.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(20), "b"))
        }
        // Another device read up to "a" at its date 30; here "a" sits at 10.
        #expect(try await !markerFirst.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(30), "a")))
        #expect(try await markerFirst.lastReadMarker(viewID: "all")?.mergeKey == "b")
        try await markerFirst.insert([late])

        try await rowFirst.insert([late])
        #expect(try await !rowFirst.moveLastReadMarker(viewID: "all", to: (t0.addingTimeInterval(30), "a")))

        for store in [markerFirst, rowFirst] {
            let marker = try #require(try await store.lastReadMarker(viewID: "all"))
            #expect(marker.mergeKey == "b")
            #expect(marker.sortDate == t0.addingTimeInterval(20))
        }
    }

    @Test func articleReadStateIsLastWriterWins() async throws {
        let store = try await store()
        try await store.insert([article("a", at: 10)])
        try await store.setArticle(mergeKey: "https://example.com/a", read: true, at: t0.addingTimeInterval(100))
        #expect(try await store.rows().first?.isRead == true)
        try await store.setArticle(mergeKey: "https://example.com/a", read: false, at: t0.addingTimeInterval(50))
        #expect(try await store.rows().first?.isRead == true)
        try await store.setArticle(mergeKey: "https://example.com/a", read: false, at: t0.addingTimeInterval(200))
        #expect(try await store.rows().first?.isRead == false)
    }

    @Test func markersConvergeWhateverOrderTheyArriveIn() async throws {
        let a = (sortDate: t0.addingTimeInterval(20), mergeKey: "post:a")
        let b = (sortDate: t0.addingTimeInterval(20), mergeKey: "post:b")
        let first = try await store(), second = try await store()
        for store in [first, second] {
            try await store.insert([post("a", at: 20), post("b", at: 20)])
        }
        try await first.moveLastReadMarker(viewID: "all", to: a)
        try await first.moveLastReadMarker(viewID: "all", to: b)
        try await second.moveLastReadMarker(viewID: "all", to: b)
        try await second.moveLastReadMarker(viewID: "all", to: a)
        #expect(try await first.lastReadMarker(viewID: "all")?.mergeKey == "post:b")
        #expect(try await second.lastReadMarker(viewID: "all")?.mergeKey == "post:b")
    }

    @Test func simultaneousReadChangesConverge() async throws {
        let key = "https://example.com/a"
        let at = t0.addingTimeInterval(100)
        let first = try await store(), second = try await store()
        for store in [first, second] {
            try await store.insert([article("a", at: 10)])
        }
        try await first.setArticle(mergeKey: key, read: true, at: at)
        try await first.setArticle(mergeKey: key, read: false, at: at)
        try await second.setArticle(mergeKey: key, read: false, at: at)
        try await second.setArticle(mergeKey: key, read: true, at: at)
        #expect(try await first.rows().first?.isRead == true)
        #expect(try await second.rows().first?.isRead == true)
    }
}

@Suite struct Retention {
    @Test func prunesPostsAfterSevenDaysAndArticlesAfterThirty() async throws {
        let store = try await store()
        let day: TimeInterval = 24 * 60 * 60
        try await store.insert([
            post("old", at: -8 * day), post("recent", at: -6 * day),
            article("old", at: -31 * day), article("recent", at: -29 * day),
        ])
        #expect(try await store.prune(now: t0) == 2)
        let rows = try await store.rows()
        #expect(rows.map(\.body) == ["Summary", "Post recent"])
    }

    @Test func bookmarkedPostsAreKeptUntilTheBookmarkGoes() async throws {
        let store = try await store()
        let day: TimeInterval = 24 * 60 * 60
        var saved = post("saved", at: -8 * day)
        saved.viewer = Item.Viewer(bookmarked: true)
        try await store.insert([saved, post("old", at: -8 * day)])
        #expect(try await store.prune(now: t0) == 1)
        #expect(try await store.rows(inView: SavedView.bookmarksID).map(\.body) == ["Post saved"])

        try await store.setViewer(Item.Viewer(), mergeKey: saved.mergeKey, sourceID: saved.sourceID)
        #expect(try await store.prune(now: t0) == 1)
        #expect(try await store.rows().isEmpty)
    }

    @Test func bookmarkedArticlesShowInBookmarksAndAreKeptUntilTheBookmarkGoes() async throws {
        let store = try await store()
        let day: TimeInterval = 24 * 60 * 60
        try await store.insert([article("saved", at: -31 * day), article("old", at: -31 * day), article("new", at: 0)])
        #expect(try await store.rows().first { $0.title == "Article saved" }?.viewer == Item.Viewer())

        #expect(try await store.toggleOwnBookmark(mergeKey: "https://example.com/saved", at: t0))
        #expect(try await store.prune(now: t0) == 1)
        let bookmarks = try await store.rows(inView: SavedView.bookmarksID)
        #expect(bookmarks.map(\.title) == ["Article saved"])
        #expect(bookmarks.first?.viewer == Item.Viewer(bookmarked: true))
        #expect(try await store.rows().map(\.title) == ["Article saved", "Article new"])

        #expect(try await !store.toggleOwnBookmark(mergeKey: "https://example.com/saved", at: t0))
        #expect(try await store.rows(inView: SavedView.bookmarksID).isEmpty)
        #expect(try await store.prune(now: t0) == 1)
        #expect(try await store.rows().map(\.title) == ["Article new"])
    }

    @Test func anArticleBookmarkIsLastWriterWinsAndATapAlwaysFlipsIt() async throws {
        let store = try await store()
        let key = "https://example.com/a"
        try await store.insert([article("a", at: 10)])
        try await store.setArticle(mergeKey: key, bookmarked: true, at: t0.addingTimeInterval(100))
        try await store.setArticle(mergeKey: key, bookmarked: false, at: t0.addingTimeInterval(50))
        #expect(try await store.rows().first?.viewer?.bookmarked == true)
        // A tap stamped before the stored change, as when another device's
        // clock ran ahead, still flips it.
        #expect(try await !store.toggleOwnBookmark(mergeKey: key, at: t0))
        #expect(try await store.rows().first?.viewer?.bookmarked == false)
    }

    @Test func futureDatedItemsStillExpire() async throws {
        let store = try await store()
        let day: TimeInterval = 24 * 60 * 60
        let future = Item(
            sourceID: mastodon.id, remoteID: "future", kind: .post, mergeKey: "future",
            authorName: "Ana Ruiz", authorHandle: "@ana", body: "From the future",
            publishedAt: t0.addingTimeInterval(365 * day), fetchedAt: t0.addingTimeInterval(-8 * day)
        )
        try await store.insert([future])
        #expect(try await store.prune(now: t0) == 1)
    }

    @Test func aFreshBoostOfAnOldPostLastsAsLongAsTheBoost() async throws {
        let store = try await store()
        let day: TimeInterval = 24 * 60 * 60
        let boost = Item(
            sourceID: mastodon.id, remoteID: "boost", kind: .post, mergeKey: "old-post",
            authorName: "Ana Ruiz", authorHandle: "@ana", body: "Written weeks ago",
            publishedAt: t0.addingTimeInterval(-20 * day), fetchedAt: t0,
            sortDate: t0.addingTimeInterval(-60 * 60), boostedBy: "Sam"
        )
        try await store.insert([boost])
        #expect(try await store.prune(now: t0) == 0)
        #expect(try await store.prune(now: t0.addingTimeInterval(8 * day)) == 1)
    }
}

@Suite struct Seed {
    @Test func seedIsDeterministic() {
        #expect(SeedFeed.items(count: 200) == SeedFeed.items(count: 200))
        #expect(SeedFeed.items(count: 200, seed: 1) != SeedFeed.items(count: 200, seed: 2))
    }

    @Test func seededTimelineHasMixedRowsAndMergedPosts() async throws {
        let store = try InfluxStore.inMemory()
        try await SeedFeed.load(into: store, count: 2_000)
        let rows = try await store.rows()
        #expect(rows.count < 2_000)
        #expect(rows.count > 1_800)
        #expect(rows.contains { $0.kind == .article })
        #expect(rows.contains { !$0.boostedBy.isEmpty })
        #expect(rows.contains { $0.linkCard != nil })
        #expect(rows.contains { !$0.media.isEmpty })
        #expect(rows.contains { $0.quote != nil && $0.quote?.isUnavailable == false })
        #expect(rows.contains { $0.quote?.isUnavailable == true })
        #expect(zip(rows, rows.dropFirst()).allSatisfy { ($0.sortDate, $0.mergeKey) < ($1.sortDate, $1.mergeKey) })
    }

    @Test func loadingTwoThousandRowsIsFast() async throws {
        let store = try InfluxStore.inMemory()
        try await SeedFeed.load(into: store, count: 2_000)
        let clock = ContinuousClock()
        let elapsed = try await clock.measure { _ = try await store.rows() }
        // Generous for CI; launch has to show the cached feed in 300 ms.
        #expect(elapsed < .milliseconds(250))
    }
}
