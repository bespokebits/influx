import Foundation

/// What `SammyConnectFlow` needs from a Sammy server: starting a sign-in,
/// trading its callback for a session without storing anything, and
/// revoking a session. `SammySignIn` is the real one.
public protocol SammyConnecting: Sendable {
    func begin(server input: String, scope: String) async throws(SammySignInError) -> PendingSammySignIn
    func exchange(_ pending: PendingSammySignIn, callback: URL) async throws(SammySignInError) -> (session: SammySession, sources: [Source])
    func revoke(_ session: SammySession) async
}

extension SammySignIn: SammyConnecting {}

/// Where `SammyConnectFlow` keeps the sources the reader chose. The store
/// is the real one.
public protocol SammyFlowSources: Sendable {
    func allSources() async throws -> [Source]
    /// Adds `sources` and removes `removing` all at once, or not at all.
    func apply(adding sources: [Source], removing: [String]) async throws
    func remove(sourceID: String) async throws
}

extension InfluxStore: SammyFlowSources {
    public func allSources() async throws -> [Source] { try await sources() }
    public func apply(adding sources: [Source], removing: [String]) async throws {
        try await save(sources: sources, removing: removing)
    }
    public func remove(sourceID: String) async throws { try await delete(sourceID: sourceID) }
}

/// Connecting a Sammy account, from the server address to the feeds the
/// reader ticks, and ending a connection again. The sheet that shows it is
/// only wiring; every rule is here, where Linux CI tests it.
///
/// 1. `begin(server:)` normalises the address (the public service's,
///    `defaultServer`, unless the reader changed it), discovers the server
///    and returns the page to open in the browser.
/// 2. `complete(callbackURL:)` trades the browser's callback for the
///    account's token and lists its feeds. Nothing is saved yet.
/// 3. `save(selected:)` saves the credential and the ticked feeds; it
///    refuses an empty selection, so an account never exists with nothing
///    to show for it.
///
/// Every path that ends without a saved source revokes the token and
/// deletes the credential: `cancel()`, `closeEmpty()` when the account has
/// no feeds yet, a save that fails, and a callback that comes back after
/// the reader cancelled. An Influx account exists only through its
/// sources, so nothing else could find a grant left behind.
public actor SammyConnectFlow {
    /// What the server address starts as.
    public static let defaultServer = SammyOAuth.defaultServer

    /// The account's feeds once the sign-in has come back, and which start
    /// ticked: the ones already here when the account was connected
    /// before, else all of them.
    public struct Offer: Sendable, Hashable {
        public var accountID: String
        public var feeds: [Source]
        public var ticked: Set<String>
        public var isEmpty: Bool { feeds.isEmpty }
    }

    /// What removing a feed did.
    public enum Removal: Sendable, Hashable {
        case removed
        /// It is the account's last feed, so it was left in place; the
        /// reader is asked whether to disconnect instead.
        case offerDisconnect
    }

    public enum FlowError: Error, Hashable, Sendable {
        /// `save` was given no feed the account offered.
        case nothingSelected
        /// There is no sign-in under way to finish or save.
        case notStarted
        /// The sign-in came back for another account than the one being
        /// signed in again.
        case differentAccount(String)
        /// Connecting again for more access came back without this scope
        /// (the reader unticked it); the new token has been revoked and the
        /// old session kept.
        case missingScope(String)
        /// Connecting again for more access, the account had no stored
        /// session left to upgrade (signed out meanwhile).
        case notConnected
    }

    private let connector: any SammyConnecting
    private let credentials: any CredentialStore
    private let sources: any SammyFlowSources
    private var pending: PendingSammySignIn?
    /// The session `complete` got, not yet saved; whoever ends the flow
    /// saves or revokes it.
    private var unsaved: SammySession?
    private var offer: Offer?
    /// Set by `cancel`, so a callback still being finished revokes what it
    /// gets instead of keeping it.
    private var isCancelled = false

    public init(connector: any SammyConnecting, credentials: any CredentialStore, sources: any SammyFlowSources) {
        self.connector = connector
        self.credentials = credentials
        self.sources = sources
    }

    // MARK: Connecting

    /// Finds the server at `server` and returns the page to approve the
    /// connection on, asking for `scope` (`feeds:read`, or with
    /// `inbox:add` to upgrade for Bookmarks to Sammy Inbox). Starting again
    /// revokes a session left unsaved.
    public func begin(server: String = SammyConnectFlow.defaultServer, scope: String = SammyOAuth.scope) async throws(SammySignInError) -> URL {
        await discardUnsaved()
        isCancelled = false
        let started = try await connector.begin(server: server, scope: scope)
        pending = started
        return started.authorizationURL
    }

    /// Trades the callback for the account's token and lists its feeds,
    /// saving nothing. An empty offer means the account has no feeds yet;
    /// the reader can only close it (`closeEmpty`).
    public func complete(callbackURL: URL) async throws -> Offer {
        guard let started = pending else { throw FlowError.notStarted }
        pending = nil
        let (session, feeds) = try await connector.exchange(started, callback: callbackURL)
        if isCancelled {
            await discard(session)
            throw CancellationError()
        }
        unsaved = session
        let here = Set(((try? await sources.allSources()) ?? []).filter { $0.kind == .sammyFeed && $0.accountID == session.accountID }.map(\.id))
        let offered = Set(feeds.map(\.id))
        let ticked = here.isDisjoint(with: offered) ? offered : here.intersection(offered)
        let made = Offer(accountID: session.accountID, feeds: feeds, ticked: ticked)
        offer = made
        return made
    }

    /// Saves the credential and the ticked feeds, and returns the session.
    /// Feeds the reader unticked that were here before are removed. A
    /// selection with none of the offered feeds is refused and changes
    /// nothing, so the reader can still tick one; a save that fails
    /// revokes the token and leaves no credential behind.
    @discardableResult
    public func save(selected: Set<String>) async throws -> SammySession {
        guard let session = unsaved, let offer else { throw FlowError.notStarted }
        let chosen = offer.feeds.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { throw FlowError.nothingSelected }
        // What is stored now is what a failed save puts back. If it can't
        // be read, nothing is changed and the reader can try again.
        let replaced: SammySession?
        do {
            replaced = try credentials.load(SammySession.self, for: session.accountID)
        } catch {
            throw SammySignInError.couldNotStore(String(describing: error))
        }
        // The save owns the session from here: a `cancel` while it runs
        // finds nothing to revoke, so it can't revoke a session this save
        // goes on to store. It comes too late to stop the save.
        unsaved = nil
        self.offer = nil
        do {
            let here = Set(try await sources.allSources().map(\.id))
            let unticked = offer.feeds.filter { !selected.contains($0.id) && here.contains($0.id) }.map(\.id)
            try credentials.save(session, for: session.accountID)
            // One transaction, so a failure leaves the account's feeds,
            // their posts and what syncs exactly as they were.
            try await sources.apply(adding: chosen.map(Self.colored), removing: unticked)
        } catch {
            await end(session, before: replaced)
            throw SammySignInError.couldNotStore(String(describing: error))
        }
        // The session replaced, and a token it replaced that Sammy hasn't
        // confirmed ending (`SammySession.endedBy`).
        for ended in replaced?.endedBy(session) ?? [] {
            await connector.revoke(ended)
        }
        return session
    }

    /// Signing an account in again: stores the session for the account
    /// already here, changing none of its sources. A sign-in that came back
    /// for another account is revoked.
    @discardableResult
    public func saveSignInAgain(expecting accountID: String) async throws -> SammySession {
        guard let session = unsaved else { throw FlowError.notStarted }
        unsaved = nil
        offer = nil
        guard session.accountID == accountID else {
            await discard(session)
            throw FlowError.differentAccount(session.accountID)
        }
        let replaced: SammySession?
        do {
            replaced = try credentials.load(SammySession.self, for: accountID)
        } catch {
            await discard(session)
            throw SammySignInError.couldNotStore(String(describing: error))
        }
        do {
            try credentials.save(session, for: accountID)
        } catch {
            await end(session, before: replaced)
            throw SammySignInError.couldNotStore(String(describing: error))
        }
        // The session replaced, and a token it replaced that Sammy hasn't
        // confirmed ending (`SammySession.endedBy`).
        for ended in replaced?.endedBy(session) ?? [] {
            await connector.revoke(ended)
        }
        return session
    }

    /// Connecting an account again for more access (switching Bookmarks to
    /// Sammy Inbox on): stores the new session in place of the one stored
    /// for `accountID`, changing none of its sources, only when it is
    /// the same Sammy account (the same issuer and pairwise subject) and
    /// holds every scope in `scopes`. Otherwise the new token is revoked,
    /// the old session stays, and this throws `.differentAccount` or
    /// `.missingScope`.
    ///
    /// The old token is not revoked: it is kept in the new session
    /// (`replacesToken`) until Sammy confirms the replacement
    /// (`SammySignIn.confirmReplacement`) and ends it a day later, so the
    /// reader's other devices keep reading feeds with it meanwhile.
    @discardableResult
    public func saveUpgrade(expecting accountID: String, scopes: [String] = [SammyOAuth.scope, SammyOAuth.inboxScope]) async throws -> SammySession {
        guard var session = unsaved else { throw FlowError.notStarted }
        unsaved = nil
        offer = nil
        let replaced: SammySession?
        do {
            replaced = try credentials.load(SammySession.self, for: accountID)
        } catch {
            await discard(session)
            throw SammySignInError.couldNotStore(String(describing: error))
        }
        guard let replaced else {
            await discard(session)
            throw FlowError.notConnected
        }
        guard session.accountID == accountID, session.issuer == replaced.issuer, session.subject == replaced.subject else {
            await discard(session)
            throw FlowError.differentAccount(session.accountID)
        }
        if let missing = scopes.first(where: { !session.grants($0) }) {
            await discard(session)
            throw FlowError.missingScope(missing)
        }
        if replaced.accessToken != session.accessToken {
            session.replacesToken = replaced.accessToken
        } else {
            session.replacesToken = replaced.replacesToken
        }
        do {
            try credentials.save(session, for: accountID)
        } catch {
            await end(session, before: replaced)
            throw SammySignInError.couldNotStore(String(describing: error))
        }
        // The old token is named by the new session, so it stays; a token
        // two upgrades back, never confirmed, is no longer named anywhere:
        // end it, so no grant is left live that nothing holds.
        for ended in replaced.endedBy(session) {
            await connector.revoke(ended)
        }
        return session
    }

    /// The reader closed the sheet or the browser: revokes a token already
    /// granted and deletes its credential. A callback still being finished
    /// revokes its token when it arrives.
    public func cancel() async {
        isCancelled = true
        pending = nil
        await discardUnsaved()
    }

    /// Closes the "no feeds yet" offer, the same way as cancelling.
    public func closeEmpty() async {
        await cancel()
    }

    // MARK: An account already connected

    /// Removes one of an account's feeds, unless it is the account's last:
    /// then nothing changes and the reader is offered to disconnect.
    public func removeSource(_ id: String) async throws -> Removal {
        let all = try await sources.allSources()
        if Self.removal(of: id, added: all) == .offerDisconnect { return .offerDisconnect }
        try await sources.remove(sourceID: id)
        return .removed
    }

    /// What removing the feed `id` from `added` would do: `.offerDisconnect`
    /// when it is its account's last Sammy feed there.
    public static func removal(of id: String, added: [Source]) -> Removal {
        guard let feed = added.first(where: { $0.id == id }), feed.kind == .sammyFeed else { return .removed }
        let siblings = added.filter { $0.kind == .sammyFeed && $0.accountID == feed.accountID }
        return siblings.count <= 1 ? .offerDisconnect : .removed
    }

    /// Ends the account's connection: revokes the stored token, then
    /// deletes the credential and every one of its feeds.
    public func disconnect(accountID: String) async {
        if let stored = try? credentials.load(SammySession.self, for: accountID) {
            for ended in stored.endedBy(nil) {
                await connector.revoke(ended)
            }
        }
        try? credentials.delete(for: accountID)
        let feeds = ((try? await sources.allSources()) ?? []).filter { $0.kind == .sammyFeed && $0.accountID == accountID }
        for feed in feeds {
            try? await sources.remove(sourceID: feed.id)
        }
    }

    // MARK: Ending

    private func discardUnsaved() async {
        offer = nil
        guard let session = unsaved else { return }
        unsaved = nil
        await discard(session)
    }

    /// Ends a session this flow never saved. What is stored for its
    /// account is what was there before, and stays. When the stored credential can't be read, nothing is revoked or
    /// deleted: the grant may be the very token already stored, and
    /// revoking it would end that connection on every device. The server
    /// ends a grant nothing uses after 90 days.
    private func discard(_ session: SammySession) async {
        let before: SammySession?
        do {
            before = try credentials.load(SammySession.self, for: session.accountID)
        } catch {
            return
        }
        await end(session, before: before)
    }

    /// Ends an unsaved `session`: revokes it, and puts the credential
    /// back as it was `before` this flow (deleting it when there was none),
    /// unless another device has stored a newer one since. A server that
    /// granted the very token already stored is left alone: revoking it
    /// would end the connection that was here before.
    private func end(_ session: SammySession, before: SammySession?) async {
        if before?.accessToken != session.accessToken {
            await connector.revoke(session)
        }
        // Unreadable now, the credential is left as it is rather than
        // overwritten or deleted on a guess.
        let stored: SammySession?
        do {
            stored = try credentials.load(SammySession.self, for: session.accountID)
        } catch {
            return
        }
        guard stored?.accessToken == session.accessToken || stored == nil else { return }
        if let before {
            try? credentials.save(before, for: session.accountID)
        } else {
            try? credentials.delete(for: session.accountID)
        }
    }

    private static func colored(_ source: Source) -> Source {
        var source = source
        source.colorIndex = Source.colorIndex(for: source.id)
        return source
    }
}
