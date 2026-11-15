import Foundation
import Observation
import InfluxKit

/// Signed-in Bluesky, Mastodon and Sammy accounts, their sources, and the
/// loop that keeps them fresh. An account is known from its sources in the store plus
/// its credentials in this device's keychain (a Sammy account, which has
/// no home timeline, from its credentials alone too), so nothing else
/// needs saving. Fetching and writing happen off the main actor in InfluxKit.
@MainActor
@Observable
final class Accounts {
    struct Account: Identifiable, Hashable {
        enum Service: Hashable { case mastodon, bluesky, sammy }

        /// `@user@instance` for Mastodon, the DID for Bluesky,
        /// `<user id>@<host>` for Sammy.
        let id: String
        let service: Service
        /// What the reader knows the account by: the Mastodon address, the
        /// Bluesky handle, or the Sammy account's name and server.
        var name: String
        /// The account's sources in the store, home first.
        var sources: [Source]
        /// False when the keychain has no credentials for it on this device,
        /// e.g. sources that arrived by sync before signing in here.
        var isSignedIn: Bool
        /// The service refused the account's stored sign-in outside a
        /// source's fetch: a Sammy account whose token was refused while
        /// sending a bookmark to its Inbox, which it may have no feed
        /// sources to show.
        var isRefused = false

        /// Whether the reader has to sign in again for this account to
        /// update: no sign-in on this device, a refused sign-in, or a
        /// source the service refused as signed out.
        func needsSignIn(_ states: [String: SourceFetchState]) -> Bool {
            !isSignedIn || isRefused || sources.contains { states[$0.id]?.problem == .signedOut }
        }

        /// When the account stopped updating, if its sources say: the
        /// earliest of their signed-out problems or, with no sign-in on this
        /// device, when one last fetched.
        func signedOutSince(_ states: [String: SourceFetchState]) -> Date? {
            let refused = sources.compactMap { states[$0.id].flatMap { $0.problem == .signedOut ? $0.problemSince : nil } }.min()
            if refused != nil || isSignedIn { return refused }
            return sources.compactMap { states[$0.id]?.lastSuccessAt }.max()
        }
    }

    private(set) var accounts: [Account] = []
    /// Accounts signing in again now, for their buttons to show it.
    private(set) var signingInAgain: Set<String> = []
    /// Why the last Sign in again of each account failed, until the next try.
    private(set) var signInAgainErrors: [String: String] = [:]

    @ObservationIgnored private let store: InfluxStore
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let mastodon: MastodonSignIn
    @ObservationIgnored private let bluesky: BlueskyOAuth
    /// One connector per Bluesky account for the app's lifetime, so two
    /// fetches never refresh the same session at once and spend its
    /// refresh token twice.
    @ObservationIgnored private var blueskyConnectors: [String: BlueskyConnector] = [:]
    @ObservationIgnored private let sammy: SammySignIn
    /// One connector per Sammy account, for the same reason: its refresh
    /// tokens rotate too.
    @ObservationIgnored private var sammyConnectors: [String: SammyFeedConnector] = [:]
    /// The last change asked for to each list, by source ID. The next one
    /// waits for it, so switching a list off and on again quickly lands in
    /// that order.
    @ObservationIgnored private var listChanges: [String: (accountID: String, task: Task<Void, Never>)] = [:]
    /// Accounts being signed out of. A list change for one of them does
    /// nothing, so no source is saved after sign-out has removed them.
    @ObservationIgnored private var signingOut: Set<String> = []
    /// For tests: runs as each list change starts, after the ones before it,
    /// so a test can hold one up.
    @ObservationIgnored var listChangeStarting: (@MainActor (_ list: Source, _ added: Bool) async -> Void)?
    @ObservationIgnored private let isSample: Bool
    /// What each account was last called, for accounts with no sign-in on
    /// this device; nil in sample runs.
    @ObservationIgnored private let names: AccountNames?
    /// Bluesky accounts whose handle is being looked up.
    @ObservationIgnored private var resolvingNames: Set<String> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// The fetch under way, which overlapping calls join.
    @ObservationIgnored private var pass: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    /// When each source is next fetched: as often as its service allows
    /// while the app is on screen, every 5 minutes otherwise
    /// (`RefreshCadence`, ADR 0036).
    @ObservationIgnored let timer = RefreshTimer()
    /// When the next pass over the accounts is due: their list, bookmarks
    /// and gaps back to the reader's place, which don't need the sources'
    /// own cadence.
    @ObservationIgnored private var nextPassAt = Date.distantPast
    /// Sources due between passes being fetched.
    @ObservationIgnored private var fetchingDue = false
    /// Each Mastodon account's home stream while the app is on screen
    /// (ADR 0037), by account ID, with a number telling one opening from
    /// the next.
    @ObservationIgnored private var streams: [String: (opening: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var streamOpenings = 0
    /// Accounts whose instance has no stream for Influx, or refused its
    /// token, until the app next comes on screen: they poll.
    @ObservationIgnored private var withoutStream: Set<String> = []
    /// How streams connect; nil in sample runs and tests, which never stream.
    @ObservationIgnored private let streamTransport: (any MastodonStreamTransport)?
    /// Each Sammy account's change stream while the app is on screen
    /// (ADR 0038), by account ID: its opening's number, the feed sources it
    /// was last told of, and whether it is live.
    @ObservationIgnored private var sammyStreams: [String: SammyStreamEntry] = [:]
    /// Sammy accounts whose server offers no change stream (403, 404),
    /// until the app next comes on screen or the account signs in again:
    /// they poll.
    @ObservationIgnored private var withoutSammyStream: Set<String> = []
    /// How change streams connect; nil in sample runs and tests.
    @ObservationIgnored private let eventTransport: (any EventStreamTransport)?
    /// Whether a pass over the accounts, or a fetch of their sources due
    /// between passes, is under way.
    var isRefreshing: Bool { pass != nil || fetchingDue }

    /// `credentials` is for tests; the app's own store is the keychain.
    init(store: InfluxStore, isSample: Bool, credentials: (any CredentialStore)? = nil) {
        self.store = store
        self.isSample = isSample
        let injected = credentials != nil
        names = isSample ? nil : AccountNames()
        #if canImport(Security)
        // Sign-ins sync through iCloud Keychain in the builds that sync
        //, so dev and test runs never touch the reader's.
        // Mastodon and Sammy sign-ins sync: their tokens never rotate
        // (ADR 0023). Bluesky refresh tokens do, and two devices sharing one
        // would end it for both, so each device signs those in itself.
        let credentials = credentials ?? (isSample ? InMemoryCredentialStore() : KeychainCredentialStore(
            synchronizes: Sync.containerID != nil, syncsAccount: { Accounts.syncsCredentials($0) }
        ))
        #else
        let credentials = credentials ?? InMemoryCredentialStore()
        #endif
        self.credentials = credentials
        streamTransport = isSample || injected ? nil : WebSocketStreamTransport()
        eventTransport = isSample || injected ? nil : EventStreamSessionTransport()
        mastodon = MastodonSignIn(crypto: .system, credentials: credentials)
        sammy = SammySignIn(crypto: .system, credentials: credentials)
        // Both Bluesky clients ask the signing service as an attested
        // install (ADR 0033). Sample runs and tests never sign in for real.
        let attestation = isSample || injected ? nil : CallerAttestation.app
        bluesky = .influx(http: URLSession.shared, crypto: .system, attestation: attestation)
    }

    /// Loads the accounts and starts refreshing them now, then each source
    /// as it falls due (`RefreshCadence`) and every account every 5 minutes.
    /// Calling it again does nothing.
    func start() {
        if isSample, AppSettings.sampleSignedOut, loop == nil {
            // The sample accounts have no credentials, so each shows as
            // signed out: for trying the alert.
            loop = Task { [weak self] in await self?.load() }
            return
        }
        guard loop == nil, !isSample else { return }
        // A rich post's media is read with its account's grants.
        MediaImages.findRichMedia { [weak self] accountID in await self?.sammyMedia(for: accountID) }
        loop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled, let accounts = self {
                await accounts.refreshDue()
            }
        }
    }

    /// Waits for the next source or pass to fall due, then runs the pass,
    /// or fetches the sources due.
    private func refreshDue() async {
        await timer.sleep(until: signedInSources, or: nextPassAt)
        if Date() >= nextPassAt {
            return await refresh(onlyDue: true)
        }
        var work: [(connector: any Connector, sources: [Source])] = []
        for account in accounts where account.isSignedIn {
            let due = timer.begin(account.sources)
            guard !due.isEmpty else { continue }
            guard let connector = await connectorOffMain(for: account) else {
                // Waits an interval, as a fetch would, rather than asking
                // the keychain again every second.
                timer.finish(Dictionary(uniqueKeysWithValues: due.map { ($0.id, .cancelled) }), begun: due)
                continue
            }
            work.append((connector, due))
        }
        guard !work.isEmpty else { return }
        fetchingDue = true
        defer { fetchingDue = false }
        let store = store
        let outcomes = await withTaskGroup(of: [String: Refresher.Outcome].self) { group in
            for (connector, sources) in work {
                group.addTask { (try? await Refresher(store: store).refreshAll(sources, with: connector)) ?? [:] }
            }
            var outcomes: [String: Refresher.Outcome] = [:]
            for await each in group {
                outcomes.merge(each) { $1 }
            }
            return outcomes
        }
        timer.finish(outcomes, begun: work.flatMap(\.sources))
    }

    private var signedInSources: [Source] {
        accounts.filter(\.isSignedIn).flatMap(\.sources)
    }

    /// Fetches every signed-in account's sources once. A call that arrives
    /// during a pass, e.g. after adding a list, gets one more pass when the
    /// current one ends, so the new source doesn't wait for the next interval.
    /// Every call returns once the passes end. `onlyDue` is the timed pass,
    /// which fetches only the sources due and leaves the rest to their
    /// cadence; a call that asks for every source wins.
    func refresh(onlyDue: Bool = false) async {
        guard !isSample else { return }
        if let pass {
            refreshAgain = refreshAgain || !onlyDue
            return await pass.value
        }
        let pass = Task { [weak self] in
            await self?.fetchAll(onlyDue: onlyDue)
            self?.pass = nil
        }
        self.pass = pass
        await pass.value
    }

    private func fetchAll(onlyDue: Bool) async {
        var onlyDue = onlyDue
        repeat {
            refreshAgain = false
            await load()
            timer.keep(only: Set(accounts.flatMap { $0.sources.map(\.id) }))
            let store = store
            // Back to the reader's place, so every post after it is here,
            // as it is on their other devices.
            let place = try? await store.earliestLastReadDate()
            for account in accounts where account.isSignedIn {
                guard let connector = connector(for: account) else { continue }
                let refresher = Refresher(store: store)
                if onlyDue {
                    let due = timer.begin(account.sources)
                    let outcomes = (try? await refresher.refreshAll(due, with: connector)) ?? [:]
                    timer.finish(outcomes, begun: due)
                } else {
                    timer.record((try? await refresher.refreshAll(account.sources, with: connector)) ?? [:])
                }
                if let place {
                    for source in account.sources {
                        _ = try? await refresher.fillGap(of: source, with: connector, backTo: place)
                    }
                }
                // After the timelines, so posts they hold aren't stored twice.
                if let home = account.sources.first(where: { Self.homeKinds.contains($0.kind) }) {
                    _ = try? await refresher.refreshBookmarks(of: home, with: connector)
                }
            }
            nextPassAt = Date().addingTimeInterval(RefreshCadence.slow * RefreshSchedule.randomJitter())
            onlyDue = false
        } while refreshAgain
    }

    /// The account's connector, with any keychain read off the main actor:
    /// a Mastodon connector is made from its stored session each time, and
    /// sources due between passes ask every minute.
    private func connectorOffMain(for account: Account) async -> (any Connector)? {
        guard account.service == .mastodon else { return connector(for: account) }
        let mastodon = mastodon, id = account.id
        return await Task.detached { (try? mastodon.stored(id)).map { MastodonConnector(session: $0) } }.value
    }

    // MARK: Streaming

    /// Says whether the reader can see the app: the poll cadence follows,
    /// and Mastodon home timelines stream only while it is so.
    func setOnScreen(_ onScreen: Bool) {
        timer.setOnScreen(onScreen)
        if onScreen {
            withoutStream.removeAll()
            withoutSammyStream.removeAll()
        }
        updateStreams()
    }

    /// Opens a home stream for each signed-in Mastodon account while the
    /// app is on screen, and closes every other: off screen, signed out,
    /// or gone.
    private func updateStreams() {
        var wanted: [String: Source] = [:]
        if timer.onScreen, streamTransport != nil {
            for account in accounts where account.service == .mastodon && account.isSignedIn && !withoutStream.contains(account.id) {
                if let home = account.sources.first(where: { $0.kind == .mastodonHome }) {
                    wanted[account.id] = home
                }
            }
        }
        for (id, stream) in streams where wanted[id] == nil {
            stream.task.cancel()
            streams[id] = nil
            if let home = accounts.first(where: { $0.id == id })?.sources.first(where: { $0.kind == .mastodonHome }) {
                timer.setStreaming(home.id, false)
            }
        }
        for (id, home) in wanted where streams[id] == nil {
            streamOpenings += 1
            streams[id] = (streamOpenings, openStream(accountID: id, home: home, opening: streamOpenings))
        }
        updateSammyStreams()
    }

    private func openStream(accountID: String, home: Source, opening: Int) -> Task<Void, Never> {
        guard let transport = streamTransport else { return Task {} }
        let mastodon = mastodon, store = store
        return Task { [weak self] in
            // A keychain read, off the main actor.
            let session = await Task.detached { try? mastodon.stored(accountID) }.value
            guard let session, !Task.isCancelled else {
                self?.streamEnded(accountID, home: home, opening: opening, .cancelled)
                return
            }
            let connector = MastodonConnector(session: session)
            let hooks = MastodonHomeStream.Hooks(
                closeGap: { [weak self] in await self?.closeGap(of: home, with: connector) ?? false },
                live: { [weak self] live in await self?.streamIsLive(accountID, home: home, opening: opening, live) },
                // As a refused fetch does: the account shows as signed out.
                refused: { try? await store.recordFailure(.unauthorized, sourceID: home.id) }
            )
            let ending = await MastodonHomeStream(connector: connector, home: home, store: store, transport: transport, hooks: hooks).run()
            self?.streamEnded(accountID, home: home, opening: opening, ending)
        }
    }

    /// One normal refresh of the home timeline as its stream connects, so
    /// the posts sent before it are here; true when it fetched.
    private func closeGap(of home: Source, with connector: MastodonConnector) async -> Bool {
        let outcome = try? await Refresher(store: store).refresh(home, with: connector)
        if let outcome { timer.record([home.id: outcome]) }
        if case .fetched? = outcome { return true }
        return false
    }

    /// The home timeline polls only as a safety net while its stream is
    /// live; a stream closed since says nothing.
    private func streamIsLive(_ accountID: String, home: Source, opening: Int, _ live: Bool) {
        guard streams[accountID]?.opening == opening else { return }
        timer.setStreaming(home.id, live)
    }

    private func streamEnded(_ accountID: String, home: Source, opening: Int, _ ending: MastodonHomeStream.Ending) {
        guard streams[accountID]?.opening == opening else { return }
        timer.setStreaming(home.id, false)
        streams[accountID] = nil
        if ending == .unavailable || ending == .refused {
            withoutStream.insert(accountID)
        }
    }

    // MARK: Sammy change streams

    struct SammyStreamEntry {
        var opening: Int
        var stream: SammyFeedEventStream
        var task: Task<Void, Never>
        /// The account's feed sources, as the stream was last told.
        var sources: [Source]
        var isLive = false
        /// The last change of sources sent to the stream; the next waits
        /// for it, so they land in order.
        var telling: Task<Void, Never>?
    }

    /// Opens a change stream for each signed-in Sammy account with a feed
    /// of posts while the app is on screen (one per account), tells each
    /// open one of its account's feeds as they change, and closes every
    /// other: off screen, signed out, refused, or no feed of posts left.
    private func updateSammyStreams() {
        var wanted: [String: [Source]] = [:]
        if timer.onScreen, eventTransport != nil {
            for account in accounts where account.service == .sammy && account.isSignedIn && !account.isRefused
                && !withoutSammyStream.contains(account.id) {
                let feeds = account.sources.filter { $0.kind == .sammyFeed }
                if feeds.contains(where: { $0.itemKind == .post }) { wanted[account.id] = feeds }
            }
        }
        for (id, entry) in sammyStreams where wanted[id] == nil {
            entry.task.cancel()
            sammyStreams[id] = nil
            for source in entry.sources { timer.setStreaming(source.id, false) }
        }
        for (id, feeds) in wanted {
            if var entry = sammyStreams[id] {
                guard entry.sources != feeds else { continue }
                let stream = entry.stream, previous = entry.telling
                entry.telling = Task {
                    await previous?.value
                    await stream.setSources(feeds)
                }
                for source in entry.sources where !feeds.contains(source) { timer.setStreaming(source.id, false) }
                entry.sources = feeds
                sammyStreams[id] = entry
                if entry.isLive { markSammyStreaming(feeds, true) }
            } else if let connector = sammyConnector(for: id), let transport = eventTransport {
                streamOpenings += 1
                sammyStreams[id] = openSammyStream(connector: connector, feeds: feeds, transport: transport, opening: streamOpenings)
            }
        }
    }

    private func openSammyStream(connector: SammyFeedConnector, feeds: [Source], transport: any EventStreamTransport,
                                 opening: Int) -> SammyStreamEntry {
        let accountID = connector.accountID
        let hooks = SammyFeedEventStream.Hooks(
            read: { [weak self] ids in await self?.readHinted(ids, accountID: accountID, opening: opening) ?? [:] },
            live: { [weak self] live in await self?.sammyStreamIsLive(accountID, opening: opening, live) },
            // As a refused bookmark does: the account shows as signed out
            // until a different session is stored for it.
            refused: { [weak self] token in await self?.markSammySignedOut(accountID, refusedToken: token) }
        )
        let stream = SammyFeedEventStream(account: connector.account, sources: feeds, transport: transport, hooks: hooks)
        let task = Task { [weak self] in
            let ending = await stream.run()
            self?.sammyStreamEnded(accountID, opening: opening, ending)
        }
        return SammyStreamEntry(opening: opening, stream: stream, task: task, sources: feeds)
    }

    /// The conditional reads a change stream asks for: a normal refresh of
    /// each of the account's sources among `ids`, recorded with the timer
    /// as any fetch is. A stream closed since reads nothing.
    private func readHinted(_ ids: [String], accountID: String, opening: Int) async -> [String: Refresher.Outcome] {
        guard sammyStreams[accountID]?.opening == opening,
              let account = accounts.first(where: { $0.id == accountID && $0.isSignedIn }),
              let connector = sammyConnector(for: accountID) else { return [:] }
        let sources = account.sources.filter { ids.contains($0.id) }
        guard !sources.isEmpty else { return [:] }
        let outcomes = (try? await Refresher(store: store).refreshAll(sources, with: connector)) ?? [:]
        timer.record(outcomes)
        return outcomes
    }

    /// While a change stream is live its account's feeds of posts poll
    /// only as a safety net; a stream closed since says nothing.
    private func sammyStreamIsLive(_ accountID: String, opening: Int, _ live: Bool) {
        guard var entry = sammyStreams[accountID], entry.opening == opening else { return }
        entry.isLive = live
        sammyStreams[accountID] = entry
        markSammyStreaming(entry.sources, live)
    }

    private func markSammyStreaming(_ feeds: [Source], _ live: Bool) {
        for source in feeds where source.itemKind == .post { timer.setStreaming(source.id, live) }
    }

    private func sammyStreamEnded(_ accountID: String, opening: Int, _ ending: SammyFeedEventStream.Ending) {
        guard let entry = sammyStreams[accountID], entry.opening == opening else { return }
        sammyStreams[accountID] = nil
        for source in entry.sources { timer.setStreaming(source.id, false) }
        // A refused token shows as signed out (`markSammySignedOut`), which
        // keeps the stream closed until the account signs in again.
        if ending == .unavailable { withoutSammyStream.insert(accountID) }
    }

    /// A new session for the Sammy account: its stream is tried again.
    private func sammySessionReplaced(_ accountID: String) {
        withoutSammyStream.remove(accountID)
        updateSammyStreams()
    }

    // MARK: Mastodon

    /// Where a sign-in has got to, for the sheet to say what it's waiting on.
    enum SignInStep: Hashable {
        /// Registering Influx on the server, before the browser opens.
        case contactingServer
        /// The sign-in page is open in the browser.
        case inBrowser
        /// The browser came back; trading the code for a token.
        case finishing
    }

    /// Signs in on the instance the reader named, through the browser, and
    /// adds the account's home timeline. Returns once the account is saved;
    /// its first fetch carries on in the background. Throws
    /// `WebSignIn.Cancelled` when the reader closes the browser, and
    /// `CancellationError` when the task is cancelled first.
    @discardableResult
    func signInToMastodon(instance: String, expecting: String? = nil, step: (SignInStep) -> Void = { _ in }) async throws -> String {
        // The pending sign-in lives only in memory, for the length of the
        // browser session.
        step(.contactingServer)
        let pending = try await mastodon.begin(instance: instance)
        try Task.checkCancellation()
        step(.inBrowser)
        let callback = try await WebSignIn.open(pending.authorizationURL, callback: .influx)
        try Task.checkCancellation()
        step(.finishing)
        let session = try await mastodon.complete(pending, callback: callback)
        // A new token: its stream is tried again.
        withoutStream.remove(session.accountID)
        if let expecting {
            guard session.accountID == expecting else {
                // Not an account here: forget it. One that is keeps the new token.
                if !accounts.contains(where: { $0.id == session.accountID }) {
                    try? await mastodon.signOut(session)
                }
                throw SignInAgainError.differentAccount(session.accountID)
            }
            return session.accountID
        }
        let home = MastodonMapper.homeSource(accountID: session.accountID, colorIndex: 0)
        try await save([home])
        refreshSoon()
        return session.accountID
    }

    /// Starts a fetch without waiting for it. Signing in must not wait on
    /// a pass over every account, which can take a while and join a pass
    /// already under way.
    private func refreshSoon() {
        Task { [weak self] in await self?.refresh() }
    }

    // MARK: Bluesky

    /// Signs in to the account with this handle (or DID), through the
    /// browser, and adds its Following feed. The callback is the universal
    /// link on influx.bespokebits.dev, since Bluesky only signs in
    /// confidential clients with a web redirect. (Sessions from before the
    /// rename keep the flux.bespokebits.dev client, which needs no callback
    /// to refresh.) Returns and throws as `signInToMastodon`.
    func signInToBluesky(handle: String, expecting: String? = nil) async throws {
        let handle = handle.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        let pending = try await bluesky.begin(account: handle)
        try Task.checkCancellation()
        let callback = try await WebSignIn.open(pending.authorizationURL, callback: .https(host: "influx.bespokebits.dev", path: "/oauth/callback"))
        try Task.checkCancellation()
        let session = try await bluesky.complete(pending, callback: callback)
        if let expecting, session.accountID != expecting {
            // Nothing is stored; the new session is revoked.
            try? await bluesky.revoke(session, nonce: nil)
            throw SignInAgainError.differentAccount(session.identity.handle.map { "@" + $0 } ?? session.accountID)
        }
        try credentials.save(session, for: session.accountID)
        // Signing in again replaces the session, so the old connector goes.
        blueskyConnectors[session.accountID] = nil
        // Signing an account in again keeps the sources it has.
        guard expecting == nil else { return }
        let following = Source(
            id: BlueskyConnector.followingSourceID(did: session.accountID), kind: .blueskyFollowing,
            accountID: session.accountID, title: "Following", colorIndex: 0
        )
        try await save([following])
        refreshSoon()
    }

    // MARK: Sammy

    /// A new connection to a Sammy account (`SammyConnectFlow`), over this
    /// device's credentials and the store.
    func makeSammyFlow() -> SammyConnectFlow {
        SammyConnectFlow(connector: sammy, credentials: credentials, sources: store)
    }

    /// Signs in on the Sammy server the reader named, through the browser:
    /// normalises the address, discovers the server, opens its approval
    /// page and finishes the sign-in. Returns the account's feeds to choose
    /// from without saving anything; the caller saves (`saveSammy`) or
    /// cancels the flow. Closing the browser cancels the flow. Once the
    /// browser has come back, cancelling the caller no longer stops the
    /// exchange: the flow revokes what it gets if it was cancelled.
    func signInToSammy(_ flow: SammyConnectFlow, server: String, scope: String = SammyOAuth.scope,
                       step: (SignInStep) -> Void = { _ in }) async throws -> SammyConnectFlow.Offer {
        step(.contactingServer)
        let page = try await flow.begin(server: server, scope: scope)
        try Task.checkCancellation()
        step(.inBrowser)
        let callback: URL
        do {
            callback = try await WebSignIn.open(page, callback: .scheme(of: SammyOAuth.redirect))
            try Task.checkCancellation()
        } catch {
            await flow.cancel()
            throw error
        }
        step(.finishing)
        return try await Task { try await flow.complete(callbackURL: callback) }.value
    }

    /// Saves the feeds the reader ticked and the account's sign-in, and
    /// returns the account's ID. A connector already made for the account
    /// takes up the new session.
    @discardableResult
    func saveSammy(_ flow: SammyConnectFlow, selected: Set<String>) async throws -> String {
        let session = try await flow.save(selected: selected)
        if let connector = sammyConnectors[session.accountID] {
            await connector.account.adopt(session)
        }
        withoutSammyStream.remove(session.accountID)
        await load()
        refreshSoon()
        return session.accountID
    }

    /// Signs the Sammy account `accountID` in again in place, keeping its
    /// feeds as they are.
    /// With Bookmarks to Sammy Inbox on, it asks for `inbox:add` again too.
    private func signInToSammyAgain(server: String, accountID: String) async throws {
        let flow = makeSammyFlow()
        let addsToInbox = (try? await store.isSammyInboxOn(accountID)) == true
        _ = try await signInToSammy(flow, server: server, scope: addsToInbox ? SammyOAuth.inboxScopes : SammyOAuth.scope)
        let session: SammySession
        do {
            session = try await flow.saveSignInAgain(expecting: accountID)
        } catch SammyConnectFlow.FlowError.differentAccount(let other) {
            throw SignInAgainError.differentAccount(other)
        }
        await tookUpSammySessionSignedInAgain(session, askedForInbox: addsToInbox)
    }

    /// After signing a Sammy account in again: the session is stored
    /// whatever it grants, so its feeds come back. But if Bookmarks to
    /// Sammy Inbox asked for `inbox:add` too and the reader unticked it,
    /// the switch goes off (dropping what waits, as switching off does)
    /// and the account screen says why, rather than leaving it on with
    /// bookmarks waiting for a permission that isn't coming.
    func tookUpSammySessionSignedInAgain(_ session: SammySession, askedForInbox: Bool) async {
        if let connector = sammyConnectors[session.accountID] {
            await connector.account.adopt(session)
        }
        if askedForInbox, !session.addsToInbox {
            try? await store.setSammyInbox(session.accountID, on: false)
            sammyInboxScopeLost?(session.accountID)
        }
        sammySessionChanged?(session.accountID)
        sammySessionReplaced(session.accountID)
    }

    /// Told the account's ID when signing it in again left out `inbox:add`
    /// and Bookmarks to Sammy Inbox went off for it.
    @ObservationIgnored var sammyInboxScopeLost: (@MainActor (String) -> Void)?

    // MARK: Bookmarks to Sammy Inbox

    /// Told the account's ID whenever this device takes up a new Sammy
    /// session (signed in again, or connected again for the Inbox), so
    /// bookmarks waiting for one go.
    @ObservationIgnored var sammySessionChanged: (@MainActor (String) -> Void)?

    /// The session stored for the Sammy account `accountID`, read off the
    /// main actor (a keychain read is a round trip to securityd).
    func sammySession(_ accountID: String) async -> SammySession? {
        let sammy = sammy
        return await Task.detached { try? sammy.stored(accountID) }.value
    }

    /// The account bookmarks go to Sammy's Inbox through: its connector's,
    /// so it shares the session the feeds use. Nil when it has no session
    /// on this device.
    func sammyInboxAccount(_ accountID: String) -> SammyAccount? {
        sammyConnector(for: accountID)?.account
    }

    /// Connects the Sammy account again asking for `feeds:read inbox:add`,
    /// through the browser, and stores the new session only when it is the
    /// same account and holds both (`SammyConnectFlow.saveUpgrade`); its
    /// feeds stay as they are. The old token is kept until Sammy confirms
    /// the replacement, which this sends once the session is stored and
    /// again at launch until it lands.
    func connectSammyForInbox(_ account: Account, step: (SignInStep) -> Void = { _ in }) async throws {
        let flow = makeSammyFlow()
        _ = try await signInToSammy(flow, server: sammyServer(for: account), scope: SammyOAuth.inboxScopes, step: step)
        let session = try await flow.saveUpgrade(expecting: account.id)
        if let connector = sammyConnectors[session.accountID] {
            await connector.account.adopt(session, revokingReplaced: false)
        }
        sammySessionChanged?(session.accountID)
        sammySessionReplaced(session.accountID)
        let sammy = sammy
        Task.detached { await sammy.confirmReplacement(for: session.accountID) }
    }

    /// Confirms every replaced Sammy token not yet confirmed: an upgrade
    /// whose confirmation was lost, on this device or another.
    func confirmSammyReplacements() async {
        let sammy = sammy
        await Task.detached {
            for accountID in (try? sammy.accountIDs()) ?? [] {
                await sammy.confirmReplacement(for: accountID)
            }
        }.value
    }

    /// Sammy refused the account's token while sending a bookmark (401):
    /// the account needs signing in again, so the reader is asked to, as
    /// when a feed is refused. That holds for the account itself, not only
    /// through its feed sources, which it may have none of; it lasts until
    /// a different session is stored for it (signed in again, here or on
    /// another device). The refusal is kept in the store, by a hash of the
    /// token, so it survives a relaunch. `refusedToken` is the token the
    /// refused request carried, not the one stored now: a session another
    /// device stored since must not be taken for the refused one.
    func markSammySignedOut(_ accountID: String, refusedToken: String?) async {
        let sources = ((try? await store.sources()) ?? []).filter { $0.kind == .sammyFeed && $0.accountID == accountID }
        for source in sources {
            try? await store.recordFailure(.unauthorized, sourceID: source.id)
        }
        guard let refusedToken else { return }
        try? await store.recordSammyRefusal(accountID: accountID, token: refusedToken)
        await load()
    }

    /// The Sammy accounts whose stored token is still the one Sammy
    /// refused; the store forgets those that have a different session
    /// since. One whose credential can't be read is left as it was.
    private func stillRefusedSammyAccounts() async -> Set<String> {
        guard let refused = try? await store.sammyRefusalAccounts(), !refused.isEmpty else { return [] }
        let credentials = credentials
        let tokens = await Task.detached { () -> [String: String?] in
            var tokens: [String: String?] = [:]
            for id in refused {
                let data: Data?
                do { data = try credentials.data(for: id) } catch { continue }
                tokens[id] = .some(data.flatMap { try? JSONDecoder().decode(SammySession.self, from: $0) }?.accessToken)
            }
            return tokens
        }.value
        return (try? await store.stillRefusedSammyAccounts(storedTokens: tokens)) ?? []
    }

    /// Whether switching off `feed` is switching off its account's last
    /// feed among `added`, which offers to disconnect instead.
    static func offersDisconnect(removing feed: Source, added: [Source]) -> Bool {
        SammyConnectFlow.removal(of: feed.id, added: added) == .offerDisconnect
    }

    /// The lists (Mastodon), saved feeds (Bluesky) or feeds (Sammy) the
    /// account offers as sources, and whether each is added.
    func lists(for account: Account) async throws -> [(source: Source, isAdded: Bool)] {
        guard let connector = connector(for: account) else { return [] }
        let added = Set(account.sources.map(\.id))
        return try await connector.availableSources()
            .filter { !Self.homeKinds.contains($0.kind) }
            .map { ($0, added.contains($0.id)) }
    }

    /// Adds or removes `list`, after any change to it asked for before,
    /// so the last one the reader made is the one that stays.
    func setList(_ list: Source, added: Bool) async {
        let accountID = list.accountID ?? ""
        guard !signingOut.contains(accountID) else { return }
        let previous = listChanges[list.id]?.task
        let change = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await listChangeStarting?(list, added)
            // Sign-out may have started while this one waited.
            guard !signingOut.contains(accountID) else { return }
            if added {
                try? await save([list])
            } else {
                try? await store.delete(sourceID: list.id)
                await load()
            }
        }
        listChanges[list.id] = (accountID, change)
        await change.value
        if listChanges[list.id]?.task == change { listChanges[list.id] = nil }
        if added, !signingOut.contains(accountID) { await refresh() }
    }

    // MARK: Signing in again

    /// Signs `account` in again in place, through the browser, with the
    /// account already named: its sources, bookmarks and place stay. Once
    /// signed in, its sources lose their signed-out state at once and are
    /// fetched, which fills the gap back to the reader's place. A failure
    /// is kept in `signInAgainErrors` for the alert to show.
    func signInAgain(_ account: Account) async {
        guard !signingInAgain.contains(account.id) else { return }
        signingInAgain.insert(account.id)
        signInAgainErrors[account.id] = nil
        defer { signingInAgain.remove(account.id) }
        do {
            switch account.service {
            case .mastodon:
                try await signInToMastodon(instance: account.id, expecting: account.id)
            case .bluesky:
                // The DID, which never changes; a handle may have moved
                // to another account since.
                try await signInToBluesky(handle: account.id, expecting: account.id)
            case .sammy:
                try await signInToSammyAgain(server: sammyServer(for: account), accountID: account.id)
            }
            let sourceIDs = account.sources.map(\.id)
            try? await store.clearSignedOut(sourceIDs: sourceIDs)
            await load()
            refreshSoon()
        } catch is WebSignIn.Cancelled, is CancellationError {
            // The reader closed the browser; the alert stays.
        } catch {
            signInAgainErrors[account.id] = signInAgainMessage(for: error, account: account)
        }
    }

    /// Where a Sammy account signs in: its stored server, else the server
    /// its feeds come from, else the host in its ID.
    private func sammyServer(for account: Account) -> String {
        if let session = try? sammy.stored(account.id) { return session.issuer.absoluteString }
        for source in account.sources {
            guard let url = source.url.flatMap(URL.init(string:)), let scheme = url.scheme, let host = url.host() else { continue }
            return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
        }
        return String(account.id.split(separator: "@").last ?? "")
    }

    /// Mastodon accounts are `@user@instance`; Bluesky's are DIDs and
    /// Sammy's `<subject>@<host>`.
    nonisolated static func isMastodonID(_ id: String) -> Bool { id.hasPrefix("@") }

    /// Whether the account's sign-in goes in iCloud Keychain: Mastodon's
    /// and Sammy's, whose tokens never rotate, but not Bluesky's (ADR 0017).
    nonisolated static func syncsCredentials(_ id: String) -> Bool {
        isMastodonID(id) || (!id.hasPrefix("did:") && id.contains("@"))
    }

    // MARK: Accounts

    /// Removes the account's sources and items, forgets its credentials on
    /// this device, and asks the service to revoke them. The sources are
    /// the store's, not `account`'s, which may have been read before a feed
    /// was switched on.
    func signOut(_ account: Account) async {
        // No list change may start now, and the ones under way finish
        // first, so none saves a source after the ones read here are gone.
        signingOut.insert(account.id)
        defer { signingOut.remove(account.id) }
        for (_, change) in listChanges where change.accountID == account.id {
            await change.task.value
        }
        if account.service == .sammy {
            // Revoked first, then the credential and the feeds go
            // (`SammyConnectFlow.disconnect`). A connector stops its
            // fetches as it signs out.
            if let connector = sammyConnectors.removeValue(forKey: account.id) {
                await connector.account.signOut()
            }
            await makeSammyFlow().disconnect(accountID: account.id)
            // Nothing is left to send with; the switch goes off everywhere.
            try? await store.setSammyInbox(account.id, on: false)
            try? await store.clearSammyRefusal(accountID: account.id)
            await load()
            return
        }
        let stored = (try? await store.sources())?.filter { $0.accountID == account.id && Self.services[$0.kind] == account.service }
        for source in stored ?? account.sources {
            try? await store.delete(sourceID: source.id)
        }
        switch account.service {
        case .mastodon:
            if let session = try? mastodon.stored(account.id) {
                try? await mastodon.signOut(session)
            } else {
                try? credentials.delete(for: account.id)
            }
        case .bluesky:
            if let session = blueskyConnector(for: account.id)?.account {
                await session.signOut()
            } else {
                try? credentials.delete(for: account.id)
            }
            blueskyConnectors[account.id] = nil
        case .sammy:
            break
        }
        await load()
    }

    /// The connector for the account `sourceID` belongs to, if it is
    /// signed in on this device.
    func connector(forSource sourceID: String) -> (any Connector)? {
        guard let account = accounts.first(where: { $0.isSignedIn && $0.sources.contains { $0.id == sourceID } }) else { return nil }
        return connector(for: account)
    }

    private func connector(for account: Account) -> (any Connector)? {
        switch account.service {
        case .mastodon:
            (try? mastodon.stored(account.id)).map { MastodonConnector(session: $0) }
        case .bluesky:
            blueskyConnector(for: account.id)
        case .sammy:
            sammyConnector(for: account.id)
        }
    }

    /// The media grants of the Sammy account `accountID`, when it is signed
    /// in on this device: its connector's, so they share its session.
    func sammyMedia(for accountID: String) -> SammyMediaGrants? {
        sammyConnector(for: accountID)?.media
    }

    private func sammyConnector(for accountID: String) -> SammyFeedConnector? {
        if let connector = sammyConnectors[accountID] { return connector }
        guard let account = try? sammy.account(accountID) else { return nil }
        let connector = SammyFeedConnector(account: account)
        sammyConnectors[accountID] = connector
        return connector
    }

    private func blueskyConnector(for did: String) -> BlueskyConnector? {
        if let connector = blueskyConnectors[did] { return connector }
        guard let stored = try? BlueskyAccount.stored(did, oauth: bluesky, credentials: credentials) else { return nil }
        let connector = BlueskyConnector(account: stored)
        blueskyConnectors[did] = connector
        return connector
    }

    /// Each account's main timeline, listed first.
    private static let homeKinds: Set<Source.Kind> = [.mastodonHome, .blueskyFollowing]
    private static let services: [Source.Kind: Account.Service] = [
        .mastodonHome: .mastodon, .mastodonList: .mastodon,
        .blueskyFollowing: .bluesky, .blueskyFeed: .bluesky,
        .sammyFeed: .sammy,
    ]

    /// Sources keep a colour derived from their ID, as RSS sources do.
    private func save(_ sources: [Source]) async throws {
        try await store.save(sources: sources.map {
            var source = $0
            source.colorIndex = Source.colorIndex(for: source.id)
            return source
        })
        await load()
    }

    /// Reads the accounts from the store and the keychain.
    func load() async {
        let sources = (try? await store.sources()) ?? []
        var byAccount: [String: (service: Account.Service, sources: [Source])] = [:]
        for source in sources {
            guard let service = Self.services[source.kind], let accountID = source.accountID else { continue }
            byAccount[accountID, default: (service, [])].sources.append(source)
        }
        // Each keychain read is a blocking round trip to securityd, so they
        // happen off the main actor, once each.
        let credentials = credentials
        let services = byAccount.mapValues(\.service)
        let stored = await Task.detached { Self.readCredentials(credentials, services: services) }.value
        // A Sammy account with no feeds switched on is still an account.
        for accountID in stored.sammy where byAccount[accountID] == nil {
            byAccount[accountID] = (.sammy, [])
        }
        func order(_ source: Source) -> (Int, String) { (Self.homeKinds.contains(source.kind) ? 0 : 1, source.title) }
        // Bluesky and Sammy sign in on each device, so an account can be
        // here with no credentials to name it: it keeps the name it had.
        names?.remember(stored.names)
        let known = (names?.all() ?? [:]).merging(stored.names) { $1 }
        // A keychain read that failed says nothing about the sign-in, so
        // such an account keeps what the last load found rather than
        // flashing the sign-in bar.
        let before = Dictionary(accounts.map { ($0.id, $0.isSignedIn) }) { first, _ in first }
        let refused = await stillRefusedSammyAccounts()
        accounts = byAccount.map { id, entry in
            Account(
                id: id, service: entry.service, name: known[id] ?? id,
                sources: entry.sources.sorted { order($0) < order($1) },
                isSignedIn: stored.signedIn.contains(id) || (stored.unreadable.contains(id) && before[id] ?? true),
                isRefused: refused.contains(id)
            )
        }
        .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        lookUpMissingHandles()
        updateStreams()
    }

    /// Names each Bluesky account still known only by its DID by the handle
    /// its DID document gives, which needs no sign-in. One that can't be
    /// found is tried again at the next load.
    private func lookUpMissingHandles() {
        guard let names else { return }
        let bluesky = bluesky
        for account in accounts where account.service == .bluesky && account.name == account.id && !resolvingNames.contains(account.id) {
            let did = account.id
            resolvingNames.insert(did)
            Task { [weak self] in
                let handle = await bluesky.handle(forDID: did)
                guard let self else { return }
                resolvingNames.remove(did)
                guard let handle else { return }
                let name = "@" + handle
                names.remember([did: name])
                if let index = accounts.firstIndex(where: { $0.id == did && $0.name == did }) {
                    accounts[index].name = name
                }
            }
        }
    }

    /// What the keychain says about the accounts: which have credentials,
    /// what to call them, and the Sammy accounts it holds, `services` (from
    /// their sources) or not. Each credential is read once. One no source
    /// names is only read if it could be a Sammy account's, so not a
    /// Mastodon address (`@user@instance`) or a Bluesky DID.
    nonisolated private static func readCredentials(
        _ credentials: any CredentialStore, services: [String: Account.Service]
    ) -> (signedIn: Set<String>, unreadable: Set<String>, names: [String: String], sammy: [String]) {
        var signedIn: Set<String> = []
        var unreadable: Set<String> = []
        var names: [String: String] = [:]
        var sammy: [String] = []
        let listed = (try? credentials.accounts()) ?? []
        for id in Set(listed).union(services.keys) {
            let service = services[id]
            guard service != nil || (!id.hasPrefix("@") && !id.hasPrefix("did:") && id.contains("@")) else { continue }
            let data: Data
            do {
                guard let found = try credentials.data(for: id) else { continue }
                data = found
            } catch {
                AuthLog.unreadable(account: id, error: error)
                unreadable.insert(id)
                continue
            }
            switch service {
            case .bluesky:
                if let handle = (try? JSONDecoder().decode(BlueskySession.self, from: data))?.identity.handle {
                    names[id] = "@" + handle
                }
            case .sammy, nil:
                let session = try? JSONDecoder().decode(SammySession.self, from: data)
                // Credentials no source names are an account only if they
                // are a Sammy session.
                if service == nil {
                    guard session != nil else { continue }
                    sammy.append(id)
                }
                // The server says only a per-client subject, not a name.
                if let session {
                    names[id] = session.displayName
                }
            case .mastodon:
                break
            }
            signedIn.insert(id)
        }
        return (signedIn, unreadable, names, sammy.sorted())
    }
}

/// What the sign-in sheet says when the signing service refuses this build
/// (ADR 0033): it is too old, or, on a Mac, its App Attest key doesn't
/// carry the full-security policy, as when System Integrity Protection is
/// off. A new key wouldn't help, so the reader is told what would.
#if os(macOS)
let appNotAcceptedMessage = "This version of Influx can't sign in to Bluesky. Update the app, and check that System Integrity Protection is on."
#else
let appNotAcceptedMessage = "This version of Influx can't sign in to Bluesky. Update the app, then try again."
#endif

/// What the sign-in sheet says when signing in fails.
func signInMessage(for error: any Error) -> String {
    switch error {
    case BlueskyError.identityNotFound:
        "Couldn't find that Bluesky account. Check the handle, e.g. name.bsky.social."
    case BlueskyError.rateLimited:
        "Bluesky sign-in is busy. Try again in a few minutes."
    case BlueskyError.oauth("access_denied"):
        "Bluesky didn't allow the sign-in."
    case BlueskyError.differentAccount:
        "That's a different Bluesky account from the one you named. Sign in as that account, or add the other one."
    case BlueskyError.appNotAccepted:
        appNotAcceptedMessage
    case BlueskyError.callbackMismatch, BlueskyError.oauth:
        "The sign-in didn't finish. Try again."
    case BlueskyError.badMetadata, BlueskyError.http, BlueskyError.signInRequired:
        "Bluesky didn't accept the sign-in."
    case let error as URLError where error.code == .notConnectedToInternet || error.code == .timedOut || error.code == .cannotFindHost:
        "Couldn't reach the server. Check your connection."
    case is WebSignIn.CouldNotStart:
        "The sign-in window couldn't open. Try again."
    case MastodonSignInError.notAnInstance:
        "That doesn't look like a Mastodon server. Try an address like mastodon.social."
    case MastodonSignInError.callback(.denied):
        "The server didn't allow the sign-in."
    case MastodonSignInError.callback:
        "The sign-in didn't finish. Try again."
    case MastodonSignInError.timedOut:
        "That server didn't answer. Check the address, or try again in a moment."
    case MastodonSignInError.failed(.offline):
        "Couldn't reach that server. Check the address and your connection."
    case MastodonSignInError.failed(.rateLimited):
        "The server is busy. Try again in a few minutes."
    case MastodonSignInError.failed(.unauthorized):
        "That server didn't accept the sign-in. Try again."
    case MastodonSignInError.failed(let error):
        "That server didn't accept the sign-in (\(error))."
    case MastodonSignInError.couldNotStore(let detail):
        "Signed in, but Influx couldn't save the sign-in on this device (\(detail))."
    case SammySignInError.notAnAddress, SammySignInError.notASammyServer:
        "That doesn't look like a Sammy server. Check the address and try again."
    case SammySignInError.callback(.denied):
        "The server didn't allow the sign-in."
    case SammySignInError.callback:
        "The sign-in didn't finish. Try again."
    case SammySignInError.timedOut:
        "That server didn't answer. Check the address, or try again in a moment."
    case SammySignInError.failed(.offline):
        "Couldn't reach that server. Check the address and your connection."
    case SammySignInError.failed(.rateLimited):
        "The server is busy. Try again in a few minutes."
    case SammySignInError.failed(.unauthorized):
        "That server didn't accept the sign-in. Try again."
    case SammySignInError.failed(let error):
        "That server didn't accept the sign-in (\(error))."
    case SammySignInError.couldNotStore(let detail):
        "Signed in, but Influx couldn't save the sign-in on this device (\(detail))."
    default:
        "Couldn't sign in (\(error))."
    }
}

/// Why Sign in again didn't sign the account in.
enum SignInAgainError: Error, Hashable {
    /// The browser signed in to another account, named here.
    case differentAccount(String)
}

/// What the alert says when Sign in again fails.
func signInAgainMessage(for error: any Error, account: Accounts.Account) -> String {
    if case SignInAgainError.differentAccount(let other) = error {
        return "That's \(other). Sign in as \(account.name) to fix this account."
    }
    if case BlueskyError.differentAccount = error {
        return "That's a different account. Sign in as \(account.name) to fix this account."
    }
    return signInMessage(for: error)
}

/// What each account was last called, kept on this device. Bluesky and
/// Sammy sign in on each device, so an account that arrived by sync, or
/// whose sign-in has gone, has no credentials to read its name from.
struct AccountNames {
    var defaults: UserDefaults = .standard
    static let key = "InfluxAccountNames"

    func all() -> [String: String] {
        defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
    }

    func remember(_ names: [String: String]) {
        var all = all()
        let before = all
        all.merge(names) { $1 }
        if all != before { defaults.set(all, forKey: Self.key) }
    }
}
