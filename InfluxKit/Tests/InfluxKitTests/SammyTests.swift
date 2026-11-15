import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import InfluxKit

private let now = Date(timeIntervalSince1970: 1_793_000_000)
private let issuer = URL(string: "https://sammy.example")!
private let accountID = "sub42@sammy.example"
private let feedID = "0193a1b2-0000-7000-8000-00000000f007"
private let feedURL = "https://sammy.example/api/v1/feeds/\(feedID)"
private let source = Source(
    id: SammyFeedConnector.sourceID(accountID: accountID, feedID: feedID), kind: .sammyFeed, accountID: accountID,
    title: "Picks", url: feedURL, colorIndex: 0
)

private func makeSession(access: String = "sao_access-1", revocation: Bool = true) -> SammySession {
    SammySession(
        issuer: issuer, revocationEndpoint: revocation ? URL(string: "https://sammy.example/oauth/revoke")! : nil,
        accessToken: access, subject: "sub42"
    )
}

private func makeAccount(_ http: any HTTPClient, session: SammySession = makeSession(), credentials: any CredentialStore = InMemoryCredentialStore()) throws -> SammyAccount {
    try credentials.save(session, for: session.accountID)
    return SammyAccount(session: session, http: http, credentials: credentials)
}

private func makeConnector(_ account: SammyAccount, _ http: FakeHTTPClient) -> SammyFeedConnector {
    SammyFeedConnector(account: account, http: http, resolver: .testing(http))
}

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func form(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

private func query(_ url: URL) -> [String: String] {
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

private func metadata(_ overrides: [String: Any?] = [:]) -> Data {
    var body: [String: Any] = [
        "issuer": "https://sammy.example",
        "authorization_endpoint": "https://sammy.example/oauth/authorize",
        "token_endpoint": "https://sammy.example/oauth/token",
        "revocation_endpoint": "https://sammy.example/oauth/revoke",
        "scopes_supported": ["feeds:read"],
        "code_challenge_methods_supported": ["S256"],
        "response_types_supported": ["code"],
    ]
    for (key, value) in overrides { body[key] = value }
    return json(body)
}

private func token(_ access: String, scope: String = "feeds:read") -> FakeHTTPClient.Response {
    .init(body: json(["access_token": access, "token_type": "Bearer", "scope": scope]))
}

private let feedList = json([
    "account": ["id": "sub42", "server": "https://sammy.example"],
    "feeds": [
        ["id": feedID, "key": "picks", "title": "Picks", "feedUrl": feedURL, "lastPostAt": "2026-10-30T10:07:12Z"],
        ["id": "f8", "title": "Longreads", "feedUrl": "https://sammy.example/api/v1/feeds/f8", "lastPostAt": NSNull()],
        // The token would go wherever a feed lives, so this one is left out.
        ["id": "f9", "title": "Elsewhere", "feedUrl": "https://other.example/api/v1/feeds/f9"],
        ["title": "No ID", "feedUrl": "https://sammy.example/api/v1/feeds/x"],
    ],
])

/// A JSON Feed page of posts at the given minutes before `now`, newest
/// first, linking to `next` for older ones.
private func feedPage(_ minutesAgo: [Int], next: String? = nil) -> Data {
    let items = minutesAgo.map { minutes -> [String: Any] in
        [
            "id": "post-\(minutes)",
            "url": "https://news.example.com/stories/\(minutes)",
            "title": "Story \(minutes)",
            "summary": "About story \(minutes).",
            "date_published": ISO8601DateFormatter().string(from: now.addingTimeInterval(TimeInterval(-60 * minutes))),
        ]
    }
    var body: [String: Any] = ["version": "https://jsonfeed.org/version/1.1", "title": "Picks", "items": items]
    if let next { body["next_url"] = next }
    return json(body)
}

private func page(_ query: String) -> String { "\(feedURL)?\(query)" }

/// What the server sends with an article page: `Content-Type` and any
/// `extra` headers.
private func articleHeaders(_ extra: [String: String] = [:]) -> [String: String] {
    extra.merging(["Content-Type": "application/feed+json; charset=utf-8"]) { $1 }
}

/// An article page as the server serves it.
private func articles(_ body: Data) -> FakeHTTPClient.Response {
    .init(headers: articleHeaders(), body: body)
}

/// What the server sends with an article feed list.
private let listHeaders = ["Content-Type": "application/json"]

private func fetchRequest(_ direction: FetchDirection, cursor: Cursor? = nil, stored: Set<String> = []) -> FetchRequest {
    FetchRequest(direction: direction, cursor: cursor, notBefore: now.addingTimeInterval(-InfluxStore.articleRetention), now: now, storedRemoteIDs: stored)
}

/// Every token and revocation request `http` was sent.
private func endpointRequests(_ http: FakeHTTPClient) -> [URLRequest] {
    http.requests.filter { ["/oauth/token", "/oauth/revoke"].contains($0.url?.path) }
}

private func revokedTokens(_ http: FakeHTTPClient) -> [String] {
    http.requests.filter { $0.url?.path == "/oauth/revoke" }.map { form($0)["token"] ?? "" }
}

/// A server that signs in: metadata, a token for the code, and the feed
/// list for that token.
private func signInServer(list: Data = feedList, access: String = "sao_new") -> FakeHTTPClient {
    FakeHTTPClient { request in
        switch request.url?.path {
        case "/.well-known/oauth-authorization-server": return .init(body: metadata())
        case "/oauth/token": return token(access)
        case "/oauth/revoke": return .init()
        case "/api/v1/feeds":
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(access)" else { return .init(status: 401) }
            return .init(headers: listHeaders, body: list)
        default: return .init(status: 404)
        }
    }
}

private func signIn(_ http: any HTTPClient, credentials: any CredentialStore = InMemoryCredentialStore()) -> SammySignIn {
    SammySignIn(http: http, crypto: .fake(), credentials: credentials, now: { now })
}

/// The callback a server sends for `pending`, approved.
private func approved(_ pending: PendingSammySignIn, code: String = "code-1") -> URL {
    let state = query(pending.authorizationURL)["state"] ?? ""
    return URL(string: "dev.bespokebits.influx:/oauth/sammy?code=\(code)&state=\(state)&iss=https%3A%2F%2Fsammy.example")!
}

/// Stops at once in a cancelled task, as URLSession does, and holds the
/// feed list back until it is cancelled, so a sign-in can be cancelled
/// after its token was granted.
private struct CancellingClient: HTTPClient {
    let inner: FakeHTTPClient

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await inner.send(request)
    }

    func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await inner.send(request, upTo: limit, at: address)
    }

    func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        return try await inner.send(request, followingRedirectsOnlyTo: allowed)
    }

    func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let answer = try await inner.sendRefusingRedirects(request)
        if request.url?.path == "/api/v1/feeds" { try await Task.sleep(for: .seconds(30)) }
        return answer
    }
}

/// Answers every request as if it came from another server, as a client
/// that followed a redirect there would.
private struct ElsewhereClient: HTTPClient {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        (feedPage([1]), HTTPURLResponse(url: URL(string: "https://other.example/api/v1/feeds/x")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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

// MARK: - Server addresses

@Suite struct ServerAddress_ {
    @Test(arguments: [
        ("feeds.example.com", "https://feeds.example.com"),
        ("  Feeds.Example.COM \n", "https://feeds.example.com"),
        ("https://feeds.example.com/", "https://feeds.example.com"),
        ("https://feeds.example.com/some/path?x=1#y", "https://feeds.example.com"),
        ("https://feeds.example.com:443", "https://feeds.example.com"),
        ("feeds.example.com:8443", "https://feeds.example.com:8443"),
    ])
    func originFromInput(input: String, expected: String) {
        #expect(ServerAddress.origin(from: input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "localhost", "http://feeds.example.com", "ftp://feeds.example.com", "https://user@feeds.example.com",
                      "https://user:pass@feeds.example.com", "not a host", ".example.com", "example."])
    func rejectsInput(input: String) {
        #expect(ServerAddress.origin(from: input) == nil)
    }

    @Test func sameOriginNeedsHTTPSAndTheSameHostAndPort() {
        let origin = URL(string: "https://feeds.example.com")!
        #expect(ServerAddress.isSameOrigin(URL(string: "https://FEEDS.example.com/a")!, origin))
        #expect(ServerAddress.isSameOrigin(URL(string: "https://feeds.example.com:443/a")!, origin))
        #expect(!ServerAddress.isSameOrigin(URL(string: "http://feeds.example.com/a")!, origin))
        #expect(!ServerAddress.isSameOrigin(URL(string: "https://feeds.example.com:8443/a")!, origin))
        #expect(!ServerAddress.isSameOrigin(URL(string: "https://other.example.com/a")!, origin))
        #expect(!ServerAddress.isSameOrigin(URL(string: "https://feeds.example.com.other.example/a")!, origin))
    }
}

// MARK: - Sign-in

@Suite struct SammySignIn_ {
    @Test func discoveryLeadsToAnAuthorizeURLWithPKCEAndState() async throws {
        let http = FakeHTTPClient { _ in .init(body: metadata()) }
        let pending = try await signIn(http).begin(server: "Sammy.Example/")
        #expect(http.requests.first?.url?.absoluteString == "https://sammy.example/.well-known/oauth-authorization-server")
        let url = pending.authorizationURL
        #expect(url.absoluteString.hasPrefix("https://sammy.example/oauth/authorize?"))
        let items = query(url)
        #expect(items["response_type"] == "code")
        #expect(items["client_id"] == "influx")
        #expect(items["redirect_uri"] == "dev.bespokebits.influx:/oauth/sammy")
        #expect(items["scope"] == "feeds:read")
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["state"]?.isEmpty == false)
        #expect(items["code_challenge"] == pending.pkce.challenge)
        #expect(items["state"] == pending.state)
    }

    @Test func aServerWithoutMetadataIsNotASammyServer() async throws {
        let http = FakeHTTPClient { _ in .init(status: 404) }
        await #expect(throws: SammySignInError.notASammyServer("no OAuth metadata")) { try await signIn(http).begin(server: "sammy.example") }
    }

    @Test func aBusyServerIsNotCalledSomethingElse() async throws {
        let unavailable = FakeHTTPClient { _ in .init(status: 503) }
        await #expect(throws: SammySignInError.failed(.badResponse("HTTP 503"))) { try await signIn(unavailable).begin(server: "sammy.example") }
        let limited = FakeHTTPClient { _ in .init(status: 429, headers: ["Retry-After": "120"]) }
        await #expect(throws: SammySignInError.failed(.rateLimited(retryAfter: now.addingTimeInterval(120)))) {
            try await signIn(limited).begin(server: "sammy.example")
        }
    }

    @Test func metadataWithoutWhatSammyNeedsIsNotASammyServer() async throws {
        let cases: [([String: Any?], String)] = [
            // The issuer must be exactly the origin that was typed.
            (["issuer": "https://other.example"], "issuer"),
            (["issuer": "https://sammy.example/tenant"], "issuer"),
            (["issuer": "http://sammy.example"], "issuer"),
            (["issuer": nil], "issuer"),
            // Every endpoint shares that origin, over https.
            (["authorization_endpoint": "https://auth.example/oauth/authorize"], "authorization_endpoint"),
            (["token_endpoint": "https://sammy.example:8443/oauth/token"], "token_endpoint"),
            (["token_endpoint": "http://sammy.example/oauth/token"], "token_endpoint"),
            (["revocation_endpoint": "https://other.example/oauth/revoke"], "revocation_endpoint"),
            (["token_endpoint": nil], "token_endpoint"),
            (["scopes_supported": ["tasks:read"]], "scope feeds:read"),
            (["scopes_supported": nil], "scope feeds:read"),
            (["code_challenge_methods_supported": ["plain"]], "PKCE S256"),
            (["code_challenge_methods_supported": nil], "PKCE S256"),
        ]
        for (overrides, missing) in cases {
            let body = metadata(overrides)
            let http = FakeHTTPClient { _ in .init(body: body) }
            await #expect(throws: SammySignInError.notASammyServer(missing)) { try await signIn(http).begin(server: "sammy.example") }
        }
    }

    @Test func theIssuerMatchesExactlyEvenItsTrailingSlash() async throws {
        // A callback's `iss` is compared with it exactly, so the metadata's
        // must be the typed origin exactly too.
        let body = metadata(["issuer": "https://sammy.example/"])
        let http = FakeHTTPClient { _ in .init(body: body) }
        await #expect(throws: SammySignInError.notASammyServer("issuer")) { try await signIn(http).begin(server: "sammy.example/") }
    }

    @Test func onlyHTTPSAddressesAreServers() async throws {
        let http = FakeHTTPClient { _ in .init(body: metadata()) }
        for address in ["http://sammy.example", "sammy", "", "https://me@sammy.example"] {
            await #expect(throws: SammySignInError.notAnAddress) { try await signIn(http).begin(server: address) }
        }
        #expect(http.requests.isEmpty)
    }

    @Test func discoveryIsNotRedirected() async throws {
        let http = FakeHTTPClient { request in
            request.url?.host() == "sammy.example" ? .init(status: 302, headers: ["Location": "https://other.example/.well-known/oauth-authorization-server"]) : .init(body: metadata())
        }
        await #expect(throws: SammySignInError.failed(.badResponse("refused a redirect (HTTP 302)"))) { try await signIn(http).begin(server: "sammy.example") }
        #expect(http.requests.count == 1)
    }

    @Test func aCallbackForAnotherSignInIsRejected() async throws {
        let http = FakeHTTPClient { _ in .init(body: metadata()) }
        let pending = try await signIn(http).begin(server: "sammy.example")
        let callback = URL(string: "dev.bespokebits.influx:/oauth/sammy?code=c&state=other")!
        await #expect(throws: SammySignInError.callback(.stateMismatch)) { try await signIn(http).complete(pending, callback: callback) }
        #expect(endpointRequests(http).isEmpty)
    }

    @Test func aCallbackForAnotherRedirectIsRejected() async throws {
        let http = FakeHTTPClient { _ in .init(body: metadata()) }
        let pending = try await signIn(http).begin(server: "sammy.example")
        let state = pending.state
        for address in ["dev.bespokebits.influx:/oauth/mastodon?code=c&state=\(state)", "other.scheme:/oauth/sammy?code=c&state=\(state)", "dev.bespokebits.flux:/oauth/sammy?code=c&state=\(state)"] {
            await #expect(throws: SammySignInError.callback(.stateMismatch)) { try await signIn(http).complete(pending, callback: URL(string: address)!) }
        }
    }

    @Test func aRefusalComesBackAsDenied() async throws {
        let http = FakeHTTPClient { _ in .init(body: metadata()) }
        let pending = try await signIn(http).begin(server: "sammy.example")
        let callback = URL(string: "dev.bespokebits.influx:/oauth/sammy?error=access_denied&state=\(pending.state)")!
        await #expect(throws: SammySignInError.callback(.denied("access_denied"))) { try await signIn(http).complete(pending, callback: callback) }
        #expect(endpointRequests(http).isEmpty)
    }

    @Test func aCallbackFromAnotherIssuerIsRejected() async throws {
        let http = FakeHTTPClient { _ in .init(body: metadata()) }
        let pending = try await signIn(http).begin(server: "sammy.example")
        let callback = URL(string: "dev.bespokebits.influx:/oauth/sammy?code=c&state=\(pending.state)&iss=https%3A%2F%2Fother.example")!
        await #expect(throws: SammySignInError.callback(.issuerMismatch)) { try await signIn(http).complete(pending, callback: callback) }
        #expect(endpointRequests(http).isEmpty)
    }

    @Test func aServerThatAlwaysNamesItselfMustNameItself() async throws {
        let http = FakeHTTPClient { _ in .init(body: metadata(["authorization_response_iss_parameter_supported": true])) }
        let pending = try await signIn(http).begin(server: "sammy.example")
        let callback = URL(string: "dev.bespokebits.influx:/oauth/sammy?code=c&state=\(pending.state)")!
        await #expect(throws: SammySignInError.callback(.issuerMismatch)) { try await signIn(http).complete(pending, callback: callback) }
    }

    @Test func theCodeIsExchangedAndTheAccountStored() async throws {
        let http = signInServer()
        let credentials = InMemoryCredentialStore()
        let sammy = signIn(http, credentials: credentials)
        let pending = try await sammy.begin(server: "sammy.example")
        let (session, sources) = try await sammy.complete(pending, callback: approved(pending))

        let exchange = try #require(http.requests.first { $0.url?.path == "/oauth/token" })
        #expect(exchange.httpMethod == "POST")
        #expect(exchange.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(form(exchange) == [
            "grant_type": "authorization_code", "code": "code-1", "redirect_uri": "dev.bespokebits.influx:/oauth/sammy",
            "client_id": "influx", "code_verifier": pending.pkce.verifier,
        ])
        // The feed list says whose account it is.
        let list = try #require(http.requests.first { $0.url?.path == "/api/v1/feeds" })
        #expect(list.url?.absoluteString == "https://sammy.example/api/v1/feeds")
        #expect(list.value(forHTTPHeaderField: "Authorization") == "Bearer sao_new")

        #expect(session == SammySession(
            issuer: issuer, revocationEndpoint: URL(string: "https://sammy.example/oauth/revoke")!, clientID: "influx",
            accessToken: "sao_new", scope: "feeds:read", subject: "sub42"
        ))
        #expect(session.accountID == accountID)
        #expect(try credentials.load(SammySession.self, for: accountID) == session)
        #expect(try sammy.accountIDs() == [accountID])
        #expect(sources == [
            Source(id: "sammy:sub42@sammy.example:feed:\(feedID)", kind: .sammyFeed, accountID: accountID, title: "Picks", url: feedURL, colorIndex: 0),
            Source(id: "sammy:sub42@sammy.example:feed:f8", kind: .sammyFeed, accountID: accountID, title: "Longreads",
                   url: "https://sammy.example/api/v1/feeds/f8", colorIndex: 0),
        ])
        #expect(revokedTokens(http).isEmpty)
    }

    @Test func theTokenIsNeverInASourceOrItsSyncPayload() async throws {
        let http = signInServer(access: "sao_secret-token")
        let sammy = signIn(http)
        let pending = try await sammy.begin(server: "sammy.example")
        let (_, sources) = try await sammy.complete(pending, callback: approved(pending))
        #expect(!sources.isEmpty)
        for source in sources {
            let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
            #expect(!encoded.contains("sao_secret-token"))
            let payload = String(decoding: try JSONEncoder().encode(SourcePayload(source: source, modifiedAt: now)), as: UTF8.self)
            #expect(!payload.contains("sao_secret-token"))
        }
    }

    @Test func aFeedListThatDoesNotSayWhoseAccountRevokesTheNewToken() async throws {
        let list = json(["account": ["server": "https://sammy.example"], "feeds": []])
        let http = signInServer(list: list)
        let credentials = InMemoryCredentialStore()
        let sammy = signIn(http, credentials: credentials)
        let pending = try await sammy.begin(server: "sammy.example")
        await #expect(throws: SammySignInError.notASammyServer("account id")) { try await sammy.complete(pending, callback: approved(pending)) }
        #expect(revokedTokens(http) == ["sao_new"])
        #expect(try credentials.accounts().isEmpty)
    }

    @Test func aSubjectThatCouldNameAnotherAccountIsRefused() async throws {
        for subject in ["me@mastodon.example", "a:b", "a/b", ".."] {
            let list = json(["account": ["id": subject, "server": "https://sammy.example"], "feeds": []])
            let http = signInServer(list: list)
            let sammy = signIn(http)
            let pending = try await sammy.begin(server: "sammy.example")
            await #expect(throws: SammySignInError.notASammyServer("account id")) { try await sammy.complete(pending, callback: approved(pending)) }
            #expect(revokedTokens(http) == ["sao_new"])
        }
    }

    @Test func aTokenGrantedButRefusedIsRevoked() async throws {
        for answer in [token("sao_wrong", scope: "tasks:read"), FakeHTTPClient.Response(body: json(["access_token": "sao_wrong", "token_type": "DPoP"]))] {
            let http = FakeHTTPClient { request in
                switch request.url?.path {
                case "/oauth/token": answer
                case "/oauth/revoke": .init()
                default: .init(body: metadata())
                }
            }
            let sammy = signIn(http)
            let pending = try await sammy.begin(server: "sammy.example")
            await #expect(throws: SammySignInError.self) { try await sammy.complete(pending, callback: approved(pending)) }
            #expect(revokedTokens(http) == ["sao_wrong"])
        }
    }

    @Test func aSpentCodeIsUnauthorized() async throws {
        let http = FakeHTTPClient { request in
            request.url?.path == "/oauth/token"
                ? .init(status: 400, body: json(["error": "invalid_grant", "error_description": "The authorization code was already used."]))
                : .init(body: metadata())
        }
        let sammy = signIn(http)
        let pending = try await sammy.begin(server: "sammy.example")
        await #expect(throws: SammySignInError.failed(.unauthorized)) { try await sammy.complete(pending, callback: approved(pending)) }
    }

    @Test func aFeedListThatFailsRevokesTheNewToken() async throws {
        let http = FakeHTTPClient { request in
            switch request.url?.path {
            case "/oauth/token": token("sao_new")
            case "/oauth/revoke": .init()
            case "/api/v1/feeds": .init(status: 500)
            default: .init(body: metadata())
            }
        }
        let credentials = InMemoryCredentialStore()
        let sammy = signIn(http, credentials: credentials)
        let pending = try await sammy.begin(server: "sammy.example")
        await #expect(throws: SammySignInError.failed(.badResponse("HTTP 500"))) { try await sammy.complete(pending, callback: approved(pending)) }
        #expect(revokedTokens(http) == ["sao_new"])
        #expect(try credentials.accounts().isEmpty)
    }

    @Test func aSignInCancelledAfterTheTokenWasGrantedRevokesIt() async throws {
        let fake = signInServer()
        let http = CancellingClient(inner: fake)
        let sammy = signIn(http)
        let pending = try await sammy.begin(server: "sammy.example")
        let callback = approved(pending)
        let task = Task { try await sammy.complete(pending, callback: callback) }
        while !fake.requests.contains(where: { $0.url?.path == "/api/v1/feeds" }) { await Task.yield() }
        task.cancel()
        _ = try? await task.value
        #expect(revokedTokens(fake) == ["sao_new"])
    }

    @Test func signingInAgainRevokesTheSessionItReplaces() async throws {
        let http = signInServer(access: "sao_second")
        let credentials = InMemoryCredentialStore()
        try credentials.save(makeSession(access: "sao_first"), for: accountID)
        let sammy = signIn(http, credentials: credentials)
        let pending = try await sammy.begin(server: "sammy.example")
        let (session, _) = try await sammy.complete(pending, callback: approved(pending))
        #expect(session.accessToken == "sao_second")
        #expect(try credentials.load(SammySession.self, for: accountID)?.accessToken == "sao_second")
        #expect(revokedTokens(http) == ["sao_first"])
    }

    @Test func aServerWithoutRevocationSignsInAndOutWithoutIt() async throws {
        let http = FakeHTTPClient { request in
            switch request.url?.path {
            case "/.well-known/oauth-authorization-server": .init(body: metadata(["revocation_endpoint": nil]))
            case "/oauth/token": token("sao_new")
            default: .init(headers: listHeaders, body: feedList)
            }
        }
        let credentials = InMemoryCredentialStore()
        let sammy = signIn(http, credentials: credentials)
        let pending = try await sammy.begin(server: "sammy.example")
        let (session, _) = try await sammy.complete(pending, callback: approved(pending))
        #expect(session.revocationEndpoint == nil)
        let account = try #require(try sammy.account(accountID))
        await account.signOut()
        #expect(try credentials.load(SammySession.self, for: accountID) == nil)
        #expect(endpointRequests(http).map(\.url?.path) == ["/oauth/token"])
    }

    @Test func theCodeIsNotRedirected() async throws {
        let http = FakeHTTPClient { request in
            switch request.url?.path {
            case "/oauth/token": .init(status: 307, headers: ["Location": "https://other.example/oauth/token"])
            default: .init(body: metadata())
            }
        }
        let sammy = signIn(http)
        let pending = try await sammy.begin(server: "sammy.example")
        await #expect(throws: SammySignInError.failed(.badResponse("refused a redirect (HTTP 307)"))) { try await sammy.complete(pending, callback: approved(pending)) }
        #expect(!http.requests.contains { $0.url?.host() == "other.example" })
    }

    @Test func anAccountWithNoFeedsYetIsStoredAndFoundByItsCredentials() async throws {
        let http = signInServer(list: json(["account": ["id": "sub42", "server": "https://sammy.example"], "feeds": []]))
        let credentials = InMemoryCredentialStore()
        let sammy = signIn(http, credentials: credentials)
        let pending = try await sammy.begin(server: "sammy.example")
        let (session, sources) = try await sammy.complete(pending, callback: approved(pending))
        #expect(sources.isEmpty)
        #expect(try sammy.accountIDs() == [session.accountID])
    }

    @Test func accountIDsKeepAPortThatIsNotHTTPSs() {
        #expect(SammySession.accountID(subject: "s", issuer: URL(string: "https://sammy.example")!) == "s@sammy.example")
        #expect(SammySession.accountID(subject: "s", issuer: URL(string: "https://Sammy.example:8443")!) == "s@sammy.example:8443")
    }
}

// MARK: - Account

@Suite struct SammyAccount_ {
    @Test func requestsCarryTheTokenToTheAccountsServerOnly() async throws {
        let http = FakeHTTPClient { _ in articles(feedPage([1])) }
        let account = try makeAccount(http)
        _ = try await account.send(URLRequest(url: URL(string: feedURL)!))
        #expect(http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer sao_access-1")
        await #expect(throws: ConnectorError.badResponse("not on the account's server")) {
            try await account.send(URLRequest(url: URL(string: "https://other.example/api/v1/feeds")!))
        }
        await #expect(throws: ConnectorError.badResponse("not on the account's server")) {
            try await account.send(URLRequest(url: URL(string: "http://sammy.example/api/v1/feeds")!))
        }
        #expect(http.requests.count == 1)
    }

    @Test func aRedirectIsNotFollowed() async throws {
        let http = FakeHTTPClient { request in
            request.url?.host() == "sammy.example" ? .init(status: 302, headers: ["Location": "https://other.example/x"]) : articles(feedPage([1]))
        }
        await #expect(throws: ConnectorError.badResponse("refused a redirect (HTTP 302)")) {
            try await makeAccount(http).send(URLRequest(url: URL(string: feedURL)!))
        }
        #expect(http.requests.count == 1)
    }

    @Test func anAnswerFromAnotherServerIsRefused() async throws {
        await #expect(throws: ConnectorError.badResponse("answered from another address")) {
            try await makeAccount(ElsewhereClient()).send(URLRequest(url: URL(string: feedURL)!))
        }
    }

    @Test func aRefusedTokenTakesUpTheSessionAnotherDeviceStored() async throws {
        let http = FakeHTTPClient { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer sao_other-device" ? articles(feedPage([1])) : .init(status: 401)
        }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, credentials: credentials)
        // Signed in again on another device, which revoked this one's token.
        try credentials.save(makeSession(access: "sao_other-device"), for: accountID)
        let (_, response) = try await account.send(URLRequest(url: URL(string: feedURL)!))
        #expect(response.statusCode == 200)
        #expect(await account.session.accessToken == "sao_other-device")
        #expect(http.requests.count == 2)
    }

    @Test func twoRequestsRefusedTogetherBothRetryWithTheNewerSession() async throws {
        /// Holds requests with the old token until two are out, then
        /// refuses both, so the second resumes after the first has taken
        /// up the stored session.
        final class TwoAtOnce: HTTPClient, @unchecked Sendable {
            let held = Mutex(0)
            let sent = Mutex<[String]>([])
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw ConnectorError.unsupported }
            func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) { throw ConnectorError.unsupported }
            func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
                throw ConnectorError.unsupported
            }
            func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
                sent.withLock { $0.append(token) }
                var status = 200
                if token == "Bearer sao_access-1" {
                    held.withLock { $0 += 1 }
                    while held.withLock({ $0 }) < 2 { try await Task.sleep(for: .milliseconds(2)) }
                    status = 401
                }
                return (feedPage([1]), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }
        let http = TwoAtOnce()
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, credentials: credentials)
        try credentials.save(makeSession(access: "sao_other-device"), for: accountID)
        async let first = account.send(URLRequest(url: URL(string: feedURL)!))
        async let second = account.send(URLRequest(url: URL(string: feedURL)!))
        let statuses = try await [first.1.statusCode, second.1.statusCode]
        #expect(statuses == [200, 200])
        #expect(http.sent.withLock { $0 }.filter { $0 == "Bearer sao_other-device" }.count == 2)
    }

    @Test func aRefusedTokenWithNothingNewerStoredComesBackAsItsRefusal() async throws {
        let http = FakeHTTPClient { _ in .init(status: 401) }
        let (_, response) = try await makeAccount(http).send(URLRequest(url: URL(string: feedURL)!))
        #expect(response.statusCode == 401)
        #expect(http.requests.count == 1)
    }

    @Test func signingOutForgetsAndRevokes() async throws {
        let http = FakeHTTPClient { _ in .init() }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, credentials: credentials)
        await account.signOut()
        #expect(try credentials.load(SammySession.self, for: accountID) == nil)
        let revoke = try #require(http.requests.first)
        #expect(revoke.url?.absoluteString == "https://sammy.example/oauth/revoke")
        #expect(revoke.httpMethod == "POST")
        #expect(form(revoke) == ["token": "sao_access-1", "token_type_hint": "access_token", "client_id": "influx"])
        // Signed out, the account sends nothing more.
        await #expect(throws: ConnectorError.unauthorized) { try await account.send(URLRequest(url: URL(string: feedURL)!)) }
        #expect(http.requests.count == 1)
    }

    @Test func signingOutRevokesTheSessionAnotherDeviceStoredToo() async throws {
        let http = FakeHTTPClient { _ in .init() }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, credentials: credentials)
        try credentials.save(makeSession(access: "sao_other-device"), for: accountID)
        await account.signOut()
        #expect(revokedTokens(http) == ["sao_other-device", "sao_access-1"])
    }

    @Test func signingOutWorksOffline() async throws {
        let http = FakeHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, credentials: credentials)
        await account.signOut()
        #expect(try credentials.load(SammySession.self, for: accountID) == nil)
    }

    @Test func signingOutInACancelledTaskStillRevokes() async throws {
        let fake = FakeHTTPClient { _ in .init() }
        let account = try makeAccount(CancellingClient(inner: fake))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await account.signOut()
        }
        await task.value
        #expect(revokedTokens(fake) == ["sao_access-1"])
    }

    @Test func takingUpANewSessionRevokesTheOldOne() async throws {
        let http = FakeHTTPClient { _ in .init() }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, credentials: credentials)
        await account.adopt(makeSession(access: "sao_second"))
        #expect(await account.session.accessToken == "sao_second")
        #expect(try credentials.load(SammySession.self, for: accountID)?.accessToken == "sao_second")
        #expect(revokedTokens(http) == ["sao_access-1"])
        // The same session again revokes nothing.
        await account.adopt(makeSession(access: "sao_second"))
        #expect(revokedTokens(http) == ["sao_access-1"])
    }
}

// MARK: - Connector

@Suite struct SammyFeedConnector_ {
    @Test func feedsBecomeSourcesOfTheAccount() async throws {
        let http = FakeHTTPClient { request in
            guard request.url?.absoluteString == "https://sammy.example/api/v1/feeds",
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer sao_access-1" else { return .init(status: 404) }
            return .init(headers: listHeaders, body: feedList)
        }
        let sources = try await makeConnector(try makeAccount(http), http).availableSources()
        #expect(sources.map(\.id) == ["sammy:sub42@sammy.example:feed:\(feedID)", "sammy:sub42@sammy.example:feed:f8"])
        #expect(sources.map(\.url) == [feedURL, "https://sammy.example/api/v1/feeds/f8"])
        #expect(sources.allSatisfy { $0.kind == .sammyFeed && $0.accountID == accountID })
    }

    @Test func theAccountAndFeedFieldsDecodeLeniently() throws {
        for id in ["" as Any, 42, NSNull(), ["x"]] {
            let list = try SammyFeedList.decode(json(["account": ["id": id, "server": 7], "feeds": []]))
            #expect(list.account.id == nil)
            #expect(list.account.server == nil)
        }
        let list = try SammyFeedList.decode(json([
            "account": ["id": "sub42", "server": "https://sammy.example"],
            "feeds": [
                ["id": "a", "feedUrl": feedURL, "lastPostAt": "2026-10-30T10:07:12Z", "title": "A"],
                ["id": "b", "feedUrl": feedURL, "lastPostAt": "yesterday", "title": 3],
                ["id": "", "feedUrl": feedURL],
                ["id": "c"],
            ],
        ]))
        #expect(list.account.id == "sub42")
        #expect(list.account.server == "https://sammy.example")
        #expect(list.feeds.map(\.id) == ["a", "b"])
        #expect(list.feeds[0].lastPostAt == FeedDate.iso8601("2026-10-30T10:07:12Z"))
        #expect(list.feeds[1].lastPostAt == nil && list.feeds[1].title == nil)
    }

    @Test func aFeedIDThatIsNotOnePlainPathSegmentIsLeftOut() {
        let list = try! SammyFeedList.decode(json([
            "account": ["id": "sub42"],
            "feeds": [
                ["id": "8443:x", "feedUrl": feedURL], ["id": "a@b", "feedUrl": feedURL], ["id": "a/b", "feedUrl": feedURL],
                ["id": "..", "feedUrl": feedURL], ["id": "ok-1", "feedUrl": feedURL],
            ],
        ]))
        let sources = SammyFeedConnector.sources(of: list, accountID: accountID, issuer: issuer, colorIndex: 0)
        #expect(sources.map(\.id) == ["sammy:sub42@sammy.example:feed:ok-1"])
    }

    @Test func theFeedIsFetchedFromTheIssuerNeverFromTheSyncedURL() async throws {
        let http = FakeHTTPClient { _ in articles(feedPage([1])) }
        var synced = source
        // Another device could sync any URL into the source.
        synced.url = "https://other.example/steal"
        _ = try await makeConnector(try makeAccount(http), http).fetch(fetchRequest(.newer), from: synced)
        let request = try #require(http.requests.first)
        #expect(request.url?.absoluteString == feedURL)
        // A feed not known to be posts asks for either format.
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.sammy.rich-feed+json; version=1, application/feed+json")
        #expect(!http.requests.contains { $0.url?.host() == "other.example" })
    }

    @Test func aSourceThatIsNotOneOfTheAccountsFeedsIsNotFetched() async throws {
        let http = FakeHTTPClient { _ in articles(feedPage([1])) }
        let connector = makeConnector(try makeAccount(http), http)
        var other = source
        other.accountID = "sub43@sammy.example"
        await #expect(throws: ConnectorError.notFound) { try await connector.fetch(fetchRequest(.newer), from: other) }
        var malformed = source
        malformed.id = "sammy:\(accountID):feed:../tasks"
        await #expect(throws: ConnectorError.notFound) { try await connector.fetch(fetchRequest(.newer), from: malformed) }
        #expect(http.requests.isEmpty)
        #expect(!connector.handles(Source(id: "rss:x", kind: .rss, title: "x", url: feedURL, colorIndex: 0)))
    }

    @Test func feedsAreKeptAsLongAsTheirItems() {
        let request = Refresher.request(for: source, direction: .newer, cursor: nil, now: now)
        // Not known to be posts: the article window.
        #expect(request.notBefore == now.addingTimeInterval(-InfluxStore.articleRetention))
        #expect(InfluxStore.articleRetention == 30 * 24 * 60 * 60)
        let rss = Source(id: "rss:x", kind: .rss, title: "x", colorIndex: 0)
        #expect(Refresher.retention(for: source) == Refresher.retention(for: rss))
        var articles = source
        articles.itemKind = .article
        #expect(Refresher.retention(for: articles) == InfluxStore.articleRetention)
        var posts = source
        posts.itemKind = .post
        #expect(Refresher.retention(for: posts) == InfluxStore.postRetention)
        #expect(InfluxStore.postRetention == 7 * 24 * 60 * 60)
    }

    @Test func postsBecomeArticles() async throws {
        let http = FakeHTTPClient { _ in .init(headers: articleHeaders(["ETag": "W/\"v1\""]), body: feedPage([1, 2], next: page("before=p2"))) }
        let fetched = try await makeConnector(try makeAccount(http), http).fetch(fetchRequest(.newer), from: source)
        let item = try #require(fetched.items.first)
        #expect(item.kind == .article)
        #expect(item.sourceID == source.id)
        #expect(item.remoteID == "post-1")
        #expect(item.title == "Story 1")
        #expect(item.body == "About story 1.")
        #expect(item.authorName == "Picks")
        #expect(item.url == "https://news.example.com/stories/1")
        #expect(item.publishedAt == now.addingTimeInterval(-60))
        #expect(http.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer sao_access-1")
        #expect(fetched.older == Cursor(rawValue: page("before=p2")))
        #expect(fetched.newer.flatMap(SammyFeedConnector.Validators.init(cursor:))?.etag == "W/\"v1\"")
    }

    @Test func anUnchangedFeedIsA304ThatKeepsItsCursor() async throws {
        let http = FakeHTTPClient { request in
            request.value(forHTTPHeaderField: "If-None-Match") == "W/\"v1\"" ? .init(status: 304, headers: ["ETag": "W/\"v1\""]) : articles(feedPage([1]))
        }
        let cursor = SammyFeedConnector.Validators(etag: "W/\"v1\"", accept: SammyNegotiation.either, format: .article).cursor
        let fetched = try await makeConnector(try makeAccount(http), http).fetch(fetchRequest(.newer, cursor: cursor), from: source)
        #expect(fetched.items.isEmpty)
        #expect(fetched.newer == cursor)
        #expect(http.requests.count == 1)
    }

    @Test func theTokenIsNeverInACursor() async throws {
        let http = FakeHTTPClient { _ in .init(headers: articleHeaders(["ETag": "W/\"v1\""]), body: feedPage([1], next: page("before=p2"))) }
        let fetched = try await makeConnector(try makeAccount(http), http).fetch(fetchRequest(.newer), from: source)
        for cursor in [fetched.newer, fetched.older].compactMap({ $0 }) {
            #expect(!cursor.rawValue.contains("sao_access-1"))
        }
    }

    @Test func catchingUpReadsBackUntilItReachesWhatItHas() async throws {
        let http = FakeHTTPClient { request in
            switch request.url?.query() {
            case nil: .init(headers: articleHeaders(["ETag": "W/\"v2\""]), body: feedPage([1, 2], next: page("page=2")))
            case "page=2": articles(feedPage([3, 4], next: page("page=3")))
            default: articles(feedPage([5, 6], next: page("page=4")))
            }
        }
        let request = fetchRequest(.newer, cursor: SammyFeedConnector.Validators(etag: "W/\"v1\"").cursor, stored: ["post-6"])
        let fetched = try await makeConnector(try makeAccount(http), http).fetch(request, from: source)
        #expect(fetched.items.map(\.remoteID) == ["post-1", "post-2", "post-3", "post-4", "post-5", "post-6"])
        #expect(http.requests.count == 3)
        #expect(fetched.newer.flatMap(SammyFeedConnector.Validators.init(cursor:))?.etag == "W/\"v2\"")
        #expect(http.requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "If-None-Match") == nil })
    }

    @Test func aCatchUpCutShortByThePageLimitCarriesOnAtTheNextFetch() async throws {
        let limit = SammyFeedConnector.maxCatchUpPages
        let http = FakeHTTPClient { request in
            let number = Int(request.url?.query()?.dropFirst("page=".count) ?? "") ?? 1
            return .init(headers: articleHeaders(number == 1 ? ["ETag": "W/\"v2\""] : [:]),
                         body: feedPage([2 * number - 1, 2 * number], next: page("page=\(number + 1)")))
        }
        let connector = makeConnector(try makeAccount(http), http)
        let stored = "post-\(2 * (limit + 10))"
        let first = try await connector.fetch(fetchRequest(.newer, cursor: SammyFeedConnector.Validators(etag: "W/\"v1\"").cursor, stored: [stored]), from: source)
        #expect(first.items.count == 2 * limit)
        #expect(http.requests.count == limit)
        let paused = try #require(first.newer.flatMap(SammyFeedConnector.Validators.init(cursor:)))
        #expect(paused.etag == "W/\"v2\"")
        #expect(paused.resume == page("page=\(limit + 1)"))

        let second = try await connector.fetch(fetchRequest(.newer, cursor: first.newer, stored: [stored]), from: source)
        #expect(second.items.map(\.remoteID) == ((2 * limit + 1)...(2 * (limit + 10))).map { "post-\($0)" })
        #expect(second.newer == SammyFeedConnector.Validators(etag: "W/\"v2\"", accept: SammyNegotiation.either, format: .article).cursor)
    }

    @Test func aResumeAddressOnAnotherServerIsNotFollowed() async throws {
        let http = FakeHTTPClient { _ in articles(feedPage([1])) }
        let cursor = SammyFeedConnector.Validators(etag: "W/\"v1\"", resume: "https://other.example/api/v1/feeds/x?page=9").cursor
        _ = try await makeConnector(try makeAccount(http), http).fetch(fetchRequest(.newer, cursor: cursor), from: source)
        #expect(http.requests.map(\.url?.absoluteString) == [feedURL])
    }

    @Test func catchingUpStopsAtTheRetentionWindow() async throws {
        let day = 24 * 60
        let http = FakeHTTPClient { request in
            let number = Int(request.url?.query()?.dropFirst("page=".count) ?? "") ?? 1
            return articles(feedPage([number * 10 * day], next: page("page=\(number + 1)")))
        }
        let request = fetchRequest(.newer, cursor: SammyFeedConnector.Validators(etag: "W/\"v1\"").cursor, stored: ["post-gone"])
        _ = try await makeConnector(try makeAccount(http), http).fetch(request, from: source)
        // 10, 20, 30 and then 40 days back, past the 30 days articles keep.
        #expect(http.requests.count == 4)
    }

    @Test func olderPagesFollowNextURLUntilTheEnd() async throws {
        let http = FakeHTTPClient { request in
            request.url?.query() == "page=2" ? articles(feedPage([3, 4], next: page("page=3"))) : articles(feedPage([5]))
        }
        let connector = makeConnector(try makeAccount(http), http)
        let second = try await connector.fetch(fetchRequest(.older, cursor: Cursor(rawValue: page("page=2"))), from: source)
        #expect(second.items.map(\.remoteID) == ["post-3", "post-4"])
        #expect(second.older == Cursor(rawValue: page("page=3")))
        let third = try await connector.fetch(fetchRequest(.older, cursor: second.older), from: source)
        #expect(third.items.map(\.remoteID) == ["post-5"])
        #expect(third.older == nil)
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer sao_access-1" })
    }

    @Test func aNextURLOnAnotherServerIsNotFollowed() async throws {
        let elsewhere = "https://other.example/api/v1/feeds/x?page=2"
        let http = FakeHTTPClient { _ in articles(feedPage([1], next: elsewhere)) }
        let connector = makeConnector(try makeAccount(http), http)
        let first = try await connector.fetch(fetchRequest(.newer), from: source)
        #expect(first.older == nil)
        // Nor while catching up, nor from a cursor that names it.
        _ = try await connector.fetch(fetchRequest(.newer, cursor: SammyFeedConnector.Validators(etag: "x").cursor, stored: ["none"]), from: source)
        let older = try await connector.fetch(fetchRequest(.older, cursor: Cursor(rawValue: elsewhere)), from: source)
        #expect(older.items.isEmpty)
        #expect(!http.requests.contains { $0.url?.host() == "other.example" })
    }

    @Test func aRefusedTokenShowsAsSignedOutThroughTheRefresher() async throws {
        for status in [401, 403] {
            let store = try InfluxStore.inMemory()
            try await store.save(sources: [source])
            let http = FakeHTTPClient { _ in .init(status: status) }
            let outcome = try await Refresher(store: store).refresh(source, with: makeConnector(try makeAccount(http), http), now: now)
            #expect(outcome == .failed(.unauthorized))
            #expect(try await store.fetchState(sourceID: source.id)?.problem == .signedOut)
        }
    }

    @Test func aRateLimitWaitsForRetryAfter() async throws {
        let http = FakeHTTPClient { _ in .init(status: 429, headers: ["Retry-After": "120"]) }
        let request = fetchRequest(.newer)
        await #expect(throws: ConnectorError.rateLimited(retryAfter: request.now.addingTimeInterval(120))) {
            try await makeConnector(try makeAccount(http), http).fetch(request, from: source)
        }
    }

    @Test func aGoneFeedIsNotFoundAndABodyThatIsNotAFeedIsABadResponse() async throws {
        let gone = FakeHTTPClient { _ in .init(status: 404) }
        await #expect(throws: ConnectorError.notFound) { try await makeConnector(try makeAccount(gone), gone).fetch(fetchRequest(.newer), from: source) }
        let garbled = FakeHTTPClient { _ in .init(headers: articleHeaders(), text: "<html>") }
        await #expect(throws: ConnectorError.badResponse("not a JSON Feed")) {
            try await makeConnector(try makeAccount(garbled), garbled).fetch(fetchRequest(.newer), from: source)
        }
        let list = FakeHTTPClient { _ in .init(headers: listHeaders, text: "{\"feeds\": []}") }
        await #expect(throws: ConnectorError.self) { try await makeConnector(try makeAccount(list), list).availableSources() }
    }

    @Test func aFeedThatDoesNotAnswerInTimeIsOffline() async throws {
        struct Silent: HTTPClient {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await Task.sleep(for: .seconds(30)); throw CancellationError() }
            func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) { try await send(request) }
            func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) { try await send(request) }
            func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await send(request) }
        }
        let account = try makeAccount(Silent())
        let connector = SammyFeedConnector(account: account, http: FakeHTTPClient { _ in .init() }, fetchLimit: .milliseconds(50))
        await #expect(throws: ConnectorError.offline) { try await connector.fetch(fetchRequest(.newer), from: source) }
        #expect(RSSConnector.fetchLimit == .seconds(60))
    }

    @Test func aPostersImageIsFetchedWithoutTheToken() async throws {
        let body = json([
            "version": "https://jsonfeed.org/version/1.1", "title": "Picks",
            "items": [["id": "post-1", "url": "https://news.example.com/stories/1", "title": "Story 1", "image": "https://sammy.example/media/feed-images/abc"]],
        ])
        let http = FakeHTTPClient { request in
            request.url?.path.hasPrefix("/media/") == true ? .init(body: MediaFixtures.jpeg(width: 352, height: 528)) : articles(body)
        }
        let fetched = try await makeConnector(try makeAccount(http), http).fetch(fetchRequest(.newer), from: source)
        let media = try #require(fetched.items.first?.media.first)
        #expect(media.url == "https://sammy.example/media/feed-images/abc")
        #expect(media.width == 352 && media.height == 528)
        let image = try #require(http.requests.first { $0.url?.path.hasPrefix("/media/") == true })
        #expect(image.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func pagesLandThroughTheRefresherAndFillTheGapThroughNextURL() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [source])
        let http = FakeHTTPClient { request in
            switch request.url?.query() {
            case nil: .init(headers: articleHeaders(["ETag": "W/\"v1\""]), body: feedPage([1, 2], next: page("page=2")))
            case "page=2": articles(feedPage([3, 4], next: page("page=3")))
            default: articles(feedPage([5]))
            }
        }
        let connector = makeConnector(try makeAccount(http), http)
        let refresher = Refresher(store: store)
        #expect(try await refresher.refresh(source, with: connector, now: now) == .fetched(newItems: 2))
        #expect(try await store.rows().map(\.title) == ["Story 2", "Story 1"])
        // The reader's place is further back than the first page.
        let pages = try await refresher.fillGap(of: source, with: connector, backTo: now.addingTimeInterval(-60 * 10), now: now)
        #expect(pages == 2)
        #expect(try await store.rows().map(\.title) == ["Story 5", "Story 4", "Story 3", "Story 2", "Story 1"])
        #expect(!http.requests.contains { $0.url?.host() != "sammy.example" })
    }
}

// MARK: - JSON Feed

@Suite struct SammyJSONFeed_ {
    @Test func itemsDecodeWithNumericIDsAndMissingFields() throws {
        let feed = try JSONFeed.decode(json([
            "version": "https://jsonfeed.org/version/1.1",
            "items": [
                ["id": 42, "content_text": "Numbered."],
                ["id": "a", "title": 7, "date_published": "not a date", "_sammy": ["metascore": "high"]],
                "not an item",
                ["id": "b", "_sammy": ["metascore": ["value": 74, "max": 100, "band": "favorable"], "image_size": ["width": 1]]],
            ],
        ]))
        #expect(feed.title == nil && feed.nextURL == nil && feed.feedURL == nil)
        #expect(feed.items.map(\.id) == ["42", "a", "b"])
        #expect(feed.items[1].title == nil)
        #expect(feed.items[1].datePublished == nil)
        #expect(feed.items[1].sammy?.metascore == nil)
        #expect(feed.items[2].sammy?.metascore == .init(value: 74, max: 100, band: "favorable"))
        #expect(feed.items[2].sammy?.imageSize == nil)
    }

    @Test func aBodyThatIsNotJSONFeedOneFails() throws {
        #expect(throws: (any Error).self) { try JSONFeed.decode(json(["version": "https://jsonfeed.org/version/2", "items": []])) }
        #expect(throws: (any Error).self) { try JSONFeed.decode(json(["items": []])) }
        #expect(throws: (any Error).self) { try JSONFeed.decode(Data("[]".utf8)) }
        #expect(try JSONFeed.decode(json(["version": "https://jsonfeed.org/version/1"])).items.isEmpty)
    }

    private func mapped(_ fields: [String: Any], feedTitle: String = "Movies: first scores") -> Item? {
        let feed = try! JSONFeed.decode(json(["version": "https://jsonfeed.org/version/1.1", "title": feedTitle, "items": [fields]]))
        return feed.items.first.flatMap { JSONFeedMapper.item(from: $0, feed: feed, source: source, fetchedAt: now) }
    }

    @Test func theBodyIsTheFirstOfSummaryTextAndHTMLThatHasText() throws {
        #expect(mapped(["id": "1", "summary": "Summary.", "content_text": "Text.", "content_html": "<p>HTML.</p>"])?.body == "Summary.")
        #expect(mapped(["id": "1", "summary": "  ", "content_text": "Text.", "content_html": "<p>HTML.</p>"])?.body == "Text.")
        #expect(mapped(["id": "1", "summary": "", "content_text": "", "content_html": "<p>HTML &amp; more.</p>"])?.body == "HTML & more.")
        // Plain-text fields are text, not markup.
        #expect(mapped(["id": "1", "content_text": "a <b>bold</b> & claim"])?.body == "a <b>bold</b> & claim")
    }

    @Test func theBodyIsCappedAtFourHundredCharacters() throws {
        for key in ["summary", "content_text", "content_html"] {
            let body = try #require(mapped(["id": "1", key: String(repeating: "word ", count: 200)])?.body)
            #expect(body.count <= 400)
            #expect(body.count > 300)
        }
        #expect(JSONFeedMapper.bodyLimit == 400)
    }

    @Test func fieldsMapToTheArticle() throws {
        let item = try #require(mapped([
            "id": " urn:uuid:0193a1b2-0000-7000-8000-00000000a003 ", "url": "https://www.example.com/movie/x/",
            "title": "Film & \"Friends\" <Three>", "summary": "🟢 65 · Out Nov 12, 2026", "date_published": "2026-10-30T10:07:12Z",
        ]))
        #expect(item.remoteID == "urn:uuid:0193a1b2-0000-7000-8000-00000000a003")
        // A global URI is the merge key as it is.
        #expect(item.mergeKey == "urn:uuid:0193a1b2-0000-7000-8000-00000000a003")
        #expect(item.title == "Film & \"Friends\" <Three>")
        #expect(item.body == "🟢 65 · Out Nov 12, 2026")
        #expect(item.url == "https://www.example.com/movie/x/")
        #expect(item.authorName == "Movies: first scores")
        #expect(item.authorHandle == "example.com")
        #expect(item.publishedAt == FeedDate.iso8601("2026-10-30T10:07:12Z"))
        #expect(item.fetchedAt == now)
        #expect(item.kind == .article)
    }

    @Test func anItemWithNothingToShowOrNoIDIsDropped() {
        #expect(mapped(["id": "1"]) == nil)
        #expect(mapped(["id": "1", "title": " ", "summary": ""]) == nil)
        #expect(mapped(["title": "No ID", "summary": "x"]) == nil)
        #expect(mapped(["id": "1", "title": "Only a title"])?.body == "")
        // A feed-local ID merges within its feed when there is no link.
        #expect(mapped(["id": "local", "summary": "x"])?.mergeKey == "\(source.id)#local")
    }

    @Test func anUndatedItemIsDatedWhenItWasFetched() {
        #expect(mapped(["id": "1", "summary": "x"])?.publishedAt == now)
    }
}
