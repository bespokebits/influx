import Foundation
import Testing
import InfluxKit
@testable import Influx

/// The iPhone reads larger than the Mac by default, and an article's
/// headline is about the size of a post.
@Suite struct TypographySizes {
    @Test func thePhoneSetsPostsAboveTheSystemBodySize() {
        let phone = Typography(sizes: Typography.phone)
        #expect(phone.body.pointSize >= 17)
        #expect(phone.meta.pointSize >= 13)
        #expect(phone.linkSummary.pointSize >= 15)
    }

    @Test func headlinesAndPostsAreASimilarSize() {
        #expect(abs(Typography.phone.title - Typography.phone.body) <= 1)
        #expect(Typography.phone.excerpt <= Typography.phone.body)
    }

    @Test func theMacKeepsItsSizes() {
        let mac = Typography(sizes: Typography.desktop)
        #expect(mac.body.pointSize == 16)
        #expect(mac.title.pointSize == 20)
        #expect(mac.meta.pointSize == 12)
    }

    @Test func dynamicTypeStillScalesEveryRole() {
        let base = Typography(scale: 1, sizes: Typography.phone)
        let large = Typography(scale: 1.35, sizes: Typography.phone)
        #expect(large.body.pointSize > base.body.pointSize)
        #expect(large.title.pointSize > base.title.pointSize)
        #expect(large.excerpt.pointSize > base.excerpt.pointSize)
        #expect(large.meta.pointSize > base.meta.pointSize)
        #expect(large != base)
    }

    @Test func anArticleBodyIsSetAsAnExcerpt() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "r", kind: .rss, title: "Blog", colorIndex: 0)])
        var item = Item(sourceID: "r", remoteID: "1", kind: .post, mergeKey: "https://blog.example/1",
                        authorName: "Ana", authorHandle: "blog.example", body: "An excerpt",
                        publishedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        item.kind = .article
        try await store.insert([item])
        let row = try #require(try await store.rows().first)
        let type = Typography(sizes: Typography.phone)
        let font = RowText.body(row, type).attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont
        #expect(font?.pointSize == type.excerpt.pointSize)
    }
}
