import Foundation
import Testing
@testable import InfluxKit

private let fetchedAt = Date(timeIntervalSince1970: 1_793_000_000)
private let sourceID = "bluesky:did:plc:me:following"

func blueskyFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/Bluesky/\(name).json")
    return try Data(contentsOf: url)
}

private func timeline() throws -> [Item] {
    let page = try JSONDecoder().decode(FeedPage.self, from: blueskyFixture("timeline"))
    return BlueskyMapping.items(page, sourceID: sourceID, fetchedAt: fetchedAt)
}

private func date(_ text: String) -> Date {
    ATDate.parse(text)!
}

@Suite struct BlueskyMapping_ {
    @Test func pageDecodesAndDropsOnlyTheMalformedEntry() throws {
        let page = try JSONDecoder().decode(FeedPage.self, from: blueskyFixture("timeline"))
        #expect(page.cursor == "1793000000000::bafyreicursor")
        #expect(page.feed.count == 8)
        #expect(try timeline().count == 8)
    }

    @Test func plainPostWithLinkCard() throws {
        let item = try #require(try timeline().first)
        #expect(item.kind == .post)
        #expect(item.sourceID == sourceID)
        #expect(item.remoteID == "at://did:plc:ana/app.bsky.feed.post/3lana1")
        #expect(item.mergeKey == "at://did:plc:ana/app.bsky.feed.post/3lana1")
        #expect(item.authorName == "Ana Ruiz")
        #expect(item.authorHandle == "@ana.bsky.social")
        #expect(item.body == "Worth reading on scroll performance")
        #expect(item.url == "https://bsky.app/profile/did:plc:ana/post/3lana1")
        #expect(item.publishedAt == date("2026-10-24T09:59:58.120Z"))
        #expect(item.sortDate == date("2026-10-24T10:00:00.000Z"))
        #expect(item.fetchedAt == fetchedAt)
        #expect(item.linkCard == Item.LinkCard(url: "https://www.example.com/scroll", site: "example.com", title: "Smooth scrolling", summary: "How to"))
        #expect(item.media.isEmpty)
        #expect(item.boostedBy == nil)
        #expect(item.replyToHandle == nil)
        #expect(item.quote == nil)
    }

    @Test func sizesTheAppViewLeftOutAreLookedUp() throws {
        let page = try JSONDecoder().decode(FeedPage.self, from: blueskyFixture("timeline"))
        let mapped = BlueskyMapping.mapped(page, sourceID: sourceID, fetchedAt: fetchedAt)
        // The link card's image comes with no size.
        #expect(mapped[0].lookups.cardImage == "https://cdn.bsky.app/img/feed_thumbnail/plain/x@jpeg")
        #expect(mapped[1].lookups.media.map(\.url) == ["https://cdn.bsky.app/f1", "https://cdn.bsky.app/f2"])
        #expect(!mapped[1].lookups.isEmpty)
        // A video with its size needs nothing.
        #expect(mapped[4].lookups.isEmpty)
    }

    @Test func boostIsItsOwnItemDatedWhenBoosted() throws {
        let items = try timeline()
        let boost = items[1]
        #expect(boost.remoteID == "at://did:plc:ana/app.bsky.feed.repost/3lrep1")
        #expect(boost.mergeKey == "at://did:plc:sam/app.bsky.feed.post/3lsam1")
        #expect(boost.boostedBy == "Ana Ruiz")
        #expect(boost.authorName == "Sam")
        #expect(boost.sortDate == date("2026-10-24T09:30:00.000Z"))
        #expect(boost.publishedAt == date("2026-10-24T08:00:00Z"))
        // The second photo has no size, so it waits for a lookup rather
        // than being boxed at a guess.
        #expect(boost.media == [Item.Media(kind: .image, url: "https://cdn.bsky.app/f1", previewURL: "https://cdn.bsky.app/t1", width: 1600, height: 900, altText: "")!])
        // Actions go to the boosted post, not the boost.
        let ref = try JSONDecoder().decode(BlueskyMapping.ActionRef.self, from: Data(try #require(boost.actionRef).utf8))
        #expect(ref == .init(uri: "at://did:plc:sam/app.bsky.feed.post/3lsam1", cid: "bafyreisam1"))

        // The original, later in the page, merges with it.
        let original = items[7]
        #expect(original.remoteID == original.mergeKey)
        #expect(original.mergeKey == boost.mergeKey)
        #expect(original.boostedBy == nil)
        #expect(original.sortDate == date("2026-10-24T08:00:01.000Z"))
    }

    @Test func boostWithoutItsRecordURIStillHasAUniqueID() throws {
        let json = """
            {"feed": [{
              "post": {"uri": "at://did:plc:sam/app.bsky.feed.post/1", "cid": "c", "author": {"did": "did:plc:sam", "handle": "sam.test"},
                       "record": {"text": "hi", "createdAt": "2026-10-24T08:00:00Z"}, "indexedAt": "2026-10-24T08:00:00Z"},
              "reason": {"$type": "app.bsky.feed.defs#reasonRepost", "by": {"did": "did:plc:ana", "handle": "ana.test"}, "indexedAt": "2026-10-24T09:00:00Z"}
            }]}
            """
        let page = try JSONDecoder().decode(FeedPage.self, from: Data(json.utf8))
        let item = try #require(BlueskyMapping.items(page, sourceID: sourceID, fetchedAt: fetchedAt).first)
        #expect(item.remoteID == "at://did:plc:sam/app.bsky.feed.post/1#repost:did:plc:ana")
        #expect(item.boostedBy == "ana.test")
    }

    @Test func replyNamesTheParentsHandle() throws {
        let items = try timeline()
        #expect(items[2].replyToHandle == "@sam.example.com")
        // A blocked or deleted parent has no handle to show.
        #expect(items[3].replyToHandle == nil)
        #expect(items[3].body == "Replying into the void")
    }

    @Test func quoteWithVideo() throws {
        let item = try timeline()[4]
        #expect(item.quote == Item.Quote(
            mergeKey: "at://did:plc:ana/app.bsky.feed.post/3lana0",
            url: "https://bsky.app/profile/did:plc:ana/post/3lana0",
            authorName: "Ana Ruiz", authorHandle: "@ana.bsky.social", body: "The original thought"
        ))
        #expect(item.media == [Item.Media(kind: .video, url: "https://video.bsky.app/watch/x/playlist.m3u8", width: 1080, height: 1920)!])
    }

    @Test func unavailableQuotesAreKeptAndPinsAndUnknownEmbedsAreLeftOut() throws {
        let items = try timeline()
        let blockedQuote = items[5]
        // A blocked quoted post is an unavailable quote, with its web address.
        #expect(blockedQuote.quote == .unavailable(url: "https://bsky.app/profile/did:plc:gone/post/2"))
        #expect(blockedQuote.quote?.isUnavailable == true)
        #expect(blockedQuote.boostedBy == nil)
        #expect(blockedQuote.remoteID == blockedQuote.mergeKey)
        // Backdated: it shows when the network first saw it.
        #expect(blockedQuote.publishedAt == date("2026-10-24T08:20:00.000Z"))
        #expect(blockedQuote.authorName == "kai.bsky.social")

        let unknown = items[6]
        #expect(unknown.linkCard == nil && unknown.media.isEmpty && unknown.quote == nil)
        // A blank display name falls back to the handle.
        #expect(unknown.authorName == "kai.bsky.social")
        // Six fractional digits and a numeric offset.
        #expect(abs(unknown.publishedAt.timeIntervalSince(date("2026-10-24T08:10:00.123Z"))) < 0.001)
    }

    @Test func mediaWithoutASizeIsNeverGuessed() {
        let image = BlueskyMapping.Media.of(.images([ImageView(thumb: "t", fullsize: "f", alt: nil, aspectRatio: nil)]))
        #expect(image.lookups.media == [UnsizedMedia(kind: .image, url: "f", previewURL: "t")])
        #expect(image.lookups.media.compactMap(\.sized).isEmpty)
        let flat = AspectRatio(width: 0, height: 900)
        #expect(BlueskyMapping.Media.of(.video(VideoView(playlist: "p", thumbnail: "v", alt: nil, aspectRatio: flat))).lookups.media.first?.sized == nil)
        // An image with no address at all is dropped.
        #expect(BlueskyMapping.Media.of(.images([ImageView(thumb: nil, fullsize: nil, alt: nil, aspectRatio: nil)])).lookups.media.isEmpty)
    }

    @Test func linkCardsNeedAWebAddress() {
        #expect(BlueskyMapping.Media.linkCard(ExternalView(uri: "at://did:plc:x/app.bsky.feed.post/1", title: "", description: "", thumb: nil)) == nil)
        #expect(BlueskyMapping.Media.linkCard(ExternalView(uri: "https://site.example/a", title: " ", description: "", thumb: nil))?.title == "site.example")
    }

    @Test func publishedDateFallsBackToIndexedDate() {
        let indexed = date("2026-10-24T10:00:00Z")
        #expect(BlueskyMapping.publishedAt("2026-10-24T09:00:00Z", indexedAt: indexed) == date("2026-10-24T09:00:00Z"))
        #expect(BlueskyMapping.publishedAt(nil, indexedAt: indexed) == indexed)
        #expect(BlueskyMapping.publishedAt("garbage", indexedAt: indexed) == indexed)
        // Claims to be from the future, or from long before it was seen.
        #expect(BlueskyMapping.publishedAt("2026-10-24T11:00:00Z", indexedAt: indexed) == indexed)
        #expect(BlueskyMapping.publishedAt("2026-10-22T10:00:00Z", indexedAt: indexed) == indexed)
    }

    @Test func datesParseInEveryValidForm() {
        let expected = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(ATDate.parse("2026-10-26T07:33:20Z") == expected)
        #expect(ATDate.parse("2026-10-26T07:33:20.000Z") == expected)
        #expect(ATDate.parse("2026-10-26T07:33:20.000000Z") == expected)
        #expect(ATDate.parse("2026-10-26T08:33:20+01:00") == expected)
        #expect(ATDate.parse(ATDate.format(expected)) == expected)
        #expect(ATDate.parse("yesterday") == nil)
    }

    @Test func webURLsOnlyForPosts() {
        #expect(BlueskyMapping.webURL(postURI: "at://did:plc:a/app.bsky.feed.post/3k") == "https://bsky.app/profile/did:plc:a/post/3k")
        #expect(BlueskyMapping.webURL(postURI: "at://did:plc:a/app.bsky.feed.generator/x") == nil)
    }
}
