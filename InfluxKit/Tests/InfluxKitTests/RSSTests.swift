import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26T08:53:20Z
private let day: TimeInterval = 24 * 60 * 60

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

private let rss2Feed = """
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
  <title>Six Colors</title>
  <link>https://sixcolors.com/</link>
  <atom:link href="https://sixcolors.com/feed/" rel="self" type="application/rss+xml"/>
  <image><title>Logo</title><url>https://sixcolors.com/logo.png</url></image>
  <item>
    <title>Apple&#8217;s new &amp; improved Mac</title>
    <link>https://sixcolors.com/post/2026/10/mac/</link>
    <guid isPermaLink="false">sixcolors-1234</guid>
    <dc:creator>Jason Snell</dc:creator>
    <pubDate>Fri, 23 Oct 2026 17:30:00 -0400</pubDate>
    <description><![CDATA[<p>The <b>new</b> Mac is here.</p><p>It&rsquo;s fast.</p>]]></description>
    <content:encoded><![CDATA[<p>Full article text.</p>]]></content:encoded>
  </item>
  <item>
    <title>Link post</title>
    <guid>https://sixcolors.com/link/2026/10/thing/</guid>
    <pubDate>Thu, 22 Oct 2026 09:00:00 GMT</pubDate>
  </item>
</channel>
</rss>
"""

private let atomFeed = """
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <title type="text">Daring Fireball</title>
  <link rel="alternate" type="text/html" href="https://daringfireball.net/"/>
  <link rel="self" type="application/atom+xml" href="https://daringfireball.net/feeds/main"/>
  <id>https://daringfireball.net/feeds/main</id>
  <updated>2026-10-24T01:00:00Z</updated>
  <author><name>John Gruber</name></author>
  <entry>
    <title>Tom &amp; Jerry &lt;3</title>
    <link rel="alternate" type="text/html" href="/2026/10/tom_and_jerry"/>
    <link rel="shorturl" href="http://df4.us/abc"/>
    <id>tag:daringfireball.net,2026:/linked//6.41234</id>
    <published>2026-10-23T22:15:00-04:00</published>
    <updated>2026-10-23T22:20:01.5Z</updated>
    <author><name>John Gruber</name></author>
    <content type="html" xml:base="https://daringfireball.net/">&lt;p&gt;Some &lt;em&gt;HTML&lt;/em&gt; content.&lt;/p&gt;</content>
  </entry>
  <entry>
    <title type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">An <i>XHTML</i> title</div></title>
    <link href="https://daringfireball.net/2026/10/second"/>
    <id>tag:daringfireball.net,2026:/second</id>
    <updated>2026-10-22T10:00:00Z</updated>
    <summary type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>First paragraph.</p><p>Second.</p></div></summary>
  </entry>
</feed>
"""

private let rdfFeed = """
<?xml version="1.0"?>
<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns="http://purl.org/rss/1.0/" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel rdf:about="https://example.org/">
    <title>RDF Site</title>
    <link>https://example.org/</link>
  </channel>
  <item rdf:about="https://example.org/1">
    <title>First</title>
    <link>https://example.org/1</link>
    <description>One</description>
    <dc:date>2026-10-20T08:00:00+00:00</dc:date>
    <dc:creator>Ana</dc:creator>
  </item>
</rdf:RDF>
"""

private let feedSource = Source(id: "rss:https://sixcolors.com/feed/", kind: .rss, title: "Six Colors", url: "https://sixcolors.com/feed/", colorIndex: 2)

@Suite struct FeedDates {
    @Test func impossibleDatesAreRejected() {
        #expect(FeedDate.parse("2026-02-31T10:00:00Z") == nil)
        #expect(FeedDate.parse("2026-10-24T24:59:00Z") == nil)
        #expect(FeedDate.parse("2028-02-29T10:00:00Z") == utc(2028, 2, 29, 10))
        #expect(FeedDate.parse("Mon, 31 Apr 2026 10:00:00 GMT") == nil)
    }

    @Test func rfc822Variants() {
        #expect(FeedDate.parse("Sat, 07 Sep 2002 00:00:01 GMT") == utc(2002, 9, 7, 0, 0, 1))
        #expect(FeedDate.parse("Fri, 23 Oct 2026 17:30:00 -0400") == utc(2026, 10, 23, 21, 30))
        #expect(FeedDate.parse("7 Sep 02 00:00 +0100") == utc(2002, 9, 6, 23))
        #expect(FeedDate.parse("Saturday, 07 September 2002 00:00:01 EST") == utc(2002, 9, 7, 5, 0, 1))
        #expect(FeedDate.parse("Sat, 7 Sep 2002 10:00:00 +05:30") == utc(2002, 9, 7, 4, 30))
        #expect(FeedDate.parse("Sat, 07 Sep 2002 00:00:01 XYZ") == utc(2002, 9, 7, 0, 0, 1))
    }

    /// The daylight reading of a US standard-time name: only on dates US
    /// daylight saving covers, and only for the standard names.
    @Test func daylightReadings() {
        #expect(FeedDate.parse("Mon, 26 Oct 2026 17:59:10 EST") == utc(2026, 10, 26, 22, 59, 10))
        #expect(FeedDate.daylightReading("Mon, 26 Oct 2026 17:59:10 EST") == utc(2026, 10, 26, 21, 59, 10))
        #expect(FeedDate.daylightReading("Mon, 26 Oct 2026 14:59:10 PST") == utc(2026, 10, 26, 21, 59, 10))
        #expect(FeedDate.daylightReading("Mon, 26 Oct 2026 17:59:10 EDT") == nil)
        #expect(FeedDate.daylightReading("Mon, 26 Oct 2026 17:59:10 GMT") == nil)
        #expect(FeedDate.daylightReading("Mon, 26 Oct 2026 17:59:10 -0500") == nil)
        #expect(FeedDate.daylightReading("Mon, 05 Jan 2026 12:00:00 EST") == nil)
        // 2026 runs from 8 March to 1 November, both at 2 a.m. local.
        #expect(FeedDate.daylightReading("Sun, 08 Mar 2026 01:59:00 EST") == nil)
        #expect(FeedDate.daylightReading("Sun, 08 Mar 2026 03:00:00 EST") == utc(2026, 3, 8, 7))
        #expect(FeedDate.daylightReading("Sun, 01 Nov 2026 01:00:00 EST") == utc(2026, 11, 1, 5))
        #expect(FeedDate.daylightReading("Sun, 01 Nov 2026 03:00:00 EST") == nil)
        // Before 2007: the first Sunday in April to the last in October.
        #expect(FeedDate.daylightReading("Sun, 07 Apr 2002 12:00:00 EST") == utc(2002, 4, 7, 16))
        #expect(FeedDate.daylightReading("Sun, 27 Oct 2002 12:00:00 EST") == nil)
        // Out-of-range years are rejected before the rule is worked out.
        #expect(FeedDate.daylightReading("Mon, 26 Oct 9223372036854775807 17:59:10 EST") == nil)
        #expect(FeedDate.parse("Mon, 26 Oct 9223372036854775807 17:59:10 EST") == nil)
    }

    @Test func iso8601Variants() {
        #expect(FeedDate.parse("2026-10-24T01:49:34Z") == utc(2026, 10, 24, 1, 49, 34))
        #expect(FeedDate.parse("2026-10-23T22:15:00-04:00") == utc(2026, 10, 24, 2, 15))
        #expect(FeedDate.parse("2026-10-23T22:20:01.5Z") == utc(2026, 10, 23, 22, 20, 1).addingTimeInterval(0.5))
        #expect(FeedDate.parse("2026-10-24 01:49") == utc(2026, 10, 24, 1, 49))
        #expect(FeedDate.parse("2026-10-24") == utc(2026, 10, 24))
        #expect(FeedDate.parse("2026-10-24T01:49:34+0530") == utc(2026, 10, 23, 20, 19, 34))
    }

    @Test func nonsenseIsNil() {
        #expect(FeedDate.parse("") == nil)
        #expect(FeedDate.parse("yesterday") == nil)
        #expect(FeedDate.parse("2026-13-40") == nil)
        #expect(FeedDate.parse("Sep 2002") == nil)
    }
}

@Suite struct HTMLTextTests {
    @Test func tagsGoAndEntitiesDecode() {
        #expect(HTMLText.plainText("<p>The <b>new</b> Mac.</p><p>It&rsquo;s&nbsp;fast &amp; quiet.</p>") == "The new Mac. It’s fast & quiet.")
        #expect(HTMLText.plainText("a<br/>b<script>alert(1)</script><style>p{}</style>c") == "a bc")
        #expect(HTMLText.plainText("1 < 2 and 3 > 2") == "1 < 2 and 3 > 2")
        #expect(HTMLText.plainText("x<!-- a > b -->y") == "x y")
        #expect(HTMLText.plainText("&#x1F600; &#169; &unknown; &") == "😀 © &unknown; &")
    }

    @Test func longTextIsCutAtAWord() {
        let text = HTMLText.plainText("one two three four five", limit: 12)
        #expect(text == "one two…")
    }
}

@Suite struct Parsing {
    @Test func rss2() throws {
        let feed = try FeedParser.parse(Data(rss2Feed.utf8))
        #expect(feed.format == .rss)
        #expect(feed.title == "Six Colors")
        #expect(feed.link == "https://sixcolors.com/")
        #expect(feed.entries.count == 2)
        let first = feed.entries[0]
        #expect(first.title == "Apple’s new & improved Mac")
        #expect(first.id == "sixcolors-1234")
        #expect(first.idIsPermaLink == false)
        #expect(first.author == "Jason Snell")
        #expect(first.published == utc(2026, 10, 23, 21, 30))
        #expect(first.summary == "<p>The <b>new</b> Mac is here.</p><p>It&rsquo;s fast.</p>")
        #expect(first.content == "<p>Full article text.</p>")
        #expect(feed.entries[1].link == nil)
        #expect(feed.entries[1].idIsPermaLink)
    }

    @Test func atomWithHTMLAndXHTML() throws {
        let feed = try FeedParser.parse(Data(atomFeed.utf8))
        #expect(feed.format == .atom)
        #expect(feed.title == "Daring Fireball")
        #expect(feed.link == "https://daringfireball.net/")
        let first = feed.entries[0]
        #expect(HTMLText.plainText(first.title!) == "Tom & Jerry <3")
        #expect(first.link == "/2026/10/tom_and_jerry")
        #expect(first.published == utc(2026, 10, 24, 2, 15))
        #expect(first.author == "John Gruber")
        #expect(HTMLText.plainText(first.content!) == "Some HTML content.")
        let second = feed.entries[1]
        #expect(HTMLText.plainText(second.title!) == "An XHTML title")
        #expect(HTMLText.plainText(second.summary!) == "First paragraph. Second.")
        #expect(second.link == "https://daringfireball.net/2026/10/second")
        #expect(second.published == nil)
        #expect(second.updated == utc(2026, 10, 22, 10))
    }

    @Test func rdf() throws {
        let feed = try FeedParser.parse(Data(rdfFeed.utf8))
        #expect(feed.format == .rdf)
        #expect(feed.title == "RDF Site")
        #expect(feed.entries.map(\.title) == ["First"])
        #expect(feed.entries[0].published == utc(2026, 10, 20, 8))
        #expect(feed.entries[0].author == "Ana")
    }

    @Test func htmlEntitiesThatXMLLacksAreRepaired() throws {
        let broken = "<rss><channel><title>Caf&eacute; &mdash; news</title><item><title>A&nbsp;B &bogus; C & D</title></item></channel></rss>"
        let feed = try FeedParser.parse(Data(broken.utf8))
        #expect(feed.title == "Café — news")
        #expect(feed.entries[0].title == "A\u{A0}B &bogus; C & D")
    }

    @Test func otherEncodingsAreRead() throws {
        let latin1 = "<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><rss><channel><title>Caf\u{E9}</title></channel></rss>"
        let feed = try FeedParser.parse(latin1.data(using: .isoLatin1)!)
        #expect(feed.title == "Café")
    }

    @Test func atomSourceDoesNotOverwriteTheEntry() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Planet</title>
        <entry><id>tag:planet,2026:1</id><title>Copied post</title><updated>2026-10-22T10:00:00Z</updated>
        <author><name>Ana</name></author>
        <source><id>tag:origin,2026:feed</id><title>Origin blog</title><updated>2026-10-01T00:00:00Z</updated>
        <link rel="alternate" href="https://origin.example/"/><author><name>Origin team</name></author></source>
        <link rel="alternate" href="https://planet.example/1"/></entry></feed>
        """
        let entry = try FeedParser.parse(Data(xml.utf8)).entries[0]
        #expect(entry.id == "tag:planet,2026:1")
        #expect(entry.title == "Copied post")
        #expect(entry.updated == utc(2026, 10, 22, 10))
        #expect(entry.author == "Ana")
        #expect(entry.link == "https://planet.example/1")
    }

    @Test func rssItemFieldsAreItsOwn() throws {
        let xml = "<rss xmlns:x=\"urn:x\"><channel><item><title>Mine</title><x:extra><title>Not mine</title><guid>nested</guid></x:extra><guid>real</guid></item></channel></rss>"
        let entry = try FeedParser.parse(Data(xml.utf8)).entries[0]
        #expect(entry.title == "Mine")
        #expect(entry.id == "real")
    }

    @Test func atomXMLBaseResolvesLinks() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://example.com/blog/"><title>B</title>
        <link rel="alternate" href="./"/>
        <entry xml:base="2026/"><id>tag:b,1</id><title>One</title><link rel="alternate" href="one.html"/></entry>
        <entry><id>tag:b,2</id><title>Two</title><link rel="alternate" href="/two.html"/></entry></feed>
        """
        let feed = try FeedParser.parse(Data(xml.utf8), baseURL: URL(string: "https://feeds.example.net/b.xml"))
        #expect(feed.link == "https://example.com/blog/")
        #expect(feed.entries.map(\.link) == ["https://example.com/blog/2026/one.html", "https://example.com/two.html"])
    }

    @Test func xhtmlKeepsLiteralMarkupCharacters() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>tag:x,1</id>
        <title type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">Use &lt;Widget&gt; &amp; <b>more</b></div></title></entry></feed>
        """
        let entry = try FeedParser.parse(Data(xml.utf8)).entries[0]
        #expect(HTMLText.plainText(entry.title!) == "Use <Widget> & more")
    }

    @Test func pagesAndJunkAreNotFeeds() {
        #expect(throws: FeedParser.Failure.notAFeed) { try FeedParser.parse(Data("<html><head></head><body>hi</body></html>".utf8)) }
        #expect(throws: FeedParser.Failure.notAFeed) { try FeedParser.parse(Data("not xml at all".utf8)) }
    }
}

@Suite struct Mapping {
    private func items(_ xml: String, source: Source = feedSource, fetchedAt: Date = t0) async throws -> [Item] {
        let feed = try FeedParser.parse(Data(xml.utf8))
        let response = HTTPURLResponse(url: URL(string: source.url!)!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return await RSSConnector(client: FakeHTTPClient(routes: [:])).page(feed, response: response, from: source, fetchedAt: fetchedAt).items
    }

    private let daylightAsStandardFeed = """
    <rss><channel>
    <item><guid isPermaLink="false">US-EN-1</guid><title>Fresh</title><pubDate>Mon, 26 Oct 2026 17:59:10 EST</pubDate></item>
    <item><guid isPermaLink="false">US-EN-2</guid><title>Older</title><pubDate>Mon, 26 Oct 2026 12:43:01 EST</pubDate></item>
    </channel></rss>
    """

    /// ESPN writes Eastern daylight time as "EST", so its feeds are read
    /// as daylight time, however long after publication they're fetched.
    @Test func espnLabelsDaylightTimeAsStandard() async throws {
        let espn = Source(id: "rss:https://www.espn.com/espn/rss/news", kind: .rss, title: "www.espn.com - TOP", url: "https://www.espn.com/espn/rss/news", colorIndex: 2)
        let daylight = [utc(2026, 10, 26, 21, 59, 10), utc(2026, 10, 26, 16, 43, 1)]
        for fetchedAt in [utc(2026, 10, 26, 22, 9, 42), utc(2026, 10, 26, 23, 30)] {
            #expect(try await items(daylightAsStandardFeed, source: espn, fetchedAt: fetchedAt).map(\.publishedAt) == daylight)
        }
        // The same dates from any other site keep RFC 822's offset, even
        // one dated in the future.
        #expect(try await items(daylightAsStandardFeed, fetchedAt: utc(2026, 10, 26, 22, 9, 42)).map(\.publishedAt)
                == [utc(2026, 10, 26, 22, 59, 10), utc(2026, 10, 26, 17, 43, 1)])
        #expect(!ArticleMapper.labelsDaylightTimeAsStandard(URL(string: "https://notespn.com/feed")))
    }

    /// Elsewhere a standard-time name keeps its fixed offset: most of
    /// Arizona is on MST all year.
    @Test func standardTimeNamesKeepTheirOffsetOtherwise() async throws {
        let xml = """
        <rss><channel>
        <item><guid isPermaLink="false">az-1</guid><title>Phoenix</title><pubDate>Mon, 26 Oct 2026 14:00:00 MST</pubDate></item>
        </channel></rss>
        """
        let items = try await items(xml, fetchedAt: utc(2026, 10, 26, 22, 9, 42))
        #expect(items.map(\.publishedAt) == [utc(2026, 10, 26, 21)])
    }

    @Test func rssEntriesBecomeArticles() async throws {
        let items = try await items(rss2Feed)
        #expect(items.count == 2)
        let first = items[0]
        #expect(first.kind == .article)
        #expect(first.sourceID == feedSource.id)
        #expect(first.remoteID == "sixcolors-1234")
        // A feed-local GUID merges by link instead.
        #expect(first.mergeKey == "https://sixcolors.com/post/2026/10/mac/")
        #expect(first.title == "Apple’s new & improved Mac")
        #expect(first.body == "The new Mac is here. It’s fast.")
        #expect(first.authorName == "Jason Snell")
        #expect(first.authorHandle == "sixcolors.com")
        #expect(first.publishedAt == utc(2026, 10, 23, 21, 30))
        #expect(first.fetchedAt == t0)
        // A permalink GUID is the link when there is no <link>.
        #expect(items[1].url == "https://sixcolors.com/link/2026/10/thing/")
        #expect(items[1].mergeKey == "https://sixcolors.com/link/2026/10/thing/")
        #expect(items[1].authorName == "Six Colors")
        #expect(items[1].body == "")
    }

    @Test func atomLinksResolveAndTagIDsMerge() async throws {
        let source = Source(id: "rss:https://daringfireball.net/feeds/main", kind: .rss, title: "Daring Fireball", url: "https://daringfireball.net/feeds/main", colorIndex: 1)
        let items = try await items(atomFeed, source: source)
        #expect(items[0].url == "https://daringfireball.net/2026/10/tom_and_jerry")
        #expect(items[0].mergeKey == "tag:daringfireball.net,2026:/linked//6.41234")
        #expect(items[0].title == "Tom & Jerry <3")
        // Without a published date, the updated one stands in.
        #expect(items[1].publishedAt == utc(2026, 10, 22, 10))
    }

    @Test func bareIDsWithoutLinksStayInTheirFeed() async throws {
        let xml = "<rss><channel><item><guid isPermaLink=\"false\">42</guid><description>Hello</description></item><item><description>No id</description></item><item><title></title></item></channel></rss>"
        let items = try await items(xml)
        #expect(items.count == 2)
        #expect(items[0].mergeKey == "\(feedSource.id)#42")
        #expect(items[0].publishedAt == t0)
        #expect(items[1].remoteID.hasPrefix("hash:"))
        #expect(try await self.items(xml)[1].remoteID == items[1].remoteID)
    }

    @Test func bareGUIDsAreNotLinks() async throws {
        let xml = "<rss><channel><item><guid>42</guid><title>Hello</title></item></channel></rss>"
        let item = try await items(xml)[0]
        #expect(item.url == nil)
        #expect(item.mergeKey == "\(feedSource.id)#42")
    }

    @Test func relativeLinksFollowRedirects() async throws {
        let feed = try FeedParser.parse(Data("<rss><channel><item><title>T</title><link>/post</link></item></channel></rss>".utf8))
        let response = HTTPURLResponse(url: URL(string: "https://new.example/feed")!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        let item = await RSSConnector(client: FakeHTTPClient(routes: [:])).page(feed, response: response, from: feedSource, fetchedAt: t0).items[0]
        #expect(item.url == "https://new.example/post")
    }

    @Test func sourceColorsFitThePalette() {
        let indices = (0..<200).map { Source.colorIndex(for: "rss:https://site\($0).example/feed") }
        #expect(Source.paletteSize == 7)
        #expect(Set(indices) == Set(0..<7))
    }

    @Test func longContentIsSummarised() async throws {
        let long = String(repeating: "word ", count: 500)
        let items = try await items("<rss><channel><item><title>T</title><description>\(long)</description></item></channel></rss>")
        #expect(items[0].body.count <= RSSConnector.summaryLimit + 1)
        #expect(items[0].body.hasSuffix("…"))
    }
}

@Suite struct OPMLTests {
    @Test func nestedOutlinesFlattenOnce() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
          <head><title>Subscriptions</title></head>
          <body>
            <outline text="Apple">
              <outline type="rss" text="Six Colors" title="Six Colors" xmlUrl="https://sixcolors.com/feed/" htmlUrl="https://sixcolors.com/"/>
              <outline type="rss" text="DF" xmlURL="https://daringfireball.net/feeds/main"/>
            </outline>
            <outline type="rss" title="" text="Dup" xmlUrl="https://sixcolors.com/feed/"/>
            <outline text="No feed here"/>
          </body>
        </opml>
        """
        let outlines = try OPML.parse(Data(opml.utf8))
        #expect(outlines.map(\.feedURL) == ["https://sixcolors.com/feed/", "https://daringfireball.net/feeds/main"])
        #expect(outlines.map(\.title) == ["Six Colors", "DF"])
        #expect(outlines[0].siteURL == "https://sixcolors.com/")
    }

    @Test func otherXMLIsRejected() {
        #expect(throws: OPML.Failure.notOPML) { try OPML.parse(Data(rss2Feed.utf8)) }
    }
}

@Suite struct Discovery {
    @Test func linkTagsInTheHeadAreFound() {
        let html = """
        <!doctype html><html><head>
        <link rel="stylesheet" href="/s.css">
        <link rel="alternate" type="application/rss+xml" title="RSS" href="/feed/">
        <LINK REL='alternate' TYPE='application/atom+xml' HREF='https://example.com/atom.xml?a=1&amp;b=2'>
        <link rel="alternate" type="text/html" hreflang="fr" href="/fr/">
        <link rel=alternate type=application/rss+xml href=/feed/>
        </head><body><link rel="alternate" type="application/rss+xml" href="/body-feed"></body></html>
        """
        let feeds = FeedDiscovery.feeds(inPage: html, at: URL(string: "https://example.com/blog/post")!)
        #expect(feeds.map(\.absoluteString) == ["https://example.com/feed/", "https://example.com/atom.xml?a=1&b=2"])
    }

    @Test func baseHrefIsHonoured() {
        let html = #"<head><base href="https://cdn.example.com/site/"><link rel="alternate" type="application/rss+xml" href="rss.xml"></head>"#
        #expect(FeedDiscovery.feeds(inPage: html, at: URL(string: "https://example.com/")!).map(\.absoluteString) == ["https://cdn.example.com/site/rss.xml"])
    }
}

@Suite struct RSSFetching {
    private let feedURL = "https://sixcolors.com/feed/"

    private func store() async throws -> InfluxStore {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [feedSource])
        return store
    }

    @Test func fetchesAreConditional() async throws {
        let client = FakeHTTPClient { request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" {
                return .init(status: 304)
            }
            return .init(headers: ["ETag": "\"v1\"", "Last-Modified": "Fri, 23 Oct 2026 21:30:00 GMT"], text: rss2Feed)
        }
        let store = try await store()
        let refresher = Refresher(store: store)
        let connector = RSSConnector(client: client)
        #expect(try await refresher.refresh(feedSource, with: connector, now: t0) == .fetched(newItems: 2))
        #expect(try await refresher.refresh(feedSource, with: connector, now: t0 + 600) == .fetched(newItems: 0))
        let second = try #require(client.requests.last)
        #expect(second.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"")
        #expect(second.value(forHTTPHeaderField: "If-Modified-Since") == "Fri, 23 Oct 2026 21:30:00 GMT")
        #expect(second.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(client.requests.first?.value(forHTTPHeaderField: "If-None-Match") == nil)
        let rows = try await store.rows()
        #expect(rows.map(\.title) == ["Link post", "Apple’s new & improved Mac"])
        #expect(rows.allSatisfy { $0.kind == .article && !$0.isRead })
        // A 304 keeps the validators.
        let state = try #require(try await store.fetchState(sourceID: feedSource.id))
        #expect(state.newerCursor.flatMap(RSSConnector.Validators.init(cursor:))?.etag == "\"v1\"")
        #expect(state.reachedOldest)
    }

    @Test func refetchingStoresNothingTwice() async throws {
        let client = FakeHTTPClient(routes: [feedURL: .init(text: rss2Feed)])
        let store = try await store()
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(feedSource, with: RSSConnector(client: client), now: t0)
        #expect(try await refresher.refresh(feedSource, with: RSSConnector(client: client), now: t0 + 60) == .fetched(newItems: 0))
        #expect(try await store.rows().count == 2)
    }

    @Test func errorsAreQuietStates() async throws {
        let client = FakeHTTPClient(routes: [feedURL: .init(text: "<html>moved</html>")])
        let store = try await store()
        let refresher = Refresher(store: store)
        #expect(try await refresher.refresh(feedSource, with: RSSConnector(client: client), now: t0) == .failed(.badResponse("not a feed")))
        client.respond { _ in .init(status: 410) }
        #expect(try await refresher.refresh(feedSource, with: RSSConnector(client: client), now: t0) == .failed(.notFound))
        client.respond { _ in throw ConnectorError.offline }
        #expect(try await refresher.refresh(feedSource, with: RSSConnector(client: client), now: t0) == .failed(.offline))
        #expect(try await store.fetchState(sourceID: feedSource.id)?.problem == .offline)
    }

    @Test func aFeedThatNeverFinishesGivesUpAsOffline() async throws {
        let store = try await store()
        let connector = RSSConnector(client: TricklingClient(), fetchLimit: .milliseconds(50))
        let started = ContinuousClock.now
        #expect(try await Refresher(store: store).refresh(feedSource, with: connector, now: t0) == .failed(.offline))
        #expect(ContinuousClock.now - started < .milliseconds(1900))
        #expect(try await store.fetchState(sourceID: feedSource.id)?.problem == .offline)
    }

    @Test func articlesReadAndUnread() async throws {
        let client = FakeHTTPClient(routes: [feedURL: .init(text: rss2Feed)])
        let store = try await store()
        _ = try await Refresher(store: store).refresh(feedSource, with: RSSConnector(client: client), now: t0)
        let row = try #require(try await store.rows().last)
        try await store.setArticle(mergeKey: row.mergeKey, read: true, at: t0)
        #expect(try await store.rows().map(\.isRead) == [false, true])
        try await store.setArticle(mergeKey: row.mergeKey, read: false, at: t0 + 1)
        #expect(try await store.rows().map(\.isRead) == [false, false])
    }
}

@Suite struct Subscribing {
    @Test func addingAFeedURLStoresItsArticlesWithOneFetch() async throws {
        let client = FakeHTTPClient(routes: ["https://sixcolors.com/feed/": .init(headers: ["ETag": "\"a\""], text: rss2Feed)])
        let store = try InfluxStore.inMemory()
        let subscriptions = RSSSubscriptions(store: store, connector: RSSConnector(client: client))
        let source = try await subscriptions.add("sixcolors.com/feed/", now: t0)
        #expect(source.id == "rss:https://sixcolors.com/feed/")
        #expect(source.title == "Six Colors")
        #expect(source.colorIndex == Source.colorIndex(for: source.id))
        #expect(client.requests.count == 1)
        #expect(try await store.rows().count == 2)
        #expect(try await store.fetchState(sourceID: source.id)?.newerCursor != nil)
        // Adding it again changes nothing and fetches nothing.
        #expect(try await subscriptions.add("https://SixColors.com/feed/", now: t0) == source)
        #expect(client.requests.count == 1)
    }

    @Test func aSiteAddressFindsItsFeed() async throws {
        let page = #"<html><head><link rel="alternate" type="application/atom+xml" href="/feeds/main"></head></html>"#
        let client = FakeHTTPClient(routes: [
            "https://daringfireball.net/": .init(text: page),
            "https://daringfireball.net/feeds/main": .init(text: atomFeed),
        ])
        let store = try InfluxStore.inMemory()
        let source = try await RSSSubscriptions(store: store, connector: RSSConnector(client: client)).add("daringfireball.net", now: t0)
        #expect(source.url == "https://daringfireball.net/feeds/main")
        #expect(source.title == "Daring Fireball")
        #expect(try await store.rows().count == 2)
    }

    @Test func aSiteWithoutLinksIsGuessedAt() async throws {
        let client = FakeHTTPClient(routes: [
            "https://example.com/": .init(text: "<html><head></head></html>"),
            "https://example.com/rss.xml": .init(text: rdfFeed),
        ])
        let source = try await RSSSubscriptions(store: try InfluxStore.inMemory(), connector: RSSConnector(client: client)).add("example.com", now: t0)
        #expect(source.url == "https://example.com/rss.xml")
    }

    @Test func badAddressesFailInline() async throws {
        let client = FakeHTTPClient(routes: ["https://example.com/": .init(text: "<html></html>")])
        let subscriptions = RSSSubscriptions(store: try InfluxStore.inMemory(), connector: RSSConnector(client: client))
        await #expect(throws: RSSSubscriptions.Failure.invalidURL) { try await subscriptions.add("not a url", now: t0) }
        await #expect(throws: RSSSubscriptions.Failure.invalidURL) { try await subscriptions.add("ftp://example.com", now: t0) }
        await #expect(throws: RSSSubscriptions.Failure.noFeedFound) { try await subscriptions.add("example.com", now: t0) }
        await #expect(throws: ConnectorError.notFound) { try await subscriptions.add("missing.example.com", now: t0) }
    }

    @Test func addressesNormalise() {
        #expect(RSSSubscriptions.normalize("feed://example.com/rss")?.absoluteString == "https://example.com/rss")
        #expect(RSSSubscriptions.normalize("feed:https://example.com/rss")?.absoluteString == "https://example.com/rss")
        #expect(RSSSubscriptions.normalize("  HTTP://Example.COM  ")?.absoluteString == "https://example.com/")
        #expect(RSSSubscriptions.normalize("http://feedpress.me/df")?.absoluteString == "https://feedpress.me/df")
        #expect(RSSSubscriptions.normalize("http://example.com:80/feed")?.absoluteString == "https://example.com/feed")
        #expect(RSSSubscriptions.normalize("feed:http://example.com/rss")?.absoluteString == "https://example.com/rss")
        #expect(RSSSubscriptions.normalize("https://example.com:80/feed")?.absoluteString == "https://example.com:80/feed")
        #expect(RSSSubscriptions.normalize("https://example.com/a#frag")?.absoluteString == "https://example.com/a")
        #expect(RSSSubscriptions.normalize("localhost") == nil)
        #expect(RSSSubscriptions.normalize("words") == nil)
    }

    @Test func opmlImportSubscribesAndFetchesEach() async throws {
        let opml = """
        <opml version="1.0"><body>
          <outline text="Six Colors" xmlUrl="https://sixcolors.com/feed/"/>
          <outline text="RDF" xmlUrl="https://example.org/rdf"/>
          <outline text="Gone" xmlUrl="https://gone.example.com/feed"/>
        </body></opml>
        """
        let client = FakeHTTPClient(routes: [
            "https://sixcolors.com/feed/": .init(text: rss2Feed),
            "https://example.org/rdf": .init(text: rdfFeed),
        ])
        let store = try InfluxStore.inMemory()
        let subscriptions = RSSSubscriptions(store: store, connector: RSSConnector(client: client))
        let imported = try await subscriptions.importOPML(Data(opml.utf8), now: t0)
        #expect(imported.map(\.title) == ["Six Colors", "RDF", "Gone"])
        #expect(try await store.sources().count == 3)
        #expect(try await store.rows().count == 3)
        #expect(try await store.fetchState(sourceID: "rss:https://gone.example.com/feed")?.problem == .notFound)
        // Importing the same file again adds nothing.
        #expect(try await subscriptions.importOPML(Data(opml.utf8), now: t0).isEmpty)
    }

    @Test func coloursSpreadAcrossThePalette() {
        let colours = Set((0..<64).map { Source.colorIndex(for: "rss:https://example\($0).com/feed") })
        #expect(colours.count == Source.paletteSize)
        #expect(Source.colorIndex(for: "rss:x") == Source.colorIndex(for: "rss:x"))
    }
}

@Suite struct FeedsThatMove {
    private let old = "https://sixcolors.com/feed/"
    private let new = "https://feeds.sixcolors.com/main"

    private func refreshed(_ routes: [String: FakeHTTPClient.Response], others: [Source] = []) async throws -> (InfluxStore, Source?) {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [feedSource] + others)
        _ = try await Refresher(store: store).refresh(feedSource, with: RSSConnector(client: FakeHTTPClient(routes: routes)), now: t0)
        return (store, try await store.sources().first { $0.id == feedSource.id })
    }

    @Test func aPermanentMoveUpdatesTheAddress() async throws {
        let (store, source) = try await refreshed([
            old: .init(status: 301, headers: ["Location": new], body: Data()),
            new: .init(text: rss2Feed),
        ])
        #expect(source?.url == new)
        #expect(source?.id == feedSource.id)
        #expect(try await store.rows().count == 2)
    }

    @Test func aTemporaryRedirectKeepsTheAddress() async throws {
        let (_, source) = try await refreshed([
            old: .init(status: 302, headers: ["Location": new], body: Data()),
            new: .init(text: rss2Feed),
        ])
        #expect(source?.url == old)
    }

    @Test func onlyThePermanentStartOfAChainCounts() async throws {
        let (_, source) = try await refreshed([
            old: .init(status: 308, headers: ["Location": new], body: Data()),
            new: .init(status: 307, headers: ["Location": "https://cdn.example/sixcolors.xml"], body: Data()),
            "https://cdn.example/sixcolors.xml": .init(text: rss2Feed),
        ])
        #expect(source?.url == new)
    }

    @Test func aMoveOntoAnotherSubscriptionIsIgnored() async throws {
        let other = Source(id: "rss:" + new, kind: .rss, title: "Also Six Colors", url: new, colorIndex: 1)
        let (store, source) = try await refreshed([
            old: .init(status: 301, headers: ["Location": new], body: Data()),
            new: .init(text: rss2Feed),
        ], others: [other])
        #expect(source?.url == old)
        #expect(try await store.sources().filter { $0.url == new }.count == 1)
    }

    @Test func theOldAddressStillFindsAMovedFeed() async throws {
        let client = FakeHTTPClient(routes: [
            old: .init(status: 301, headers: ["Location": new], body: Data()),
            new: .init(text: rss2Feed),
        ])
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [feedSource])
        let connector = RSSConnector(client: client)
        _ = try await Refresher(store: store).refresh(feedSource, with: connector, now: t0)
        let subscriptions = RSSSubscriptions(store: store, connector: connector)
        #expect(try await subscriptions.add(old, now: t0).url == new)
        let opml = #"<opml version="2.0"><body><outline type="rss" text="Six Colors" xmlUrl="https://sixcolors.com/feed/"/></body></opml>"#
        #expect(try await subscriptions.importOPML(Data(opml.utf8), now: t0).isEmpty)
        #expect(try await store.sources().map(\.url) == [new])
    }

    @Test func olderHTTPSubscriptionsAreNotDuplicated() async throws {
        let plain = Source(id: "rss:http://example.com/rss", kind: .rss, title: "Plain", url: "http://example.com/rss", colorIndex: 0)
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [plain])
        let subscriptions = RSSSubscriptions(store: store, connector: RSSConnector(client: FakeHTTPClient(routes: [:])))
        #expect(try await subscriptions.add("http://example.com/rss", now: t0) == plain)
        let opml = #"<opml version="2.0"><body><outline type="rss" text="Plain" xmlUrl="http://example.com/rss"/></body></opml>"#
        #expect(try await subscriptions.importOPML(Data(opml.utf8), now: t0).isEmpty)
        #expect(try await store.sources() == [plain])
    }

    @Test func olderHTTPSubscriptionsAreFetchedOverHTTPS() async throws {
        let plain = Source(id: "rss:http://example.com/rss", kind: .rss, title: "Plain", url: "http://example.com/rss", colorIndex: 0)
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [plain])
        let client = FakeHTTPClient(routes: ["https://example.com/rss": .init(text: rss2Feed)])
        #expect(try await Refresher(store: store).refresh(plain, with: RSSConnector(client: client), now: t0) == .fetched(newItems: 2))
        #expect(client.requests.map(\.url?.absoluteString) == ["https://example.com/rss"])
        #expect(try await store.sources().first?.url == "https://example.com/rss")
        #expect(try await store.sources().first?.id == plain.id)
    }

    @Test func olderHTTPSubscriptionsThatMovedAreNotDuplicated() async throws {
        let moved = Source(id: "rss:http://example.com/rss", kind: .rss, title: "Moved", url: "https://feeds.example.com/rss", colorIndex: 0)
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [moved])
        let subscriptions = RSSSubscriptions(store: store, connector: RSSConnector(client: FakeHTTPClient(routes: [:])))
        let opml = #"<opml version="2.0"><body><outline type="rss" text="Moved" xmlUrl="http://example.com/rss"/></body></opml>"#
        #expect(try await subscriptions.importOPML(Data(opml.utf8), now: t0).isEmpty)
        #expect(try await subscriptions.add("example.com/rss", now: t0) == moved)
        #expect(try await store.sources() == [moved])
    }

    @Test func aStalePageMovesNothing() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [feedSource])
        let first = Refresher.request(for: feedSource, direction: .newer, cursor: nil, now: t0)
        try await store.record(FetchedPage(items: [], newer: Cursor(rawValue: "v2"), older: nil), for: first, sourceID: feedSource.id)
        // A page fetched before that one landed, carrying a move it saw then.
        #expect(try await store.record(FetchedPage(items: [], newer: Cursor(rawValue: "v1"), older: nil, movedTo: new), for: first, sourceID: feedSource.id) == 0)
        #expect(try await store.sources().first?.url == old)
    }

    @Test func cleartextRedirectsAreUpgraded() async throws {
        let (_, source) = try await refreshed([
            old: .init(status: 301, headers: ["Location": "http://feeds.sixcolors.com/main"], body: Data()),
            new: .init(text: rss2Feed),
        ])
        #expect(source?.url == new)
    }

    @Test func addingAMovedFeedSubscribesToWhereItWent() async throws {
        let client = FakeHTTPClient(routes: [
            old: .init(status: 301, headers: ["Location": new], body: Data()),
            new: .init(text: rss2Feed),
        ])
        let store = try InfluxStore.inMemory()
        let subscriptions = RSSSubscriptions(store: store, connector: RSSConnector(client: client))
        let source = try await subscriptions.add(old, now: t0)
        #expect(source.url == new)
        #expect(source.id == "rss:" + new)
        #expect(try await subscriptions.add(new, now: t0) == source)
    }
}

/// A server that keeps the connection open, as one that sends a byte at a
/// time does: it answers after 2 s, whether or not it was cancelled.
private struct TricklingClient: HTTPClient {
    private func trickle() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await trickle()
        return (Data(rss2Feed.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }
    func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        try await send(request)
    }
}
