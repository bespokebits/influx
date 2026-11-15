import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

private let instance = URL(string: "https://example.social")!
private let fetchedAt = Date(timeIntervalSince1970: 1_793_000_000)
private let home = MastodonMapper.homeSource(accountID: "@me@example.social", colorIndex: 1)
private let friends = MastodonMapper.listSource(Mastodon.List(id: "12", title: "Friends"), accountID: "@me@example.social", colorIndex: 2)

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/mastodon"))
    return try Data(contentsOf: url)
}

private func statuses(_ name: String) throws -> [Mastodon.Status] {
    try Mastodon.decoder().decode([Mastodon.Status].self, from: fixture(name))
}

private func homeItems() throws -> [Item] {
    MastodonMapper.items(from: try statuses("home-timeline"), source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt)
}

/// Answers each request by its path, and anything else with a 404.
private func replay(_ routes: [String: FakeHTTPClient.Response]) -> FakeHTTPClient {
    FakeHTTPClient { request in
        routes[request.url!.path()] ?? FakeHTTPClient.Response(status: 404)
    }
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

private func form(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

@Suite struct MastodonMapping {
    @Test func plainStatusBecomesAPost() throws {
        let item = try #require(try homeItems().first)
        #expect(item.kind == .post)
        #expect(item.sourceID == home.id)
        #expect(item.remoteID == "113400000000000005")
        #expect(item.mergeKey == "https://example.social/users/ana/statuses/113400000000000005")
        #expect(item.authorName == "Ana Ruiz")
        // A local account's handle gains its instance.
        #expect(item.authorHandle == "@ana@example.social")
        #expect(item.url == "https://example.social/@ana/113400000000000005")
        #expect(item.publishedAt == Date(timeIntervalSince1970: 1_792_803_600))
        #expect(item.sortDate == item.publishedAt)
        #expect(item.fetchedAt == fetchedAt)
        #expect(item.boostedBy == nil)
        #expect(item.replyToHandle == nil)
        #expect(item.actionRef == "113400000000000005")
    }

    @Test func htmlBecomesPlainText() throws {
        let item = try #require(try homeItems().first)
        #expect(item.body == """
            Reading @cy's notes on #RSS & ActivityPub: example.com/a/very/long/pa…

            Second paragraph
            with a break.
            """)
    }

    @Test func boostShowsTheBoostedPostAtTheBoostsDate() throws {
        let item = try homeItems()[1]
        #expect(item.remoteID == "113400000000000004")
        #expect(item.mergeKey == "https://other.example/users/bo/statuses/4400")
        // An empty display name falls back to the username.
        #expect(item.authorName == "bo")
        #expect(item.authorHandle == "@bo@other.example")
        #expect(item.boostedBy == "Ana Ruiz")
        #expect(item.publishedAt == Date(timeIntervalSince1970: 1_792_793_730))
        #expect(item.sortDate == Date(timeIntervalSince1970: 1_792_803_540))
        #expect(item.body == "A photo from the hills.")
        #expect(item.media == [Item.Media(kind: .image, url: "https://files.example.social/cache/media/7.jpg", width: 1600, height: 1200, altText: "Hills at dusk")!])
        // Actions go to the boosted status, not the boost.
        #expect(item.actionRef == "113399999000000001")
    }

    @Test func replyNamesTheMentionedAccountAndKeepsTheContentWarning() throws {
        let item = try homeItems()[2]
        #expect(item.replyToHandle == "@ana@example.social")
        #expect(item.authorHandle == "@cy@far.example")
        #expect(item.body == "Film ending\n\nSpoilers below")
        // Fractional seconds survive.
        #expect(abs(item.publishedAt.timeIntervalSince1970 - 1_792_803_480.123) < 0.0005)
    }

    @Test func replyToSelfNamesTheAuthor() throws {
        let item = try homeItems()[3]
        #expect(item.replyToHandle == "@ana@example.social")
    }

    @Test func cardWithoutProviderUsesTheHost() throws {
        let item = try homeItems()[4]
        let image = Item.Media(kind: .image, url: "https://files.example.social/cache/preview_cards/images/1.jpg", width: 400, height: 200)
        #expect(item.linkCard == Item.LinkCard(url: "https://news.example.org/story", site: "news.example.org", title: "A story worth reading", summary: "…", image: image))
        #expect(item.media.isEmpty)
        // Dates without fractional seconds decode too.
        #expect(item.publishedAt == Date(timeIntervalSince1970: 1_792_803_360))
    }

    @Test func statusesHiddenByServerFiltersAreDropped() throws {
        let items = try homeItems()
        #expect(items.count == 6)
        #expect(!items.contains { $0.body == "Something I filtered" })
    }

    @Test func mediaWithoutSizeIsLeftForTheResolver() throws {
        let item = try #require(try homeItems().last)
        #expect(item.media.isEmpty)
        let status = try #require(try statuses("home-timeline").last)
        #expect(MastodonMapper.unsizedMedia(status) == [UnsizedMedia(
            kind: .video, url: "https://files.example.social/cache/media/8.mp4",
            previewURL: "https://files.example.social/cache/media/8.png", width: nil, height: nil, altText: nil
        )])
    }

    @Test func cardLinkSkipsMentionsAndHashtags() throws {
        let first = try #require(try statuses("home-timeline").first)
        #expect(MastodonMapper.cardLink(first) == "https://www.example.com/a/very/long/path/to/an/article")
    }

    @Test func sameBoostFromTwoSourcesIsOneRow() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [home, friends])
        try await store.insert(try homeItems())
        let list = MastodonMapper.items(from: try statuses("list-timeline"), source: friends.id, instanceHost: "example.social", fetchedAt: fetchedAt.addingTimeInterval(60))
        #expect(try await store.insert(list) == 1)

        let rows = try await store.rows()
        #expect(rows.count == 6)
        let photo = try #require(rows.first { $0.mergeKey == "https://other.example/users/bo/statuses/4400" })
        #expect(photo.boostedBy == ["Ana Ruiz", "Cy :blobcat:"])
        // The row stays where the first copy put it.
        #expect(photo.sourceID == home.id)
        #expect(photo.sortDate == Date(timeIntervalSince1970: 1_792_803_540))
    }

    @Test func storedItemKeepsItsActionRef() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [home])
        try await store.insert(try homeItems())
        let rows = try await store.rows()
        let photo = try #require(rows.first { $0.boostedBy == ["Ana Ruiz"] })
        let reference = try #require(try await store.itemReference(id: photo.id))
        #expect(reference == ItemReference(sourceID: home.id, remoteID: "113400000000000004", actionRef: "113399999000000001", viewer: Item.Viewer()))
        // Rows are oldest first; the newest post is the plain one.
        #expect(rows.last?.body.hasPrefix("Reading @cy") == true)
    }

    @Test func handlesAndSources() {
        let me = Mastodon.Account(id: "1", acct: "me", username: "me", displayName: "Me", url: nil)
        #expect(MastodonMapper.accountID(for: me, on: instance) == "@me@example.social")
        #expect(home.id == "mastodon:@me@example.social:home")
        #expect(home.kind == .mastodonHome)
        #expect(friends.id == "mastodon:@me@example.social:list:12")
        #expect(friends.title == "Friends")
        #expect(MastodonMapper.fullAcct("bo@other.example", instanceHost: "example.social") == "bo@other.example")
    }
}

@Suite struct MastodonText {
    @Test(arguments: [
        ("<p>a &lt;b&gt; &quot;c&quot; &#x1F600; &#8212; d&nbsp;e</p>", "a <b> \"c\" 😀 — d\u{A0}e"),
        ("<p>one</p><p>two</p><p>three</p>", "one\n\ntwo\n\nthree"),
        ("<p>line<br>break<br/>again</p>", "line\nbreak\nagain"),
        ("plain &unknown; text & more", "plain &unknown; text & more"),
        ("<p></p>", ""),
    ])
    func decodes(html: String, text: String) {
        #expect(MastodonHTML.text(html) == text)
    }
}

@Suite struct MastodonOAuthRequests {
    let oauth = MastodonOAuth(instance: instance, redirectURI: "dev.bespokebits.influx://oauth/mastodon")

    @Test(arguments: [
        ("mastodon.social", "https://mastodon.social"),
        ("  Mastodon.Social \n", "https://mastodon.social"),
        ("@me@mastodon.social", "https://mastodon.social"),
        ("me@mastodon.social", "https://mastodon.social"),
        ("https://mastodon.social/@me", "https://mastodon.social"),
        ("https://hachyderm.io/", "https://hachyderm.io"),
    ])
    func instanceFromInput(input: String, expected: String) {
        #expect(MastodonOAuth.instanceURL(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "localhost", "http://mastodon.social", "@me", "not a host"])
    func rejectsInput(input: String) {
        #expect(MastodonOAuth.instanceURL(from: input) == nil)
    }

    @Test func registersTheApp() {
        let request = oauth.registerAppRequest()
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://example.social/api/v1/apps")
        #expect(form(request) == [
            "client_name": "Influx",
            "redirect_uris": "dev.bespokebits.influx://oauth/mastodon",
            "scopes": "read write:favourites write:statuses write:bookmarks",
            "website": "https://bespokebits.dev",
        ])
    }

    @Test func authorizeURLCarriesPKCEAndState() throws {
        let url = oauth.authorizeURL(clientID: "client id+1", state: "s&t", codeChallenge: "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(url.path() == "/oauth/authorize")
        #expect(url.query()?.contains("client_id=client%20id%2B1") == true)
        let request = URLRequest(url: url)
        #expect(query(request) == [
            "response_type": "code",
            "client_id": "client id+1",
            "redirect_uri": "dev.bespokebits.influx://oauth/mastodon",
            "scope": "read write:favourites write:statuses write:bookmarks",
            "state": "s&t",
            "code_challenge": "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
            "code_challenge_method": "S256",
        ])
    }

    @Test func readsTheCallback() throws {
        let ok = URL(string: "dev.bespokebits.influx://oauth/mastodon?code=abc123&state=xyz")!
        #expect(try oauth.code(fromCallback: ok, expectedState: "xyz") == "abc123")
        #expect(throws: MastodonOAuth.CallbackError.stateMismatch) {
            try oauth.code(fromCallback: ok, expectedState: "other")
        }
        let denied = URL(string: "dev.bespokebits.influx://oauth/mastodon?error=access_denied&error_description=The%20user%20said%20no&state=xyz")!
        #expect(throws: MastodonOAuth.CallbackError.denied("The user said no")) {
            try oauth.code(fromCallback: denied, expectedState: "xyz")
        }
        let empty = URL(string: "dev.bespokebits.influx://oauth/mastodon?state=xyz")!
        #expect(throws: MastodonOAuth.CallbackError.missingCode) {
            try oauth.code(fromCallback: empty, expectedState: "xyz")
        }
    }

    @Test func tradesTheCodeForAToken() throws {
        let app = try Mastodon.decoder().decode(Mastodon.Application.self, from: fixture("app"))
        let request = oauth.tokenRequest(app: app, code: "abc123", codeVerifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(request.url?.absoluteString == "https://example.social/oauth/token")
        #expect(form(request) == [
            "grant_type": "authorization_code",
            "code": "abc123",
            "client_id": "fixture-client-id",
            "client_secret": "fixture-client-secret",
            "redirect_uri": "dev.bespokebits.influx://oauth/mastodon",
            "code_verifier": "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk",
            "scope": "read write:favourites write:statuses write:bookmarks",
        ])
        let token = try Mastodon.decoder().decode(Mastodon.Token.self, from: fixture("token"))
        #expect(token.accessToken == "fixture-access-token")

        let revoke = oauth.revokeRequest(app: app, accessToken: token.accessToken)
        #expect(revoke.url?.path() == "/oauth/revoke")
        #expect(form(revoke)["token"] == "fixture-access-token")
    }
}

private let homeLink = #"<https://example.social/api/v1/timelines/home?limit=40&max_id=113399999999999999>; rel="next", <https://example.social/api/v1/timelines/home?limit=40&min_id=113400000000000005>; rel="prev""#

@Suite struct MastodonTimelines {
    @Test func homePageReadsCursorsAndRateLimit() async throws {
        let replay = replay([
            "/api/v1/timelines/home": .init(headers: [
                "Link": homeLink,
                "X-RateLimit-Limit": "300",
                "X-RateLimit-Remaining": "297",
                "X-RateLimit-Reset": "2026-10-24T02:00:00.000Z",
            ], body: try fixture("home-timeline")),
        ])
        let client = MastodonClient(instance: instance, accessToken: "fixture-access-token", http: replay)
        let page = try await client.homeTimeline()
        #expect(page.statuses.count == 7)
        #expect(page.older == .before("113399999999999999"))
        #expect(page.newer == .after("113400000000000005"))
        #expect(page.rateLimit == .init(limit: 300, remaining: 297, resetsAt: Date(timeIntervalSince1970: 1_792_807_200)))

        let request = try #require(replay.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access-token")
        #expect(query(request) == ["limit": "40"])
    }

    @Test func pagesAskForTheRightSide() async throws {
        let replay = replay(["/api/v1/timelines/list/12": .init(text: "[]")])
        let client = MastodonClient(instance: instance, accessToken: "t", http: replay)
        let newer = try await client.listTimeline(listID: "12", .after("100"))
        _ = try await client.listTimeline(listID: "12", .before("90"))
        #expect(replay.requests.map(query) == [["limit": "40", "min_id": "100"], ["limit": "40", "max_id": "90"]])
        // An empty page has nothing older.
        #expect(newer.statuses.isEmpty)
        #expect(newer.older == nil)
    }

    @Test func accountAndLists() async throws {
        let replay = replay([
            "/api/v1/accounts/verify_credentials": .init(body: try fixture("verify-credentials")),
            "/api/v1/lists": .init(body: try fixture("lists")),
        ])
        let client = MastodonClient(instance: instance, accessToken: "t", http: replay)
        let account = try await client.verifyCredentials()
        #expect(MastodonMapper.accountID(for: account, on: instance) == "@me@example.social")
        #expect(try await client.lists().map(\.title) == ["Friends", "News & such"])
    }

    @Test(arguments: [
        (401, [:], ConnectorError.unauthorized),
        (404, [:], ConnectorError.notFound),
        // Mastodon says when its window resets in its own header.
        (429, ["X-RateLimit-Limit": "300", "X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2026-10-24T02:00:00Z"], ConnectorError.rateLimited(retryAfter: Date(timeIntervalSince1970: 1_792_807_200))),
        (429, [:], ConnectorError.rateLimited(retryAfter: nil)),
        (500, [:], ConnectorError.badResponse("HTTP 500")),
    ] as [(Int, [String: String], ConnectorError)])
    func errorsBecomeQuietStates(status: Int, headers: [String: String], expected: ConnectorError) async {
        let replay = replay(["/api/v1/timelines/home": .init(status: status, headers: headers, text: #"{"error":"Nope"}"#)])
        let client = MastodonClient(instance: instance, accessToken: "t", http: replay)
        await #expect(throws: expected) {
            try await client.homeTimeline()
        }
    }

    @Test func unreachableInstanceIsOffline() async {
        let client = MastodonClient(instance: instance, accessToken: "t", http: FakeHTTPClient { _ in throw URLError(.notConnectedToInternet) })
        await #expect(throws: ConnectorError.offline) {
            try await client.homeTimeline()
        }
    }

    @Test func unexpectedJSONIsABadResponse() async {
        let replay = replay(["/api/v1/lists": .init(text: #"{"not":"a list"}"#)])
        let client = MastodonClient(instance: instance, accessToken: "t", http: replay)
        await #expect {
            try await client.lists()
        } throws: { error in
            if case .badResponse = error as? ConnectorError { true } else { false }
        }
    }
}

@Suite struct MastodonConnectorTests {
    private let account = "@me@example.social"

    private func connector(_ http: FakeHTTPClient) -> MastodonConnector {
        MastodonConnector(accountID: account, instance: instance, accessToken: "t", colorIndex: 4, http: http, resolver: .testing(http))
    }

    private func request(_ direction: FetchDirection, _ cursor: String?, notBefore: Date = fetchedAt.addingTimeInterval(-InfluxStore.postRetention)) -> FetchRequest {
        FetchRequest(direction: direction, cursor: cursor.map(Cursor.init), notBefore: notBefore, now: fetchedAt)
    }

    @Test func offersHomeAndLists() async throws {
        let sources = try await connector(replay(["/api/v1/lists": .init(body: try fixture("lists"))])).availableSources()
        #expect(sources.map(\.id) == [
            "mastodon:@me@example.social:home",
            "mastodon:@me@example.social:list:12",
            "mastodon:@me@example.social:list:13",
        ])
        #expect(sources.map(\.title) == ["Home", "Friends", "News & such"])
        #expect(sources.allSatisfy { $0.colorIndex == 4 && $0.accountID == account })
    }

    @Test func handlesOnlyItsOwnSources() {
        let connector = connector(replay([:]))
        #expect(connector.handles(home))
        #expect(connector.handles(friends))
        #expect(!connector.handles(MastodonMapper.homeSource(accountID: "@me@other.example", colorIndex: 0)))
        #expect(!connector.handles(Source(id: "rss:x", kind: .rss, title: "X", url: "https://x.example/feed", colorIndex: 0)))
    }

    @Test func firstFetchIsTheNewestPage() async throws {
        let http = replay(["/api/v1/timelines/home": .init(headers: ["Link": homeLink], body: try fixture("home-timeline"))])
        let page = try await connector(http).fetch(request(.newer, nil), from: home)
        #expect(query(http.requests[0]) == ["limit": "40"])
        #expect(page.items.count == 6)
        #expect(page.items.allSatisfy { $0.sourceID == home.id && $0.fetchedAt == fetchedAt })
        #expect(page.newer == Cursor(rawValue: "113400000000000005"))
        // The hidden status still counts for the cursor.
        #expect(page.older == Cursor(rawValue: "113399999999999999"))
    }

    @Test func newerPagesContinueStraightAfterTheCursor() async throws {
        let http = replay(["/api/v1/timelines/list/12": .init(body: try fixture("list-timeline"))])
        let page = try await connector(http).fetch(request(.newer, "113400000000000005"), from: friends)
        #expect(query(http.requests[0]) == ["limit": "40", "min_id": "113400000000000005"])
        #expect(page.newer == Cursor(rawValue: "113400000000000010"))
        #expect(page.items.map(\.boostedBy) == ["Cy :blobcat:"])
    }

    @Test func emptyNewerPageKeepsTheCursor() async throws {
        let http = replay(["/api/v1/timelines/home": .init(text: "[]")])
        let page = try await connector(http).fetch(request(.newer, "500"), from: home)
        #expect(page.items.isEmpty)
        #expect(page.newer == Cursor(rawValue: "500"))
        #expect(page.older == nil)
    }

    @Test func olderPagingStopsAtTheRetentionWindow() async throws {
        let http = replay(["/api/v1/timelines/home": .init(headers: ["Link": homeLink], body: try fixture("home-timeline"))])
        let inside = try await connector(http).fetch(request(.older, "113400000000000006"), from: home)
        #expect(query(http.requests[0]) == ["limit": "40", "max_id": "113400000000000006"])
        #expect(inside.older == Cursor(rawValue: "113399999999999999"))

        // The page's oldest status is from 00:54 on 24 October; a window
        // starting after it has nothing further back to fetch.
        let past = try await connector(http).fetch(request(.older, "113400000000000006", notBefore: Date(timeIntervalSince1970: 1_792_803_300)), from: home)
        #expect(past.older == nil)
    }

    @Test func fetchFillsInSizesAndCards() async throws {
        let http = FakeHTTPClient { request in
            if request.url!.path() == "/api/v1/timelines/home" {
                return .init(headers: ["Link": homeLink], body: try fixture("home-timeline"))
            }
            switch request.url!.absoluteString {
            case "https://files.example.social/cache/media/8.png":
                return .init(body: MediaFixtures.png(width: 1280, height: 720))
            case "https://www.example.com/a/very/long/path/to/an/article":
                return .init(text: #"<html><head><meta property="og:title" content="A long article"><meta property="og:site_name" content="Example"></head></html>"#)
            default:
                return .init(status: 404)
            }
        }
        let page = try await connector(http).fetch(request(.newer, nil), from: home)
        #expect(page.items[0].linkCard == Item.LinkCard(url: "https://www.example.com/a/very/long/path/to/an/article", site: "Example", title: "A long article"))
        #expect(page.items.last?.media == [Item.Media(
            kind: .video, url: "https://files.example.social/cache/media/8.mp4",
            previewURL: "https://files.example.social/cache/media/8.png", width: 1280, height: 720
        )!])
    }

    @Test func storedStatusesAreNotLookedUpAgain() async throws {
        let http = replay(["/api/v1/timelines/home": .init(headers: ["Link": homeLink], body: try fixture("home-timeline"))])
        var request = request(.newer, nil)
        request.storedRemoteIDs = Set(try homeItems().map(\.remoteID))
        _ = try await connector(http).fetch(request, from: home)
        #expect(http.requests.count == 1)
    }

    @Test func statusIDsCompareAsNumbers() {
        #expect(MastodonConnector.isOrdered("99", "100"))
        #expect(!MastodonConnector.isOrdered("100", "99"))
        #expect(MastodonConnector.isOrdered("113399999999999999", "113400000000000000"))
    }

    @Test func refresherStoresPagesAndRecordsProblems() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [home])
        let http = replay(["/api/v1/timelines/home": .init(headers: ["Link": homeLink], body: try fixture("home-timeline"))])
        let refresher = Refresher(store: store)
        let connector = connector(http)

        #expect(try await refresher.refresh(home, with: connector, now: fetchedAt) == .fetched(newItems: 6))
        let state = try #require(try await store.fetchState(sourceID: home.id))
        #expect(state.newerCursor == Cursor(rawValue: "113400000000000005"))
        #expect(state.olderCursor == Cursor(rawValue: "113399999999999999"))
        #expect(try await store.rows().count == 6)

        http.respond { _ in .init(status: 401, text: #"{"error":"The access token was revoked"}"#) }
        #expect(try await refresher.refresh(home, with: connector, now: fetchedAt.addingTimeInterval(60)) == .failed(.unauthorized))
        #expect(try await store.fetchState(sourceID: home.id)?.problem == .signedOut)
    }
}

@Suite struct MastodonBookmarks {
    @Test func readsEveryPageAsHomeItems() async throws {
        let first = try fixture("home-timeline")
        let replay = FakeHTTPClient { request in
            guard request.url!.path() == "/api/v1/bookmarks" else { return .init(status: 404) }
            if query(request)["max_id"] == nil {
                return .init(headers: ["Link": #"<https://example.social/api/v1/bookmarks?limit=40&max_id=900>; rel="next""#], body: first)
            }
            return .init(text: "[]")
        }
        let connector = MastodonConnector(accountID: "@me@example.social", instance: instance, accessToken: "t", http: replay)
        let list = try await connector.bookmarks(for: home, now: fetchedAt, storedRemoteIDs: Set(try homeItems().map(\.remoteID)))
        #expect(list.isComplete)
        #expect(list.items.map(\.remoteID) == (try homeItems()).map(\.remoteID))
        #expect(list.items.allSatisfy { $0.sourceID == home.id })
        let sent = replay.requests.filter { $0.url!.path() == "/api/v1/bookmarks" }
        #expect(sent.map(query) == [["limit": "40"], ["limit": "40", "max_id": "900"]])
    }

    @Test func aListLongerThanThePageLimitIsIncomplete() async throws {
        let replay = FakeHTTPClient { _ in
            .init(headers: ["Link": #"<https://example.social/api/v1/bookmarks?max_id=1>; rel="next""#], body: try fixture("home-timeline"))
        }
        let connector = MastodonConnector(accountID: "@me@example.social", instance: instance, accessToken: "t", http: replay)
        let list = try await connector.bookmarks(for: home, now: fetchedAt, storedRemoteIDs: Set(try homeItems().map(\.remoteID)))
        #expect(!list.isComplete)
        #expect(replay.requests.filter { $0.url!.path() == "/api/v1/bookmarks" }.count == MastodonConnector.maxBookmarkPages)
    }
}

@Suite struct MastodonAccountSignIn {
    private func signIn(_ http: FakeHTTPClient, _ credentials: InMemoryCredentialStore = InMemoryCredentialStore()) -> MastodonSignIn {
        MastodonSignIn(http: http, crypto: .fake(), credentials: credentials)
    }

    private func server() throws -> FakeHTTPClient {
        replay([
            "/api/v1/apps": .init(body: try fixture("app")),
            "/oauth/token": .init(body: try fixture("token")),
            "/oauth/revoke": .init(text: "{}"),
            "/api/v1/accounts/verify_credentials": .init(body: try fixture("verify-credentials")),
        ])
    }

    @Test func signsInAndStoresTheSession() async throws {
        let http = try server(), credentials = InMemoryCredentialStore()
        let signIn = signIn(http, credentials)
        let pending = try await signIn.begin(instance: "@me@Example.Social")

        let authorize = URLRequest(url: pending.authorizationURL)
        #expect(pending.authorizationURL.host() == "example.social")
        let parameters = query(authorize)
        #expect(parameters["client_id"] == "fixture-client-id")
        #expect(parameters["redirect_uri"] == "dev.bespokebits.influx:/oauth/mastodon")
        #expect(parameters["code_challenge"] == pending.pkce.challenge)
        #expect(form(http.requests[0])["redirect_uris"] == "dev.bespokebits.influx:/oauth/mastodon")

        let state = try #require(parameters["state"])
        let session = try await signIn.complete(pending, callback: URL(string: "dev.bespokebits.influx:/oauth/mastodon?code=abc&state=\(state)")!)
        #expect(session.accountID == "@me@example.social")
        #expect(session.accessToken == "fixture-access-token")
        #expect(session.app.clientId == "fixture-client-id")
        #expect(form(http.requests[1])["code_verifier"] == pending.pkce.verifier)
        #expect(http.requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access-token")
        #expect(try signIn.stored("@me@example.social") == session)

        // The stored session makes the account's connector.
        let connector = MastodonConnector(session: session, http: http)
        #expect(connector.handles(home))
    }

    @Test func rejectsAForeignCallback() async throws {
        let signIn = signIn(try server())
        let pending = try await signIn.begin(instance: "example.social")
        await #expect(throws: MastodonSignInError.callback(.stateMismatch)) {
            try await signIn.complete(pending, callback: URL(string: "dev.bespokebits.influx:/oauth/mastodon?code=abc&state=forged")!)
        }
    }

    @Test func reportsInstancesThatCantBeUsed() async throws {
        await #expect(throws: MastodonSignInError.notAnInstance) {
            try await signIn(try server()).begin(instance: "not an instance")
        }
        let down = FakeHTTPClient { _ in .init(status: 502) }
        await #expect(throws: MastodonSignInError.failed(.badResponse("HTTP 502"))) {
            try await signIn(down).begin(instance: "example.social")
        }
    }

    /// An instance that takes the connection and never answers: the
    /// spinner must stop with an error, not wait out URLSession's minute.
    @Test func givesUpOnAnInstanceThatNeverAnswers() async throws {
        struct Silent: HTTPClient {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await Task.sleep(for: .seconds(3600))
                throw ConnectorError.offline
            }
            func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
                try await send(request)
            }
            func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
                try await send(request)
            }
            func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await send(request)
            }
        }
        let signIn = MastodonSignIn(http: Silent(), crypto: .fake(), credentials: InMemoryCredentialStore(), timeout: .milliseconds(100))
        let started = ContinuousClock.now
        await #expect(throws: MastodonSignInError.timedOut) {
            try await signIn.begin(instance: "example.social")
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test func givesUpWhenTheAccountLookupNeverAnswers() async throws {
        let answering = try server()
        struct SilentOnAccount: HTTPClient {
            let answering: FakeHTTPClient
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.url?.path() == "/api/v1/accounts/verify_credentials" {
                    try await Task.sleep(for: .seconds(3600))
                }
                return try await answering.send(request)
            }
            func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
                try await send(request)
            }
            func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
                try await send(request)
            }
            func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                try await send(request)
            }
        }
        let credentials = InMemoryCredentialStore()
        let signIn = MastodonSignIn(http: SilentOnAccount(answering: answering), crypto: .fake(), credentials: credentials, timeout: .milliseconds(100))
        let pending = try await signIn.begin(instance: "example.social")
        let state = try #require(query(URLRequest(url: pending.authorizationURL))["state"])
        await #expect(throws: MastodonSignInError.timedOut) {
            try await signIn.complete(pending, callback: URL(string: "dev.bespokebits.influx:/oauth/mastodon?code=abc&state=\(state)")!)
        }
        // Nothing half-finished is stored.
        #expect(try signIn.stored("@me@example.social") == nil)
    }

    @Test func saysSoWhenTheCredentialsCantBeSaved() async throws {
        struct Refusing: CredentialStore {
            struct Failure: Error {}
            func data(for account: String) throws -> Data? { nil }
            func setData(_ data: Data, for account: String) throws { throw Failure() }
            func deleteData(for account: String) throws {}
            func accounts() throws -> [String] { [] }
        }
        let signIn = MastodonSignIn(http: try server(), crypto: .fake(), credentials: Refusing())
        let pending = try await signIn.begin(instance: "example.social")
        let state = try #require(query(URLRequest(url: pending.authorizationURL))["state"])
        await #expect(throws: MastodonSignInError.couldNotStore("Failure()")) {
            try await signIn.complete(pending, callback: URL(string: "dev.bespokebits.influx:/oauth/mastodon?code=abc&state=\(state)")!)
        }
    }

    @Test func signOutForgetsTheTokenAndRevokesIt() async throws {
        let http = try server(), credentials = InMemoryCredentialStore()
        let signIn = signIn(http, credentials)
        let pending = try await signIn.begin(instance: "example.social")
        let state = try #require(query(URLRequest(url: pending.authorizationURL))["state"])
        let session = try await signIn.complete(pending, callback: URL(string: "dev.bespokebits.influx:/oauth/mastodon?code=abc&state=\(state)")!)

        try await signIn.signOut(session)
        #expect(try signIn.stored(session.accountID) == nil)
        #expect(http.requests.last?.url?.path() == "/oauth/revoke")
        #expect(form(try #require(http.requests.last))["token"] == "fixture-access-token")

        // Offline: the token is still forgotten.
        try credentials.save(session, for: session.accountID)
        http.respond { _ in throw URLError(.notConnectedToInternet) }
        try await signIn.signOut(session)
        #expect(try signIn.stored(session.accountID) == nil)
    }
}

/// A status as the API sends it, with only what Influx reads.
private func statusJSON(_ id: String, replyTo: String? = nil, favourited: Bool = false, reblogged: Bool = false, bookmarked: Bool = false, reblog: [String: Any]? = nil) -> [String: Any] {
    var status: [String: Any] = [
        "id": id, "uri": "https://example.social/users/ana/statuses/\(id)", "url": "https://example.social/@ana/\(id)",
        "created_at": "2026-10-24T01:00:00.000Z", "content": "<p>Status \(id)</p>", "spoiler_text": "",
        "account": ["id": "109", "username": "ana", "acct": "ana", "display_name": "Ana Ruiz"],
        "mentions": [], "media_attachments": [],
        "favourited": favourited, "reblogged": reblogged, "bookmarked": bookmarked,
    ]
    if let replyTo {
        status["in_reply_to_id"] = replyTo
        status["in_reply_to_account_id"] = "109"
    }
    if let reblog { status["reblog"] = reblog }
    return status
}

private func json(_ value: Any) -> FakeHTTPClient.Response {
    .init(body: try! JSONSerialization.data(withJSONObject: value))
}

@Suite struct MastodonActions {
    private func connector(_ http: FakeHTTPClient) -> MastodonConnector {
        MastodonConnector(accountID: "@me@example.social", instance: instance, accessToken: "t", http: http, resolver: .testing(http))
    }

    @Test func viewerStateIsMappedFromTheBoostedPost() throws {
        let boost = try Mastodon.decoder().decode(Mastodon.Status.self, from: JSONSerialization.data(withJSONObject:
            statusJSON("2", reblog: statusJSON("1", favourited: true, bookmarked: true))))
        let item = try #require(MastodonMapper.item(from: boost, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(item.viewer == Item.Viewer(liked: true, bookmarked: true))
    }

    @Test(arguments: [
        (ConnectorAction.like, "favourite"), (.unlike, "unfavourite"), (.boost, "reblog"),
        (.unboost, "unreblog"), (.bookmark, "bookmark"), (.unbookmark, "unbookmark"),
    ])
    func actionsPostToTheStatusTheyAreAbout(action: ConnectorAction, verb: String) async throws {
        let http = FakeHTTPClient { request in
            // A boost answers with the new boost; the rest with the status.
            let status = statusJSON("1", favourited: action == .like, reblogged: action == .boost, bookmarked: action == .bookmark)
            return json(verb == "reblog" ? statusJSON("9", reblog: status) : status)
        }
        let viewer = try await connector(http).perform(action, on: ItemReference(sourceID: home.id, remoteID: "wrapper", actionRef: "1"))
        let sent = try #require(http.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/api/v1/statuses/1/\(verb)")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        #expect(viewer == Item.Viewer().applying(action))
    }

    @Test func theActionTakenIsTrustedOverALaggingAnswer() async throws {
        let http = FakeHTTPClient { _ in json(statusJSON("1", favourited: true, bookmarked: true)) }
        let viewer = try await connector(http).perform(.unlike, on: ItemReference(sourceID: home.id, remoteID: "1"))
        #expect(viewer == Item.Viewer(bookmarked: true))
    }

    @Test func refusalsAreConnectorErrors() async throws {
        let http = FakeHTTPClient { _ in .init(status: 404) }
        await #expect(throws: ConnectorError.notFound) {
            try await connector(http).perform(.like, on: ItemReference(sourceID: home.id, remoteID: "1"))
        }
    }

    @Test func threadHasAncestorsAndNestedReplies() async throws {
        let http = replay([
            "/api/v1/statuses/3": json(statusJSON("3", replyTo: "2")),
            "/api/v1/statuses/3/context": json([
                "ancestors": [statusJSON("1"), statusJSON("2", replyTo: "1")],
                "descendants": [statusJSON("4", replyTo: "3"), statusJSON("5", replyTo: "4"), statusJSON("6", replyTo: "3")],
            ]),
        ])
        let thread = try await connector(http).thread(of: ItemReference(sourceID: home.id, remoteID: "boost-of-3", actionRef: "3"))
        #expect(thread.ancestors.map(\.remoteID) == ["1", "2"])
        #expect(thread.post.remoteID == "3")
        #expect(thread.post.body == "Status 3")
        #expect(thread.replies.map(\.item.remoteID) == ["4", "5", "6"])
        #expect(thread.replies.map(\.depth) == [1, 2, 1])
        #expect((thread.ancestors + [thread.post]).allSatisfy { $0.sourceID == home.id && $0.viewer != nil })
    }
}

@Suite struct MastodonLinks {
    @Test func anchorsBecomeLinksOverTheirShownText() throws {
        let item = try #require(try homeItems().first)
        let body = item.body as NSString
        let shown = item.links.map { body.substring(with: NSRange(location: $0.start, length: $0.length)) }
        #expect(shown == ["@cy", "#RSS", "example.com/a/very/long/pa…"])
        #expect(item.links.map(\.url) == [
            "https://far.example/@cy", "https://example.social/tags/RSS", "https://www.example.com/a/very/long/path/to/an/article",
        ])
    }

    @Test func linksMoveWithTrimmingAndContentWarnings() throws {
        let (text, links) = MastodonHTML.textAndLinks("  <p><a href=\"https://a.example/x\">here</a> &amp; there</p>")
        #expect(text == "here & there")
        #expect(links == [Item.Link(start: 0, length: 4, url: "https://a.example/x")])

        var status = try #require(try statuses("home-timeline").first)
        status.content = "<p>see <a href=\"https://a.example/x\">this</a></p>"
        status.spoilerText = "CW"
        let item = try #require(MastodonMapper.item(from: status, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(item.body == "CW\n\nsee this")
        #expect((item.body as NSString).substring(with: NSRange(location: item.links[0].start, length: item.links[0].length)) == "this")
    }

    @Test func nonWebAnchorsAreNotLinks() {
        #expect(MastodonHTML.textAndLinks("<a href=\"mailto:a@b\">mail</a>").links.isEmpty)
    }
}
