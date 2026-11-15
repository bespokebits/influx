import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The app's registration with Bluesky. AT Protocol OAuth has no client
/// registration: the client ID is the HTTPS URL of a metadata document the
/// authorization server fetches.
public struct BlueskyClientConfiguration: Sendable {
    public var clientID: String
    public var redirectURI: String
    public var scope: String
    public var authentication: BlueskyClientAuthentication

    public init(clientID: String, redirectURI: String, scope: String, authentication: BlueskyClientAuthentication = .none) {
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scope = scope
        self.authentication = authentication
    }

    /// Influx as a confidential client: Bluesky only accepts one registered
    /// as a web app, so the browser comes back through a universal link.
    /// New sign-ins use this one. With `attestation`, its signing service
    /// is asked as an attested install (ADR 0033).
    public static func influx(http: any HTTPClient, attestation: CallerAttestation? = nil) -> BlueskyClientConfiguration {
        confidential(host: "influx.bespokebits.dev", http: http, attestation: attestation)
    }

    /// The client Influx signed in with before the rename, on the old host.
    /// Sessions it started are refreshed and revoked with it, for as long as
    /// they last (ADR 0032); nothing new signs in with it.
    public static func flux(http: any HTTPClient, attestation: CallerAttestation? = nil) -> BlueskyClientConfiguration {
        confidential(host: "flux.bespokebits.dev", http: http, attestation: attestation)
    }

    /// The client on one of the hosts the OAuth Worker serves: its metadata,
    /// its callback, and its signing service, whose assertions name it.
    private static func confidential(host: String, http: any HTTPClient, attestation: CallerAttestation?) -> BlueskyClientConfiguration {
        BlueskyClientConfiguration(
            clientID: "https://\(host)/oauth/client-metadata.json",
            redirectURI: "https://\(host)/oauth/callback",
            scope: influxScope,
            authentication: .signed(ClientAssertionService(
                url: URL(string: "https://\(host)/oauth/assertion")!, http: http, attestation: attestation
            ))
        )
    }

    static let influxClientID = "https://influx.bespokebits.dev/oauth/client-metadata.json"
    /// The client of a session that doesn't say: every session from before
    /// sessions recorded their client started with this one.
    static let fluxClientID = "https://flux.bespokebits.dev/oauth/client-metadata.json"
    static let influxScope = "atproto transition:generic"

    /// Influx as a public client, as tests and previews use it.
    public static let influxPublic = BlueskyClientConfiguration(
        clientID: influxClientID,
        redirectURI: "dev.bespokebits.influx:/oauth/callback",
        // Reading needs only `atproto`; likes and boosts need writes,
        // which granular scopes can't yet grant for app.bsky records.
        scope: influxScope
    )
}

/// How Influx proves to an authorization server that it is Influx.
public enum BlueskyClientAuthentication: Sendable {
    /// A public client proves nothing, and its sessions end after two weeks.
    case none
    /// A confidential client sends an assertion signed with a Bespoke Bits
    /// key with every PAR and token request, and keeps its session.
    case signed(any ClientAssertionSigner)
}

/// A signed client assertion (RFC 7523) for one request.
public struct ClientAssertion: Sendable, Hashable {
    public var jwt: String
    /// The key that signed it. A session must be refreshed with the key it
    /// started with, so the session keeps this.
    public var keyID: String

    public init(jwt: String, keyID: String) {
        self.jwt = jwt
        self.keyID = keyID
    }
}

public protocol ClientAssertionSigner: Sendable {
    /// A fresh assertion addressed to `issuer`, signed with `keyID`, or with
    /// the current key when that is nil.
    func assertion(for issuer: String, keyID: String?) async throws -> ClientAssertion
}

/// The Bespoke Bits signing service, which holds Influx's client key. It only
/// signs assertions; tokens never pass through it.
public struct ClientAssertionService: ClientAssertionSigner {
    public let url: URL
    let http: any HTTPClient
    /// Proves the request comes from a genuine install (ADR 0033). Without
    /// it, or where the platform can't attest, requests go unattested.
    let attestation: CallerAttestation?

    public init(url: URL, http: any HTTPClient, attestation: CallerAttestation? = nil) {
        self.url = url
        self.http = http
        self.attestation = attestation
    }

    public func assertion(for issuer: String, keyID: String?) async throws -> ClientAssertion {
        struct Body: Encodable { var aud: String; var kid: String?; var challenge: String? }
        struct Reply: Decodable { var client_assertion: String; var kid: String }
        let body = { @Sendable (challenge: String?) throws -> Data in
            try JSONEncoder().encode(Body(aud: issuer, kid: keyID, challenge: challenge))
        }
        let (data, response): (Data, HTTPURLResponse)
        if let attestation {
            (data, response) = try await attestation.send(to: url, body: body)
        } else {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try body(nil)
            (data, response) = try await http.send(request)
        }
        // 503 is the service's daily limit (or an outage): the session is
        // fine, so it waits like a rate limit rather than signing out.
        if response.statusCode == 429 || response.statusCode == 503 {
            throw BlueskyError.rateLimited(until: DPoPRequest.rateLimitReset(response))
        }
        // The session's key has been retired, so the session can't be
        // refreshed: the reader has to sign in again.
        if response.statusCode == 409 { throw BlueskyError.signInRequired }
        guard response.statusCode == 200, let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw BlueskyError.http(status: response.statusCode, error: "client assertion")
        }
        guard keyID == nil || reply.kid == keyID else { throw BlueskyError.oauth("client key changed") }
        return ClientAssertion(jwt: reply.client_assertion, keyID: reply.kid)
    }
}

/// A signed-in Bluesky account's tokens, and the DPoP key they are bound
/// to. Kept in the keychain as one value, on this device only.
public struct BlueskySession: Codable, Sendable, Hashable {
    public var identity: ATIdentity
    /// The authorization server that issued the tokens.
    public var issuer: String
    public var tokenEndpoint: URL
    public var accessToken: String
    /// Single-use: every refresh returns a new one, which must be stored
    /// before the old one is forgotten.
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String
    public var dpopKey: Data
    /// The client key the session started with, for a confidential client.
    public var clientKeyID: String?
    /// The client ID the session started with. A session is refreshed and
    /// revoked with its own client, never another, so a change of client
    /// for new sign-ins leaves it signed in. Nil in a session stored before
    /// sessions recorded it, which is the flux client's
    /// (`BlueskyClientConfiguration.flux`).
    public var clientID: String?

    /// The client the session started with, saying it or not.
    var startedWithClient: String { clientID ?? BlueskyClientConfiguration.fluxClientID }

    /// The account ID that sources and the credential store use.
    public var accountID: String { identity.did }
}

/// A sign-in that has been started in the browser and not yet finished.
/// Held in memory for the length of the web authentication session.
public struct PendingBlueskySignIn: Sendable {
    /// Where to send the browser.
    public let authorizationURL: URL
    let state: String
    let pkce: PKCE
    let key: any DPoPKey
    let server: AuthorizationServerMetadata
    /// Who the reader said they are; nil when they started from a server.
    let expectedIdentity: ATIdentity?
    let nonce: String?
    let clientKeyID: String?
}

struct ProtectedResourceMetadata: Decodable {
    var authorization_servers: [String]
}

struct AuthorizationServerMetadata: Decodable, Sendable {
    var issuer: String
    var authorization_endpoint: URL
    var token_endpoint: URL
    var pushed_authorization_request_endpoint: URL
    var revocation_endpoint: URL?
    var dpop_signing_alg_values_supported: [String]?
    var scopes_supported: [String]?
    var authorization_response_iss_parameter_supported: Bool?
    var require_pushed_authorization_requests: Bool?
    var client_id_metadata_document_supported: Bool?
}

struct TokenResponse: Decodable {
    var access_token: String
    var token_type: String
    var refresh_token: String?
    var expires_in: Double?
    var scope: String?
    var sub: String?
}

struct OAuthErrorBody: Decodable {
    var error: String
    var error_description: String?
}

/// AT Protocol OAuth (atproto.com/specs/oauth): PAR, PKCE, and DPoP-bound
/// tokens, as a public or a confidential client.
public struct BlueskyOAuth: Sendable {
    /// The client new sign-ins use.
    let configuration: BlueskyClientConfiguration
    /// Clients earlier sign-ins used, which their sessions keep.
    let earlierClients: [BlueskyClientConfiguration]
    let http: any HTTPClient
    let crypto: OAuthCrypto
    let now: @Sendable () -> Date
    var resolver: ATIdentityResolver

    /// `earlierClients` are the clients sessions stored here may have
    /// started with besides `configuration`; such a session is refreshed
    /// and revoked with its own.
    public init(
        configuration: BlueskyClientConfiguration, earlierClients: [BlueskyClientConfiguration] = [],
        http: any HTTPClient, crypto: OAuthCrypto, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.earlierClients = earlierClients
        self.http = http
        self.crypto = crypto
        self.now = now
        resolver = ATIdentityResolver(http: http)
    }

    /// The app's: new sign-ins use the influx client, and sessions from
    /// before the rename keep the flux client they started with. Both ask
    /// their signing service through `attestation`, which is one Worker
    /// with one key store, so one registered key serves both.
    public static func influx(
        http: any HTTPClient, crypto: OAuthCrypto, attestation: CallerAttestation? = nil, now: @escaping @Sendable () -> Date = Date.init
    ) -> BlueskyOAuth {
        BlueskyOAuth(
            configuration: .influx(http: http, attestation: attestation), earlierClients: [.flux(http: http, attestation: attestation)],
            http: http, crypto: crypto, now: now
        )
    }

    /// The client `session` started with. One this build no longer knows
    /// can't be refreshed, so the reader signs in again.
    func client(for session: BlueskySession) throws -> BlueskyClientConfiguration {
        let id = session.startedWithClient
        guard let client = ([configuration] + earlierClients).first(where: { $0.clientID == id }) else {
            throw BlueskyError.signInRequired
        }
        return client
    }

    /// The handle the account `did` goes by, checked both ways, or nil if
    /// it can't be found. Needs no sign-in, so an account with none on this
    /// device can still be shown by its handle.
    public func handle(forDID did: String) async -> String? {
        try? await resolver.identity(did: did, claimedHandle: nil).handle
    }

    /// Starts signing in as `account`: a handle or a DID, or the address of
    /// a server such as `https://bsky.social` to choose the account there.
    public func begin(account: String) async throws -> PendingBlueskySignIn {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity: ATIdentity?
        let serverURL: URL
        if trimmed.hasPrefix("https://"), let url = URL(string: trimmed) {
            identity = nil
            serverURL = url
        } else {
            let resolved = try await resolver.resolve(trimmed)
            identity = resolved
            serverURL = resolved.pds
        }
        let server: AuthorizationServerMetadata
        if identity == nil, let direct = try? await authorizationServerMetadata(at: Self.origin(serverURL)) {
            // An entryway such as bsky.social is its own authorization server.
            server = direct
        } else {
            server = try await authorizationServer(for: serverURL)
        }

        let pkce = PKCE(crypto: crypto)
        let state = crypto.randomToken()
        let key = crypto.newKey()
        var fields = [
            ("client_id", configuration.clientID),
            ("response_type", "code"),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", pkce.method),
            ("state", state),
            ("redirect_uri", configuration.redirectURI),
            ("scope", configuration.scope),
        ]
        if let identity {
            fields.append(("login_hint", identity.handle ?? identity.did))
        }
        let (data, response, nonce, clientKeyID) = try await sendForm(
            server.pushed_authorization_request_endpoint, fields, client: configuration, issuer: server.issuer, clientKeyID: nil, key: key, nonce: nil
        )
        guard (200..<300).contains(response.statusCode) else { throw Self.failure(data, response) }
        struct PARResponse: Decodable { var request_uri: String }
        let par = try JSONDecoder().decode(PARResponse.self, from: data)

        var authorize = URLComponents(url: server.authorization_endpoint, resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "request_uri", value: par.request_uri),
        ]
        return PendingBlueskySignIn(
            authorizationURL: authorize.url!, state: state, pkce: pkce, key: key,
            server: server, expectedIdentity: identity, nonce: nonce, clientKeyID: clientKeyID
        )
    }

    /// Finishes signing in from the URL the browser was redirected to.
    public func complete(_ pending: PendingBlueskySignIn, callback: URL) async throws -> BlueskySession {
        let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        var bare = parts
        bare?.query = nil
        guard bare?.string == configuration.redirectURI else { throw BlueskyError.callbackMismatch("redirect_uri") }
        let query = parts?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        guard value("state") == pending.state else { throw BlueskyError.callbackMismatch("state") }
        guard value("iss") == pending.server.issuer else { throw BlueskyError.callbackMismatch("iss") }
        if let error = value("error") { throw BlueskyError.oauth(error) }
        guard let code = value("code") else { throw BlueskyError.callbackMismatch("code") }

        let (data, response, _, clientKeyID) = try await sendForm(
            pending.server.token_endpoint, [
                ("grant_type", "authorization_code"),
                ("code", code),
                ("redirect_uri", configuration.redirectURI),
                ("client_id", configuration.clientID),
                ("code_verifier", pending.pkce.verifier),
            ],
            client: configuration, issuer: pending.server.issuer, clientKeyID: pending.clientKeyID, key: pending.key, nonce: pending.nonce
        )
        guard response.statusCode == 200 else { throw Self.failure(data, response) }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        guard let sub = tokens.sub, let refreshToken = tokens.refresh_token else {
            throw BlueskyError.oauth("incomplete token response")
        }
        try Self.check(tokens)

        // The account the server signed in must be the one asked for, or,
        // starting from a server, one whose PDS that server speaks for.
        func session(_ identity: ATIdentity) -> BlueskySession {
            BlueskySession(
                identity: identity, issuer: pending.server.issuer, tokenEndpoint: pending.server.token_endpoint,
                accessToken: tokens.access_token, refreshToken: refreshToken,
                expiresAt: now().addingTimeInterval(tokens.expires_in ?? 300),
                scope: tokens.scope ?? configuration.scope, dpopKey: pending.key.rawRepresentation,
                clientKeyID: clientKeyID, clientID: configuration.clientID
            )
        }
        let identity: ATIdentity
        if let expected = pending.expectedIdentity {
            guard expected.did == sub else {
                // The browser signed in to another account. Its grant is
                // live by now, so it is revoked rather than left behind.
                var other = expected
                other.did = sub
                other.handle = nil
                try? await revoke(session(other), nonce: nil)
                throw BlueskyError.differentAccount(sub)
            }
            identity = expected
        } else {
            identity = try await resolver.identity(did: sub, claimedHandle: nil)
            let server = try await authorizationServer(for: identity.pds)
            guard server.issuer == pending.server.issuer else { throw BlueskyError.callbackMismatch("issuer") }
        }
        return session(identity)
    }

    /// Exchanges the session's refresh token for new tokens, as the client
    /// the session started with. The old refresh token is spent whether or
    /// not the caller manages to store the result.
    func refresh(_ session: BlueskySession, nonce: String?) async throws -> (BlueskySession, nonce: String?) {
        let client = try client(for: session)
        let key = try crypto.restoreKey(session.dpopKey)
        let (data, response, nonce, _) = try await sendForm(
            session.tokenEndpoint, [
                ("grant_type", "refresh_token"),
                ("refresh_token", session.refreshToken),
                ("client_id", client.clientID),
            ],
            client: client, issuer: session.issuer, clientKeyID: session.clientKeyID, key: key, nonce: nonce
        )
        guard response.statusCode == 200 else {
            AuthLog.refused("Bluesky", account: session.accountID, status: response.statusCode, data: data)
            let error = Self.failure(data, response)
            // A spent, revoked or expired refresh token ends the session.
            if case .oauth("invalid_grant") = error { throw BlueskyError.signInRequired }
            throw error
        }
        let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
        try Self.check(tokens)
        guard tokens.sub == nil || tokens.sub == session.identity.did else { throw BlueskyError.callbackMismatch("sub") }
        var refreshed = session
        refreshed.accessToken = tokens.access_token
        refreshed.refreshToken = tokens.refresh_token ?? session.refreshToken
        refreshed.expiresAt = now().addingTimeInterval(tokens.expires_in ?? 300)
        refreshed.scope = tokens.scope ?? session.scope
        return (refreshed, nonce)
    }

    /// Asks the authorization server to revoke the session's refresh token,
    /// which ends the access tokens issued with it too (RFC 7009), as the
    /// client the session started with.
    public func revoke(_ session: BlueskySession, nonce: String?) async throws {
        let client = try client(for: session)
        guard let issuer = URL(string: session.issuer) else { throw BlueskyError.badMetadata("issuer") }
        let server = try await authorizationServerMetadata(at: Self.origin(issuer))
        guard let endpoint = server.revocation_endpoint, Self.isSafeEndpoint(endpoint) else {
            throw BlueskyError.badMetadata("revocation_endpoint")
        }
        let key = try crypto.restoreKey(session.dpopKey)
        let (data, response, _, _) = try await sendForm(
            endpoint, [
                ("token", session.refreshToken),
                ("token_type_hint", "refresh_token"),
                ("client_id", client.clientID),
            ],
            client: client, issuer: session.issuer, clientKeyID: session.clientKeyID, key: key, nonce: nonce
        )
        guard response.statusCode == 200 else { throw Self.failure(data, response) }
    }

    /// Posts a form to the authorization server with a DPoP proof and, for a
    /// confidential `client`, a client assertion from its signing service.
    /// Each attempt gets a fresh assertion, because a server refuses one it
    /// has already seen.
    private func sendForm(
        _ url: URL, _ fields: [(String, String)], client: BlueskyClientConfiguration,
        issuer: String, clientKeyID: String?, key: any DPoPKey, nonce: String?
    ) async throws -> (Data, HTTPURLResponse, nonce: String?, clientKeyID: String?) {
        guard case .signed(let signer) = client.authentication else {
            let (data, response, nonce) = try await DPoPRequest.send(
                .form(url, fields), key: key, accessToken: nil, nonce: nonce, http: http, crypto: crypto, now: now()
            )
            return (data, response, nonce, nil)
        }
        var usedKey = clientKeyID
        let (data, response, nonce) = try await DPoPRequest.send(
            {
                let assertion = try await signer.assertion(for: issuer, keyID: usedKey)
                usedKey = assertion.keyID
                return .form(url, fields + [
                    ("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
                    ("client_assertion", assertion.jwt),
                ])
            },
            key: key, accessToken: nil, nonce: nonce, http: http, crypto: crypto, now: now()
        )
        return (data, response, nonce, usedKey)
    }

    private static func check(_ tokens: TokenResponse) throws {
        guard tokens.token_type.caseInsensitiveCompare("DPoP") == .orderedSame else {
            throw BlueskyError.oauth("token type \(tokens.token_type)")
        }
        guard let scope = tokens.scope, scope.split(separator: " ").contains("atproto") else {
            throw BlueskyError.oauth("scope without atproto")
        }
    }

    /// The authorization server a PDS (or an entryway such as bsky.social)
    /// sends its accounts to, with its metadata checked against the profile.
    func authorizationServer(for resource: URL) async throws -> AuthorizationServerMetadata {
        let resourceMetadata: ProtectedResourceMetadata = try await getJSON(Self.origin(resource).appending(path: ".well-known/oauth-protected-resource"))
        guard resourceMetadata.authorization_servers.count == 1,
              let issuer = URL(string: resourceMetadata.authorization_servers[0]),
              issuer.scheme == "https", issuer.path.isEmpty || issuer.path == "/", issuer.query == nil else {
            throw BlueskyError.badMetadata("authorization_servers")
        }
        return try await authorizationServerMetadata(at: Self.origin(issuer))
    }

    func authorizationServerMetadata(at origin: URL) async throws -> AuthorizationServerMetadata {
        let server: AuthorizationServerMetadata = try await getJSON(origin.appending(path: ".well-known/oauth-authorization-server"))
        guard server.issuer == origin.absoluteString else { throw BlueskyError.badMetadata("issuer") }
        // Codes, verifiers and refresh tokens go to these, so all must be
        // plain HTTPS addresses.
        for (name, endpoint) in [
            ("authorization_endpoint", server.authorization_endpoint),
            ("token_endpoint", server.token_endpoint),
            ("pushed_authorization_request_endpoint", server.pushed_authorization_request_endpoint),
        ] where !Self.isSafeEndpoint(endpoint) {
            throw BlueskyError.badMetadata(name)
        }
        guard server.dpop_signing_alg_values_supported?.contains("ES256") == true else { throw BlueskyError.badMetadata("dpop") }
        guard server.scopes_supported?.contains("atproto") ?? true else { throw BlueskyError.badMetadata("scopes") }
        return server
    }

    private func getJSON<Value: Decodable>(_ url: URL) async throws -> Value {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200, let value = try? JSONDecoder().decode(Value.self, from: data) else {
            throw BlueskyError.badMetadata(url.absoluteString)
        }
        return value
    }

    /// An absolute HTTPS URL with a host, and no credentials or fragment.
    static func isSafeEndpoint(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && !(parts.host ?? "").isEmpty
            && parts.user == nil && parts.password == nil && parts.fragment == nil
    }

    /// `https://host[:port]`, with no path or trailing slash.
    static func origin(_ url: URL) -> URL {
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.port = url.port
        return parts.url!
    }

    static func failure(_ data: Data, _ response: HTTPURLResponse) -> BlueskyError {
        if response.statusCode == 429 { return .rateLimited(until: DPoPRequest.rateLimitReset(response)) }
        if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data) {
            return response.statusCode == 400 || response.statusCode == 401 ? .oauth(body.error) : .http(status: response.statusCode, error: body.error)
        }
        return .http(status: response.statusCode, error: nil)
    }
}

/// Sends a request with a DPoP proof, retrying once when the server asks for
/// a fresh nonce, and returns the latest nonce the server sent.
enum DPoPRequest {
    static func send(
        _ request: URLRequest, key: any DPoPKey, accessToken: String?, nonce: String?,
        http: any HTTPClient, crypto: OAuthCrypto, now: Date
    ) async throws -> (Data, HTTPURLResponse, nonce: String?) {
        try await send({ request }, key: key, accessToken: accessToken, nonce: nonce, http: http, crypto: crypto, now: now)
    }

    /// As above, building the request afresh for each attempt.
    static func send(
        _ build: () async throws -> URLRequest, key: any DPoPKey, accessToken: String?, nonce: String?,
        http: any HTTPClient, crypto: OAuthCrypto, now: Date
    ) async throws -> (Data, HTTPURLResponse, nonce: String?) {
        var nonce = nonce
        for attempt in 0..<2 {
            let request = try await build()
            var signed = request
            let url = request.url!
            signed.setValue(
                try DPoP.proof(key: key, method: request.httpMethod ?? "GET", url: url, nonce: nonce, accessToken: accessToken, crypto: crypto, now: now),
                forHTTPHeaderField: "DPoP"
            )
            if let accessToken {
                signed.setValue("DPoP \(accessToken)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await http.send(signed)
            let previous = nonce
            if let fresh = response.header("DPoP-Nonce") { nonce = fresh }
            if attempt == 0, nonce != previous, needsNonce(data, response) {
                continue
            }
            return (data, response, nonce)
        }
        preconditionFailure("unreachable")
    }

    /// Whether the server refused the proof for want of its current nonce:
    /// an OAuth error body from an authorization server, or a
    /// `WWW-Authenticate` challenge from a resource server.
    static func needsNonce(_ data: Data, _ response: HTTPURLResponse) -> Bool {
        guard response.statusCode == 400 || response.statusCode == 401 else { return false }
        if response.header("WWW-Authenticate")?.contains("use_dpop_nonce") == true { return true }
        return (try? JSONDecoder().decode(OAuthErrorBody.self, from: data))?.error == "use_dpop_nonce"
    }

    /// When a rate limit lifts: the `ratelimit-reset` header (Unix seconds),
    /// or `Retry-After` (seconds from now).
    static func rateLimitReset(_ response: HTTPURLResponse, now: Date = Date()) -> Date? {
        if let reset = response.header("ratelimit-reset").flatMap(TimeInterval.init) {
            return Date(timeIntervalSince1970: reset)
        }
        if let after = response.header("Retry-After").flatMap(TimeInterval.init) {
            return now.addingTimeInterval(after)
        }
        return nil
    }
}
