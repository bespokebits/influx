import CoreGraphics
import Foundation
import Testing
import InfluxKit
@testable import Influx

/// Taps on a row bitmap reach what was drawn where they land.
@Suite struct RowHits {
    private let type = Typography(scale: 1)
    private let environment = RowEnvironment(width: 390, scale: 3, dark: false, typography: Typography(scale: 1))

    private func row(_ item: Item, source: Source.Kind = .mastodonHome) async throws -> TimelineRow {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: item.sourceID, kind: source, accountID: "a", title: "S", colorIndex: 0)])
        try await store.insert([item])
        return try #require(try await store.rows().first)
    }

    private func post(body: String = "Hello there", links: [Item.Link] = [], replyTo: String? = nil, viewer: Item.Viewer? = Item.Viewer()) -> Item {
        Item(sourceID: "m", remoteID: "1", kind: .post, mergeKey: "https://example.social/1",
             authorName: "Ana", authorHandle: "@ana@example.social", body: body, url: "https://example.social/@ana/1",
             publishedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
             replyToHandle: replyTo, viewer: viewer, links: links)
    }

    private func hit(_ point: CGPoint, _ row: TimelineRow) -> RowHit? {
        RowHit.at(point, in: row, geometry: RowLayout.geometry(for: row, in: environment), typography: type)
    }

    @Test func postsHaveFourIconsInsideTheRow() async throws {
        let row = try await row(post())
        let geometry = RowLayout.geometry(for: row, in: environment)
        #expect(geometry.actions.count == RowAction.allCases.count)
        #expect(geometry.actions.allSatisfy { $0.maxY < geometry.height && $0.minY > geometry.body.maxY })
        for action in RowAction.allCases {
            let frame = geometry.actions[action.rawValue]
            guard case .action(let tapped, _) = hit(CGPoint(x: frame.midX, y: frame.midY), row) else {
                Issue.record("no action at \(action)")
                continue
            }
            #expect(tapped == action)
        }
    }

    @Test func articlesHaveOnlyABookmarkIcon() async throws {
        let article = Item(sourceID: "r", remoteID: "1", kind: .article, mergeKey: "https://example.com/1",
                           authorName: "Example", authorHandle: "example.com", title: "An article", body: "Summary",
                           url: "https://example.com/1",
                           publishedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let row = try await row(article, source: .rss)
        let geometry = RowLayout.geometry(for: row, in: environment)
        #expect(RowAction.available(for: row) == [.bookmark])
        let frame = try #require(geometry.actions.first)
        #expect(geometry.actions.count == 1)
        guard case .action(.bookmark, _) = hit(CGPoint(x: frame.midX, y: frame.midY), row) else {
            Issue.record("no bookmark on the article")
            return
        }
        #expect(RowHit.accessibilityActions(for: row).first?.name == "Bookmark")
    }

    @Test func rowsWithoutActionsHaveNoIcons() async throws {
        let row = try await row(post(viewer: nil))
        let geometry = RowLayout.geometry(for: row, in: environment)
        #expect(geometry.actions.isEmpty)
        // The icons' footer adds to a post's height.
        let withIcons = RowLayout.geometry(for: try await self.row(post()), in: environment)
        #expect(withIcons.height > geometry.height)
    }

    @Test func theRestOfAPostOpensItsThread() async throws {
        let row = try await row(post())
        let geometry = RowLayout.geometry(for: row, in: environment)
        guard case .thread = hit(CGPoint(x: geometry.body.midX, y: geometry.body.midY), row) else {
            Issue.record("body tap didn't open the thread")
            return
        }
    }

    /// A Sammy feed's posts have no thread to open: the rest of the post
    /// opens its own page, and the reply chip and thread icon do nothing.
    @Test func aPostWithoutAThreadOpensItsOriginal() async throws {
        let row = try await row(post(replyTo: "@bo@example.social"), source: .sammyFeed)
        #expect(!row.hasThread)
        #expect(!RowAction.available(for: row).contains(.thread))
        let geometry = RowLayout.geometry(for: row, in: environment)
        guard case .link(let url) = hit(CGPoint(x: geometry.body.midX, y: geometry.body.midY), row) else {
            Issue.record("body tap didn't open the original")
            return
        }
        #expect(url.absoluteString == "https://example.social/@ana/1")
        let chip = try #require(geometry.context)
        #expect(hit(CGPoint(x: chip.midX, y: chip.midY), row) == nil, "the reply chip opened something")
    }

    /// A rich post that names a thread offers it in the item menu, but a
    /// tap on the post still opens its original, and its one icon is
    /// Influx's own bookmark (ADR 0031).
    @Test func aRichPostWithAThreadStillOpensItsOriginal() async throws {
        var item = post(viewer: nil)
        item.actionRef = "thread:contract-thread-1"
        let row = try await row(item, source: .sammyFeed)
        #expect(row.hasThread && row.isRich)
        #expect(RowAction.available(for: row) == [.bookmark])
        let geometry = RowLayout.geometry(for: row, in: environment)
        guard case .link(let url) = hit(CGPoint(x: geometry.body.midX, y: geometry.body.midY), row) else {
            Issue.record("body tap didn't open the original")
            return
        }
        #expect(url.absoluteString == "https://example.social/@ana/1")
        let icon = try #require(geometry.actions.first)
        guard case .action(.bookmark, _) = hit(CGPoint(x: icon.midX, y: icon.midY), row) else {
            Issue.record("the icon isn't the bookmark")
            return
        }
        #expect(RowHit.accessibilityActions(for: row).prefix(2).map(\.name) == ["Bookmark", "Open thread"])
    }

    @Test func aLinkInTheTextOpensItsAddress() async throws {
        let row = try await row(post(body: "read https://x.example now", links: [Item.Link(start: 5, length: 17, url: "https://x.example/full")]))
        let geometry = RowLayout.geometry(for: row, in: environment)
        // The link starts a few characters in, on the first line.
        let point = CGPoint(x: geometry.body.minX + 80, y: geometry.body.minY + 8)
        guard case .link(let url) = hit(point, row) else {
            Issue.record("no link at \(point)")
            return
        }
        #expect(url.absoluteString == "https://x.example/full")
        // The first word isn't part of it.
        guard case .thread = hit(CGPoint(x: geometry.body.minX + 4, y: geometry.body.minY + 8), row) else {
            Issue.record("the word before the link opened something else")
            return
        }
    }

    @Test func theReplyChipOpensTheThreadAndTheAuthorTheirProfile() async throws {
        let row = try await row(post(replyTo: "@bo@other.example"))
        let geometry = RowLayout.geometry(for: row, in: environment)
        let chip = try #require(geometry.context)
        guard case .thread = hit(CGPoint(x: chip.minX + 20, y: chip.midY), row) else {
            Issue.record("chip didn't open the thread")
            return
        }
        guard case .link(let profile) = hit(CGPoint(x: geometry.header.minX + 10, y: geometry.header.midY), row) else {
            Issue.record("author didn't open the profile")
            return
        }
        #expect(profile.absoluteString == "https://example.social/@ana")
    }

    @Test func articlesOpenTheirPage() async throws {
        var item = post(viewer: nil)
        item.kind = .article
        item.url = "https://blog.example/post"
        let row = try await row(item, source: .rss)
        let geometry = RowLayout.geometry(for: row, in: environment)
        guard case .article(_, let url) = hit(CGPoint(x: geometry.body.midX, y: geometry.body.midY), row) else {
            Issue.record("article tap didn't open it")
            return
        }
        #expect(url.absoluteString == "https://blog.example/post")
    }

    @Test func voiceOverListsTheActionsByWhatTheyDoNow() async throws {
        let row = try await row(post(viewer: Item.Viewer(liked: true)))
        let names = RowHit.accessibilityActions(for: row).map(\.name)
        #expect(names.prefix(4) == ["Open thread", "Boost", "Unlike", "Bookmark"])
        #expect(names.contains("Open Ana's profile"))
        #expect(RowText.accessibilityLabel(row).hasSuffix("Liked"))
    }

    @Test func theAvatarOpensTheProfileAndTheTextStartsBesideIt() async throws {
        let row = try await row(post())
        let geometry = RowLayout.geometry(for: row, in: environment)
        #expect(geometry.avatar.maxX < geometry.body.minX)
        #expect(geometry.height >= geometry.avatar.maxY)
        guard case .link(let profile) = hit(CGPoint(x: geometry.avatar.midX, y: geometry.avatar.midY), row) else {
            Issue.record("avatar didn't open the profile")
            return
        }
        #expect(profile.absoluteString == "https://example.social/@ana")
    }

    @Test func picturesAreCappedOnAWideWindow() async throws {
        var item = post()
        item.media = [Item.Media(kind: .image, url: "https://cdn.example/a.jpg", width: 2000, height: 1000)!]
        let row = try await row(item)
        let wide = RowEnvironment(width: 1100, scale: 2, dark: false, typography: type)
        let frame = try #require(RowLayout.geometry(for: row, in: wide).media.first)
        #expect(frame.width == RowLayout.mediaMaxWidth)
        #expect(frame.height == RowLayout.mediaMaxWidth / 2)
        // A phone's column is narrower than the cap.
        let narrow = try #require(RowLayout.geometry(for: row, in: environment).media.first)
        #expect(narrow.width < RowLayout.mediaMaxWidth)
    }

    /// A rich post's media is references, not URLs: each is laid out at its
    /// own size, an image opens the viewer, a video or GIF plays on a tap,
    /// and the text still opens the post's own page.
    @Test func aRichPostsMediaOpensAndPlaysFromItsReferences() async throws {
        let base = "sammy-media:abc@example.com/feed-1/"
        var item = post(viewer: nil)
        item.media = [
            Item.Media(kind: .image, url: base + "i", width: 1600, height: 900, altText: "A lighthouse")!,
            Item.Media(kind: .video, url: base + "v", previewURL: base + "v?variant=preview", width: 1280, height: 720, durationMs: 15500)!,
            Item.Media(kind: .gif, url: base + "g", width: 480, height: 480)!,
        ]
        let row = try await row(item, source: .sammyFeed)
        let geometry = RowLayout.geometry(for: row, in: environment)
        #expect(geometry.media.count == 3)
        #expect(row.media.allSatisfy { $0.kind == .image || VideoPlayback.canPlay($0) })
        var hits: [String] = []
        for frame in geometry.media {
            switch hit(CGPoint(x: frame.midX, y: frame.midY), row) {
            case .image(let media): hits.append("image \(media.url)")
            case .video(let media): hits.append("play \(media.url)")
            default: hits.append("other")
            }
        }
        #expect(hits == ["image \(base)i", "play \(base)v", "play \(base)g"])
        guard case .link(let url) = hit(CGPoint(x: geometry.body.midX, y: geometry.body.midY), row) else {
            Issue.record("the text didn't open the original")
            return
        }
        #expect(url.absoluteString == "https://example.social/@ana/1")
        // Anything that isn't a reference or https still doesn't play.
        #expect(!VideoPlayback.canPlay(Item.Media(kind: .video, url: "sammy-media:not-one", width: 1, height: 1)!))
    }

    @Test func aWideCardImageGoesAcrossTheTopAndASquareOneStaysSmall() async throws {
        var item = post()
        item.linkCard = Item.LinkCard(url: "https://news.example/a", site: "news.example", title: "Big news", summary: "What happened.",
                                      image: Item.Media(kind: .image, url: "https://news.example/a.jpg", width: 1200, height: 630))
        let large = RowLayout.geometry(for: try await row(item), in: environment)
        let card = try #require(large.link), image = try #require(large.linkImage), summary = try #require(large.linkSummary)
        #expect(image.width == card.width && image.minY == card.minY)
        #expect(try #require(large.linkTitle).minY > image.maxY)
        #expect(summary.maxY <= card.maxY)

        item.linkCard?.image = Item.Media(kind: .image, url: "https://news.example/sq.jpg", width: 400, height: 400)
        let small = RowLayout.geometry(for: try await row(item), in: environment)
        let thumb = try #require(small.linkImage)
        #expect(thumb.width == thumb.height && thumb.maxX == small.link?.maxX)
        #expect(small.linkSummary == nil)
    }

    @Test func aQuotedPostIsDrawnAndOpens() async throws {
        var item = post()
        item.quote = Item.Quote(mergeKey: "q", url: "https://example.social/@wnba/9", authorName: "WNBA", authorHandle: "@wnba@example.social",
                                body: "Game 6 moves to Thursday")
        let row = try await row(item)
        let geometry = RowLayout.geometry(for: row, in: environment)
        let quote = try #require(geometry.quote)
        #expect(quote.minY > geometry.body.maxY && geometry.quoteBody != nil)
        guard case .link(let url) = hit(CGPoint(x: quote.midX, y: quote.midY), row) else {
            Issue.record("quote didn't open")
            return
        }
        #expect(url.absoluteString == "https://example.social/@wnba/9")
    }

    @Test func aQuotedPostsPictureTopsItsCard() async throws {
        var item = post()
        item.quote = Item.Quote(mergeKey: "q", url: "https://elsewhere.example/status/1", authorName: "River City Rowers",
                                authorHandle: "@rowers@bridge.example", body: "Tonight's crew list",
                                image: Item.Media(kind: .image, url: "https://cdn.example/crew.jpg", width: 960, height: 1200))
        let geometry = RowLayout.geometry(for: try await row(item), in: environment)
        let quote = try #require(geometry.quote), image = try #require(geometry.quoteImage)
        #expect(image.minY == quote.minY && image.width == quote.width)
        // No taller than a single image in a post may be.
        #expect(image.height <= (image.width * MediaGrid.tallest).rounded())
        #expect(try #require(geometry.quoteHeader).minY > image.maxY)
        #expect(try #require(geometry.quoteSite).maxY < quote.maxY)
    }

    @Test func voiceOverReadsAQuotedPostsPicture() async throws {
        var item = post()
        item.quote = Item.Quote(mergeKey: "q", url: nil, authorName: "Rowers", authorHandle: "@rowers", body: "",
                                image: Item.Media(kind: .image, url: "https://cdn.example/i.jpg", width: 960, height: 1200,
                                                  altText: "Crew list"))
        #expect(RowText.accessibilityLabel(try await row(item)).contains("Quoting Rowers. Image: Crew list"))
    }

    @Test func aBoostShowsTheBoostersPicture() async throws {
        var item = post()
        item.boostedBy = "Lydia"
        item.boostedByAvatar = "https://cdn.example/lydia.png"
        let geometry = RowLayout.geometry(for: try await row(item), in: environment)
        let booster = try #require(geometry.boosterAvatar)
        #expect(booster.maxX < (geometry.context?.minX ?? 0))
    }

    @Test func aShortHeaderStaysOnOneLine() async throws {
        let geometry = RowLayout.geometry(for: try await row(post()), in: environment)
        #expect(geometry.handle == nil)
        #expect(geometry.time.minY == geometry.header.minY && geometry.time.minX >= geometry.header.maxX)
    }

    /// A bridged handle is too long to share a phone's line with the name
    /// and time, so it moves down and the time keeps its place in full.
    @Test func aLongHandleMovesBelowAndTheTimeIsNeverCut() async throws {
        var item = post()
        item.authorName = "Example City Sports"
        item.authorHandle = "@examplecitysports@relay.bridgehost.example.social"
        let row = try await row(item)
        let geometry = RowLayout.geometry(for: row, in: environment)
        let handle = try #require(geometry.handle)
        #expect(handle.minY > geometry.header.maxY && handle.maxY < geometry.body.minY)
        #expect(geometry.time.minY == geometry.header.minY)
        #expect(geometry.time.width >= RowLayout.singleLineWidth(RowText.time(row, type)))
        #expect(geometry.time.maxX <= environment.width - RowLayout.inset)
        // Tapping the handle still opens the profile.
        guard case .link = hit(CGPoint(x: handle.minX + 10, y: handle.midY), row) else {
            Issue.record("handle tap didn't open the profile")
            return
        }
    }

    @Test func aLongNameIsCutBeforeTheTime() async throws {
        var item = post()
        item.authorName = String(repeating: "Very Long Name ", count: 8)
        let row = try await row(item)
        let geometry = RowLayout.geometry(for: row, in: environment)
        #expect(geometry.time.width >= RowLayout.singleLineWidth(RowText.time(row, type)))
        #expect(geometry.time.maxX <= environment.width - RowLayout.inset)
        #expect(geometry.handle != nil)
    }

    /// "Boosted by … · posted …" wraps rather than losing the time.
    @Test func aLongBoostLineWraps() async throws {
        var item = post()
        item.boostedBy = "Somebody With A Rather Long Display Name"
        item.boostedByAvatar = "https://cdn.example/b.png"
        item.sortDate = item.publishedAt.addingTimeInterval(86_400)
        let geometry = RowLayout.geometry(for: try await row(item), in: environment)
        let context = try #require(geometry.context)
        #expect(context.height > Broadsheet.lineHeight(type.meta) * 1.5)
        #expect(context.maxY < geometry.body.minY)
    }

    @Test func profilesForBothServices() async throws {
        #expect(RowText.profileURL(try await row(post()))?.absoluteString == "https://example.social/@ana")
        var bluesky = post()
        bluesky.authorHandle = "@ana.bsky.social"
        bluesky.url = "https://bsky.app/profile/did:plc:x/post/1"
        #expect(RowText.profileURL(try await row(bluesky, source: .blueskyFollowing))?.absoluteString == "https://bsky.app/profile/ana.bsky.social")
    }
}
