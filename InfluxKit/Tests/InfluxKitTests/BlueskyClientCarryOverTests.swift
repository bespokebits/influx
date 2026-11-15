import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

private let now = Date(timeIntervalSince1970: 1_793_000_000)
private let fluxClient = "https://flux.bespokebits.dev/oauth/client-metadata.json"
private let influxClient = "https://influx.bespokebits.dev/oauth/client-metadata.json"

/// A session as Influx stored it before sessions recorded their client.
private func storedBeforeTheRename() throws -> BlueskySession {
    let session = BlueskySession(
        identity: ATIdentity(did: "did:plc:ana", handle: "ana.bsky.social", pds: URL(string: "https://pds.example.com")!),
        issuer: "https://auth.example.com", tokenEndpoint: URL(string: "https://auth.example.com/oauth/token")!,
        accessToken: "access-0", refreshToken: "refresh-0", expiresAt: now,
        scope: "atproto transition:generic", dpopKey: Data("key".utf8), clientKeyID: "key-1"
    )
    let stored = try JSONEncoder().encode(session)
    let fields = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
    #expect(fields["clientID"] == nil)
    return try JSONDecoder().decode(BlueskySession.self, from: stored)
}

private func assertionHosts(_ http: FakeHTTPClient) -> [String] {
    http.requests.filter { $0.url?.path == "/oauth/assertion" }.compactMap { $0.url?.host }
}

/// The app's two Bluesky clients (ADR 0032): sessions from before the
/// rename keep the flux one, and new sign-ins use the influx one.
@Suite struct BlueskyClientCarryOver {
    @Test func aSessionFromBeforeTheRenameRefreshesWithTheFluxClient() async throws {
        let http = blueskyServers()
        let oauth = BlueskyOAuth.influx(http: http, crypto: .fake(), now: { now })
        let session = try storedBeforeTheRename()
        #expect(session.clientID == nil)

        let (refreshed, _) = try await oauth.refresh(session, nonce: "nonce-1")
        let refresh = try #require(http.requests.last { $0.url?.path == "/oauth/token" })
        #expect(formFields(refresh)["client_id"] == fluxClient)
        #expect(formFields(refresh)["client_assertion"] == "signed-by-flux.bespokebits.dev")
        #expect(assertionHosts(http) == ["flux.bespokebits.dev"])
        // Still the flux client's session, saying it or not.
        #expect(refreshed.refreshToken == "refresh-1")
        #expect(refreshed.startedWithClient == fluxClient)

        try await oauth.revoke(refreshed, nonce: "nonce-2")
        let revoke = try #require(http.requests.last { $0.url?.path == "/oauth/revoke" })
        #expect(formFields(revoke)["client_id"] == fluxClient)
        #expect(assertionHosts(http) == ["flux.bespokebits.dev", "flux.bespokebits.dev"])
    }

    @Test func aNewSignInUsesTheInfluxClientAndKeepsIt() async throws {
        let http = blueskyServers()
        let oauth = BlueskyOAuth.influx(http: http, crypto: .fake(), now: { now })
        let pending = try await oauth.begin(account: "ana.bsky.social")
        let par = try #require(http.requests.last { $0.url?.path == "/oauth/par" })
        #expect(formFields(par)["client_id"] == influxClient)
        #expect(formFields(par)["redirect_uri"] == "https://influx.bespokebits.dev/oauth/callback")
        #expect(URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "client_id" }?.value == influxClient)

        var callback = URLComponents(string: "https://influx.bespokebits.dev/oauth/callback")!
        callback.queryItems = [
            URLQueryItem(name: "state", value: pending.state),
            URLQueryItem(name: "iss", value: "https://auth.example.com"),
            URLQueryItem(name: "code", value: "code-1"),
        ]
        let session = try await oauth.complete(pending, callback: callback.url!)
        #expect(session.clientID == influxClient)
        let token = try #require(http.requests.last { $0.url?.path == "/oauth/token" })
        #expect(formFields(token)["client_id"] == influxClient)

        // The keychain keeps the client with the session.
        let stored = try JSONDecoder().decode(BlueskySession.self, from: JSONEncoder().encode(session))
        #expect(stored == session)
        #expect(stored.clientID == influxClient)

        _ = try await oauth.refresh(stored, nonce: "nonce-1")
        let refresh = try #require(http.requests.last { $0.url?.path == "/oauth/token" })
        #expect(formFields(refresh)["client_id"] == influxClient)
        #expect(formFields(refresh)["client_assertion"] == "signed-by-influx.bespokebits.dev")
        #expect(Set(assertionHosts(http)) == ["influx.bespokebits.dev"])
    }

    @Test func aSessionOfAClientThisBuildDoesntKnowSignsInAgain() async throws {
        let http = blueskyServers()
        let oauth = BlueskyOAuth.influx(http: http, crypto: .fake(), now: { now })
        var session = try storedBeforeTheRename()
        session.clientID = "https://elsewhere.example.com/oauth/client-metadata.json"
        await #expect(throws: BlueskyError.signInRequired) {
            try await oauth.refresh(session, nonce: "nonce-1")
        }
        #expect(http.requests.isEmpty)
    }
}
