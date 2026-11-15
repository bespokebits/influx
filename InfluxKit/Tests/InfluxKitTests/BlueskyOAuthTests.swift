import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

private let now = Date(timeIntervalSince1970: 1_793_000_000)

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func formFields(_ request: URLRequest) -> [String: String] {
    let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    var fields: [String: String] = [:]
    for pair in body.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
        fields[parts[0]] = parts.count > 1 ? parts[1] : ""
    }
    return fields
}

func proofClaims(_ request: URLRequest) throws -> DPoP.Claims {
    let header = try #require(request.value(forHTTPHeaderField: "DPoP"))
    return try decodeJWT(header, (DPoP.Header.self, DPoP.Claims.self)).1
}

/// Ana's identity, PDS and authorization server, as recorded responses.
/// The authorization server asks for a DPoP nonce before it accepts a PAR.
func blueskyServers(sub: String = "did:plc:ana", handleInDocument: String = "ana.bsky.social", tokenEndpoint: String = "https://auth.example.com/oauth/token") -> FakeHTTPClient {
    FakeHTTPClient { request in
        let url = request.url!.absoluteString
        switch (request.httpMethod ?? "GET", url) {
        case ("GET", "https://ana.bsky.social/.well-known/atproto-did"):
            return .init(text: "did:plc:ana\n")
        case ("GET", "https://plc.directory/did:plc:ana"):
            return .init(body: json([
                "id": "did:plc:ana",
                "alsoKnownAs": ["at://\(handleInDocument)"],
                "service": [["id": "#atproto_pds", "type": "AtprotoPersonalDataServer", "serviceEndpoint": "https://pds.example.com"]],
            ]))
        case ("GET", "https://pds.example.com/.well-known/oauth-protected-resource"):
            return .init(body: json(["resource": "https://pds.example.com", "authorization_servers": ["https://auth.example.com"]]))
        case ("GET", "https://auth.example.com/.well-known/oauth-authorization-server"):
            return .init(body: json([
                "issuer": "https://auth.example.com",
                "authorization_endpoint": "https://auth.example.com/oauth/authorize",
                "token_endpoint": tokenEndpoint,
                "pushed_authorization_request_endpoint": "https://auth.example.com/oauth/par",
                "revocation_endpoint": "https://auth.example.com/oauth/revoke",
                "dpop_signing_alg_values_supported": ["ES256"],
                "scopes_supported": ["atproto", "transition:generic"],
                "authorization_response_iss_parameter_supported": true,
                "require_pushed_authorization_requests": true,
                "client_id_metadata_document_supported": true,
            ]))
        case ("POST", "https://auth.example.com/oauth/par"):
            guard try proofClaims(request).nonce == "nonce-1" else {
                return .init(status: 400, headers: ["DPoP-Nonce": "nonce-1"], body: json(["error": "use_dpop_nonce"]))
            }
            return .init(status: 201, headers: ["DPoP-Nonce": "nonce-1"], body: json(["request_uri": "urn:ietf:params:oauth:request_uri:req-1", "expires_in": 299]))
        case ("POST", "https://auth.example.com/oauth/token"):
            guard try proofClaims(request).nonce == "nonce-1" else {
                return .init(status: 400, headers: ["DPoP-Nonce": "nonce-1"], body: json(["error": "use_dpop_nonce"]))
            }
            return .init(headers: ["DPoP-Nonce": "nonce-2"], body: json([
                "access_token": "access-1", "token_type": "DPoP", "refresh_token": "refresh-1",
                "expires_in": 300, "scope": "atproto transition:generic", "sub": sub,
            ]))
        case ("POST", "https://influx.bespokebits.dev/oauth/assertion"), ("POST", "https://flux.bespokebits.dev/oauth/assertion"):
            // Each client's signing service, on its own host. The
            // assertion says which one signed it.
            let asked = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
            return .init(body: json(["client_assertion": "signed-by-\(request.url!.host!)", "kid": asked?["kid"] ?? "key-1"]))
        case ("POST", "https://auth.example.com/oauth/revoke"):
            guard try proofClaims(request).nonce == "nonce-2" else {
                return .init(status: 400, headers: ["DPoP-Nonce": "nonce-2"], body: json(["error": "use_dpop_nonce"]))
            }
            return .init()
        default:
            return .init(status: 404)
        }
    }
}

private func oauth(_ http: FakeHTTPClient) -> BlueskyOAuth {
    BlueskyOAuth(configuration: .influxPublic, http: http, crypto: .fake(), now: { now })
}

private func callback(_ pending: PendingBlueskySignIn, state: String? = nil, iss: String = "https://auth.example.com") -> URL {
    var parts = URLComponents(string: "dev.bespokebits.influx:/oauth/callback")!
    parts.queryItems = [
        URLQueryItem(name: "state", value: state ?? pending.state),
        URLQueryItem(name: "iss", value: iss),
        URLQueryItem(name: "code", value: "code-1"),
    ]
    return parts.url!
}

/// Signs assertions as the signing service would, numbering them.
final class FakeAssertionSigner: ClientAssertionSigner, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [(issuer: String, keyID: String?)] = []
    var requests: [(issuer: String, keyID: String?)] { lock.withLock { _requests } }

    func assertion(for issuer: String, keyID: String?) async throws -> ClientAssertion {
        let count = lock.withLock {
            _requests.append((issuer, keyID))
            return _requests.count
        }
        return ClientAssertion(jwt: "assertion-\(count)", keyID: keyID ?? "key-1")
    }
}

private func confidential(_ http: FakeHTTPClient, _ signer: FakeAssertionSigner) -> BlueskyOAuth {
    let configuration = BlueskyClientConfiguration(
        clientID: "https://influx.bespokebits.dev/oauth/client-metadata.json",
        redirectURI: "https://influx.bespokebits.dev/oauth/callback",
        scope: "atproto transition:generic",
        authentication: .signed(signer)
    )
    return BlueskyOAuth(configuration: configuration, http: http, crypto: .fake(), now: { now })
}

@Suite struct BlueskyOAuth_ {
    @Test func signInWithAHandle() async throws {
        let http = blueskyServers()
        let client = oauth(http)
        let pending = try await client.begin(account: "@Ana.bsky.social")

        let authorize = try #require(URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false))
        #expect(authorize.host == "auth.example.com" && authorize.path == "/oauth/authorize")
        #expect(authorize.queryItems == [
            URLQueryItem(name: "client_id", value: "https://influx.bespokebits.dev/oauth/client-metadata.json"),
            URLQueryItem(name: "request_uri", value: "urn:ietf:params:oauth:request_uri:req-1"),
        ])
        let par = try #require(http.requests.last { $0.url?.path == "/oauth/par" })
        let fields = formFields(par)
        #expect(fields["client_id"] == BlueskyClientConfiguration.influxPublic.clientID)
        #expect(fields["redirect_uri"] == "dev.bespokebits.influx:/oauth/callback")
        #expect(fields["scope"] == "atproto transition:generic")
        #expect(fields["response_type"] == "code")
        #expect(fields["code_challenge_method"] == "S256")
        #expect(fields["code_challenge"] == pending.pkce.challenge)
        #expect(fields["state"] == pending.state)
        #expect(fields["login_hint"] == "ana.bsky.social")
        // The first PAR was refused for want of a nonce, and retried with it.
        #expect(http.requests.filter { $0.url?.path == "/oauth/par" }.count == 2)

        let session = try await client.complete(pending, callback: callback(pending))
        let token = try #require(http.requests.last { $0.url?.path == "/oauth/token" })
        #expect(formFields(token)["code_verifier"] == pending.pkce.verifier)
        #expect(formFields(token)["grant_type"] == "authorization_code")
        #expect(try proofClaims(token).htu == "https://auth.example.com/oauth/token")
        #expect(try proofClaims(token).ath == nil)

        #expect(session.identity == ATIdentity(did: "did:plc:ana", handle: "ana.bsky.social", pds: URL(string: "https://pds.example.com")!))
        #expect(session.accountID == "did:plc:ana")
        #expect(session.issuer == "https://auth.example.com")
        #expect(session.accessToken == "access-1")
        #expect(session.refreshToken == "refresh-1")
        #expect(session.expiresAt == now.addingTimeInterval(300))
        #expect(session.dpopKey == Data("key".utf8))
    }

    @Test func aConfidentialClientSignsEveryTokenRequest() async throws {
        let http = blueskyServers()
        let signer = FakeAssertionSigner()
        let client = confidential(http, signer)
        let pending = try await client.begin(account: "ana.bsky.social")
        var parts = URLComponents(string: "https://influx.bespokebits.dev/oauth/callback")!
        parts.queryItems = [
            URLQueryItem(name: "state", value: pending.state),
            URLQueryItem(name: "iss", value: "https://auth.example.com"),
            URLQueryItem(name: "code", value: "code-1"),
        ]
        let session = try await client.complete(pending, callback: parts.url!)

        // The PAR was retried for a nonce, with a new assertion each time.
        let pars = http.requests.filter { $0.url?.path == "/oauth/par" }.map(formFields)
        #expect(pars.map { $0["client_assertion"] } == ["assertion-1", "assertion-2"])
        #expect(pars.allSatisfy { $0["client_assertion_type"] == "urn:ietf:params:oauth:client-assertion-type:jwt-bearer" })
        #expect(pars.last?["redirect_uri"] == "https://influx.bespokebits.dev/oauth/callback")
        let token = try #require(http.requests.last { $0.url?.path == "/oauth/token" })
        #expect(formFields(token)["client_assertion"] == "assertion-3")
        #expect(signer.requests.map(\.issuer) == Array(repeating: "https://auth.example.com", count: 3))
        // Every assertion after the first names the key the first one used.
        #expect(signer.requests.map(\.keyID) == [nil, "key-1", "key-1"])
        #expect(session.clientKeyID == "key-1")

        _ = try await client.refresh(session, nonce: "nonce-1")
        let refresh = try #require(http.requests.last { $0.url?.path == "/oauth/token" })
        #expect(formFields(refresh)["grant_type"] == "refresh_token")
        #expect(formFields(refresh)["client_assertion"] == "assertion-4")
        #expect(signer.requests.last?.keyID == "key-1")
    }

    @Test func aConfidentialClientSignsTheRevocation() async throws {
        let http = blueskyServers()
        let signer = FakeAssertionSigner()
        let client = confidential(http, signer)
        let session = BlueskySession(
            identity: ATIdentity(did: "did:plc:ana", handle: "ana.bsky.social", pds: URL(string: "https://pds.example.com")!),
            issuer: "https://auth.example.com", tokenEndpoint: URL(string: "https://auth.example.com/oauth/token")!,
            accessToken: "access-1", refreshToken: "refresh-1", expiresAt: now,
            scope: "atproto", dpopKey: Data("key".utf8), clientKeyID: "key-1",
            clientID: "https://influx.bespokebits.dev/oauth/client-metadata.json"
        )
        try await client.revoke(session, nonce: nil)

        // Retried for a nonce, with a fresh assertion from the session's key.
        let revokes = http.requests.filter { $0.url?.path == "/oauth/revoke" }.map(formFields)
        #expect(revokes.map { $0["client_assertion"] } == ["assertion-1", "assertion-2"])
        #expect(revokes.last?["token"] == "refresh-1")
        #expect(revokes.last?["token_type_hint"] == "refresh_token")
        #expect(signer.requests.map(\.keyID) == ["key-1", "key-1"])
        #expect(signer.requests.map(\.issuer) == ["https://auth.example.com", "https://auth.example.com"])
    }

    @Test func aServerWithoutRevocationCantRevoke() async throws {
        let http = FakeHTTPClient { request in
            .init(body: json([
                "issuer": "https://auth.example.com",
                "authorization_endpoint": "https://auth.example.com/oauth/authorize",
                "token_endpoint": "https://auth.example.com/oauth/token",
                "pushed_authorization_request_endpoint": "https://auth.example.com/oauth/par",
                "dpop_signing_alg_values_supported": ["ES256"],
            ]))
        }
        let session = BlueskySession(
            identity: ATIdentity(did: "did:plc:ana", handle: nil, pds: URL(string: "https://pds.example.com")!),
            issuer: "https://auth.example.com", tokenEndpoint: URL(string: "https://auth.example.com/oauth/token")!,
            accessToken: "access-1", refreshToken: "refresh-1", expiresAt: now,
            scope: "atproto", dpopKey: Data("key".utf8), clientID: BlueskyClientConfiguration.influxPublic.clientID
        )
        await #expect(throws: BlueskyError.badMetadata("revocation_endpoint")) {
            try await oauth(http).revoke(session, nonce: nil)
        }
        #expect(http.requests.count == 1)
    }

    @Test func theCallbackMustComeBackToTheRedirect() async throws {
        let client = oauth(blueskyServers())
        let pending = try await client.begin(account: "ana.bsky.social")
        let elsewhere = URL(string: "https://evil.example/oauth/callback?state=\(pending.state)&iss=https://auth.example.com&code=code-1")!
        await #expect(throws: BlueskyError.callbackMismatch("redirect_uri")) {
            try await client.complete(pending, callback: elsewhere)
        }
    }

    @Test func theSigningServiceIsAskedForAnAssertion() async throws {
        let http = FakeHTTPClient { request in
            .init(body: try! JSONSerialization.data(withJSONObject: ["client_assertion": "jwt-1", "kid": "key-2"]))
        }
        let service = ClientAssertionService(url: URL(string: "https://influx.bespokebits.dev/oauth/assertion")!, http: http)
        let assertion = try await service.assertion(for: "https://auth.example.com", keyID: nil)
        #expect(assertion == ClientAssertion(jwt: "jwt-1", keyID: "key-2"))
        let sent = try #require(http.requests.first)
        #expect(sent.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(with: try #require(sent.httpBody)) as? [String: String]
        #expect(body == ["aud": "https://auth.example.com"])

        // A session started with one key can't be refreshed with another.
        await #expect(throws: BlueskyError.oauth("client key changed")) {
            try await service.assertion(for: "https://auth.example.com", keyID: "key-1")
        }
        http.respond { _ in .init(status: 409, body: try! JSONSerialization.data(withJSONObject: ["error": "key_retired"])) }
        await #expect(throws: BlueskyError.signInRequired) {
            try await service.assertion(for: "https://auth.example.com", keyID: "key-1")
        }
        // The day's limit is a wait, not a sign-out.
        http.respond { _ in .init(status: 503, headers: ["Retry-After": "3600"], body: try! JSONSerialization.data(withJSONObject: ["error": "daily_limit"])) }
        let error = await #expect(throws: BlueskyError.self) {
            try await service.assertion(for: "https://auth.example.com", keyID: "key-1")
        }
        guard case .rateLimited(let until)? = error else {
            Issue.record("expected a wait, got \(String(describing: error))")
            return
        }
        #expect(until != nil)
    }

    @Test func callbackMustMatchTheRequest() async throws {
        let client = oauth(blueskyServers())
        let pending = try await client.begin(account: "ana.bsky.social")
        await #expect(throws: BlueskyError.callbackMismatch("state")) {
            try await client.complete(pending, callback: callback(pending, state: "forged"))
        }
        await #expect(throws: BlueskyError.callbackMismatch("iss")) {
            try await client.complete(pending, callback: callback(pending, iss: "https://evil.example"))
        }
        let denied = URL(string: "dev.bespokebits.influx:/oauth/callback?state=\(pending.state)&iss=https://auth.example.com&error=access_denied")!
        await #expect(throws: BlueskyError.oauth("access_denied")) {
            try await client.complete(pending, callback: denied)
        }
    }

    @Test func tokensMustBeForTheAccountAskedFor() async throws {
        let client = oauth(blueskyServers(sub: "did:plc:someone-else"))
        let pending = try await client.begin(account: "ana.bsky.social")
        // Its grant is revoked on the way out (best effort).
        await #expect(throws: BlueskyError.differentAccount("did:plc:someone-else")) {
            try await client.complete(pending, callback: callback(pending))
        }
    }

    @Test func aHandleTheDocumentDoesNotClaimIsRejected() async throws {
        let http = blueskyServers(handleInDocument: "impostor.example")
        await #expect(throws: BlueskyError.identityNotFound("ana.bsky.social")) {
            try await oauth(http).begin(account: "ana.bsky.social")
        }
        #expect(!http.requests.contains { $0.url?.path == "/oauth/par" })
    }

    @Test func endpointsMustBeHTTPS() async throws {
        for endpoint in ["http://auth.example.com/oauth/token", "https://user@auth.example.com/oauth/token", "https://auth.example.com/oauth/token#x"] {
            let client = oauth(blueskyServers(tokenEndpoint: endpoint))
            await #expect(throws: BlueskyError.badMetadata("token_endpoint")) {
                try await client.begin(account: "ana.bsky.social")
            }
        }
    }

    @Test func aDIDIsNamedByItsCheckedHandleWithoutSigningIn() async {
        #expect(await oauth(blueskyServers()).handle(forDID: "did:plc:ana") == "ana.bsky.social")
        // A handle that doesn't point back at the DID isn't used.
        #expect(await oauth(blueskyServers(handleInDocument: "impostor.example")).handle(forDID: "did:plc:ana") == nil)
        #expect(await oauth(blueskyServers()).handle(forDID: "did:plc:nobody") == nil)
    }

    @Test func unknownHandlesFail() async throws {
        let client = oauth(blueskyServers())
        await #expect(throws: BlueskyError.identityNotFound("nobody.example")) {
            try await client.begin(account: "nobody.example")
        }
    }

    @Test func formEncodingEscapesReservedCharacters() {
        #expect(URLRequest.formEncoded([("a b", "x+y&z=é"), ("u", "dev.bespokebits.influx:/oauth/callback")])
            == "a%20b=x%2By%26z%3D%C3%A9&u=dev.bespokebits.influx%3A%2Foauth%2Fcallback")
    }
}

@Suite struct DPoPProofs {
    @Test func proofCarriesTheRequestAndKey() throws {
        let crypto = OAuthCrypto.fake()
        let url = URL(string: "https://pds.example.com/xrpc/app.bsky.feed.getTimeline?limit=100#frag")!
        let proof = try DPoP.proof(key: FakeDPoPKey(), method: "get", url: url, nonce: "n", accessToken: "tok", crypto: crypto, now: now)
        let (header, claims, signature) = try decodeJWT(proof, (DPoP.Header.self, DPoP.Claims.self))
        #expect(header == DPoP.Header(jwk: JWK(x: "x-key", y: "y-key")))
        #expect(claims.htm == "GET")
        #expect(claims.htu == "https://pds.example.com/xrpc/app.bsky.feed.getTimeline")
        #expect(claims.iat == 1_793_000_000)
        #expect(claims.nonce == "n")
        #expect(claims.ath == Data("sha256:tok".utf8).base64URLEncoded)
        #expect(!claims.jti.isEmpty)
        #expect(signature == Data("signed-by-key".utf8))
    }

    @Test func everyProofHasItsOwnID() throws {
        let crypto = OAuthCrypto.fake()
        let url = URL(string: "https://auth.example.com/oauth/token")!
        let first = try decodeJWT(DPoP.proof(key: FakeDPoPKey(), method: "POST", url: url, nonce: nil, accessToken: nil, crypto: crypto, now: now), (DPoP.Header.self, DPoP.Claims.self)).1
        let second = try decodeJWT(DPoP.proof(key: FakeDPoPKey(), method: "POST", url: url, nonce: nil, accessToken: nil, crypto: crypto, now: now), (DPoP.Header.self, DPoP.Claims.self)).1
        #expect(first.jti != second.jti)
        #expect(first.nonce == nil && first.ath == nil)
    }
}

#if canImport(CryptoKit)
import CryptoKit

/// The real cryptography, on Apple platforms only.
@Suite struct SystemCrypto {
    @Test func pkceMatchesRFC7636() {
        // RFC 7636 appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", crypto: .system)
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE(crypto: .system).verifier.count == 43)
    }

    @Test func proofsVerifyWithTheirJWK() throws {
        let key = OAuthCrypto.system.newKey()
        let proof = try DPoP.proof(key: key, method: "POST", url: URL(string: "https://auth.example.com/oauth/par")!, nonce: nil, accessToken: nil, crypto: .system, now: now)
        let (header, _, signature) = try decodeJWT(proof, (DPoP.Header.self, DPoP.Claims.self))
        func bytes(_ text: String) -> Data {
            var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            return Data(base64Encoded: base64)!
        }
        let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + bytes(header.jwk.x) + bytes(header.jwk.y))
        let signingInput = proof.split(separator: ".").prefix(2).joined(separator: ".")
        #expect(publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature), for: Data(signingInput.utf8)))

        let restored = try OAuthCrypto.system.restoreKey(key.rawRepresentation)
        #expect(restored.publicJWK == key.publicJWK)
    }
}
#endif
