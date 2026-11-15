import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

/// A clock a test moves by hand.
private final class DirectClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ date: Date) {
        value = date
    }

    var now: Date { lock.withLock { value } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { value += seconds }
    }
}

/// A Sammy server that answers direct sources (ADR 0040) as a test says,
/// grants any attachment, and serves the grants' bytes; and the source's
/// public media servers, at `media.example.org` and `video.example.org`.
private final class DirectServer: @unchecked Sendable {
    static let feedPath = "/api/v1/feeds/\(RichFixtures.richFeedID)"
    static let grantBytes = Data(repeating: 0x47, count: 32)
    static let imageBytes = Data(repeating: 0x49, count: 48)
    static let video = Data((0..<200).map { UInt8($0) })

    let clock: DirectClock
    private let lock = NSLock()
    /// The answer for one ID, or nil for the server's own default (an image
    /// at three sizes, for 15 minutes).
    private var answerFor: @Sendable (String) -> [String: Any]? = { _ in nil }
    /// How the batch route answers: its status, or nil for a 200.
    private var sourcesStatus: Int?
    /// How a media server answers a path, or nil for its default.
    private var mediaAnswer: @Sendable (URLRequest) -> FakeHTTPClient.Response? = { _ in nil }

    init(clock: DirectClock) {
        self.clock = clock
    }

    func answer(_ answer: @escaping @Sendable (String) -> [String: Any]?) { lock.withLock { answerFor = answer } }
    func sources(status: Int?) { lock.withLock { sourcesStatus = status } }
    func media(_ answer: @escaping @Sendable (URLRequest) -> FakeHTTPClient.Response?) { lock.withLock { mediaAnswer = answer } }

    var expiry: String { ISO8601DateFormatter().string(from: clock.now.addingTimeInterval(900)) }

    func image(_ id: String) -> [String: Any] {
        ["id": id, "use": "direct", "kind": "image", "expiresAt": expiry, "images": [
            ["url": "https://media.example.org/\(id).jpg?size=small", "width": 680, "height": 383],
            ["url": "https://media.example.org/\(id).jpg?size=large", "width": 1200, "height": 675],
            ["url": "https://media.example.org/\(id).jpg", "width": 1600, "height": 900],
        ]]
    }

    func handler() -> @Sendable (URLRequest) throws -> FakeHTTPClient.Response {
        { [self] request in
            guard let url = request.url, url.scheme == "https" else { return .init(status: 404) }
            if url.host() == "media.example.org" || url.host() == "video.example.org" {
                if let answer = lock.withLock({ mediaAnswer })(request) { return answer }
                if url.host() == "video.example.org" { return Self.ranged(request) }
                return .init(headers: ["Content-Type": "image/jpeg", "Content-Length": "\(Self.imageBytes.count)"], body: Self.imageBytes)
            }
            guard url.host() == "example.com" else { return .init(status: 404) }
            let path = url.path
            if path == "\(Self.feedPath)/media-sources", request.httpMethod == "POST" {
                if let status = lock.withLock({ sourcesStatus }) { return .init(status: status) }
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: [String]]
                let ids = body?["ids"] ?? []
                let answerFor = lock.withLock { self.answerFor }
                let media = ids.map { answerFor($0) ?? image($0) }
                return .init(headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
                             body: try JSONSerialization.data(withJSONObject: ["media": media]))
            }
            let grantPrefix = "\(Self.feedPath)/media/"
            if path.hasPrefix(grantPrefix), path.hasSuffix("/grant"), request.httpMethod == "POST" {
                let id = String(path.dropFirst(grantPrefix.count).dropLast("/grant".count))
                let grant = ["url": "https://example.com/api/v1/rich-media/\(id)-token",
                             "expiresAt": ISO8601DateFormatter().string(from: clock.now.addingTimeInterval(900))]
                return .init(headers: ["Content-Type": "application/json"], body: try JSONSerialization.data(withJSONObject: grant))
            }
            if path.hasPrefix("/api/v1/rich-media/") {
                if path.contains("video") { return Self.ranged(request) }
                return .init(headers: ["Content-Type": "image/jpeg", "Content-Length": "\(Self.grantBytes.count)"], body: Self.grantBytes)
            }
            return .init(status: 404)
        }
    }

    /// `video`'s bytes, honouring one `Range`.
    static func ranged(_ request: URLRequest) -> FakeHTTPClient.Response {
        guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") else {
            return .init(headers: ["Content-Type": "video/mp4", "Content-Length": "\(video.count)"], body: video)
        }
        let bounds = header.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        let lower = bounds[0], upper = min(bounds[1], video.count - 1)
        return .init(status: 206, headers: ["Content-Type": "video/mp4", "Content-Length": "\(upper - lower + 1)",
                                            "Content-Range": "bytes \(lower)-\(upper)/\(video.count)"],
                     body: video.subdata(in: lower..<(upper + 1)))
    }
}

private extension URLRequest {
    var isSources: Bool { httpMethod == "POST" && url?.path.hasSuffix("/media-sources") == true }
    var isGrant: Bool { httpMethod == "POST" && url?.path.hasSuffix("/grant") == true }
    var isDirect: Bool { url?.host()?.hasSuffix("example.org") == true }
}

/// Holds a request on a background thread until opened, so a test can
/// cancel the load waiting for it.
private final class DirectGate: @unchecked Sendable {
    private let opened = DispatchSemaphore(value: 0)
    func hold() { opened.wait(); opened.signal() }
    func open() { opened.signal() }
}

/// Answers everything as `inner` does, except a batch of direct sources,
/// which it takes and never answers until cancelled.
private final class StallingSources: HTTPClient, @unchecked Sendable {
    private let inner: FakeHTTPClient
    private let lock = NSLock()
    private var cancelledCount = 0

    init(_ inner: FakeHTTPClient) { self.inner = inner }

    var cancelled: Int { lock.withLock { cancelledCount } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.httpMethod == "POST", request.url?.path.hasSuffix("/media-sources") == true {
            do { try await Task.sleep(for: .seconds(60)) } catch { lock.withLock { cancelledCount += 1 } }
            throw ConnectorError.offline
        }
        return try await inner.send(request)
    }

    func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
        try await inner.send(request, upTo: limit, at: address)
    }

    func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }

    func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }
}

private extension Array where Element: Sendable {
    /// Each element through `transform`, all at once, in order.
    func asyncMap<T: Sendable>(_ transform: @escaping @Sendable (Element) async throws -> T) async throws -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            for (index, element) in enumerated() { group.addTask { (index, try await transform(element)) } }
            var results = [T?](repeating: nil, count: count)
            for try await (index, value) in group { results[index] = value }
            return results.map { $0! }
        }
    }
}

/// Waits, a little at a time, until `condition` holds; fails after 5 seconds.
private func eventually(_ condition: () async -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<1000 {
        if await condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("never happened", sourceLocation: sourceLocation)
}

@Suite struct SammyDirectMediaTests {
    private static let server: [UInt8] = [93, 184, 216, 34]
    private static let mediaServer: [UInt8] = [203, 0, 114, 7]

    /// The grants of the contract's account, reading direct media through
    /// `http` with the media hosts at `mediaAddresses`.
    private static func grants(_ http: any HTTPClient, clock: DirectClock, tally: SammyMediaTally = SammyMediaTally(),
                               mediaAddresses: [String: [[UInt8]]] = [:], sourcesTimeout: Duration = .seconds(5)) throws -> SammyMediaGrants {
        let session = RichFixtures.session()
        let credentials = InMemoryCredentialStore()
        try credentials.save(session, for: session.accountID)
        let addresses = ["media.example.org": [mediaServer], "video.example.org": [mediaServer]].merging(mediaAddresses) { $1 }
        return SammyMediaGrants(account: SammyAccount(session: session, http: http, credentials: credentials), http: http,
                                addresses: AddressLookup { host in host == "example.com" ? [Self.server] : nil },
                                now: { clock.now }, tally: tally, direct: .testing(http, addresses: addresses),
                                sourcesTimeout: sourcesTimeout)
    }

    private static func reference(_ id: String, preview: Bool = false, thread: String? = nil) -> SammyMediaReference {
        SammyMediaReference(accountID: RichFixtures.accountID, feedID: RichFixtures.richFeedID, mediaID: id, preview: preview,
                            thread: thread)!
    }

    private static func load(_ grants: SammyMediaGrants, _ id: String, pixels: Int? = 700,
                             kind: SammyMediaGrants.Kind = .attachment) async throws -> Data {
        try await grants.data(for: reference(id), upTo: 1_000_000, timeout: .seconds(10), kind: kind, pixels: pixels)
    }

    // MARK: Batches

    @Test func rowsAboutToShowAskTogetherAndTheAnswersAreKept() async throws {
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        let http = FakeHTTPClient(server.handler())
        let grants = try Self.grants(http, clock: clock)
        for id in ["a-1", "a-2", "a-3"] { grants.warm(Self.reference(id)) }
        await eventually { http.requests.contains { $0.isSources } }
        async let first = Self.load(grants, "a-1")
        async let second = Self.load(grants, "a-2")
        async let third = Self.load(grants, "a-3")
        #expect(try await [first, second, third] == Array(repeating: DirectServer.imageBytes, count: 3))
        // One request for all three, with the account's credential, to its own server.
        let batches = http.requests.filter(\.isSources)
        #expect(batches.count == 1)
        let batch = try #require(batches.first)
        #expect(batch.url?.absoluteString == "\(RichFixtures.richFeedURL)/media-sources")
        #expect(batch.value(forHTTPHeaderField: "Authorization") != nil)
        #expect(batch.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: batch.httpBody ?? Data()) as? [String: [String]])
        #expect(Set(body["ids"] ?? []) == ["a-1", "a-2", "a-3"])
        #expect(!http.requests.contains { $0.isGrant })

        // Kept until they expire: a second load asks nothing new.
        _ = try await Self.load(grants, "a-1")
        #expect(http.requests.filter(\.isSources).count == 1)
        clock.advance(900)
        _ = try await Self.load(grants, "a-1")
        #expect(http.requests.filter(\.isSources).count == 2)
    }

    @Test func fiftyIDsAtMostGoInOneBatch() async throws {
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        let http = FakeHTTPClient(server.handler())
        let grants = try Self.grants(http, clock: clock)
        for n in 0..<60 { grants.warm(Self.reference("m-\(n)")) }
        await eventually { http.requests.filter(\.isSources).count == 2 }
        let sizes = try http.requests.filter(\.isSources).map { request in
            (try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: [String]])?["ids"]?.count ?? 0
        }
        #expect(sizes.sorted() == [10, 50])
    }

    @Test func aThreadsMediaIsAskedForByItsThread() async throws {
        let clock = DirectClock(RichFixtures.now)
        let http = FakeHTTPClient(DirectServer(clock: clock).handler())
        let grants = try Self.grants(http, clock: clock)
        _ = try await grants.data(for: Self.reference("t-1", thread: "thread-1"), upTo: 1_000_000, timeout: .seconds(10), pixels: 700)
        let batch = try #require(http.requests.first { $0.isSources })
        #expect(batch.url?.absoluteString == "\(RichFixtures.richFeedURL)/media-sources?thread=thread-1")
    }

    // MARK: Direct loads

    @Test func theSmallestImageAtLeastTheDrawnSizeLoadsWithNoCredential() async throws {
        let clock = DirectClock(RichFixtures.now)
        let tally = SammyMediaTally()
        let http = FakeHTTPClient(DirectServer(clock: clock).handler())
        let grants = try Self.grants(http, clock: clock, tally: tally)
        _ = try await Self.load(grants, "row", pixels: 700)
        _ = try await Self.load(grants, "small", pixels: 300)
        // The image viewer asks for the image's own size.
        _ = try await Self.load(grants, "viewer", pixels: 1600)
        _ = try await Self.load(grants, "huge", pixels: 4000)
        let direct = http.requests.filter(\.isDirect)
        #expect(direct.map { $0.url?.absoluteString } == [
            "https://media.example.org/row.jpg?size=large", "https://media.example.org/small.jpg?size=small",
            "https://media.example.org/viewer.jpg", "https://media.example.org/huge.jpg",
        ])
        // Nothing of the account reaches the source: only what an image fetch needs.
        for request in direct {
            #expect(Set((request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }).isSubset(of: ["accept", "user-agent"]))
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil
                && request.value(forHTTPHeaderField: "Referer") == nil)
        }
        // Connected to the address checked to be public.
        #expect(http.addresses.suffix(4).allSatisfy { $0 == Self.mediaServer })
        #expect(tally.counts.attachment.direct == 4 && tally.counts.attachment.fallbacks == 0)
        #expect(tally.counts.timeToImage.direct.reduce(0, +) == 4)
        #expect(!http.requests.contains { $0.isGrant })
    }

    @Test func eachFailureFallsBackToTheGrantForThatIDFromThenOn() async throws {
        let failures: [@Sendable (URLRequest) -> FakeHTTPClient.Response?] = [
            { _ in .init(status: 403) }, { _ in .init(status: 404) }, { _ in .init(status: 410) },
            { _ in .init(headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)) },
            { _ in .init(headers: ["Content-Type": "image/jpeg", "Content-Length": "4096"], body: Data(count: 10)) },
            { _ in .init(status: 302, headers: ["Location": "https://inside.example.net/x.jpg"]) },
        ]
        for (index, failure) in failures.enumerated() {
            let clock = DirectClock(RichFixtures.now)
            let tally = SammyMediaTally()
            let server = DirectServer(clock: clock)
            server.media(failure)
            let http = FakeHTTPClient(server.handler())
            // The redirect leads to a private address, refused at that hop.
            let grants = try Self.grants(http, clock: clock, tally: tally, mediaAddresses: ["inside.example.net": [[10, 0, 0, 7]]])
            #expect(try await Self.load(grants, "f-1") == DirectServer.grantBytes, "failure \(index)")
            #expect(http.requests.filter(\.isGrant).count == 1, "failure \(index)")
            #expect(tally.counts.attachment.fallbacks == 1 && tally.counts.attachment.direct == 0, "failure \(index)")
            #expect(!http.addresses.contains([10, 0, 0, 7]), "failure \(index)")
            // That ID now reads through its grant, without trying the source again.
            let tried = http.requests.filter(\.isDirect).count
            #expect(try await Self.load(grants, "f-1") == DirectServer.grantBytes)
            #expect(http.requests.filter(\.isDirect).count == tried)
        }
    }

    @Test func aLoadItsRowStoppedWaitingForIsNoFailureOfTheSource() async throws {
        let clock = DirectClock(RichFixtures.now)
        let tally = SammyMediaTally()
        let gate = DirectGate()
        let server = DirectServer(clock: clock)
        let http = FakeHTTPClient { request in
            if request.url?.host() == "media.example.org" { gate.hold() }
            return try server.handler()(request)
        }
        let grants = try Self.grants(http, clock: clock, tally: tally)
        let load = Task { try await Self.load(grants, "c-1") }
        await eventually { http.requests.contains { $0.isDirect } }
        load.cancel()
        gate.open()
        _ = try? await load.value
        // Not counted as a fallback, and the next load still goes to the source.
        #expect(tally.counts.attachment.fallbacks == 0)
        #expect(try await Self.load(grants, "c-1") == DirectServer.imageBytes)
        #expect(!http.requests.contains { $0.isGrant })
    }

    @Test func aSourceAtAPrivateAddressIsNeverReached() async throws {
        let clock = DirectClock(RichFixtures.now)
        let http = FakeHTTPClient(DirectServer(clock: clock).handler())
        let grants = try Self.grants(http, clock: clock, mediaAddresses: ["media.example.org": [[192, 168, 1, 20]]])
        #expect(try await Self.load(grants, "p-1") == DirectServer.grantBytes)
        #expect(!http.requests.contains { $0.isDirect })
    }

    @Test func urlsTheServerShouldNotHaveSentAreNeverLoaded() async throws {
        let hostile = ["http://media.example.org/a.jpg", "https://127.0.0.1/a.jpg", "https://localhost/a.jpg", "https://nas.local/a.jpg",
                       "https://reader:fictional@media.example.org/a.jpg", "https://media.example.org:8443/a.jpg",
                       "https://media.example.org/a.jpg#x", "https://[::1]/a.jpg"]
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        server.answer { id in
            guard let index = Int(id.dropFirst(2)) else { return nil }
            return ["id": id, "use": "direct", "kind": "image", "expiresAt": server.expiry,
                    "images": [["url": hostile[index], "width": 680, "height": 383]]]
        }
        let http = FakeHTTPClient(server.handler())
        let grants = try Self.grants(http, clock: clock)
        for index in hostile.indices {
            #expect(try await Self.load(grants, "h-\(index)") == DirectServer.grantBytes)
        }
        #expect(!http.requests.contains { $0.url?.scheme != "https" || $0.url?.host() != "example.com" })
    }

    @Test func aBodyLargerThanTheLimitNeverSitsInMemoryWhole() async throws {
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        server.media { _ in .init(headers: ["Content-Type": "image/jpeg"], body: Data(count: 5000)) }
        let http = FakeHTTPClient(server.handler())
        let grants = try Self.grants(http, clock: clock)
        let data = try await grants.data(for: Self.reference("big"), upTo: 1001, timeout: .seconds(10), pixels: 700)
        #expect(data.count <= 1001)
    }

    @Test func goneNeedsNoGrant() async throws {
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        server.answer { id in ["id": id, "use": "gone"] }
        let http = FakeHTTPClient(server.handler())
        let grants = try Self.grants(http, clock: clock)
        await #expect(throws: ConnectorError.notFound) { _ = try await Self.load(grants, "g-1") }
        #expect(!http.requests.contains { $0.isGrant || $0.isDirect })
    }

    @Test func useAGrantReadsThroughTheGrant() async throws {
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        server.answer { id in ["id": id, "use": "grant"] }
        let http = FakeHTTPClient(server.handler())
        let tally = SammyMediaTally()
        let grants = try Self.grants(http, clock: clock, tally: tally)
        #expect(try await Self.load(grants, "k-1") == DirectServer.grantBytes)
        #expect(http.requests.filter(\.isGrant).count == 1 && !http.requests.contains { $0.isDirect })
        // Not a fallback: nothing direct was tried.
        #expect(tally.counts.attachment.fallbacks == 0 && tally.counts.timeToImage.grant.reduce(0, +) == 1)
    }

    @Test func aPicturesDirectLoadSpendsNoGrantAllowance() async throws {
        let clock = DirectClock(RichFixtures.now)
        let tally = SammyMediaTally()
        let http = FakeHTTPClient(DirectServer(clock: clock).handler())
        let grants = try Self.grants(http, clock: clock, tally: tally)
        for n in 0..<70 { _ = try await Self.load(grants, "av-\(n)", pixels: 120, kind: .avatar) }
        // More pictures than the allowance's 60, every one loaded, none deferred.
        #expect(tally.counts.avatar.direct == 70 && tally.counts.avatar.deferred == 0 && tally.counts.avatar.grants == 0)
    }

    // MARK: A server without direct sources

    @Test func aServerWithoutTheRouteIsReadAsBeforeAndNotAskedAgainSoon() async throws {
        for status in [404, 403, 405] {
            let clock = DirectClock(RichFixtures.now)
            let server = DirectServer(clock: clock)
            server.sources(status: status)
            let http = FakeHTTPClient(server.handler())
            let grants = try Self.grants(http, clock: clock)
            #expect(try await Self.load(grants, "o-1") == DirectServer.grantBytes)
            #expect(try await Self.load(grants, "o-2") == DirectServer.grantBytes)
            // One try, then grants exactly as before, for an hour.
            #expect(http.requests.filter(\.isSources).count == 1)
            #expect(http.requests.filter(\.isGrant).count == 2)
            clock.advance(3601)
            _ = try await Self.load(grants, "o-3")
            #expect(http.requests.filter(\.isSources).count == 2)
        }
    }

    @Test func aBatchTheServerStallsOnLeavesTimeForTheGrant() async throws {
        let clock = DirectClock(RichFixtures.now)
        let http = StallingSources(FakeHTTPClient(DirectServer(clock: clock).handler()))
        let grants = try Self.grants(http, clock: clock, sourcesTimeout: .milliseconds(200))
        // Well inside the caller's own deadline, through the grant.
        let started = ContinuousClock.now
        let data = try await grants.data(for: Self.reference("s-1"), upTo: 1_000_000, timeout: .seconds(3), pixels: 700)
        #expect(data == DirectServer.grantBytes)
        #expect(ContinuousClock.now - started < .seconds(2))
        // The stalled request was given up, so it holds no slot: four more stalls still leave room for grants.
        async let more = [ "s-2", "s-3", "s-4", "s-5" ].asyncMap { id in
            try await grants.data(for: Self.reference(id), upTo: 1_000_000, timeout: .seconds(3), pixels: 700)
        }
        #expect(try await more == Array(repeating: DirectServer.grantBytes, count: 4))
        #expect(http.cancelled >= 1)
    }

    @Test func aBatchThatFailsFallsBackWithoutGivingUpOnTheRoute() async throws {
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        server.sources(status: 502)
        let http = FakeHTTPClient(server.handler())
        let grants = try Self.grants(http, clock: clock)
        #expect(try await Self.load(grants, "b-1") == DirectServer.grantBytes)
        server.sources(status: nil)
        #expect(try await Self.load(grants, "b-2") == DirectServer.imageBytes)
    }

    // MARK: Video

    @Test func aVideoPlaysFromItsSourceEveryRangeFromTheSameFile() async throws {
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        server.answer { id in
            ["id": id, "use": "direct", "kind": "video", "expiresAt": server.expiry,
             "videos": [["url": "https://video.example.org/low.mp4", "width": 480, "height": 270, "bitrate": 256_000],
                        ["url": "https://video.example.org/mid.mp4", "width": 1280, "height": 720, "bitrate": 2_176_000],
                        ["url": "https://video.example.org/high.mp4", "width": 1920, "height": 1080, "bitrate": 8_000_000]],
             "preview": [["url": "https://media.example.org/still.jpg", "width": 1280, "height": 720]]]
        }
        let http = FakeHTTPClient(server.handler())
        let grants = try Self.grants(http, clock: clock)
        let video = Self.reference("video-1")
        let head = try await grants.fetch(video, bytes: 0...1, upTo: 2, timeout: .seconds(10))
        #expect(head.statusCode == 206 && head.totalLength == 200 && head.contentType == "video/mp4")
        let rest = try await grants.fetch(video, bytes: 2...199, upTo: 198, timeout: .seconds(10))
        #expect(rest.data == DirectServer.video.subdata(in: 2..<200))
        // The best rendition at or under the player's bitrate, both times; no grant.
        #expect(http.requests.filter(\.isDirect).map { $0.url?.absoluteString } == Array(repeating: "https://video.example.org/mid.mp4", count: 2))
        #expect(http.requests.filter(\.isDirect).map { $0.value(forHTTPHeaderField: "Range") } == ["bytes=0-1", "bytes=2-199"])
        #expect(!http.requests.contains { $0.isGrant })

        // A later range that fails can't switch files mid-playback.
        server.media { request in request.url?.host() == "video.example.org" ? .init(status: 403) : nil }
        await #expect(throws: ConnectorError.offline) { _ = try await grants.fetch(video, bytes: 100...150, upTo: 51, timeout: .seconds(10)) }
        #expect(!http.requests.contains { $0.isGrant })
    }

    @Test func aVideoWhoseFirstRangeFailsPlaysThroughItsGrant() async throws {
        let clock = DirectClock(RichFixtures.now)
        let server = DirectServer(clock: clock)
        server.answer { id in
            ["id": id, "use": "direct", "kind": "video", "expiresAt": server.expiry,
             "videos": [["url": "https://video.example.org/clip.mp4", "width": 480, "height": 270, "bitrate": 256_000]]]
        }
        // The source answers with the whole file to a range: not what a player reads in pieces.
        server.media { request in
            request.url?.host() == "video.example.org"
                ? .init(headers: ["Content-Type": "video/mp4", "Content-Length": "200"], body: DirectServer.video) : nil
        }
        let http = FakeHTTPClient(server.handler())
        let tally = SammyMediaTally()
        let grants = try Self.grants(http, clock: clock, tally: tally)
        let head = try await grants.fetch(Self.reference("video-2"), bytes: 0...1, upTo: 2, timeout: .seconds(10))
        #expect(head.statusCode == 206)
        #expect(http.requests.filter(\.isGrant).count == 1)
        #expect(tally.counts.attachment.fallbacks == 1)
    }

    // MARK: The answer

    @Test func theRecordedExchangeIsWhatThisBuildSendsAndReads() throws {
        let recorded = try RichFixtures.object("rich-feed-media-sources.json")
        let request = try #require(recorded["request"] as? [String: Any])
        let ids = try #require((request["body"] as? [String: [String]])?["ids"])
        let sent = try SammyMediaSources.request(server: URL(string: RichFixtures.origin)!, feedID: RichFixtures.richFeedID, thread: nil, ids: ids)
        #expect(sent.httpMethod == request["method"] as? String)
        #expect(sent.url?.absoluteString == request["endpoint"] as? String)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: [String]] == ["ids": ids])
        let thread = try SammyMediaSources.request(server: URL(string: RichFixtures.origin)!, feedID: RichFixtures.richFeedID,
                                                   thread: "contract-thread-1", ids: ids)
        #expect(thread.url?.absoluteString == (recorded["threadRequest"] as? [String: Any])?["endpoint"] as? String)

        let response = try #require(recorded["response"] as? [String: Any])
        let body = try JSONSerialization.data(withJSONObject: try #require(response["body"]))
        let answers = try SammyMediaSources.decode(body, ids: ids, now: FeedDate.iso8601("2026-11-03T12:00:00Z")!)
        guard case .direct(let image) = answers["example-image-1"], case .direct(let video) = answers["example-video-1"] else {
            Issue.record("the recorded direct answers didn't read as direct")
            return
        }
        #expect(image.kind == .image && image.images.count == 3 && image.image(forPixels: 700, preview: false)?.width == 2048)
        #expect(video.kind == .video && video.video?.bitrate == 2_176_000 && video.preview.count == 1)
        #expect(answers["example-private-1"] == .grant && answers["example-gone-1"] == .gone)
        // The limits this build holds an answer to are the contract's.
        let limits = try #require(recorded["limits"] as? [String: Int])
        #expect(limits["maxIds"] == SammyMediaSources.maxIDs && limits["listMax"] == SammyMediaSources.listMax)
    }

    @Test func answersAreHeldToTheContract() throws {
        let now = RichFixtures.now
        let later = ISO8601DateFormatter().string(from: now.addingTimeInterval(600))
        let earlier = ISO8601DateFormatter().string(from: now.addingTimeInterval(-1))
        let image = ["url": "https://media.example.org/a.jpg", "width": 680, "height": 383] as [String: Any]
        func decode(_ entries: [[String: Any]], ids: [String]) throws -> [String: SammyDirectAnswer] {
            try SammyMediaSources.decode(try JSONSerialization.data(withJSONObject: ["media": entries]), ids: ids, now: now)
        }
        let ids = ["ok", "late", "extra", "kind", "nothing", "bool", "gone", "gone-extra", "grant"]
        let answers = try decode([
            ["id": "ok", "use": "direct", "kind": "image", "expiresAt": later, "images": [image]],
            ["id": "late", "use": "direct", "kind": "image", "expiresAt": earlier, "images": [image]],
            ["id": "extra", "use": "direct", "kind": "image", "expiresAt": later, "images": [image], "session": "x"],
            ["id": "kind", "use": "direct", "kind": "audio", "expiresAt": later, "images": [image]],
            ["id": "nothing", "use": "direct", "kind": "video", "expiresAt": later, "images": [image]],
            ["id": "bool", "use": "direct", "kind": "image", "expiresAt": later, "images": [["url": "https://media.example.org/b.jpg", "width": true, "height": 1]]],
            ["id": "gone", "use": "gone"],
            ["id": "gone-extra", "use": "gone", "kind": "image"],
            ["id": "grant", "use": "grant"],
        ], ids: ids)
        guard case .direct(let source) = answers["ok"] else { Issue.record("not direct"); return }
        #expect(source.images.map(\.url.absoluteString) == ["https://media.example.org/a.jpg"])
        #expect(ids.dropFirst().map { answers[$0] } == [.grant, .grant, .grant, .grant, .grant, .gone, .grant, .grant])
        // One entry per ID, in order, or nothing is read from it.
        #expect(throws: ConnectorError.self) { try decode([["id": "b", "use": "grant"], ["id": "a", "use": "grant"]], ids: ["a", "b"]) }
        #expect(throws: ConnectorError.self) { try decode([["id": "a", "use": "grant"]], ids: ["a", "b"]) }
    }

    @Test func sizesAreChosenForTheDrawnSize() throws {
        let url = URL(string: "https://media.example.org/x.jpg")!
        let source = SammyDirectSource(kind: .video, expiresAt: RichFixtures.now, images: [], videos: [
            .init(url: url, width: 1, height: 1, bitrate: 3_000_000), .init(url: url, width: 2, height: 2, bitrate: 9_000_000),
        ], preview: [.init(url: url, width: 400, height: 200), .init(url: url, width: 1600, height: 900)])
        // Over the player's bitrate only: the lowest.
        #expect(source.video?.bitrate == 3_000_000)
        #expect(source.image(forPixels: 300, preview: true)?.width == 400)
        #expect(source.image(forPixels: 401, preview: true)?.width == 1600)
        #expect(source.image(forPixels: 5000, preview: true)?.width == 1600)
        #expect(source.image(forPixels: 300, preview: false) == nil)
    }
}
