import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Signing in to one Mastodon instance with OAuth 2 and PKCE. Influx registers
/// itself on each instance, per device, the first time someone signs in
/// there; the token that comes back stays in this device's keychain.
///
/// This builds the requests and reads the callback. Sending them, opening
/// the browser and storing the result are up to the caller.
public struct MastodonOAuth: Sendable, Hashable {
    /// Reading, plus the three v1 actions: favourite, boost (which is
    /// `write:statuses`) and bookmark.
    public static let scopes = "read write:favourites write:statuses write:bookmarks"
    public static let clientName = "Influx"
    public static let website = "https://bespokebits.dev"

    /// The instance's base URL, e.g. `https://mastodon.social`.
    public let instance: URL
    /// Where the instance sends the browser back with the code, e.g.
    /// `MastodonSignIn.redirectURI`.
    public let redirectURI: String

    public init(instance: URL, redirectURI: String) {
        self.instance = instance
        self.redirectURI = redirectURI
    }

    public enum CallbackError: Error, Hashable, Sendable {
        /// The callback isn't for the sign-in that was started.
        case stateMismatch
        /// The reader said no, or the instance refused.
        case denied(String)
        case missingCode
    }

    /// Turns what someone typed (`mastodon.social`, `@me@mastodon.social`,
    /// `https://mastodon.social/@me`) into the instance's base URL.
    public static func instanceURL(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            // A full handle names its instance after the last "@".
            if !text.contains("/"), let at = text.lastIndex(of: "@") {
                text = String(text[text.index(after: at)...])
            }
        }
        return ServerAddress.origin(from: text)
    }

    /// `POST /api/v1/apps`: registers Influx on the instance. The answer is a
    /// `Mastodon.Application`.
    public func registerAppRequest() -> URLRequest {
        formRequest(path: "/api/v1/apps", [
            ("client_name", Self.clientName),
            ("redirect_uris", redirectURI),
            ("scopes", Self.scopes),
            ("website", Self.website),
        ])
    }

    /// The page to open in the browser. `state` ties the callback to this
    /// sign-in; `codeChallenge` is the PKCE S256 challenge.
    public func authorizeURL(clientID: String, state: String, codeChallenge: String) -> URL {
        var components = URLComponents(url: endpoint("/oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = Self.formEncoded([
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("scope", Self.scopes),
            ("state", state),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
        ])
        return components.url!
    }

    /// Reads the authorization code from the URL the browser came back with.
    public func code(fromCallback url: URL, expectedState: String) throws(CallbackError) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw .stateMismatch }
        if let error = value("error") {
            throw .denied(value("error_description") ?? error)
        }
        guard let code = value("code"), !code.isEmpty else { throw .missingCode }
        return code
    }

    /// `POST /oauth/token`: trades the code for an access token. The answer
    /// is a `Mastodon.Token`.
    public func tokenRequest(app: Mastodon.Application, code: String, codeVerifier: String) -> URLRequest {
        formRequest(path: "/oauth/token", [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("client_id", app.clientId),
            ("client_secret", app.clientSecret),
            ("redirect_uri", redirectURI),
            ("code_verifier", codeVerifier),
            ("scope", Self.scopes),
        ])
    }

    /// `POST /oauth/revoke`: signs this device out on the instance.
    public func revokeRequest(app: Mastodon.Application, accessToken: String) -> URLRequest {
        formRequest(path: "/oauth/revoke", [
            ("client_id", app.clientId),
            ("client_secret", app.clientSecret),
            ("token", accessToken),
        ])
    }

    private func endpoint(_ path: String) -> URL {
        instance.appending(path: path)
    }

    private func formRequest(path: String, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncoded(fields).utf8)
        return request
    }

    /// `application/x-www-form-urlencoded`, which also suits a query string:
    /// everything but unreserved characters is percent-encoded, so `+`, `&`,
    /// `=` and spaces in values survive.
    static func formEncoded(_ fields: [(String, String)]) -> String {
        var unreserved = CharacterSet.alphanumerics
        unreserved.insert(charactersIn: "-._~")
        func encode(_ text: String) -> String {
            // Alphanumerics in CharacterSet include non-ASCII letters; keep
            // only ASCII ones unescaped.
            text.unicodeScalars.map { scalar in
                scalar.isASCII && unreserved.contains(scalar)
                    ? String(scalar)
                    : String(scalar).utf8.map { String(format: "%%%02X", $0) }.joined()
            }.joined()
        }
        return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
