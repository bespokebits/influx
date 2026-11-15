import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import InfluxKit

@Suite struct ImageSizes {
    @Test func readsEachFormatsHeader() {
        #expect(ImageSize.parse(MediaFixtures.png(width: 1200, height: 630))! == (1200, 630))
        #expect(ImageSize.parse(MediaFixtures.gif(width: 320, height: 240))! == (320, 240))
        #expect(ImageSize.parse(MediaFixtures.jpeg(width: 1600, height: 900))! == (1600, 900))
        #expect(ImageSize.parse(MediaFixtures.webpLossy(width: 800, height: 450))! == (800, 450))
        #expect(ImageSize.parse(MediaFixtures.webpLossless(width: 640, height: 480))! == (640, 480))
        #expect(ImageSize.parse(MediaFixtures.webpExtended(width: 4000, height: 3000))! == (4000, 3000))
    }

    @Test func jpegsTurnedOnTheirSideSwapSides() {
        #expect(ImageSize.parse(MediaFixtures.jpeg(width: 4032, height: 3024, orientation: 6))! == (3024, 4032))
        #expect(ImageSize.parse(MediaFixtures.jpeg(width: 4032, height: 3024, orientation: 3))! == (4032, 3024))
    }

    @Test func otherBytesHaveNoSize() {
        #expect(ImageSize.parse(Data("<html>".utf8)) == nil)
        #expect(ImageSize.parse(MediaFixtures.png(width: 0, height: 10)) == nil)
        // A JPEG cut off before its frame header.
        #expect(ImageSize.parse(MediaFixtures.jpeg(width: 10, height: 10).prefix(20)) == nil)
    }
}

@Suite struct OpenGraphPages {
    private let page = URL(string: "https://www.site.example/post/1")!

    @Test func readsTitleSiteAndSizedImage() throws {
        let html = """
        <html><head>
        <meta property="og:title" content="Tom &amp; Jerry">
        <meta property="og:site_name" content="The Site">
        <meta property="og:url" content="/post/1?ref=og">
        <meta property="og:image" content="/img/1.jpg">
        <meta property="og:image:width" content="1200"><meta property="og:image:height" content="630">
        <meta property="og:image:alt" content="A cat">
        <title>Ignored</title></head><body><meta property="og:title" content="Body"></body></html>
        """
        let og = try #require(OpenGraph.parse(html, at: page))
        #expect(og.title == "Tom & Jerry")
        #expect(og.siteName == "The Site")
        #expect(og.url == "https://www.site.example/post/1?ref=og")
        #expect(og.imageURL == "https://www.site.example/img/1.jpg")
        #expect(og.imageWidth == 1200 && og.imageHeight == 630)
        #expect(og.imageAlt == "A cat")
    }

    @Test func fallsBackToTwitterTagsAndTitle() throws {
        let twitter = try #require(OpenGraph.parse(#"<head><meta name="twitter:title" content="Tw"><meta name="twitter:image" content="https://cdn.example/t.png"></head>"#, at: page))
        #expect(twitter.title == "Tw")
        #expect(twitter.imageURL == "https://cdn.example/t.png")
        let plain = try #require(OpenGraph.parse("<head><title> Just a <b>page</b> </title></head>", at: page))
        #expect(plain.title == "Just a page")
        #expect(plain.imageURL == nil)
        #expect(OpenGraph.parse("<head></head><body>no title</body>", at: page) == nil)
    }
}

@Suite struct Resolving {
    @Test func cardsGetSizedImagesAndAreCached() async throws {
        let http = FakeHTTPClient(routes: [
            "https://www.site.example/a": .init(text: #"<head><meta property="og:title" content="A"><meta property="og:image" content="https://cdn.example/a.webp"></head>"#),
            "https://cdn.example/a.webp": .init(body: MediaFixtures.webpExtended(width: 1200, height: 800)),
        ])
        let resolver = MediaResolver.testing(http)
        let card = await resolver.card(for: "https://www.site.example/a")
        #expect(card == Item.LinkCard(url: "https://www.site.example/a", site: "site.example", title: "A",
                                      image: Item.Media(kind: .image, url: "https://cdn.example/a.webp", width: 1200, height: 800)))
        #expect(http.requests.last?.value(forHTTPHeaderField: "Range") == "bytes=0-65535")
        _ = await resolver.card(for: "https://www.site.example/a")
        #expect(http.requests.count == 2)
    }

    @Test func aCardWhoseImageCantBeSizedKeepsItsTitle() async {
        let http = FakeHTTPClient(routes: [
            "https://site.example/b": .init(text: #"<head><meta property="og:title" content="B"><meta property="og:image" content="https://cdn.example/b.heic"></head>"#),
            "https://cdn.example/b.heic": .init(text: "not an image we read"),
        ])
        let card = await MediaResolver.testing(http).card(for: "https://site.example/b")
        #expect(card?.title == "B")
        #expect(card?.image == nil)
    }

    @Test func failuresGiveNothing() async {
        let http = FakeHTTPClient(routes: [:])
        let resolver = MediaResolver.testing(http)
        #expect(await resolver.card(for: "https://gone.example/") == nil)
        #expect(await resolver.card(for: "mailto:a@b.example") == nil)
        let media = await resolver.sized([UnsizedMedia(kind: .image, url: "https://gone.example/x.jpg")])
        #expect(media.isEmpty)
    }

    @Test func sizedMediaPassesThroughAndVideosAreSizedFromTheirPreview() async {
        let http = FakeHTTPClient(routes: ["https://cdn.example/v.jpg": .init(body: MediaFixtures.jpeg(width: 1920, height: 1080))])
        let media = await MediaResolver.testing(http).sized([
            UnsizedMedia(kind: .image, url: "https://cdn.example/i.png", width: 10, height: 20),
            UnsizedMedia(kind: .video, url: "https://cdn.example/v.mp4", previewURL: "https://cdn.example/v.jpg"),
        ])
        #expect(media.map(\.width) == [10, 1920])
        #expect(media[1].kind == .video && media[1].previewURL == "https://cdn.example/v.jpg")
        #expect(http.requests.map(\.url?.absoluteString) == ["https://cdn.example/v.jpg"])
    }
}

@Suite struct ArticleImages {
    private let source = Source(id: "rss:https://site.example/feed", kind: .rss, title: "Site", url: "https://site.example/feed", colorIndex: 0)

    private func items(_ xml: String, routes: [String: FakeHTTPClient.Response] = [:]) async throws -> [Item] {
        let feed = try FeedParser.parse(Data(xml.utf8), baseURL: URL(string: source.url!))
        let response = HTTPURLResponse(url: URL(string: source.url!)!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        let http = FakeHTTPClient(routes: routes)
        return await RSSConnector(client: http, resolver: .testing(http)).page(feed, response: response, from: source, fetchedAt: Date(timeIntervalSince1970: 0)).items
    }

    @Test func mediaRSSWithSizesNeedsNoFetch() async throws {
        let xml = """
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item><title>A</title>
        <enclosure url="https://site.example/e.jpg" type="image/jpeg"/>
        <media:thumbnail url="https://site.example/t.jpg" width="150" height="100"/>
        <media:content url="/c.jpg" medium="image" width="1200" height="675"/>
        </item></channel></rss>
        """
        let items = try await items(xml)
        #expect(items[0].media == [Item.Media(kind: .image, url: "https://site.example/c.jpg", width: 1200, height: 675)!])
    }

    @Test func inlineImagesAreSizedAndTinyOnesSkipped() async throws {
        let xml = """
        <rss><channel><item><title>B</title><description><![CDATA[<p><img src="https://px.example/1x1.gif" width="1" height="1"> <img src="/big.png"> text</p>]]></description></item></channel></rss>
        """
        let items = try await items(xml, routes: ["https://site.example/big.png": .init(body: MediaFixtures.png(width: 900, height: 600))])
        #expect(items[0].media.map(\.url) == ["https://site.example/big.png"])
        #expect(items[0].media.first?.aspect == 1.5)
    }

    @Test func atomEnclosuresCount() async throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>F</title><entry><id>tag:x,1</id><title>C</title>
        <link rel="enclosure" type="image/gif" href="https://site.example/c.gif"/></entry></feed>
        """
        let items = try await items(xml, routes: ["https://site.example/c.gif": .init(body: MediaFixtures.gif(width: 400, height: 300))])
        #expect(items[0].media.first?.width == 400)
    }

    @Test func mediaRSSVideosComeWithTheirStill() async throws {
        let xml = """
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item><title>V</title>
        <media:content url="https://site.example/c.jpg" medium="image" width="1200" height="675"/>
        <enclosure url="https://site.example/e.mp4" type="video/mp4"/>
        <media:content url="https://site.example/s.m3u8" type="application/x-mpegURL" width="640" height="360"/>
        <media:group><media:content url="/v.mp4" type=" Video/MP4 " width="1920" height="1080">
        <media:thumbnail url="/v.jpg"/></media:content></media:group>
        </item></channel></rss>
        """
        let items = try await items(xml)
        #expect(items[0].media == [Item.Media(kind: .video, url: "https://site.example/v.mp4", previewURL: "https://site.example/v.jpg", width: 1920, height: 1080)!])
    }

    @Test func unsizedVideosAreSizedFromAStillOrMadeWide() async throws {
        let withStill = """
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item><title>W</title>
        <enclosure url="https://site.example/w.mov" type=" video/quicktime; codecs=&quot;avc1.42E01E&quot;"/><media:thumbnail url="https://site.example/w.jpg"/>
        </item></channel></rss>
        """
        let sized = try await items(withStill, routes: ["https://site.example/w.jpg": .init(body: MediaFixtures.jpeg(width: 1080, height: 1920))])
        #expect(sized[0].media == [Item.Media(kind: .video, url: "https://site.example/w.mov", previewURL: "https://site.example/w.jpg", width: 1080, height: 1920)!])

        let bare = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>F</title><entry><id>tag:x,2</id><title>X</title>
        <link rel="enclosure" type="video/mp4" href="https://site.example/x.mp4"/></entry></feed>
        """
        let wide = try await items(bare)
        #expect(wide[0].media == [Item.Media(kind: .video, url: "https://site.example/x.mp4", width: 1280, height: 720)!])
    }

    @Test func videosAppleCantPlayAreLeftOut() async throws {
        let xml = """
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item><title>Y</title>
        <enclosure url="https://site.example/y.mp3" type="audio/mpeg"/>
        <enclosure url="https://site.example/y.webm" type="video/webm"/>
        <enclosure url="https://site.example/y.m3u8"/>
        <media:content url="https://site.example/y.swf" medium="video" type="application/x-shockwave-flash"/>
        <media:content url="https://site.example/y.png" medium="image" width="800" height="600"/>
        </item></channel></rss>
        """
        let items = try await items(xml)
        #expect(items[0].media.map(\.kind) == [.image])
    }

    @Test func undeclaredMediaRSSIsReadAndBeatsASmallEnclosure() async throws {
        // As AV Club writes it: no xmlns:media, an untyped media:content, and
        // a 151-pixel enclosure of something else.
        let xml = """
        <rss version="2.0"><channel><title>S</title><item><title>Lead</title>
        <media:title>Not the title</media:title>
        <media:thumbnail>https://site.example/lead.jpg</media:thumbnail>
        <media:content url="https://site.example/lead.jpg"><media:credit>(Credit)</media:credit></media:content>
        <link>https://site.example/lead</link>
        <enclosure url="https://cdn.example/thumb.jpg" length="1024" type="image/jpeg"/>
        </item></channel></rss>
        """
        let items = try await items(xml, routes: [
            "https://site.example/lead.jpg": .init(body: MediaFixtures.jpeg(width: 1200, height: 675)),
            "https://cdn.example/thumb.jpg": .init(body: MediaFixtures.jpeg(width: 151, height: 151)),
        ])
        #expect(items[0].title == "Lead")
        #expect(items[0].media == [Item.Media(kind: .image, url: "https://site.example/lead.jpg", width: 1200, height: 675)!])
    }

    @Test func untypedMediaContentMustNameAPicture() throws {
        let xml = """
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item><title>P</title>
        <media:content url="https://site.example/episode.mp3"/>
        <media:content url="https://site.example/cover.png?w=1200"/>
        </item></channel></rss>
        """
        let feed = try FeedParser.parse(Data(xml.utf8))
        #expect(feed.entries[0].images.map(\.url) == ["https://site.example/cover.png?w=1200"])
    }

    @Test func aSmallFirstPictureGivesWayToALargerOne() async throws {
        let xml = """
        <rss><channel><item><title>T</title>
        <enclosure url="https://site.example/thumb.jpg" type="image/jpeg"/>
        <description><![CDATA[<img src="/mid.jpg"><img src="/full.jpg">]]></description>
        </item></channel></rss>
        """
        let routes: [String: FakeHTTPClient.Response] = [
            "https://site.example/thumb.jpg": .init(body: MediaFixtures.jpeg(width: 151, height: 151)),
            "https://site.example/mid.jpg": .init(body: MediaFixtures.jpeg(width: 400, height: 300)),
            "https://site.example/full.jpg": .init(body: MediaFixtures.jpeg(width: 1600, height: 900)),
        ]
        #expect(try await items(xml, routes: routes)[0].media.map(\.url) == ["https://site.example/full.jpg"])

        // With nothing good enough, the largest of those tried.
        var smaller = routes
        smaller["https://site.example/full.jpg"] = .init(body: MediaFixtures.jpeg(width: 300, height: 200))
        #expect(try await items(xml, routes: smaller)[0].media.map(\.url) == ["https://site.example/mid.jpg"])
    }

    @Test func absurdStatedSizesAreIgnoredForTheFilesOwn() async throws {
        // A valid small picture, then one whose stated height would crash
        // layout: the stated size is dropped and the file measured.
        let xml = """
        <rss xmlns:media="http://search.yahoo.com/mrss/"><channel><item><title>H</title>
        <media:content url="https://site.example/a.jpg" medium="image" width="300" height="200"/>
        <media:content url="https://site.example/b.jpg" medium="image" width="500" height="9223372036854775807"/>
        <media:content url="https://site.example/c.jpg" medium="image" width="400" height="-3"/>
        </item></channel></rss>
        """
        let items = try await items(xml, routes: ["https://site.example/b.jpg": .init(body: MediaFixtures.jpeg(width: 500, height: 400))])
        #expect(items[0].media == [Item.Media(kind: .image, url: "https://site.example/b.jpg", width: 500, height: 400)!])
        #expect(FeedParser.statedSide("100001") == nil && FeedParser.statedSide(" 640 ") == 640)
    }

    @Test func articlesWithoutImagesHaveNone() async throws {
        let items = try await items("<rss><channel><item><title>D</title><description>Plain</description></item></channel></rss>")
        #expect(items[0].media.isEmpty)
    }
}

@Suite struct StoringMedia {
    @Test func sizedMediaAndCardImagesRoundTrip() async throws {
        let store = try InfluxStore.inMemory()
        let source = Source(id: "s", kind: .mastodonHome, title: "S", colorIndex: 0)
        try await store.save(sources: [source])
        let image = Item.Media(kind: .image, url: "https://cdn.example/i.jpg", width: 3, height: 2)
        let card = Item.LinkCard(url: "https://site.example/", site: "site.example", title: "T", image: image)
        try await store.insert([Item(sourceID: "s", remoteID: "1", kind: .post, mergeKey: "k", authorName: "A", authorHandle: "@a",
                                     body: "b", publishedAt: Date(), fetchedAt: Date(), linkCard: card, media: [image!])])
        let row = try #require(try await store.rows().first)
        #expect(row.linkCard?.image?.aspect == 1.5)
        #expect(row.media.count == 1)
    }

    @Test func cardsStoredBeforeImagesDecode() throws {
        let old = try JSONDecoder().decode(Item.LinkCard.self, from: Data(#"{"url":"u","site":"s","title":"t"}"#.utf8))
        #expect(old.image == nil)
    }
}

@Suite struct MastodonSizes {
    @Test func onlySanePixelCountsCount() {
        #expect(MastodonMapper.pixels(1600, 1200)! == (1600, 1200))
        #expect(MastodonMapper.pixels(553.6, 415.5)! == (554, 416))
        #expect(MastodonMapper.pixels(nil, 10) == nil)
        #expect(MastodonMapper.pixels(0, 10) == nil)
        #expect(MastodonMapper.pixels(.nan, 10) == nil)
        #expect(MastodonMapper.pixels(.infinity, 10) == nil)
        #expect(MastodonMapper.pixels(1e300, 10) == nil)
    }
}

@Suite struct ReadingLimits {
    @Test func lookupsReadOnlyTheStartOfABody() async {
        let huge = MediaFixtures.png(width: 640, height: 480) + Data(count: 1_000_000)
        let http = FakeHTTPClient(routes: ["https://cdn.example/big.png": .init(body: huge)])
        let (data, _) = try! await http.send(URLRequest(url: URL(string: "https://cdn.example/big.png")!), upTo: 100, at: [93, 184, 216, 34])
        #expect(data.count == 100)
        let media = await MediaResolver.testing(http).sized([UnsizedMedia(kind: .image, url: "https://cdn.example/big.png")])
        #expect(media.first?.width == 640)
    }
}

@Suite struct PrivateDestinations {
    @Test func onlyPublicNamesQualify() {
        for host in ["www.site.example", "cdn.example.com.", "xn--bcher-kva.example"] {
            #expect(PublicAddress.isPublicName(host), "\(host)")
        }
        for host in ["localhost", "printer.local", "nas", "db.internal", "router.home.arpa", "127.0.0.1", "2130706433", "0x7f.1",
                     "::1", "10.0.0.1.", "a..example", "app.localhost"] {
            #expect(!PublicAddress.isPublicName(host), "\(host)")
        }
    }

    @Test func onlyPublicAddressesQualify() {
        #expect(PublicAddress.isPublic([93, 184, 216, 34]))
        #expect(PublicAddress.isPublic([0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x68, 0x10, 0x84, 0x28]))
        for v4: [UInt8] in [[127, 0, 0, 1], [10, 1, 2, 3], [172, 20, 0, 1], [192, 168, 1, 1], [169, 254, 169, 254], [100, 100, 0, 1], [0, 0, 0, 0], [224, 0, 0, 1]] {
            #expect(!PublicAddress.isPublic(v4), "\(v4)")
        }
        let loopback6: [UInt8] = Array(repeating: 0, count: 15) + [1]
        let mapped: [UInt8] = Array(repeating: 0, count: 10) + [0xFF, 0xFF, 192, 168, 0, 1]
        let uniqueLocal: [UInt8] = [0xFD] + Array(repeating: 0, count: 15)
        let linkLocal: [UInt8] = [0xFE, 0x80] + Array(repeating: 0, count: 14)
        for v6 in [loopback6, mapped, uniqueLocal, linkLocal] {
            #expect(!PublicAddress.isPublic(v6), "\(v6)")
        }
    }

    @Test func theSystemResolverAnswers() {
        let local = PublicAddress.addresses(of: "localhost")
        #expect(local?.isEmpty == false)
        #expect(local?.allSatisfy { !PublicAddress.isPublic($0) } == true)
    }

    @Test func privateDestinationsAreNeverRequested() async {
        let http = FakeHTTPClient { _ in .init(text: "<title>Secret</title>") }
        let resolver = MediaResolver.testing(http, addresses: ["rebound.example": [[192, 168, 1, 10]]])
        for url in ["http://127.0.0.1/", "http://localhost:8080/", "http://[::1]/", "https://rebound.example/", "http://router.local/"] {
            #expect(await resolver.card(for: url) == nil, "\(url)")
        }
        #expect(http.requests.isEmpty)
    }

    @Test func requestsGoToTheAddressThatWasChecked() async {
        let http = FakeHTTPClient { _ in .init(text: "<title>Pinned</title>") }
        let resolver = MediaResolver.testing(http, addresses: ["dual.example": [[0x26, 0x06, 0x47, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x68, 0x10, 0x84, 0x28], [104, 16, 132, 40]]])
        #expect(await resolver.card(for: "https://dual.example/")?.title == "Pinned")
        #expect(http.addresses == [[104, 16, 132, 40]])
    }

    @Test func plainHTTPIsNotLookedUp() async {
        let http = FakeHTTPClient { _ in .init(text: "<title>Cleartext</title>") }
        #expect(await MediaResolver.testing(http).card(for: "http://site.example/") == nil)
        #expect(http.requests.isEmpty)
    }

    @Test func addressesParse() {
        #expect(PublicAddress.parse("93.184.216.34") == [93, 184, 216, 34])
        #expect(PublicAddress.parse("[::1]") == Array(repeating: 0, count: 15) + [1])
        #expect(PublicAddress.parse("fe80::1%en0")?.prefix(2) == [0xFE, 0x80])
        #expect(PublicAddress.parse("not an address") == nil)
    }

    @Test func urlSessionRefusesPinnedRequestsWithoutNetworkFramework() async {
        #if !canImport(Network)
        await #expect(throws: ConnectorError.self) {
            _ = try await URLSession.shared.send(URLRequest(url: URL(string: "https://site.example/")!), upTo: 10, at: [93, 184, 216, 34])
        }
        #endif
    }

    @Test func redirectsAreCheckedAtEveryHop() async {
        let http = FakeHTTPClient(routes: [
            "https://short.example/a": .init(status: 301, headers: ["Location": "https://site.example/a"], body: Data()),
            "https://site.example/a": .init(text: "<title>Followed</title>"),
            "https://short.example/b": .init(status: 302, headers: ["Location": "http://192.168.1.1/admin"], body: Data()),
        ])
        let resolver = MediaResolver.testing(http)
        let followed = await resolver.card(for: "https://short.example/a")
        #expect(followed?.title == "Followed")
        #expect(followed?.url == "https://site.example/a")
        #expect(await resolver.card(for: "https://short.example/b") == nil)
        #expect(http.requests.map(\.url?.absoluteString) == ["https://short.example/a", "https://site.example/a", "https://short.example/b"])
    }
}

@Suite struct LookupDeadlines {
    /// Answers after a long wait, as a server dripping bytes would.
    private struct SlowClient: HTTPClient {
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            try await Task.sleep(for: .seconds(30))
            return (Data("<title>Late</title>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }

        func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
            try await send(request)
        }
        func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
            try await send(request)
        }
    }

    @Test func aSlowLookupGivesUpOnTime() async {
        let resolver = MediaResolver.testing(SlowClient(), timeout: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await resolver.card(for: "https://slow.example/") == nil)
        #expect(await resolver.imageSize(at: "https://slow.example/i.png") == nil)
        #expect(clock.now - start < .seconds(3))
    }

    @Test func aSlowResolverGivesUpOnTime() async {
        let never = AddressLookup { _ in
            try? await Task.sleep(for: .seconds(30))
            return nil
        }
        let resolver = MediaResolver(client: FakeHTTPClient(routes: [:]), addresses: never, timeout: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await resolver.card(for: "https://slow.example/") == nil)
        #expect(clock.now - start < .seconds(3))
    }

    @Test func aSlowImageLeavesTheCardItsTitle() async {
        struct SlowImages: HTTPClient {
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                if request.url?.path == "/slow.png" { try await Task.sleep(for: .seconds(30)) }
                let page = #"<head><meta property="og:title" content="Kept"><meta property="og:image" content="https://site.example/slow.png"></head>"#
                return (Data(page.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!)
            }

            func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
                try await send(request)
            }
            func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
                try await send(request)
            }
        }
        let card = await MediaResolver.testing(SlowImages(), timeout: .milliseconds(200)).card(for: "https://site.example/post")
        #expect(card?.title == "Kept")
        #expect(card?.image == nil)
    }

    @Test func fetchesFollowTheSameRules() async {
        let image = Data(repeating: 7, count: 1_000)
        let http = FakeHTTPClient(routes: [
            "https://cdn.example/photo.jpg": .init(body: image),
            "https://cdn.example/moved.jpg": .init(status: 302, headers: ["Location": "https://router.local/x.jpg"], body: Data()),
        ])
        let resolver = MediaResolver.testing(http)
        #expect(await resolver.fetch("https://cdn.example/photo.jpg", upTo: 100, timeout: .seconds(5)) == image.prefix(100))
        #expect(await resolver.fetch("https://cdn.example/moved.jpg", upTo: 100, timeout: .seconds(5)) == nil)
        #expect(await resolver.fetch("http://cdn.example/photo.jpg", upTo: 100, timeout: .seconds(5)) == nil)
        #expect(await MediaResolver.testing(SlowClient()).fetch("https://slow.example/i.jpg", upTo: 100, timeout: .milliseconds(200)) == nil)
    }

    @Test func everyLookupSaysWhoItIs() async {
        let http = FakeHTTPClient { request in
            switch request.url?.path {
            case "/page": .init(text: #"<head><meta property="og:title" content="T"><meta property="og:image" content="https://cdn.example/i.png"></head>"#)
            case "/i.png": .init(body: MediaFixtures.png(width: 200, height: 100))
            default: .init(status: 206, headers: ["Content-Range": "bytes 0-1/4"], body: Data([0, 1]))
            }
        }
        let resolver = MediaResolver.testing(http)
        _ = await resolver.card(for: "https://site.example/page")
        _ = await resolver.fetch("https://cdn.example/i.png", upTo: 100, timeout: .seconds(5))
        _ = await resolver.fetch("https://cdn.example/v.mp4", bytes: 0...1, upTo: 100, timeout: .seconds(5))
        _ = await resolver.sized([UnsizedMedia(kind: .image, url: "https://cdn.example/i.png?probe")])
        #expect(http.requests.count >= 5)
        #expect(http.requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == RSSConnector.userAgent })
    }

    @Test func rangedFetchesSayWhatCameBack() async {
        let http = FakeHTTPClient { request in
            switch (request.url?.path, request.value(forHTTPHeaderField: "Range")) {
            case ("/v.mp4", "bytes=0-1"?):
                .init(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 0-1/5000"], body: Data([0, 1]))
            case ("/v.mp4", nil):
                .init(status: 200, headers: ["Content-Type": "video/mp4", "Content-Length": "4"], body: Data([0, 1, 2, 3]))
            default:
                .init(status: 404)
            }
        }
        let resolver = MediaResolver.testing(http)
        let part = await resolver.fetch("https://cdn.example/v.mp4", bytes: 0...1, upTo: 100, timeout: .seconds(5))
        #expect(part == RangedResponse(data: Data([0, 1]), statusCode: 206, contentType: "video/mp4", totalLength: 5000))
        let whole = await resolver.fetch("https://cdn.example/v.mp4", bytes: nil, upTo: 100, timeout: .seconds(5))
        #expect(whole?.statusCode == 200 && whole?.totalLength == 4)
        #expect(await resolver.fetch("https://cdn.example/v.mp4", bytes: -1...1, upTo: 100, timeout: .seconds(5)) == nil)
        #expect(await resolver.fetch("http://cdn.example/v.mp4", bytes: 0...1, upTo: 100, timeout: .seconds(5)) == nil)
        #expect(RangedResponse.totalLength(status: 206, contentLength: "2", contentRange: "bytes 0-1/*") == nil)
    }

    @Test func postsSharingALinkShareOneLookup() async {
        let http = FakeHTTPClient(routes: ["https://site.example/shared": .init(text: "<title>Shared</title>")])
        let resolver = MediaResolver.testing(http)
        async let first = resolver.card(for: "https://site.example/shared")
        async let second = resolver.card(for: "https://site.example/shared")
        let titles = await [first?.title, second?.title]
        #expect(titles == ["Shared", "Shared"])
        #expect(http.requests.count == 1)
    }
}

@Suite struct ReadingResponses {
    private func read(_ text: String, limit: Int = 1_000, in pieces: Int = 1) throws -> HTTPResponseReader {
        var reader = HTTPResponseReader(limit: limit)
        let bytes = Data(text.utf8)
        let size = max(1, bytes.count / pieces)
        var start = 0
        while start < bytes.count, !reader.isDone {
            try reader.feed(bytes[start..<min(start + size, bytes.count)])
            start += size
        }
        if !reader.isDone { try reader.finish() }
        return reader
    }

    @Test func readsALengthDelimitedBody() throws {
        let reader = try read("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 5\r\n\r\nhelloEXTRA", in: 7)
        #expect(reader.status == 200)
        #expect(reader.headers["content-type"] == "text/html")
        #expect(reader.body == Data("hello".utf8))
    }

    @Test func undoesChunkedEncodingAcrossPieces() throws {
        let text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5;ext=1\r\nhello\r\n7\r\n, world\r\n0\r\n\r\n"
        for pieces in [1, 3, text.utf8.count] {
            #expect(try read(text, in: pieces).body == Data("hello, world".utf8))
        }
    }

    @Test func stopsAtTheLimit() throws {
        let reader = try read("HTTP/1.1 200 OK\r\n\r\n" + String(repeating: "x", count: 500), limit: 64)
        #expect(reader.isDone && reader.body.count == 64)
    }

    @Test func redirectsKeepTheirLocation() throws {
        let reader = try read("HTTP/1.1 301 Moved\r\nLocation: /next\r\nContent-Length: 0\r\n\r\n")
        #expect(reader.status == 301)
        #expect(reader.headers["location"] == "/next")
    }

    @Test func earlyHintsAreSkipped() throws {
        let text = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>; rel=preload\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\npage"
        for pieces in [1, 5, text.utf8.count] {
            let reader = try read(text, in: pieces)
            #expect(reader.status == 200)
            #expect(reader.headers["link"] == nil)
            #expect(reader.body == Data("page".utf8))
        }
        let endless = String(repeating: "HTTP/1.1 103 Early Hints\r\n\r\n", count: 20)
        #expect(throws: HTTPResponseReader.Malformed.self) { try read(endless) }
    }

    @Test func brokenResponsesThrow() {
        #expect(throws: HTTPResponseReader.Malformed.self) { try read("SSH-2.0-OpenSSH\r\n\r\n") }
        #expect(throws: HTTPResponseReader.Malformed.self) { try read("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nshort") }
        #expect(throws: HTTPResponseReader.Malformed.self) { try read("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n") }
    }
}

/// Real lookups over the network, for a Mac: `INFLUX_LIVE_NETWORK=1 swift test --filter LiveLookups`
/// (`FLUX_LIVE_NETWORK=1` still works).
@Suite(.enabled(if: ["INFLUX_LIVE_NETWORK", "FLUX_LIVE_NETWORK"].contains { ProcessInfo.processInfo.environment[$0] == "1" }))
struct LiveLookups {
    @Test func pinnedLookupsReadRealPages() async throws {
        let card = await MediaResolver(client: URLSession.shared).card(for: "https://www.apple.com/")
        #expect(card?.title.isEmpty == false)
    }

    @Test func aPinnedAddressStillHasToProveTheName() async throws {
        // Another site's address can't answer for www.apple.com: its certificate won't match.
        let other = try #require(PublicAddress.addresses(of: "example.com")?.first { $0.count == 4 })
        await #expect(throws: (any Error).self) {
            _ = try await URLSession.shared.send(URLRequest(url: URL(string: "https://www.apple.com/")!, timeoutInterval: 5), upTo: 1_000, at: other)
        }
    }
}

@Suite struct MigratingMedia {
    @Test func itemsStoredBeforeSizedMediaStillDecode() throws {
        let db = try DatabaseQueue()
        try Schema.migrator.migrate(db, upTo: "v2: source fetch state")
        try db.write { db in
            try db.execute(sql: "INSERT INTO source (id, kind, title, colorIndex) VALUES ('s', 'mastodonHome', 'S', 0)")
            try db.execute(sql: """
                INSERT INTO item (sourceID, remoteID, kind, mergeKey, authorName, authorHandle, body, publishedAt, fetchedAt, sortDate, mediaAspect)
                VALUES ('s', '1', 'post', 'k', 'A', '@a', 'b', '2026-10-24 00:00:00.000', '2026-10-24 00:00:00.000', '2026-10-24 00:00:00.000', 1.5)
                """)
        }
        try Schema.migrator.migrate(db)
        let item = try db.read { try Item.fetchOne($0) }
        #expect(item?.media == [])
    }
}

@Suite struct MigratingViewerState {
    @Test func postsStoredBeforeViewerStateAskBeforeActing() throws {
        let db = try DatabaseQueue()
        try Schema.migrator.migrate(db, upTo: "v5: booster ID")
        try db.write { db in
            try db.execute(sql: "INSERT INTO source (id, kind, title, colorIndex) VALUES ('s', 'mastodonHome', 'S', 0)")
            try db.execute(sql: "INSERT INTO source (id, kind, title, colorIndex) VALUES ('r', 'rss', 'R', 1)")
            for (source, id, kind) in [("s", "1", "post"), ("r", "2", "article")] {
                try db.execute(sql: """
                    INSERT INTO item (sourceID, remoteID, kind, mergeKey, authorName, authorHandle, body, publishedAt, fetchedAt, sortDate)
                    VALUES (?, ?, ?, ?, 'A', '@a', 'b', '2026-10-24 00:00:00.000', '2026-10-24 00:00:00.000', '2026-10-24 00:00:00.000')
                    """, arguments: [source, id, kind, "k\(id)"])
            }
        }
        try Schema.migrator.migrate(db)
        let items = try db.read { try Item.order(Column("remoteID")).fetchAll($0) }
        var unconfirmed = Item.Viewer()
        unconfirmed.unconfirmed = true
        #expect(items.map(\.viewer) == [unconfirmed, nil])
        #expect(items.map(\.links) == [[], []])
    }
}
