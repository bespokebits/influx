import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A connected Sammy account's credentials: the server, the one access
/// token it granted, and whose account it is. Kept in the credential store
/// as one value, keyed by `accountID`, which syncs through iCloud Keychain
/// (ADR 0017). The token is never put in a source, a cursor or a sync
/// payload. There is no refresh state: the token doesn't expire, and is
/// revoked on the server or by signing out (ADR 0023).
public struct SammySession: Codable, Sendable, Hashable {
    /// The server's issuer, its https origin. The token is only ever sent
    /// here, and every feed URL is built from it.
    public var issuer: URL
    public var revocationEndpoint: URL?
    public var clientID: String
    public var accessToken: String
    public var scope: String
    /// The account's subject on the server, as its feed list gives it
    /// (`account.id`): stable, and particular to this client, so it says
    /// nothing about the server's own user IDs.
    public var subject: String
    /// After connecting again for more access (Bookmarks to Sammy Inbox),
    /// the access token this session replaces, until Sammy has confirmed
    /// the replacement (`SammySignIn.confirmReplacement`). Kept so the
    /// confirmation can be retried, and never sent anywhere else. Sammy
    /// ends the old token a day after it is confirmed, so the reader's
    /// other devices keep reading feeds with it until this session reaches
    /// them. Nil for every other session; sessions stored before it
    /// existed decode without it.
    public var replacesToken: String?

    public init(issuer: URL, revocationEndpoint: URL?, clientID: String = SammyOAuth.clientID, accessToken: String, scope: String = SammyOAuth.scope, subject: String, replacesToken: String? = nil) {
        self.issuer = issuer
        self.revocationEndpoint = revocationEndpoint
        self.clientID = clientID
        self.accessToken = accessToken
        self.scope = scope
        self.subject = subject
        self.replacesToken = replacesToken
    }

    /// Whether the server granted `scope` to this session, as the token
    /// response's space-separated `scope` says.
    public func grants(_ scope: String) -> Bool {
        self.scope.split(separator: " ").contains(Substring(scope))
    }

    /// Whether Influx may add to this account's Inbox with this session.
    public var addsToInbox: Bool { grants(SammyOAuth.inboxScope) }

    /// What to revoke when this stored session is replaced by `next`, or
    /// removed (nil): its own token, and the token it replaced that Sammy
    /// hasn't been confirmed to end (`replacesToken`), unless `next` still
    /// holds or names either. Without the second, a reconnect or sign-out
    /// before the confirmation lands would drop the only reference to a
    /// live grant.
    func endedBy(_ next: SammySession?) -> [SammySession] {
        let kept = Set([next?.accessToken, next?.replacesToken].compactMap { $0 })
        var ended: [SammySession] = []
        if !kept.contains(accessToken) {
            var own = self
            own.replacesToken = nil
            ended.append(own)
        }
        if let old = replacesToken, old != accessToken, !kept.contains(old) {
            var predecessor = self
            predecessor.accessToken = old
            predecessor.replacesToken = nil
            ended.append(predecessor)
        }
        return ended
    }

    /// `<subject>@<issuer host>`: what sources and the credential store call
    /// the account.
    public var accountID: String { Self.accountID(subject: subject, issuer: issuer) }

    /// What the reader knows the account by: "Sammy (<issuer host>)", with
    /// the port when it isn't https's own. The subject means nothing to a
    /// reader, so it isn't shown.
    public var displayName: String {
        let host = issuer.host()?.lowercased() ?? ""
        return "Sammy (\(issuer.port.map { "\(host):\($0)" } ?? host))"
    }

    /// The account ID for `subject` on `issuer`: its host, and its port when
    /// that isn't https's own. IDs are only compared, never taken apart.
    public static func accountID(subject: String, issuer: URL) -> String {
        let host = issuer.host()?.lowercased() ?? ""
        return issuer.port.map { "\(subject)@\(host):\($0)" } ?? "\(subject)@\(host)"
    }
}

/// A sign-in that has been started in the browser and not yet finished.
/// Held in memory for the length of the web authentication session.
public struct PendingSammySignIn: Sendable {
    /// Where to send the browser.
    public let authorizationURL: URL
    let oauth: SammyOAuth
    let state: String
    let pkce: PKCE
    /// What the authorization request asks for.
    var scope: String = SammyOAuth.scope
}

public enum SammySignInError: Error, Hashable, Sendable {
    /// What the reader typed isn't a server address.
    case notAnAddress
    /// The server answered, but not as a Sammy server does; the detail
    /// says what was missing.
    case notASammyServer(String)
    /// The browser came back without a usable code.
    case callback(SammyOAuth.CallbackError)
    /// The server refused, or couldn't be reached.
    case failed(ConnectorError)
    /// The server didn't answer within `SammySignIn.timeout`.
    case timedOut
    /// Signed in, but the credentials couldn't be saved on this device.
    case couldNotStore(String)
    /// The server doesn't offer this scope, as an older Sammy doesn't
    /// offer `inbox:add`.
    case scopeNotOffered(String)
    /// The reader approved, but without this scope (unticked on the
    /// approval sheet); the token granted has been revoked.
    case missingScope(String)
}

/// Signing in to Sammy accounts and finding them again. A Sammy server is
/// found by the address the reader types and its OAuth metadata; Influx is
/// a public client there, so there is nothing to register.
public struct SammySignIn: Sendable {
    /// `SammyOAuth.redirect`, under its older name.
    public static let redirectURI = SammyOAuth.redirect
    /// How long each sign-in request waits for the server. The reader is
    /// watching a spinner, so this is far shorter than URLSession's minute.
    public static let timeout: Duration = .seconds(15)

    let http: any HTTPClient
    let crypto: OAuthCrypto
    let credentials: any CredentialStore
    let redirectURI: String
    let timeout: Duration
    let now: @Sendable () -> Date

    public init(
        http: any HTTPClient = URLSession.shared, crypto: OAuthCrypto, credentials: any CredentialStore,
        redirectURI: String = SammyOAuth.redirect, timeout: Duration = Self.timeout, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.crypto = crypto
        self.credentials = credentials
        self.redirectURI = redirectURI
        self.timeout = timeout
        self.now = now
    }

    /// Finds the Sammy server at what the reader typed, such as
    /// `feeds.example.com`, from its metadata. Throws `.notAnAddress` for
    /// anything but an https origin, and `.notASammyServer` when the server
    /// has no metadata, or metadata a Sammy server wouldn't have.
    public func discover(server input: String) async throws(SammySignInError) -> SammyOAuth {
        guard let url = SammyOAuth.serverURL(from: input) else { throw .notAnAddress }
        let (data, response) = try await send(SammyOAuth.metadataRequest(server: url))
        let found = try SammyOAuth.discover(at: url, from: data, response, now: now())
        return SammyOAuth(server: found.server, redirectURI: redirectURI, requiresIssuer: found.requiresIssuer, scopesSupported: found.scopesSupported)
    }

    /// Starts signing in on the server the reader named, asking for
    /// `scope`: `feeds:read` alone for a new connection, and with
    /// `inbox:add` when Bookmarks to Sammy Inbox is switched on. A scope
    /// the server's metadata doesn't offer is `.scopeNotOffered`.
    public func begin(server input: String, scope: String = SammyOAuth.scope) async throws(SammySignInError) -> PendingSammySignIn {
        let oauth = try await discover(server: input)
        for wanted in scope.split(separator: " ") where !oauth.scopesSupported.contains(String(wanted)) {
            throw .scopeNotOffered(String(wanted))
        }
        return begin(oauth, state: crypto.randomToken(), pkce: PKCE(crypto: crypto), scope: scope)
    }

    /// The sign-in for `oauth` with this `state` and proof key: the
    /// authorization page to open, and what `complete` checks against.
    func begin(_ oauth: SammyOAuth, state: String, pkce: PKCE, scope: String = SammyOAuth.scope) -> PendingSammySignIn {
        PendingSammySignIn(
            authorizationURL: oauth.authorizeURL(state: state, codeChallenge: pkce.challenge, scope: scope),
            oauth: oauth, state: state, pkce: pkce, scope: scope
        )
    }

    /// Finishes signing in with the URL the browser came back with, learns
    /// whose account it is from its feed list (`account.id`), and stores the
    /// credentials. Returns the session and a source for each of the
    /// account's feeds, which may be none yet. Whenever the new token isn't
    /// stored, it is revoked, so no grant is left live that nothing holds;
    /// for the same reason, signing in again revokes the session it replaces.
    public func complete(_ pending: PendingSammySignIn, callback: URL) async throws(SammySignInError) -> (session: SammySession, sources: [Source]) {
        let (session, sources) = try await exchange(pending, callback: callback)
        try await store(session)
        return (session, sources)
    }

    /// Stores `session` for its account, and revokes the session it
    /// replaces, so no grant is left live that nothing holds. When it can't
    /// be stored, `session` itself is revoked.
    public func store(_ session: SammySession) async throws(SammySignInError) {
        let replaced = try? credentials.load(SammySession.self, for: session.accountID)
        do {
            try credentials.save(session, for: session.accountID)
        } catch {
            await revoke(session)
            throw .couldNotStore(String(describing: error))
        }
        for ended in replaced?.endedBy(session) ?? [] {
            await revoke(ended)
        }
    }

    /// Finishes signing in with the URL the browser came back with, and
    /// learns whose account it is from its feed list (`account.id`), but
    /// stores nothing: the caller stores the session (`store`) once the
    /// reader has chosen what to keep, or revokes it (`revoke`). Whenever
    /// this throws after the server granted a token, the token is revoked.
    public func exchange(_ pending: PendingSammySignIn, callback: URL) async throws(SammySignInError) -> (session: SammySession, sources: [Source]) {
        let code: String
        do {
            code = try pending.oauth.code(fromCallback: callback, expectedState: pending.state)
        } catch {
            throw .callback(error)
        }
        let server = pending.oauth.server
        let (tokenData, tokenResponse) = try await send(pending.oauth.tokenRequest(code: code, codeVerifier: pending.pkce.verifier))
        let tokens: SammyOAuth.Tokens
        do {
            tokens = try SammyOAuth.tokens(from: tokenData, tokenResponse, now: now(), requested: pending.scope)
        } catch {
            // A token granted but refused here (another scope, say) is
            // still live on the server.
            if tokenResponse.statusCode == 200, let granted = SammyOAuth.grantedToken(in: tokenData) {
                await revoke(SammySession(issuer: server.url, revocationEndpoint: server.revocationEndpoint, accessToken: granted, subject: ""))
                // The reader unticked reading feeds on the approval sheet.
                if let scope = SammyOAuth.grantedScope(in: tokenData), !scope.split(separator: " ").contains(Substring(SammyOAuth.scope)) {
                    throw .missingScope(SammyOAuth.scope)
                }
            }
            throw .failed(error)
        }

        // Whose token it is isn't known yet; revoking needs only the token.
        var session = SammySession(
            issuer: server.url, revocationEndpoint: server.revocationEndpoint, accessToken: tokens.accessToken,
            scope: tokens.scope, subject: ""
        )
        do throws(SammySignInError) {
            var request = SammyFeedList.request(issuer: server.url)
            request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
            let (listData, listResponse) = try await send(request)
            let list: SammyFeedList
            do {
                list = try SammyFeedList.decode(listData, listResponse, now: now())
            } catch let error as ConnectorError {
                throw .failed(error)
            } catch {
                throw .failed(.badResponse(String(describing: error)))
            }
            // The subject names the account here; a token that the feed
            // list doesn't say is whose can't be kept.
            guard let subject = list.account.id, SammyFeedList.isSafeID(subject) else { throw .notASammyServer("account id") }
            session.subject = subject
            let sources = SammyFeedConnector.sources(of: list, accountID: session.accountID, issuer: server.url, colorIndex: 0)
            return (session, sources)
        } catch {
            await revoke(session)
            throw error
        }
    }

    /// What confirming a replaced token came to.
    public enum Replacement: Sendable, Hashable {
        /// The stored session replaces no token.
        case nothingPending
        /// Sammy took it (204); the old token is no longer kept.
        case confirmed
        /// No answer, or a busy server: the old token is kept, and the
        /// confirmation is tried again at the next launch.
        case retryLater
        /// Sammy will never take it (the new token was refused, or the
        /// server has no such endpoint); the old token is no longer kept,
        /// and Sammy ends it when it has gone unused for 90 days.
        case abandoned
    }

    /// Confirms to Sammy that the session stored for `accountID`, made by
    /// connecting again for more access, replaces the token it names
    /// (`replacesToken`): `POST /oauth/replace` with the new token as its
    /// bearer and the old one in the form body. Sammy then ends the old
    /// token a day later. Called only once the new session is stored, and
    /// again at each launch until it lands; a repeat changes nothing.
    @discardableResult
    public func confirmReplacement(for accountID: String) async -> Replacement {
        guard let stored = try? credentials.load(SammySession.self, for: accountID), let old = stored.replacesToken else {
            return .nothingPending
        }
        let outcome: Replacement
        do {
            let (_, response) = try await send(SammyOAuth.replaceRequest(issuer: stored.issuer, bearer: stored.accessToken, replacing: old))
            outcome = SammyOAuth.replacement(status: response.statusCode)
        } catch {
            outcome = .retryLater
        }
        guard outcome == .confirmed || outcome == .abandoned else { return outcome }
        // Only the session confirmed is changed: another device may have
        // stored a newer one meanwhile.
        if var current = try? credentials.load(SammySession.self, for: accountID),
           current.accessToken == stored.accessToken, current.replacesToken == old {
            current.replacesToken = nil
            try? credentials.save(current, for: accountID)
        }
        return outcome
    }

    /// The session stored for `accountID`, if it has signed in on this
    /// device or another of the reader's.
    public func stored(_ accountID: String) throws -> SammySession? {
        try credentials.load(SammySession.self, for: accountID)
    }

    /// The Sammy accounts with a stored session, signed in on this device
    /// or another of the reader's. An account is found here, not only from
    /// its sources, so one with no feeds switched on can still be signed out
    /// of and offered the feeds it gains.
    public func accountIDs() throws -> [String] {
        try credentials.accounts().filter { (try? stored($0)) != nil }.sorted()
    }

    /// The account for a stored session.
    public func account(_ accountID: String) throws -> SammyAccount? {
        try stored(accountID).map { SammyAccount(session: $0, http: http, credentials: credentials) }
    }

    /// Asks the server to revoke `session`, best effort, within `timeout`.
    /// It goes in a task of its own, so a sign-in cancelled after the token
    /// was granted (the sheet closed while finishing, say) still revokes
    /// it: a cancelled task's requests would stop at once.
    public func revoke(_ session: SammySession) async {
        guard let request = SammyOAuth.revokeRequest(session) else { return }
        await Task { _ = try? await send(request) }.value
    }

    /// Sends `request` to the server, refusing redirects, giving up after
    /// `timeout`.
    private func send(_ request: URLRequest) async throws(SammySignInError) -> (Data, HTTPURLResponse) {
        let http = http
        let answer: Result<(Data, HTTPURLResponse), any Error>? = await withDeadline(timeout) {
            do {
                return .success(try await SammyOAuth.send(request, http: http))
            } catch {
                return .failure(error)
            }
        }
        switch answer {
        case nil: throw .timedOut
        case .success(let value): return value
        case .failure(let error as ConnectorError): throw .failed(error)
        case .failure: throw .failed(.offline)
        }
    }
}
