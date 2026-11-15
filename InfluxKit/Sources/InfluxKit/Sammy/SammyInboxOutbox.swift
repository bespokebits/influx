import Foundation

/// Bookmarks to Sammy Inbox: sends the bookmarks the reader makes on this
/// device to each Sammy account that has the switch on, from a local
/// outbox in the store (`SammyOutboxEntry`), never synced.
///
/// A bookmark is sent at once, then again whenever the app asks (`run`:
/// at launch, on coming to the foreground, when the network returns, and
/// when the backoff is up). Only no answer, a 429 or a 5xx is retried; any
/// other 4xx drops the bookmark at once, because Sammy will never take it.
/// Two kinds of refusal keep it waiting instead: a session without
/// `inbox:add` (the upgraded session has not reached this device yet, or
/// Sammy answered 403), and a revoked token (401), which also tells the
/// app the account needs approving again. A bookmark that hasn't gone
/// through after `expiry` is dropped, and the account screen says so.
///
/// Before every send the switch and the bookmark are checked again, so
/// nothing goes from this device once it knows the switch is off or the
/// bookmark was removed. Sammy derives the task's id from the bookmark's
/// key, so a send repeated after a lost answer makes nothing new.
public actor SammyInboxOutbox {
    /// How long a bookmark is tried for before it is dropped.
    public static let expiry: TimeInterval = 7 * 24 * 60 * 60
    /// How long the first send waits for an answer before the notice says
    /// it will go later. It goes on in the background.
    public static let firstSendLimit: Duration = .seconds(10)
    /// How often a bookmark held for a session that can add to the Inbox
    /// is looked at again while the app is open. The upgraded session
    /// reaches this device through iCloud Keychain, which says nothing
    /// when it does, so a pass rereads the stored session this often. A
    /// look is one keychain read per account, and sends nothing until the
    /// session holds `inbox:add`.
    public static let approvalRecheck: TimeInterval = 15 * 60

    /// What happened to a bookmark just made, for the notice.
    public enum Outcome: Sendable, Hashable {
        /// No Sammy account has the switch on: nothing to say.
        case off
        /// Sammy has it.
        case sent
        /// It waits, and goes once it can.
        case waiting(Waiting)
        /// It can't go to Sammy at all, so it wasn't queued.
        case cannotSend(SammyCapture.Refusal)
        /// Sammy refused it; it was dropped.
        case refused
    }

    public enum Waiting: Sendable, Hashable {
        /// No answer yet: offline, or slow.
        case offline
        /// Sammy is busy (a 429 or a 5xx).
        case busy
        /// This device's session can't add to the Inbox yet.
        case approval
        /// The account was signed out (token revoked).
        case signedOut
    }

    /// The backoff after `attempts` failed sends: a minute, doubling, at
    /// most an hour.
    public static func backoff(afterAttempts attempts: Int) -> TimeInterval {
        min(60 * pow(2, Double(max(0, attempts - 1))), 60 * 60)
    }

    private let store: InfluxStore
    private let account: @Sendable (String) async -> (any SammyInboxAccount)?
    private let signedOut: @Sendable (_ accountID: String, _ refusedToken: String?) async -> Void
    private let retryAt: @Sendable (Date) async -> Void
    private let now: @Sendable () -> Date
    /// Entries being sent now, so a pass and a first send never send the
    /// same one twice at once.
    private var sending: Set<Entry> = []

    private struct Entry: Hashable {
        var key: String
        var accountID: String
    }

    /// `account` finds the account a capture goes through, nil when it
    /// has no session on this device. `signedOut` is told when an account's
    /// token was refused (401), with the token that request carried, for
    /// the app to ask for approval again.
    /// `retryAt` is told the date of every retry a send records, whenever
    /// that send finishes (one the first send stopped waiting for
    /// included), for the app to run again then.
    public init(
        store: InfluxStore,
        account: @escaping @Sendable (String) async -> (any SammyInboxAccount)?,
        signedOut: @escaping @Sendable (_ accountID: String, _ refusedToken: String?) async -> Void = { _, _ in },
        retryAt: @escaping @Sendable (Date) async -> Void = { _ in },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.account = account
        self.signedOut = signedOut
        self.retryAt = retryAt
        self.now = now
    }

    // MARK: Bookmarking

    /// The reader bookmarked something on this device. `capture` is it, or
    /// why it can't go to Sammy. Queues it for every account with the
    /// switch on and sends it at once, waiting at most `limit` for the
    /// answer.
    public func bookmarked(_ made: Result<SammyCapture, SammyCapture.Refusal>, limit: Duration = SammyInboxOutbox.firstSendLimit) async -> Outcome {
        let accounts = (try? await store.sammyInboxAccounts()) ?? []
        guard !accounts.isEmpty else { return .off }
        let capture: SammyCapture
        switch made {
        case .success(let value): capture = value
        case .failure(let refusal): return .cannotSend(refusal)
        }
        let queued: [SammyOutboxEntry]
        do {
            queued = try await store.queueCapture(capture, for: accounts, at: now())
        } catch {
            return .waiting(.offline)
        }
        guard !queued.isEmpty else { return .sent }
        // A task of its own, so the send goes on when the notice stops
        // waiting for it.
        let sends = Task { [self] in
            var outcomes: [Outcome] = []
            for entry in queued { outcomes.append(await self.send(entry)) }
            return outcomes
        }
        let outcomes = await withDeadline(limit) { () async -> [Outcome]? in await sends.value }
        guard let outcomes else { return .waiting(.offline) }
        if outcomes.contains(.sent) { return .sent }
        return outcomes.first { if case .waiting = $0 { true } else { false } } ?? outcomes.first ?? .off
    }

    /// The reader removed the bookmark `key` on this device: it is not
    /// sent where it still waits. Sent already, its task stays.
    public func unbookmarked(key: String) async {
        try? await store.cancelCaptures(key: key)
    }

    // MARK: Sending

    /// Sends every waiting bookmark that is due, after dropping those
    /// older than `expiry`. Returns when the next one falls due by its
    /// backoff, if any does, for the app to run again then.
    @discardableResult
    public func run() async -> Date? {
        let start = now()
        _ = try? await store.expireCaptures(queuedBefore: start.addingTimeInterval(-Self.expiry), at: start)
        let waiting = (try? await store.waitingCaptures()) ?? []
        for entry in waiting {
            if let due = entry.nextAttemptAt, due > now() { continue }
            _ = await send(entry)
        }
        var next: Date?
        let after = (try? await store.waitingCaptures()) ?? []
        for entry in after {
            // One with no date waits for a session that can add to the
            // Inbox: looked at again in `approvalRecheck`.
            let due = Self.wake(at: entry.nextAttemptAt ?? now().addingTimeInterval(Self.approvalRecheck), for: entry)
            if due > now() { next = min(next ?? due, due) }
        }
        return next
    }

    /// When a pass should run for `entry` that would otherwise run at
    /// `date`: no later than just after it expires, so a server's distant
    /// `Retry-After` (or a long hold) can't keep it waiting past `expiry`
    /// in an app that stays open, where nothing else may run the sweep.
    static func wake(at date: Date, for entry: SammyOutboxEntry) -> Date {
        min(date, expiresAt(entry))
    }

    /// The first moment a pass drops `entry` as expired.
    static func expiresAt(_ entry: SammyOutboxEntry) -> Date {
        entry.queuedAt.addingTimeInterval(expiry + 1)
    }

    /// A new session arrived for `accountID` (approved again, or
    /// upgraded): its waiting bookmarks go at the next pass.
    public func wake(accountID: String) async {
        try? await store.wakeCaptures(accountID: accountID)
    }

    /// Sends one waiting entry and records what came of it.
    private func send(_ entry: SammyOutboxEntry) async -> Outcome {
        let id = Entry(key: entry.key, accountID: entry.accountID)
        guard sending.insert(id).inserted else { return .waiting(.offline) }
        defer { sending.remove(id) }
        // Checked again before every send: another device may have
        // switched it off, or the bookmark may have gone since.
        guard (try? await store.isSammyInboxOn(entry.accountID)) == true else {
            try? await store.deleteWaitingCapture(key: entry.key, accountID: entry.accountID)
            return .off
        }
        if (try? await store.isBookmarked(mergeKey: entry.key, kind: entry.kind)) == false {
            try? await store.deleteWaitingCapture(key: entry.key, accountID: entry.accountID)
            return .off
        }
        // Still waiting? A pass may have sent or dropped it meanwhile.
        guard let current = try? await store.waitingCapture(key: entry.key, accountID: entry.accountID) else { return .sent }
        guard let account = await account(entry.accountID), await account.mayAddToInbox() else {
            // Waits, unsent, without spending its backoff, for a session
            // that can add to the Inbox to reach this device; it is looked
            // at again in `approvalRecheck`, or at the next pass.
            await retryAt(Self.wake(at: now().addingTimeInterval(Self.approvalRecheck), for: current))
            return .waiting(.approval)
        }
        let at = now()
        let result = await account.sendCapture(current.capture, now: at)
        switch result {
        case .accepted:
            try? await store.updateWaitingCapture(key: entry.key, accountID: entry.accountID) {
                $0.status = .sent
                $0.settledAt = at
                $0.nextAttemptAt = nil
            }
            return .sent
        case .refused:
            try? await store.updateWaitingCapture(key: entry.key, accountID: entry.accountID) {
                $0.status = .dropped
                $0.dropReason = .refused
                $0.settledAt = at
                $0.nextAttemptAt = nil
            }
            return .refused
        case .offline:
            await retryLater(current, after: nil, at: at)
            return .waiting(.offline)
        case .retry(let after):
            await retryLater(current, after: after, at: at)
            return .waiting(.busy)
        case .missingScope:
            await retryLater(current, after: nil, at: at)
            return .waiting(.approval)
        case .signedOut:
            // Waits for approval again; `wake` sends it once a new session
            // arrives, and an hour's wait stops a revoked token being
            // tried at every pass meanwhile.
            let hold = at.addingTimeInterval(60 * 60)
            try? await store.updateWaitingCapture(key: entry.key, accountID: entry.accountID) {
                $0.nextAttemptAt = hold
            }
            await signedOut(entry.accountID, await account.refusedToken())
            await retryAt(Self.wake(at: hold, for: current))
            return .waiting(.signedOut)
        }
    }

    private func retryLater(_ entry: SammyOutboxEntry, after: Date?, at: Date) async {
        let backoff = at.addingTimeInterval(Self.backoff(afterAttempts: entry.attempts + 1))
        let next = max(backoff, after ?? backoff)
        try? await store.updateWaitingCapture(key: entry.key, accountID: entry.accountID) {
            $0.attempts += 1
            $0.nextAttemptAt = next
        }
        // Said once the date is recorded, so a send the first send's
        // notice stopped waiting for still gets a pass at its backoff, or
        // at its expiry if that comes first.
        await retryAt(Self.wake(at: next, for: entry))
    }
}
