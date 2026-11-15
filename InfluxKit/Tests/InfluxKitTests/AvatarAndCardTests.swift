import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

// Profile pictures, card descriptions, quotes, feed icons and video cards.

private let fetchedAt = Date(timeIntervalSince1970: 1_793_000_000)
private let home = MastodonMapper.homeSource(accountID: "@me@example.social", colorIndex: 1)

private func mastodonStatus(_ json: String) throws -> Mastodon.Status {
    try Mastodon.decoder().decode(Mastodon.Status.self, from: Data(json.utf8))
}

private func account(_ id: String, _ name: String, avatar: String? = nil) -> String {
    let picture = avatar.map { #", "avatar": "\#($0).gif", "avatar_static": "\#($0).png""# } ?? ""
    return #"{"id": "\#(id)", "username": "\#(name)", "acct": "\#(name)", "display_name": "\#(name.capitalized)"\#(picture)}"#
}

private func status(_ id: String, account: String, content: String = "<p>Hi</p>", extra: String = "") -> String {
    #"""
    {"id": "\#(id)", "uri": "https://example.social/users/x/statuses/\#(id)", "url": "https://example.social/@x/\#(id)",
     "created_at": "2026-10-24T01:00:00.000Z", "content": "\#(content)", "spoiler_text": "",
     "account": \#(account), "mentions": [], "media_attachments": []\#(extra)}
    """#
}

@Suite struct MastodonAvatarsAndQuotes {
    @Test func authorAndBoosterPicturesAreTheStills() throws {
        let boost = try mastodonStatus(status("2", account: account("7", "lydia", avatar: "https://cdn.example/lydia"),
                                              extra: #", "reblog": \#(status("1", account: account("8", "daisy", avatar: "https://cdn.example/daisy")))"#))
        let item = try #require(MastodonMapper.item(from: boost, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(item.authorAvatar == "https://cdn.example/daisy.png")
        #expect(item.boostedByAvatar == "https://cdn.example/lydia.png")

        let plain = try mastodonStatus(status("3", account: account("8", "daisy")))
        let noPicture = try #require(MastodonMapper.item(from: plain, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(noPicture.authorAvatar == nil)
        #expect(noPicture.boostedByAvatar == nil)
    }

    @Test func cardsKeepTheirDescription() throws {
        let card = #", "card": {"url": "https://news.example/a", "title": "Big news", "description": "What happened today.", "provider_name": "News", "image": "https://news.example/a.jpg", "width": 1200, "height": 630}"#
        let item = try #require(MastodonMapper.item(from: try mastodonStatus(status("4", account: account("8", "daisy"), extra: card)),
                                                    source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(item.linkCard?.summary == "What happened today.")
        #expect(item.linkCard?.image?.width == 1200)
    }

    @Test func acceptedQuotesAreKept() throws {
        let quoted = status("10", account: account("9", "wnba"), content: "<p>Game 6 moves to Thursday</p>")
        let accepted = try mastodonStatus(status("11", account: account("8", "ashlee"), content: "<p>These are not serious people</p>",
                                                 extra: #", "quote": {"state": "accepted", "quoted_status": \#(quoted)}"#))
        let item = try #require(MastodonMapper.item(from: accepted, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(item.quote == Item.Quote(mergeKey: "https://example.social/users/x/statuses/10", url: "https://example.social/@x/10",
                                         authorName: "Wnba", authorHandle: "@wnba@example.social", body: "Game 6 moves to Thursday"))

        let pending = try mastodonStatus(status("12", account: account("8", "ashlee"),
                                                extra: #", "quote": {"state": "pending", "quoted_status": null}"#))
        // A quote without its post is an unavailable quote, with no address:
        // Mastodon sends none.
        #expect(MastodonMapper.item(from: pending, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt)?.quote
            == .unavailable(url: nil))
        for state in ["deleted", "revoked", "rejected", "unauthorized", "blocked_account", "blocked_domain"] {
            let gone = try mastodonStatus(status("16", account: account("8", "ashlee"),
                                                 extra: #", "quote": {"state": "\#(state)", "quoted_status": null}"#))
            let quote = MastodonMapper.item(from: gone, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt)?.quote
            #expect(quote?.isUnavailable == true, "\(state)")
        }
        // One the reader muted is left out, as a filtered one is.
        let muted = try mastodonStatus(status("17", account: account("8", "ashlee"),
                                              extra: #", "quote": {"state": "muted_account", "quoted_status": null}"#))
        #expect(MastodonMapper.item(from: muted, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt)?.quote == nil)
        // A post with no quote has none.
        let plain = try mastodonStatus(status("18", account: account("8", "ashlee")))
        #expect(MastodonMapper.item(from: plain, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt)?.quote == nil)

        // A quoted status the reader's filters hide is left out too.
        let filtered = status("14", account: account("9", "wnba"),
                              extra: #", "filtered": [{"filter": {"filter_action": "hide"}}]"#)
        let hiding = try mastodonStatus(status("15", account: account("8", "ashlee"),
                                               extra: #", "quote": {"state": "accepted", "quoted_status": \#(filtered)}"#))
        let shown = try #require(MastodonMapper.item(from: hiding, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(shown.quote == nil)

        // A quoted status Influx can't read is an unavailable quote, and the
        // post stays.
        let broken = try mastodonStatus(status("13", account: account("8", "ashlee"),
                                               extra: #", "quote": {"state": "accepted", "quoted_status": {"id": 5}}"#))
        let kept = try #require(MastodonMapper.item(from: broken, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        #expect(kept.quote == .unavailable(url: nil))
    }
}

@Suite struct QuotePictures {
    @Test func aBridgedQuoteKeepsItsPictureAndOwnAddress() throws {
        // As example.social (Mastodon 4.7) sends a quote of a post bridged from another network.
        let quoted = #"""
            {"id": "117500000000000001", "uri": "https://bridge.example.social/users/rowers/statuses/2100000000000000001",
             "url": "https://elsewhere.example/status/2100000000000000001", "created_at": "2026-10-26T22:45:01.000Z",
             "content": "<p>Tonight's crew list</p>", "spoiler_text": "", "mentions": [],
             "account": {"id": "1", "username": "rowers", "acct": "rowers@bridge.example.social", "display_name": "River City Rowers"},
             "media_attachments": [{"id": "9", "type": "image", "url": "https://example.social/files/original/6459.jpg",
               "preview_url": "https://example.social/files/small/6459.jpg",
               "meta": {"original": {"width": 960, "height": 1200}, "small": {"width": 429, "height": 536}}, "description": null}],
             "card": null, "quote": null}
            """#
        let post = try mastodonStatus(status("117500000000000002", account: account("2", "coxswain"),
                                             content: "<p>Our stroke is racing tonight.</p>",
                                             extra: #", "card": null, "quote": {"state": "accepted", "quoted_status": \#(quoted)}"#))
        let item = try #require(MastodonMapper.item(from: post, source: home.id, instanceHost: "example.social", fetchedAt: fetchedAt))
        let quote = try #require(item.quote)
        #expect(quote.url == "https://elsewhere.example/status/2100000000000000001")
        #expect(quote.authorName == "River City Rowers")
        #expect(quote.image == Item.Media(kind: .image, url: "https://example.social/files/original/6459.jpg", width: 960, height: 1200))
    }

    @Test func aBlueskyQuoteKeepsItsPicture() throws {
        let json = """
            {"feed": [{"post": {"uri": "at://did:plc:sam/app.bsky.feed.post/1", "cid": "c",
              "author": {"did": "did:plc:sam", "handle": "sam.test"},
              "record": {"text": "look at this", "createdAt": "2026-10-24T08:00:00Z"}, "indexedAt": "2026-10-24T08:00:00Z",
              "embed": {"$type": "app.bsky.embed.record#view", "record": {
                "$type": "app.bsky.embed.record#viewRecord", "uri": "at://did:plc:ana/app.bsky.feed.post/2",
                "author": {"did": "did:plc:ana", "handle": "ana.test"}, "value": {"text": "a photo", "createdAt": "2026-10-24T07:00:00Z"},
                "embeds": [{"$type": "app.bsky.embed.images#view", "images": [
                  {"thumb": "https://cdn.bsky.app/t.jpg", "fullsize": "https://cdn.bsky.app/f.jpg", "alt": "", "aspectRatio": {"width": 1600, "height": 900}}]}]}}}}]}
            """
        let page = try JSONDecoder().decode(FeedPage.self, from: Data(json.utf8))
        let item = try #require(BlueskyMapping.items(page, sourceID: "bluesky:did:plc:me:following", fetchedAt: fetchedAt).first)
        #expect(item.quote?.body == "a photo")
        #expect(item.quote?.image == Item.Media(kind: .image, url: "https://cdn.bsky.app/f.jpg", width: 1600, height: 900))
    }
}

@Suite struct BlueskyAvatars {
    @Test func authorAndReposterPicturesAndCardDescription() throws {
        let json = """
            {"feed": [{
              "post": {"uri": "at://did:plc:sam/app.bsky.feed.post/1", "cid": "c",
                       "author": {"did": "did:plc:sam", "handle": "sam.test", "avatar": "https://cdn.bsky.app/img/avatar/sam.jpg"},
                       "record": {"text": "look", "createdAt": "2026-10-24T08:00:00Z"}, "indexedAt": "2026-10-24T08:00:00Z",
                       "embed": {"$type": "app.bsky.embed.external#view", "external": {"uri": "https://www.example.com/story", "title": "Story", "description": "The whole story."}}},
              "reason": {"$type": "app.bsky.feed.defs#reasonRepost", "by": {"did": "did:plc:ana", "handle": "ana.test", "avatar": "https://cdn.bsky.app/img/avatar/ana.jpg"}, "indexedAt": "2026-10-24T09:00:00Z"}
            }]}
            """
        let page = try JSONDecoder().decode(FeedPage.self, from: Data(json.utf8))
        let item = try #require(BlueskyMapping.items(page, sourceID: "bluesky:did:plc:me:following", fetchedAt: fetchedAt).first)
        #expect(item.authorAvatar == "https://cdn.bsky.app/img/avatar/sam.jpg")
        #expect(item.boostedByAvatar == "https://cdn.bsky.app/img/avatar/ana.jpg")
        #expect(item.linkCard?.summary == "The whole story.")
    }
}

@Suite struct FeedIcons {
    private let source = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 0)

    private func icon(_ xml: String) throws -> String? {
        let feed = try FeedParser.parse(Data(xml.utf8), baseURL: URL(string: "https://example.com/feed"))
        return ArticleMapper.item(from: feed.entries[0], feed: feed, feedURL: URL(string: "https://example.com/feed"),
                                  source: source, fetchedAt: fetchedAt)?.authorAvatar
    }

    @Test func rssChannelImage() throws {
        #expect(try icon("""
            <rss><channel><title>E</title><link>https://example.com/</link>
            <image><url>https://example.com/logo.png</url><title>E</title><link>https://example.com/</link></image>
            <item><title>A</title><link>https://example.com/a</link><image><url>https://example.com/not-this.png</url></image></item>
            </channel></rss>
            """) == "https://example.com/logo.png")
    }

    @Test func podcastImage() throws {
        #expect(try icon("""
            <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel><title>E</title>
            <itunes:image href="https://example.com/cover.jpg"/>
            <item><title>A</title><link>https://example.com/a</link></item>
            </channel></rss>
            """) == "https://example.com/cover.jpg")
    }

    @Test func atomPrefersTheIconToTheLogo() throws {
        #expect(try icon("""
            <feed xmlns="http://www.w3.org/2005/Atom"><title>E</title>
            <logo>https://example.com/wide.png</logo><icon>/icon.png</icon>
            <entry><id>urn:a</id><title>A</title><link href="https://example.com/a"/></entry>
            </feed>
            """) == "https://example.com/icon.png")
    }

    @Test func aPlainHTTPFeedIconIsPassedOver() throws {
        #expect(try icon("""
            <rss><channel><title>E</title><link>https://www.example.org/</link>
            <image><url>http://www.example.org/logo.png</url></image>
            <item><title>A</title><link>https://www.example.org/a</link></item>
            </channel></rss>
            """) == "https://www.example.org/apple-touch-icon.png")
    }

    @Test func otherwiseTheSitesTouchIcon() throws {
        #expect(try icon("""
            <rss><channel><title>E</title><link>https://www.example.org/</link>
            <item><title>A</title><link>https://www.example.org/a</link></item>
            </channel></rss>
            """) == "https://www.example.org/apple-touch-icon.png")
    }
}

@Suite struct SiteIcons {
    private let page = URL(string: "https://www.example.com/")!

    @Test func theTouchIconWithoutSizesBeatsSmallerOnesAndPlainIcons() {
        // As AV Club's home page declares them: another site's icons first,
        // then its own, with no sizes.
        let html = """
            <html><head>
            <link rel="icon" sizes="196x196" href="/theme/mobile-icon-196.png">
            <link rel="apple-touch-icon" sizes="57x57" href="/theme/mobile-icon-57.png">
            <link rel="apple-touch-icon" sizes="144x144" href="/theme/mobile-icon-144.png">
            <link rel="shortcut icon" href="/theme/favicon.ico" type="image/vnd.microsoft.icon">
            <link rel="icon" href="https://cdn.example.com/logo-512.jpg" sizes="192x192" />
            <link rel="apple-touch-icon" href="https://cdn.example.com/logo-512.jpg" />
            </head><body><link rel="apple-touch-icon" href="/not-in-the-head.png"></body></html>
            """
        #expect(SiteIcon.parse(html, at: page) == "https://cdn.example.com/logo-512.jpg")
    }

    @Test func aLargerDeclaredTouchIconWins() {
        let html = #"<link rel="apple-touch-icon" href="/a.png"><link rel="apple-touch-icon" sizes="152x152 512x512" href="/b.png">"#
        #expect(SiteIcon.parse(html, at: page) == "https://www.example.com/b.png")
    }

    @Test func relativeIconsResolveAgainstTheFirstBase() {
        let html = #"<link rel="apple-touch-icon" href="icon.png"><base href="https://cdn.example.com/site/"><base href="/ignored/">"#
        #expect(SiteIcon.parse(html, at: page) == "https://cdn.example.com/site/icon.png")
    }

    @Test func plainIconsOnlyWhenLargeEnough() {
        #expect(SiteIcon.parse(#"<link rel="icon" sizes="32x32" href="/f.png"><link rel="icon" href="/f.ico">"#, at: page) == nil)
        #expect(SiteIcon.parse(#"<link rel="icon" sizes="32x32" href="/f.png"><link rel="icon" sizes="192x192" href="/i.png">"#, at: page)
                == "https://www.example.com/i.png")
    }

    @Test func iconsTheAppCantDrawAreSkipped() {
        let html = """
            <link rel="apple-touch-icon" href="data:image/png;base64,AAAA">
            <link rel="apple-touch-icon" href="/icon.svg">
            <link rel="icon" type="image/svg+xml" sizes="any" href="/icon">
            <link rel="mask-icon" href="/mask.png">
            <link rel="apple-touch-icon" href="http://cdn.example.com/plain.png">
            """
        #expect(SiteIcon.parse(html, at: page) == nil)
    }

    @Test func theSitePageIsTheFeedsLinkElseItsSiteOverHTTPS() throws {
        func page(_ xml: String, _ feedURL: String) throws -> String? {
            ArticleMapper.sitePage(try FeedParser.parse(Data(xml.utf8)), feedURL: URL(string: feedURL))
        }
        #expect(try page("<rss><channel><title>E</title><link>https://www.example.com/news/</link></channel></rss>", "https://www.example.com/rss")
                == "https://www.example.com/news/")
        #expect(try page("<rss><channel><title>E</title></channel></rss>", "https://feeds.example.com/x/rss?f=1") == "https://feeds.example.com/")
        #expect(try page("<rss><channel><title>E</title><link>http://www.example.com/</link></channel></rss>", "https://www.example.com/rss")
                == "https://www.example.com/")
    }

    private let source = Source(id: "rss:https://www.example.com/rss", kind: .rss, title: "Example", url: "https://www.example.com/rss", colorIndex: 0)
    private let feed = """
        <rss><channel><title>E</title><link>https://www.example.com</link>
        <item><guid isPermaLink="false">old</guid><title>Old</title><link>https://www.example.com/old</link></item>
        <item><guid isPermaLink="false">new</guid><title>New</title><link>https://www.example.com/new</link></item>
        </channel></rss>
        """

    private func page(declaring icon: String?, feed xml: String? = nil) async throws -> FetchedPage {
        let head = icon.map { #"<html><head><link rel="apple-touch-icon" href="\#($0)"></head></html>"# }
        let http = FakeHTTPClient(routes: head.map { ["https://www.example.com": .init(text: $0)] } ?? [:])
        let parsed = try FeedParser.parse(Data((xml ?? feed).utf8))
        let response = HTTPURLResponse(url: URL(string: source.url!)!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return await RSSConnector(client: http, resolver: .testing(http))
            .page(parsed, response: response, from: source, fetchedAt: fetchedAt)
    }

    @Test func articlesTakeTheIconTheSiteDeclares() async throws {
        let page = try await page(declaring: "/icon-512.png")
        #expect(page.items.map(\.authorAvatar) == ["https://www.example.com/icon-512.png", "https://www.example.com/icon-512.png"])
        #expect(page.articleIcon == "https://www.example.com/icon-512.png")
    }

    @Test func aGuessIsNeverThePagesIcon() async throws {
        let page = try await page(declaring: nil)
        #expect(page.items.map(\.authorAvatar) == ["https://www.example.com/apple-touch-icon.png", "https://www.example.com/apple-touch-icon.png"])
        #expect(page.articleIcon == nil)
    }

    @Test func feedIconsTheAppCantShowAreNotDeclared() async throws {
        for icon in ["http://www.example.com/logo.png", "https://www.example.com/logo.svg"] {
            let xml = feed.replacingOccurrences(of: "<link>https://www.example.com</link>",
                                                with: "<link>https://www.example.com</link><image><url>\(icon)</url></image>")
            #expect(try await page(declaring: "/icon-512.png", feed: xml).articleIcon == "https://www.example.com/icon-512.png")
        }
    }

    @Test func theStoreGivesTheDeclaredIconToEveryStoredArticle() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [source, Source(id: "other", kind: .rss, title: "Other", url: "https://other.example/rss", colorIndex: 1)])
        func article(_ id: String, from sourceID: String) -> Item {
            Item(sourceID: sourceID, remoteID: id, kind: .article, mergeKey: "https://www.example.com/\(id)", authorName: "Example",
                 authorHandle: "example.com", authorAvatar: "https://www.example.com/apple-touch-icon.png", body: "Text",
                 publishedAt: fetchedAt, fetchedAt: fetchedAt)
        }
        try await store.insert([article("gone", from: source.id), article("elsewhere", from: "other")])
        let request = Refresher.request(for: source, direction: .newer, cursor: nil, now: fetchedAt)
        // A page without the stored article, and with no declared icon: nothing changes.
        _ = try await store.record(FetchedPage(items: [], newer: nil, older: nil), for: request, sourceID: source.id)
        #expect(try await store.rows().map(\.authorAvatar).allSatisfy { $0 == "https://www.example.com/apple-touch-icon.png" })
        // With one: the source's articles take it, even those no longer in the feed.
        _ = try await store.record(FetchedPage(items: [], newer: nil, older: nil, articleIcon: "https://cdn.example.com/icon.png"),
                                   for: request, sourceID: source.id)
        let avatars = Dictionary(uniqueKeysWithValues: try await store.rows().map { ($0.sourceID, $0.authorAvatar) })
        #expect(avatars[source.id] == "https://cdn.example.com/icon.png")
        #expect(avatars["other"] == "https://www.example.com/apple-touch-icon.png")
    }
}

@Suite struct VideoCards {
    @Test(arguments: [
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10", "dQw4w9WgXcQ"),
        ("https://youtu.be/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
        ("//www.youtube-nocookie.com/embed/dQw4w9WgXcQ?rel=0", "dQw4w9WgXcQ"),
        ("https://m.youtube.com/shorts/dQw4w9WgXcQ", "dQw4w9WgXcQ"),
    ])
    func youTubeAddresses(address: String, id: String) {
        #expect(ArticleMapper.youTubeID(fromURL: address) == id)
    }

    @Test func notVideos() {
        #expect(ArticleMapper.youTubeID(fromURL: "https://www.youtube.com/@verge") == nil)
        #expect(ArticleMapper.youTubeID(fromURL: "https://www.youtube.com/watch?v=short") == nil)
        #expect(ArticleMapper.youTubeID(fromURL: "https://example.com/watch?v=dQw4w9WgXcQ") == nil)
    }

    @Test func anArticleWithOnlyAnEmbeddedVideoGetsItsCard() async throws {
        var entry = ParsedFeed.Entry()
        entry.title = "Today’s Vergecast"
        entry.content = #"<p>We talk.</p><iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>"#
        // The video page can't be fetched here, so YouTube's standard still stands in.
        let card = try #require(await ArticleMapper.videoCard(for: entry, resolver: .testing(FakeHTTPClient(routes: [:]))))
        #expect(card.url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(card.title == "Today’s Vergecast")
        #expect(card.image?.url == "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")

        var plain = ParsedFeed.Entry()
        plain.content = "<p>No video here.</p>"
        #expect(await ArticleMapper.videoCard(for: plain, resolver: .testing(FakeHTTPClient(routes: [:]))) == nil)
    }
}

@Suite struct RowAvatars {
    @Test func rowsCarryTheAuthorsAndTheFirstBoostersPicture() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "m", kind: .mastodonHome, accountID: "a", title: "Home", colorIndex: 0)])
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func boost(_ id: String, by name: String, at offset: TimeInterval) -> Item {
            Item(sourceID: "m", remoteID: id, kind: .post, mergeKey: "https://example.social/1", authorName: "Daisy",
                 authorHandle: "@daisy@example.social", authorAvatar: "https://cdn.example/daisy.png", body: "Fun fact",
                 publishedAt: t0, fetchedAt: t0.addingTimeInterval(600), sortDate: t0.addingTimeInterval(offset),
                 boostedBy: name, boostedByID: name, boostedByAvatar: "https://cdn.example/\(name).png")
        }
        try await store.insert([boost("b2", by: "sam", at: 120), boost("b1", by: "lydia", at: 60)])
        let row = try #require(try await store.rows().first)
        #expect(row.authorAvatar == "https://cdn.example/daisy.png")
        #expect(row.boostedBy == ["lydia", "sam"])
        #expect(row.boosterAvatar == "https://cdn.example/lydia.png")
    }
}
