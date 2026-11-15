import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One connected Sammy account: requests to its server with its bearer
/// token.
///
/// The token doesn't expire and isn't refreshed (ADR 0023), so a 401 means
/// the connection has ended: disconnected in Sammy, signed out everywhere,
/// or idle too long. The source then shows as needing to sign in again.
/// The stored session syncs to the reader's other devices through iCloud
/// Keychain (ADR 0017), so another device may have signed in again since
/// this one read it: before a 401 counts, a different stored session is
/// taken up and the request is tried once more with it.
///
/// The token is only ever sent to the account's own server, by a request
/// that follows no redirects.
public actor SammyAccount {
    public private(set) var session: SammySession
    /// `<subject>@<host>`: what sources and the credential store call it.
    public nonisolated let accountID: String
    /// The issuer: the server's origin. The token is only ever sent here.
    public nonisolated let server: URL
    private let http: any HTTPClient
    private let credentials: any CredentialStore
    /// Set once the reader signs out here, so later requests fail at once.
    private var signedOut = false
    /// Set while the session in memory is newer than the stored one,
    /// because writing it failed, so the stored one isn't taken over it.
    private var unsaved = false

    public init(session: SammySession, http: any HTTPClient = URLSession.shared, credentials: any CredentialStore) {
        self.session = session
        accountID = session.accountID
        server = session.issuer
        self.http = http
        self.credentials = credentials
    }

    /// Ends the connection: asks the server to revoke it, then forgets it
    /// on this device (and so, through iCloud Keychain, on the reader's
    /// others). Another device may have signed in again since this one
    /// read the store, so the stored token is revoked too. Each revocation
    /// waits at most `SammySignIn.timeout`, and signing out works offline;
    /// if a revocation fails, the token stays valid on the server until
    /// Sammy revokes it (disconnected there, or 90 days idle).
    public func signOut() async {
        signedOut = true
        var sessions = [session]
        if let stored = try? credentials.load(SammySession.self, for: accountID), stored.accessToken != session.accessToken {
            sessions.insert(stored, at: 0)
        }
        // A token replaced by connecting again, not yet confirmed to Sammy,
        // would otherwise outlive the sign-out: ending the new grant first
        // clears the old one's deadline on the server.
        for replaced in Set(sessions.compactMap(\.replacesToken)) where !sessions.contains(where: { $0.accessToken == replaced }) {
            var old = session
            old.accessToken = replaced
            old.replacesToken = nil
            sessions.append(old)
        }
        let http = http
        for old in sessions {
            // A task of its own, so a cancelled caller still revokes.
            _ = await Task {
                await withDeadline(SammySignIn.timeout) { () async -> Bool? in
                    await SammyOAuth.revoke(old, http: http)
                    return true
                }
            }.value
        }
        try? credentials.delete(for: accountID)
    }

    /// Takes up `session`, from signing in again on this device, in place
    /// of the one this account holds, and revokes the one it replaces, so
    /// no grant is left live that nothing holds. Revoking a token
    /// `SammySignIn.complete` already revoked is harmless (RFC 7009).
    /// Connecting again for more access passes `revokingReplaced: false`:
    /// the old token stays live until Sammy ends it, a day after the
    /// replacement is confirmed, because the reader's other devices read
    /// feeds with it until the new session reaches them.
    public func adopt(_ session: SammySession, revokingReplaced: Bool = true) async {
        let replaced = self.session
        self.session = session
        signedOut = false
        unsaved = (try? credentials.save(session, for: accountID)) == nil
        guard revokingReplaced else { return }
        for ended in replaced.endedBy(session) {
            await SammyOAuth.revoke(ended, http: http)
        }
    }

    /// The session to send with: the stored one when another device (or
    /// connecting again here) has stored a different one since, so a
    /// session that gained `inbox:add` is taken up before a capture is
    /// sent rather than after a refusal.
    public func latestSession() -> SammySession {
        if !unsaved, !signedOut, let stored = try? credentials.load(SammySession.self, for: accountID),
           stored.accessToken != session.accessToken {
            session = stored
        }
        return session
    }

    /// Whether this account has been signed out of here.
    var isSignedOut: Bool { signedOut }

    /// The token the last capture Sammy refused (401) carried.
    private var lastRefusedToken: String?

    func noteRefusal(_ token: String?) { lastRefusedToken = token }

    public func refusedToken() -> String? { lastRefusedToken }

    // MARK: Requests

    /// Sends `request` with the access token, refusing redirects. A 401 is
    /// tried once more when another device has stored a different session
    /// since; otherwise the 401 comes back for the caller to read as
    /// signed out. Only requests to the account's own server are sent.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, ServerAddress.isSameOrigin(url, server) else {
            throw ConnectorError.badResponse("not on the account's server")
        }
        if signedOut { throw ConnectorError.unauthorized }
        if unsaved {
            unsaved = (try? credentials.save(session, for: accountID)) == nil
        }
        let token = session.accessToken
        var result = try await sendWithToken(request)
        guard result.1.statusCode == 401, !signedOut else { return result }
        if session.accessToken != token {
            // Another request took up a newer session while this one was
            // out; this one was refused with the old token.
            result = try await sendWithToken(request)
        } else if !unsaved, let stored = try? credentials.load(SammySession.self, for: accountID), stored.accessToken != token {
            session = stored
            result = try await sendWithToken(request)
        }
        return result
    }

    // MARK: The change stream

    /// `<issuer>/api/v1/feeds/events`, the feed change stream (ADR 0038).
    static func feedEventsURL(on server: URL) -> URL {
        server.appending(path: "api/v1/feeds/events")
    }

    /// The change stream's request, to the account's server only, with
    /// the token in its `Authorization` header (never in the URL), and that
    /// token, so a refusal can be told from a session taken up since. Nil
    /// once the reader has signed out here. The transport follows no
    /// redirect, and gives up on a connection that is silent for
    /// `SammyFeedEvents.idleTimeout`.
    func feedEventsRequest() -> (request: URLRequest, token: String)? {
        if signedOut { return nil }
        if unsaved {
            unsaved = (try? credentials.save(session, for: accountID)) == nil
        }
        var request = URLRequest(url: Self.feedEventsURL(on: server), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: SammyFeedEvents.idleTimeout)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(RSSConnector.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return (request, session.accessToken)
    }

    /// After the change stream refused `token` (401): whether there is
    /// another session to try, as `send` looks for one. One taken up by
    /// another request since counts, and so does a different one stored by
    /// another device or by connecting again, which this account then takes
    /// up.
    func takeUpNewerSession(refused token: String) -> Bool {
        guard !signedOut else { return false }
        if session.accessToken != token { return true }
        guard !unsaved, let stored = try? credentials.load(SammySession.self, for: accountID), stored.accessToken != token else {
            return false
        }
        session = stored
        return true
    }

    private func sendWithToken(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        return try await SammyOAuth.send(request, http: http)
    }

    /// Whether `url` is on `server`: https, the same host and the same port.
    static func isOnServer(_ url: URL, _ server: URL) -> Bool {
        ServerAddress.isSameOrigin(url, server)
    }
}
