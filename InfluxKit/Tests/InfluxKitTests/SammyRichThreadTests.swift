import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import InfluxKit

/// A Sammy server with the contract's attribution page, its thread, grants
/// for any attachment, and the grants' bytes. What the thread route
/// answers can be changed per test.
private final class ThreadServer: @unchecked Sendable {
    static let feedPath = "/api/v1/feeds/\(RichFixtures.richFeedID)"
    static let ref = "contract-thread-1"
    static let threadPath = "\(feedPath)/threads/\(ref)"

    private let lock = NSLock()
    private var threadAnswer: (@Sendable (URLRequest) -> FakeHTTPClient.Response)?
    let page: Data
    let exchange: [String: Any]

    init() throws {
        page = try RichFixtures.data("rich-feed-page-attribution.json")
        exchange = try RichFixtures.object("rich-feed-thread.json")
    }

    /// The thread's recorded 200: its headers and its body.
    func recorded() throws -> FakeHTTPClient.Response {
        let response = try #require(exchange["response"] as? [String: Any])
        let headers = try #require(response["headers"] as? [String: String])
        let body = try JSONSerialization.data(withJSONObject: try #require(response["body"]))
        return .init(headers: headers, body: body)
    }

    /// The recorded thread with `change` made to its body.
    func recorded(_ change: (inout [String: Any]) throws -> Void) throws -> FakeHTTPClient.Response {
        var answer = try recorded()
        var body = try #require(try JSONSerialization.jsonObject(with: answer.body) as? [String: Any])
        try change(&body)
        answer.body = try JSONSerialization.data(withJSONObject: body)
        return answer
    }

    var etag: String {
        get throws {
            let response = try #require(exchange["response"] as? [String: Any])
            return try #require((response["headers"] as? [String: String])?["ETag"])
        }
    }

    func thread(_ answer: @escaping @Sendable (URLRequest) -> FakeHTTPClient.Response) {
        lock.withLock { threadAnswer = answer }
    }

    func handler() throws -> @Sendable (URLRequest) throws -> FakeHTTPClient.Response {
        let pageHeaders = try RichFixtures.headers("page")
        let recorded = try recorded()
        let etag = try etag
        return { [self] request in
            guard let url = request.url, url.host() == "example.com", url.scheme == "https" else { return .init(status: 404) }
            if url.path == Self.feedPath { return .init(headers: pageHeaders, body: page) }
            if url.path == Self.threadPath {
                if let answer = lock.withLock({ threadAnswer }) { return answer(request) }
                if request.value(forHTTPHeaderField: "If-None-Match") == etag {
                    return .init(status: 304, headers: ["Cache-Control": "private, no-cache", "ETag": etag, "Vary": "Accept"])
                }
                return recorded
            }
            if url.path.hasSuffix("/grant"), request.httpMethod == "POST" {
                let mediaID = url.path.split(separator: "/").dropLast().last.map(String.init) ?? ""
                let body = try JSONSerialization.data(withJSONObject: [
                    "url": "https://example.com/api/v1/rich-media/\(mediaID)-token",
                    "expiresAt": "2026-11-05T00:15:00Z",
                ])
                return .init(headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: body)
            }
            if url.path.hasPrefix("/api/v1/rich-media/") {
                return .init(headers: ["Content-Type": "image/jpeg", "Content-Length": "4"], body: Data([1, 2, 3, 4]))
            }
            return .init(status: 404)
        }
    }
}

@Suite struct SammyRichThreadTests {
    private static let token = "Bearer sao_contract-example-access-token"
    private static let account = RichFixtures.accountID, feed = RichFixtures.richFeedID
    private static let threadID = "urn:uuid:2eb84ebf-0321-84ee-8fba-57d7f6d121a8"
    private static let repostID = "urn:uuid:73727e07-0a03-853d-8758-79fd836fc7cb"
    private static let quoteID = "urn:uuid:79be70d6-136d-81ed-84f3-ca7bc8d08bcb"
    private static let unavailableID = "urn:uuid:318f901e-02bc-8c66-b4d1-cbacaad06f3f"
    private static let cardID = "urn:uuid:955125f4-90e3-846a-9776-4216dd92efd4"
    private static let article = "https://www.example.com/articles/coast-path?utm_source=example"

    private static func connector(_ http: FakeHTTPClient) throws -> SammyFeedConnector {
        let credentials = InMemoryCredentialStore()
        let session = RichFixtures.session()
        try credentials.save(session, for: session.accountID)
        let account = SammyAccount(session: session, http: http, credentials: credentials)
        return SammyFeedConnector(account: account, http: http, resolver: .testing(http), fetchLimit: RSSConnector.fetchLimit,
                                  addresses: AddressLookup { host in host == "example.com" ? [[93, 184, 216, 34]] : nil },
                                  now: { RichFixtures.now }, directSources: false)
    }

    /// A store holding the attribution page, refreshed as the app does.
    private static func stored(_ server: ThreadServer) throws -> (FakeHTTPClient, SammyFeedConnector) {
        let http = FakeHTTPClient(try server.handler())
        return (http, try connector(http))
    }

    private static func refreshed(_ connector: SammyFeedConnector) async throws -> (InfluxStore, Source) {
        let store = try InfluxStore.inMemory()
        let source = RichFixtures.source(.post)
        try await store.save(sources: [source])
        #expect(try await Refresher(store: store).refresh(source, with: connector, now: RichFixtures.now) == .fetched(newItems: 5))
        return (store, source)
    }

    private static func row(_ rows: [TimelineRow], _ remoteID: String, in store: InfluxStore) async throws -> (TimelineRow, Item) {
        for row in rows {
            let item = try #require(try await store.item(id: row.id))
            if item.remoteID == remoteID { return (row, item) }
        }
        Issue.record("no row for \(remoteID)")
        throw ConnectorError.notFound
    }

    /// The stored post the thread is opened on.
    private static func focus(_ store: InfluxStore) async throws -> Item {
        try await row(try await store.rows(), threadID, in: store).1
    }

    // MARK: The page

    @Test func theAttributionPageDecodesEachField() throws {
        let page = try RichFeedPage.decode(RichFixtures.data("rich-feed-page-attribution.json"), feedID: Self.feed,
                                           feedURL: URL(string: RichFixtures.richFeedURL)!)
        #expect(page.posts.map(\.id) == [Self.threadID, Self.repostID, Self.quoteID, Self.unavailableID, Self.cardID])
        #expect(page.posts[0].threadRef == ThreadServer.ref)
        #expect(page.posts[1].repostedBy == RichFeedPage.Person(name: "Example Author", url: "https://www.example.com/author/",
                                                                 avatarID: "example-avatar-1"))
        #expect(page.posts[1].authorName == "Another Author")
        // An author's picture is a media ID; a post whose author has none has none.
        #expect(page.posts.map(\.authorAvatarID) == [nil, "example-avatar-2", nil, nil, "example-avatar-2"])
        // So is a handle.
        #expect(page.posts.map(\.authorHandle) == [nil, "@another_author", nil, nil, "@another_author"])
        // A shared article carries the source's card; nothing else does.
        #expect(page.posts[4].card == RichFeedPage.Card(
            url: Self.article, title: "Walking the coast path in winter",
            description: "What to pack, where to start and how long each stretch takes.", site: "example.com",
            image: RichFeedPage.CardImage(id: "example-card-image-1", width: 1200, height: 628)))
        #expect(page.posts.filter { $0.card != nil }.count == 1)
        guard case .post(let quoted)? = page.posts[2].quote else {
            Issue.record("no quoted post")
            return
        }
        #expect(quoted.url == "https://www.example.com/other/posts/53")
        #expect(quoted.canonicalID == "urn:uuid:0193a1b2-0000-7000-8000-000000000053")
        #expect(quoted.author == RichFeedPage.Person(name: "Another Author", url: "https://www.example.com/other/",
                                                     avatarID: "example-avatar-2", handle: "@another_author"))
        #expect(quoted.text == "The harbour at first light.")
        #expect(quoted.media.map(\.id) == ["example-image-3"])
        #expect(quoted.publishedAt == FeedDate.iso8601("2026-10-20T06:00:00Z"))
        #expect(page.posts[3].quote == .unavailable(url: "https://www.example.com/other/posts/55"))
        // Nothing else carries any of them.
        #expect(page.posts.filter { $0.threadRef != nil }.count == 1)
        #expect(page.posts.filter { $0.repostedBy != nil }.count == 1)
    }

    @Test func aRepostNamesWhoRepostedItAsItsBooster() async throws {
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let (row, item) = try await Self.row(try await store.rows(), Self.repostID, in: store)
        #expect(row.boostedBy == ["Example Author"])
        #expect(item.boostedByID == "https://www.example.com/author/")
        // Both pictures are references, drawn as any profile picture is.
        #expect(row.authorAvatar == "sammy-media:\(Self.account)/\(Self.feed)/example-avatar-2")
        #expect(item.boostedByAvatar == "sammy-media:\(Self.account)/\(Self.feed)/example-avatar-1")
        #expect(row.boosterAvatar == item.boostedByAvatar)
        // The original author's post, placed by its own time.
        #expect(row.authorName == "Another Author")
        #expect(row.sortDate == FeedDate.iso8601("2026-11-02T15:00:00Z"))
        // Its one action is Influx's own bookmark (ADR 0031).
        #expect(row.viewer == Item.Viewer() && !row.hasThread)
    }

    @Test func anAuthorsPictureIsGrantedLikeAnAttachment() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let (row, _) = try await Self.row(try await store.rows(), Self.repostID, in: store)
        let reference = try #require(row.authorAvatar.flatMap(SammyMediaReference.init))
        #expect(reference.mediaID == "example-avatar-2" && reference.thread == nil && !reference.preview)
        #expect(try await connector.media.data(for: reference, upTo: 1_000, timeout: .seconds(5)) == Data([1, 2, 3, 4]))
        let grant = try #require(http.requests.first { $0.httpMethod == "POST" })
        #expect(grant.url?.absoluteString == "\(RichFixtures.richFeedURL)/media/example-avatar-2/grant")
        #expect(grant.value(forHTTPHeaderField: "Authorization") == Self.token)
        // A post whose author has no picture keeps the monogram.
        let (plain, _) = try await Self.row(try await store.rows(), Self.quoteID, in: store)
        #expect(plain.authorAvatar == nil)
    }

    @Test func aQuoteIsTheQuoteCardWithItsPictureAsAReference() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let (row, _) = try await Self.row(try await store.rows(), Self.quoteID, in: store)
        let quote = try #require(row.quote)
        #expect(quote == Item.Quote(
            mergeKey: "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-000000000053",
            url: "https://www.example.com/other/posts/53", authorName: "Another Author", authorHandle: "@another_author",
            body: "The harbour at first light.",
            image: Item.Media(kind: .image, url: "sammy-media:\(Self.account)/\(Self.feed)/example-image-3", width: 1200, height: 800,
                              altText: "Fishing boats moored in a calm harbour.")
        ))
        // The quote's picture comes through a feed grant, as the post's own.
        let image = try #require(quote.image)
        let reference = try #require(SammyMediaReference(image.url))
        #expect(try await connector.media.data(for: reference, upTo: 1_000, timeout: .seconds(5)) == Data([1, 2, 3, 4]))
        let grant = try #require(http.requests.first { $0.httpMethod == "POST" })
        #expect(grant.url?.absoluteString == "\(RichFixtures.richFeedURL)/media/example-image-3/grant")
    }

    @Test func anAuthorsHandleIsShownAfterTheirNameAndTheHostWithoutOne() async throws {
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let rows = try await store.rows()
        #expect(try await Self.row(rows, Self.repostID, in: store).0.authorHandle == "@another_author")
        #expect(try await Self.row(rows, Self.cardID, in: store).0.authorHandle == "@another_author")
        // The feed's author has no handle on the page: the row shows the host, as before.
        #expect(try await Self.row(rows, Self.quoteID, in: store).0.authorHandle == "example.com")
    }

    @Test func aSharedArticleIsTheRowsLinkCardWithItsPictureAsAReference() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let (row, item) = try await Self.row(try await store.rows(), Self.cardID, in: store)
        #expect(item.linkCard == Item.LinkCard(
            url: Self.article, site: "example.com", title: "Walking the coast path in winter",
            summary: "What to pack, where to start and how long each stretch takes.",
            image: Item.Media(kind: .image, url: "sammy-media:\(Self.account)/\(Self.feed)/example-card-image-1", width: 1200, height: 628)
        ))
        #expect(row.linkCard == item.linkCard)
        // The card shows its link, so the text is the post's alone, with
        // no URL listed after it.
        #expect(item.body == "Worth a read before the weekend's walk.")
        #expect(item.links.isEmpty)
        // Its picture comes through a feed grant, as an attachment's.
        let reference = try #require(item.linkCard?.image.flatMap { SammyMediaReference($0.url) })
        #expect(reference.thread == nil && !reference.preview)
        #expect(try await connector.media.data(for: reference, upTo: 1_000, timeout: .seconds(5)) == Data([1, 2, 3, 4]))
        let grant = try #require(http.requests.first { $0.httpMethod == "POST" })
        #expect(grant.url?.absoluteString == "\(RichFixtures.richFeedURL)/media/example-card-image-1/grant")
        // No other post has a card.
        for id in [Self.threadID, Self.repostID, Self.quoteID, Self.unavailableID] {
            #expect(try await Self.row(try await store.rows(), id, in: store).1.linkCard == nil, "\(id)")
        }
    }

    @Test func aCardWithoutASiteNamesItsLinksHostAndOneWithoutAPictureHasNone() throws {
        let page = try RichFixtures.page("rich-feed-page-attribution.json") { page in
            var items = try #require(page["items"] as? [[String: Any]])
            items[4]["card"] = ["url": Self.article, "title": "Walking the coast path in winter"]
            page["items"] = items
        }
        let decoded = try RichFeedPage.decode(page, feedID: Self.feed, feedURL: URL(string: RichFixtures.richFeedURL)!)
        let item = RichFeedMapper.item(from: decoded.posts[4], feedID: Self.feed, source: RichFixtures.source(.post), fetchedAt: RichFixtures.now)
        #expect(item.linkCard == Item.LinkCard(url: Self.article, site: "example.com", title: "Walking the coast path in winter"))
    }

    @Test(arguments: [
        "a card off the post's links", "a card with no title", "a card with an empty title", "a card title too long",
        "a description too long", "an empty site", "a picture URL", "a picture without its size", "a picture too large",
        "a picture with a malformed ID", "a null card", "a card that isn't an object", "a card beside media", "a card beside a quote",
    ])
    func aBrokenCardIsLeftOutAndThePostStaysWithItsLinkAfterTheText(_ fault: String) throws {
        let page = try RichFixtures.page("rich-feed-page-attribution.json") { page in
            var items = try #require(page["items"] as? [[String: Any]])
            var card = try #require(items[4]["card"] as? [String: Any])
            var post = items[4]
            switch fault {
            case "a card off the post's links": card["url"] = "https://www.example.com/articles/other"
            case "a card with no title": card["title"] = nil
            case "a card with an empty title": card["title"] = ""
            case "a card title too long": card["title"] = String(repeating: "t", count: 301)
            case "a description too long": card["description"] = String(repeating: "d", count: 1001)
            case "an empty site": card["site"] = ""
            case "a picture URL": card["image"] = "https://www.example.com/a.jpg"
            case "a picture without its size": card["image"] = ["id": "example-card-image-1"]
            case "a picture too large": card["image"] = ["id": "example-card-image-1", "width": 16385, "height": 10]
            case "a picture with a malformed ID": card["image"] = ["id": "a/b", "width": 10, "height": 10]
            case "a null card": post["card"] = NSNull()
            case "a card that isn't an object": post["card"] = "card"
            case "a card beside media": post["media"] = [["id": "example-image-9", "kind": "image", "width": 10, "height": 10]]
            case "a card beside a quote": post["quote"] = ["url": "https://www.example.com/other/posts/55", "unavailable": true]
            default: Issue.record("unknown fault \(fault)")
            }
            if post["card"] is [String: Any] { post["card"] = card }
            items[4] = post
            page["items"] = items
        }
        let decoded = try RichFeedPage.decode(page, feedID: Self.feed, feedURL: URL(string: RichFixtures.richFeedURL)!)
        #expect(decoded.posts.map(\.id) == [Self.threadID, Self.repostID, Self.quoteID, Self.unavailableID, Self.cardID], "\(fault)")
        let post = try #require(decoded.posts.last)
        #expect(post.card == nil, "\(fault)")
        let item = RichFeedMapper.item(from: post, feedID: Self.feed, source: RichFixtures.source(.post), fetchedAt: RichFixtures.now)
        #expect(item.linkCard == nil, "\(fault)")
        // The link the card would have shown is listed after the text instead.
        #expect(item.body == "Worth a read before the weekend's walk.\n\n\(Self.article)", "\(fault)")
    }

    @Test(arguments: ["", "@", "another_author", "@another author", "@another\nauthor", "@" + String(repeating: "x", count: 65), "@a/b", "@é"])
    func aHandleOutsideTheGrammarIsLeftOutAndThePostStays(_ handle: String) throws {
        let page = try RichFixtures.page("rich-feed-page-attribution.json") { page in
            var items = try #require(page["items"] as? [[String: Any]])
            var author = try #require(items[1]["author"] as? [String: Any])
            author["handle"] = handle
            items[1]["author"] = author
            page["items"] = items
        }
        let decoded = try RichFeedPage.decode(page, feedID: Self.feed, feedURL: URL(string: RichFixtures.richFeedURL)!)
        #expect(decoded.posts.count == 5)
        #expect(decoded.posts[1].authorHandle == nil)
        let item = RichFeedMapper.item(from: decoded.posts[1], feedID: Self.feed, source: RichFixtures.source(.post), fetchedAt: RichFixtures.now)
        #expect(item.authorHandle == "example.com")
        #expect(RichFeedPage.isHandle("@a") && RichFeedPage.isHandle("@a_b.c-d@example.com")
                && RichFeedPage.isHandle("@" + String(repeating: "x", count: 64)))
    }

    @Test func aVideosStillIsTheQuotesPictureAndOneWithoutAStillHasNone() throws {
        let page = try RichFixtures.page("rich-feed-page-attribution.json") { page in
            var items = try #require(page["items"] as? [[String: Any]])
            var quote = try #require(items[2]["quote"] as? [String: Any])
            quote["media"] = [["id": "clip", "kind": "video", "width": 1280, "height": 720, "preview": true]]
            items[2]["quote"] = quote
            var bare = quote
            bare["media"] = [["id": "loop", "kind": "gif", "width": 480, "height": 480]]
            items[3]["quote"] = bare
            page["items"] = items
        }
        let decoded = try RichFeedPage.decode(page, feedID: Self.feed, feedURL: URL(string: RichFixtures.richFeedURL)!)
        let items = RichFeedMapper.items(from: decoded, source: RichFixtures.source(.post), fetchedAt: RichFixtures.now)
        #expect(items[2].quote?.image == Item.Media(kind: .image, url: "sammy-media:\(Self.account)/\(Self.feed)/clip?variant=preview",
                                                    width: 1280, height: 720))
        #expect(items[3].quote != nil && items[3].quote?.image == nil)
    }

    @Test func anUnavailableQuoteIsKeptWithItsAddressAndThePostStays() async throws {
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let (row, _) = try await Self.row(try await store.rows(), Self.unavailableID, in: store)
        let quote = try #require(row.quote)
        #expect(quote.isUnavailable)
        #expect(quote == .unavailable(url: "https://www.example.com/other/posts/55"))
        #expect(quote.authorName.isEmpty && quote.body.isEmpty && quote.image == nil)
        #expect(row.body == "Quoting a post the source can no longer show.")
    }

    @Test func postsWithoutTheNewFieldsAreStoredAsBefore() async throws {
        let source = RichFixtures.source(.post)
        let page = try await RichFixtures.connector(try RichFixtures.pages()).fetch(RichFixtures.request(source), from: source)
        #expect(page.items.count == 2)
        #expect(page.items.allSatisfy { $0.boostedBy == nil && $0.boostedByID == nil && $0.quote == nil && $0.actionRef == nil })
    }

    /// Each of these breaks the contract and drops its post alone, as any
    /// other broken field does (ADR 0031); the server refuses the whole
    /// page over the same faults.
    @Test(arguments: [
        "a quote inside a quote", "a repost inside a quote", "a thread inside a quote", "an unavailable quote with text",
        "an unavailable quote that isn't", "a quote with no time", "a quote with empty text", "a quote off https",
        "a quote with a malformed identity", "a quote with too much media", "a null quote", "a null repost",
        "a repost with no name", "a null thread", "a thread reference outside its alphabet", "a thread reference too long",
    ])
    func aBrokenAttributionDropsItsPostAlone(_ fault: String) throws {
        let page = try RichFixtures.page("rich-feed-page-attribution.json") { page in
            var items = try #require(page["items"] as? [[String: Any]])
            var quote = try #require(items[2]["quote"] as? [String: Any])
            var post = items[2]
            switch fault {
            case "a quote inside a quote": quote["quote"] = ["url": "https://www.example.com/x", "unavailable": true]
            case "a repost inside a quote": quote["repostedBy"] = ["name": "Someone"]
            case "a thread inside a quote": quote["thread"] = ["ref": "abc"]
            case "an unavailable quote with text": quote = ["url": "https://www.example.com/x", "unavailable": true, "text": "x"]
            case "an unavailable quote that isn't": quote = ["url": "https://www.example.com/x", "unavailable": false]
            case "a quote with no time": quote["publishedAt"] = nil
            case "a quote with empty text": quote["text"] = ""
            case "a quote off https": quote["url"] = "http://www.example.com/other/posts/53"
            case "a quote with a malformed identity": quote["canonicalId"] = "urn:uuid:NOT-A-UUID"
            case "a quote with too much media":
                quote["media"] = (0..<9).map { ["id": "m\($0)", "kind": "image", "width": 10, "height": 10] }
            case "a null quote": post["quote"] = NSNull()
            case "a null repost": post["repostedBy"] = NSNull()
            case "a repost with no name": post["repostedBy"] = ["name": ""]
            case "a null thread": post["thread"] = NSNull()
            case "a thread reference outside its alphabet": post["thread"] = ["ref": "has space"]
            case "a thread reference too long": post["thread"] = ["ref": String(repeating: "a", count: 257)]
            default: Issue.record("unknown fault \(fault)")
            }
            if post["quote"] is [String: Any] { post["quote"] = quote }
            items[2] = post
            page["items"] = items
        }
        let decoded = try RichFeedPage.decode(page, feedID: Self.feed, feedURL: URL(string: RichFixtures.richFeedURL)!)
        #expect(decoded.posts.map(\.id) == [Self.threadID, Self.repostID, Self.unavailableID, Self.cardID], "\(fault)")
    }

    // MARK: Opening a thread

    @Test func onlyAPostThatNamesAThreadOffersOne() async throws {
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let rows = try await store.rows()
        let threads = Dictionary(uniqueKeysWithValues: try await rows.asyncMap { row in
            (try #require(try await store.item(id: row.id)).remoteID, row.hasThread)
        })
        #expect(threads == [Self.threadID: true, Self.repostID: false, Self.quoteID: false, Self.unavailableID: false, Self.cardID: false])
        #expect(rows.allSatisfy { $0.isRich && $0.viewer == Item.Viewer() })
        let focus = try await Self.focus(store)
        #expect(focus.actionRef == "thread:contract-thread-1")
        #expect(connector.offersThread(of: ItemReference(focus)))
        // A post that names none still answers as before.
        let (_, repost) = try await Self.row(rows, Self.repostID, in: store)
        #expect(!connector.offersThread(of: ItemReference(repost)))
        await #expect(throws: ConnectorError.unsupported) { try await connector.thread(of: ItemReference(repost)) }
    }

    @Test func theThreadIsReadWithTheRichAcceptAndTheAccountsCredential() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let focus = try await Self.focus(store)
        let thread = try await connector.thread(of: ItemReference(focus))

        let request = try #require(http.requests.last)
        let recorded = try #require(server.exchange["request"] as? [String: Any])
        #expect(request.url?.absoluteString == recorded["endpoint"] as? String)
        #expect(request.httpMethod ?? "GET" == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == (recorded["headers"] as? [String: String])?["Accept"])
        #expect(request.value(forHTTPHeaderField: "Authorization") == Self.token)
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
        // The token went only to the account's own server.
        #expect(http.requests.allSatisfy { $0.url?.host() == "example.com" && $0.url?.scheme == "https" })

        #expect(thread.ancestors.map(\.body) == ["Where is the best place to watch the lighthouse at dusk?",
                                                 "Asking again now that the evenings are drawing in."])
        #expect(thread.post.remoteID == Self.threadID && thread.post.body == focus.body)
        #expect(thread.post.mergeKey == focus.mergeKey)
        #expect(thread.replies.map(\.item.body) == ["Second: the path is steep, so leave half an hour for it.",
                                                    "Third: bring a torch for the walk back down."])
        #expect(thread.replies.map(\.depth) == [1, 1])
        #expect(thread.gaps == [PostThread.Gap(position: .ancestors, reason: .deleted)])
        // Every post reads as the feed's, read-only, and only the focus
        // opens a thread.
        let all = thread.ancestors + [thread.post] + thread.replies.map(\.item)
        #expect(all.allSatisfy { $0.sourceID == focus.sourceID && $0.viewer == nil && $0.kind == .post })
        #expect(all.map { connector.offersThread(of: ItemReference($0)) } == [false, false, true, false, false])
        // A context post's picture names the thread, at its own size.
        #expect(thread.ancestors[0].media == [
            Item.Media(kind: .image, url: "sammy-media:\(Self.account)/\(Self.feed)/example-image-4?thread=contract-thread-1",
                       width: 1024, height: 768, altText: "A lighthouse seen from far along the coast.")!,
        ])
    }

    @Test func aThreadPostsMediaIsGrantedByTheThread() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let thread = try await connector.thread(of: ItemReference(try await Self.focus(store)))
        let picture = try #require(thread.ancestors[0].media.first)
        let reference = try #require(SammyMediaReference(picture.url))
        #expect(reference.thread == ThreadServer.ref)
        #expect(try await connector.media.data(for: reference, upTo: 1_000, timeout: .seconds(5)) == Data([1, 2, 3, 4]))
        let grant = try #require(http.requests.first { $0.httpMethod == "POST" })
        let recorded = try #require((server.exchange["mediaGrant"] as? [String: Any])?["request"] as? [String: Any])
        #expect(grant.url?.absoluteString == recorded["endpoint"] as? String)
        #expect(grant.httpMethod == recorded["method"] as? String)
        #expect(grant.value(forHTTPHeaderField: "Authorization") == Self.token)
        #expect(grant.httpBody == nil)
    }

    @Test func aThreadPostsAuthorPictureIsGrantedByTheThread() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let thread = try await connector.thread(of: ItemReference(try await Self.focus(store)))
        #expect(thread.ancestors.map(\.authorAvatar) == Array(repeating:
            "sammy-media:\(Self.account)/\(Self.feed)/example-avatar-2?thread=contract-thread-1", count: 2))
        #expect(thread.post.authorAvatar == nil)
        let reference = try #require(thread.ancestors[0].authorAvatar.flatMap(SammyMediaReference.init))
        #expect(try await connector.media.data(for: reference, upTo: 1_000, timeout: .seconds(5)) == Data([1, 2, 3, 4]))
        let grant = try #require(http.requests.first { $0.httpMethod == "POST" })
        let recorded = try #require((server.exchange["avatarGrant"] as? [String: Any])?["request"] as? [String: Any])
        #expect(grant.url?.absoluteString == recorded["endpoint"] as? String)
        #expect(grant.httpMethod == recorded["method"] as? String)
    }

    @Test func aThreadPostsCardPictureIsGrantedByTheThread() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let thread = try await connector.thread(of: ItemReference(try await Self.focus(store)))
        let card = try #require(thread.ancestors[1].linkCard)
        #expect(card.url == "https://www.example.com/articles/lighthouse-hours")
        #expect(card.title == "Lighthouse opening hours" && card.site == "example.com")
        let image = try #require(card.image)
        #expect(image.url == "sammy-media:\(Self.account)/\(Self.feed)/example-card-image-2?thread=contract-thread-1")
        #expect(image.width == 800 && image.height == 418)
        #expect(thread.ancestors[1].authorHandle == "@another_author")
        let reference = try #require(SammyMediaReference(image.url))
        #expect(try await connector.media.data(for: reference, upTo: 1_000, timeout: .seconds(5)) == Data([1, 2, 3, 4]))
        let grant = try #require(http.requests.first { $0.httpMethod == "POST" })
        let recorded = try #require((server.exchange["cardImageGrant"] as? [String: Any])?["request"] as? [String: Any])
        #expect(grant.url?.absoluteString == recorded["endpoint"] as? String)
        #expect(grant.httpMethod == recorded["method"] as? String)
    }

    @Test func threadPostsAreNeverStored() async throws {
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let before = try await store.rows()
        let count = { try await store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0 } }
        // As the thread view opens it, through the post actions.
        let thread = try await PostActions(store: store).thread(of: try await Self.focus(store), with: connector)
        #expect(thread.ancestors.count == 2 && thread.replies.count == 2)
        #expect(try await store.rows() == before)
        #expect(try await count() == 5)
        // The rich posts stay without actions.
        #expect(([thread.post] + thread.ancestors).allSatisfy { $0.viewer == nil })
    }

    @Test func anUnchangedThreadCostsA304() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let focus = ItemReference(try await Self.focus(store))
        let first = try await connector.thread(of: focus)
        let again = try await connector.thread(of: focus)
        let threadReads = http.requests.filter { $0.url?.path == ThreadServer.threadPath }
        #expect(threadReads.count == 2)
        let notModified = try #require((server.exchange["notModified"] as? [String: Any])?["request"] as? [String: Any])
        #expect(threadReads[1].value(forHTTPHeaderField: "If-None-Match") == (notModified["headers"] as? [String: String])?["If-None-Match"])
        #expect(threadReads[1].value(forHTTPHeaderField: "Accept") == SammyNegotiation.rich)
        #expect(again == first)
    }

    @Test func a304WithNoThreadKeptOrForAnotherRepresentationIsRefused() async throws {
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let focus = ItemReference(try await Self.focus(store))
        server.thread { _ in .init(status: 304, headers: ["ETag": "W/\"rich-thread-v1-abc\""]) }
        await #expect(throws: ConnectorError.badResponse("a 304 for another representation")) { try await connector.thread(of: focus) }

        server.thread { _ in try! server.recorded() }
        _ = try await connector.thread(of: focus)
        // A page's validator can never stand for a thread.
        server.thread { _ in .init(status: 304, headers: ["ETag": "W/\"rich-v1-abc\""]) }
        await #expect(throws: ConnectorError.badResponse("a 304 for another representation")) { try await connector.thread(of: focus) }
    }

    @Test func refusalsAreTheThreadRoutesOwn() async throws {
        let refusals = try RichFixtures.object("rich-feed-thread-refusals.json")
        func refusal(_ name: String) throws -> FakeHTTPClient.Response {
            let entry = try #require(refusals[name] as? [String: Any])
            return .init(status: try #require(entry["status"] as? Int), headers: ["Content-Type": "application/json"],
                         body: try JSONSerialization.data(withJSONObject: try #require(entry["body"])))
        }
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let focus = ItemReference(try await Self.focus(store))

        let notFound = try refusal("notFound")
        server.thread { _ in notFound }
        await #expect(throws: ConnectorError.notFound) { try await connector.thread(of: focus) }
        let notAcceptable = try refusal("notAcceptable")
        server.thread { _ in notAcceptable }
        await #expect(throws: ConnectorError.unsupported) { try await connector.thread(of: focus) }
        let unavailable = try refusal("sourceUnavailable")
        server.thread { _ in unavailable }
        await #expect(throws: ConnectorError.badResponse("HTTP 502")) { try await connector.thread(of: focus) }
        let limited = try refusal("rateLimited")
        server.thread { _ in limited }
        await #expect(throws: ConnectorError.self) { try await connector.thread(of: focus) }
    }

    @Test func aRedirectIsNotFollowed() async throws {
        let server = try ThreadServer()
        let (http, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        server.thread { _ in .init(status: 302, headers: ["Location": "https://elsewhere.example.com/thread"]) }
        await #expect(throws: ConnectorError.self) { try await connector.thread(of: ItemReference(try await Self.focus(store))) }
        #expect(!http.requests.contains { $0.url?.host() != "example.com" })
    }

    @Test(arguments: [
        "another format", "another version", "another thread", "another focus", "a context post naming a thread",
        "a focus naming another thread", "a broken context post", "a repeated post", "an ancestor after the focus",
        "too many ancestors", "a gap of no known position",
    ])
    func aThreadThatBreaksTheContractIsRefusedWhole(_ fault: String) async throws {
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let answer = try server.recorded { body in
            var ancestors = try #require(body["ancestors"] as? [[String: Any]])
            var focus = try #require(body["focus"] as? [String: Any])
            switch fault {
            case "another format": body["format"] = "sammy.rich-feed"
            case "another version": body["version"] = 2
            case "another thread": body["ref"] = "contract-thread-2"
            case "another focus": focus["id"] = Self.repostID
            case "a context post naming a thread": ancestors[0]["thread"] = ["ref": "contract-thread-1"]
            case "a focus naming another thread": focus["thread"] = ["ref": "contract-thread-2"]
            case "a broken context post": ancestors[0]["url"] = "http://www.example.com/other/posts/61"
            case "a repeated post": ancestors[1] = ancestors[0]
            case "an ancestor after the focus": ancestors[1]["publishedAt"] = "2026-11-03T09:00:00Z"
            case "too many ancestors":
                ancestors = (0..<51).map { index in
                    var copy = ancestors[0]
                    copy["id"] = "urn:uuid:00000000-0000-4000-8000-\(String(format: "%012d", index))"
                    return copy
                }
            case "a gap of no known position": body["gaps"] = [["position": "elsewhere", "reason": "deleted"]]
            default: Issue.record("unknown fault \(fault)")
            }
            body["ancestors"] = ancestors
            body["focus"] = focus
        }
        server.thread { _ in answer }
        await #expect(throws: ConnectorError.self, "\(fault)") { try await connector.thread(of: ItemReference(try await Self.focus(store))) }
    }

    @Test func aThreadServedAsAnythingButRichIsRefused() async throws {
        let server = try ThreadServer()
        let (_, connector) = try Self.stored(server)
        let (store, _) = try await Self.refreshed(connector)
        let recorded = try server.recorded()
        server.thread { _ in .init(headers: ["Content-Type": "application/json"], body: recorded.body) }
        await #expect(throws: ConnectorError.badResponse("not a rich thread")) {
            try await connector.thread(of: ItemReference(try await Self.focus(store)))
        }
    }

    @Test func anUnknownGapReasonIsStillAGapAndRepeatsCountOnce() throws {
        let server = try ThreadServer()
        let body = try server.recorded { body in
            body["gaps"] = [["position": "continuations", "reason": "not-collected"], ["position": "continuations", "reason": "not-collected"],
                            ["position": "ancestors", "reason": "unavailable"], ["position": "ancestors", "reason": "withheld"]]
        }.body
        let thread = try RichThread.decode(body, ref: ThreadServer.ref, focusID: Self.threadID)
        #expect(thread.gaps == [PostThread.Gap(position: .replies, reason: .notCollected), PostThread.Gap(position: .ancestors, reason: .unavailable),
                                PostThread.Gap(position: .ancestors, reason: .other)])
    }

    @Test func theThreadsKeptAreBounded() async throws {
        let threads = SammyThreads()
        let server = try ThreadServer()
        let thread = try RichThread.decode(try server.recorded().body, ref: ThreadServer.ref, focusID: Self.threadID)
        for index in 0...SammyThreads.limit {
            await threads.keep(thread, etag: "W/\"rich-thread-v1-\(index)\"", for: .init(feedID: Self.feed, ref: "r\(index)"))
        }
        #expect(await threads.kept(.init(feedID: Self.feed, ref: "r0")) == nil)
        #expect(await threads.kept(.init(feedID: Self.feed, ref: "r\(SammyThreads.limit)"))?.etag == "W/\"rich-thread-v1-\(SammyThreads.limit)\"")
    }

    // MARK: References

    @Test func aThreadMediaReferenceSpellsItsThread() throws {
        let plain = try #require(SammyMediaReference(accountID: Self.account, feedID: Self.feed, mediaID: "m"))
        let threaded = try #require(SammyMediaReference(accountID: Self.account, feedID: Self.feed, mediaID: "m", thread: "t-1"))
        let preview = try #require(SammyMediaReference(accountID: Self.account, feedID: Self.feed, mediaID: "m", preview: true, thread: "t-1"))
        #expect(threaded.string == "sammy-media:\(Self.account)/\(Self.feed)/m?thread=t-1")
        #expect(preview.string == "sammy-media:\(Self.account)/\(Self.feed)/m?thread=t-1&variant=preview")
        for reference in [plain, threaded, preview] { #expect(SammyMediaReference(reference.string) == reference) }
        #expect(preview.original == threaded)
        // Only the one spelling reads back.
        for wrong in ["m?variant=preview&thread=t-1", "m?thread=", "m?thread=a b", "m?thread=t&thread=u", "m?other=1", "m?thread=t&"] {
            #expect(SammyMediaReference("sammy-media:\(Self.account)/\(Self.feed)/\(wrong)") == nil, "\(wrong)")
        }
        #expect(SammyMediaReference(accountID: Self.account, feedID: Self.feed, mediaID: "m", thread: String(repeating: "t", count: 257)) == nil)
    }
}

private extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
