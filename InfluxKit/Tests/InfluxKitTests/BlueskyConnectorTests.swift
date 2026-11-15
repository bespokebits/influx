import Foundation
import Synchronization
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

private let now = Date(timeIntervalSince1970: 1_793_000_000)
private let did = "did:plc:me"
private let following = Source(id: BlueskyConnector.followingSourceID(did: did), kind: .blueskyFollowing, accountID: did, title: "Following", colorIndex: 0)
private let feedURI = "at://did:plc:gen/app.bsky.feed.generator/cats"
private let cats = Source(id: BlueskyConnector.feedSourceID(did: did, feed: feedURI), kind: .blueskyFeed, accountID: did, title: "Cats", colorIndex: 1)

private func makeSession(expiresAt: Date = now.addingTimeInterval(600)) -> BlueskySession {
    BlueskySession(
        identity: ATIdentity(did: did, handle: "me.test", pds: URL(string: "https://pds.example.com")!),
        issuer: "https://auth.example.com", tokenEndpoint: URL(string: "https://auth.example.com/oauth/token")!,
        accessToken: "access-1", refreshToken: "refresh-1", expiresAt: expiresAt,
        scope: "atproto transition:generic", dpopKey: Data("key".utf8),
        clientID: BlueskyClientConfiguration.influxPublic.clientID
    )
}

private func makeAccount(_ http: any HTTPClient, session: BlueskySession = makeSession(), credentials: any CredentialStore = InMemoryCredentialStore()) throws -> BlueskyAccount {
    try credentials.save(session, for: session.accountID)
    return try BlueskyAccount(session: session, oauth: BlueskyOAuth(configuration: .influxPublic, http: http, crypto: .fake(), now: { now }), credentials: credentials)
}

private func makeConnector(_ http: FakeHTTPClient) throws -> BlueskyConnector {
    try BlueskyConnector(account: makeAccount(http), resolver: .testing(http))
}

private func query(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

/// A feed page of posts at the given minutes before `now`, newest first.
private func feedPage(_ minutesAgo: [Int], cursor: String?) -> Data {
    let feed = minutesAgo.map { minutes -> [String: Any] in
        let date = ATDate.format(now.addingTimeInterval(TimeInterval(-60 * minutes)))
        return [
            "post": [
                "uri": "at://did:plc:ana/app.bsky.feed.post/m\(minutes)", "cid": "c\(minutes)",
                "author": ["did": "did:plc:ana", "handle": "ana.test"],
                "record": ["text": "\(minutes) minutes ago", "createdAt": date],
                "indexedAt": date,
            ],
        ]
    }
    var body: [String: Any] = ["feed": feed]
    if let cursor { body["cursor"] = cursor }
    return try! JSONSerialization.data(withJSONObject: body)
}

/// The authorization server's metadata, with a revocation endpoint that
/// answers with `revokeStatus`.
private func revokingServer(revokeStatus: Int) -> FakeHTTPClient {
    FakeHTTPClient { revokingResponse($0, revokeStatus: revokeStatus) }
}

private func revokingResponse(_ request: URLRequest, revokeStatus: Int) -> FakeHTTPClient.Response {
    switch request.url?.absoluteString {
    case "https://auth.example.com/.well-known/oauth-authorization-server":
        return .init(body: try! JSONSerialization.data(withJSONObject: [
            "issuer": "https://auth.example.com",
            "authorization_endpoint": "https://auth.example.com/oauth/authorize",
            "token_endpoint": "https://auth.example.com/oauth/token",
            "pushed_authorization_request_endpoint": "https://auth.example.com/oauth/par",
            "revocation_endpoint": "https://auth.example.com/oauth/revoke",
            "dpop_signing_alg_values_supported": ["ES256"],
        ]))
    case "https://auth.example.com/oauth/revoke":
        return .init(status: revokeStatus)
    default:
        return .init(body: feedPage([1], cursor: nil))
    }
}

private func fetchRequest(_ direction: FetchDirection, cursor: String? = nil) -> FetchRequest {
    FetchRequest(direction: direction, cursor: cursor.map(Cursor.init(rawValue:)), notBefore: now.addingTimeInterval(-InfluxStore.postRetention), now: now)
}

@Suite struct BlueskyAccount_ {
    @Test func requestsCarryTheBoundTokenAndProxy() async throws {
        let http = FakeHTTPClient { _ in .init(body: feedPage([1], cursor: nil)) }
        _ = try await makeAccount(http).timeline(cursor: "abc")
        let sent = try #require(http.requests.first)
        #expect(sent.url?.path == "/xrpc/app.bsky.feed.getTimeline")
        #expect(query(sent, "cursor") == "abc")
        #expect(query(sent, "limit") == "100")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "DPoP access-1")
        #expect(sent.value(forHTTPHeaderField: "atproto-proxy") == "did:web:api.bsky.app#bsky_appview")
        let claims = try proofClaims(sent)
        #expect(claims.ath == Data("sha256:access-1".utf8).base64URLEncoded)
        #expect(claims.htu == "https://pds.example.com/xrpc/app.bsky.feed.getTimeline")
    }

    @Test func resourceNonceIsLearnedAndRetried() async throws {
        let http = FakeHTTPClient { request in
            guard try proofClaims(request).nonce == "pds-nonce" else {
                return .init(status: 401, headers: ["DPoP-Nonce": "pds-nonce", "WWW-Authenticate": #"DPoP error="use_dpop_nonce""#], text: "")
            }
            return .init(body: feedPage([1], cursor: nil))
        }
        let account = try makeAccount(http)
        _ = try await account.timeline(cursor: nil)
        _ = try await account.timeline(cursor: nil)
        // One refusal, then the nonce is kept for later requests.
        #expect(http.requests.count == 3)
    }

    @Test func anExpiredTokenIsRefreshedOnceAndStored() async throws {
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                #expect(formFields(request)["refresh_token"] == "refresh-1")
                #expect(formFields(request)["grant_type"] == "refresh_token")
                return .init(body: try! JSONSerialization.data(withJSONObject: [
                    "access_token": "access-2", "token_type": "DPoP", "refresh_token": "refresh-2",
                    "expires_in": 300, "scope": "atproto transition:generic", "sub": did,
                ]))
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP access-2")
            return .init(body: feedPage([1], cursor: nil))
        }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, session: makeSession(expiresAt: now.addingTimeInterval(30)), credentials: credentials)
        async let first = account.timeline(cursor: nil)
        async let second = account.timeline(cursor: nil)
        _ = try await (first, second)

        #expect(http.requests.filter { $0.url?.path == "/oauth/token" }.count == 1)
        let stored = try #require(try credentials.load(BlueskySession.self, for: did))
        #expect(stored.refreshToken == "refresh-2")
        #expect(stored.accessToken == "access-2")
        #expect(await account.session.expiresAt == now.addingTimeInterval(300))
    }

    @Test func aTokenThePDSRejectsIsRefreshed() async throws {
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(body: try! JSONSerialization.data(withJSONObject: [
                    "access_token": "access-2", "token_type": "DPoP", "refresh_token": "refresh-2", "expires_in": 300, "scope": "atproto",
                ]))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "DPoP access-1" {
                return .init(status: 401, headers: ["WWW-Authenticate": #"DPoP error="invalid_token""#], text: "")
            }
            return .init(body: feedPage([1], cursor: nil))
        }
        let page = try await makeAccount(http).timeline(cursor: nil)
        #expect(page.feed.count == 1)
    }

    @Test func aRequestRefusedWithAFreshTokenIsNotASignOut() async throws {
        // A 401 the refreshed token can't clear, or a 403, is one request's
        // problem: only the token endpoint ends the session.
        for status in [401, 403] {
            let http = FakeHTTPClient { request in
                if request.url?.path == "/oauth/token" {
                    return .init(body: try! JSONSerialization.data(withJSONObject: [
                        "access_token": "access-2", "token_type": "DPoP", "refresh_token": "refresh-2", "expires_in": 300, "scope": "atproto",
                    ]))
                }
                return .init(status: status, body: try! JSONSerialization.data(withJSONObject: ["error": "AuthRequired"]))
            }
            await #expect(throws: ConnectorError.badResponse("HTTP \(status): AuthRequired")) {
                try await makeAccount(http).timeline(cursor: nil)
            }
            // A 401 is tried once more with a fresh token first.
            #expect(http.requests.filter { $0.url?.path == "/oauth/token" }.count == (status == 401 ? 1 : 0))
        }
    }

    @Test func aRefreshThatCantBeStoredIsKeptAndStoredLater() async throws {
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(body: try! JSONSerialization.data(withJSONObject: [
                    "access_token": "access-2", "token_type": "DPoP", "refresh_token": "refresh-2",
                    "expires_in": 300, "scope": "atproto transition:generic", "sub": did,
                ]))
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP access-2")
            return .init(body: feedPage([1], cursor: nil))
        }
        let credentials = FailingCredentialStore()
        let account = try makeAccount(http, session: makeSession(expiresAt: now.addingTimeInterval(30)), credentials: credentials)
        credentials.failing.withLock { $0 = true }
        _ = try await account.timeline(cursor: nil)
        #expect(await account.session.refreshToken == "refresh-2")
        #expect(try credentials.load(BlueskySession.self, for: did)?.refreshToken == "refresh-1")

        credentials.failing.withLock { $0 = false }
        _ = try await account.timeline(cursor: nil)
        #expect(try credentials.load(BlueskySession.self, for: did)?.refreshToken == "refresh-2")
        #expect(http.requests.filter { $0.url?.path == "/oauth/token" }.count == 1)
    }

    @Test func aLateRejectionOfAnOldTokenDoesNotRefreshAgain() async throws {
        // Two requests go out with access-1. The first is rejected and
        // refreshes; the second's rejection only arrives after that.
        let fake = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(body: try! JSONSerialization.data(withJSONObject: [
                    "access_token": "access-2", "token_type": "DPoP", "refresh_token": "refresh-2", "expires_in": 300, "scope": "atproto",
                ]))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "DPoP access-1" {
                return .init(status: 401, headers: ["WWW-Authenticate": #"DPoP error="invalid_token""#], text: "")
            }
            return .init(body: feedPage([1], cursor: nil))
        }
        let http = GatedHTTPClient(fake)
        let account = try makeAccount(http)
        async let first = account.timeline(cursor: nil, limit: 1)
        async let second = account.timeline(cursor: nil, limit: 2)
        _ = try await (first, second)
        #expect(fake.requests.filter { $0.url?.path == "/oauth/token" }.count == 1)
    }

    @Test func aTokenThatStillWorksIsUsedWhileRefreshIsDown() async throws {
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(status: 503, text: "")
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP access-1")
            return .init(body: feedPage([1], cursor: nil))
        }
        let account = try makeAccount(http, session: makeSession(expiresAt: now.addingTimeInterval(30)))
        let page = try await account.timeline(cursor: nil)
        #expect(page.feed.count == 1)

        // An expired token isn't tried.
        let sent = http.requests.count
        let expired = try makeAccount(http, session: makeSession(expiresAt: now))
        await #expect(throws: (any Error).self) {
            try await expired.timeline(cursor: nil)
        }
        #expect(http.requests.dropFirst(sent).allSatisfy { $0.url?.path == "/oauth/token" })
    }

    @Test func anEndedSessionSignsOutEvenWithTimeLeft() async throws {
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(status: 400, body: try! JSONSerialization.data(withJSONObject: ["error": "invalid_grant"]))
            }
            return .init(body: feedPage([1], cursor: nil))
        }
        let account = try makeAccount(http, session: makeSession(expiresAt: now.addingTimeInterval(30)))
        await #expect(throws: ConnectorError.unauthorized) {
            try await account.timeline(cursor: nil)
        }
    }

    @Test func aRefreshRefusedForAnotherReasonIsNotASignOut() async throws {
        // The signing service being down (invalid_client) leaves the
        // session as it was, so the account isn't shown signed out.
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(status: 400, body: try! JSONSerialization.data(withJSONObject: ["error": "invalid_client"]))
            }
            return .init(body: feedPage([1], cursor: nil))
        }
        let account = try makeAccount(http, session: makeSession(expiresAt: now))
        await #expect(throws: ConnectorError.badResponse("oauth invalid_client")) {
            try await account.timeline(cursor: nil)
        }
        // The next request tries the refresh again rather than failing at once.
        let sent = http.requests.count
        _ = try? await account.timeline(cursor: nil)
        #expect(http.requests.dropFirst(sent).contains { $0.url?.path == "/oauth/token" })
    }

    @Test func aSessionAnotherDeviceRefreshedIsUsedWithoutRefreshing() async throws {
        let http = FakeHTTPClient { request in
            #expect(request.url?.path != "/oauth/token")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP access-2")
            return .init(body: feedPage([1], cursor: nil))
        }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, session: makeSession(expiresAt: now.addingTimeInterval(30)), credentials: credentials)
        var newer = makeSession(expiresAt: now.addingTimeInterval(600))
        newer.accessToken = "access-2"
        newer.refreshToken = "refresh-2"
        try credentials.save(newer, for: did)

        _ = try await account.timeline(cursor: nil)
        #expect(await account.session.refreshToken == "refresh-2")
    }

    @Test func aRefusedRefreshTakesTheSessionAnotherDeviceStored() async throws {
        // The other device spends refresh-1 first and stores refresh-2,
        // which arrives here while this device's refresh is out.
        let credentials = InMemoryCredentialStore()
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                var newer = makeSession(expiresAt: now.addingTimeInterval(600))
                newer.accessToken = "access-2"
                newer.refreshToken = "refresh-2"
                try! credentials.save(newer, for: did)
                return .init(status: 400, body: try! JSONSerialization.data(withJSONObject: ["error": "invalid_grant"]))
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP access-2")
            return .init(body: feedPage([1], cursor: nil))
        }
        let account = try makeAccount(http, session: makeSession(expiresAt: now), credentials: credentials)
        let page = try await account.timeline(cursor: nil)
        #expect(page.feed.count == 1)
        #expect(await account.session.refreshToken == "refresh-2")
    }

    @Test func anEndedSessionSignsOut() async throws {
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(status: 400, body: try! JSONSerialization.data(withJSONObject: ["error": "invalid_grant"]))
            }
            return .init(body: feedPage([1], cursor: nil))
        }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, session: makeSession(expiresAt: now), credentials: credentials)
        await #expect(throws: ConnectorError.unauthorized) {
            try await account.timeline(cursor: nil)
        }
        // The credentials stay: deleting them would delete them on the
        // reader's other devices too, which may hold a newer copy.
        #expect(try credentials.load(BlueskySession.self, for: did)?.refreshToken == "refresh-1")
        // Later requests fail at once, without spending the token again.
        let sent = http.requests.count
        await #expect(throws: ConnectorError.unauthorized) {
            try await account.timeline(cursor: nil)
        }
        #expect(http.requests.count == sent)
    }

    @Test func aSessionStoredLaterRevivesAnEndedOne() async throws {
        // This device's refresh is refused before the other device's new
        // session reaches it through iCloud Keychain.
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(status: 400, body: try! JSONSerialization.data(withJSONObject: ["error": "invalid_grant"]))
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "DPoP access-2")
            return .init(body: feedPage([1], cursor: nil))
        }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, session: makeSession(expiresAt: now), credentials: credentials)
        await #expect(throws: ConnectorError.unauthorized) {
            try await account.timeline(cursor: nil)
        }
        var newer = makeSession(expiresAt: now.addingTimeInterval(600))
        newer.accessToken = "access-2"
        newer.refreshToken = "refresh-2"
        try credentials.save(newer, for: did)

        _ = try await account.timeline(cursor: nil)
        #expect(await account.session.refreshToken == "refresh-2")
    }

    @Test func signingOutRevokesTheRefreshToken() async throws {
        let http = revokingServer(revokeStatus: 200)
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, credentials: credentials)
        await account.signOut()

        #expect(try credentials.load(BlueskySession.self, for: did) == nil)
        let revoke = try #require(http.requests.last { $0.url?.path == "/oauth/revoke" })
        #expect(revoke.httpMethod == "POST")
        #expect(formFields(revoke)["token"] == "refresh-1")
        #expect(formFields(revoke)["token_type_hint"] == "refresh_token")
        #expect(formFields(revoke)["client_id"] == BlueskyClientConfiguration.influxPublic.clientID)
        // The token is DPoP-bound, so the request carries a proof for it.
        #expect(try proofClaims(revoke).htu == "https://auth.example.com/oauth/revoke")
        // Later requests fail at once, without touching the network.
        let sent = http.requests.count
        await #expect(throws: ConnectorError.unauthorized) {
            try await account.timeline(cursor: nil)
        }
        #expect(http.requests.count == sent)
    }

    @Test func signingOutCompletesWhenRevocationFails() async throws {
        for status in [500, 404] {
            let http = revokingServer(revokeStatus: status)
            let credentials = InMemoryCredentialStore()
            let account = try makeAccount(http, credentials: credentials)
            await account.signOut()
            #expect(http.requests.contains { $0.url?.path == "/oauth/revoke" })
            #expect(try credentials.load(BlueskySession.self, for: did) == nil)
        }
        // Offline: nothing answers at all.
        let offline = FakeHTTPClient { _ in throw URLError(.notConnectedToInternet) }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(offline, credentials: credentials)
        await account.signOut()
        #expect(try credentials.load(BlueskySession.self, for: did) == nil)
    }

    @Test func signingOutDuringARefreshRevokesTheNewToken() async throws {
        let http = FakeHTTPClient { request in
            if request.url?.path == "/oauth/token" {
                return .init(body: try! JSONSerialization.data(withJSONObject: [
                    "access_token": "access-2", "token_type": "DPoP", "refresh_token": "refresh-2", "expires_in": 300, "scope": "atproto",
                ]))
            }
            return revokingResponse(request, revokeStatus: 200)
        }
        let credentials = InMemoryCredentialStore()
        let account = try makeAccount(http, session: makeSession(expiresAt: now), credentials: credentials)
        async let reading: FeedPage? = try? account.timeline(cursor: nil)
        await account.signOut()
        _ = await reading

        #expect(try credentials.load(BlueskySession.self, for: did) == nil)
        let revoke = try #require(http.requests.last { $0.url?.path == "/oauth/revoke" })
        let refreshed = http.requests.contains { $0.url?.path == "/oauth/token" }
        #expect(formFields(revoke)["token"] == (refreshed ? "refresh-2" : "refresh-1"))
    }

    @Test func savedFeedsComeWithTheirNamesPinnedFirst() async throws {
        let http = FakeHTTPClient { request in
            switch request.url?.path {
            case "/xrpc/app.bsky.actor.getPreferences":
                return .init(body: try! JSONSerialization.data(withJSONObject: ["preferences": [
                    ["$type": "app.bsky.actor.defs#adultContentPref", "enabled": false],
                    ["$type": "app.bsky.actor.defs#savedFeedsPrefV2", "items": [
                        ["id": "1", "type": "timeline", "value": "following", "pinned": true],
                        ["id": "2", "type": "feed", "value": "at://did:plc:gen/app.bsky.feed.generator/dogs", "pinned": false],
                        ["id": "3", "type": "feed", "value": feedURI, "pinned": true],
                        ["id": "4", "type": "list", "value": "at://did:plc:me/app.bsky.graph.list/x", "pinned": true],
                    ]],
                ]]))
            case "/xrpc/app.bsky.feed.getFeedGenerators":
                let asked = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.filter { $0.name == "feeds" }.map(\.value!)
                #expect(asked == [feedURI, "at://did:plc:gen/app.bsky.feed.generator/dogs"])
                return .init(body: try! JSONSerialization.data(withJSONObject: ["feeds": [
                    ["uri": "at://did:plc:gen/app.bsky.feed.generator/dogs", "cid": "c", "did": "did:web:gen", "displayName": "Dogs", "creator": [:], "indexedAt": "2026-10-01T00:00:00Z"],
                    ["uri": feedURI, "cid": "c", "did": "did:web:gen", "displayName": "Cats", "creator": [:], "indexedAt": "2026-10-01T00:00:00Z"],
                ]]))
            default:
                return .init(status: 404)
            }
        }
        let sources = try await makeConnector(http).availableSources()
        #expect(sources.map(\.title) == ["Following", "Cats", "Dogs"])
        #expect(sources.map(\.kind) == [.blueskyFollowing, .blueskyFeed, .blueskyFeed])
        #expect(sources[1].id == "bluesky:did:plc:me:feed:\(feedURI)")
        #expect(sources.allSatisfy { $0.accountID == did })
    }
}

@Suite struct BlueskyConnector_ {
    @Test func handlesOnlyItsOwnAccountsSources() throws {
        let connector = try makeConnector(FakeHTTPClient { _ in .init(status: 404) })
        #expect(connector.handles(following))
        #expect(connector.handles(cats))
        #expect(!connector.handles(Source(id: "bluesky:did:plc:other:following", kind: .blueskyFollowing, accountID: "did:plc:other", title: "Following", colorIndex: 0)))
        #expect(!connector.handles(Source(id: "rss:x", kind: .rss, title: "x", url: "https://x", colorIndex: 0)))
        #expect(BlueskyConnector.feedURI(cats) == feedURI)
    }

    @Test func firstFetchIsOnePageAndStartsPagingBack() async throws {
        let http = FakeHTTPClient { _ in .init(body: feedPage([1, 2, 3], cursor: "p2")) }
        let page = try await makeConnector(http).fetch(fetchRequest(.newer), from: following)
        #expect(http.requests.count == 1)
        #expect(page.items.map(\.body) == ["1 minutes ago", "2 minutes ago", "3 minutes ago"])
        #expect(page.older == Cursor(rawValue: "p2"))
        #expect(page.newer == Cursor(rawValue: ATDate.format(now.addingTimeInterval(-60))))
    }

    @Test func newerReadsBackUntilItReachesWhatItHas() async throws {
        let http = FakeHTTPClient { request in
            switch query(request, "cursor") {
            case nil: .init(body: feedPage([1, 2], cursor: "p2"))
            case "p2": .init(body: feedPage([3, 4], cursor: "p3"))
            case "p3": .init(body: feedPage([5, 6], cursor: "p4"))
            default: .init(status: 500)
            }
        }
        let since = ATDate.format(now.addingTimeInterval(-60 * 5))
        let page = try await makeConnector(http).fetch(fetchRequest(.newer, cursor: since), from: following)
        #expect(http.requests.count == 3)
        #expect(page.items.count == 6)
        #expect(page.newer == Cursor(rawValue: ATDate.format(now.addingTimeInterval(-60))))
    }

    @Test func nothingNewKeepsTheCursor() async throws {
        let http = FakeHTTPClient { _ in .init(body: feedPage([], cursor: nil)) }
        let page = try await makeConnector(http).fetch(fetchRequest(.newer, cursor: "2026-10-24T00:00:00.000Z"), from: following)
        #expect(page.items.isEmpty)
        #expect(page.newer == Cursor(rawValue: "2026-10-24T00:00:00.000Z"))
    }

    @Test func anOlderPageDoesNotMoveTheCursorBack() async throws {
        let since = ATDate.format(now.addingTimeInterval(-60 * 5))
        let http = FakeHTTPClient { _ in .init(body: feedPage([10, 20], cursor: nil)) }
        let page = try await makeConnector(http).fetch(fetchRequest(.newer, cursor: since), from: following)
        #expect(page.items.count == 2)
        #expect(page.newer == Cursor(rawValue: since))
    }

    @Test func pagingBackStopsAtTheRetentionWindow() async throws {
        let eightDays = 8 * 24 * 60
        let http = FakeHTTPClient { request in
            query(request, "cursor") == "p2" ? .init(body: feedPage([10, 20], cursor: "p3")) : .init(body: feedPage([30, eightDays], cursor: "p4"))
        }
        let connector = try makeConnector(http)
        #expect(try await connector.fetch(fetchRequest(.older, cursor: "p2"), from: following).older == Cursor(rawValue: "p3"))
        #expect(try await connector.fetch(fetchRequest(.older, cursor: "p3"), from: following).older == nil)
    }

    @Test func customFeedsAreNotAssumedToBeInDateOrder() async throws {
        let eightDays = 8 * 24 * 60
        let http = FakeHTTPClient { request in
            // A ranked feed: an old post first, recent ones after it.
            query(request, "cursor") == nil ? .init(body: feedPage([eightDays, 2], cursor: "p2")) : .init(body: feedPage([3, 4], cursor: "p3"))
        }
        let connector = try makeConnector(http)
        let since = ATDate.format(now.addingTimeInterval(-60 * 60))
        let newer = try await connector.fetch(fetchRequest(.newer, cursor: since), from: cats)
        #expect(http.requests.count == 1)
        #expect(newer.items.count == 2)
        // One old post doesn't end paging back while the page has recent ones.
        #expect(try await connector.fetch(fetchRequest(.older), from: cats).older == Cursor(rawValue: "p2"))
        #expect(try await connector.fetch(fetchRequest(.older), from: following).older == nil)

        // Even a page of nothing but old posts keeps a ranked feed's cursor.
        let allOld = FakeHTTPClient { _ in .init(body: feedPage([eightDays, eightDays + 1], cursor: "p9")) }
        #expect(try await makeConnector(allOld).fetch(fetchRequest(.older), from: cats).older == Cursor(rawValue: "p9"))
    }

    @Test func aFreshBoostOfAnOldPostIsStored() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [following])
        let old = ATDate.format(now.addingTimeInterval(-20 * 24 * 60 * 60))
        let boosted = ATDate.format(now.addingTimeInterval(-60))
        let json = """
            {"feed": [{
              "post": {"uri": "at://did:plc:sam/app.bsky.feed.post/old", "cid": "c", "author": {"did": "did:plc:sam", "handle": "sam.test"},
                       "record": {"text": "From weeks ago", "createdAt": "\(old)"}, "indexedAt": "\(old)"},
              "reason": {"$type": "app.bsky.feed.defs#reasonRepost", "by": {"did": "did:plc:ana", "handle": "ana.test"}, "indexedAt": "\(boosted)"}
            }]}
            """
        let http = FakeHTTPClient { _ in .init(text: json) }
        let outcome = try await Refresher(store: store).refresh(following, with: makeConnector(http), now: now)
        #expect(outcome == .fetched(newItems: 1))
        #expect(try await store.prune(now: now) == 0)
        #expect(try await store.rows().first?.boostedBy == ["ana.test"])
    }

    @Test func imagesWithoutASizeAreSizedBeforeTheyAreStored() async throws {
        let http = FakeHTTPClient { request in
            switch request.url?.absoluteString {
            case "https://cdn.bsky.app/f2": .init(body: MediaFixtures.png(width: 800, height: 600))
            case "https://cdn.bsky.app/img/feed_thumbnail/plain/x@jpeg": .init(body: MediaFixtures.jpeg(width: 1200, height: 630))
            default: .init(body: try! blueskyFixture("timeline"))
            }
        }
        let page = try await makeConnector(http).fetch(fetchRequest(.older), from: following)
        #expect(page.items[0].linkCard?.image == Item.Media(kind: .image, url: "https://cdn.bsky.app/img/feed_thumbnail/plain/x@jpeg", width: 1200, height: 630))
        #expect(page.items[1].media.map(\.width) == [1600, 800])

        // Items the store already has are passed on without lookups.
        let before = http.requests.count
        var stored = fetchRequest(.older)
        stored.storedRemoteIDs = Set(page.items.map(\.remoteID))
        let again = try await makeConnector(http).fetch(stored, from: following)
        #expect(http.requests.count == before + 1)
        #expect(again.items[1].media.count == 1)
    }

    @Test func customFeedsFetchByTheirURI() async throws {
        let http = FakeHTTPClient { _ in .init(body: feedPage([1], cursor: nil)) }
        let page = try await makeConnector(http).fetch(fetchRequest(.newer), from: cats)
        let sent = try #require(http.requests.first)
        #expect(sent.url?.path == "/xrpc/app.bsky.feed.getFeed")
        #expect(query(sent, "feed") == feedURI)
        #expect(page.items.first?.sourceID == cats.id)
        #expect(page.older == nil)
    }

    @Test func failuresBecomeQuietSourceStates() async throws {
        let reset = 1_793_000_900
        let limited = FakeHTTPClient { _ in .init(status: 429, headers: ["ratelimit-reset": "\(reset)"], text: "{\"error\":\"RateLimitExceeded\"}") }
        await #expect(throws: ConnectorError.rateLimited(retryAfter: Date(timeIntervalSince1970: TimeInterval(reset)))) {
            try await makeConnector(limited).fetch(fetchRequest(.newer), from: following)
        }
        let gone = FakeHTTPClient { _ in .init(status: 400, text: "{\"error\":\"UnknownFeed\",\"message\":\"Unknown feed\"}") }
        await #expect(throws: ConnectorError.notFound) {
            try await makeConnector(gone).fetch(fetchRequest(.newer), from: cats)
        }
        let garbled = FakeHTTPClient { _ in .init(text: "<html>") }
        await #expect(throws: ConnectorError.self) {
            try await makeConnector(garbled).fetch(fetchRequest(.newer), from: following)
        }
    }

    @Test func boostsAndOriginalsShareOneRow() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [following])
        let http = FakeHTTPClient { _ in .init(body: try! blueskyFixture("timeline")) }
        let fixtureNow = ATDate.parse("2026-10-24T10:05:00Z")!
        let outcome = try await Refresher(store: store).refresh(following, with: makeConnector(http), now: fixtureNow)
        #expect(outcome == .fetched(newItems: 8))
        let rows = try await store.rows()
        #expect(rows.count == 7)
        let sam = try #require(rows.first { $0.mergeKey == "at://did:plc:sam/app.bsky.feed.post/3lsam1" })
        #expect(sam.boostedBy == ["Ana Ruiz"])
        #expect(rows.last?.body == "Worth reading on scroll performance")
        #expect(rows.contains { $0.quote?.body == "The original thought" })
    }
}

/// A credential store whose writes fail while `failing` is set.
private final class FailingCredentialStore: CredentialStore {
    struct Failure: Error {}
    let failing = Mutex(false)
    private let store = InMemoryCredentialStore()

    func data(for account: String) throws -> Data? { try store.data(for: account) }

    func setData(_ data: Data, for account: String) throws {
        if failing.withLock({ $0 }) { throw Failure() }
        try store.setData(data, for: account)
    }

    func deleteData(for account: String) throws { try store.deleteData(for: account) }

    func accounts() throws -> [String] { try store.accounts() }
}

/// Holds back answers so two requests overlap: the first request's answer
/// waits until the second has been sent, and the second's waits until the
/// first has refreshed and been sent again.
private final class GatedHTTPClient: HTTPClient {
    let inner: FakeHTTPClient
    private let secondSent = AsyncStream<Void>.makeStream()
    private let refreshed = AsyncStream<Void>.makeStream()

    init(_ inner: FakeHTTPClient) { self.inner = inner }

    func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
        try await inner.send(request, upTo: limit, at: address)
    }
    func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let limit = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value
        let stale = request.value(forHTTPHeaderField: "Authorization") == "DPoP access-1"
        let result = try await inner.send(request)
        // The first request's retry is sent once its refresh is done.
        if limit == "1", !stale { refreshed.continuation.yield() }
        if stale, limit == "2" {
            secondSent.continuation.yield()
            for await _ in refreshed.stream { break }
        }
        if stale, limit == "1" {
            for await _ in secondSent.stream { break }
        }
        return result
    }
}

private let postRef = BlueskyMapping.actionRef(uri: "at://did:plc:ana/app.bsky.feed.post/p1", cid: "cid-p1")

private func body(_ request: URLRequest) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
}

/// A post view, as getPostThread and getPosts send it.
private func postView(_ rkey: String, viewer: [String: Any]? = nil) -> [String: Any] {
    var post: [String: Any] = [
        "uri": "at://did:plc:ana/app.bsky.feed.post/\(rkey)", "cid": "cid-\(rkey)",
        "author": ["did": "did:plc:ana", "handle": "ana.test"],
        "record": ["text": "Post \(rkey)", "createdAt": ATDate.format(now)],
        "indexedAt": ATDate.format(now),
    ]
    if let viewer { post["viewer"] = viewer }
    return post
}

private func node(_ rkey: String, parent: [String: Any]? = nil, replies: [[String: Any]] = []) -> [String: Any] {
    var node: [String: Any] = ["$type": "app.bsky.feed.defs#threadViewPost", "post": postView(rkey), "replies": replies]
    if let parent { node["parent"] = parent }
    return node
}

@Suite struct BlueskyActions {
    private func send(_ action: ConnectorAction, viewer: Item.Viewer? = nil, answer: @escaping @Sendable (URLRequest) -> FakeHTTPClient.Response) async throws -> (Item.Viewer, [URLRequest]) {
        let http = FakeHTTPClient { answer($0) }
        let viewer = try await makeConnector(http).perform(action, on: ItemReference(sourceID: following.id, remoteID: "x", actionRef: postRef, viewer: viewer))
        return (viewer, http.requests)
    }

    @Test func viewerStateComesFromThePostView() throws {
        let page = try JSONDecoder().decode(FeedPage.self, from: JSONSerialization.data(withJSONObject: [
            "feed": [["post": postView("p1", viewer: ["like": "at://did:plc:me/app.bsky.feed.like/l1", "bookmarked": true])]],
        ]))
        let item = try #require(BlueskyMapping.items(page, sourceID: following.id, fetchedAt: now).first)
        #expect(item.viewer == Item.Viewer(liked: true, bookmarked: true, likeRef: "at://did:plc:me/app.bsky.feed.like/l1"))
    }

    @Test func aLikeIsARecordInTheReadersRepository() async throws {
        let (viewer, requests) = try await send(.like) { _ in .init(text: #"{"uri":"at://did:plc:me/app.bsky.feed.like/l1","cid":"x"}"#) }
        let sent = try #require(requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://pds.example.com/xrpc/com.atproto.repo.createRecord")
        // The PDS keeps the reader's records itself; nothing goes to the app view.
        #expect(sent.value(forHTTPHeaderField: "atproto-proxy") == nil)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sentBody = try body(sent)
        #expect(sentBody["repo"] as? String == did)
        #expect(sentBody["collection"] as? String == "app.bsky.feed.like")
        let record = try #require(sentBody["record"] as? [String: Any])
        #expect(record["$type"] as? String == "app.bsky.feed.like")
        #expect(record["createdAt"] as? String == ATDate.format(now))
        #expect(record["subject"] as? [String: String] == ["uri": "at://did:plc:ana/app.bsky.feed.post/p1", "cid": "cid-p1"])
        #expect(viewer == Item.Viewer(liked: true, likeRef: "at://did:plc:me/app.bsky.feed.like/l1"))
    }

    @Test func aBoostIsARepostRecord() async throws {
        let (viewer, requests) = try await send(.boost) { _ in .init(text: #"{"uri":"at://did:plc:me/app.bsky.feed.repost/r1","cid":"x"}"#) }
        #expect(try body(#require(requests.first))["collection"] as? String == "app.bsky.feed.repost")
        #expect(viewer == Item.Viewer(boosted: true, boostRef: "at://did:plc:me/app.bsky.feed.repost/r1"))
    }

    @Test func undoingDeletesTheStoredRecord() async throws {
        let stored = Item.Viewer(liked: true, boosted: true, likeRef: "at://did:plc:me/app.bsky.feed.like/l1", boostRef: "at://did:plc:me/app.bsky.feed.repost/r1")
        let (viewer, requests) = try await send(.unboost, viewer: stored) { _ in .init(text: "{}") }
        let sent = try #require(requests.first)
        #expect(sent.url?.absoluteString == "https://pds.example.com/xrpc/com.atproto.repo.deleteRecord")
        #expect(try body(sent) as? [String: String] == ["repo": did, "collection": "app.bsky.feed.repost", "rkey": "r1"])
        #expect(viewer == Item.Viewer(liked: true, likeRef: "at://did:plc:me/app.bsky.feed.like/l1"))
    }

    @Test func undoingWithoutAStoredRecordAsksTheAppViewForIt() async throws {
        let (viewer, requests) = try await send(.unlike, viewer: Item.Viewer(liked: true)) { request in
            if request.url?.path() == "/xrpc/app.bsky.feed.getPosts" {
                return .init(body: try! JSONSerialization.data(withJSONObject: ["posts": [postView("p1", viewer: ["like": "at://did:plc:me/app.bsky.feed.like/l9"])]]))
            }
            return .init(text: "{}")
        }
        #expect(requests.count == 2)
        #expect(query(requests[0], "uris") == "at://did:plc:ana/app.bsky.feed.post/p1")
        #expect(try body(requests[1])["rkey"] as? String == "l9")
        #expect(viewer == Item.Viewer())
    }

    @Test func onlyTheReadersOwnRecordsAreDeleted() async throws {
        await #expect(throws: ConnectorError.self) {
            _ = try await send(.unlike, viewer: Item.Viewer(liked: true, likeRef: "at://did:plc:ana/app.bsky.feed.like/l1")) { _ in .init(text: "{}") }
        }
    }

    @Test func bookmarksGoToTheAppViewAndMayAnswerWithNoBody() async throws {
        let (viewer, requests) = try await send(.bookmark) { _ in .init(text: "") }
        let sent = try #require(requests.first)
        #expect(sent.url?.absoluteString == "https://pds.example.com/xrpc/app.bsky.bookmark.createBookmark")
        #expect(sent.value(forHTTPHeaderField: "atproto-proxy") == "did:web:api.bsky.app#bsky_appview")
        #expect(try body(sent) as? [String: String] == ["uri": "at://did:plc:ana/app.bsky.feed.post/p1", "cid": "cid-p1"])
        #expect(viewer == Item.Viewer(bookmarked: true))

        let (_, removed) = try await send(.unbookmark, viewer: viewer) { _ in .init(text: "") }
        #expect(removed.first?.url?.absoluteString == "https://pds.example.com/xrpc/app.bsky.bookmark.deleteBookmark")
        #expect(try body(#require(removed.first)) as? [String: String] == ["uri": "at://did:plc:ana/app.bsky.feed.post/p1"])
    }

    @Test func aRefusalKeepsTheServicesReason() async throws {
        let refusal = try JSONSerialization.data(withJSONObject: ["error": "InvalidRequest", "message": "Bookmark not found"])
        await #expect(throws: ConnectorError.badResponse("InvalidRequest: Bookmark not found")) {
            _ = try await send(.unbookmark, viewer: Item.Viewer(bookmarked: true)) { _ in .init(status: 400, body: refusal) }
        }
    }

    @Test func threadHasItsParentsAndNestedReplies() async throws {
        let blocked: [String: Any] = ["$type": "app.bsky.feed.defs#blockedPost", "uri": "at://x", "blocked": true]
        let thread = node("p1", parent: node("p0", parent: node("root")), replies: [
            node("r1", replies: [node("r1a")]), blocked, node("r2"),
        ])
        let response = try JSONSerialization.data(withJSONObject: ["thread": thread])
        let http = FakeHTTPClient { _ in .init(body: response) }
        let result = try await makeConnector(http).thread(of: ItemReference(sourceID: following.id, remoteID: "x", actionRef: postRef))
        let sent = try #require(http.requests.first)
        #expect(sent.url?.path() == "/xrpc/app.bsky.feed.getPostThread")
        #expect(query(sent, "uri") == "at://did:plc:ana/app.bsky.feed.post/p1")
        #expect(result.ancestors.map(\.body) == ["Post root", "Post p0"])
        #expect(result.post.body == "Post p1")
        #expect(result.replies.map(\.item.body) == ["Post r1", "Post r1a", "Post r2"])
        #expect(result.replies.map(\.depth) == [1, 2, 1])
        #expect(result.post.sourceID == following.id)
        #expect(BlueskyMapping.ActionRef(result.replies[0].item.actionRef)?.uri == "at://did:plc:ana/app.bsky.feed.post/r1")
    }

    @Test func aMissingPostIsNotFound() async throws {
        let http = FakeHTTPClient { _ in .init(text: #"{"thread":{"$type":"app.bsky.feed.defs#notFoundPost","uri":"at://x","notFound":true}}"#) }
        await #expect(throws: ConnectorError.notFound) {
            try await makeConnector(http).thread(of: ItemReference(sourceID: following.id, remoteID: "x", actionRef: postRef))
        }
    }
}

@Suite struct BlueskyBookmarks {
    @Test func readsEveryPageAsFollowingItemsAndSkipsGonePosts() async throws {
        let gone: [String: Any] = ["subject": ["uri": "at://x", "cid": "c"], "createdAt": ATDate.format(now),
                                   "item": ["$type": "app.bsky.feed.defs#notFoundPost", "uri": "at://x", "notFound": true]]
        func bookmark(_ rkey: String) -> [String: Any] {
            ["subject": ["uri": "at://did:plc:ana/app.bsky.feed.post/\(rkey)", "cid": "cid-\(rkey)"], "createdAt": ATDate.format(now),
             "item": postView(rkey, viewer: ["bookmarked": true])]
        }
        let firstPage = try JSONSerialization.data(withJSONObject: ["bookmarks": [bookmark("b1"), gone], "cursor": "next"])
        let lastPage = try JSONSerialization.data(withJSONObject: ["bookmarks": [bookmark("b2")]])
        let http = FakeHTTPClient { request in
            .init(body: query(request, "cursor") == nil ? firstPage : lastPage)
        }
        let list = try await makeConnector(http).bookmarks(for: following, now: now, storedRemoteIDs: [])
        #expect(list.isComplete)
        #expect(list.items.map(\.body) == ["Post b1", "Post b2"])
        #expect(list.items.allSatisfy { $0.sourceID == following.id && $0.viewer?.bookmarked == true })
        let sent = http.requests.filter { $0.url?.path() == "/xrpc/app.bsky.bookmark.getBookmarks" }
        #expect(sent.map { query($0, "cursor") } == [nil, "next"])
        #expect(sent.first?.value(forHTTPHeaderField: "atproto-proxy") == "did:web:api.bsky.app#bsky_appview")
    }

    @Test func aListLongerThanThePageLimitIsIncomplete() async throws {
        // An empty page ends the list, so every page here holds a post.
        let bookmark: [String: Any] = ["subject": ["uri": "at://did:plc:ana/app.bsky.feed.post/b1", "cid": "cid-b1"],
                                       "createdAt": ATDate.format(now), "item": postView("b1")]
        let page = try JSONSerialization.data(withJSONObject: ["bookmarks": [bookmark], "cursor": "more"])
        let http = FakeHTTPClient { _ in .init(body: page) }
        let list = try await makeConnector(http).bookmarks(for: following, now: now, storedRemoteIDs: [])
        #expect(!list.isComplete)
        #expect(http.requests.count == BlueskyConnector.maxBookmarkPages)
    }
}

@Suite struct BlueskyLinks {
    private func record(_ text: String, facets: [[String: Any]]) throws -> PostRecord {
        try JSONDecoder().decode(PostRecord.self, from: JSONSerialization.data(withJSONObject: ["text": text, "facets": facets]))
    }

    private func facet(_ start: Int, _ end: Int, _ feature: [String: Any]) -> [String: Any] {
        ["index": ["byteStart": start, "byteEnd": end], "features": [feature]]
    }

    @Test func facetsBecomeLinksInUTF16() throws {
        // "🦋 " is 5 bytes of UTF-8 but 3 UTF-16 units.
        let text = "🦋 hi @ana.test see example.com #cats"
        let bytes = Array(text.utf8)
        func byteOffset(_ part: String) -> Int {
            let range = text.range(of: part)!
            return text.utf8.distance(from: text.utf8.startIndex, to: range.lowerBound)
        }
        let links = BlueskyMapping.links(try record(text, facets: [
            facet(byteOffset("@ana"), byteOffset("@ana") + 9, ["$type": "app.bsky.richtext.facet#mention", "did": "did:plc:ana"]),
            facet(byteOffset("example"), byteOffset("example") + 11, ["$type": "app.bsky.richtext.facet#link", "uri": "https://example.com/full"]),
            facet(byteOffset("#cats"), bytes.count, ["$type": "app.bsky.richtext.facet#tag", "tag": "cats"]),
            // Splits the butterfly, so it is dropped.
            facet(1, 3, ["$type": "app.bsky.richtext.facet#link", "uri": "https://bad.example"]),
            facet(0, 4, ["$type": "app.bsky.richtext.facet#link", "uri": "javascript:alert(1)"]),
            facet(byteOffset("hi"), 999, ["$type": "app.bsky.richtext.facet#link", "uri": "https://long.example"]),
        ]))
        let shown = links.map { (text as NSString).substring(with: NSRange(location: $0.start, length: $0.length)) }
        #expect(shown == ["@ana.test", "example.com", "#cats"])
        #expect(links.map(\.url) == ["https://bsky.app/profile/did:plc:ana", "https://example.com/full", "https://bsky.app/hashtag/cats"])
    }

    @Test func aMalformedFacetDoesntLoseThePost() throws {
        let post = try record("text", facets: [["index": "nope"]])
        #expect(post.text == "text")
        #expect(post.facets.isEmpty)
    }
}
