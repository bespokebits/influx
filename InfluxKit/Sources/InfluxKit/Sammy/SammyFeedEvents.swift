import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sammy's feed change stream (`GET /api/v1/feeds/events`, ADR 0038): a
/// `text/event-stream` that names a feed of the account whenever it gains
/// content. A hint carries nothing else; the feed is then read as usual.
public enum SammyFeedEvents {
    /// What one event of the stream means to a reader.
    public enum Event: Sendable, Hashable {
        /// The stream is subscribed: every change after it is sent.
        case ready
        /// The feed with this ID has new content.
        case changed(feedID: String)
    }

    /// The event `name` and `data` are, or nil for one to ignore: an
    /// unknown name, or a `feed.changed` that names no feed. Unknown data
    /// members are ignored.
    public static func event(name: String, data: String) -> Event? {
        switch name {
        case "ready":
            return .ready
        case "feed.changed":
            struct Changed: Decodable { var feedId: String }
            guard let changed = try? JSONDecoder().decode(Changed.self, from: Data(data.utf8)), !changed.feedId.isEmpty else { return nil }
            return .changed(feedID: changed.feedId)
        default:
            return nil
        }
    }

    /// A connection that sends nothing for this long has died quietly:
    /// the server sends a comment every 25 seconds.
    public static let idleTimeout: TimeInterval = 60
    /// The longest `retry:` taken, so a mistaken one can't park the stream.
    public static let longestRetry: TimeInterval = 5 * 60

    /// How long to wait before connecting again after `attempt` ends in a
    /// row without a `ready`: a second, doubling, at most two minutes,
    /// jittered by `jitter`, but never less than the server's `retry` or
    /// its `Retry-After`.
    public static func reconnectDelay(attempt: Int, jitter: Double = 1, retry: TimeInterval? = nil, retryAfter: TimeInterval? = nil) -> TimeInterval {
        let backoff = min(pow(2, TimeInterval(min(max(attempt, 0), 16))), 120) * jitter
        return max(backoff, min(retry ?? 0, longestRetry), retryAfter ?? 0)
    }
}

/// One Sammy account's change stream while the app is on screen
/// (ADR 0038). Each connection's `ready` reads every rich feed of the
/// account, so what changed while it was away is here; each
/// `feed.changed` reads that feed, if it is one of the reader's sources.
/// A hint that arrives while its feed is being read gets one more read
/// after it, however many arrive, and reads of one feed start at least
/// `readGap` apart. When the connection ends it says so and connects
/// again, after the server's `retry` and a back-off on repeated failures.
/// It ends when the server refuses the stream or the task running it is
/// cancelled.
public actor SammyFeedEventStream {
    /// What the stream tells the account's owner.
    public struct Hooks: Sendable {
        /// Conditional reads of these sources, by ID: the outcome of each.
        public var read: @Sendable ([String]) async -> [String: Refresher.Outcome]
        /// The stream is live (true) or not (false), for the poll cadence.
        public var live: @Sendable (Bool) async -> Void
        /// Sammy refused `token`, the account's, and no other is stored.
        public var refused: @Sendable (_ token: String) async -> Void

        public init(read: @escaping @Sendable ([String]) async -> [String: Refresher.Outcome],
                    live: @escaping @Sendable (Bool) async -> Void,
                    refused: @escaping @Sendable (_ token: String) async -> Void) {
            self.read = read
            self.live = live
            self.refused = refused
        }
    }

    /// Why `run` ended.
    public enum Ending: Sendable, Hashable {
        /// The server offers no stream to this account (403, 404, or not
        /// an event stream at all): keep polling until the account changes.
        case unavailable
        /// The token was refused (401).
        case refused
        /// The task was cancelled: off screen, or signed out.
        case cancelled
    }

    /// How a connection ended.
    private enum Close {
        /// Connect again after the delay; `ready` says it got that far.
        case ended(ready: Bool, retryAfter: TimeInterval?)
        /// Another session was stored since: connect with it at once.
        case newerSession
        case refused
        case unavailable
    }

    private let account: SammyAccount
    private let transport: any EventStreamTransport
    private let hooks: Hooks
    private let readGap: TimeInterval?
    private let busyPause: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let now: @Sendable () -> Date

    /// The account's feed sources, by ID, and which of them hold posts.
    private var feeds: Set<String> = []
    private var rich: [String] = []
    /// The server's last `retry`, kept across connections.
    private var retry: TimeInterval?
    /// Each feed with a read waiting or under way, and its task.
    private var readers: [String: Task<Void, Never>] = [:]
    private var reading: Set<String> = []
    /// Feeds hinted while being read: each gets one more read after.
    private var again: Set<String> = []
    private var lastRead: [String: ContinuousClock.Instant] = [:]

    /// `sources` are the account's feed sources. `readGap` is the least
    /// time between two reads of one feed, by default the account's share
    /// of Sammy's allowance (`RefreshCadence.sammyChangeReadGap`), and
    /// `busyPause` how long a read waits for a fetch of its feed already
    /// under way. `sleep` (the wait before connecting again), `jitter` and
    /// `now` are for tests.
    public init(account: SammyAccount, sources: [Source], transport: any EventStreamTransport, hooks: Hooks,
                readGap: TimeInterval? = nil, busyPause: Duration = .seconds(1),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.9...1.1) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.account = account
        self.transport = transport
        self.hooks = hooks
        self.readGap = readGap
        self.busyPause = busyPause
        self.sleep = sleep
        self.jitter = jitter
        self.now = now
        (feeds, rich) = Self.feeds(of: sources, accountID: account.accountID)
    }

    /// The account's feed sources now: hints name only these, and `ready`
    /// reads those that hold posts.
    public func setSources(_ sources: [Source]) {
        (feeds, rich) = Self.feeds(of: sources, accountID: account.accountID)
    }

    private static func feeds(of sources: [Source], accountID: String) -> (Set<String>, [String]) {
        let mine = sources.filter { $0.kind == .sammyFeed && $0.accountID == accountID }
        return (Set(mine.map(\.id)), mine.filter { $0.itemKind == .post }.map(\.id))
    }

    /// Runs until the server refuses the stream or the task is cancelled.
    public func run() async -> Ending {
        defer {
            for reader in readers.values { reader.cancel() }
        }
        var attempt = 0
        var tookUpNewer = false
        while !Task.isCancelled {
            let close = await connect()
            var retryAfter: TimeInterval?
            switch close {
            case .refused: return .refused
            case .unavailable: return .unavailable
            case .newerSession where !tookUpNewer:
                tookUpNewer = true
                continue
            case .newerSession:
                break
            case .ended(let ready, let after):
                if ready { attempt = 0 }
                retryAfter = after
            }
            tookUpNewer = false
            if Task.isCancelled { break }
            let delay = SammyFeedEvents.reconnectDelay(attempt: attempt, jitter: jitter(), retry: retry, retryAfter: retryAfter)
            do {
                try await sleep(.seconds(delay))
            } catch {
                break
            }
            attempt += 1
        }
        return .cancelled
    }

    /// One connection, until it ends.
    private func connect() async -> Close {
        guard let opening = await account.feedEventsRequest() else { return .unavailable }
        let (request, token) = opening
        var parser = ServerSentEventParser()
        var opened = false
        var ready = false
        do {
            for try await chunk in transport.open(request) {
                switch chunk {
                case .response(let response):
                    guard !opened else { continue }
                    opened = true
                    if let close = await check(response, token: token) { return close }
                case .bytes(let bytes):
                    guard opened else { return .ended(ready: false, retryAfter: nil) }
                    for event in try parser.push(bytes) where handle(event) {
                        // Live first, then what changed while it wasn't.
                        if !ready { await hooks.live(true) }
                        ready = true
                        for id in rich { scheduleRead(id) }
                    }
                }
            }
        } catch {
            // A dropped connection, or a body that isn't an event stream.
        }
        if ready { await hooks.live(false) }
        return .ended(ready: ready, retryAfter: nil)
    }

    /// What a response's status says, or nil for a stream to read: 200
    /// from the account's server as `text/event-stream`.
    private func check(_ response: HTTPURLResponse, token: String) async -> Close? {
        // The transport follows no redirect, so the answer is from where
        // the request went; anything else isn't the account's stream.
        guard let url = response.url, ServerAddress.isSameOrigin(url, account.server),
              url.path == SammyAccount.feedEventsURL(on: account.server).path else { return .unavailable }
        switch response.statusCode {
        case 200:
            let type = response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first
            guard type?.trimmingCharacters(in: .whitespaces).lowercased() == "text/event-stream" else { return .unavailable }
            return nil
        case 401:
            // As a feed read does: a session stored since, by another
            // device or by connecting again, is tried before it counts.
            if await account.takeUpNewerSession(refused: token) { return .newerSession }
            await hooks.refused(token)
            return .refused
        case 403, 404, 410:
            return .unavailable
        case 429:
            let at = now()
            return .ended(ready: false, retryAfter: ConnectorError.retryAfter(response, now: at).map { max(0, $0.timeIntervalSince(at)) })
        default:
            // 503 (not configured yet), 5xx, a redirect: try again later.
            return .ended(ready: false, retryAfter: nil)
        }
    }

    /// Takes in one thing the stream said; true when it is `ready`.
    private func handle(_ event: ServerSentEvent) -> Bool {
        switch event {
        case .retry(let milliseconds):
            retry = TimeInterval(milliseconds) / 1000
        case .comment:
            break
        case .event(let name, let data):
            switch SammyFeedEvents.event(name: name, data: data) {
            case .ready?:
                return true
            case .changed(let feedID)?:
                // Only the reader's own sources of this account; an ID that
                // could run into another part of a source ID isn't one.
                guard SammyFeedList.isSafeID(feedID) else { break }
                let id = SammyFeedConnector.sourceID(accountID: account.accountID, feedID: feedID)
                if feeds.contains(id) { scheduleRead(id) }
            case nil:
                break
            }
        }
        return false
    }

    // MARK: Reads

    /// Reads the source `id` soon: at once, unless a read of it waits
    /// already (which covers this), is under way (one more follows it), or
    /// ran less than the gap ago.
    private func scheduleRead(_ id: String) {
        if reading.contains(id) {
            again.insert(id)
            return
        }
        guard readers[id] == nil else { return }
        readers[id] = Task { await self.read(id) }
    }

    /// How many times a read waits for a fetch of its feed already under
    /// way, which may have been sent before the change, before leaving the
    /// feed to its next poll.
    static let busyRetries = 5

    private func read(_ id: String) async {
        var busy = 0
        while !Task.isCancelled {
            let gap = readGap ?? RefreshCadence.sammyChangeReadGap(feeds: feeds.count)
            if let last = lastRead[id] {
                let wait = last.advanced(by: .seconds(gap)) - ContinuousClock.now
                if wait > .zero { try? await Task.sleep(for: wait) }
                if Task.isCancelled { break }
            }
            let previous = lastRead[id]
            lastRead[id] = ContinuousClock.now
            reading.insert(id)
            let outcome = await hooks.read([id])[id]
            reading.remove(id)
            if outcome == .alreadyRefreshing, busy < Self.busyRetries {
                // Not a read: the next one isn't held back by it.
                lastRead[id] = previous
                busy += 1
                again.insert(id)
                try? await Task.sleep(for: busyPause)
            } else {
                busy = 0
            }
            guard again.remove(id) != nil else { break }
        }
        again.remove(id)
        readers[id] = nil
    }
}
