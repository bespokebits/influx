import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

/// A clock a test moves by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) {
        value = date
    }

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

/// A Sammy server with a rich feed of media posts: the contract's media
/// page, a grant for any attachment on request, and the grants' bytes.
/// Each grant has a token of its own (`<media id>-<n>`) and lasts 15
/// minutes from the clock's time.
private final class MediaServer: @unchecked Sendable {
    static let feedPath = "/api/v1/feeds/\(RichFixtures.richFeedID)"
    static let body = Data((0..<64).map { UInt8($0) })

    let clock: TestClock
    private let lock = NSLock()
    private var granted: [String: Int] = [:]
    private var grantAnswer: (@Sendable (_ mediaID: String, _ request: URLRequest) -> FakeHTTPClient.Response?)?
    private var bytesAnswer: (@Sendable (_ token: String, _ request: URLRequest) -> FakeHTTPClient.Response?)?
    private let pageBody: Data

    init(clock: TestClock) throws {
        self.clock = clock
        pageBody = try RichFixtures.data("rich-feed-page-media.json")
    }

    /// Answers grant requests with `answer` where it gives one.
    func grants(_ answer: @escaping @Sendable (_ mediaID: String, _ request: URLRequest) -> FakeHTTPClient.Response?) {
        lock.withLock { grantAnswer = answer }
    }

    /// Answers byte requests with `answer` where it gives one.
    func bytes(_ answer: @escaping @Sendable (_ token: String, _ request: URLRequest) -> FakeHTTPClient.Response?) {
        lock.withLock { bytesAnswer = answer }
    }

    static func grant(url: String, expiresAt: Date) -> FakeHTTPClient.Response {
        let body = try! JSONSerialization.data(withJSONObject: ["url": url, "expiresAt": ISO8601DateFormatter().string(from: expiresAt)])
        return .init(headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: body)
    }

    func handler() throws -> @Sendable (URLRequest) throws -> FakeHTTPClient.Response {
        let pageHeaders = try RichFixtures.headers("page")
        return { [self] request in
            guard let url = request.url, url.host() == "example.com", url.scheme == "https", url.port == nil else { return .init(status: 404) }
            let path = url.path
            if path == Self.feedPath, request.httpMethod ?? "GET" == "GET" {
                return .init(headers: pageHeaders, body: pageBody)
            }
            let grantPrefix = "\(Self.feedPath)/media/"
            if path.hasPrefix(grantPrefix), path.hasSuffix("/grant"), request.httpMethod == "POST" {
                let mediaID = String(path.dropFirst(grantPrefix.count).dropLast("/grant".count))
                if let answer = lock.withLock({ grantAnswer })?(mediaID, request) { return answer }
                let count = lock.withLock { () -> Int in
                    granted[mediaID, default: 0] += 1
                    return granted[mediaID]!
                }
                return Self.grant(url: "https://example.com/api/v1/rich-media/\(mediaID)-\(count)", expiresAt: clock.now.addingTimeInterval(900))
            }
            if path.hasPrefix("/api/v1/rich-media/") {
                let token = String(path.dropFirst("/api/v1/rich-media/".count))
                if let answer = lock.withLock({ bytesAnswer })?(token, request) { return answer }
                return .init(headers: ["Content-Type": "image/jpeg", "Content-Length": "\(Self.body.count)"], body: Self.body)
            }
            return .init(status: 404)
        }
    }
}

private extension URLRequest {
    var isGrant: Bool { httpMethod == "POST" && url?.path.hasSuffix("/grant") == true }
    var isBytes: Bool { url?.path.hasPrefix("/api/v1/rich-media/") == true }
}

/// Counts how many requests are out at once, each taking a moment.
private final class SlowHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) throws -> FakeHTTPClient.Response
    private var inFlight = 0
    private(set) var mostAtOnce = 0

    init(_ handler: @escaping @Sendable (URLRequest) throws -> FakeHTTPClient.Response) {
        self.handler = handler
    }

    var most: Int { lock.withLock { mostAtOnce } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock {
            inFlight += 1
            mostAtOnce = max(mostAtOnce, inFlight)
        }
        try? await Task.sleep(for: .milliseconds(20))
        lock.withLock { inFlight -= 1 }
        let response = try handler(request)
        return (response.body, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!)
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

/// Holds each request until the test lets it through, in the order sent.
private final class GatedHTTPClient: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (URLRequest) throws -> FakeHTTPClient.Response
    private var held: [CheckedContinuation<Void, Never>] = []
    private var openings = 0
    private var sentRequests: [URLRequest] = []

    init(_ handler: @escaping @Sendable (URLRequest) throws -> FakeHTTPClient.Response) {
        self.handler = handler
    }

    /// Every request sent so far, held or not.
    var sent: [URLRequest] { lock.withLock { sentRequests } }

    /// Lets `count` more requests through: those held first, oldest first.
    func open(_ count: Int = 1) {
        let going = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            openings += count
            let going = Array(held.prefix(openings))
            held.removeFirst(going.count)
            openings -= going.count
            return going
        }
        going.forEach { $0.resume() }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await withCheckedContinuation { continuation in
            let go = lock.withLock { () -> Bool in
                sentRequests.append(request)
                guard openings > 0 else {
                    held.append(continuation)
                    return false
                }
                openings -= 1
                return true
            }
            if go { continuation.resume() }
        }
        let response = try handler(request)
        return (response.body, HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!)
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

/// Waits, a little at a time, until `condition` holds; fails after 5 seconds.
private func eventually(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<1000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("never happened", sourceLocation: sourceLocation)
}

@Suite struct SammyRichMediaTests {
    private static let token = "Bearer sao_contract-example-access-token"
    private static let imageID = "example-image-1", videoID = "example-video-1", gifID = "example-gif-1"

    private static func connector(_ http: any HTTPClient, clock: TestClock,
                                  credentials: InMemoryCredentialStore = InMemoryCredentialStore()) throws -> SammyFeedConnector {
        let session = RichFixtures.session()
        if try credentials.load(SammySession.self, for: session.accountID) == nil {
            try credentials.save(session, for: session.accountID)
        }
        let account = SammyAccount(session: session, http: http, credentials: credentials)
        // The grants themselves: direct sources are SammyDirectMediaTests'.
        return SammyFeedConnector(account: account, http: http, resolver: .testing(http), fetchLimit: RSSConnector.fetchLimit,
                                  addresses: AddressLookup { host in host == "example.com" ? [Self.serverAddress] : nil },
                                  now: { clock.now }, directSources: false)
    }

    /// Where the fake server's name points; a byte read connects here.
    private static let serverAddress: [UInt8] = [93, 184, 216, 34]

    private static func reference(_ mediaID: String, preview: Bool = false) -> SammyMediaReference {
        SammyMediaReference(accountID: RichFixtures.accountID, feedID: RichFixtures.richFeedID, mediaID: mediaID, preview: preview)!
    }

    /// A store holding the media page's post, refreshed through the
    /// connector as the app refreshes it.
    private static func stored(_ http: FakeHTTPClient, clock: TestClock) async throws -> (InfluxStore, SammyFeedConnector, Source) {
        let store = try InfluxStore.inMemory()
        let source = RichFixtures.source(.post)
        try await store.save(sources: [source])
        let connector = try connector(http, clock: clock)
        #expect(try await Refresher(store: store).refresh(source, with: connector, now: clock.now) == .fetched(newItems: 1))
        return (store, connector, source)
    }

    // MARK: The page

    @Test func eachAttachmentIsStoredAtItsSizeWithItsAltAndNoURL() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let (store, _, _) = try await Self.stored(http, clock: clock)

        let row = try #require(try await store.rows().first)
        #expect(row.body == "A post with a photo, a short clip and an animation. The words stand alone without them.")
        let account = "AbCdEfGhIjKlMnOpQrStUv@example.com", feed = RichFixtures.richFeedID
        #expect(row.media == [
            Item.Media(kind: .image, url: "sammy-media:\(account)/\(feed)/example-image-1", width: 1600, height: 900,
                       altText: "A lighthouse on a rocky shore at dusk.")!,
            Item.Media(kind: .video, url: "sammy-media:\(account)/\(feed)/example-video-1",
                       previewURL: "sammy-media:\(account)/\(feed)/example-video-1?variant=preview", width: 1280, height: 720,
                       altText: "Waves breaking against the lighthouse rocks.", durationMs: 15500)!,
            // No preview: the box is drawn as paper until it plays.
            Item.Media(kind: .gif, url: "sammy-media:\(account)/\(feed)/example-gif-1", width: 480, height: 480)!,
        ])
        // The boxes exist before any byte: only the page was asked for.
        #expect(http.requests.map { $0.url?.path } == [MediaServer.feedPath])
        // Each reference names the account, the feed and the attachment.
        let video = try #require(SammyMediaReference(row.media[1].url))
        #expect(video == Self.reference(Self.videoID))
        #expect(SammyMediaReference(try #require(row.media[1].previewURL)) == Self.reference(Self.videoID, preview: true))
        #expect(!row.media.contains { $0.url.contains("https:") || $0.previewURL?.contains("https:") == true })
    }

    @Test func postsWithoutMediaAreStoredAsBefore() async throws {
        let source = RichFixtures.source(.post)
        let page = try await RichFixtures.connector(try RichFixtures.pages()).fetch(RichFixtures.request(source), from: source)
        #expect(page.items.count == 2 && page.items.allSatisfy { $0.media.isEmpty })
        // Media without a duration encodes as it always did.
        let image = try #require(Item.Media(kind: .image, url: "https://www.example.com/a.jpg", width: 2, height: 1))
        let encoded = try #require(String(data: JSONEncoder().encode(image), encoding: .utf8))
        #expect(!encoded.contains("durationMs"))
        let old = Data(#"{"kind":"video","url":"https://www.example.com/v.mp4","width":2,"height":1}"#.utf8)
        #expect(try JSONDecoder().decode(Item.Media.self, from: old).durationMs == nil)
    }

    @Test func anAttachmentOfAKindThisBuildDoesNotKnowIsLeftOut() async throws {
        var item = try #require(try RichFixtures.object("rich-feed-page-media.json")["items"] as? [[String: Any]]).first!
        item["media"] = [
            ["id": "a1", "kind": "audio", "width": 0, "somethingNew": true],
            ["id": "i1", "kind": "image", "width": 16384, "height": 1, "alt": String(repeating: "é", count: 1500), "somethingNew": 1],
        ]
        let page = try RichFixtures.page("rich-feed-page-media.json") { $0["items"] = [item] }
        let source = RichFixtures.source(.post)
        let fetched = try await RichFixtures.connector(RichFixtures.answering(page, headers: try RichFixtures.headers("page")))
            .fetch(RichFixtures.request(source), from: source)
        let post = try #require(fetched.items.first)
        #expect(post.media.map { SammyMediaReference($0.url)?.mediaID } == ["i1"])
        #expect(post.media.first?.width == 16384 && post.media.first?.altText?.count == 1500)
    }

    // MARK: Grants

    @Test func theRecordedExchangeIsWhatThisBuildSendsAndReads() async throws {
        let recorded = try RichFixtures.object("rich-feed-media-grant.json")
        let grant = try #require(recorded["grant"] as? [String: Any])
        let request = try #require(grant["request"] as? [String: Any])
        let response = try #require(grant["response"] as? [String: Any])
        let bytes = try #require(recorded["bytes"] as? [String: Any])
        let urls = try #require(bytes["urls"] as? [String: String])
        let range = try #require(bytes["range"] as? [String: Any])
        let rangeHeader = try #require(((range["request"] as? [String: Any])?["headers"] as? [String: String])?["Range"])
        let rangeHeaders = try #require((range["response"] as? [String: Any])?["headers"] as? [String: String])
        let grantBody = try JSONSerialization.data(withJSONObject: try #require(response["body"]))
        let grantHeaders = try #require(response["headers"] as? [String: String])
        let endpoint = try #require(request["endpoint"] as? String)
        #expect(request["method"] as? String == "POST")
        #expect(bytes["pathPrefix"] as? String == SammyMediaGrants.grantPath)

        let http = FakeHTTPClient { sent in
            switch (sent.httpMethod ?? "GET", sent.url?.absoluteString) {
            case ("POST", endpoint): return .init(headers: grantHeaders, body: grantBody)
            case ("GET", urls["preview"]), ("GET", urls["original"]):
                guard sent.value(forHTTPHeaderField: "Range") == rangeHeader else { return .init(status: 400) }
                return .init(status: 206, headers: rangeHeaders, body: Data(count: 1024))
            default: return .init(status: 404)
            }
        }
        // Before the recorded grant expires.
        let clock = TestClock(FeedDate.iso8601("2026-11-03T12:00:00Z")!)
        let media = try Self.connector(http, clock: clock).media
        let answer = try await media.fetch(Self.reference(Self.videoID, preview: true), bytes: 0...1023, upTo: 4096, timeout: .seconds(5))
        #expect(answer.statusCode == 206 && answer.data.count == 1024 && answer.totalLength == 4096 && answer.contentType == "video/mp4")
        _ = try await media.fetch(Self.reference(Self.videoID), bytes: 0...1023, upTo: 4096, timeout: .seconds(5))

        // One grant for both, asked for with the credential and no body;
        // the bytes with no credential at all.
        let sent = http.requests
        #expect(sent.map { "\($0.httpMethod ?? "GET") \($0.url?.absoluteString ?? "")" } == [
            "POST \(endpoint)", "GET \(urls["preview"]!)", "GET \(urls["original"]!)",
        ])
        #expect(sent[0].value(forHTTPHeaderField: "Authorization") == Self.token && sent[0].httpBody == nil)
        #expect(sent.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    @Test func theCredentialGoesOnlyToTheAccountsOwnServer() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let media = try Self.connector(http, clock: clock).media
        #expect(try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5)) == MediaServer.body)
        #expect(http.requests.allSatisfy { $0.url?.host() == "example.com" && $0.url?.scheme == "https" })
        #expect(http.requests.filter { $0.value(forHTTPHeaderField: "Authorization") != nil }.allSatisfy { $0.isGrant })
        #expect(http.requests.filter(\.isBytes).count == 1)
        // The bytes come over a connection of their own to the server's
        // address, which stops reading at the limit.
        #expect(http.addresses == [Self.serverAddress])

        // Another account's attachment is never asked for with this one's.
        let other = try #require(SammyMediaReference(accountID: "someone@example.com", feedID: RichFixtures.richFeedID, mediaID: Self.imageID))
        let sent = http.requests.count
        await #expect(throws: ConnectorError.notFound) {
            try await media.data(for: other, upTo: 1024, timeout: .seconds(5))
        }
        #expect(http.requests.count == sent)
    }

    @Test func aGrantOffTheAccountsServerIsRefusedAndNothingIsSentToIt() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let media = try Self.connector(http, clock: clock).media
        let elsewhere = [
            "https://media.example.com/api/v1/rich-media/x", "http://example.com/api/v1/rich-media/x",
            "https://example.com:8443/api/v1/rich-media/x", "https://user@example.com/api/v1/rich-media/x",
            "https://example.com/api/v1/feeds/x", "https://example.com/api/v1/rich-media/", "https://example.com/api/v1/rich-media/x?a=b",
            "/api/v1/rich-media/x",
            // Out of the media path once a server resolves it.
            "https://example.com/api/v1/rich-media/../private", "https://example.com/api/v1/rich-media/%2e%2e/private",
            "https://example.com/api/v1/rich-media/x/../../private", "https://example.com/api/v1/rich-media/x%2F..%2F..",
        ]
        for url in elsewhere {
            server.grants { _, _ in MediaServer.grant(url: url, expiresAt: clock.now.addingTimeInterval(900)) }
            await #expect(throws: ConnectorError.badResponse("a media grant off the account's server"), "\(url)") {
                try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5))
            }
        }
        // A grant that has already expired, or says nothing, is refused too.
        server.grants { _, _ in MediaServer.grant(url: "https://example.com/api/v1/rich-media/x", expiresAt: clock.now) }
        await #expect(throws: ConnectorError.badResponse("a media grant with no time left")) {
            try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5))
        }
        server.grants { _, _ in .init(headers: ["Content-Type": "application/json"], text: "{}") }
        await #expect(throws: ConnectorError.badResponse("not a media grant")) {
            try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5))
        }
        #expect(http.requests.allSatisfy { $0.url?.host() == "example.com" && $0.url?.port == nil })
        #expect(!http.requests.contains { $0.isBytes })
    }

    @Test func aGrantIsKeptUntilShortlyBeforeItExpires() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let media = try Self.connector(http, clock: clock).media
        func read(_ reference: SammyMediaReference) async throws { _ = try await media.data(for: reference, upTo: 1024, timeout: .seconds(5)) }

        // The attachment and its preview share one grant, and other
        // attachments have their own.
        try await read(Self.reference(Self.videoID, preview: true))
        try await read(Self.reference(Self.videoID))
        try await read(Self.reference(Self.imageID))
        #expect(http.requests.filter(\.isGrant).count == 2)
        #expect(http.requests.filter(\.isBytes).map { $0.url?.absoluteString } == [
            "https://example.com/api/v1/rich-media/example-video-1-1?variant=preview",
            "https://example.com/api/v1/rich-media/example-video-1-1",
            "https://example.com/api/v1/rich-media/example-image-1-1",
        ])
        // Kept while it has more than the margin left.
        clock.advance(900 - SammyMediaGrants.renewalMargin - 1)
        try await read(Self.reference(Self.videoID))
        #expect(http.requests.filter(\.isGrant).count == 2)
        // Then asked for again before it can expire mid-read.
        clock.advance(2)
        try await read(Self.reference(Self.videoID))
        #expect(http.requests.filter(\.isGrant).count == 3)
        #expect(http.requests.last?.url?.path == "/api/v1/rich-media/example-video-1-2")
    }

    @Test func aGoneGrantIsRenewedOnceAndThenTheAttachmentIsGone() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let media = try Self.connector(http, clock: clock).media
        let reference = Self.reference(Self.imageID)

        // A 410 from the first grant: one new grant, and the read works.
        server.bytes { token, _ in token == "example-image-1-1" ? .init(status: 410, text: #"{"error":"Media grant expired"}"#) : nil }
        #expect(try await media.data(for: reference, upTo: 1024, timeout: .seconds(5)) == MediaServer.body)
        #expect(http.requests.filter(\.isGrant).count == 2)
        // The new grant is the one kept.
        _ = try await media.data(for: reference, upTo: 1024, timeout: .seconds(5))
        #expect(http.requests.filter(\.isGrant).count == 2)

        // A 404 from every grant: renewed once, then the attachment is gone.
        server.bytes { _, _ in .init(status: 404, text: #"{"error":"Not found"}"#) }
        let before = http.requests.count
        await #expect(throws: ConnectorError.notFound) {
            try await media.data(for: reference, upTo: 1024, timeout: .seconds(5))
        }
        let sent = http.requests.dropFirst(before)
        #expect(sent.filter(\.isBytes).count == 2 && sent.filter(\.isGrant).count == 1)
        // A grant refused with a 404 is an attachment that is gone.
        server.grants { _, _ in .init(status: 404, text: #"{"error":"Not found"}"#) }
        await #expect(throws: ConnectorError.notFound) {
            try await media.data(for: Self.reference(Self.gifID), upTo: 1024, timeout: .seconds(5))
        }
    }

    @Test func a429HoldsEveryRequestBackUntilItsRetryAfter() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let media = try Self.connector(http, clock: clock).media
        let busy = FakeHTTPClient.Response(status: 429, headers: ["Retry-After": "30"], text: #"{"error":"Too many requests"}"#)

        server.bytes { _, _ in busy }
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(30))) {
            try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5))
        }
        // Held back: nothing is sent, for this attachment or any other.
        server.bytes { _, _ in nil }
        let sent = http.requests.count
        clock.advance(29)
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(1))) {
            try await media.data(for: Self.reference(Self.videoID), upTo: 1024, timeout: .seconds(5))
        }
        #expect(http.requests.count == sent)
        // Once it allows, reads go on.
        clock.advance(2)
        #expect(try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5)) == MediaServer.body)

        // A 429 on a grant holds back the same way; with no Retry-After,
        // for the first wait.
        server.grants { _, _ in .init(status: 429, text: #"{"error":"Too many requests"}"#) }
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(SammyMediaGrants.firstBackoff))) {
            try await media.data(for: Self.reference(Self.gifID), upTo: 1024, timeout: .seconds(5))
        }
        let held = http.requests.count
        _ = try? await media.data(for: Self.reference(Self.gifID), upTo: 1024, timeout: .seconds(5))
        #expect(http.requests.count == held)
    }

    @Test func noMoreThanTheServersStreamLimitIsOutAtOnce() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = SlowHTTPClient(try server.handler())
        let media = try Self.connector(http, clock: clock).media
        let ids = (0..<10).map { "m\($0)" }
        try await withThrowingTaskGroup(of: Data.self) { group in
            for id in ids {
                group.addTask { try await media.data(for: Self.reference(id), upTo: 1024, timeout: .seconds(10)) }
            }
            for try await data in group { #expect(data == MediaServer.body) }
        }
        #expect(http.most <= SammyMediaGrants.streams)
        #expect(http.most > 1)
    }

    // MARK: Authors' pictures (ADR 0039)

    /// The grants alone, counting into `tally`.
    private static func grants(_ http: any HTTPClient, clock: TestClock, tally: SammyMediaTally = SammyMediaTally()) throws -> SammyMediaGrants {
        let session = RichFixtures.session()
        let credentials = InMemoryCredentialStore()
        try credentials.save(session, for: session.accountID)
        return SammyMediaGrants(account: SammyAccount(session: session, http: http, credentials: credentials), http: http,
                                addresses: AddressLookup { host in host == "example.com" ? [Self.serverAddress] : nil },
                                now: { clock.now }, tally: tally, directSources: false)
    }

    private static func grantID(_ request: URLRequest) -> String? {
        guard request.isGrant, let path = request.url?.path else { return nil }
        return path.split(separator: "/").dropLast().last.map(String.init)
    }

    @Test func picturesHoldAtMostTheirSlotsAndAttachmentsStillGetTheRest() async throws {
        let clock = TestClock(RichFixtures.now)
        let http = GatedHTTPClient(try MediaServer(clock: clock).handler())
        let media = try Self.grants(http, clock: clock)
        let pictures = (0..<6).map { id in
            Task { try await media.data(for: Self.reference("p\(id)"), upTo: 1024, timeout: .seconds(10), kind: .avatar) }
        }
        await eventually {
            await media.waitingForSlots.avatars == 6 - SammyMediaGrants.avatarStreams && http.sent.count == SammyMediaGrants.avatarStreams
        }
        // An attachment goes out while the pictures wait.
        let attachment = Task { try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(10)) }
        await eventually { http.sent.count == SammyMediaGrants.avatarStreams + 1 }
        #expect(Self.grantID(http.sent.last!) == Self.imageID)

        http.open(100)
        #expect(try await attachment.value == MediaServer.body)
        for picture in pictures { #expect(try await picture.value == MediaServer.body) }
    }

    @Test func anAttachmentWaitingForASlotGoesBeforeAPicture() async throws {
        let clock = TestClock(RichFixtures.now)
        let http = GatedHTTPClient(try MediaServer(clock: clock).handler())
        let media = try Self.grants(http, clock: clock)
        // Four attachments hold every slot.
        let first = (0..<SammyMediaGrants.streams).map { id in
            Task { try await media.data(for: Self.reference("a\(id)"), upTo: 1024, timeout: .seconds(10)) }
        }
        await eventually { http.sent.count == SammyMediaGrants.streams }
        let picture = Task { try await media.data(for: Self.reference("p0"), upTo: 1024, timeout: .seconds(10), kind: .avatar) }
        await eventually { await media.waitingForSlots.avatars == 1 }
        let later = Task { try await media.data(for: Self.reference("a9"), upTo: 1024, timeout: .seconds(10)) }
        await eventually { await media.waitingForSlots.attachments == 1 }

        // The first slot freed goes to the attachment that came later.
        http.open(1)
        await eventually { http.sent.count == SammyMediaGrants.streams + 1 }
        #expect(Self.grantID(http.sent.last!) == "a9")

        http.open(100)
        for task in first + [later, picture] { #expect(try await task.value == MediaServer.body) }
    }

    @Test func a429OnAPictureHoldsBackOnlyPictures() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let tally = SammyMediaTally()
        let media = try Self.grants(http, clock: clock, tally: tally)
        let busy = FakeHTTPClient.Response(status: 429, headers: ["Retry-After": "30"], text: #"{"error":"Too many requests"}"#)
        func picture(_ id: String) async throws -> Data {
            try await media.data(for: Self.reference(id), upTo: 1024, timeout: .seconds(5), kind: .avatar)
        }

        server.grants { id, _ in id == "p1" ? busy : nil }
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(30))) { try await picture("p1") }
        // Other pictures wait, sending nothing.
        let sent = http.requests.count
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(30))) { try await picture("p2") }
        #expect(http.requests.count == sent)
        // Attachments don't.
        #expect(try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5)) == MediaServer.body)

        // A 429 on an attachment holds back both.
        server.grants { id, _ in id == Self.gifID ? .init(status: 429, text: #"{"error":"Too many requests"}"#) : nil }
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(SammyMediaGrants.firstBackoff))) {
            try await media.data(for: Self.reference(Self.gifID), upTo: 1024, timeout: .seconds(5))
        }
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(SammyMediaGrants.firstBackoff))) {
            try await media.data(for: Self.reference(Self.videoID), upTo: 1024, timeout: .seconds(5))
        }
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(30))) { try await picture("p3") }

        // Each is counted, by kind.
        #expect(tally.counts.avatar == .init(grants: 1, grantsRateLimited: 1, heldBack: 2))
        #expect(tally.counts.attachment == .init(grants: 2, grantsRateLimited: 1, heldBack: 1))
    }

    @Test func picturesSpendAnAllowanceThatComesBackOverTime() async throws {
        let clock = TestClock(RichFixtures.now)
        let http = FakeHTTPClient(try MediaServer(clock: clock).handler())
        let tally = SammyMediaTally()
        let media = try Self.grants(http, clock: clock, tally: tally)
        func picture(_ id: String) async throws -> Data {
            try await media.data(for: Self.reference(id), upTo: 1024, timeout: .seconds(5), kind: .avatar)
        }
        let burst = Int(SammyMediaGrants.Allowance.burst)
        for id in 0..<burst { #expect(try await picture("p\(id)") == MediaServer.body) }
        #expect(http.requests.filter(\.isGrant).count == burst)

        // Spent: the next picture asks for nothing until a grant comes back.
        let next = 3600 / SammyMediaGrants.Allowance.perHour
        await #expect(throws: ConnectorError.rateLimited(retryAfter: clock.now.addingTimeInterval(next))) { try await picture("p\(burst)") }
        #expect(http.requests.filter(\.isGrant).count == burst)
        // A picture whose grant is kept needs none, and attachments have no allowance.
        #expect(try await picture("p0") == MediaServer.body)
        #expect(try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5)) == MediaServer.body)
        #expect(http.requests.filter(\.isGrant).count == burst + 1)

        clock.advance(next)
        #expect(try await picture("p\(burst)") == MediaServer.body)
        #expect(tally.counts.avatar == .init(grants: burst + 1, deferred: 1))
        #expect(tally.counts.attachment == .init(grants: 1))
    }

    @Test func aGrantNoOneWaitsForAnyMoreIsNeverSent() async throws {
        let clock = TestClock(RichFixtures.now)
        let http = GatedHTTPClient(try MediaServer(clock: clock).handler())
        let tally = SammyMediaTally()
        let media = try Self.grants(http, clock: clock, tally: tally)
        let first = (0..<SammyMediaGrants.streams).map { id in
            Task { try await media.data(for: Self.reference("a\(id)"), upTo: 1024, timeout: .seconds(10)) }
        }
        await eventually { http.sent.count == SammyMediaGrants.streams }
        let picture = Task { try await media.data(for: Self.reference("p0"), upTo: 1024, timeout: .seconds(10), kind: .avatar) }
        await eventually { await media.waitingForSlots.avatars == 1 }
        // Its row scrolled away.
        picture.cancel()
        await eventually { await media.asksOut == SammyMediaGrants.streams }

        http.open(100)
        for task in first { #expect(try await task.value == MediaServer.body) }
        await eventually { await media.waitingForSlots.avatars == 0 }
        _ = try? await picture.value
        #expect(!http.sent.contains { $0.url?.path.contains("/p0") == true })
        #expect(tally.counts.avatar == .init())
    }

    @Test func aGrantAlreadySentIsJoinedEvenOnceNoOneWaitsForIt() async throws {
        let clock = TestClock(RichFixtures.now)
        let http = GatedHTTPClient(try MediaServer(clock: clock).handler())
        let tally = SammyMediaTally()
        let media = try Self.grants(http, clock: clock, tally: tally)
        let first = Task { try await media.data(for: Self.reference("p0"), upTo: 1024, timeout: .seconds(10), kind: .avatar) }
        await eventually { http.sent.count == 1 }
        // Its row scrolled away while the grant was out; then it came back.
        first.cancel()
        _ = try? await first.value
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await media.asksOut == 1)
        let again = Task { try await media.data(for: Self.reference("p0"), upTo: 1024, timeout: .seconds(10), kind: .avatar) }

        http.open(100)
        #expect(try await again.value == MediaServer.body)
        #expect(http.sent.filter(\.isGrant).count == 1)
        #expect(tally.counts.avatar.grants == 1)
    }

    @Test func anAttachmentNeverJoinsAPicturesPendingAsk() async throws {
        let clock = TestClock(RichFixtures.now)
        let http = GatedHTTPClient(try MediaServer(clock: clock).handler())
        let media = try Self.grants(http, clock: clock)
        // Two pictures hold the pictures' slots; a third, with the same
        // media ID as an attachment, waits for one.
        let pictures = ["p0", "p1", "shared"].map { id in
            Task { try await media.data(for: Self.reference(id), upTo: 1024, timeout: .seconds(10), kind: .avatar) }
        }
        await eventually { await media.waitingForSlots.avatars == 1 && http.sent.count == SammyMediaGrants.avatarStreams }
        // The attachment asks on its own, at once.
        let attachment = Task { try await media.data(for: Self.reference("shared"), upTo: 1024, timeout: .seconds(10)) }
        await eventually { http.sent.count == SammyMediaGrants.avatarStreams + 1 }
        #expect(Self.grantID(http.sent.last!) == "shared")

        http.open(100)
        #expect(try await attachment.value == MediaServer.body)
        for picture in pictures { #expect(try await picture.value == MediaServer.body) }
    }

    @Test func aRevokedCredentialFailsTheGrantAsItFailsAFeedRead() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let (store, connector, source) = try await Self.stored(http, clock: clock)
        let rows = try await store.rows()

        // Revoked on the server: every request with the token is refused.
        let serving = try server.handler()
        http.respond { request in
            request.value(forHTTPHeaderField: "Authorization") != nil ? .init(status: 401, text: #"{"error":"Unauthorized"}"#) : try serving(request)
        }
        await #expect(throws: ConnectorError.unauthorized) {
            try await connector.media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5))
        }
        #expect(try await Refresher(store: store).refresh(source, with: connector, now: clock.now) == .failed(.unauthorized))
        #expect(try await store.fetchState(sourceID: source.id)?.problem == .signedOut)
        // No bytes were asked for, and the post keeps its boxes.
        #expect(!http.requests.contains { $0.isBytes })
        #expect(try await store.rows() == rows)
    }

    @Test func aGrantRefusedWithAnOldTokenIsAskedAgainWithTheOneAnotherDeviceStored() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let serving = try server.handler()
        let http = FakeHTTPClient { request in
            request.isGrant && request.value(forHTTPHeaderField: "Authorization") != "Bearer sao_newer" ? .init(status: 401) : try serving(request)
        }
        let credentials = InMemoryCredentialStore()
        let media = try Self.connector(http, clock: clock, credentials: credentials).media
        var newer = RichFixtures.session()
        newer.accessToken = "sao_newer"
        try credentials.save(newer, for: newer.accountID)

        #expect(try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5)) == MediaServer.body)
        #expect(http.requests.filter(\.isGrant).map { $0.value(forHTTPHeaderField: "Authorization") } == [Self.token, "Bearer sao_newer"])
    }

    @Test func aBodyCutShortIsAFailedRead() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let media = try Self.connector(http, clock: clock).media

        server.bytes { _, _ in .init(headers: ["Content-Type": "image/jpeg", "Content-Length": "100"], body: Data(count: 50)) }
        await #expect(throws: ConnectorError.badResponse("a body shorter than its length")) {
            try await media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5))
        }
        server.bytes { _, _ in .init(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-1023/4096"], body: Data(count: 10)) }
        await #expect(throws: ConnectorError.badResponse("a body shorter than its range")) {
            try await media.fetch(Self.reference(Self.videoID), bytes: 0...1023, upTo: 1024, timeout: .seconds(5))
        }
        // A range nobody asked for isn't taken as the whole file.
        await #expect(throws: ConnectorError.badResponse("a range that wasn't asked for")) {
            try await media.data(for: Self.reference(Self.videoID), upTo: 1024, timeout: .seconds(5))
        }
        // Nor is one starting elsewhere, or running past the end asked for,
        // whose bytes a player would put in the wrong place.
        await #expect(throws: ConnectorError.badResponse("a range that wasn't asked for")) {
            try await media.fetch(Self.reference(Self.videoID), bytes: 1024...2047, upTo: 1024, timeout: .seconds(5))
        }
        server.bytes { _, _ in .init(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-2047/4096"], body: Data(count: 2048)) }
        await #expect(throws: ConnectorError.badResponse("a range that wasn't asked for")) {
            try await media.fetch(Self.reference(Self.videoID), bytes: 0...1023, upTo: 1024, timeout: .seconds(5))
        }
        // A whole file sent for a range is the file, from its start.
        server.bytes { _, _ in .init(headers: ["Content-Type": "video/mp4", "Content-Length": "64"], body: MediaServer.body) }
        let whole = try await media.fetch(Self.reference(Self.videoID), bytes: 0...1, upTo: 1024, timeout: .seconds(5))
        #expect(whole.statusCode == 200 && whole.totalLength == 64)
        // At most the limit comes back, so a caller can tell an oversized body.
        #expect(try await media.data(for: Self.reference(Self.imageID), upTo: 10, timeout: .seconds(5)).count == 10)
    }

    @Test func aMissingAttachmentLeavesThePostAndTheReadingPlaceAndComesBackLater() async throws {
        let clock = TestClock(RichFixtures.now)
        let server = try MediaServer(clock: clock)
        let http = FakeHTTPClient(try server.handler())
        let (store, connector, _) = try await Self.stored(http, clock: clock)
        let row = try #require(try await store.rows().first)
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (row.sortDate, row.mergeKey), at: clock.now))
        let rows = try await store.rows()
        let marker = try await store.lastReadMarker(viewID: SavedView.allID)

        server.grants { _, _ in .init(status: 502, text: #"{"error":"Feed source unavailable"}"#) }
        await #expect(throws: ConnectorError.badResponse("HTTP 502")) {
            try await connector.media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5))
        }
        #expect(try await store.rows() == rows)
        #expect(try await store.lastReadMarker(viewID: SavedView.allID) == marker)

        // A later load, once the server is back, gets the bytes.
        server.grants { _, _ in nil }
        #expect(try await connector.media.data(for: Self.reference(Self.imageID), upTo: 1024, timeout: .seconds(5)) == MediaServer.body)
        #expect(try await store.rows() == rows)
    }

    // MARK: References

    @Test func referencesReadBackExactlyAndNothingElseIsOne() throws {
        let withPort = try #require(SammyMediaReference(accountID: "abc@example.com:8443", feedID: "feed-1", mediaID: "A_b-9", preview: true))
        #expect(withPort.string == "sammy-media:abc@example.com%3A8443/feed-1/A_b-9?variant=preview")
        #expect(SammyMediaReference(withPort.string) == withPort)
        #expect(withPort.original.string == "sammy-media:abc@example.com%3A8443/feed-1/A_b-9")
        for string in [
            "https://example.com/api/v1/rich-media/x", "sammy-media:", "sammy-media:a@example.com/feed", "sammy-media:a@example.com/feed/m/x",
            "sammy-media:a@example.com/feed/m?variant=other", "sammy-media:a@example.com/feed/m?", "sammy-media:/feed/m",
            "sammy-media:a@example.com/../m", "sammy-media:a@example.com/feed/a.b", "sammy-media:a%40example.com/feed/m",
            "sammy-media:a@example.com:8443/feed/m",
        ] {
            #expect(SammyMediaReference(string) == nil, "\(string)")
        }
    }
}
