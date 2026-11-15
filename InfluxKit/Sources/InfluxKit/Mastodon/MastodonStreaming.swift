import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The Mastodon streaming API, for the home timeline while the app is on
/// screen (ADR 0037): where the stream is, and what its messages say.
public enum MastodonStreaming {
    /// The WebSocket address of the account's `user` stream, from the
    /// instance's `/api/v2/instance` answer (`configuration.urls.streaming`).
    /// Nil when it names none, isn't `wss`, or is on another host than the
    /// instance or one of its subdomains: the token goes there.
    public static func userStreamURL(instanceInfo: Data, instance: URL) -> URL? {
        struct Info: Decodable {
            struct Configuration: Decodable {
                struct URLs: Decodable { var streaming: String? }
                var urls: URLs?
            }
            var configuration: Configuration?
        }
        guard let info = try? JSONDecoder().decode(Info.self, from: instanceInfo),
              let string = info.configuration?.urls?.streaming,
              var components = URLComponents(string: string),
              components.scheme?.lowercased() == "wss",
              let host = components.host?.lowercased(), let instanceHost = instance.host()?.lowercased(),
              host == instanceHost || host.hasSuffix("." + instanceHost),
              components.user == nil, components.password == nil else {
            return nil
        }
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + "/api/v1/streaming"
        components.queryItems = [URLQueryItem(name: "stream", value: "user")]
        components.fragment = nil
        return components.url
    }

    /// One message of the stream.
    public enum Event: Sendable, Hashable {
        /// A new status in the home timeline.
        case update(Mastodon.Status)
        /// A status was edited. The store keeps no edits yet, so it is
        /// ignored.
        case statusUpdate(id: String)
        /// A status was deleted. The store keeps no deletions yet, so it is
        /// ignored.
        case delete(id: String)
        /// Anything else: notifications, filter changes, unknown events.
        case other(String)
    }

    /// The event a WebSocket text message carries
    /// (`{"stream":["user"],"event":"update","payload":"…"}`), or nil when
    /// it can't be read.
    public static func event(fromMessage message: String) -> Event? {
        struct Message: Decodable {
            var event: String
            var payload: String?
        }
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(message.utf8)) else { return nil }
        switch message.event {
        case "update":
            guard let payload = message.payload,
                  let status = try? Mastodon.decoder().decode(Mastodon.Status.self, from: Data(payload.utf8)) else { return nil }
            return .update(status)
        case "status.update":
            guard let payload = message.payload,
                  let status = try? Mastodon.decoder().decode(Mastodon.Status.self, from: Data(payload.utf8)) else { return nil }
            return .statusUpdate(id: status.id)
        case "delete":
            guard let id = message.payload else { return nil }
            return .delete(id: id)
        default:
            return .other(message.event)
        }
    }

    /// How long to wait before connecting again after `attempt` failures in
    /// a row: a second, doubling, at most two minutes, jittered by `jitter`.
    public static func reconnectDelay(attempt: Int, jitter: Double = 1) -> TimeInterval {
        min(pow(2, TimeInterval(min(max(attempt, 0), 16))), 120) * jitter
    }
}

/// What a stream's connection sends up.
public enum MastodonStreamFrame: Sendable, Hashable {
    /// The connection is open: the handshake succeeded.
    case opened
    /// A text message.
    case message(String)
}

/// Why a stream's connection ended, as a transport throws it.
public enum MastodonStreamFailure: Error, Sendable, Hashable {
    /// The instance refused the token (401).
    case unauthorized
    /// The instance doesn't offer the stream to this client (403, 404, 410).
    case unavailable
    /// The connection failed or closed: try again later.
    case dropped
}

/// Opens a stream's connection. The app's is a `URLSessionWebSocketTask`,
/// which Linux Foundation may lack, so InfluxKit only knows this.
public protocol MastodonStreamTransport: Sendable {
    /// Connects to `url` with `bearer` in the `Authorization` header,
    /// following no redirect. The stream yields `.opened` once connected,
    /// then each text message, and ends by throwing a
    /// `MastodonStreamFailure`. Ending iteration closes the connection.
    func open(_ url: URL, bearer: String) -> AsyncThrowingStream<MastodonStreamFrame, any Error>
}

/// One Mastodon account's home stream while the app is on screen
/// (ADR 0037). It finds the stream, connects, and on each connection asks
/// for one normal refresh to close the gap, then stores what the stream
/// sends: statuses through the account's connector, as a fetched page's
/// are, batched into one write. When the connection drops it says so, and
/// connects again after a back-off. It ends when the instance has no
/// stream, refuses the token, or the task running it is cancelled.
public actor MastodonHomeStream {
    /// What the stream tells the account's owner.
    public struct Hooks: Sendable {
        /// One normal refresh of the home source; true when it fetched.
        public var closeGap: @Sendable () async -> Bool
        /// The stream is live (true) or not (false), for the poll cadence.
        public var live: @Sendable (Bool) async -> Void
        /// The instance refused the token.
        public var refused: @Sendable () async -> Void

        public init(closeGap: @escaping @Sendable () async -> Bool, live: @escaping @Sendable (Bool) async -> Void,
                    refused: @escaping @Sendable () async -> Void) {
            self.closeGap = closeGap
            self.live = live
            self.refused = refused
        }
    }

    /// Why `run` ended.
    public enum Ending: Sendable, Hashable {
        /// The instance has no stream for this client: keep polling.
        case unavailable
        /// The token was refused.
        case refused
        /// The task was cancelled: off screen, or signed out.
        case cancelled
    }

    private let connector: MastodonConnector
    private let home: Source
    private let store: InfluxStore
    private let transport: any MastodonStreamTransport
    private let hooks: Hooks
    private let batchWindow: Duration
    private let busyPause: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let jitter: @Sendable () -> Double
    private let now: @Sendable () -> Date

    private var pending: [Mastodon.Status] = []
    private var flushing: Task<Void, Never>?
    /// Whether this connection's statuses follow on from the home source's
    /// cursor: its gap was closed, so the cursor may move to them.
    private var contiguous = false

    /// `batchWindow` is how long a status waits for others to share its
    /// write, and `busyPause` how long it waits for a fetch under way. `sleep` (the wait before connecting again), `jitter` and
    /// `now` are for tests.
    public init(connector: MastodonConnector, home: Source, store: InfluxStore, transport: any MastodonStreamTransport, hooks: Hooks,
                batchWindow: Duration = .milliseconds(500), busyPause: Duration = .seconds(1),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.9...1.1) },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.connector = connector
        self.home = home
        self.store = store
        self.transport = transport
        self.hooks = hooks
        self.batchWindow = batchWindow
        self.busyPause = busyPause
        self.sleep = sleep
        self.jitter = jitter
        self.now = now
    }

    /// Runs until the instance has no stream, the token is refused, or the
    /// task is cancelled.
    public func run() async -> Ending {
        var attempt = 0
        var url: URL?
        while !Task.isCancelled {
            if url == nil {
                do {
                    guard let found = try await connector.userStreamURL() else { return .unavailable }
                    url = found
                } catch .unauthorized {
                    await hooks.refused()
                    return .refused
                } catch {
                    // No answer: try again after the back-off.
                }
            }
            if let url {
                switch await connect(url, attempt: &attempt) {
                case .some(let ending): return ending
                case nil: break
                }
            }
            if Task.isCancelled { break }
            do {
                try await sleep(.seconds(MastodonStreaming.reconnectDelay(attempt: attempt, jitter: jitter())))
            } catch {
                break
            }
            attempt += 1
        }
        return .cancelled
    }

    /// One connection, until it ends. Nil when it dropped and should be
    /// tried again.
    private func connect(_ url: URL, attempt: inout Int) async -> Ending? {
        var isLive = false
        defer { contiguous = false }
        do {
            for try await frame in connector.openUserStream(at: url, with: transport) {
                switch frame {
                case .opened:
                    // Posts sent before the stream opened are fetched, then
                    // the stream carries on from them.
                    contiguous = await hooks.closeGap()
                    attempt = 0
                    isLive = true
                    await hooks.live(true)
                case .message(let message):
                    if case .update(let status) = MastodonStreaming.event(fromMessage: message) {
                        add(status)
                    }
                }
            }
            throw MastodonStreamFailure.dropped
        } catch {
            await flushNow()
            if isLive { await hooks.live(false) }
            switch error as? MastodonStreamFailure {
            case .unauthorized?:
                await hooks.refused()
                return .refused
            case .unavailable?:
                return .unavailable
            default:
                return Task.isCancelled ? .cancelled : nil
            }
        }
    }

    /// Holds `status` for the next write, which waits `batchWindow` for
    /// others. One write runs at a time, taking whatever has arrived since.
    private func add(_ status: Mastodon.Status) {
        pending.append(status)
        guard flushing == nil else { return }
        let window = batchWindow
        flushing = Task {
            try? await Task.sleep(for: window)
            await self.drain()
        }
    }

    /// Writes what is held, waiting for a write under way first.
    private func flushNow() async {
        if let flushing { await flushing.value }
        if !pending.isEmpty { await drain() }
    }

    private func drain() async {
        while !pending.isEmpty {
            let statuses = pending
            pending = []
            await store(statuses)
        }
        flushing = nil
    }

    /// How many times a write waits for a fetch of the home source that is
    /// under way before it gives up; the next poll gets the posts instead,
    /// from a cursor no later write of this connection moves.
    static let busyRetries = 5

    private func store(_ statuses: [Mastodon.Status]) async {
        let at = now()
        let stored = (try? await store.remoteIDs(sourceID: home.id)) ?? []
        let items = await connector.streamedItems(statuses, home: home, now: at, stored: stored)
        let newest = statuses.map(\.id).max(by: MastodonConnector.isOrdered)
        let advance: @Sendable (Cursor?) -> Cursor? = { [contiguous] current in
            guard contiguous, let newest else { return current }
            guard let current else { return Cursor(rawValue: newest) }
            return MastodonConnector.isOrdered(current.rawValue, newest) ? Cursor(rawValue: newest) : current
        }
        let refresher = Refresher(store: store)
        for _ in 0...Self.busyRetries {
            let result = try? await refresher.recordStreamed(items, for: home, now: at, advancing: advance)
            if let result, result != .busy { return }
            if result == nil { break }
            try? await Task.sleep(for: busyPause)
        }
        // These posts are left to the next poll, so no later write may move
        // the cursor past them.
        contiguous = false
    }
}
