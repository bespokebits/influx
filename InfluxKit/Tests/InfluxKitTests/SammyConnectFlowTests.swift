import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

/// The contract files a connection is checked against: what the server
/// sends, and the revocation it expects.
private enum Files {
    static let origin = "https://example.com"
    static let subject = "AbCdEfGhIjKlMnOpQrStUv"
    static let accountID = "\(subject)@example.com"

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/SammyContract"))
        return try Data(contentsOf: url)
    }

    static func object(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }

    static func body(_ name: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: try #require(object(name)["body"]))
    }

    /// The feed list for the contract account with no feeds in it.
    static func emptyList() throws -> Data {
        var list = try #require(try JSONSerialization.jsonObject(with: data("feed-list-oauth.json")) as? [String: Any])
        list["feeds"] = []
        return try JSONSerialization.data(withJSONObject: list)
    }

    /// A Sammy server answering from the contract files, on any host, with
    /// `list` as the account's feed list.
    static func server(list: Data? = nil) throws -> FakeHTTPClient {
        let metadata = try data("oauth-authorization-server.json")
        let token = try body("token-response.json")
        let list = try list ?? data("feed-list-oauth.json")
        return FakeHTTPClient { request in
            guard request.url?.host() == "example.com" else { return .init(status: 404) }
            switch request.url?.path {
            case "/.well-known/oauth-authorization-server": return .init(body: metadata)
            case "/oauth/token": return .init(body: token)
            case "/oauth/revoke": return .init()
            case "/api/v1/feeds": return .init(headers: ["Content-Type": "application/json"], body: list)
            default: return .init(status: 404)
            }
        }
    }

    /// The approved callback from the contract, carrying the state of the
    /// sign-in `authorizeURL` began.
    static func approved(for authorizeURL: URL) throws -> URL {
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        let address = try #require(object("callback-approved.json")["url"] as? String)
        var callback = try #require(URLComponents(string: address))
        callback.queryItems = callback.queryItems?.map { $0.name == "state" ? URLQueryItem(name: "state", value: state) : $0 }
        return try #require(callback.url)
    }

    /// Every revocation `http` was sent is exactly the recorded one.
    static func expectRecordedRevokes(_ http: FakeHTTPClient, count: Int = 1, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let recorded = try object("revoke-request.json")
        let revokes = http.requests.filter { $0.url?.path == "/oauth/revoke" }
        #expect(revokes.count == count, sourceLocation: sourceLocation)
        for sent in revokes {
            #expect(sent.httpMethod == recorded["method"] as? String, sourceLocation: sourceLocation)
            #expect(sent.url?.absoluteString == recorded["endpoint"] as? String, sourceLocation: sourceLocation)
            #expect(sent.value(forHTTPHeaderField: "Content-Type") == recorded["contentType"] as? String, sourceLocation: sourceLocation)
            #expect(String(decoding: sent.httpBody ?? Data(), as: UTF8.self) == recorded["body"] as? String, sourceLocation: sourceLocation)
        }
    }
}

/// A source store whose writes fail, for a save that can't finish.
private struct FailingSources: SammyFlowSources {
    struct Refused: Error {}
    func allSources() async throws -> [Source] { [] }
    func apply(adding sources: [Source], removing: [String]) async throws { throw Refused() }
    func remove(sourceID: String) async throws { throw Refused() }
}

/// A credential store whose reads can be made to fail, as a locked or
/// unavailable keychain's do.
private final class FlakyCredentials: CredentialStore, @unchecked Sendable {
    struct Unreadable: Error {}
    let inner = InMemoryCredentialStore()
    private let lock = NSLock()
    private var _failsReads = false
    var failsReads: Bool {
        get { lock.withLock { _failsReads } }
        set { lock.withLock { _failsReads = newValue } }
    }

    func data(for account: String) throws -> Data? {
        if failsReads { throw Unreadable() }
        return try inner.data(for: account)
    }
    func setData(_ data: Data, for account: String) throws { try inner.setData(data, for: account) }
    func deleteData(for account: String) throws { try inner.deleteData(for: account) }
    func accounts() throws -> [String] { try inner.accounts() }
}

/// Reads through to a real store, then fails the write, as a store
/// whose transaction is rolled back does.
private struct FailingAfterReads: SammyFlowSources {
    let inner: InfluxStore
    func allSources() async throws -> [Source] { try await inner.allSources() }
    func apply(adding sources: [Source], removing: [String]) async throws { throw FailingSources.Refused() }
    func remove(sourceID: String) async throws { try await inner.remove(sourceID: sourceID) }
}

/// A store whose writes take a moment, so a save can be cancelled while
/// it runs.
private struct SlowSources: SammyFlowSources {
    let inner: InfluxStore
    func allSources() async throws -> [Source] { try await inner.allSources() }
    func apply(adding sources: [Source], removing: [String]) async throws {
        try await Task.sleep(for: .milliseconds(400))
        try await inner.apply(adding: sources, removing: removing)
    }
    func remove(sourceID: String) async throws { try await inner.remove(sourceID: sourceID) }
}

/// Holds the feed list back for a moment, so a sign-in can be cancelled
/// while it is being finished.
private struct SlowListClient: HTTPClient {
    let inner: FakeHTTPClient

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await inner.send(request) }
    func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
        try await inner.send(request, upTo: limit, at: address)
    }
    func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        try await inner.send(request, followingRedirectsOnlyTo: allowed)
    }
    func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path == "/api/v1/feeds" { try await Task.sleep(for: .milliseconds(400)) }
        return try await inner.sendRefusingRedirects(request)
    }
}

private struct Setup {
    let http: FakeHTTPClient
    let credentials = InMemoryCredentialStore()
    let store: InfluxStore
    let flow: SammyConnectFlow

    init(list: Data? = nil, sources: (any SammyFlowSources)? = nil, client: ((FakeHTTPClient) -> any HTTPClient)? = nil) throws {
        http = try Files.server(list: list)
        store = try InfluxStore.inMemory()
        let signIn = SammySignIn(http: client?(http) ?? http, crypto: .fake(), credentials: credentials)
        flow = SammyConnectFlow(connector: signIn, credentials: credentials, sources: sources ?? store)
    }

    /// Begins on the contract server and comes back approved.
    func connect() async throws -> SammyConnectFlow.Offer {
        let page = try await flow.begin(server: Files.origin)
        return try await flow.complete(callbackURL: Files.approved(for: page))
    }

    var stored: SammySession? { get throws { try credentials.load(SammySession.self, for: Files.accountID) } }

    func sammySources() async throws -> [Source] {
        try await store.sources().filter { $0.kind == .sammyFeed }
    }
}

@Suite struct SammyConnectFlowTests {
    // MARK: The address

    @Test func theAddressStartsAsThePublicServiceAndCanBeChanged() async throws {
        #expect(SammyConnectFlow.defaultServer == "api.heysammy.app")
        #expect(SammyOAuth.serverURL(from: SammyConnectFlow.defaultServer)?.absoluteString == "https://api.heysammy.app")
        let setup = try Setup()
        // Left as it is, the public service is asked.
        await #expect(throws: SammySignInError.self) { try await setup.flow.begin() }
        #expect(setup.http.requests.first?.url?.absoluteString == "https://api.heysammy.app/.well-known/oauth-authorization-server")
        // Changed, the server typed is the one asked, normalised the same way.
        let page = try await setup.flow.begin(server: " Example.COM/ ")
        #expect(setup.http.requests.last?.url?.absoluteString == "https://example.com/.well-known/oauth-authorization-server")
        #expect(page.host() == "example.com")
        await #expect(throws: SammySignInError.notAnAddress) { try await setup.flow.begin(server: "http://example.com") }
    }

    // MARK: Connecting

    @Test func finishingTheSignInSavesNothingUntilFeedsAreTicked() async throws {
        let setup = try Setup()
        let offer = try await setup.connect()
        #expect(offer.accountID == Files.accountID)
        #expect(offer.feeds.map(\.title) == ["Movies: first scores", "New TV: first scores"])
        // A first connection starts with every feed ticked.
        #expect(offer.ticked == Set(offer.feeds.map(\.id)))
        #expect(try setup.stored == nil)
        #expect(try await setup.sammySources().isEmpty)

        let session = try await setup.flow.save(selected: [offer.feeds[0].id])
        #expect(session.accountID == Files.accountID)
        #expect(try setup.stored?.accessToken == "sao_contract-example-access-token")
        let saved = try await setup.sammySources()
        #expect(saved.map(\.id) == [offer.feeds[0].id])
        #expect(saved[0].colorIndex == Source.colorIndex(for: offer.feeds[0].id))
        #expect(!setup.http.requests.contains { $0.url?.path == "/oauth/revoke" })
    }

    @Test func savingRefusesAnEmptySelection() async throws {
        let setup = try Setup()
        let offer = try await setup.connect()
        await #expect(throws: SammyConnectFlow.FlowError.nothingSelected) { try await setup.flow.save(selected: []) }
        await #expect(throws: SammyConnectFlow.FlowError.nothingSelected) { try await setup.flow.save(selected: ["sammy:someone-else:feed:x"]) }
        #expect(try setup.stored == nil)
        #expect(try await setup.sammySources().isEmpty)
        // Nothing ended, so the reader can still tick a feed.
        try await setup.flow.save(selected: Set(offer.feeds.map(\.id)))
        #expect(try await setup.sammySources().count == 2)
    }

    @Test func cancellingAfterTheTokenWasGrantedRevokesItAndLeavesNoCredential() async throws {
        let setup = try Setup()
        _ = try await setup.connect()
        await setup.flow.cancel()
        try Files.expectRecordedRevokes(setup.http)
        #expect(try setup.stored == nil)
        #expect(try await setup.sammySources().isEmpty)
        await #expect(throws: SammyConnectFlow.FlowError.notStarted) { try await setup.flow.save(selected: ["x"]) }
    }

    @Test func cancellingBeforeTheBrowserCameBackSendsNothing() async throws {
        let setup = try Setup()
        _ = try await setup.flow.begin(server: Files.origin)
        await setup.flow.cancel()
        #expect(!setup.http.requests.contains { ["/oauth/token", "/oauth/revoke"].contains($0.url?.path) })
        #expect(try setup.stored == nil)
    }

    @Test func aCallbackFinishedAfterCancellingIsRevoked() async throws {
        let setup = try Setup(client: { SlowListClient(inner: $0) })
        let page = try await setup.flow.begin(server: Files.origin)
        let callback = try Files.approved(for: page)
        let finishing = Task { try await setup.flow.complete(callbackURL: callback) }
        try await Task.sleep(for: .milliseconds(100))
        await setup.flow.cancel()
        await #expect(throws: CancellationError.self) { try await finishing.value }
        try Files.expectRecordedRevokes(setup.http)
        #expect(try setup.stored == nil)
    }

    @Test func anAccountWithNoFeedsYetIsClosedAndRevoked() async throws {
        let setup = try Setup(list: try Files.emptyList())
        let offer = try await setup.connect()
        #expect(offer.isEmpty)
        await #expect(throws: SammyConnectFlow.FlowError.nothingSelected) { try await setup.flow.save(selected: []) }
        await setup.flow.closeEmpty()
        try Files.expectRecordedRevokes(setup.http)
        #expect(try setup.stored == nil)
        #expect(try await setup.sammySources().isEmpty)
    }

    @Test func aSaveThatFailsRevokesAndLeavesNothingBehind() async throws {
        let setup = try Setup(sources: FailingSources())
        let offer = try await setup.connect()
        await #expect(throws: SammySignInError.self) { try await setup.flow.save(selected: Set(offer.feeds.map(\.id))) }
        try Files.expectRecordedRevokes(setup.http)
        #expect(try setup.stored == nil)
    }

    @Test func aSaveThatFailsKeepsTheFeedsAlreadyHere() async throws {
        let setup = try Setup()
        let first = try await setup.connect()
        try await setup.flow.save(selected: Set(first.feeds.map(\.id)))
        let stored = try setup.stored
        // Connecting again and unticking one, with a store that then fails
        // part-way, removes nothing.
        let failing = SammyConnectFlow(
            connector: SammySignIn(http: setup.http, crypto: .fake(), credentials: setup.credentials),
            credentials: setup.credentials, sources: FailingAfterReads(inner: setup.store)
        )
        let page = try await failing.begin(server: Files.origin)
        let again = try await failing.complete(callbackURL: Files.approved(for: page))
        await #expect(throws: SammySignInError.self) { try await failing.save(selected: [again.feeds[0].id]) }
        #expect(try await setup.sammySources().count == 2)
        #expect(try setup.stored == stored)
    }

    @Test func cancellingWhileSavingDoesNotRevokeWhatTheSaveStores() async throws {
        let setup = try Setup(sources: SlowSources(inner: try InfluxStore.inMemory()))
        let offer = try await setup.connect()
        let saving = Task { try await setup.flow.save(selected: Set(offer.feeds.map(\.id))) }
        try await Task.sleep(for: .milliseconds(100))
        await setup.flow.cancel()
        _ = try await saving.value
        #expect(!setup.http.requests.contains { $0.url?.path == "/oauth/revoke" })
        #expect(try setup.stored != nil)
    }

    @Test func connectingAgainTicksTheFeedsAlreadyHereAndRevokesTheOldToken() async throws {
        let setup = try Setup()
        let old = SammySession(
            issuer: try #require(URL(string: Files.origin)), revocationEndpoint: URL(string: "\(Files.origin)/oauth/revoke"),
            accessToken: "sao_contract-example-access-token", subject: Files.subject
        )
        var first = try await setup.connect()
        try await setup.flow.save(selected: [first.feeds[1].id])
        #expect(try setup.stored == old)

        first = try await setup.connect()
        #expect(first.ticked == [first.feeds[1].id])
        // Ticking the other one instead swaps them.
        try await setup.flow.save(selected: [first.feeds[0].id])
        #expect(try await setup.sammySources().map(\.id) == [first.feeds[0].id])
        // The server granted the same token again, so there is nothing to revoke.
        #expect(!setup.http.requests.contains { $0.url?.path == "/oauth/revoke" })
    }

    @Test func cancellingAReconnectionKeepsTheConnectionAlreadyHere() async throws {
        let setup = try Setup()
        let first = try await setup.connect()
        try await setup.flow.save(selected: Set(first.feeds.map(\.id)))
        let stored = try setup.stored
        // The contract server grants the same token again; cancelling the
        // picker must not revoke or forget it.
        _ = try await setup.connect()
        await setup.flow.cancel()
        #expect(!setup.http.requests.contains { $0.url?.path == "/oauth/revoke" })
        #expect(try setup.stored == stored)
        #expect(try await setup.sammySources().count == 2)
    }

    @Test func cancellingAReconnectionThatGotANewTokenRevokesOnlyThatOne() async throws {
        let setup = try Setup()
        let older = SammySession(
            issuer: try #require(URL(string: Files.origin)), revocationEndpoint: URL(string: "\(Files.origin)/oauth/revoke"),
            accessToken: "sao_older", subject: Files.subject
        )
        try setup.credentials.save(older, for: Files.accountID)
        _ = try await setup.connect()
        await setup.flow.cancel()
        try Files.expectRecordedRevokes(setup.http)
        #expect(try setup.stored == older)
    }

    @Test func rejectingAGrantOfTheTokenAlreadyHereKeepsTheConnection() async throws {
        // Signing in again as an account already connected here, while
        // expecting another, grants the stored token again: it stays.
        let setup = try Setup()
        let first = try await setup.connect()
        try await setup.flow.save(selected: Set(first.feeds.map(\.id)))
        let stored = try setup.stored
        _ = try await setup.connect()
        await #expect(throws: SammyConnectFlow.FlowError.differentAccount(Files.accountID)) {
            try await setup.flow.saveSignInAgain(expecting: "someone@example.com")
        }
        #expect(!setup.http.requests.contains { $0.url?.path == "/oauth/revoke" })
        #expect(try setup.stored == stored)

        // A callback finished after cancelling that grants it again too.
        let slow = try Setup(client: { SlowListClient(inner: $0) })
        try slow.credentials.save(try #require(stored), for: Files.accountID)
        let page = try await slow.flow.begin(server: Files.origin)
        let callback = try Files.approved(for: page)
        let finishing = Task { try await slow.flow.complete(callbackURL: callback) }
        try await Task.sleep(for: .milliseconds(100))
        await slow.flow.cancel()
        await #expect(throws: CancellationError.self) { try await finishing.value }
        #expect(!slow.http.requests.contains { $0.url?.path == "/oauth/revoke" })
        #expect(try slow.stored == stored)
    }

    @Test func anUnreadableCredentialIsNeverRevokedOrDeletedOnAGuess() async throws {
        let http = try Files.server()
        let credentials = FlakyCredentials()
        let store = try InfluxStore.inMemory()
        let flow = SammyConnectFlow(
            connector: SammySignIn(http: http, crypto: .fake(), credentials: credentials), credentials: credentials, sources: store
        )
        var page = try await flow.begin(server: Files.origin)
        let first = try await flow.complete(callbackURL: Files.approved(for: page))
        try await flow.save(selected: Set(first.feeds.map(\.id)))
        let stored = try credentials.inner.data(for: Files.accountID)

        // Reconnecting grants the stored token again; with the keychain
        // unreadable, cancelling neither revokes nor deletes it.
        page = try await flow.begin(server: Files.origin)
        _ = try await flow.complete(callbackURL: Files.approved(for: page))
        credentials.failsReads = true
        await #expect(throws: SammySignInError.self) { try await flow.save(selected: Set(first.feeds.map(\.id))) }
        await flow.cancel()
        credentials.failsReads = false
        #expect(!http.requests.contains { $0.url?.path == "/oauth/revoke" })
        #expect(try credentials.inner.data(for: Files.accountID) == stored)
    }

    @Test func signingInAgainAsAnotherAccountIsRevoked() async throws {
        let setup = try Setup()
        _ = try await setup.connect()
        await #expect(throws: SammyConnectFlow.FlowError.differentAccount(Files.accountID)) {
            try await setup.flow.saveSignInAgain(expecting: "someone@example.com")
        }
        try Files.expectRecordedRevokes(setup.http)
        #expect(try setup.stored == nil)

        _ = try await setup.connect()
        try await setup.flow.saveSignInAgain(expecting: Files.accountID)
        #expect(try setup.stored != nil)
        #expect(try await setup.sammySources().isEmpty)
    }

    // MARK: An account already connected

    @Test func removingTheLastFeedOffersToDisconnectAndDisconnectingRevokes() async throws {
        let setup = try Setup()
        let offer = try await setup.connect()
        try await setup.flow.save(selected: Set(offer.feeds.map(\.id)))
        let ids = try await setup.sammySources().map(\.id).sorted()

        #expect(try await setup.flow.removeSource(ids[0]) == .removed)
        #expect(try await setup.flow.removeSource(ids[1]) == .offerDisconnect)
        // The last one stays until the reader says to disconnect.
        #expect(try await setup.sammySources().map(\.id) == [ids[1]])
        #expect(!setup.http.requests.contains { $0.url?.path == "/oauth/revoke" })

        await setup.flow.disconnect(accountID: Files.accountID)
        try Files.expectRecordedRevokes(setup.http)
        #expect(try setup.stored == nil)
        #expect(try await setup.sammySources().isEmpty)
    }

    @Test func onlyAnAccountsOwnLastFeedOffersToDisconnect() {
        func feed(_ id: String, _ account: String) -> Source {
            Source(id: SammyFeedConnector.sourceID(accountID: account, feedID: id), kind: .sammyFeed, accountID: account, title: id, colorIndex: 0)
        }
        let a = feed("a", "1@example.com"), b = feed("b", "2@example.com")
        let rss = Source(id: "rss", kind: .rss, title: "RSS", url: "https://example.com/feed", colorIndex: 0)
        #expect(SammyConnectFlow.removal(of: a.id, added: [a, b, rss]) == .offerDisconnect)
        #expect(SammyConnectFlow.removal(of: a.id, added: [a, feed("c", "1@example.com")]) == .removed)
        #expect(SammyConnectFlow.removal(of: rss.id, added: [rss]) == .removed)
    }

    @Test func aGoneFeedAndAnUnreadableOneEachShowTheirOwnProblem() async throws {
        let setup = try Setup()
        let offer = try await setup.connect()
        let session = try await setup.flow.save(selected: Set(offer.feeds.map(\.id)))
        let feeds = try await setup.sammySources().sorted { $0.id < $1.id }
        setup.http.respond { request in
            request.url?.path.hasSuffix("f001") == true ? .init(status: 404) : .init(text: "{\"not\": \"a feed\"}")
        }
        let account = SammyAccount(session: session, http: setup.http, credentials: setup.credentials)
        let connector = SammyFeedConnector(account: account, http: setup.http, resolver: .testing(setup.http))
        let refresher = Refresher(store: setup.store)
        for feed in feeds { _ = try await refresher.refresh(feed, with: connector) }
        #expect(try await setup.store.fetchState(sourceID: feeds[0].id)?.problem == .notFound)
        #expect(try await setup.store.fetchState(sourceID: feeds[1].id)?.problem == .badResponse)
    }

    @Test func anAccountIsNamedForItsServer() throws {
        let issuer = try #require(URL(string: "https://example.com"))
        #expect(SammySession(issuer: issuer, revocationEndpoint: nil, accessToken: "t", subject: "s").displayName == "Sammy (example.com)")
        let ported = try #require(URL(string: "https://Example.com:8443"))
        #expect(SammySession(issuer: ported, revocationEndpoint: nil, accessToken: "t", subject: "s").displayName == "Sammy (example.com:8443)")
    }
}
