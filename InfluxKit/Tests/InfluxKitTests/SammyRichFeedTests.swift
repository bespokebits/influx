import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import InfluxKit

/// A Sammy server for the production path, answering from the contract
/// files as the real one does: the rich list and rich pages for a request
/// that names the rich format, article pages for one that names articles,
/// and a 406 otherwise.
private enum Server {
    static let origin = RichFixtures.origin
    static let feeds = "/api/v1/feeds"

    /// The handler. With `ignoringValidators`, a changed page is sent
    /// whatever validator comes; with `articlesForPosts`, the rich feed is
    /// wrongly answered as an article feed.
    static func handler(ignoringValidators: Bool = false, articlesForPosts: Bool = false) throws -> @Sendable (URLRequest) throws -> FakeHTTPClient.Response {
        let metadata = try RichFixtures.data("oauth-authorization-server.json", in: "Fixtures/SammyContract")
        let granted = try RichFixtures.object("token-response.json", in: "Fixtures/SammyContract")
        let token = try JSONSerialization.data(withJSONObject: try #require(granted["body"]))
        let list = try RichFixtures.data("rich-feed-list-oauth.json")
        let first = try RichFixtures.data("rich-feed-page-1.json"), second = try RichFixtures.data("rich-feed-page-2.json")
        let listHeaders = try RichFixtures.headers("list"), pageHeaders = try RichFixtures.headers("page")
        let recorded = try RichFixtures.object("rich-feed-not-modified.json")
        let notModified = try #require((recorded["response"] as? [String: Any])?["headers"] as? [String: String])
        let etag = try #require(pageHeaders["ETag"])
        return { request in
            guard request.url?.host() == "example.com", let path = request.url?.path else { return .init(status: 404) }
            let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
            let wantsRich = accept.contains(SammyNegotiation.rich)
            let wantsArticles = accept.contains(SammyNegotiation.article)
            switch path {
            case "/.well-known/oauth-authorization-server": return .init(body: metadata)
            case "/oauth/token": return .init(body: token)
            case "/oauth/revoke": return .init()
            case feeds:
                return wantsRich ? .init(headers: listHeaders, body: list) : .init(status: 406)
            case "\(feeds)/\(RichFixtures.richFeedID)":
                if articlesForPosts { return .init(headers: RichFixtures.articlePageHeaders, body: articlePage(published: RichFixtures.now)) }
                guard wantsRich else { return .init(status: 406) }
                if request.url?.query() == "before=contract-page-2" { return .init(headers: pageHeaders, body: second) }
                if !ignoringValidators, request.value(forHTTPHeaderField: "If-None-Match") == etag {
                    return .init(status: 304, headers: notModified)
                }
                return .init(headers: pageHeaders, body: first)
            case "\(feeds)/\(RichFixtures.articleFeedID)":
                guard wantsArticles else { return .init(status: 406) }
                return .init(headers: RichFixtures.articlePageHeaders, body: articlePage(published: FeedDate.iso8601("2026-11-01T08:00:00Z")!))
            default:
                return .init(status: 404)
            }
        }
    }

    /// An article feed's page: one article.
    static func articlePage(published: Date) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "version": "https://jsonfeed.org/version/1.1", "title": "Example article feed",
            "items": [[
                "id": "urn:uuid:0193a1b2-0000-7000-8000-00000000a001", "url": "https://www.example.com/articles/1",
                "title": "An article", "summary": "About it.", "date_published": ISO8601DateFormatter().string(from: published),
            ]],
        ])
    }

    /// The contract's approved callback, carrying the state of the sign-in
    /// `authorizeURL` began.
    static func approved(for authorizeURL: URL) throws -> URL {
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        let callback = try RichFixtures.object("callback-approved.json", in: "Fixtures/SammyContract")
        let address = try #require(callback["url"] as? String)
        var components = try #require(URLComponents(string: address))
        components.queryItems = components.queryItems?.map { $0.name == "state" ? URLQueryItem(name: "state", value: state) : $0 }
        return try #require(components.url)
    }
}

extension RichFixtures {
    static func object(_ name: String, in folder: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data(name, in: folder)) as? [String: Any])
    }
}

/// A folder of its own for a store file, under `TMPDIR`.
private struct StoreFolder {
    let url: URL

    init() throws {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        url = base.appendingPathComponent("SammyRichFeedTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var storePath: String { url.appendingPathComponent("influx.sqlite").path }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

/// An account connected the way the app connects one: signed in through
/// the connect flow, every offered feed ticked and saved to the store.
private struct Connected {
    let http: FakeHTTPClient
    let credentials = InMemoryCredentialStore()
    let connector: SammyFeedConnector
    let sources: [Source]

    init(store: InfluxStore, http: FakeHTTPClient) async throws {
        self.http = http
        let signIn = SammySignIn(http: http, crypto: .fake(), credentials: credentials, now: { RichFixtures.now })
        let flow = SammyConnectFlow(connector: signIn, credentials: credentials, sources: store)
        let page = try await flow.begin(server: Server.origin)
        let offer = try await flow.complete(callbackURL: Server.approved(for: page))
        let session = try await flow.save(selected: Set(offer.feeds.map(\.id)))
        let account = try #require(try signIn.account(session.accountID))
        connector = SammyFeedConnector(account: account, http: http, resolver: .testing(http))
        sources = try await store.sources().filter { $0.kind == .sammyFeed }
    }

    var rich: Source { get throws { try #require(sources.first { $0.id.hasSuffix(RichFixtures.richFeedID) }) } }
    var articles: Source { get throws { try #require(sources.first { $0.id.hasSuffix(RichFixtures.articleFeedID) }) } }
}

@Suite struct SammyRichFeedTests {
    private let now = RichFixtures.now

    // MARK: The production path

    @Test func aRichPostKeepsItsRowThroughRefreshesA304AndAReopen() async throws {
        let folder = try StoreFolder()
        defer { folder.remove() }
        let http = FakeHTTPClient(try Server.handler())
        let text = try #require(try RichFixtures.pageOneItems()[0]["text"] as? String)

        let before: [TimelineRow]
        let marker: LastReadMarker?
        let connector: SammyFeedConnector
        let rich: Source
        do {
            let store = try InfluxStore(path: folder.storePath)
            let connected = try await Connected(store: store, http: http)
            connector = connected.connector
            rich = try connected.rich
            // The list said what each feed holds, and the store kept it.
            #expect(connected.sources.map(\.itemKind).sorted { ($0?.rawValue ?? "") < ($1?.rawValue ?? "") } == [.article, .article, .post])
            #expect(try await store.source(id: rich.id)?.itemKind == .post)
            #expect(http.requests.first { $0.url?.path == Server.feeds }?.value(forHTTPHeaderField: "Accept") == SammyNegotiation.either)

            let refresher = Refresher(store: store)
            #expect(try await refresher.refresh(rich, with: connector, now: now) == .fetched(newItems: 2))
            let rows = try await store.rows(in: .sources([rich.id]))
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.kind == .post && $0.title == nil && $0.media.isEmpty && $0.viewer == Item.Viewer() })
            let long = try #require(rows.first { $0.mergeKey == "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-000000000002" })
            #expect(long.body.hasPrefix(text) && long.body.count > 400)
            #expect(long.links.map(\.url) == ["https://www.example.com/read/one", "https://www.example.com/read/two"])
            #expect(long.authorName == "Example Author")
            #expect(long.url == "https://www.example.com/author/posts/2")
            #expect(try await store.item(id: long.id)?.remoteID == "urn:uuid:70ad2d4e-b17f-8d6d-84e0-14a6d944d82b")
            // Two posts that share a URL are two rows.
            #expect(Set(rows.map(\.url)) == ["https://www.example.com/author/posts/2"])
            #expect(Set(rows.map(\.mergeKey)).count == 2)
            let last = try #require(rows.last)
            #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (last.sortDate, last.mergeKey), at: now))

            // The page again, sent whole: nothing new, nothing moved.
            http.respond(try Server.handler(ignoringValidators: true))
            #expect(try await refresher.refresh(rich, with: connector, now: now.addingTimeInterval(60)) == .fetched(newItems: 0))
            #expect(try await store.rows(in: .sources([rich.id])) == rows)
            // Unchanged: a 304, on the recorded request.
            http.respond(try Server.handler())
            #expect(try await refresher.refresh(rich, with: connector, now: now.addingTimeInterval(120)) == .fetched(newItems: 0))
            let conditional = try #require(http.requests.last)
            #expect(conditional.value(forHTTPHeaderField: "If-None-Match") != nil)
            #expect(conditional.value(forHTTPHeaderField: "Accept") == SammyNegotiation.rich)
            #expect(try await store.rows(in: .sources([rich.id])) == rows)
            before = try await store.rows()
            marker = try await store.lastReadMarker(viewID: SavedView.allID)
        }

        // The store opened again: the same rows, IDs and marker, and its
        // cursor still earns a 304.
        let reopened = try InfluxStore(path: folder.storePath)
        #expect(try await reopened.rows() == before)
        #expect(try await reopened.lastReadMarker(viewID: SavedView.allID) == marker)
        #expect(try await reopened.source(id: rich.id)?.itemKind == .post)
        let sent = http.requests.count
        #expect(try await Refresher(store: reopened).refresh(rich, with: connector, now: now.addingTimeInterval(180)) == .fetched(newItems: 0))
        #expect(http.requests.count == sent + 1)
        #expect(try await reopened.rows() == before)
    }

    @Test func postsAreKeptSevenDaysAtFetchAndPruneAndArticlesThirty() async throws {
        let folder = try StoreFolder()
        defer { folder.remove() }
        let store = try InfluxStore(path: folder.storePath)
        let connected = try await Connected(store: store, http: FakeHTTPClient(try Server.handler()))
        let rich = try connected.rich
        let refresher = Refresher(store: store)
        #expect(try await refresher.refresh(rich, with: connected.connector, now: now) == .fetched(newItems: 2))
        #expect(try await refresher.refresh(rich, with: connected.connector, direction: .older, now: now) == .fetched(newItems: 1))
        // An RSS article as old as page 2's post.
        let feed = Source(id: "rss:https://www.example.com/feed.xml", kind: .rss, title: "Example", url: "https://www.example.com/feed.xml", colorIndex: 1)
        try await store.save(sources: [feed])
        let published = try #require(FeedDate.iso8601("2026-11-01T08:00:00Z"))
        try await store.insert([Item(sourceID: feed.id, remoteID: "a1", kind: .article, mergeKey: "https://www.example.com/articles/a1",
                                     authorName: "Example", authorHandle: "example.com", title: "An article", body: "", publishedAt: published, fetchedAt: now)])

        // Seven days and four hours after page 2's post.
        let later = try #require(FeedDate.iso8601("2026-11-08T12:00:00Z"))
        #expect(try await store.prune(now: later) == 1)
        let rows = try await store.rows()
        #expect(rows.filter { $0.sourceID == rich.id }.map(\.publishedAt) == [FeedDate.iso8601("2026-11-02T09:30:00Z")!, FeedDate.iso8601("2026-11-02T09:30:00Z")!])
        #expect(rows.filter { $0.sourceID == feed.id }.count == 1)

        // Fetched that late, the post is never stored at all.
        let fresh = try InfluxStore.inMemory()
        try await fresh.save(sources: [rich])
        let late = Refresher(store: fresh)
        #expect(Refresher.request(for: rich, direction: .newer, cursor: nil, now: later).notBefore == later.addingTimeInterval(-InfluxStore.postRetention))
        #expect(try await late.refresh(rich, with: connected.connector, now: later) == .fetched(newItems: 2))
        #expect(try await late.refresh(rich, with: connected.connector, direction: .older, now: later) == .fetched(newItems: 0))
        #expect(Refresher.request(for: feed, direction: .newer, cursor: nil, now: later).notBefore == later.addingTimeInterval(-InfluxStore.articleRetention))
    }

    @Test func aFeedWithNoClassificationStillReadsRichAndKeepsPostsAWeek() async throws {
        let folder = try StoreFolder()
        defer { folder.remove() }
        let store = try InfluxStore(path: folder.storePath)
        let connected = try await Connected(store: store, http: FakeHTTPClient(try Server.handler()))
        // As a build from before, or one that lost the field, saved it.
        var unknown = try connected.rich
        unknown.itemKind = nil
        try await store.save(sources: [unknown])
        let refresher = Refresher(store: store)
        #expect(try await refresher.refresh(unknown, with: connected.connector, now: now) == .fetched(newItems: 2))
        #expect(connected.http.requests.last?.value(forHTTPHeaderField: "Accept") == SammyNegotiation.either)
        #expect(try await store.rows(in: .sources([unknown.id])).allSatisfy { $0.kind == .post })

        // Fetched for the article window, its posts still go after a week.
        let other = try InfluxStore.inMemory()
        try await other.save(sources: [unknown])
        let tenDaysOn = try #require(FeedDate.iso8601("2026-11-10T00:00:00Z"))
        #expect(Refresher.request(for: unknown, direction: .newer, cursor: nil, now: tenDaysOn).notBefore == tenDaysOn.addingTimeInterval(-InfluxStore.articleRetention))
        #expect(try await Refresher(store: other).refresh(unknown, with: connected.connector, now: tenDaysOn) == .fetched(newItems: 0))
        #expect(try await other.rows().isEmpty)
    }

    @Test func aFeedListedAsPostsAnsweredAsAnArticleIsRefused() async throws {
        let folder = try StoreFolder()
        defer { folder.remove() }
        let store = try InfluxStore(path: folder.storePath)
        let connected = try await Connected(store: store, http: FakeHTTPClient(try Server.handler()))
        connected.http.respond(try Server.handler(articlesForPosts: true))
        let outcome = try await Refresher(store: store).refresh(try connected.rich, with: connected.connector, now: now)
        #expect(outcome == .failed(.badResponse("a rich feed answered as an article feed")))
        #expect(try await store.rows().isEmpty)
        #expect(try await store.fetchState(sourceID: try connected.rich.id)?.problem == .badResponse)
    }

    @Test func articleFeedsStillReadAsArticles() async throws {
        let folder = try StoreFolder()
        defer { folder.remove() }
        let store = try InfluxStore(path: folder.storePath)
        let connected = try await Connected(store: store, http: FakeHTTPClient(try Server.handler()))
        let articles = try connected.articles
        #expect(articles.itemKind == .article)
        #expect(try await Refresher(store: store).refresh(articles, with: connected.connector, now: now) == .fetched(newItems: 1))
        #expect(connected.http.requests.last?.value(forHTTPHeaderField: "Accept") == SammyNegotiation.either)
        let row = try #require(try await store.rows(in: .sources([articles.id])).first)
        #expect(row.kind == .article)
        #expect(row.title == "An article")
        #expect(row.mergeKey == "urn:uuid:0193a1b2-0000-7000-8000-00000000a001")
        let validators = try #require(try await store.fetchState(sourceID: articles.id)?.newerCursor.flatMap(SammyFeedConnector.Validators.init(cursor:)))
        #expect(validators.format == .article && validators.accept == SammyNegotiation.either)
    }

    // MARK: The reserved merge keys

    @Test func anRSSItemWithARichPostsIDDoesNotTakeItsRow() async throws {
        let store = try InfluxStore.inMemory()
        let feed = Source(id: "rss:https://www.example.com/feed.xml", kind: .rss, title: "Example", url: "https://www.example.com/feed.xml", colorIndex: 1)
        let rich = RichFixtures.source(.post)
        try await store.save(sources: [feed, rich])
        // Its GUID is the rich post's canonical ID, and its link the post's.
        let guid = "urn:uuid:0193a1b2-0000-7000-8000-000000000002"
        let key = ArticleMapper.mergeKey(id: guid, url: URL(string: "https://www.example.com/author/posts/2"), source: feed, remoteID: guid)
        try await store.insert([Item(sourceID: feed.id, remoteID: guid, kind: .article, mergeKey: key, authorName: "Example", authorHandle: "example.com",
                                     title: "Copied", body: "", url: "https://www.example.com/author/posts/2", publishedAt: now, fetchedAt: now)])
        let fetched = try await RichFixtures.connector(try RichFixtures.pages()).fetch(RichFixtures.request(rich), from: rich)
        try await store.insert(fetched.items)
        let rows = try await store.rows()
        #expect(rows.count == 3)
        let post = try #require(rows.first { $0.mergeKey == "sammy-post:example.com:\(guid)" })
        #expect(post.sourceID == rich.id && post.kind == .post)
    }

    @Test func aRichPostKeyStandsOnlyOnItsOwnServersFeeds() async throws {
        let store = try InfluxStore.inMemory()
        let key = "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-000000000002"
        let rich = RichFixtures.source(.post)
        let mastodon = MastodonMapper.homeSource(accountID: "@reader@social.example.com", colorIndex: 2)
        let feed = Source(id: "rss:https://www.example.com/feed.xml", kind: .rss, title: "Example", colorIndex: 1)
        let otherServer = Source(id: SammyFeedConnector.sourceID(accountID: "s1@other.example.com", feedID: "f1"), kind: .sammyFeed,
                                 accountID: "s1@other.example.com", title: "Elsewhere", colorIndex: 3, itemKind: .post)
        let sameServer = Source(id: SammyFeedConnector.sourceID(accountID: "s2@example.com", feedID: "f1"), kind: .sammyFeed,
                                accountID: "s2@example.com", title: "Another account", colorIndex: 4, itemKind: .post)
        try await store.save(sources: [rich, mastodon, feed, otherServer, sameServer])
        func item(_ source: Source, _ remoteID: String, key: String) -> Item {
            Item(sourceID: source.id, remoteID: remoteID, kind: .post, mergeKey: key, authorName: "A", authorHandle: "a", body: remoteID,
                 publishedAt: now, fetchedAt: now)
        }
        // A Mastodon server can send any URI, which the mapper keeps.
        #expect(MastodonMapper.mergeKey(uri: key) == key)
        try await store.insert([
            item(rich, "urn:uuid:70ad2d4e-b17f-8d6d-84e0-14a6d944d82b", key: key),
            item(mastodon, "m1", key: key),
            item(feed, "r1", key: key),
            item(otherServer, "o1", key: key),
            item(rich, "bad", key: "sammy-post:example.com:urn:uuid:NOT-A-UUID"),
            item(sameServer, "s1", key: key),
        ])
        let stored = try await store.writer.read { db in try Item.fetchAll(db) }
        let keys = Dictionary(uniqueKeysWithValues: stored.map { ($0.remoteID, $0.mergeKey) })
        #expect(keys["urn:uuid:70ad2d4e-b17f-8d6d-84e0-14a6d944d82b"] == key)
        #expect(keys["m1"] == "\(mastodon.id)#m1")
        #expect(keys["r1"] == "\(feed.id)#r1")
        #expect(keys["o1"] == "\(otherServer.id)#o1")
        #expect(keys["bad"] == "\(rich.id)#bad")
        // Another account on the same server names the same post.
        #expect(keys["s1"] == key)
        #expect(try await store.rows().count == 5)
        // Stored, a copy keeps its key.
        try await store.insert([item(mastodon, "m1", key: key)])
        #expect(try await store.writer.read { db in try String.fetchOne(db, sql: "SELECT mergeKey FROM item WHERE remoteID = 'm1'") } == "\(mastodon.id)#m1")
    }

    @Test func noRSSItemIsGivenARichPostKey() {
        let feed = Source(id: "rss:https://www.example.com/feed.xml", kind: .rss, title: "Example", colorIndex: 1)
        for id in ["sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-000000000002", "SAMMY-POST:example.com:x", "sammy-post://example.com/x"] {
            let key = ArticleMapper.mergeKey(id: id, url: nil, source: feed, remoteID: id)
            #expect(!key.hasPrefix(SammyPostKey.prefix), "\(id)")
        }
        let link = ArticleMapper.resolve("sammy-post:example.com:x", against: URL(string: "https://www.example.com/feed.xml"))
        #expect(link.map { ArticleMapper.mergeKey(id: nil, url: $0, source: feed, remoteID: "x").hasPrefix(SammyPostKey.prefix) } != true)
    }

    // MARK: Sync

    @Test func theItemKindSyncsWithoutANewPayloadVersion() async throws {
        let sender = try InfluxStore.inMemory()
        let rich = RichFixtures.source(.post)
        try await sender.save(sources: [rich], at: now)
        let outgoing = try #require(try await sender.syncRecordToSend(named: SyncRecord.name(type: .source, key: rich.id)))
        let payload = try #require(try JSONSerialization.jsonObject(with: outgoing.record.payload) as? [String: Any])
        #expect((payload["source"] as? [String: Any])?["itemKind"] as? String == "post")
        #expect(SyncCoding.version(of: outgoing.record.payload) == 1)
        #expect(SyncRecordType.source.payloadVersion == 1)

        let receiver = try InfluxStore.inMemory()
        _ = try await receiver.mergeSyncRecords([FetchedSyncRecord(record: outgoing.record, systemFields: Data("fields".utf8))], at: now)
        #expect(try await receiver.source(id: rich.id) == rich)
    }

    @Test func aPayloadWithoutTheItemKindOrWithAnUnknownOneMergesAsUnknown() async throws {
        for itemKind in [nil, "thread"] as [String?] {
            var fields: [String: Any] = [
                "id": RichFixtures.source(nil).id, "kind": "sammyFeed", "accountID": RichFixtures.accountID, "title": "Authored posts",
                "url": RichFixtures.richFeedURL, "colorIndex": 2,
            ]
            if let itemKind { fields["itemKind"] = itemKind }
            let data = try JSONSerialization.data(withJSONObject: ["source": fields, "modifiedAt": now.timeIntervalSinceReferenceDate])
            let record = FetchedSyncRecord(record: SyncRecord(type: .source, key: RichFixtures.source(nil).id, payload: data), systemFields: Data("fields".utf8))
            let store = try InfluxStore.inMemory()
            let result = try await store.mergeSyncRecords([record], at: now)
            #expect(result.unread == 0)
            let source = try #require(try await store.source(id: RichFixtures.source(nil).id), "\(itemKind ?? "none")")
            #expect(source.itemKind == nil)
        }
    }

    @Test func aSourceSavedWithoutItsKindLosesIt() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [RichFixtures.source(.post)])
        try await store.save(sources: [RichFixtures.source(nil)])
        #expect(try await store.source(id: RichFixtures.source(nil).id)?.itemKind == nil)
    }
}

/// A store from before rich posts may hold `sammy-post:` keys that a
/// Mastodon or Bluesky server sent as a post's URI; the migration that
/// reserves the namespace gives them back to their sources, where they keep
/// their places.
@Suite struct MigratingClaimedRichKeys {
    @Test func keysClaimedBeforeTheReservationGoBackToTheirSources() throws {
        let db = try DatabaseQueue()
        try Schema.migrator.migrate(db, upTo: "v22: unread sync records")
        let claimed = "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-000000000002"
        let genuine = "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-000000000003"
        try db.write { db in
            try db.execute(sql: "INSERT INTO source (id, kind, title, colorIndex) VALUES ('m', 'mastodonHome', 'M', 0)")
            for (id, key) in [("1", claimed), ("2", "https://social.example/statuses/2")] {
                try db.execute(sql: """
                    INSERT INTO item (sourceID, remoteID, kind, mergeKey, authorName, authorHandle, body, publishedAt, fetchedAt, sortDate)
                    VALUES ('m', ?, 'post', ?, 'A', '@a', 'b', '2026-11-01 00:00:00.000', '2026-11-01 00:00:00.000', '2026-11-01 00:00:00.000')
                    """, arguments: [id, key])
                try db.execute(sql: "INSERT INTO timelinePosition (mergeKey, sortDate) VALUES (?, '2026-11-01 00:00:00.000')", arguments: [key])
                try db.execute(sql: "INSERT INTO pendingTimelinePosition (mergeKey, sortDate, receivedAt) VALUES (?, '2026-11-01 00:00:00.000', '2026-11-01 00:00:00.000')", arguments: [key])
            }
            // A genuine rich post's position, synced from a device already
            // upgraded, waits here for its post: no item here claims it.
            try db.execute(sql: "INSERT INTO pendingTimelinePosition (mergeKey, sortDate, receivedAt) VALUES (?, '2026-11-02 00:00:00.000', '2026-11-02 00:00:00.000')",
                           arguments: [genuine])
            try db.execute(sql: "INSERT INTO syncRecord (recordName, type, key, modifiedAt) VALUES (?, 'TimelinePosition', ?, '2026-11-02 00:00:00.000')",
                           arguments: [SyncRecord.name(type: .timelinePosition, key: genuine), genuine])
            // iCloud already has the claim's position.
            try db.execute(sql: "INSERT INTO syncRecord (recordName, type, key, modifiedAt) VALUES (?, 'TimelinePosition', ?, '2026-11-01 00:00:00.000')",
                           arguments: [SyncRecord.name(type: .timelinePosition, key: claimed), claimed])
        }
        try Schema.migrator.migrate(db)
        // Its deletion goes up, and the moved position is offered under the
        // new key.
        let deleted = try db.read {
            try Row.fetchOne($0, sql: "SELECT isDeleted, pending FROM syncRecord WHERE recordName = ?",
                             arguments: [SyncRecord.name(type: .timelinePosition, key: claimed)])
        }
        #expect(deleted?["isDeleted"] as Bool? == true)
        #expect(deleted?["pending"] as Int64? != nil)
        let offered = try db.read {
            try Int64.fetchOne($0, sql: "SELECT pending FROM syncRecord WHERE recordName = ?",
                               arguments: [SyncRecord.name(type: .timelinePosition, key: "m#1")])
        }
        #expect(offered != nil)
        let keys = try db.read { try String.fetchAll($0, sql: "SELECT mergeKey FROM item ORDER BY remoteID") }
        #expect(keys == ["m#1", "https://social.example/statuses/2"])
        // The claim's row keeps its place under its new key; nothing is
        // left under the reserved one.
        let positions = try db.read {
            try Row.fetchAll($0, sql: "SELECT mergeKey, sortDate, itemID FROM timelinePosition ORDER BY mergeKey")
                .map { [$0["mergeKey"] as String, $0["sortDate"] as String, String($0["itemID"] as Int64? ?? -1)] }
        }
        let ids = try db.read { try Int64.fetchAll($0, sql: "SELECT id FROM item ORDER BY remoteID") }
        #expect(positions == [
            ["https://social.example/statuses/2", "2026-11-01 00:00:00.000", "-1"],
            ["m#1", "2026-11-01 00:00:00.000", String(ids[0])],
        ])
        let pending = try db.read { try String.fetchAll($0, sql: "SELECT mergeKey FROM pendingTimelinePosition ORDER BY mergeKey") }
        #expect(pending == ["https://social.example/statuses/2", genuine])
        let untouched = try db.read {
            try Row.fetchOne($0, sql: "SELECT isDeleted, pending FROM syncRecord WHERE recordName = ?",
                             arguments: [SyncRecord.name(type: .timelinePosition, key: genuine)])
        }
        #expect(untouched?["isDeleted"] as Bool? == false)
        #expect(untouched?["pending"] as Int64? == nil)
    }
}
