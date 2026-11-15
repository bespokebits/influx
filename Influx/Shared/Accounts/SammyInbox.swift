import Foundation
import Network
import Observation
import os
import InfluxKit
#if os(macOS)
import AppKit
#endif

/// Bookmarks to Sammy Inbox in the app: the switch on each Sammy account's
/// screen, connecting again for `inbox:add` when it is switched on, and
/// the outbox (`SammyInboxOutbox`, in InfluxKit) that sends the bookmarks
/// the reader makes on this device. It sends at once, then at launch, on
/// coming to the foreground, when the network returns, and when a backoff
/// is up. Idle on sample and stand-in stores.
@MainActor
@Observable
final class SammyInbox {
    /// Accounts connecting again for `inbox:add` now.
    private(set) var connecting: Set<String> = []
    /// Where each account's connecting has got to, for the screen to say.
    private(set) var steps: [String: Accounts.SignInStep] = [:]
    /// Why switching on didn't, per account, until the next try.
    private(set) var errors: [String: String] = [:]

    @ObservationIgnored private let store: InfluxStore
    @ObservationIgnored private let accounts: Accounts
    @ObservationIgnored private let isSample: Bool
    @ObservationIgnored private let outbox: SammyInboxOutbox
    @ObservationIgnored private var started = false
    /// Whether the network was there at the last change, nil before one.
    @ObservationIgnored private var networkSatisfied: Bool?
    /// The pass waiting for the next backoff to be up.
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// When `timer` runs its pass.
    @ObservationIgnored private var scheduledAt: Date?
    @ObservationIgnored private var pass: Task<Void, Never>?
    @ObservationIgnored private var passAgain = false
    @ObservationIgnored private var path: NWPathMonitor?
    /// Each account's connecting for `inbox:add`, for Cancel to stop.
    @ObservationIgnored private var connections: [String: Task<Void, any Error>] = [:]
    #if os(macOS)
    @ObservationIgnored private var becameActive: (any NSObjectProtocol)?
    #endif
    private static let log = Logger(subsystem: "dev.bespokebits.influx", category: "SammyInbox")

    init(store: InfluxStore, accounts: Accounts, isSample: Bool) {
        self.store = store
        self.accounts = accounts
        self.isSample = isSample
        let relay = RetryRelay()
        outbox = SammyInboxOutbox(
            store: store,
            account: { [weak accounts] accountID in await accounts?.sammyInboxAccount(accountID) },
            signedOut: { [weak accounts] accountID, token in await accounts?.markSammySignedOut(accountID, refusedToken: token) },
            retryAt: { date in await relay.inbox?.schedule(date) }
        )
        relay.inbox = self
        // Signing in again without the Inbox permission switched it off;
        // the account screen says why, as after connecting for it.
        accounts.sammyInboxScopeLost = { [weak self] accountID in
            self?.errors[accountID] = Self.message(for: SammyConnectFlow.FlowError.missingScope(SammyOAuth.inboxScope))
        }
    }

    /// Hands the outbox's retry dates to this, which the outbox is made
    /// before.
    @MainActor
    private final class RetryRelay {
        weak var inbox: SammyInbox?
    }

    /// At launch: confirms any replaced token still unconfirmed, sends
    /// what is waiting, and watches for the network coming back. Calling
    /// it again does nothing.
    func start() {
        guard !started, !isSample else { return }
        started = true
        accounts.sammySessionChanged = { [weak self] accountID in self?.sessionArrived(for: accountID) }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.network(isSatisfied: satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.bespokebits.influx.sammy-inbox.path", qos: .utility))
        path = monitor
        #if os(macOS)
        // The Mac's scene phase doesn't change when the reader switches
        // back to the app.
        becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.send() }
        }
        #endif
        let accounts = accounts
        Task { [weak self] in
            await accounts.confirmSammyReplacements()
            self?.send()
        }
    }

    /// Sends what is due now: the app came to the foreground, the network
    /// returned, or a backoff is up. A pass under way gets one more.
    func send() {
        guard started else { return }
        if pass != nil {
            passAgain = true
            return
        }
        pass = Task { [weak self] in
            guard let self else { return }
            var next: Date?
            repeat {
                passAgain = false
                next = await outbox.run()
            } while passAgain
            pass = nil
            schedule(next)
        }
    }

    /// The network changed: coming back sends what waits.
    private func network(isSatisfied: Bool) {
        defer { networkSatisfied = isSatisfied }
        if isSatisfied, networkSatisfied == false { send() }
    }

    /// Runs a pass at `next`, unless one is set for no later. A pass that
    /// finds nothing due never cancels a timer already set: a send still
    /// under way during that pass (one the first send's notice stopped
    /// waiting for) records its backoff, and asks for its pass, only when
    /// it finishes. A pass with nothing to do is harmless.
    fileprivate func schedule(_ next: Date?) {
        guard started, let next else { return }
        if timer != nil, let scheduledAt, scheduledAt <= next { return }
        timer?.cancel()
        scheduledAt = next
        let wait = max(1, next.timeIntervalSinceNow)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            timer = nil
            scheduledAt = nil
            send()
        }
    }

    /// A new session for `accountID` here: what waited for one goes now.
    private func sessionArrived(for accountID: String) {
        let outbox = outbox
        Task { [weak self] in
            await outbox.wake(accountID: accountID)
            self?.send()
        }
    }

    // MARK: Bookmarking

    /// An article was bookmarked (or not) on this device. Returns the
    /// notice to show, if any.
    func article(_ row: TimelineRow, isBookmarked: Bool) async -> String? {
        guard !isSample else { return nil }
        guard isBookmarked else {
            await outbox.unbookmarked(key: row.mergeKey)
            return nil
        }
        guard await isOnAnywhere() else { return nil }
        let capture = Result { () throws(SammyCapture.Refusal) in
            try SammyCapture.make(
                key: row.mergeKey, kind: .article, title: row.title, body: row.body, url: row.url,
                from: row.sourceTitle, bookmarkedAt: Date()
            )
        }
        return await queue(capture)
    }

    /// A post was bookmarked (or not) on this device, from the timeline or
    /// a thread. Returns the notice to show, if any.
    func post(_ item: Item, isBookmarked: Bool) async -> String? {
        guard !isSample else { return nil }
        guard isBookmarked else {
            await outbox.unbookmarked(key: item.mergeKey)
            return nil
        }
        guard await isOnAnywhere() else { return nil }
        let source = try? await store.source(id: item.sourceID)
        let from = SammyCapture.from(sourceKind: source?.kind, sourceTitle: source?.title ?? "", authorHandle: item.authorHandle)
        let capture = Result { () throws(SammyCapture.Refusal) in
            try SammyCapture.make(
                key: item.mergeKey, kind: .post, title: item.title, body: item.body, url: item.url,
                from: from, bookmarkedAt: Date()
            )
        }
        return await queue(capture)
    }

    /// Queues and sends `capture`, and returns the notice. One that has to
    /// wait gets a pass scheduled for when its backoff is up.
    private func queue(_ capture: Result<SammyCapture, SammyCapture.Refusal>) async -> String? {
        let outcome = await outbox.bookmarked(capture)
        if case .waiting = outcome { send() }
        return Self.notice(for: outcome)
    }

    private func isOnAnywhere() async -> Bool {
        !((try? await store.sammyInboxAccounts()) ?? []).isEmpty
    }

    #if os(macOS)
    static let device = "Mac"
    #else
    static let device = "iPhone"
    #endif

    /// What the timeline says after a bookmark, for the switch's accounts.
    static func notice(for outcome: SammyInboxOutbox.Outcome) -> String? {
        switch outcome {
        case .off: nil
        case .sent: "Bookmarked · added to your Sammy Inbox"
        case .waiting(.offline): "Bookmarked · goes to your Sammy Inbox when you’re back online"
        case .waiting(.busy): "Bookmarked · goes to your Sammy Inbox once Sammy answers"
        case .waiting(.approval): "Bookmarked · goes to your Sammy Inbox once Sammy’s approval reaches this \(device)"
        case .waiting(.signedOut): "Bookmarked · goes to your Sammy Inbox once you sign in to Sammy again"
        case .refused: "Bookmarked · Sammy didn’t accept it for your Inbox"
        case .cannotSend(.notHTTPS): "Bookmarked · it has no secure web link, so it can’t go to your Sammy Inbox"
        case .cannotSend(.urlTooLong): "Bookmarked · its link is too long to go to your Sammy Inbox"
        case .cannotSend(.badKey): "Bookmarked · it can’t go to your Sammy Inbox"
        }
    }

    // MARK: The switch

    /// Whether this device's session for `accountID` can add to the Inbox
    /// already, so switching on needs no new approval.
    func addsToInbox(_ accountID: String) async -> Bool {
        await accounts.sammySession(accountID)?.addsToInbox == true
    }

    /// Switches Bookmarks to Sammy Inbox on or off for `account`. Off drops
    /// what is waiting for it. On with a session that already holds
    /// `inbox:add` just switches on; otherwise `approve` must be true (the
    /// reader confirmed the alert) and the account is connected again
    /// first, and the switch stays off, with the reason, if that doesn't
    /// come back with both scopes for this account.
    func set(_ on: Bool, for account: Accounts.Account, approve: Bool = false) async {
        errors[account.id] = nil
        guard on else {
            try? await store.setSammyInbox(account.id, on: false)
            return
        }
        if await addsToInbox(account.id) {
            try? await store.setSammyInbox(account.id, on: true)
            send()
            return
        }
        guard approve, !connecting.contains(account.id) else { return }
        connecting.insert(account.id)
        let accounts = accounts
        let connection = Task { [weak self] in
            #if os(macOS)
            // The approval alert is still closing: a sign-in sheet shown
            // on it now would never appear.
            try await Task.sleep(for: .milliseconds(400))
            #endif
            try await accounts.connectSammyForInbox(account) { step in
                Self.log.info("connecting for the Inbox: \(String(describing: step), privacy: .public)")
                self?.steps[account.id] = step
            }
        }
        connections[account.id] = connection
        defer {
            connecting.remove(account.id)
            steps[account.id] = nil
            connections[account.id] = nil
        }
        do {
            try await connection.value
            // Cancel after the browser came back doesn't stop the exchange
            // (`Accounts.signInToSammy`), but the reader still said no: the
            // switch stays off. The session kept can add to the Inbox, so
            // switching on later needs no new approval.
            guard !connection.isCancelled else {
                Self.log.info("connecting for the Inbox cancelled after the exchange")
                return
            }
            try await store.setSammyInbox(account.id, on: true)
            send()
        } catch where connection.isCancelled || error is WebSignIn.Cancelled || error is CancellationError {
            // The reader closed the browser or chose Cancel (whatever the
            // step it stopped threw): the switch stays off.
            Self.log.info("connecting for the Inbox cancelled")
        } catch {
            Self.log.error("connecting for the Inbox failed: \(String(describing: error), privacy: .public)")
            errors[account.id] = Self.message(for: error)
        }
    }

    /// Stops connecting `accountID` for the Inbox, as closing the browser
    /// does: the switch stays off. Once the browser has come back, the
    /// exchange still finishes (`Accounts.signInToSammy`).
    func cancelConnecting(_ accountID: String) {
        connections[accountID]?.cancel()
    }

    /// Why switching on didn't.
    static func message(for error: any Error) -> String {
        switch error {
        case SammyConnectFlow.FlowError.differentAccount:
            "That approval was for a different Sammy account, so it’s off. Sign the Sammy app in to this account, then try again."
        case SammyConnectFlow.FlowError.missingScope(SammyOAuth.inboxScope):
            "Adding to your Inbox wasn’t ticked on the approval, so it’s off. Your feeds stay as they were."
        case SammyConnectFlow.FlowError.missingScope, SammySignInError.missingScope:
            "Reading your feeds wasn’t ticked on the approval, so Influx kept your connection as it was and it’s off."
        case SammyConnectFlow.FlowError.notConnected:
            "This account isn’t connected on this \(device) any more."
        case SammySignInError.scopeNotOffered:
            "This Sammy server can’t add to your Inbox yet."
        default:
            signInMessage(for: error)
        }
    }

    /// What the account screen shows under the switch, kept current: each
    /// change is handed to `update` until the caller's task ends.
    func watchSummary(_ accountID: String, since: Date, _ update: (SammyInboxSummary) -> Void) async {
        do {
            for try await summary in store.observeSammyInboxSummary(accountID, since: since) { update(summary) }
        } catch {}
    }
}
