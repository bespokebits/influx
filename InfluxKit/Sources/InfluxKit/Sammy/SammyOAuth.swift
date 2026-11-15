import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Sammy server's OAuth endpoints, from its authorization server metadata
/// (RFC 8414). Every one of them is on `url`, the issuer's origin.
public struct SammyServer: Codable, Sendable, Hashable {
    /// The issuer: the server's https origin, e.g. `https://feeds.example.com`.
    public var url: URL
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    /// Nil when the server doesn't offer one; signing out then only
    /// forgets the token.
    public var revocationEndpoint: URL?
}

/// Signing in to a Sammy server with OAuth 2: a public client with a fixed
/// client ID, the authorization code grant with PKCE (S256), and read-only
/// access to the reader's feeds, plus `inbox:add` once Bookmarks to Sammy
/// Inbox is switched on (connecting again for both). The server issues one
/// access token per connection, with no refresh token and no expiry; it is
/// revoked on the server or by signing out (ADR 0023).
///
/// This builds the requests and reads the answers. Sending them, opening
/// the browser and storing the result are up to the caller
/// (`SammySignIn`, `SammyAccount`).
public struct SammyOAuth: Sendable, Hashable {
    /// The access every connection asks for.
    public static let scope = "feeds:read"
    /// Adding to the reader's Inbox from what they bookmark (Bookmarks to
    /// Sammy Inbox). It allows one call, `POST /api/v1/captures`, and is
    /// asked for together with `scope` when the switch is turned on.
    public static let inboxScope = "inbox:add"
    /// What connecting again for Bookmarks to Sammy Inbox asks for.
    public static let inboxScopes = "\(scope) \(inboxScope)"
    /// Every Sammy server knows Influx by this; there is no registration
    /// and no secret.
    public static let clientID = "influx"
    /// Where the server sends the browser back, on the app's URL scheme
    /// beside Mastodon's.
    public static let redirect = "dev.bespokebits.influx:/oauth/sammy"
    /// What Connect Sammy fills the server address in with: the public
    /// Sammy service. The reader can change it to reach another server;
    /// either way it is normalised by `ServerAddress` like anything typed.
    public static let defaultServer = "api.heysammy.app"

    public let server: SammyServer
    /// Where the server sends the browser back with the code, normally
    /// `redirect`.
    public let redirectURI: String
    /// Whether the metadata says callbacks always name their issuer
    /// (`authorization_response_iss_parameter_supported`).
    public let requiresIssuer: Bool
    /// The scopes the metadata offers (`scopes_supported`).
    public let scopesSupported: [String]

    public init(server: SammyServer, redirectURI: String = Self.redirect, requiresIssuer: Bool = false, scopesSupported: [String] = [Self.scope]) {
        self.server = server
        self.redirectURI = redirectURI
        self.requiresIssuer = requiresIssuer
        self.scopesSupported = scopesSupported
    }

    /// The issuer, as metadata and callbacks spell it.
    public var issuer: String { server.url.absoluteString }

    public enum CallbackError: Error, Hashable, Sendable {
        /// The callback isn't for the sign-in that was started: another
        /// state, or another redirect on the app's scheme.
        case stateMismatch
        /// The callback names another server as its issuer (RFC 9207), or
        /// none when this one always names itself.
        case issuerMismatch
        /// The reader said no (`access_denied`), or the server refused.
        case denied(String)
        case missingCode
    }

    /// What a token request returns: the access token and its scope.
    struct Tokens: Sendable, Hashable {
        var accessToken: String
        var scope: String
    }

    // MARK: Discovery

    /// Turns what someone typed (`feeds.example.com`,
    /// `https://feeds.example.com/`) into the server's origin. Only https
    /// is accepted.
    public static func serverURL(from input: String) -> URL? {
        ServerAddress.origin(from: input)
    }

    /// `GET /.well-known/oauth-authorization-server` on the server.
    static func metadataRequest(server url: URL) -> URLRequest {
        var request = URLRequest(url: url.appending(path: ".well-known/oauth-authorization-server"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Reads the metadata that makes `url`, the origin the reader typed, a
    /// Sammy server: an issuer that is exactly that origin, authorization,
    /// token and revocation endpoints on the same origin, the `feeds:read`
    /// scope and S256 PKCE. Anything else is not a Sammy server, and the
    /// error says what was missing.
    static func discover(at url: URL, from data: Data, _ response: HTTPURLResponse, now: Date) throws(SammySignInError) -> SammyOAuth {
        struct Metadata: Decodable {
            var issuer: String?
            var authorization_endpoint: String?
            var token_endpoint: String?
            var revocation_endpoint: String?
            var scopes_supported: [String]?
            var code_challenge_methods_supported: [String]?
            var authorization_response_iss_parameter_supported: Bool?
        }
        // A busy or broken server may still be a Sammy server.
        if response.statusCode == 429 || response.statusCode >= 500 {
            do {
                try ConnectorError.check(response, now: now)
            } catch let error as ConnectorError {
                throw .failed(error)
            } catch {}
            throw .failed(.badResponse("HTTP \(response.statusCode)"))
        }
        guard response.statusCode == 200, let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else {
            throw .notASammyServer("no OAuth metadata")
        }
        // Exactly, as RFC 8414 compares it and as a callback's `iss` must
        // then match it (RFC 9207): not even a trailing slash differs.
        guard metadata.issuer == url.absoluteString else {
            throw .notASammyServer("issuer")
        }
        func endpoint(_ text: String?, _ name: String) throws(SammySignInError) -> URL {
            guard let text, let endpoint = URL(string: text), isSafeEndpoint(endpoint), ServerAddress.isSameOrigin(endpoint, url) else {
                throw .notASammyServer(name)
            }
            return endpoint
        }
        let authorization = try endpoint(metadata.authorization_endpoint, "authorization_endpoint")
        let token = try endpoint(metadata.token_endpoint, "token_endpoint")
        // Optional, but one elsewhere is no use and isn't sent the token.
        var revocation: URL?
        if let text = metadata.revocation_endpoint {
            revocation = try endpoint(text, "revocation_endpoint")
        }
        guard metadata.scopes_supported?.contains(scope) == true else { throw .notASammyServer("scope \(scope)") }
        guard metadata.code_challenge_methods_supported?.contains("S256") == true else { throw .notASammyServer("PKCE S256") }
        let server = SammyServer(url: url, authorizationEndpoint: authorization, tokenEndpoint: token, revocationEndpoint: revocation)
        return SammyOAuth(
            server: server, requiresIssuer: metadata.authorization_response_iss_parameter_supported == true,
            scopesSupported: metadata.scopes_supported ?? []
        )
    }

    /// An absolute https URL with a host, and no credentials or fragment.
    static func isSafeEndpoint(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme?.lowercased() == "https" && !(parts.host ?? "").isEmpty
            && parts.user == nil && parts.password == nil && parts.fragment == nil
    }

    // MARK: Sign-in

    /// The page to open in the browser. `state` ties the callback to this
    /// sign-in; `codeChallenge` is the PKCE S256 challenge; `scope` is
    /// what it asks for, `feeds:read` unless Bookmarks to Sammy Inbox
    /// needs `inbox:add` too.
    public func authorizeURL(state: String, codeChallenge: String, scope: String = Self.scope) -> URL {
        var components = URLComponents(url: server.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        let existing = components.percentEncodedQuery.map { $0 + "&" } ?? ""
        components.percentEncodedQuery = existing + MastodonOAuth.formEncoded([
            ("response_type", "code"),
            ("client_id", Self.clientID),
            ("redirect_uri", redirectURI),
            ("scope", scope),
            ("state", state),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
        ])
        return components.url!
    }

    /// Reads the authorization code from the URL the browser came back with,
    /// which must be `redirectURI` with this sign-in's state, and name this
    /// server as issuer if it names one. A refusal (`error=access_denied`)
    /// is `.denied`.
    public func code(fromCallback url: URL, expectedState: String) throws(CallbackError) -> String {
        let callback = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let expected = URLComponents(string: redirectURI)
        guard let callback, let expected, callback.scheme?.lowercased() == expected.scheme?.lowercased(),
              callback.host == expected.host, callback.path == expected.path
        else { throw .stateMismatch }
        let items = callback.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw .stateMismatch }
        if let iss = value("iss") {
            guard iss == issuer else { throw .issuerMismatch }
        } else if requiresIssuer {
            throw .issuerMismatch
        }
        if let error = value("error") {
            throw .denied(value("error_description") ?? error)
        }
        guard let code = value("code"), !code.isEmpty else { throw .missingCode }
        return code
    }

    /// Trades the code for the access token.
    func tokenRequest(code: String, codeVerifier: String) -> URLRequest {
        Self.formRequest(server.tokenEndpoint, [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", Self.clientID),
            ("code_verifier", codeVerifier),
        ])
    }

    // MARK: Tokens

    /// Asks the server to revoke the session's access token (RFC 7009).
    /// Nil when the server has no revocation endpoint.
    static func revokeRequest(_ session: SammySession) -> URLRequest? {
        guard let endpoint = session.revocationEndpoint else { return nil }
        return formRequest(endpoint, [
            ("token", session.accessToken),
            ("token_type_hint", "access_token"),
            ("client_id", session.clientID),
        ])
    }

    /// Reads a token endpoint's answer, which must be a Bearer token for
    /// `feeds:read`. A refused grant (`invalid_grant`: the code is spent,
    /// expired or not this client's) or client is `.unauthorized`; a 429 is
    /// `.rateLimited`. An answer without `scope` granted what was
    /// `requested` (RFC 6749 §5.1).
    static func tokens(from data: Data, _ response: HTTPURLResponse, now: Date, requested: String = Self.scope) throws(ConnectorError) -> Tokens {
        struct Answer: Decodable {
            var access_token: String
            var token_type: String
            var scope: String?
        }
        struct Failure: Decodable { var error: String }
        guard response.statusCode == 200 else {
            if response.statusCode == 400 || response.statusCode == 401 {
                let error = (try? JSONDecoder().decode(Failure.self, from: data))?.error
                if response.statusCode == 401 || error == "invalid_grant" || error == "invalid_client" {
                    throw .unauthorized
                }
                throw .badResponse(error ?? "HTTP \(response.statusCode)")
            }
            do {
                try ConnectorError.check(response, now: now)
            } catch let error as ConnectorError {
                throw error
            } catch {}
            throw .badResponse("HTTP \(response.statusCode)")
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), !answer.access_token.isEmpty else {
            throw .badResponse("undecodable token response")
        }
        guard answer.token_type.lowercased() == "bearer" else { throw .badResponse("token_type \(answer.token_type)") }
        if let scope = answer.scope, !scope.split(separator: " ").contains(Substring(Self.scope)) {
            throw .badResponse("scope without \(Self.scope)")
        }
        return Tokens(accessToken: answer.access_token, scope: answer.scope ?? requested)
    }

    /// The access token in a token endpoint's 200 answer, read without
    /// checking it, so a token `tokens(from:_:now:)` refuses can still be
    /// revoked.
    static func grantedToken(in data: Data) -> String? {
        struct Answer: Decodable { var access_token: String? }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.access_token.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The scope in a token endpoint's 200 answer, read without checking
    /// anything else, to say what the reader left out of an approval.
    static func grantedScope(in data: Data) -> String? {
        struct Answer: Decodable { var scope: String? }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.scope
    }

    /// Confirms that the `bearer` token, from connecting again, replaces
    /// the `replacing` one: `POST /oauth/replace` on the issuer, the old
    /// token in the form body, never in the URL.
    static func replaceRequest(issuer: URL, bearer: String, replacing old: String) -> URLRequest {
        var request = formRequest(issuer.appending(path: "oauth/replace"), [("replaces_token", old)])
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// What an answer to `replaceRequest` means. Sammy answers 204 to any
    /// valid bearer, whatever the old token was, so a 2xx is the end of
    /// it; a refused bearer (401), a refused body (400) or a server without
    /// the endpoint (404) won't change by trying again.
    static func replacement(status: Int) -> SammySignIn.Replacement {
        switch status {
        case 200..<300: .confirmed
        case 400, 401, 403, 404, 405: .abandoned
        default: .retryLater
        }
    }

    /// Asks the server to revoke `session`, best effort. It goes in a task
    /// of its own, so a caller that is cancelled (signing out as a sign-in
    /// is abandoned, say) still sends it: a cancelled task's requests stop
    /// at once, and the grant would stay live with nothing holding it.
    static func revoke(_ session: SammySession, http: any HTTPClient) async {
        guard let request = revokeRequest(session) else { return }
        await Task { _ = try? await send(request, http: http) }.value
    }

    /// Sends a request to a Sammy server: discovery, the token exchange, a
    /// revocation, or a feed request carrying the token. No redirect is
    /// followed (`sendRefusingRedirects`), so a code, verifier or token is
    /// only ever sent to the URL it was built for, and an answer from any
    /// other address is refused too.
    static func send(_ request: URLRequest, http: any HTTPClient) async throws(ConnectorError) -> (Data, HTTPURLResponse) {
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.sendRefusingRedirects(request)
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw .offline
        }
        guard let sent = request.url, let url = response.url, ServerAddress.isSameOrigin(url, sent), url.path == sent.path else {
            throw .badResponse("answered from another address")
        }
        return (data, response)
    }

    private static func formRequest(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(MastodonOAuth.formEncoded(fields).utf8)
        return request
    }
}
