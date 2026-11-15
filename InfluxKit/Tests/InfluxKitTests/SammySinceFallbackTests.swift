import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

/// A since link the server stops serving (a feed source rolled back to a
/// build without since reads, or a token it no longer accepts) is dropped
/// for a top read of the whole window, so the feed keeps refreshing and no
/// post is lost; and links are held off for a while after, so a server that
/// offers links it can't serve never costs a whole-window read a refresh.
@Suite struct SammySinceFallbackTests {
    private typealias Files = RichFixtures
    private typealias Validators = SammyFeedConnector.Validators

    private static func since(_ name: String) throws -> (request: String, page: [String: Any]) {
        let cases = try Files.object("rich-feed-since.json")
        let entry = try #require(cases[name] as? [String: Any])
        return (try #require(entry["request"] as? String), try #require(entry["page"] as? [String: Any]))
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    private static func validators(_ page: FetchedPage) throws -> Validators {
        try #require(page.newer.flatMap(Validators.init(cursor:)))
    }

    /// The feed: a top page that offers the since link and has a next page,
    /// that next page, and the since link answered by `since` (its status,
    /// and its headers when it is a page).
    private struct Feed {
        let top: Data, second: Data, late: Data
        let headers: [String: String]
        let sinceURL: String
        let http: FakeHTTPClient

        init() throws {
            headers = try Files.headers("page")
            let first = try SammySinceFallbackTests.since("first"), late = try SammySinceFallbackTests.since("late")
            var top = first.page
            top["nextUrl"] = Files.secondPageURL
            self.top = try SammySinceFallbackTests.json(top)
            second = try Files.data("rich-feed-page-2.json")
            self.late = try SammySinceFallbackTests.json(late.page)
            sinceURL = late.request
            http = FakeHTTPClient { _ in .init(status: 404) }
            serveSince(status: 200)
        }

        /// Serves the top pages, and the since link with `status`: a page
        /// for 200, else that status with `sinceHeaders`. With `topStatus`,
        /// the top page fails too.
        func serveSince(status: Int, sinceHeaders: [String: String] = [:], topStatus: Int = 200) {
            let headers = headers, top = top, second = second, late = late, sinceURL = sinceURL
            http.respond { request in
                switch request.url?.absoluteString {
                case Files.richFeedURL?: topStatus == 200 ? .init(headers: headers, body: top) : .init(status: topStatus)
                case Files.secondPageURL?: .init(headers: headers, body: second)
                case sinceURL?: status == 200 ? .init(headers: headers, body: late) : .init(status: status, headers: sinceHeaders)
                default: .init(status: 404)
                }
            }
        }

        /// The URLs requested since `count` requests had been sent.
        func sent(after count: Int) -> [String?] {
            http.requests.dropFirst(count).map { $0.url?.absoluteString }
        }
    }

    /// A first fetch, which takes the since link, and the posts it stored.
    private static func start(_ feed: Feed, _ connector: SammyFeedConnector, _ source: Source) async throws -> (FetchedPage, Set<String>) {
        let read = try await connector.fetch(Files.request(source), from: source)
        #expect(try validators(read).since == feed.sinceURL)
        return (read, Set(read.items.map(\.remoteID)))
    }

    /// The rollback: a 400 (the contract's refusal of a token), 404 or 410
    /// from the since link drops it, and the same fetch reads the top page
    /// and every page of the window below it, past the posts the source has.
    @Test(arguments: [400, 404, 410])
    func aSinceLinkNoLongerServedIsDroppedForAWholeWindowRead(status: Int) async throws {
        let feed = try Feed()
        let source = Files.source(.post)
        let connector = try Files.connector(feed.http)
        let (read, stored) = try await Self.start(feed, connector, source)
        feed.serveSince(status: status)
        let sent = feed.http.requests.count

        let fallback = try await connector.fetch(Files.request(source, cursor: read.newer, stored: stored), from: source)
        #expect(feed.sent(after: sent) == [feed.sinceURL, Files.richFeedURL, Files.secondPageURL])
        #expect(feed.http.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
        #expect(fallback.items.contains { !stored.contains($0.remoteID) })
        let next = try Self.validators(fallback)
        #expect(next.since == nil && next.resume == nil && next.readsAll == nil)
        #expect(next.sinceDrops == 1 && next.sinceHeldUntil == Files.now.addingTimeInterval(3600))
    }

    /// After a drop, offered links are not taken until the hold ends; the
    /// first one taken then reads the whole window once, and the since
    /// reads carry on. A drop that follows the link's return holds links off
    /// twice as long, and a since read that works ends the count.
    @Test func linksAreHeldOffAfterADropAndTakenAgainAfter() async throws {
        let feed = try Feed()
        let source = Files.source(.post)
        let connector = try Files.connector(feed.http)
        let (read, stored) = try await Self.start(feed, connector, source)
        feed.serveSince(status: 404)
        let dropped = try await connector.fetch(Files.request(source, cursor: read.newer, stored: stored), from: source)
        let all = stored.union(dropped.items.map(\.remoteID))

        // Held: the offered link is not taken, and the read stops at the
        // first post the source has.
        var sent = feed.http.requests.count
        let held = try await connector.fetch(Files.request(source, cursor: dropped.newer, stored: all, now: Files.now.addingTimeInterval(1800)), from: source)
        #expect(feed.sent(after: sent) == [Files.richFeedURL])
        #expect(feed.http.requests.last?.value(forHTTPHeaderField: "If-None-Match") != nil)
        #expect(try Self.validators(held).since == nil)
        #expect(try Self.validators(held).sinceHeldUntil == Files.now.addingTimeInterval(3600))

        // The hold is over: the link is taken, with one whole-window read.
        // The top page is read whole, since a quiet feed would otherwise
        // answer 304 and the link would never be seen.
        let later = Files.now.addingTimeInterval(3601)
        sent = feed.http.requests.count
        let taken = try await connector.fetch(Files.request(source, cursor: held.newer, stored: all, now: later), from: source)
        #expect(feed.sent(after: sent) == [Files.richFeedURL, Files.secondPageURL])
        #expect(feed.http.requests[sent].value(forHTTPHeaderField: "If-None-Match") == nil)
        let back = try Self.validators(taken)
        #expect(back.since == feed.sinceURL && back.sinceHeldUntil == nil && back.sinceDrops == 1)

        // Still not served: dropped again, and held off for two hours.
        sent = feed.http.requests.count
        let again = try await connector.fetch(Files.request(source, cursor: taken.newer, stored: all, now: later), from: source)
        #expect(feed.sent(after: sent) == [feed.sinceURL, Files.richFeedURL, Files.secondPageURL])
        #expect(try Self.validators(again).sinceDrops == 2)
        #expect(try Self.validators(again).sinceHeldUntil == later.addingTimeInterval(2 * 3600))

        // Served again after the hold: one since read that works clears it.
        feed.serveSince(status: 200)
        let latest = later.addingTimeInterval(2 * 3600 + 1)
        let retaken = try await connector.fetch(Files.request(source, cursor: again.newer, stored: all, now: latest), from: source)
        sent = feed.http.requests.count
        let working = try await connector.fetch(Files.request(source, cursor: retaken.newer, stored: all, now: latest), from: source)
        #expect(feed.sent(after: sent) == [feed.sinceURL])
        let cleared = try Self.validators(working)
        #expect(cleared.sinceDrops == nil && cleared.sinceFailures == nil && cleared.sinceHeldUntil == nil)
        #expect(cleared.since != nil)
    }

    /// A server error from the since link, while the top page can be read,
    /// is counted: below the limit the link and its validator are kept and
    /// the top page is read as usual, so the feed keeps refreshing; the
    /// limit drops the link for a whole-window read.
    @Test func serverErrorsFromTheSinceLinkAreCountedThenDropIt() async throws {
        let feed = try Feed()
        let source = Files.source(.post)
        let connector = try Files.connector(feed.http)
        let (read, stored) = try await Self.start(feed, connector, source)
        feed.serveSince(status: 502)
        var cursor = read.newer
        for count in 1..<SammyFeedConnector.sinceFailureLimit {
            let sent = feed.http.requests.count
            let page = try await connector.fetch(Files.request(source, cursor: cursor, stored: stored), from: source)
            #expect(feed.sent(after: sent) == [feed.sinceURL, Files.richFeedURL])
            let next = try Self.validators(page)
            #expect(next.since == feed.sinceURL && next.sinceFailures == count)
            #expect(next.etag == (try Self.validators(read)).etag && next.sinceHeldUntil == nil)
            cursor = page.newer
        }
        let sent = feed.http.requests.count
        let dropped = try await connector.fetch(Files.request(source, cursor: cursor, stored: stored), from: source)
        #expect(feed.sent(after: sent) == [feed.sinceURL, Files.richFeedURL, Files.secondPageURL])
        #expect(dropped.items.contains { !stored.contains($0.remoteID) })
        let next = try Self.validators(dropped)
        #expect(next.since == nil && next.sinceFailures == nil && next.sinceDrops == 1)
    }

    /// The count is of errors in a row: a since read that works, or one
    /// that is unchanged, ends it.
    @Test(arguments: [false, true])
    func aSinceReadThatWorksEndsTheCount(unchanged: Bool) async throws {
        let feed = try Feed()
        let source = Files.source(.post)
        let connector = try Files.connector(feed.http)
        let (read, stored) = try await Self.start(feed, connector, source)
        feed.serveSince(status: 500)
        let failed = try await connector.fetch(Files.request(source, cursor: read.newer, stored: stored), from: source)
        #expect(try Self.validators(failed).sinceFailures == 1)
        if unchanged {
            let tag = try #require(Self.validators(read).etag)
            feed.serveSince(status: 304, sinceHeaders: ["ETag": tag])
        } else {
            feed.serveSince(status: 200)
        }
        let sent = feed.http.requests.count
        let worked = try await connector.fetch(Files.request(source, cursor: failed.newer, stored: stored), from: source)
        #expect(feed.sent(after: sent) == [feed.sinceURL])
        #expect(try Self.validators(worked).sinceFailures == nil)
    }

    /// When the top page fails too, the server is what's failing, not the
    /// link: the fetch fails as any does, and nothing is counted.
    @Test func aServerErrorEverywhereFailsTheFetchAndCountsNothing() async throws {
        let feed = try Feed()
        let source = Files.source(.post)
        let connector = try Files.connector(feed.http)
        let (read, stored) = try await Self.start(feed, connector, source)
        feed.serveSince(status: 502, topStatus: 502)
        let sent = feed.http.requests.count
        await #expect(throws: ConnectorError.badResponse("HTTP 502")) {
            try await connector.fetch(Files.request(source, cursor: read.newer, stored: stored), from: source)
        }
        #expect(feed.sent(after: sent) == [feed.sinceURL, Files.richFeedURL])
    }

    /// A rate limit, and any other failure that says nothing about the link,
    /// fails the fetch with the usual backoff, sends nothing else, and keeps
    /// the link.
    @Test(arguments: [(429, [:]), (503, ["Retry-After": "120"]), (401, [:]), (406, [:])] as [(Int, [String: String])])
    func otherFailuresKeepTheLink(status: Int, headers: [String: String]) async throws {
        let feed = try Feed()
        let source = Files.source(.post)
        let connector = try Files.connector(feed.http)
        let (read, stored) = try await Self.start(feed, connector, source)
        feed.serveSince(status: status, sinceHeaders: headers)
        let sent = feed.http.requests.count
        await #expect(throws: ConnectorError.self) {
            try await connector.fetch(Files.request(source, cursor: read.newer, stored: stored), from: source)
        }
        #expect(feed.sent(after: sent).allSatisfy { $0 == feed.sinceURL })
    }

    /// A since read that never gets an answer is a failed fetch, not a drop.
    @Test func anUnansweredSinceReadKeepsTheLink() async throws {
        let feed = try Feed()
        let source = Files.source(.post)
        let connector = try Files.connector(feed.http)
        let (read, stored) = try await Self.start(feed, connector, source)
        let sinceURL = feed.sinceURL
        feed.http.respond { request in
            guard request.url?.absoluteString != sinceURL else { throw URLError(.notConnectedToInternet) }
            return .init(status: 404)
        }
        let sent = feed.http.requests.count
        await #expect(throws: (any Error).self) {
            try await connector.fetch(Files.request(source, cursor: read.newer, stored: stored), from: source)
        }
        #expect(feed.sent(after: sent) == [feed.sinceURL])
    }

    @Test func theHoldOffDoublesFromAnHourToADay() {
        let hours = (1...8).map { SammyFeedConnector.sinceHoldOff(afterDrops: $0) / 3600 }
        #expect(hours == [1, 2, 4, 8, 16, 24, 24, 24])
    }

    /// A cursor from before the fallback reads as one with nothing counted.
    @Test func aCursorFromBeforeTheFallbackHasNothingCounted() throws {
        let old = Cursor(rawValue: #"{"accept":"a","format":"rich/1","since":"https://example.com/x"}"#)
        let validators = try #require(Validators(cursor: old))
        #expect(validators.since == "https://example.com/x")
        #expect(validators.sinceFailures == nil && validators.sinceHeldUntil == nil && validators.sinceDrops == nil)
    }
}
