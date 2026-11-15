import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26T08:53:20Z

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

/// The spec's simple example (jsonfeed.org/version/1.1).
private let simpleFeed = """
{
    "version": "https://jsonfeed.org/version/1.1",
    "title": "My Example Feed",
    "home_page_url": "https://example.org/",
    "feed_url": "https://example.org/feed.json",
    "items": [
        {
            "id": "2",
            "content_text": "This is a second item.",
            "url": "https://example.org/second-item"
        },
        {
            "id": "1",
            "content_html": "<p>Hello, world!</p>",
            "url": "https://example.org/initial-post"
        }
    ]
}
"""

/// Shaped like the spec's podcast example, with the 1.1 fields filled in.
private let podcastFeed = """
{
    "version": "https://jsonfeed.org/version/1.1",
    "user_comment": "This is a podcast feed.",
    "title": "The Record",
    "home_page_url": "https://example.com/the-record/",
    "feed_url": "https://example.com/the-record/feed.json",
    "icon": "https://example.com/the-record/icon-512.png",
    "favicon": "https://example.com/the-record/icon-64.png",
    "next_url": "https://example.com/the-record/feed.json?page=2",
    "authors": [{"name": "Ana and Bo", "url": "https://example.com/the-record/about"}],
    "items": [
        {
            "id": "https://example.com/the-record/2026/10/episode-1",
            "title": "Special #1 - A guest",
            "url": "https://example.com/the-record/2026/10/episode-1",
            "summary": "Ana interviews a guest & friends.",
            "content_text": "The guest has worked at <Example Co> and elsewhere.",
            "content_html": "<p>The guest has worked at <a href=\\"https://example.com/co\\">Example Co</a>.</p>",
            "image": "https://example.com/the-record/2026/10/episode-1.jpg",
            "banner_image": "https://example.com/the-record/banner.jpg",
            "date_published": "2026-10-23T22:15:00-04:00",
            "date_modified": "2026-10-24T01:00:00Z",
            "attachments": [
                {"url": "https://example.com/the-record/episode-1.m4a", "mime_type": "audio/x-m4a", "size_in_bytes": 89970236},
                {"url": "https://example.com/the-record/episode-1.mp4", "mime_type": "video/mp4"},
                {"url": "https://example.com/the-record/cover.png", "mime_type": "image/png"}
            ]
        }
    ]
}
"""

private let feedSource = Source(id: "rss:https://example.com/feed.json", kind: .rss, title: "Example", url: "https://example.com/feed.json", colorIndex: 2)

@Suite struct JSONFeedParsing {
    @Test func theSpecsSimpleExample() throws {
        let feed = try FeedParser.parse(Data(simpleFeed.utf8))
        #expect(feed.format == .json)
        #expect(feed.title == "My Example Feed")
        #expect(feed.link == "https://example.org/")
        #expect(feed.feedURL == "https://example.org/feed.json")
        #expect(feed.next == nil)
        #expect(feed.entries.map(\.id) == ["2", "1"])
        #expect(feed.entries.map(\.link) == ["https://example.org/second-item", "https://example.org/initial-post"])
        #expect(feed.entries[0].content == "This is a second item.")
        #expect(feed.entries[1].content == "<p>Hello, world!</p>")
        #expect(feed.entries.allSatisfy { !$0.idIsPermaLink && $0.title == nil })
    }

    @Test func everyItemFieldIsRead() throws {
        let feed = try FeedParser.parse(Data(podcastFeed.utf8), baseURL: URL(string: "https://example.com/the-record/feed.json"))
        #expect(feed.icon == "https://example.com/the-record/icon-512.png")
        #expect(feed.next == "https://example.com/the-record/feed.json?page=2")
        let entry = try #require(feed.entries.first)
        #expect(entry.id == "https://example.com/the-record/2026/10/episode-1")
        #expect(entry.title == "Special #1 - A guest")
        #expect(HTMLText.plainText(entry.summary!) == "Ana interviews a guest & friends.")
        // HTML wins over text when both are given.
        #expect(HTMLText.plainText(entry.content!) == "The guest has worked at Example Co.")
        // The feed's authors stand in for an item's own.
        #expect(entry.author == "Ana and Bo")
        #expect(entry.published == utc(2026, 10, 24, 2, 15))
        #expect(entry.updated == utc(2026, 10, 24, 1))
        #expect(entry.images.map(\.url) == [
            "https://example.com/the-record/2026/10/episode-1.jpg",
            "https://example.com/the-record/banner.jpg",
            "https://example.com/the-record/cover.png",
        ])
        // Audio is skipped; the movie file is a video.
        #expect(entry.videos.map(\.url) == ["https://example.com/the-record/episode-1.mp4"])
    }

    @Test func versionOneIsReadToo() throws {
        let json = """
        {"version": "https://jsonfeed.org/version/1", "title": "Old", "favicon": "/favicon.ico",
         "author": {"name": "Feed Author"},
         "items": [{"id": 42, "url": "https://example.com/42", "content_text": "One", "author": {"name": "Ana"}},
                   {"id": "43", "external_url": "https://example.net/story", "content_text": "Two"}]}
        """
        let feed = try FeedParser.parse(Data(json.utf8), baseURL: URL(string: "https://example.com/feed.json"))
        #expect(feed.icon == "https://example.com/favicon.ico")
        // A numeric ID is read as a string.
        #expect(feed.entries.map(\.id) == ["42", "43"])
        #expect(feed.entries.map(\.author) == ["Ana", "Feed Author"])
        // A link post's subject is kept apart from its own page.
        #expect(feed.entries[1].link == nil)
        #expect(feed.entries[1].externalLink == "https://example.net/story")
    }

    @Test func aBlankHTMLContentFallsBackToText() throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"id": "1", "content_html": " ", "content_text": "Hi"}]}"#
        #expect(try FeedParser.parse(Data(json.utf8)).entries[0].content == "Hi")
    }

    @Test func anUnusableIconGivesWayToTheFavicon() throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "icon": "data:image/png;base64,AAAA", "favicon": "/favicon.png", "items": []}"#
        let feed = try FeedParser.parse(Data(json.utf8), baseURL: URL(string: "https://example.com/feed.json"))
        #expect(feed.icon == "https://example.com/favicon.png")

        // So does one the row couldn't show: plain http, or SVG.
        for icon in ["http://cdn.example.com/icon.png", "/icon.svg"] {
            let json = #"{"version": "https://jsonfeed.org/version/1.1", "icon": "\#(icon)", "favicon": "/favicon.png", "items": []}"#
            #expect(try FeedParser.parse(Data(json.utf8), baseURL: URL(string: "https://example.com/feed.json")).icon
                    == "https://example.com/favicon.png")
        }
    }

    @Test func aNumberTooLargeToHoldReadsAsMissing() throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "_ext": {"score": 1e400}, "items": [{"id": "1", "content_text": "x", "_ext": [1e400]}]}"#
        let feed = try FeedParser.parse(Data(json.utf8))
        #expect(feed.entries.map(\.content) == ["x"])
    }

    @Test func onlyASameOriginHTTPSNextPageIsKept() throws {
        func next(_ value: String, at base: String? = "https://sammy.example/feeds/1") throws -> String? {
            let json = #"{"version": "https://jsonfeed.org/version/1.1", "next_url": "\#(value)", "feed_url": "\#(value)", "items": []}"#
            return try FeedParser.parse(Data(json.utf8), baseURL: base.flatMap(URL.init(string:))).next
        }
        #expect(try next("?before=9") == "https://sammy.example/feeds/1?before=9")
        #expect(try next("https://SAMMY.example:443/feeds/1?before=9") == "https://SAMMY.example:443/feeds/1?before=9")
        #expect(try next("https://other.example/feeds/1?before=9") == nil)
        #expect(try next("https://sammy.example:8443/feeds/1?before=9") == nil)
        #expect(try next("http://sammy.example/feeds/1?before=9") == nil)
        #expect(try next("http://sammy.example/feeds/1?before=9", at: "http://sammy.example/feeds/1") == nil)
        // Without the address it came from there is no origin to hold it to.
        #expect(try next("https://sammy.example/feeds/1?before=9", at: nil) == nil)
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "feed_url": "http://example.com/feed.json", "items": []}"#
        #expect(try FeedParser.parse(Data(json.utf8)).feedURL == nil)
    }

    @Test func xmlFeedsHaveNoNextPage() throws {
        let rss = #"<rss version="2.0"><channel><title>T</title><item><guid>1</guid><title>A</title></item></channel></rss>"#
        let feed = try FeedParser.parse(Data(rss.utf8), baseURL: URL(string: "https://example.com/feed.xml"))
        #expect(feed.format == .rss)
        #expect(feed.next == nil)
        #expect(feed.feedURL == nil)
    }

    @Test func authorsArePreferredToTheOlderAuthor() throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"id": "1", "content_text": "x", "authors": [{"url": "https://example.com/"}, {"name": " Ana & Bo "}], "author": {"name": "Old"}}]}"#
        let entry = try FeedParser.parse(Data(json.utf8)).entries[0]
        #expect(HTMLText.plainText(entry.author!) == "Ana & Bo")
    }

    @Test func relativeURLsResolveAgainstTheFeed() throws {
        let json = """
        {"version": "https://jsonfeed.org/version/1.1", "title": "Rel", "home_page_url": "/", "next_url": "feed.json?page=2", "icon": "icon.png",
         "items": [{"id": "1", "url": "/posts/1", "image": "img/1.jpg", "content_text": "x",
                    "attachments": [{"url": "media/1.mp4", "mime_type": "video/mp4"}]}]}
        """
        let feed = try FeedParser.parse(Data(json.utf8), baseURL: URL(string: "https://example.com/blog/feed.json"))
        #expect(feed.link == "https://example.com/")
        #expect(feed.next == "https://example.com/blog/feed.json?page=2")
        #expect(feed.icon == "https://example.com/blog/icon.png")
        #expect(feed.entries[0].link == "https://example.com/posts/1")
        #expect(feed.entries[0].images.map(\.url) == ["https://example.com/blog/img/1.jpg"])
        #expect(feed.entries[0].videos.map(\.url) == ["https://example.com/blog/media/1.mp4"])
    }

    @Test func plainTextIsEscapedForTheHTMLStep() throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "title": "Tom & Jerry <3", "items": [{"id": "1", "title": "Use <Widget> &amp; more", "content_text": "a < b"}]}"#
        let feed = try FeedParser.parse(Data(json.utf8))
        #expect(HTMLText.plainText(feed.title!) == "Tom & Jerry <3")
        #expect(HTMLText.plainText(feed.entries[0].title!) == "Use <Widget> &amp; more")
        #expect(HTMLText.plainText(feed.entries[0].content!) == "a < b")
    }

    @Test func badDatesAreNil() throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"id": "1", "content_text": "x", "date_published": "yesterday", "date_modified": 1793000000}]}"#
        let entry = try FeedParser.parse(Data(json.utf8)).entries[0]
        #expect(entry.published == nil)
        #expect(entry.updated == nil)
    }

    @Test func emptyAndOddItemsAreTolerated() throws {
        let empty = try FeedParser.parse(Data(#"{"version": "https://jsonfeed.org/version/1.1", "title": "Quiet", "items": []}"#.utf8))
        #expect(empty.entries.isEmpty)
        #expect(try FeedParser.parse(Data(#"{"version": "https://jsonfeed.org/version/1.1"}"#.utf8)).entries.isEmpty)
        // Wrong types read as missing; an item that isn't an object is skipped.
        let odd = #"{"version": "https://jsonfeed.org/version/1.1", "title": 7, "items": ["nope", 3, {"id": "1", "title": ["x"], "url": false, "content_text": "kept"}]}"#
        let feed = try FeedParser.parse(Data(odd.utf8))
        #expect(feed.title == nil)
        #expect(feed.entries.count == 1)
        #expect(feed.entries[0].title == nil)
        #expect(feed.entries[0].link == nil)
        #expect(feed.entries[0].content == "kept")
    }

    @Test func aByteOrderMarkAndWhitespaceAreSkipped() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("\n  \(simpleFeed)".utf8)
        #expect(try FeedParser.parse(data).format == .json)
    }

    @Test func malformedJSONFailsClearly() {
        #expect(throws: FeedParser.Failure.notAJSONFeed("malformed JSON")) { try FeedParser.parse(Data(#"{"version": "https://jsonfeed.org/version/1.1", "items": ["#.utf8)) }
        #expect(throws: FeedParser.Failure.notAJSONFeed("no JSON Feed version")) { try FeedParser.parse(Data(#"{"error": "unauthorized"}"#.utf8)) }
        #expect(throws: FeedParser.Failure.notAJSONFeed("no JSON Feed version")) { try FeedParser.parse(Data(#"{"version": "2.0", "items": []}"#.utf8)) }
        #expect(throws: FeedParser.Failure.notAJSONFeed("not an object")) { try FeedParser.parse(Data("[]".utf8), contentType: "application/json") }
    }

    @Test func theBodyAndTypeChooseTheParser() {
        let brace = Data("{}".utf8), xml = Data("<rss/>".utf8), list = Data("[1]".utf8)
        #expect(FeedParser.isJSON(brace, contentType: nil))
        #expect(FeedParser.isJSON(brace, contentType: "text/html"))
        #expect(FeedParser.isJSON(list, contentType: "application/feed+json; charset=utf-8"))
        #expect(FeedParser.isJSON(list, contentType: "Application/JSON"))
        #expect(!FeedParser.isJSON(list, contentType: "text/plain"))
        // An XML body labelled JSON is still read as XML.
        #expect(!FeedParser.isJSON(xml, contentType: "application/json"))
        #expect(!FeedParser.isJSON(xml, contentType: nil))
    }
}

@Suite struct JSONFeedMapping {
    private func items(_ json: String, at url: String = "https://example.com/feed.json") async throws -> [Item] {
        let feed = try FeedParser.parse(Data(json.utf8), baseURL: URL(string: url))
        let response = HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return await RSSConnector(client: FakeHTTPClient(routes: [:])).page(feed, response: response, from: feedSource, fetchedAt: t0).items
    }

    @Test func itemsBecomeArticles() async throws {
        let items = try await items(simpleFeed)
        #expect(items.count == 2)
        let first = items[0]
        #expect(first.kind == .article)
        #expect(first.remoteID == "2")
        // A feed-local ID merges by link, as an RSS GUID does.
        #expect(first.mergeKey == "https://example.org/second-item")
        // Without a title the row shows its text.
        #expect(first.title == nil)
        #expect(first.body == "This is a second item.")
        #expect(items[1].body == "Hello, world!")
        // No date: placed by when it was fetched.
        #expect(first.publishedAt == t0)
        #expect(first.authorName == "Example")
    }

    @Test func globalIDsMergeAsTheyAre() async throws {
        let item = try #require(try await items(podcastFeed).first)
        #expect(item.mergeKey == "https://example.com/the-record/2026/10/episode-1")
        #expect(item.title == "Special #1 - A guest")
        // The summary comes before the content, as it does for RSS.
        #expect(item.body == "Ana interviews a guest & friends.")
        #expect(item.publishedAt == utc(2026, 10, 24, 2, 15))
        #expect(item.authorAvatar == "https://example.com/the-record/icon-512.png")
    }

    @Test func bareIDsWithoutLinksStayInTheirFeed() async throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"id": "7", "content_html": "<p>Hi</p>"}, {"id": "8"}]}"#
        let items = try await items(json)
        // An item with nothing to show is dropped.
        #expect(items.count == 1)
        #expect(items[0].mergeKey == "\(feedSource.id)#7")
        #expect(items[0].url == nil)
    }

    @Test func aLinkPostMergesWithinItsFeedButOpensItsSubject() async throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"id": "123", "external_url": "https://example.net/story", "content_text": "Worth a read."}]}"#
        let item = try #require(try await items(json).first)
        // Not the merge key of the article it is about.
        #expect(item.mergeKey == "\(feedSource.id)#123")
        #expect(item.url == "https://example.net/story")
    }

    @Test func twoIDLessLinkPostsAboutTheSameStoryStayApart() async throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"external_url": "https://example.net/story", "content_text": "First take."}, {"external_url": "https://example.net/story", "content_text": "Second take."}]}"#
        let found = try await items(json)
        #expect(found.count == 2)
        #expect(Set(found.map(\.remoteID)).count == 2)
        #expect(Set(found.map(\.mergeKey)).count == 2)
        #expect(found.allSatisfy { $0.url == "https://example.net/story" })
    }

    @Test func anItemWithoutAnIDIsKnownByItsURL() async throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"url": "https://example.com/posts/5", "content_text": "Five"}]}"#
        let item = try #require(try await items(json).first)
        #expect(item.remoteID == "https://example.com/posts/5")
        #expect(item.mergeKey == "https://example.com/posts/5")
    }

    @Test func aModifiedDateStandsInForAMissingPublishedOne() async throws {
        let json = #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"id": "1", "content_text": "x", "date_modified": "2026-10-24T01:00:00Z"}]}"#
        let item = try #require(try await items(json).first)
        #expect(item.publishedAt == utc(2026, 10, 24, 1))
    }
}

@Suite struct JSONFeedSubscribing {
    @Test func aJSONFeedSubscribesAndFetches() async throws {
        let client = FakeHTTPClient(routes: ["https://example.com/feed.json": .init(headers: ["Content-Type": "application/feed+json", "ETag": "\"j1\""], text: simpleFeed)])
        let store = try InfluxStore.inMemory()
        let source = try await RSSSubscriptions(store: store, connector: RSSConnector(client: client)).add("example.com/feed.json", now: t0)
        #expect(source.kind == .rss)
        #expect(source.title == "My Example Feed")
        #expect(try await store.rows().count == 2)
        #expect(client.requests.first?.value(forHTTPHeaderField: "Accept")?.contains("application/feed+json") == true)
    }

    @Test func aSiteAdvertisingAJSONFeedFindsIt() async throws {
        let page = #"<html><head><link rel="alternate" type="application/json" href="/wp-json/wp/v2/pages/2"><link rel="alternate" type="application/feed+json" title="JSON Feed" href="/feed.json"></head></html>"#
        let client = FakeHTTPClient(routes: [
            "https://example.com/": .init(text: page),
            "https://example.com/feed.json": .init(text: simpleFeed),
        ])
        let source = try await RSSSubscriptions(store: try InfluxStore.inMemory(), connector: RSSConnector(client: client)).add("example.com", now: t0)
        #expect(source.url == "https://example.com/feed.json")
        // Discovery reads the page, then the feed; a look at the site's
        // icon may follow, where the test machine can resolve the name.
        #expect(client.requests.prefix(2).map(\.url?.absoluteString) == ["https://example.com/", "https://example.com/feed.json"])
    }

    @Test func discoveryListsJSONFeedsButNotOtherJSON() {
        let html = #"<head><link rel="alternate" type="application/json" href="/api/post/1"><link rel="alternate" type="application/feed+json" href="/feed.json"><link rel="alternate" type="application/rss+xml" href="/feed.xml"></head>"#
        let feeds = FeedDiscovery.feeds(inPage: html, at: URL(string: "https://example.com/")!)
        #expect(feeds.map(\.absoluteString) == ["https://example.com/feed.json", "https://example.com/feed.xml"])
    }

    @Test func aBrokenJSONFeedIsABadResponse() async throws {
        let client = FakeHTTPClient(routes: ["https://example.com/feed.json": .init(headers: ["Content-Type": "application/feed+json"], text: #"{"version": "https://jsonfeed.org/version/1.1", "items": [{"#)])
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [feedSource])
        let result = try await Refresher(store: store).refresh(feedSource, with: RSSConnector(client: client), now: t0)
        #expect(result == .failed(.badResponse("not a JSON Feed: malformed JSON")))
    }

    @Test func theResponseTypeReachesTheParser() async throws {
        // Only the Content-Type says this body is JSON.
        let client = FakeHTTPClient(routes: ["https://example.com/feed.json": .init(headers: ["Content-Type": "application/json"], text: "[]")])
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [feedSource])
        let result = try await Refresher(store: store).refresh(feedSource, with: RSSConnector(client: client), now: t0)
        #expect(result == .failed(.badResponse("not a JSON Feed: not an object")))
    }

    @Test func theAcceptHeaderDoesNotAskForOtherJSON() {
        let accept = RSSConnector.request(for: URL(string: "https://example.com/")!, validators: nil).value(forHTTPHeaderField: "Accept") ?? ""
        #expect(accept.contains("application/feed+json"))
        #expect(!accept.contains("application/json"))
    }
}
