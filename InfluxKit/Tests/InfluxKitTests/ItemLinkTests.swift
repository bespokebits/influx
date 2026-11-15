import Foundation
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
private let rss = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 3)
private let mastodon = Source(id: "mastodon:@me@example.social:home", kind: .mastodonHome, accountID: "@me@example.social", title: "Mastodon", colorIndex: 1)

/// A ref that is well formed: 43 base64url characters.
private let wellFormed = "YJIhI3NxAmicLoHTxcTM1nffqG-DNrTMTy02vHUWNFM"

@Suite struct ItemLinkParsing {
    @Test func readsTheOneRoute() throws {
        let link = try #require(ItemLink(URL(string: "dev.bespokebits.influx://item?ref=\(wellFormed)")!))
        #expect(link.ref == wellFormed)
        #expect(ItemLink(link.url()) == link)
        // Schemes are case-insensitive.
        #expect(ItemLink(URL(string: "Dev.Bespokebits.Influx://item?ref=\(wellFormed)")!) == link)
    }

    @Test func takesTheSchemeTheBuildRegistered() {
        let url = URL(string: "dev.bespokebits.influx.dev://item?ref=\(wellFormed)")!
        #expect(ItemLink(url) == nil)
        #expect(ItemLink(url, scheme: "dev.bespokebits.influx.dev")?.ref == wellFormed)
        #expect(ItemLink(URL(string: "dev.bespokebits.influx://item?ref=\(wellFormed)")!, scheme: "dev.bespokebits.influx.dev") == nil)
    }

    @Test func ignoresTheSignInCallbacks() {
        for address in [
            "dev.bespokebits.influx:/oauth/sammy?code=c&state=s&iss=https%3A%2F%2Fsammy.example.com",
            "dev.bespokebits.influx://oauth/mastodon?code=abc123&state=xyz",
            "dev.bespokebits.influx:/oauth/callback?ref=\(wellFormed)",
            "dev.bespokebits.influx://oauth/item?ref=\(wellFormed)",
        ] {
            #expect(ItemLink(URL(string: address)!) == nil, "\(address)")
        }
    }

    @Test func ignoresAnotherSchemeHostOrPath() {
        for address in [
            "https://item?ref=\(wellFormed)",
            "https://example.com/item?ref=\(wellFormed)",
            "other.scheme://item?ref=\(wellFormed)",
            "dev.bespokebits.flux://item?ref=\(wellFormed)",
            "dev.bespokebits.influx://items?ref=\(wellFormed)",
            "dev.bespokebits.influx://ITEM?ref=\(wellFormed)",
            "dev.bespokebits.influx:item?ref=\(wellFormed)",
            "dev.bespokebits.influx:/item?ref=\(wellFormed)",
            "dev.bespokebits.influx:///item?ref=\(wellFormed)",
            "dev.bespokebits.influx://item/?ref=\(wellFormed)",
            "dev.bespokebits.influx://item/x?ref=\(wellFormed)",
            "dev.bespokebits.influx://item:443?ref=\(wellFormed)",
            "dev.bespokebits.influx://user@item?ref=\(wellFormed)",
            "dev.bespokebits.influx://item?ref=\(wellFormed)#top",
            "dev.bespokebits.influx://item?ref=\(wellFormed)#",
        ] {
            #expect(ItemLink(URL(string: address)!) == nil, "\(address)")
        }
    }

    @Test func needsExactlyOneRef() {
        for query in [
            "", "?", "?ref=", "?ref", "?other=\(wellFormed)", "?Ref=\(wellFormed)",
            "?ref=\(wellFormed)&ref=\(wellFormed)",
            "?ref=\(wellFormed)&x=1",
            "?x=1&ref=\(wellFormed)",
            "?ref=\(wellFormed)&",
        ] {
            #expect(ItemLink(URL(string: "dev.bespokebits.influx://item\(query)")!) == nil, "\(query)")
        }
    }

    @Test func needsFortyThreeBase64URLCharacters() {
        let short = String(wellFormed.dropLast())
        // Percent-encoded characters are refused, not decoded.
        let encoded = String(wellFormed.dropLast(3)) + "%41"
        let refs: [String] = [
            short, wellFormed + "A", wellFormed + "=", short + "=", short + "+", short + "/", short + ".",
            encoded, String(repeating: "A", count: 64),
        ]
        for ref in refs {
            let url = URL(string: "dev.bespokebits.influx://item?ref=\(ref)")
            #expect(url.flatMap { ItemLink($0) } == nil, "\(ref)")
        }
    }
}

@Suite struct ItemLinkHashing {
    /// Each made independently with Node, as Sammy makes it:
    /// `createHash("sha256").update(key).digest("base64url")`, and checked
    /// with `openssl dgst -sha256 -binary | base64`.
    @Test func matchesSammysRefByteForByte() {
        let vectors: [(key: String, ref: String)] = [
            ("", "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU"),
            ("https://example.com/articles/1", "YJIhI3NxAmicLoHTxcTM1nffqG-DNrTMTy02vHUWNFM"),
            ("at://did:plc:example/app.bsky.feed.post/3kexample", "a47Jn6IYmiMTFbkhxV4nJWN315hIQKzv0vJ2J7BVhP4"),
            ("https://example.social/users/ana/statuses/1", "uo57lDwY_Omx3e6usx8zYiwC2QbUO1YElAd_7UZhP1Q"),
            ("sammy-post:example.com:9f1c", "sdH9GeDaerkhkGhGaAuRWx-ik0JHwZxtLJsbeUF0gqg"),
            ("https://example.com/caf\u{e9}/\u{1F600}", "jioip3fZi-M-e_PM60szizj4dATotbcrY4TnkBAm2cc"),
        ]
        for vector in vectors {
            #expect(ItemLink.ref(forKey: vector.key) == vector.ref, "\(vector.key)")
            #expect(ItemLink(key: vector.key).ref.count == ItemLink.refLength)
            #expect(ItemLink(ItemLink(key: vector.key).url())?.ref == vector.ref)
        }
    }

    @Test func recordNamesKeepTheirHex() {
        #expect(RecordNameHash.hex("abc".utf8) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(RecordNameHash.digest("abc".utf8).count == 32)
    }
}

@Suite struct ItemLinkLookup {
    private func store() async throws -> InfluxStore {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss, mastodon])
        return store
    }

    private func article(_ name: String, at offset: TimeInterval = 0) -> Item {
        Item(sourceID: rss.id, remoteID: name, kind: .article, mergeKey: "https://example.com/\(name)",
             authorName: "Example", authorHandle: "example.com", title: "Article \(name)", body: "Summary",
             url: "https://example.com/\(name)",
             publishedAt: t0.addingTimeInterval(offset), fetchedAt: t0.addingTimeInterval(offset))
    }

    private func post(_ name: String, bookmarked: Bool) -> Item {
        Item(sourceID: mastodon.id, remoteID: name, kind: .post, mergeKey: "https://example.social/users/ana/statuses/\(name)",
             authorName: "Ana", authorHandle: "@ana@example.social", body: "Post \(name)",
             url: "https://example.social/@ana/\(name)", publishedAt: t0, fetchedAt: t0,
             viewer: Item.Viewer(bookmarked: bookmarked))
    }

    @Test func findsABookmarkedArticle() async throws {
        let store = try await store()
        try await store.insert([article("a"), article("b")])
        try await store.setArticle(mergeKey: "https://example.com/b", bookmarked: true, at: t0)
        guard case .bookmark(let row) = try await store.target(of: ItemLink(key: "https://example.com/b")) else {
            Issue.record("no row")
            return
        }
        #expect(row.mergeKey == "https://example.com/b")
        #expect(row.title == "Article b")
        #expect(row.viewer?.bookmarked == true)
    }

    @Test func findsABookmarkedPostByItsMergeKey() async throws {
        let store = try await store()
        try await store.insert([post("1", bookmarked: false), post("2", bookmarked: true)])
        let key = "https://example.social/users/ana/statuses/2"
        #expect(ItemLink(key: key).ref == ItemLink.ref(forKey: key))
        guard case .bookmark(let row) = try await store.target(of: ItemLink(key: key)) else {
            Issue.record("no row")
            return
        }
        #expect(row.kind == .post)
        #expect(row.body == "Post 2")
    }

    @Test func findsAPostStoredOnlyFromTheBookmarkList() async throws {
        let store = try await store()
        let saved = post("3", bookmarked: true)
        _ = try await store.storeBookmarks([saved], isComplete: true, in: mastodon.id, fetchedAt: t0)
        guard case .bookmark(let row) = try await store.target(of: ItemLink(key: saved.mergeKey)) else {
            Issue.record("no row")
            return
        }
        #expect(row.body == "Post 3")
    }

    @Test func matchesACopyByTheKeyItKeptWhenItJoinedARow() async throws {
        let store = try await store()
        let stored = post("5", bookmarked: false)
        try await store.insert([stored])
        // The bookmark was sent from a device that stored this copy first,
        // under its own key; here it joined a row keyed by another copy.
        let ownKey = "sammy-post:example.com:5"
        try await store.writer.write { db in
            try db.execute(sql: "UPDATE item SET postKey = ? WHERE mergeKey = ?", arguments: [ownKey, stored.mergeKey])
        }
        guard case .row(let row) = try await store.target(of: ItemLink(key: ownKey)) else {
            Issue.record("no row")
            return
        }
        #expect(row.mergeKey == stored.mergeKey)
    }

    @Test func opensABookmarkOnlyPostAfterItsBookmarkWasRemoved() async throws {
        let store = try await store()
        let saved = post("4", bookmarked: true)
        _ = try await store.storeBookmarks([saved], isComplete: true, in: mastodon.id, fetchedAt: t0)
        try await store.updateViewer(mergeKey: saved.mergeKey, sourceID: mastodon.id, at: t0.addingTimeInterval(1)) { viewer in
            var viewer = viewer
            viewer.bookmarked = false
            return viewer
        }
        guard case .row(let row) = try await store.target(of: ItemLink(key: saved.mergeKey)) else {
            Issue.record("no row")
            return
        }
        #expect(row.body == "Post 4")
    }

    @Test func stillOpensAnItemWhoseBookmarkWasRemoved() async throws {
        let store = try await store()
        try await store.insert([article("a"), post("1", bookmarked: false)])
        try await store.setArticle(mergeKey: "https://example.com/a", bookmarked: true, at: t0)
        try await store.setArticle(mergeKey: "https://example.com/a", bookmarked: false, at: t0.addingTimeInterval(1))
        guard case .row(let article) = try await store.target(of: ItemLink(key: "https://example.com/a")) else {
            Issue.record("no article")
            return
        }
        #expect(article.title == "Article a")
        guard case .row(let post) = try await store.target(of: ItemLink(key: "https://example.social/users/ana/statuses/1")) else {
            Issue.record("no post")
            return
        }
        #expect(post.body == "Post 1")
    }

    @Test func aBookmarkWithoutItsItemOpensBookmarks() async throws {
        let store = try await store()
        // A bookmark synced from another device, for an article this one
        // hasn't fetched.
        try await store.setArticle(mergeKey: "https://example.com/elsewhere", bookmarked: true, at: t0)
        #expect(try await store.target(of: ItemLink(key: "https://example.com/elsewhere")) == .bookmarked)
    }

    @Test func notFoundIsGone() async throws {
        let store = try await store()
        try await store.insert([article("a"), post("1", bookmarked: true)])
        try await store.setArticle(mergeKey: "https://example.com/removed", bookmarked: false, at: t0)
        #expect(try await store.target(of: ItemLink(key: "https://example.com/missing")) == .gone)
        #expect(try await store.target(of: ItemLink(key: "https://example.com/removed")) == .gone)
        #expect(try await store.target(of: ItemLink(key: "")) == .gone)
        #expect(try await InfluxStore.inMemory().target(of: ItemLink(key: "https://example.com/a")) == .gone)
    }
}
