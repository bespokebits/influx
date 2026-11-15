import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import InfluxKit

// A catch-up read of a rich feed's whole window (ADR 0031 § Since reads)
// brings every post in the window, including days of older posts the
// reader never had. Only posts that join a row the timeline has, and posts
// newer than the source's newest when the catch-up began, change what the
// reader sees. Posts arrive through the real connectors, refresher and
// store; only HTTP is faked.

private let now = RichFixtures.now
private let mastodonAccount = "@reader@example.social"
private let mastodon = MastodonMapper.homeSource(accountID: mastodonAccount, colorIndex: 2)
private let rich = RichFixtures.source(.post)

/// The Mastodon post the late repost is the same post as.
private let nativeKey = "https://posts.example.com/authors/ada/posts/1001"

private let topURL = RichFixtures.richFeedURL
private let secondURL = "\(RichFixtures.richFeedURL)?before=catch-up-page-2"
private let sinceURL = "\(RichFixtures.richFeedURL)?since=catch-up-since-1"
private let nextSinceURL = "\(RichFixtures.richFeedURL)?since=catch-up-since-2"

private func date(_ text: String) -> Date { FeedDate.iso8601(text)! }

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

/// A rich post numbered `n`, published at `at`.
private func post(_ n: Int, at: Date, aliases: [String] = [], repostedBy: String? = nil) -> [String: Any] {
    let hex = String(format: "%012x", n)
    var post: [String: Any] = [
        "id": "urn:uuid:0193a1b2-0000-7000-8000-\(hex)", "canonicalId": "urn:uuid:0193a1b2-0000-7000-9000-\(hex)", "aliases": aliases,
        "classification": ["kind": "post", "retentionDays": 7], "capabilities": ["text"],
        "url": "https://www.example.com/author/posts/\(n)", "author": ["name": "Example Author"],
        "text": "Post \(n)", "links": [] as [Any], "publishedAt": iso(at),
    ]
    if let repostedBy { post["repostedBy"] = ["name": repostedBy] }
    return post
}

private func remoteID(_ n: Int) -> String { "urn:uuid:0193a1b2-0000-7000-8000-\(String(format: "%012x", n))" }

private func page(_ posts: [[String: Any]], next: String? = nil, since: String? = nil) throws -> Data {
    var page: [String: Any] = [
        "format": "sammy.rich-feed", "version": 1,
        "feed": ["id": RichFixtures.richFeedID, "title": "Feed", "feedUrl": RichFixtures.richFeedURL],
        "items": posts.sorted { ($0["publishedAt"] as! String) > ($1["publishedAt"] as! String) },
    ]
    if let next { page["nextUrl"] = next }
    if let since { page["sinceUrl"] = since }
    return try JSONSerialization.data(withJSONObject: page)
}

/// A Sammy server answering each URL with its page.
private func richConnector(_ routes: [String: Data]) throws -> SammyFeedConnector {
    let headers = try RichFixtures.headers("page")
    let http = FakeHTTPClient { request in
        guard let url = request.url?.absoluteString, let body = routes[url] else { return .init(status: 404) }
        return .init(headers: headers, body: body)
    }
    return try RichFixtures.connector(http)
}

private func status(_ id: String, uri: String, at date: String, url: String? = nil) -> [String: Any] {
    var status: [String: Any] = [
        "id": id, "uri": uri, "created_at": date, "content": "<p>Status \(id)</p>", "spoiler_text": "",
        "account": ["id": "109", "username": "ada", "acct": "ada@posts.example.com", "display_name": "Ada"],
        "mentions": [] as [Any], "media_attachments": [] as [Any], "favourited": false, "reblogged": false, "bookmarked": false,
    ]
    if let url { status["url"] = url }
    return status
}

private func mastodonConnector(_ statuses: [[String: Any]]) -> MastodonConnector {
    let timeline = try! JSONSerialization.data(withJSONObject: statuses)
    let http = FakeHTTPClient { request in
        guard request.url?.path == "/api/v1/timelines/home" else { return .init(status: 404) }
        return .init(body: timeline)
    }
    return MastodonConnector(accountID: mastodonAccount, instance: URL(string: "https://example.social")!, accessToken: "t", http: http, resolver: .testing(http))
}

private func refresh(_ store: InfluxStore, _ source: Source, _ connector: any Connector, at time: Date) async throws -> Int {
    guard case .fetched(let new) = try await Refresher(store: store).refresh(source, with: connector, now: time) else {
        Issue.record("refresh of \(source.id) failed")
        return -1
    }
    return new
}

/// The rows after the All view's last-read marker: what the reader counts
/// as unread.
private func unread(_ store: InfluxStore) async throws -> [TimelineRow] {
    let rows = try await store.rows()
    guard let marker = try await store.lastReadMarker(viewID: SavedView.allID) else { return rows }
    return rows.filter { ReadingPosition.isAfter($0, marker) }
}

private func storedRemoteIDs(_ store: InfluxStore) async throws -> Set<String> {
    try await store.remoteIDs(sourceID: rich.id)
}

/// The rich feed's posts a reader on an earlier build had: three in the
/// evening before `now`.
private var storedPosts: [[String: Any]] { [post(1, at: date("2026-11-04T20:00:00Z")), post(2, at: date("2026-11-04T21:00:00Z")),
                           post(3, at: date("2026-11-04T22:00:00Z"))] }
/// Three posts that really are new since then.
private var newPosts: [[String: Any]] { [post(10, at: date("2026-11-04T23:10:00Z")), post(11, at: date("2026-11-05T00:20:00Z")),
                        post(12, at: date("2026-11-05T00:50:00Z"))] }
/// A week of older posts the reader never had: one between two stored ones,
/// and one an hour back for two days, from before the stored ones.
private var oldPosts: [[String: Any]] {
    [post(100, at: date("2026-11-04T21:30:00Z"))]
    + (1...48).map { post(100 + $0, at: date("2026-11-04T19:00:00Z").addingTimeInterval(-3600 * Double($0))) }
}

/// A store holding the Mastodon home and the rich feed, read once as a build
/// without since reads read it, with the reader caught up to the last row.
private func caughtUpStore() async throws -> InfluxStore {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [mastodon, rich], at: now)
    let statuses = [status("900", uri: "https://posts.example.com/authors/ada/posts/900", at: "2026-11-02T08:00:00.000Z"),
                    status("1001", uri: nativeKey, at: "2026-11-02T09:30:00.000Z", url: "https://posts.example.com/@ada/1001"),
                    status("901", uri: "https://posts.example.com/authors/ada/posts/901", at: "2026-11-02T11:00:00.000Z")]
    #expect(try await refresh(store, mastodon, mastodonConnector(statuses), at: now) == 3)
    // No since link yet: the source's cursor is one from before since reads.
    #expect(try await refresh(store, rich, try richConnector([topURL: try page(storedPosts)]), at: now) == 3)
    let rows = try await store.rows()
    let last = try #require(rows.last)
    #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (last.sortDate, last.mergeKey), at: now))
    _ = try await store.moveReadingPlace(viewID: SavedView.allID, to: (last.sortDate, last.mergeKey), at: now)
    #expect(try await unread(store).isEmpty)
    return store
}

@Suite struct RichCatchUps {
    /// The bug: the first since link reads the whole window, and every older
    /// post the reader never had landed below their place as unread.
    @Test func aCatchUpAddsOnlyJoinsAndNewPosts() async throws {
        let store = try await caughtUpStore()
        let before = try await store.rows()
        let alias = try #require(LegacyPostIdentity.alias(of: nativeKey))
        let lateRepost = post(50, at: date("2026-11-02T09:30:00Z"), aliases: [alias], repostedBy: "Example Reposter")

        let top = try page(newPosts + storedPosts + [oldPosts[0]], next: secondURL, since: sinceURL)
        let second = try page(Array(oldPosts.dropFirst()) + [lateRepost])
        let connector = try richConnector([topURL: top, secondURL: second])
        let added = try await refresh(store, rich, connector, at: now.addingTimeInterval(3600))
        // The three new posts, and the repost that joined its Mastodon copy.
        #expect(added == 4)

        let after = try await store.rows()
        // Nothing moved or was added among the rows the reader had.
        #expect(Array(after.prefix(before.count)).map(\.mergeKey) == before.map(\.mergeKey))
        #expect(Array(after.prefix(before.count)).map(\.sortDate) == before.map(\.sortDate))
        // The repost joined the Mastodon row, which shows from it now.
        let joined = try #require(after.first { $0.mergeKey == nativeKey })
        #expect(joined.sourceID == rich.id)
        // Only the new posts are unread, below the reader in their own order.
        #expect(try await unread(store).map(\.body) == ["Post 10", "Post 11", "Post 12"])
        // The older posts the reader never had aren't stored at all.
        let stored = try await storedRemoteIDs(store)
        #expect(stored.isDisjoint(with: oldPosts.map { $0["id"] as! String }))
        #expect(stored.contains(remoteID(50)))
        #expect(stored.count == storedPosts.count + newPosts.count + 1)

        // From then on, since reads deliver late posts as before: one that
        // entered since the token is new to the reader whatever its date.
        // Dated above what they have read, it goes directly below that
        // (ADR 0041).
        let late = post(60, at: date("2026-11-03T12:00:00Z"))
        let sinceConnector = try richConnector([sinceURL: try page([late], since: nextSinceURL)])
        #expect(try await refresh(store, rich, sinceConnector, at: now.addingTimeInterval(7200)) == 1)
        #expect(try await unread(store).map(\.body) == ["Post 60", "Post 10", "Post 11", "Post 12"])
    }
}

/// Which reads of a rich feed are catch-ups, and where each begins.
@Suite struct RichCatchUpReads {
    private typealias Validators = SammyFeedConnector.Validators

    private static let start = date("2026-11-04T22:00:00Z")

    /// A server answering each URL with its status and page, 404 otherwise.
    private static func connector(_ routes: [String: (status: Int, body: Data?)]) throws -> SammyFeedConnector {
        let headers = try RichFixtures.headers("page")
        let http = FakeHTTPClient { request in
            guard let url = request.url?.absoluteString, let route = routes[url] else { return .init(status: 404) }
            guard let body = route.body else { return .init(status: route.status) }
            return .init(status: route.status, headers: headers, body: body)
        }
        return try RichFixtures.connector(http)
    }

    private static func request(_ validators: Validators, newestStored: Date? = start) -> InfluxKit.FetchRequest {
        var request = RichFixtures.request(rich, cursor: validators.cursor, stored: [remoteID(3)])
        request.newestStored = newestStored
        return request
    }

    private static func validators(_ page: FetchedPage) throws -> Validators {
        try #require(page.newer.flatMap(Validators.init(cursor:)))
    }

    /// The window: a top page offering a since link, and a page below it.
    private static func window() throws -> [String: (status: Int, body: Data?)] {
        [topURL: (200, try page([post(10, at: date("2026-11-04T23:00:00Z")), post(3, at: start)], next: secondURL, since: sinceURL)),
         secondURL: (200, try page([post(100, at: date("2026-11-03T12:00:00Z"))]))]
    }

    private static let sinceLink = Validators(etag: nil, accept: SammyNegotiation.rich, format: .rich, since: sinceURL)

    @Test func theFirstSinceLinksWholeWindowReadIsACatchUp() async throws {
        let before = Validators(etag: nil, accept: SammyNegotiation.rich, format: .rich)
        let page = try await Self.connector(try Self.window()).fetch(Self.request(before), from: rich)
        #expect(page.items.count == 3)
        #expect(page.catchUpFrom == Self.start)
        #expect(try Self.validators(page).catchUpFrom == nil)
        // With nothing stored, every post it brings is new.
        let empty = try await Self.connector(try Self.window()).fetch(Self.request(before, newestStored: nil), from: rich)
        #expect(empty.catchUpFrom == .distantPast)
    }

    @Test func aDroppedSinceLinksWholeWindowReadIsACatchUp() async throws {
        var routes = try Self.window()
        routes[sinceURL] = (410, nil)
        let page = try await Self.connector(routes).fetch(Self.request(Self.sinceLink), from: rich)
        #expect(page.items.count == 3)
        #expect(page.catchUpFrom == Self.start)
        #expect(try Self.validators(page).since == nil)
    }

    /// A server error below the limit keeps the link, and the top read that
    /// stands in for it stops at the first post the source has, as an
    /// ordinary one does: no catch-up.
    @Test func aStandInForAFailedSinceReadIsNoCatchUp() async throws {
        var routes = try Self.window()
        routes[sinceURL] = (502, nil)
        let page = try await Self.connector(routes).fetch(Self.request(Self.sinceLink), from: rich)
        #expect(page.items.count == 2)
        #expect(page.catchUpFrom == nil)
    }

    @Test func aSinceReadIsNoCatchUp() async throws {
        let routes: [String: (status: Int, body: Data?)] = [sinceURL: (200, try page([post(60, at: date("2026-11-03T12:00:00Z"))], since: nextSinceURL))]
        let page = try await Self.connector(routes).fetch(Self.request(Self.sinceLink), from: rich)
        #expect(page.items.count == 1)
        #expect(page.catchUpFrom == nil)
    }

    /// A catch-up cut at the page limit carries on from where it began,
    /// whatever the first part stored.
    @Test func aCatchUpCutAtThePageLimitKeepsItsStart() async throws {
        let count = SammyFeedConnector.maxCatchUpPages + 2
        let url = { (index: Int) in index == 0 ? topURL : "\(RichFixtures.richFeedURL)?before=chain-\(index)" }
        var routes: [String: (status: Int, body: Data?)] = [:]
        for index in 0..<count {
            let at = Self.start.addingTimeInterval(-3600 * Double(index))
            routes[url(index)] = (200, try page([post(200 + index, at: at)], next: index + 1 < count ? url(index + 1) : nil,
                                                since: index == 0 ? sinceURL : nil))
        }
        let connector = try Self.connector(routes)
        let before = Validators(etag: nil, accept: SammyNegotiation.rich, format: .rich)
        let first = try await connector.fetch(Self.request(before), from: rich)
        let cut = try Self.validators(first)
        #expect(cut.resume == url(SammyFeedConnector.maxCatchUpPages) && cut.readsAll == true)
        #expect(first.catchUpFrom == Self.start && cut.catchUpFrom == Self.start)

        var request = RichFixtures.request(rich, cursor: first.newer)
        request.newestStored = date("2026-11-05T00:30:00Z")
        let rest = try await connector.fetch(request, from: rich)
        #expect(rest.items.count == 2)
        #expect(rest.catchUpFrom == Self.start)
        let done = try Self.validators(rest)
        #expect(done.resume == nil && done.catchUpFrom == nil)
    }

    /// A catch-up a build before they were told apart left unfinished says
    /// neither where it began nor that it is a since read's: it is taken as
    /// a read of the whole window, from what the source has now. A since
    /// read's, which says so, keeps every post.
    @Test func anUnfinishedCatchUpFromBeforeIsTakenAsOneOfTheWholeWindow() async throws {
        let routes: [String: (status: Int, body: Data?)] = [secondURL: (200, try page([post(100, at: date("2026-11-03T12:00:00Z"))]))]
        var legacy = Validators(etag: nil, resume: secondURL, accept: SammyNegotiation.rich, format: .rich, since: sinceURL)
        legacy.readsAll = true
        let page = try await Self.connector(routes).fetch(Self.request(legacy), from: rich)
        #expect(page.catchUpFrom == Self.start)

        var since = legacy
        since.readsSince = true
        let sincePage = try await Self.connector(routes).fetch(Self.request(since), from: rich)
        #expect(sincePage.items.count == 1)
        #expect(sincePage.catchUpFrom == nil)
    }
}

/// Build 0.1.0 (9): the same catch-up, without the mark that tells the store
/// it is one.
private struct Build9Connector: Connector {
    let inner: SammyFeedConnector
    func handles(_ source: Source) -> Bool { inner.handles(source) }
    func fetch(_ request: InfluxKit.FetchRequest, from source: Source) async throws -> FetchedPage {
        var page = try await inner.fetch(request, from: source)
        page.catchUpFrom = nil
        return page
    }
}

/// Stores where build 9's catch-up stored a window of older posts as new rows
/// at the bottom: the migration removes those the reader can't have seen.
@Suite struct RepairingCatchUps {
    /// 250 older posts, ten minutes apart from before the stored ones.
    private static var flood: [[String: Any]] {
        (0..<250).map { post(300 + $0, at: date("2026-11-04T19:00:00Z").addingTimeInterval(-600 * Double($0))) }
    }

    /// A caught-up store after build 9's catch-up (three new posts, a
    /// repost that joined its Mastodon copy, and the flood) and an ordinary
    /// since read after it that brought one late post.
    private static func flooded() async throws -> InfluxStore {
        let store = try await caughtUpStore()
        let alias = try #require(LegacyPostIdentity.alias(of: nativeKey))
        let lateRepost = post(50, at: date("2026-11-02T09:30:00Z"), aliases: [alias], repostedBy: "Example Reposter")
        let top = try page(newPosts + storedPosts, next: secondURL, since: sinceURL)
        let second = try page(flood + [lateRepost])
        let catchUp = Build9Connector(inner: try richConnector([topURL: top, secondURL: second]))
        #expect(try await refresh(store, rich, catchUp, at: now.addingTimeInterval(3600)) == 254)
        let late = post(60, at: date("2026-11-03T12:00:00Z"))
        #expect(try await refresh(store, rich, try richConnector([sinceURL: try page([late], since: nextSinceURL)]),
                                  at: now.addingTimeInterval(7200)) == 1)
        try await placeAtTheBottom(60, in: store)
        #expect(try await unread(store).count == 254)
        return store
    }

    /// Puts the post numbered `n` where build 9 put a row that arrived
    /// late: below the newest row in the timeline (ADR 0022). The flood
    /// itself is there already, since the reader had read to the last row.
    private static func placeAtTheBottom(_ n: Int, in store: InfluxStore) async throws {
        try await store.writer.write { db in
            let key = mergeKey(n)
            let newest = try #require(try Date.fetchOne(db, sql: "SELECT MAX(sortDate) FROM timelinePosition WHERE mergeKey <> ?", arguments: [key]))
            try db.execute(sql: "UPDATE timelinePosition SET sortDate = ? WHERE mergeKey = ?", arguments: [newest.addingTimeInterval(0.001), key])
            #expect(db.changesCount == 1)
        }
    }

    private static func repair(_ store: InfluxStore) async throws {
        try await store.writer.write { db in
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = ?", arguments: ["v27: posts a catch-up read added"])
        }
        try Schema.migrator.migrate(store.writer)
    }

    private static func mergeKey(_ n: Int) -> String {
        "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-9000-\(String(format: "%012x", n))"
    }

    @Test func theOlderPostsTheReaderCantHaveSeenGo() async throws {
        let store = try await Self.flooded()
        let before = try await store.rows()
        // The newest of the flood is bookmarked, and iCloud has a removed
        // row's position.
        let bookmarked = Self.mergeKey(300)
        #expect(try await store.toggleOwnBookmark(mergeKey: bookmarked, at: now))
        let removedKey = Self.mergeKey(301)
        try await store.writer.write { db in
            // Offered when it was placed at the bottom, and sent since.
            try db.execute(sql: "UPDATE syncRecord SET pending = NULL, systemFields = x'00' WHERE recordName = ?",
                           arguments: [SyncRecord.name(type: .timelinePosition, key: removedKey)])
            #expect(db.changesCount == 1)
        }

        try await Self.repair(store)

        let after = try await store.rows()
        // Nothing above the reader's place changed, nor the joined row.
        let place = try #require(before.firstIndex { $0.body == "Post 3" })
        #expect(Array(after.prefix(place + 1)) == Array(before.prefix(place + 1)))
        #expect(after.first { $0.mergeKey == nativeKey }?.sourceID == rich.id)
        // What may have been on screen below the place stays: the first
        // rows after it, all from the flood.
        let unread = try await unread(store)
        let kept = Array(before.dropFirst(place + 1).prefix(CatchUpRepair.onScreen))
        #expect(Array(unread.prefix(CatchUpRepair.onScreen)) == kept)
        // After them, only the bookmarked post, the new ones and the late one.
        #expect(unread.dropFirst(CatchUpRepair.onScreen).map(\.mergeKey)
            == [bookmarked, Self.mergeKey(10), Self.mergeKey(11), Self.mergeKey(12), Self.mergeKey(60)])
        #expect(try await store.remoteIDs(sourceID: rich.id).count == 3 + 3 + 1 + CatchUpRepair.onScreen + 1 + 1)
        // The removed row's position goes from iCloud too.
        #expect(!after.contains { $0.mergeKey == removedKey })
        let deleted = try await store.writer.read {
            try Bool.fetchOne($0, sql: "SELECT isDeleted AND pending IS NOT NULL FROM syncRecord WHERE recordName = ?",
                              arguments: [SyncRecord.name(type: .timelinePosition, key: removedKey)])
        }
        #expect(deleted == true)
        #expect(try await store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM timelinePosition") } == after.count)
    }

    /// A view the reader read further in keeps every row up to there, and
    /// a view of other sources doesn't protect the feed's rows.
    @Test func aViewReadFurtherKeepsItsRows() async throws {
        let store = try await Self.flooded()
        let rows = try await store.rows()
        try await store.save(view: SavedView(id: "feed", name: "Feed", sourceIDs: [rich.id], sortIndex: 0))
        try await store.save(view: SavedView(id: "other", name: "Other", sourceIDs: [mastodon.id], sortIndex: 1))
        let end = try #require(rows.last)
        #expect(try await store.moveLastReadMarker(viewID: "feed", to: (end.sortDate, end.mergeKey), at: now))
        try await Self.repair(store)
        #expect(try await store.rows() == rows)
    }

    /// A since read after the catch-up that brought as many late posts is
    /// no catch-up: its posts stay, however many of them there are.
    @Test func aLargeSinceReadAfterTheCatchUpIsKept() async throws {
        let store = try await Self.flooded()
        let backlog = (0..<150).map { post(700 + $0, at: date("2026-11-03T12:00:00Z").addingTimeInterval(-60 * Double($0))) }
        let since = try richConnector([nextSinceURL: try page(backlog, since: "\(RichFixtures.richFeedURL)?since=catch-up-since-3")])
        #expect(try await refresh(store, rich, since, at: now.addingTimeInterval(10_800)) == 150)
        try await Self.repair(store)
        let rows = Set(try await store.rows().map(\.mergeKey))
        #expect(backlog.indices.allSatisfy { rows.contains(Self.mergeKey(700 + $0)) })
        // The catch-up's own flood still went.
        #expect(!rows.contains(Self.mergeKey(301)))
    }

    /// A store that never ran a catch-up loses nothing.
    @Test func aStoreWithoutACatchUpIsUnchanged() async throws {
        let store = try await caughtUpStore()
        let late = post(60, at: date("2026-11-03T12:00:00Z"))
        let top = try page(newPosts + storedPosts + [late])
        #expect(try await refresh(store, rich, try richConnector([topURL: top]), at: now.addingTimeInterval(3600)) == 4)
        let rows = try await store.rows()
        try await Self.repair(store)
        #expect(try await store.rows() == rows)
    }
}
