import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

private let instance = URL(string: "https://example.social")!
private let fetchedAt = Date(timeIntervalSince1970: 1_793_000_000)
private let home = MastodonMapper.homeSource(accountID: "@me@example.social", colorIndex: 1)
private let streamURL = URL(string: "wss://streaming.example.social/api/v1/streaming?stream=user")!

private func instanceInfo(streaming: String?) -> Data {
    let urls = streaming.map { #"{"streaming":"\#($0)"}"# } ?? "{}"
    return Data(#"{"domain":"example.social","configuration":{"urls":\#(urls)}}"#.utf8)
}

/// The home-timeline fixture's statuses as JSON, newest first: ids ending
/// 5 down to 1, then a filtered one (0) and 999.
private func statusJSON() throws -> [String] {
    let url = try #require(Bundle.module.url(forResource: "home-timeline", withExtension: "json", subdirectory: "Fixtures/mastodon"))
    let array = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [Any])
    return try array.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
}

private func message(_ event: String, payload: String) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: ["stream": ["user"], "event": event, "payload": payload]), as: UTF8.self)
}

@Suite struct MastodonStreamParsing {
    @Test func theStreamIsOnTheInstanceOrASubdomainOverWSS() {
        #expect(MastodonStreaming.userStreamURL(instanceInfo: instanceInfo(streaming: "wss://streaming.example.social"), instance: instance) == streamURL)
        #expect(MastodonStreaming.userStreamURL(instanceInfo: instanceInfo(streaming: "wss://example.social/"), instance: instance)
            == URL(string: "wss://example.social/api/v1/streaming?stream=user"))
        // The token goes there, so nowhere else.
        for refused in ["wss://example.com", "wss://notexample.social", "https://streaming.example.social", "ws://example.social",
                        "wss://user:pass@example.social"] {
            #expect(MastodonStreaming.userStreamURL(instanceInfo: instanceInfo(streaming: refused), instance: instance) == nil, "\(refused)")
        }
        #expect(MastodonStreaming.userStreamURL(instanceInfo: instanceInfo(streaming: nil), instance: instance) == nil)
        #expect(MastodonStreaming.userStreamURL(instanceInfo: Data("not json".utf8), instance: instance) == nil)
    }

    @Test func messagesAreReadByTheirEvent() throws {
        let status = try #require(try statusJSON().first)
        guard case .update(let update)? = MastodonStreaming.event(fromMessage: try message("update", payload: status)) else {
            Issue.record("not an update")
            return
        }
        #expect(update.id == "113400000000000005")
        #expect(MastodonStreaming.event(fromMessage: try message("status.update", payload: status)) == .statusUpdate(id: "113400000000000005"))
        #expect(MastodonStreaming.event(fromMessage: try message("delete", payload: "113400000000000005")) == .delete(id: "113400000000000005"))
        #expect(MastodonStreaming.event(fromMessage: try message("notification", payload: "{}")) == .other("notification"))
        #expect(MastodonStreaming.event(fromMessage: try message("update", payload: "{}")) == nil)
        #expect(MastodonStreaming.event(fromMessage: "garbage") == nil)
    }

    @Test func reconnectingBacksOffFromASecondToTwoMinutes() {
        #expect((0...8).map { MastodonStreaming.reconnectDelay(attempt: $0) } == [1, 2, 4, 8, 16, 32, 64, 120, 120])
        #expect(MastodonStreaming.reconnectDelay(attempt: 10_000) == 120)
        #expect(MastodonStreaming.reconnectDelay(attempt: 7, jitter: 1.1) == 132)
    }

    @Test func theTokenGoesInTheHeaderNeverTheURL() async throws {
        let transport = ScriptedTransport()
        let connector = MastodonConnector(accountID: "@me@example.social", instance: instance, accessToken: "secret-token",
                                          http: FakeHTTPClient { _ in .init(status: 404) })
        _ = connector.openUserStream(at: streamURL, with: transport)
        let opened = try #require(transport.opened.first)
        #expect(opened.bearer == "secret-token")
        #expect(!opened.url.absoluteString.contains("secret-token"))
    }
}

@Suite struct MastodonHomeStreaming {
    /// A home timeline whose newest page, asked for without a cursor, is
    /// `firstPage`; asked with `min_id`, `newer`.
    private final class Server: @unchecked Sendable {
        let lock = NSLock()
        var firstPage: [String] = []
        var newer: [String] = []
        var instanceStatus = 200
        var streaming: String? = "wss://streaming.example.social"
        var homeRequests: [URLRequest] = []

        lazy var http = FakeHTTPClient { [unowned self] request in
            lock.withLock {
                switch request.url!.path() {
                case "/api/v2/instance":
                    return instanceStatus == 200 ? .init(body: instanceInfo(streaming: streaming)) : .init(status: instanceStatus)
                case "/api/v1/timelines/home":
                    homeRequests.append(request)
                    let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    let page = query.contains { $0.name == "min_id" } ? newer : firstPage
                    return .init(text: "[" + page.joined(separator: ",") + "]")
                default:
                    return .init(status: 404)
                }
            }
        }
    }

    private final class Log: @unchecked Sendable {
        let lock = NSLock()
        var events: [String] = []
        var sleeps: [TimeInterval] = []
        func note(_ event: String) { lock.withLock { events.append(event) } }
        var all: [String] { lock.withLock { events } }
    }

    private struct Rig {
        let server = Server()
        let transport = ScriptedTransport()
        let log = Log()
        let store: InfluxStore
        let connector: MastodonConnector

        init() throws {
            store = try InfluxStore.inMemory()
            connector = MastodonConnector(accountID: "@me@example.social", instance: instance, accessToken: "t", colorIndex: 1,
                                          http: server.http, resolver: .testing(server.http))
        }

        func stream(closeGapFails: Bool = false) -> MastodonHomeStream {
            let log = log, store = store, connector = connector
            let hooks = MastodonHomeStream.Hooks(
                closeGap: {
                    log.note("gap")
                    let outcome = try? await Refresher(store: store).refresh(home, with: connector, now: fetchedAt)
                    if case .fetched = outcome { return !closeGapFails }
                    return false
                },
                live: { log.note($0 ? "live" : "not live") },
                refused: { log.note("refused") }
            )
            return MastodonHomeStream(connector: connector, home: home, store: store, transport: transport, hooks: hooks,
                                      batchWindow: .milliseconds(100), busyPause: .milliseconds(10),
                                      sleep: { duration in
                                          log.lock.withLock { log.sleeps.append(TimeInterval(duration.components.seconds)) }
                                          try Task.checkCancellation()
                                      },
                                      jitter: { 1 }, now: { fetchedAt })
        }
    }

    @Test func aBurstIsOneWriteAtTheBottomAndMovesTheCursor() async throws {
        let rig = try Rig()
        let statuses = try statusJSON()
        rig.server.firstPage = Array(statuses[3...])
        try await rig.store.save(sources: [home])
        let stream = rig.stream()
        let running = Task { await stream.run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(.opened)
        try await until { rig.log.all == ["gap", "live"] }
        let before = try await rig.store.rows().map(\.mergeKey)
        let rows = RowDeliveries(rig.store)
        try await rows.settle()

        for status in statuses[..<3].reversed() {
            connection.yield(.message(try message("update", payload: status)))
        }
        connection.yield(.message(try message("notification", payload: "{}")))
        connection.yield(.message(try message("delete", payload: "1")))
        try await until { try await rig.store.rows().count == before.count + 3 }
        try await rows.settle()
        // One delivery for the burst of three new rows.
        #expect(rows.count == 2)
        let after = try await rig.store.rows().map(\.mergeKey)
        #expect(Array(after.prefix(before.count)) == before)
        #expect(try await rig.store.fetchState(sourceID: home.id)?.newerCursor == Cursor(rawValue: "113400000000000005"))

        // A poll that brings the same posts adds no rows: one row per post.
        rig.server.newer = Array(statuses[..<3])
        _ = try await Refresher(store: rig.store).refresh(home, with: rig.connector, direction: .newer, now: fetchedAt.addingTimeInterval(60))
        #expect(try await rig.store.rows().map(\.mergeKey) == after)

        running.cancel()
        #expect(await running.value == .cancelled)
        #expect(rig.log.all == ["gap", "live", "not live"])
    }

    @Test func aStreamWhoseGapStayedOpenLeavesTheCursor() async throws {
        let rig = try Rig()
        let statuses = try statusJSON()
        rig.server.firstPage = Array(statuses[3...])
        try await rig.store.save(sources: [home])
        let stream = rig.stream(closeGapFails: true)
        let running = Task { await stream.run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(.opened)
        try await until { rig.log.all == ["gap", "live"] }
        let cursor = try await rig.store.fetchState(sourceID: home.id)?.newerCursor
        connection.yield(.message(try message("update", payload: statuses[0])))
        try await until { try await rig.store.remoteIDs(sourceID: home.id).contains("113400000000000005") }
        #expect(try await rig.store.fetchState(sourceID: home.id)?.newerCursor == cursor)
        running.cancel()
        _ = await running.value
    }

    @Test func postsLeftToThePollKeepTheCursorBehindThem() async throws {
        let rig = try Rig()
        let statuses = try statusJSON()
        rig.server.firstPage = Array(statuses[3...])
        try await rig.store.save(sources: [home])
        let stream = rig.stream()
        let running = Task { await stream.run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(.opened)
        try await until { rig.log.all == ["gap", "live"] }
        let cursor = try await rig.store.fetchState(sourceID: home.id)?.newerCursor
        // A fetch holds the home timeline for longer than a write waits.
        #expect(rig.store.beginRefresh(of: home.id))
        connection.yield(.message(try message("update", payload: statuses[2])))
        try await Task.sleep(for: .milliseconds(400))
        rig.store.endRefresh(of: home.id)
        #expect(try await !rig.store.remoteIDs(sourceID: home.id).contains("113400000000000003"))
        // A later post is stored, but the cursor stays where the poll finds the first.
        connection.yield(.message(try message("update", payload: statuses[0])))
        try await until { try await rig.store.remoteIDs(sourceID: home.id).contains("113400000000000005") }
        #expect(try await rig.store.fetchState(sourceID: home.id)?.newerCursor == cursor)
        running.cancel()
        _ = await running.value
    }

    @Test func aDropPollsAgainAndReconnectsWithBackOff() async throws {
        let rig = try Rig()
        rig.server.firstPage = try Array(statusJSON()[3...])
        try await rig.store.save(sources: [home])
        let stream = rig.stream()
        let running = Task { await stream.run() }
        // Fails before opening twice, then opens and drops.
        try await rig.transport.connection(0).finish(throwing: MastodonStreamFailure.dropped)
        try await rig.transport.connection(1).finish(throwing: URLError(.networkConnectionLost))
        let third = try await rig.transport.connection(2)
        third.yield(.opened)
        try await until { rig.log.all == ["gap", "live"] }
        third.finish(throwing: MastodonStreamFailure.dropped)
        let fourth = try await rig.transport.connection(3)
        try await until { rig.log.all == ["gap", "live", "not live"] }
        // Each failure in a row waits longer; an open connection starts over.
        #expect(rig.log.lock.withLock { rig.log.sleeps } == [1, 2, 1])
        fourth.yield(.opened)
        try await until { rig.log.all == ["gap", "live", "not live", "gap", "live"] }
        running.cancel()
        #expect(await running.value == .cancelled)
        #expect(rig.transport.closed >= 4)
    }

    @Test func aRefusedTokenEndsTheStreamAndSaysSo() async throws {
        let rig = try Rig()
        let stream = rig.stream()
        let running = Task { await stream.run() }
        let connection = try await rig.transport.connection(0)
        connection.finish(throwing: MastodonStreamFailure.unauthorized)
        #expect(await running.value == .refused)
        #expect(rig.log.all == ["refused"])

        // Refused when finding the stream, too.
        let other = try Rig()
        other.server.instanceStatus = 401
        #expect(await other.stream().run() == .refused)
        #expect(other.transport.opened.isEmpty)
    }

    @Test(arguments: [404, 403, 500])
    func anInstanceWithoutAStreamLeavesPolling(status: Int) async throws {
        let rig = try Rig()
        rig.server.instanceStatus = status
        #expect(await rig.stream().run() == .unavailable)
        #expect(rig.transport.opened.isEmpty)
        #expect(rig.log.all.isEmpty)
    }

    @Test func anInstanceThatNamesNoStreamLeavesPolling() async throws {
        let rig = try Rig()
        rig.server.streaming = nil
        #expect(await rig.stream().run() == .unavailable)
        // A stream refused at the handshake does too.
        let other = try Rig()
        let running = Task { await other.stream().run() }
        try await other.transport.connection(0).finish(throwing: MastodonStreamFailure.unavailable)
        #expect(await running.value == .unavailable)
    }

    @Test func aStreamBeforeTheFirstFetchStoresNothing() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [home])
        let item = try #require(MastodonMapper.item(from: try Mastodon.decoder().decode(Mastodon.Status.self, from: Data(try statusJSON()[0].utf8)),
                                                    source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(try await Refresher(store: store).recordStreamed([item], for: home, now: fetchedAt) { $0 } == .notFetchedYet)
        #expect(try await store.rows().isEmpty)
    }
}

/// Polls `condition` until it holds, for at most two seconds.
private func until(_ condition: () async throws -> Bool) async throws {
    for _ in 0..<400 {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("timed out")
}

/// A transport whose connections the test drives.
final class ScriptedTransport: MastodonStreamTransport, @unchecked Sendable {
    typealias Connection = AsyncThrowingStream<MastodonStreamFrame, any Error>.Continuation
    private let lock = NSLock()
    private var _opened: [(url: URL, bearer: String)] = []
    private var connections: [Connection] = []
    private var _closed = 0

    var opened: [(url: URL, bearer: String)] { lock.withLock { _opened } }
    var closed: Int { lock.withLock { _closed } }

    func open(_ url: URL, bearer: String) -> AsyncThrowingStream<MastodonStreamFrame, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?._closed += 1 } }
            lock.withLock {
                _opened.append((url, bearer))
                connections.append(continuation)
            }
        }
    }

    /// The `index`th connection, once it has been opened.
    func connection(_ index: Int) async throws -> Connection {
        for _ in 0..<400 {
            if let connection = lock.withLock({ connections.count > index ? connections[index] : nil }) { return connection }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}

/// Counts what the timeline's observation delivers.
private final class RowDeliveries: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    private var task: Task<Void, Never>?
    var count: Int { lock.withLock { _count } }

    init(_ store: InfluxStore) {
        let rows = store.observeRows()
        task = Task { [weak self] in
            do { for try await _ in rows { self?.lock.withLock { self?._count += 1 } } } catch {}
        }
    }

    deinit { task?.cancel() }

    func settle() async throws {
        try await Task.sleep(for: .milliseconds(150))
    }
}
