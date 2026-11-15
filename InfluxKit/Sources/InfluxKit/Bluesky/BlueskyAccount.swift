import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One signed-in Bluesky account: authenticated app view requests through
/// the account's PDS, with token refresh.
///
/// Refresh tokens are single-use, so refreshes are serialized: requests that
/// find the access token expired share one refresh, and the new session is
/// written to the credential store before any request uses it. If that
/// write fails, the new session is kept in memory (the old refresh token is
/// already spent) and the write is retried before each later request. If the
/// app dies before a write succeeds, the account has to sign in again.
///
/// The app keeps each Bluesky session on the device that signed in (ADR
/// 0017): the server ends the whole session when a spent refresh token is
/// used again, so devices can't safely share one. The rules below still
/// cover a session an earlier Influx shared, and another process reading
/// the same item, where another holder may refresh it first. Before
/// refreshing, a stored session newer than this one is taken instead; and a
/// refresh the server refuses is checked against the store, since the
/// token it spent may have been spent by the other device, which stored a
/// new one. An ended session's credentials are left in place rather than
/// deleted, because the deletion would reach the other devices too, and the
/// one this device has may only be the old copy.
public actor BlueskyAccount {
    public private(set) var session: BlueskySession
    /// The account's DID: what sources and the credential store call it.
    public nonisolated let accountID: String
    private let oauth: BlueskyOAuth
    private let credentials: any CredentialStore
    private var key: any DPoPKey
    /// The latest DPoP nonce from each server: the PDS and the
    /// authorization server rotate theirs separately.
    private var resourceNonce: String?
    private var authorizationNonce: String?
    /// The refresh under way, if any, numbered so that only the requests
    /// waiting on that refresh act on its result.
    private var refreshing: (generation: Int, task: Task<Refreshed, any Error>)?
    private var refreshGeneration = 0
    /// Set once the reader signs out here, so later requests fail at once.
    private var signedOut = false
    /// The refresh token of a session that has ended, so later requests
    /// fail at once instead of spending it again, until another device
    /// stores a new session (by refreshing or signing in again), which
    /// this one then takes up.
    private var endedRefreshToken: String?
    /// Set while the session in memory is newer than the stored one.
    private var unsaved = false

    private struct Refreshed: Sendable {
        var session: BlueskySession
        var nonce: String?
        var saved: Bool
    }

    /// Refresh this long before the access token expires, so a request
    /// doesn't race the expiry.
    static let refreshMargin: TimeInterval = 60
    static let appView = "did:web:api.bsky.app#bsky_appview"

    public init(session: BlueskySession, oauth: BlueskyOAuth, credentials: any CredentialStore) throws {
        self.session = session
        accountID = session.accountID
        self.oauth = oauth
        self.credentials = credentials
        key = try oauth.crypto.restoreKey(session.dpopKey)
    }

    /// The account stored for `accountID`, if it has signed in on this device.
    public static func stored(_ accountID: String, oauth: BlueskyOAuth, credentials: any CredentialStore) throws -> BlueskyAccount? {
        try credentials.load(BlueskySession.self, for: accountID).map {
            try BlueskyAccount(session: $0, oauth: oauth, credentials: credentials)
        }
    }

    /// Ends the session: forgets it on this device, then asks the
    /// authorization server to revoke it. Signing out works offline; if the
    /// revocation fails, the token stays valid on the server until it expires.
    public func signOut() async {
        signedOut = true
        // A refresh under way is about to replace the refresh token, so wait
        // for it and revoke the one it returns.
        if let task = refreshing?.task, let refreshed = try? await task.value {
            session = refreshed.session
            authorizationNonce = refreshed.nonce
        }
        try? credentials.delete(for: accountID)
        try? await oauth.revoke(session, nonce: authorizationNonce)
    }

    // MARK: Feeds

    /// The Following feed, newest first; pass the last page's cursor for
    /// the next, older page.
    func timeline(cursor: String?, limit: Int = 100) async throws -> FeedPage {
        try await get("app.bsky.feed.getTimeline", [("limit", "\(limit)"), ("cursor", cursor)])
    }

    /// A custom feed by its generator's `at://` URI.
    func feed(_ uri: String, cursor: String?, limit: Int = 100) async throws -> FeedPage {
        try await get("app.bsky.feed.getFeed", [("feed", uri), ("limit", "\(limit)"), ("cursor", cursor)])
    }

    /// The custom feeds the reader has saved in Bluesky, with their names,
    /// pinned ones first, for choosing sources.
    func savedFeeds() async throws -> [FeedGeneratorView] {
        let preferences: Preferences = try await get("app.bsky.actor.getPreferences", [])
        let saved = preferences.savedFeeds.filter { $0.type == "feed" }
        let uris = saved.filter(\.pinned).map(\.value) + saved.filter { !$0.pinned }.map(\.value)
        guard !uris.isEmpty else { return [] }
        struct Generators: Decodable { var feeds: [Lenient<FeedGeneratorView>] }
        var named: [String: FeedGeneratorView] = [:]
        // getFeedGenerators takes at most 25 feeds a call.
        for start in stride(from: 0, to: uris.count, by: 25) {
            let batch = uris[start..<min(start + 25, uris.count)]
            let page: Generators = try await get("app.bsky.feed.getFeedGenerators", batch.map { ("feeds", String?($0)) })
            for feed in page.feeds.compactMap(\.value) { named[feed.uri] = feed }
        }
        return uris.compactMap { named[$0] }
    }

    /// A post with what it answers and its replies, by its `at://` URI.
    func postThread(_ uri: String) async throws -> PostThreadResponse {
        try await get("app.bsky.feed.getPostThread", [("uri", uri), ("depth", "\(Self.threadDepth)"), ("parentHeight", "\(Self.threadParents)")])
    }

    /// What the reader has done to one post, fresh from the app view.
    func viewer(ofPost uri: String) async throws -> ViewerState? {
        struct Posts: Decodable { var posts: [Lenient<PostView>] }
        let page: Posts = try await get("app.bsky.feed.getPosts", [("uris", uri)])
        return page.posts.compactMap(\.value).first { $0.uri == uri }?.viewer
    }

    /// One page of the reader's bookmarks from the app view, most recently
    /// bookmarked first, and the cursor for the next; nil at the end.
    /// Bookmarked posts that are blocked or gone are left out.
    func bookmarks(cursor: String?, limit: Int = 100) async throws -> (posts: [PostView], cursor: String?) {
        struct Bookmark: Decodable { var item: Lenient<PostView>? }
        struct Page: Decodable { var cursor: String?; var bookmarks: [Lenient<Bookmark>] }
        let page: Page = try await get("app.bsky.bookmark.getBookmarks", [("limit", "\(limit)"), ("cursor", cursor)])
        let posts = page.bookmarks.compactMap { $0.value?.item?.value }
        return (posts, page.bookmarks.isEmpty ? nil : page.cursor)
    }

    /// How many levels of replies, and of posts above, a thread fetches.
    static let threadDepth = 6
    static let threadParents = 40

    // MARK: Writes

    /// The record the reader made, as `com.atproto.repo.createRecord`
    /// returns it.
    struct CreatedRecord: Decodable, Sendable {
        var uri: String
    }

    /// Writes a record (a like or a repost) to the reader's own repository.
    func createRecord(collection: String, record: [String: any Sendable]) async throws -> CreatedRecord {
        var record = record
        record["$type"] = collection
        record["createdAt"] = ATDate.format(oauth.now())
        return try await procedure("com.atproto.repo.createRecord", [
            "repo": accountID, "collection": collection, "record": record,
        ], viaAppView: false)
    }

    /// Deletes one of the reader's records by its `at://` URI. Only records
    /// in the reader's own repository and `collection` qualify.
    func deleteRecord(_ uri: String, collection: String) async throws {
        let parts = uri.split(separator: "/", omittingEmptySubsequences: true)
        guard uri.hasPrefix("at://"), parts.count == 4, parts[1] == accountID, parts[2] == collection else {
            throw ConnectorError.badResponse("not the reader's \(collection) record")
        }
        let _: Empty = try await procedure("com.atproto.repo.deleteRecord", [
            "repo": accountID, "collection": collection, "rkey": String(parts[3]),
        ], viaAppView: false)
    }

    func bookmark(uri: String, cid: String) async throws {
        let _: Empty = try await procedure("app.bsky.bookmark.createBookmark", ["uri": uri, "cid": cid], viaAppView: true)
    }

    func removeBookmark(uri: String) async throws {
        let _: Empty = try await procedure("app.bsky.bookmark.deleteBookmark", ["uri": uri], viaAppView: true)
    }

    /// Any JSON body, or none; procedures whose answer Influx doesn't read.
    struct Empty: Decodable, Sendable {
        init() {}
        init(from decoder: any Decoder) throws {}
    }

    // MARK: Requests

    private func get<Value: Decodable>(_ method: String, _ parameters: [(String, String?)]) async throws -> Value {
        var parts = URLComponents(url: session.identity.pds.appending(path: "xrpc/\(method)"), resolvingAgainstBaseURL: false)!
        let items = parameters.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
        parts.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: parts.url!)
        // The PDS forwards app.bsky calls to this app view.
        request.setValue(Self.appView, forHTTPHeaderField: "atproto-proxy")
        return try await call(method, request)
    }

    /// An XRPC procedure: a JSON POST. Writes to the reader's repository go
    /// to the PDS itself; app.bsky procedures go on to the app view.
    private func procedure<Value: Decodable>(_ method: String, _ body: [String: any Sendable], viaAppView: Bool) async throws -> Value {
        var request = URLRequest(url: session.identity.pds.appending(path: "xrpc/\(method)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        if viaAppView {
            request.setValue(Self.appView, forHTTPHeaderField: "atproto-proxy")
        }
        return try await call(method, request)
    }

    private func call<Value: Decodable>(_ method: String, _ request: URLRequest) async throws -> Value {
        var request = request
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await authorized(request)
        try Self.check(data, response, now: oauth.now())
        // Some procedures answer with no body at all.
        if let empty = Empty() as? Value { return empty }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw ConnectorError.badResponse("\(method): \(error)")
        }
    }

    /// The `ConnectorError` an XRPC response stands for, if any.
    static func check(_ data: Data, _ response: HTTPURLResponse, now: Date) throws {
        struct XRPCError: Decodable { var error: String; var message: String? }
        switch response.statusCode {
        case 200:
            return
        case 429:
            throw ConnectorError.rateLimited(retryAfter: DPoPRequest.rateLimitReset(response, now: now))
        case 401, 403:
            // Not a sign-out: the request went with a token that was fresh
            // or just refreshed, and only the token endpoint refusing the
            // refresh token (`invalid_grant`) ends the session. A feed
            // generator or the app view refusing one request, or a PDS
            // hiccup, shows as a quiet problem on the source instead of the
            // sign-in bar.
            let error = (try? JSONDecoder().decode(XRPCError.self, from: data))?.error ?? "none"
            AuthLog.rejected("Bluesky", status: response.statusCode, error: error)
            throw ConnectorError.badResponse("HTTP \(response.statusCode): \(error)")
        case 400:
            let body = try? JSONDecoder().decode(XRPCError.self, from: data)
            let error = body?.error ?? "HTTP 400"
            guard !["UnknownFeed", "NotFound", "UnknownList"].contains(error) else { throw ConnectorError.notFound }
            // The message says what was wrong with the request, for the log.
            throw ConnectorError.badResponse(body?.message.map { "\(error): \($0)" } ?? error)
        default:
            try ConnectorError.check(response, now: now)
            throw ConnectorError.badResponse("HTTP \(response.statusCode)")
        }
    }

    /// Sends `request` with the access token, refreshing it first when it is
    /// about to expire, and once more if the PDS says it has expired anyway.
    private func authorized(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try checkNotEnded()
        if unsaved {
            unsaved = (try? credentials.save(session, for: accountID)) == nil
        }
        if session.expiresAt.timeIntervalSince(oauth.now()) < Self.refreshMargin {
            takeStoredSessionIfNewer()
        }
        if session.expiresAt.timeIntervalSince(oauth.now()) < Self.refreshMargin {
            do {
                try await refresh()
            } catch ConnectorError.unauthorized {
                throw ConnectorError.unauthorized
            } catch where session.expiresAt > oauth.now() {
                // The token still works, so an outage of the signing
                // service or token endpoint doesn't stop reading yet.
            }
        }
        let token = session.accessToken
        var result = try await send(request)
        if result.1.statusCode == 401, result.1.header("WWW-Authenticate")?.contains("use_dpop_nonce") != true {
            // Usually `invalid_token`, but any other 401 is retried with a
            // fresh token too: whether the session has ended is the token
            // endpoint's call, not one request's. Another request may have
            // refreshed while this one was out; then the current token is
            // already new and needs no refresh.
            if session.accessToken == token { try await refresh() }
            result = try await send(request)
        }
        return result
    }

    /// Throws `ConnectorError.unauthorized` after sign-out, or while the
    /// session has ended and no other device has stored a new one.
    private func checkNotEnded() throws {
        if signedOut { throw ConnectorError.unauthorized }
        guard let ended = endedRefreshToken else { return }
        guard let stored = try? credentials.load(BlueskySession.self, for: accountID),
              stored.refreshToken != ended
        else { throw ConnectorError.unauthorized }
        try use(stored)
        endedRefreshToken = nil
        unsaved = false
    }

    /// Takes the stored session when another device has refreshed it since
    /// this one was read, so this device doesn't spend a token that is
    /// already spent.
    private func takeStoredSessionIfNewer() {
        guard !unsaved, refreshing == nil,
              let stored = try? credentials.load(BlueskySession.self, for: accountID),
              stored.refreshToken != session.refreshToken, stored.expiresAt > session.expiresAt
        else { return }
        try? use(stored)
    }

    /// Switches to `newer`, with its DPoP key if it has another one (as it
    /// does when the other device signed in again).
    private func use(_ newer: BlueskySession) throws {
        if newer.dpopKey != session.dpopKey {
            key = try oauth.crypto.restoreKey(newer.dpopKey)
            resourceNonce = nil
        }
        session = newer
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response, nonce) = try await DPoPRequest.send(
            request, key: key, accessToken: session.accessToken, nonce: resourceNonce,
            http: oauth.http, crypto: oauth.crypto, now: oauth.now()
        )
        resourceNonce = nonce
        return (data, response)
    }

    /// Replaces the session with a refreshed one, sharing a refresh already
    /// under way. Throws `ConnectorError.unauthorized` once the session has
    /// ended, and then forgets the stored credentials.
    func refresh() async throws {
        // After sign-out, a refresh would store a new session again.
        try checkNotEnded()
        let generation: Int
        let task: Task<Refreshed, any Error>
        if let refreshing {
            (generation, task) = refreshing
        } else {
            refreshGeneration += 1
            generation = refreshGeneration
            task = Task { [oauth, credentials, session, authorizationNonce] in
                do {
                    let (refreshed, nonce) = try await oauth.refresh(session, nonce: authorizationNonce)
                    // The old refresh token is spent, so a failed write
                    // must not lose the new one.
                    let saved = (try? credentials.save(refreshed, for: refreshed.accountID)) != nil
                    return Refreshed(session: refreshed, nonce: nonce, saved: saved)
                } catch BlueskyError.signInRequired {
                    // Another device may have spent the token and stored
                    // the new one, which works here too.
                    if let stored = try? credentials.load(BlueskySession.self, for: session.accountID),
                       stored.refreshToken != session.refreshToken {
                        return Refreshed(session: stored, nonce: nil, saved: true)
                    }
                    throw BlueskyError.signInRequired
                }
            }
            refreshing = (generation, task)
        }
        do {
            let refreshed = try await task.value
            // A later refresh may have started once this one finished; its
            // result is newer, so this one must not replace it.
            if refreshing?.generation == generation {
                try use(refreshed.session)
                authorizationNonce = refreshed.nonce ?? authorizationNonce
                unsaved = !refreshed.saved
                refreshing = nil
            }
        } catch {
            if refreshing?.generation == generation { refreshing = nil }
            switch error {
            case BlueskyError.signInRequired:
                endedRefreshToken = session.refreshToken
                throw ConnectorError.unauthorized
            case let error as BlueskyError:
                throw ConnectorError(error)
            default:
                throw error
            }
        }
    }
}

extension ConnectorError {
    /// How a sign-in or token failure shows on a source.
    init(_ error: BlueskyError) {
        switch error {
        case .signInRequired, .callbackMismatch, .differentAccount:
            self = .unauthorized
        case .oauth(let code):
            // Only `invalid_grant` (already `.signInRequired`) ends the
            // sign-in. Anything else, such as the signing service being
            // down (`invalid_client`), passes, so the account isn't shown
            // as signed out while its session still works.
            self = .badResponse("oauth \(code)")
        case .rateLimited(let until):
            self = .rateLimited(retryAfter: until)
        case .identityNotFound:
            self = .notFound
        case .badMetadata(let detail):
            self = .badResponse(detail)
        case .appNotAccepted:
            // The session is fine; this build just can't renew it, and
            // signing in again wouldn't help.
            self = .badResponse("this version of Influx can't sign in to Bluesky; update the app")
        case .http(let status, let error):
            self = .badResponse(error ?? "HTTP \(status)")
        }
    }
}
