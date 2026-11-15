import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A signed-in Mastodon account's credentials: the app's registration on the
/// instance and the access token it was granted. Kept in the keychain as one
/// value, on this device only. Mastodon tokens don't expire, so
/// there is nothing to refresh.
public struct MastodonSession: Codable, Sendable, Hashable {
    public var instance: URL
    /// `@user@instance`: what sources and the credential store call it.
    public var accountID: String
    public var app: Mastodon.Application
    public var accessToken: String
    public var scope: String
}

/// A sign-in that has been started in the browser and not yet finished.
/// Held in memory for the length of the web authentication session.
public struct PendingMastodonSignIn: Sendable {
    /// Where to send the browser.
    public let authorizationURL: URL
    let oauth: MastodonOAuth
    let app: Mastodon.Application
    let state: String
    let pkce: PKCE
}

public enum MastodonSignInError: Error, Hashable, Sendable {
    /// What the reader typed doesn't name an instance.
    case notAnInstance
    /// The browser came back without a usable code.
    case callback(MastodonOAuth.CallbackError)
    /// The instance refused, or couldn't be reached.
    case failed(ConnectorError)
    /// The instance didn't answer within `MastodonSignIn.timeout`.
    case timedOut
    /// Signed in, but the credentials couldn't be saved on this device.
    case couldNotStore(String)
}

/// Signing in to Mastodon accounts and finding them again. Each sign-in
/// registers Influx on the instance afresh, so nothing about one sign-in is
/// shared with another account or device.
public struct MastodonSignIn: Sendable {
    /// On the app's URL scheme, which was `dev.bespokebits.flux` before the
    /// rename. Accounts signed in before keep working: the redirect is used
    /// only while signing in, by the app each sign-in registers.
    public static let redirectURI = "dev.bespokebits.influx:/oauth/mastodon"
    /// How long each sign-in request waits for the instance. The reader is
    /// watching a spinner, so this is far shorter than URLSession's minute.
    public static let timeout: Duration = .seconds(15)

    let http: any HTTPClient
    let crypto: OAuthCrypto
    let credentials: any CredentialStore
    let redirectURI: String
    let timeout: Duration

    public init(http: any HTTPClient = URLSession.shared, crypto: OAuthCrypto, credentials: any CredentialStore, redirectURI: String = Self.redirectURI, timeout: Duration = Self.timeout) {
        self.http = http
        self.crypto = crypto
        self.credentials = credentials
        self.redirectURI = redirectURI
        self.timeout = timeout
    }

    /// Starts signing in on the instance the reader named: an address such
    /// as `mastodon.social`, or a handle such as `@me@mastodon.social`.
    public func begin(instance input: String) async throws(MastodonSignInError) -> PendingMastodonSignIn {
        guard let instance = MastodonOAuth.instanceURL(from: input) else { throw .notAnInstance }
        let oauth = MastodonOAuth(instance: instance, redirectURI: redirectURI)
        let app: Mastodon.Application = try await send(oauth.registerAppRequest())
        let state = crypto.randomToken()
        let pkce = PKCE(crypto: crypto)
        return PendingMastodonSignIn(
            authorizationURL: oauth.authorizeURL(clientID: app.clientId, state: state, codeChallenge: pkce.challenge),
            oauth: oauth, app: app, state: state, pkce: pkce
        )
    }

    /// Finishes signing in with the URL the browser came back with, and
    /// stores the account's credentials.
    public func complete(_ pending: PendingMastodonSignIn, callback: URL) async throws(MastodonSignInError) -> MastodonSession {
        let code: String
        do {
            code = try pending.oauth.code(fromCallback: callback, expectedState: pending.state)
        } catch {
            throw .callback(error)
        }
        let token: Mastodon.Token = try await send(pending.oauth.tokenRequest(app: pending.app, code: code, codeVerifier: pending.pkce.verifier))
        let instance = pending.oauth.instance
        let client = MastodonClient(instance: instance, accessToken: token.accessToken, http: http)
        let verified: Result<Mastodon.Account, ConnectorError>? = await withDeadline(timeout) {
            do throws(ConnectorError) {
                return .success(try await client.verifyCredentials())
            } catch {
                return .failure(error)
            }
        }
        let account: Mastodon.Account
        switch verified {
        case .success(let value): account = value
        case .failure(let error): throw .failed(error)
        case nil: throw .timedOut
        }
        let session = MastodonSession(
            instance: instance,
            accountID: MastodonMapper.accountID(for: account, on: instance),
            app: pending.app,
            accessToken: token.accessToken,
            scope: token.scope
        )
        do {
            try credentials.save(session, for: session.accountID)
        } catch {
            throw .couldNotStore(String(describing: error))
        }
        return session
    }

    /// The session stored for `accountID`, if it has signed in on this
    /// device.
    public func stored(_ accountID: String) throws -> MastodonSession? {
        try credentials.load(MastodonSession.self, for: accountID)
    }

    /// Forgets the account on this device, and asks the instance to revoke
    /// the token. The token is forgotten even if the instance can't be
    /// reached.
    public func signOut(_ session: MastodonSession) async throws {
        try credentials.delete(for: session.accountID)
        let oauth = MastodonOAuth(instance: session.instance, redirectURI: redirectURI)
        _ = try? await http.sendRefusingRedirects(oauth.revokeRequest(app: session.app, accessToken: session.accessToken))
    }

    /// Sign-in requests carry the app's secret, the authorization code or
    /// the token, so none of them follows a redirect off the instance.
    private func send<Value: Decodable>(_ request: URLRequest) async throws(MastodonSignInError) -> Value {
        let http = http
        let answer: Result<(Data, HTTPURLResponse), any Error>? = await withDeadline(timeout) {
            do {
                return .success(try await http.sendRefusingRedirects(request))
            } catch {
                return .failure(error)
            }
        }
        do {
            guard let answer else { throw MastodonSignInError.timedOut }
            let (data, response) = try answer.get()
            try ConnectorError.check(response, now: Date())
            return try Mastodon.decoder().decode(Value.self, from: data)
        } catch let error as MastodonSignInError {
            throw error
        } catch let error as ConnectorError {
            throw .failed(error)
        } catch is DecodingError {
            throw .failed(.badResponse("undecodable \(Value.self)"))
        } catch {
            throw .failed(.offline)
        }
    }
}

extension MastodonConnector {
    /// The connector for a signed-in account.
    public init(session: MastodonSession, colorIndex: Int = 0, http: any HTTPClient = URLSession.shared) {
        self.init(accountID: session.accountID, instance: session.instance, accessToken: session.accessToken, colorIndex: colorIndex, http: http)
    }
}
