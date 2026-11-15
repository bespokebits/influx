import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

@Suite struct ServerSentEventParsing {
    private func parse(_ chunks: [String]) throws -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return try chunks.flatMap { try parser.push(Data($0.utf8)) }
    }

    @Test func theContractStreamReadsAsItsEvents() throws {
        let fixture = try RichFixtures.object("rich-feed-events.json")
        let stream = try #require(fixture["stream"] as? String)
        let events = try parse([stream])
        #expect(events == [
            .retry(milliseconds: 5000),
            .event(name: "ready", data: "{}"),
            .event(name: "feed.changed", data: #"{"feedId":"0193a1b2-0000-7000-8000-00000000f003"}"#),
            .event(name: "feed.changed", data: #"{"feedId":"0193a1b2-0000-7000-8000-00000000f005"}"#),
            .comment("keepalive"),
        ])
        // The same, a byte at a time.
        #expect(try parse(stream.map { String($0) }) == events)
        // And each frame alone.
        let frames = try #require(fixture["frames"] as? [String: String])
        #expect(try parse([try #require(frames["keepalive"])]) == [.comment("keepalive")])
        let limits = try #require(fixture["limits"] as? [String: Int])
        #expect(try parse([try #require(frames["reconnect"])]) == [.retry(milliseconds: try #require(limits["retryMilliseconds"]))])
        #expect(TimeInterval(try #require(limits["keepaliveSeconds"])) * 2 < SammyFeedEvents.idleTimeout)
    }

    @Test func linesEndWithCRLFOrLFOrCREvenAcrossChunks() throws {
        let expected: [ServerSentEvent] = [.event(name: "a", data: "1"), .event(name: "b", data: "2"), .event(name: "c", data: "3")]
        #expect(try parse(["event: a\r\ndata: 1\r\n\r\nevent: b\ndata: 2\n\nevent: c\rdata: 3\r\r"]) == expected)
        // A CR at the end of one chunk and its LF at the start of the next
        // are one line end, not two (which would end the event early).
        #expect(try parse(["event: a\r", "\ndata: 1\r", "\n\r", "\nevent: b\ndata: 2\n\nevent: c\rdata: 3\r", "\r"]) == expected)
    }

    @Test func dataLinesJoinAndOneLeadingSpaceIsDropped() throws {
        #expect(try parse(["data: one\ndata:two\ndata:  three\ndata\n\n"]) == [.event(name: "message", data: "one\ntwo\n three\n")])
        #expect(try parse(["data\n\n"]) == [.event(name: "message", data: "")])
    }

    @Test func anEventWithoutDataIsNotSentAndItsNameDoesNotCarryOver() throws {
        #expect(try parse(["event: ready\n\ndata: x\n\n"]) == [.event(name: "message", data: "x")])
        #expect(try parse(["event: first\ndata: x\n\ndata: y\n\n"]) == [.event(name: "first", data: "x"), .event(name: "message", data: "y")])
    }

    @Test func commentsIDsAndUnknownFieldsAreReadOrIgnored() throws {
        #expect(try parse([":\n: keepalive\n:no space\n\n"]) == [.comment(""), .comment("keepalive"), .comment("no space")])
        #expect(try parse(["id: 7\nfoo: bar\nevent: ready\ndata: {}\n\n"]) == [.event(name: "ready", data: "{}")])
    }

    @Test func onlyADigitsRetryCounts() throws {
        #expect(try parse(["retry: 2500\n", "retry: 5s\n", "retry: -1\n", "retry:\n", "retry: 1.5\n"]) == [.retry(milliseconds: 2500)])
    }

    @Test func aLeadingByteOrderMarkIsDroppedEvenSplit() throws {
        var parser = ServerSentEventParser()
        var events = try parser.push([0xEF, 0xBB])
        events += try parser.push(Array([0xBF] + Array("event: ready\ndata: {}\n\n".utf8)))
        #expect(events == [.event(name: "ready", data: "{}")])
    }

    @Test func anEventCutOffByTheEndIsNeverSent() throws {
        #expect(try parse(["event: ready\ndata: {}\n"]).isEmpty)
        #expect(try parse(["event: ready\ndata: {}"]).isEmpty)
    }

    @Test func anEndlessLineOrEventIsRefused() throws {
        var parser = ServerSentEventParser()
        #expect(throws: ServerSentEventParser.TooLong.self) {
            _ = try parser.push(Data(repeating: 0x61, count: ServerSentEventParser.maxBytes + 1))
        }
        var another = ServerSentEventParser()
        let line = "data: " + String(repeating: "x", count: 1000) + "\n"
        #expect(throws: ServerSentEventParser.TooLong.self) {
            for _ in 0..<70 { _ = try another.push(Data(line.utf8)) }
        }
    }
}

@Suite struct SammyFeedEventReading {
    @Test func eventsAreReadyOrAChangedFeed() {
        #expect(SammyFeedEvents.event(name: "ready", data: "{}") == .ready)
        #expect(SammyFeedEvents.event(name: "feed.changed", data: #"{"feedId":"f1"}"#) == .changed(feedID: "f1"))
        // Unknown members are ignored.
        #expect(SammyFeedEvents.event(name: "feed.changed", data: #"{"feedId":"f1","count":3}"#) == .changed(feedID: "f1"))
        for data in ["{}", #"{"feedId":""}"#, #"{"feedId":7}"#, "not json"] {
            #expect(SammyFeedEvents.event(name: "feed.changed", data: data) == nil, "\(data)")
        }
        #expect(SammyFeedEvents.event(name: "message", data: "{}") == nil)
        #expect(SammyFeedEvents.event(name: "feed.removed", data: #"{"feedId":"f1"}"#) == nil)
    }

    @Test func reconnectingHonoursRetryAndBacksOff() {
        #expect((0...8).map { SammyFeedEvents.reconnectDelay(attempt: $0) } == [1, 2, 4, 8, 16, 32, 64, 120, 120])
        #expect((0...4).map { SammyFeedEvents.reconnectDelay(attempt: $0, retry: 5) } == [5, 5, 5, 8, 16])
        #expect(SammyFeedEvents.reconnectDelay(attempt: 0, retry: 5, retryAfter: 30) == 30)
        // A retry far too long is cut to five minutes; the back-off isn't.
        #expect(SammyFeedEvents.reconnectDelay(attempt: 0, retry: 86_400) == 300)
        #expect(SammyFeedEvents.reconnectDelay(attempt: 7, jitter: 1.1, retry: 5) == 132)
    }
}

@Suite struct SammyChangeStreaming {
    static let richID = RichFixtures.richFeedID
    static let articleID = RichFixtures.articleFeedID
    static let otherRichID = "0193a1b2-0000-7000-8000-00000000f00b"

    static func source(_ feedID: String, _ kind: Item.Kind?) -> Source {
        Source(id: SammyFeedConnector.sourceID(accountID: RichFixtures.accountID, feedID: feedID), kind: .sammyFeed,
               accountID: RichFixtures.accountID, title: feedID, url: "\(RichFixtures.origin)/api/v1/feeds/\(feedID)", colorIndex: 0,
               itemKind: kind)
    }

    static let rich = source(richID, .post)
    static let otherRich = source(otherRichID, .post)
    static let article = source(articleID, .article)

    static let eventsURL = URL(string: "\(RichFixtures.origin)/api/v1/feeds/events")!

    static func response(_ status: Int, headers: [String: String] = ["Content-Type": "text/event-stream", "Cache-Control": "no-store"],
                         url: URL = eventsURL) -> EventStreamChunk {
        .response(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }

    static func bytes(_ text: String) -> EventStreamChunk { .bytes(Data(text.utf8)) }

    static let ready = "retry: 5000\n\nevent: ready\ndata: {}\n\n"
    static func changed(_ feedID: String) -> String { "event: feed.changed\ndata: {\"feedId\":\"\(feedID)\"}\n\n" }

    /// What the stream told its owner.
    final class Log: @unchecked Sendable {
        let lock = NSLock()
        private var _reads: [String] = []
        private var _events: [String] = []
        private var _sleeps: [TimeInterval] = []
        private var _readTimes: [ContinuousClock.Instant] = []
        /// Reads wait while this is set.
        var holding = false
        /// What each read comes back as.
        var outcome: Refresher.Outcome = .fetched(newItems: 0)

        var reads: [String] { lock.withLock { _reads } }
        var events: [String] { lock.withLock { _events } }
        var sleeps: [TimeInterval] { lock.withLock { _sleeps } }
        var readTimes: [ContinuousClock.Instant] { lock.withLock { _readTimes } }

        func note(_ event: String) { lock.withLock { _events.append(event) } }
        func slept(_ seconds: TimeInterval) { lock.withLock { _sleeps.append(seconds) } }
        func hold(_ on: Bool) { lock.withLock { holding = on } }
        func answer(_ outcome: Refresher.Outcome) { lock.withLock { self.outcome = outcome } }

        func read(_ ids: [String]) async -> [String: Refresher.Outcome] {
            let outcome = lock.withLock {
                _reads += ids.map { String($0.split(separator: ":").last ?? "") }
                _readTimes.append(.now)
                return self.outcome
            }
            while lock.withLock({ holding }), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(2))
            }
            return Dictionary(uniqueKeysWithValues: ids.map { ($0, outcome) })
        }

        /// How many times the feed `feedID` was read.
        func count(_ feedID: String) -> Int { reads.filter { $0 == feedID }.count }
    }

    struct Rig {
        let transport = ScriptedEventTransport()
        let log = Log()
        let credentials = InMemoryCredentialStore()
        let account: SammyAccount

        init() throws {
            let session = RichFixtures.session()
            try credentials.save(session, for: session.accountID)
            account = SammyAccount(session: session, http: FakeHTTPClient { _ in .init(status: 404) }, credentials: credentials)
        }

        func stream(sources: [Source] = [rich, otherRich, article], readGap: TimeInterval = 0) -> SammyFeedEventStream {
            let log = log
            let hooks = SammyFeedEventStream.Hooks(
                read: { await log.read($0) },
                live: { log.note($0 ? "live" : "not live") },
                refused: { log.note("refused \($0)") }
            )
            return SammyFeedEventStream(account: account, sources: sources, transport: transport, hooks: hooks, readGap: readGap,
                                        busyPause: .milliseconds(10),
                                        sleep: { duration in
                                            log.slept(TimeInterval(duration.components.seconds))
                                            try Task.checkCancellation()
                                        },
                                        jitter: { 1 })
        }
    }

    @Test func readyReadsEveryRichFeedAndAHintReadsItsFeed() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream().run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200))
        connection.yield(Self.bytes(Self.ready))
        try await until { rig.log.reads.count == 2 }
        #expect(rig.log.events == ["live"])
        // The article feed waits for its hint or its poll.
        #expect(Set(rig.log.reads) == [Self.richID, Self.otherRichID])

        connection.yield(Self.bytes(Self.changed(Self.richID)))
        try await until { rig.log.count(Self.richID) == 2 }
        connection.yield(Self.bytes(Self.changed(Self.articleID)))
        try await until { rig.log.count(Self.articleID) == 1 }
        // A keepalive does nothing.
        connection.yield(Self.bytes(": keepalive\n\n"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.log.reads.count == 4)
        #expect(rig.log.count(Self.otherRichID) == 1)

        running.cancel()
        #expect(await running.value == .cancelled)
        #expect(rig.log.events == ["live", "not live"])
        #expect(rig.transport.closed == 1)
    }

    @Test func theContractStreamReadsEachFeedOnce() async throws {
        // Ready, then hints for the rich feed and the article feed at once:
        // the rich feed's hint is covered by the read ready asked for.
        let rig = try Rig()
        let stream = try #require(try RichFixtures.object("rich-feed-events.json")["stream"] as? String)
        let running = Task { await rig.stream().run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200))
        connection.yield(Self.bytes(stream))
        try await until { rig.log.reads.count == 3 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.log.reads.sorted() == [Self.richID, Self.articleID, Self.otherRichID].sorted())
        running.cancel()
        _ = await running.value
    }

    @Test func hintsDuringAReadAreOneMoreRead() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream(sources: [Self.rich]).run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200))
        rig.log.hold(true)
        connection.yield(Self.bytes(Self.ready))
        try await until { rig.log.count(Self.richID) == 1 }
        for _ in 0..<5 { connection.yield(Self.bytes(Self.changed(Self.richID))) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.log.count(Self.richID) == 1)
        rig.log.hold(false)
        try await until { rig.log.count(Self.richID) == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.log.count(Self.richID) == 2)
        running.cancel()
        _ = await running.value
    }

    @Test func readsOfOneFeedKeepTheirGap() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream(sources: [Self.rich], readGap: 0.3).run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200))
        connection.yield(Self.bytes(Self.ready))
        try await until { rig.log.count(Self.richID) == 1 }
        // Three hints soon after: one read, once the gap has passed.
        for _ in 0..<3 { connection.yield(Self.bytes(Self.changed(Self.richID))) }
        try await until { rig.log.count(Self.richID) == 2 }
        let times = rig.log.readTimes
        #expect(times[1] - times[0] >= .milliseconds(290))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.log.count(Self.richID) == 2)
        running.cancel()
        _ = await running.value
    }

    @Test func aReadMeetingAFetchUnderWayTriesAgainAfterIt() async throws {
        let rig = try Rig()
        rig.log.answer(.alreadyRefreshing)
        let running = Task { await rig.stream(sources: [Self.rich]).run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200))
        connection.yield(Self.bytes(Self.ready))
        try await until { rig.log.count(Self.richID) == 2 }
        rig.log.answer(.fetched(newItems: 1))
        try await Task.sleep(for: .milliseconds(80))
        // Once the fetch under way has finished, no more.
        let reads = rig.log.count(Self.richID)
        try await Task.sleep(for: .milliseconds(80))
        #expect(rig.log.count(Self.richID) == reads)
        #expect(reads <= 1 + SammyFeedEventStream.busyRetries)
        running.cancel()
        _ = await running.value
    }

    @Test func hintsForOtherFeedsAndOtherEventsAreIgnored() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream().run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200))
        connection.yield(Self.bytes(": keepalive\n\n"))
        connection.yield(Self.bytes(Self.changed("0193a1b2-0000-7000-8000-0000000000ff")))
        connection.yield(Self.bytes(Self.changed("..")))
        connection.yield(Self.bytes(Self.changed("a:feed:b")))
        connection.yield(Self.bytes("event: feed.changed\ndata: {\"feed\":\"\(Self.richID)\"}\n\n"))
        connection.yield(Self.bytes("event: feed.removed\ndata: {\"feedId\":\"\(Self.richID)\"}\n\n"))
        connection.yield(Self.bytes("data: {\"feedId\":\"\(Self.richID)\"}\n\n"))
        connection.yield(Self.bytes("id: 1\nevent: feed.changed\n\n"))
        try await Task.sleep(for: .milliseconds(80))
        #expect(rig.log.reads.isEmpty)
        #expect(rig.log.events.isEmpty)
        running.cancel()
        _ = await running.value
    }

    @Test func aFeedAddedWhileStreamingIsReadOnItsHint() async throws {
        let rig = try Rig()
        let stream = rig.stream(sources: [Self.rich])
        let running = Task { await stream.run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200))
        connection.yield(Self.bytes(Self.changed(Self.articleID)))
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.log.reads.isEmpty)
        await stream.setSources([Self.rich, Self.article])
        connection.yield(Self.bytes(Self.changed(Self.articleID)))
        try await until { rig.log.count(Self.articleID) == 1 }
        running.cancel()
        _ = await running.value
    }

    @Test func endsReconnectAfterRetryAndBackOffAndReadAgain() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream(sources: [Self.rich]).run() }
        // No answer, then a server not ready yet: one second, then two.
        try await rig.transport.connection(0).finish(throwing: URLError(.networkConnectionLost))
        let second = try await rig.transport.connection(1)
        second.yield(Self.response(503, headers: ["Content-Type": "application/json"]))
        // Then a stream that sends its retry and ready, and ends (its hour
        // is up): it waits the server's five seconds and reads again.
        let third = try await rig.transport.connection(2)
        third.yield(Self.response(200))
        third.yield(Self.bytes(Self.ready))
        try await until { rig.log.count(Self.richID) == 1 }
        third.finish()
        let fourth = try await rig.transport.connection(3)
        // A drop before ready counts as a failure in a row, still no less
        // than the retry.
        fourth.finish(throwing: URLError(.timedOut))
        let fifth = try await rig.transport.connection(4)
        fifth.yield(Self.response(200))
        fifth.yield(Self.bytes("event: ready\ndata: {}\n\n"))
        try await until { rig.log.count(Self.richID) == 2 }
        #expect(rig.log.sleeps == [1, 2, 5, 5])
        #expect(rig.log.events == ["live", "not live", "live"])
        running.cancel()
        #expect(await running.value == .cancelled)
        #expect(rig.transport.closed == 5)
    }

    @Test func aRefusedTokenEndsTheStreamAsSignedOut() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream().run() }
        try await rig.transport.connection(0).yield(Self.response(401, headers: ["Content-Type": "application/json"]))
        #expect(await running.value == .refused)
        #expect(rig.log.events == ["refused \(RichFixtures.session().accessToken)"])
        #expect(rig.log.reads.isEmpty)
        #expect(rig.log.sleeps.isEmpty)
    }

    @Test func aRefusalTriesASessionStoredSinceFirst() async throws {
        let rig = try Rig()
        var newer = RichFixtures.session()
        newer.accessToken = "sao_signed-in-again-on-another-device"
        try rig.credentials.save(newer, for: newer.accountID)
        let running = Task { await rig.stream().run() }
        try await rig.transport.connection(0).yield(Self.response(401))
        // At once, with the stored session's token.
        let second = try await rig.transport.connection(1)
        #expect(rig.transport.requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(newer.accessToken)")
        #expect(rig.log.sleeps.isEmpty)
        second.yield(Self.response(401))
        #expect(await running.value == .refused)
        #expect(rig.log.events == ["refused \(newer.accessToken)"])
    }

    @Test(arguments: [403, 404])
    func aStreamTheServerDoesNotOfferStopsIt(status: Int) async throws {
        let rig = try Rig()
        let running = Task { await rig.stream().run() }
        try await rig.transport.connection(0).yield(Self.response(status, headers: ["Content-Type": "application/json"]))
        #expect(await running.value == .unavailable)
        #expect(rig.log.events.isEmpty)
        #expect(rig.log.reads.isEmpty)
        #expect(rig.transport.requests.count == 1)
    }

    @Test func aRateLimitWaitsForRetryAfter() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream().run() }
        try await rig.transport.connection(0).yield(Self.response(429, headers: ["Retry-After": "30"]))
        // The stream cap's refusal, as the contract records it.
        let refusals = try #require(try RichFixtures.object("rich-feed-events.json")["refusals"] as? [String: [String: Any]])
        let cap = try #require(refusals["tooManyStreams"]?["headers"] as? [String: String])
        try await rig.transport.connection(1).yield(Self.response(429, headers: cap))
        _ = try await rig.transport.connection(2)
        #expect(rig.log.sleeps == [30, 5])
        running.cancel()
        _ = await running.value
    }

    @Test func eachContractRefusalIsFollowed() async throws {
        let refusals = try #require(try RichFixtures.object("rich-feed-events.json")["refusals"] as? [String: [String: Any]])
        var endings: [String: SammyFeedEventStream.Ending] = [:]
        for (name, refusal) in refusals {
            let rig = try Rig()
            let status = try #require(refusal["status"] as? Int)
            let headers = (refusal["headers"] as? [String: String] ?? [:]).merging(["Content-Type": "application/json"]) { a, _ in a }
            let running = Task { await rig.stream().run() }
            try await rig.transport.connection(0).yield(Self.response(status, headers: headers))
            if (try? await rig.transport.connection(1, waiting: 20)) != nil {
                // Connected again: a wait, not an end.
                running.cancel()
            }
            endings[name] = await running.value
        }
        #expect(endings == [
            "unauthorized": .refused, "forbiddenScope": .unavailable, "notFound": .unavailable,
            "rateLimited": .cancelled, "tooManyStreams": .cancelled, "notConfigured": .cancelled,
        ])
    }

    @Test func theCredentialGoesOnlyToTheAccountsStreamInItsHeader() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream().run() }
        let connection = try await rig.transport.connection(0)
        let request = try #require(rig.transport.requests.first)
        #expect(request.url == Self.eventsURL)
        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(RichFixtures.session().accessToken)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(!(request.url?.absoluteString.contains(RichFixtures.session().accessToken) ?? true))
        #expect(request.timeoutInterval == SammyFeedEvents.idleTimeout)
        // An answer from anywhere else, as a redirect would bring, is not
        // the account's stream: nothing in it is read.
        connection.yield(Self.response(200, url: URL(string: "https://elsewhere.example.com/api/v1/feeds/events")!))
        connection.yield(Self.bytes(Self.ready))
        #expect(await running.value == .unavailable)
        #expect(rig.log.reads.isEmpty)
    }

    @Test func aResponseThatIsNotAnEventStreamStopsIt() async throws {
        let rig = try Rig()
        let running = Task { await rig.stream().run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200, headers: ["Content-Type": "text/html"]))
        connection.yield(Self.bytes(Self.ready))
        #expect(await running.value == .unavailable)
        #expect(rig.log.reads.isEmpty)
    }

    @Test func anAccountSignedOutHereOpensNothing() async throws {
        let rig = try Rig()
        await rig.account.signOut()
        #expect(await rig.stream().run() == .unavailable)
        #expect(rig.transport.requests.isEmpty)
    }

    @Test func goingOffScreenCancelsReadsUnderWay() async throws {
        let rig = try Rig()
        rig.log.hold(true)
        let running = Task { await rig.stream(sources: [Self.rich]).run() }
        let connection = try await rig.transport.connection(0)
        connection.yield(Self.response(200))
        connection.yield(Self.bytes(Self.ready))
        try await until { rig.log.count(Self.richID) == 1 }
        running.cancel()
        #expect(await running.value == .cancelled)
        #expect(rig.transport.closed == 1)
        #expect(rig.log.events == ["live", "not live"])
    }

    @Test func readsAreConditionalThroughTheConnector() async throws {
        // The owner's read is a normal refresh: the second, after a hint,
        // sends the first one's ETag and costs a 304.
        let headers = try RichFixtures.headers("page")
        let page = try RichFixtures.data("rich-feed-page-1.json")
        let notModified = try RichFixtures.object("rich-feed-not-modified.json")
        let response = try #require(notModified["response"] as? [String: Any])
        let notModifiedHeaders = try #require(response["headers"] as? [String: String])
        let http = FakeHTTPClient { request in
            request.value(forHTTPHeaderField: "If-None-Match") == headers["ETag"]
                ? .init(status: 304, headers: notModifiedHeaders) : .init(headers: headers, body: page)
        }
        let connector = try RichFixtures.connector(http)
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Self.rich])
        let transport = ScriptedEventTransport()
        let hooks = SammyFeedEventStream.Hooks(
            read: { ids in
                let sources = [Self.rich].filter { ids.contains($0.id) }
                return (try? await Refresher(store: store).refreshAll(sources, with: connector, now: RichFixtures.now)) ?? [:]
            },
            live: { _ in }, refused: { _ in }
        )
        let stream = SammyFeedEventStream(account: connector.account, sources: [Self.rich], transport: transport, hooks: hooks, readGap: 0)
        let running = Task { await stream.run() }
        let connection = try await transport.connection(0)
        connection.yield(Self.response(200))
        connection.yield(Self.bytes(Self.ready))
        try await until { try await !store.rows().isEmpty }
        let rows = try await store.rows().count
        connection.yield(Self.bytes(Self.changed(Self.richID)))
        try await until { http.requests.filter { $0.url?.path().hasSuffix(Self.richID) == true }.count == 2 }
        let feedRequests = http.requests.filter { $0.url?.path().hasSuffix(Self.richID) == true }
        #expect(feedRequests[0].value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(feedRequests[1].value(forHTTPHeaderField: "If-None-Match") == headers["ETag"])
        #expect(try await store.rows().count == rows)
        // The stream's own request went through the transport, not the
        // feed reader's client.
        #expect(!http.requests.contains { $0.url?.path().hasSuffix("/events") == true })
        running.cancel()
        _ = await running.value
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

/// An event stream transport whose connections the test drives.
final class ScriptedEventTransport: EventStreamTransport, @unchecked Sendable {
    typealias Connection = AsyncThrowingStream<EventStreamChunk, any Error>.Continuation
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var connections: [Connection] = []
    private var _closed = 0

    var requests: [URLRequest] { lock.withLock { _requests } }
    var closed: Int { lock.withLock { _closed } }

    func open(_ request: URLRequest) -> AsyncThrowingStream<EventStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { self?._closed += 1 } }
            lock.withLock {
                _requests.append(request)
                connections.append(continuation)
            }
        }
    }

    /// The `index`th connection, once it has been opened, waiting at most
    /// `waiting` tries of 5 ms.
    func connection(_ index: Int, waiting: Int = 400) async throws -> Connection {
        for _ in 0..<waiting {
            if let connection = lock.withLock({ connections.count > index ? connections[index] : nil }) { return connection }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationError()
    }
}
