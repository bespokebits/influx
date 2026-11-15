import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import InfluxKit

/// Answers `https://sammy.example/…` and `https://social.example/…` with a
/// 302 to another host and anything else with a page, recording every
/// request it is sent, so a real URLSession can be watched following, or
/// refusing, a redirect.
final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex<[URLRequest]>([])
    static let elsewhere = URL(string: "https://elsewhere.example/stolen")!
    static let redirecting: Set<String> = ["sammy.example", "social.example"]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0.append(request) }
        let url = request.url!
        guard let host = url.host, Self.redirecting.contains(host) else {
            answer(status: 200, url: url, body: Data("taken".utf8))
            return
        }
        if url.path == "/unchanged" {
            answer(status: 304, url: url, headers: ["ETag": "W/\"v1\""], body: Data())
            return
        }
        let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": Self.elsewhere.absoluteString])!
        #if canImport(FoundationNetworking)
        // FoundationNetworking follows redirects only for its own HTTP
        // loader, so here the 302 is the answer, as a refused redirect is.
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
        #else
        var next = URLRequest(url: Self.elsewhere)
        next.allHTTPHeaderFields = request.allHTTPHeaderFields
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
        #endif
    }

    override func stopLoading() {}

    private func answer(status: Int, url: URL, headers: [String: String] = [:], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// A URLSession whose every request goes to this protocol.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingProtocol.self]
        return URLSession(configuration: configuration)
    }
}

/// `sendRefusingRedirects` on the real URLSession, not the fake: a stub
/// protocol answers with a redirect to another host, and the request that
/// carries the token must be the only one made.
@Suite(.serialized) struct HTTPClientRedirectTests {
    private func tokenRequest(_ path: String = "/api/v1/feeds/f1") -> URLRequest {
        var request = URLRequest(url: URL(string: "https://sammy.example\(path)")!)
        request.setValue("Bearer sao_secret", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func aRedirectIsRefusedAfterExactlyOneRequest() async throws {
        RedirectingProtocol.requests.withLock { $0.removeAll() }
        await #expect(throws: ConnectorError.badResponse("refused a redirect (HTTP 302)")) {
            try await RedirectingProtocol.session().sendRefusingRedirects(tokenRequest())
        }
        let sent = RedirectingProtocol.requests.withLock { $0 }
        #expect(sent.count == 1)
        #expect(sent.first?.url?.host == "sammy.example")
        #expect(!sent.contains { $0.url?.host == "elsewhere.example" })
    }

    @Test func notModifiedIsAnAnswerNotARedirect() async throws {
        RedirectingProtocol.requests.withLock { $0.removeAll() }
        let (_, response) = try await RedirectingProtocol.session().sendRefusingRedirects(tokenRequest("/unchanged"))
        #expect(response.statusCode == 304)
        #expect(RedirectingProtocol.requests.withLock { $0.count } == 1)
    }

    @Test func aSammyAccountsRequestIsNotRedirectedThroughTheRealSession() async throws {
        RedirectingProtocol.requests.withLock { $0.removeAll() }
        let session = SammySession(issuer: URL(string: "https://sammy.example")!, revocationEndpoint: nil, accessToken: "sao_secret", subject: "s1")
        let credentials = InMemoryCredentialStore()
        try credentials.save(session, for: session.accountID)
        let account = SammyAccount(session: session, http: RedirectingProtocol.session(), credentials: credentials)
        await #expect(throws: ConnectorError.badResponse("refused a redirect (HTTP 302)")) {
            try await account.send(URLRequest(url: URL(string: "https://sammy.example/api/v1/feeds")!))
        }
        #expect(RedirectingProtocol.requests.withLock { $0.map(\.url?.host) } == ["sammy.example"])
    }

    /// A Mastodon token reads and writes the account, so the request that
    /// carries it is the only one made when the instance answers with a
    /// redirect.
    @Test func aMastodonClientsRequestIsNotRedirectedThroughTheRealSession() async throws {
        RedirectingProtocol.requests.withLock { $0.removeAll() }
        let client = MastodonClient(instance: URL(string: "https://social.example")!, accessToken: "secret", http: RedirectingProtocol.session())
        await #expect(throws: ConnectorError.badResponse("refused a redirect (HTTP 302)")) {
            _ = try await client.verifyCredentials()
        }
        let sent = RedirectingProtocol.requests.withLock { $0 }
        #expect(sent.map(\.url?.host) == ["social.example"])
        #expect(sent.first?.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    }

    /// Registering the app is the first sign-in request; the ones after it
    /// carry the app's secret and the code through the same path.
    @Test func aMastodonSignInIsNotRedirectedThroughTheRealSession() async throws {
        RedirectingProtocol.requests.withLock { $0.removeAll() }
        let signIn = MastodonSignIn(http: RedirectingProtocol.session(), crypto: .fake(), credentials: InMemoryCredentialStore())
        await #expect(throws: MastodonSignInError.failed(.badResponse("refused a redirect (HTTP 302)"))) {
            _ = try await signIn.begin(instance: "social.example")
        }
        #expect(RedirectingProtocol.requests.withLock { $0.map(\.url?.host) } == ["social.example"])
    }

    @Test func aMastodonSignOutsRevocationIsNotRedirectedThroughTheRealSession() async throws {
        RedirectingProtocol.requests.withLock { $0.removeAll() }
        let signIn = MastodonSignIn(http: RedirectingProtocol.session(), crypto: .fake(), credentials: InMemoryCredentialStore())
        let session = MastodonSession(
            instance: URL(string: "https://social.example")!, accountID: "@me@social.example",
            app: .init(clientId: "client", clientSecret: "client-secret"), accessToken: "secret", scope: "read"
        )
        try await signIn.signOut(session)
        #expect(RedirectingProtocol.requests.withLock { $0.map(\.url?.host) } == ["social.example"])
    }

    #if !canImport(FoundationNetworking)
    /// The stub really redirects: a plain `send` follows it to the other
    /// host, which is what `sendRefusingRedirects` prevents.
    @Test func aPlainSendFollowsTheSameRedirect() async throws {
        RedirectingProtocol.requests.withLock { $0.removeAll() }
        let (data, response) = try await RedirectingProtocol.session().send(tokenRequest())
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "taken")
        #expect(RedirectingProtocol.requests.withLock { $0.map(\.url?.host) } == ["sammy.example", "elsewhere.example"])
    }
    #endif
}
