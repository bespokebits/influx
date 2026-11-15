import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

/// A rich feed is newest first by `publishedAt`, so a post the server learns
/// of late (a repost of an older post) enters below posts a reader already
/// has. These are the since reads that deliver it (`rich-feed-since.json`).
@Suite struct SammySinceReadTests {
    private typealias Files = RichFixtures

    /// The since fixture's case `name`: the request that gets it and its page.
    private static func since(_ name: String) throws -> (request: String, page: [String: Any]) {
        let cases = try Files.object("rich-feed-since.json")
        let entry = try #require(cases[name] as? [String: Any])
        return (try #require(entry["request"] as? String), try #require(entry["page"] as? [String: Any]))
    }

    private static func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    /// A server answering each URL with its body and `headers`, 404 otherwise.
    private static func server(_ headers: [String: String], _ routes: [(String, Data)]) -> FakeHTTPClient {
        let table = Dictionary(routes, uniquingKeysWith: { first, _ in first })
        return FakeHTTPClient { request in
            guard let url = request.url?.absoluteString, let body = table[url] else { return .init(status: 404) }
            return .init(headers: headers, body: body)
        }
    }

    private static func validators(_ page: FetchedPage) throws -> SammyFeedConnector.Validators {
        try #require(page.newer.flatMap(SammyFeedConnector.Validators.init(cursor:)))
    }

    /// The bug: the late post sits below a page of posts the reader has, and
    /// the since link is what reaches it.
    @Test func aLatePostOlderThanEverythingReadComesThroughTheSinceLink() async throws {
        let headers = try Files.headers("page")
        let first = try Self.since("first"), late = try Self.since("late"), nothing = try Self.since("nothingNew")
        let http = Self.server(headers, [(first.request, try Self.json(first.page)), (late.request, try Self.json(late.page)),
                                         (nothing.request, try Self.json(nothing.page))])
        let source = Files.source(.post)
        let connector = try Files.connector(http)
        let read = try await connector.fetch(Files.request(source), from: source)
        #expect(try Self.validators(read).since == late.request)

        let stored = Set(read.items.map(\.remoteID))
        let again = try await connector.fetch(Files.request(source, cursor: read.newer, stored: stored), from: source)
        #expect(http.requests.last?.url?.absoluteString == late.request)
        let latePost = try #require(again.items.first)
        #expect(again.items.count == 1 && !stored.contains(latePost.remoteID))
        #expect(latePost.publishedAt < read.items.map(\.publishedAt).min()!)
        #expect(try Self.validators(again).since == nothing.request)

        let quiet = try await connector.fetch(Files.request(source, cursor: again.newer, stored: stored.union([latePost.remoteID])), from: source)
        #expect(http.requests.last?.url?.absoluteString == nothing.request)
        #expect(quiet.items.isEmpty)
        #expect(try Self.validators(quiet).since == nothing.request)
    }

    /// A since read's pages hold only posts that entered after the token, so
    /// a post the reader has (a repeat) is no reason to stop.
    @Test func everyPageOfASinceReadIsRead() async throws {
        let headers = try Files.headers("page")
        let first = try Self.since("first"), late = try Self.since("late")
        let secondURL = "\(Files.richFeedURL)?before=since-page-2"
        var head = late.page
        head["items"] = try #require(first.page["items"] as? [Any])
        head["nextUrl"] = secondURL
        let http = Self.server(headers, [(first.request, try Self.json(first.page)), (late.request, try Self.json(head)),
                                         (secondURL, try Self.json(late.page))])
        let source = Files.source(.post)
        let connector = try Files.connector(http)
        let read = try await connector.fetch(Files.request(source), from: source)
        let again = try await connector.fetch(Files.request(source, cursor: read.newer, stored: Set(read.items.map(\.remoteID))), from: source)
        #expect(http.requests.last?.url?.absoluteString == secondURL)
        #expect(again.items.count == 2)
    }

    /// Posts missed before the feed offered a since link: the first top read
    /// that offers one, for a source fetched before, reads the whole window
    /// once instead of stopping at the first post it has.
    @Test func theFirstSinceLinkASourceFetchedBeforeIsOfferedReadsTheWholeWindowOnce() async throws {
        let headers = try Files.headers("page")
        let first = try Self.since("first"), late = try Self.since("late")
        var top = first.page
        top["nextUrl"] = Files.secondPageURL
        let older = try Files.data("rich-feed-page-2.json")
        let http = Self.server(headers, [(first.request, try Self.json(top)), (Files.secondPageURL, older),
                                         (late.request, try Self.json(late.page))])
        let source = Files.source(.post)
        let connector = try Files.connector(http)
        // A cursor from before since reads, and the top page's post stored.
        let before = SammyFeedConnector.Validators(etag: nil, accept: SammyNegotiation.rich, format: .rich).cursor
        let topIDs = try #require(top["items"] as? [[String: Any]]).count
        #expect(topIDs == 1)
        let probe = try await connector.fetch(Files.request(source), from: source)
        let stored = Set(probe.items.map(\.remoteID))
        let sent = http.requests.count

        let caughtUp = try await connector.fetch(Files.request(source, cursor: before, stored: stored), from: source)
        #expect(http.requests.dropFirst(sent).map { $0.url?.absoluteString } == [first.request, Files.secondPageURL])
        #expect(caughtUp.items.contains { !stored.contains($0.remoteID) })
        let validators = try Self.validators(caughtUp)
        #expect(validators.since == late.request && validators.resume == nil && validators.readsAll == nil)

        // From then on, `.newer` is the since read.
        _ = try await connector.fetch(Files.request(source, cursor: caughtUp.newer, stored: stored), from: source)
        #expect(http.requests.last?.url?.absoluteString == late.request)
    }

    /// Without a since link the feed is read as before: a source fetched
    /// before stops at the first page that holds a post it has.
    @Test func aFeedWithoutASinceLinkIsReadAsBefore() async throws {
        let source = Files.source(.post)
        let http = try Files.pages()
        let connector = try Files.connector(http)
        let read = try await connector.fetch(Files.request(source), from: source)
        #expect(try Self.validators(read).since == nil)
        let sent = http.requests.count
        _ = try await connector.fetch(Files.request(source, cursor: read.newer, stored: Set(read.items.map(\.remoteID))), from: source)
        #expect(http.requests.dropFirst(sent).map { $0.url?.absoluteString } == [Files.richFeedURL])
    }

    /// A since page with no link gives no token: the old one is kept and
    /// read again, and its pages stop as a top read's do.
    @Test func aSincePageWithoutALinkKeepsTheTokenItHas() async throws {
        let headers = try Files.headers("page")
        let first = try Self.since("first"), late = try Self.since("late")
        var unlinked = late.page
        unlinked.removeValue(forKey: "sinceUrl")
        let http = Self.server(headers, [(first.request, try Self.json(first.page)), (late.request, try Self.json(unlinked))])
        let source = Files.source(.post)
        let connector = try Files.connector(http)
        let read = try await connector.fetch(Files.request(source), from: source)
        let again = try await connector.fetch(Files.request(source, cursor: read.newer), from: source)
        #expect(again.items.count == 1)
        #expect(try Self.validators(again).since == late.request)
    }

    /// An unchanged since read is a 304 on its own validator, and keeps the
    /// cursor.
    @Test func anUnchangedSinceReadIsA304() async throws {
        let headers = try Files.headers("page")
        let first = try Self.since("first"), late = try Self.since("late")
        let sinceTag = "W/\"rich-v1-since-example\""
        var sinceHeaders = headers
        sinceHeaders["ETag"] = sinceTag
        var same = late.page
        same["sinceUrl"] = late.request
        let firstBody = try Self.json(first.page), sameBody = try Self.json(same)
        let answers = sinceHeaders, firstURL = first.request
        let http = FakeHTTPClient { request in
            if request.url?.absoluteString == firstURL { return .init(headers: headers, body: firstBody) }
            if request.value(forHTTPHeaderField: "If-None-Match") == sinceTag { return .init(status: 304, headers: ["ETag": sinceTag]) }
            return .init(headers: answers, body: sameBody)
        }
        let source = Files.source(.post)
        let connector = try Files.connector(http)
        let read = try await connector.fetch(Files.request(source), from: source)
        let changed = try await connector.fetch(Files.request(source, cursor: read.newer), from: source)
        #expect(try Self.validators(changed).etag == sinceTag)
        let unchanged = try await connector.fetch(Files.request(source, cursor: changed.newer), from: source)
        #expect(unchanged.items.isEmpty && unchanged.newer == changed.newer)
        #expect(http.requests.last?.value(forHTTPHeaderField: "If-None-Match") == sinceTag)
    }

    /// A since link off the feed's own origin or path is left out, and the
    /// page is still read.
    @Test func aSinceLinkOffTheFeedIsLeftOut() throws {
        let first = try Self.since("first")
        let feedURL = URL(string: Files.richFeedURL)!
        for link in ["https://other.example/api/v1/feeds/\(Files.richFeedID)?since=x",
                     "\(Files.origin)/api/v1/feeds/0193a1b2-0000-7000-8000-00000000f004?since=x", "http://example.com/x", 7] as [Any] {
            var page = first.page
            page["sinceUrl"] = link
            let decoded = try RichFeedPage.decode(Self.json(page), feedID: Files.richFeedID, feedURL: feedURL)
            #expect(decoded.sinceURL == nil, "\(link)")
            #expect(decoded.posts.count == 1)
        }
        let decoded = try RichFeedPage.decode(Self.json(first.page), feedID: Files.richFeedID, feedURL: feedURL)
        #expect(decoded.sinceURL == (first.page["sinceUrl"] as? String))
    }
}
