import Foundation
import Testing
@testable import InfluxKit

// Two Mastodon accounts on different instances and two Bluesky accounts,
// all seeing the same few posts:
// - Bo's photo: posted on other.example, boosted by Ana (seen by both
//   Mastodon accounts) and by Dee.
// - Cy's Bluesky post: fetched from Bluesky, and boosted on Mastodon by Ed
//   through the Bridgy Fed bridge.
// - Sam's Bluesky post: reposted by Ana (seen by both Bluesky accounts) and
//   by Lee.

private let fetchedAt = Date(timeIntervalSince1970: 1_793_000_000)
private let exampleHome = MastodonMapper.homeSource(accountID: "@me@example.social", colorIndex: 1)
private let otherHome = MastodonMapper.homeSource(accountID: "@me2@other.example", colorIndex: 2)
private let blueskyMe = Source(id: "bluesky:did:plc:me:following", kind: .blueskyFollowing, accountID: "did:plc:me", title: "Following", colorIndex: 0)
private let blueskyMe2 = Source(id: "bluesky:did:plc:me2:following", kind: .blueskyFollowing, accountID: "did:plc:me2", title: "Following", colorIndex: 4)

private let photoKey = "https://other.example/users/bo/statuses/4400"
private let cyKey = "at://did:plc:cy/app.bsky.feed.post/3lcy1"
private let samKey = "at://did:plc:sam/app.bsky.feed.post/3lsam9"

private func data(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/merging"))
    return try Data(contentsOf: url)
}

private func mastodon(_ name: String, _ source: Source, host: String) throws -> [Item] {
    let statuses = try Mastodon.decoder().decode([Mastodon.Status].self, from: data(name))
    return MastodonMapper.items(from: statuses, source: source.id, instanceHost: host, fetchedAt: fetchedAt)
}

private func bluesky(_ name: String, _ source: Source) throws -> [Item] {
    BlueskyMapping.items(try JSONDecoder().decode(FeedPage.self, from: data(name)), sourceID: source.id, fetchedAt: fetchedAt)
}

/// Each account's first page, in the order its source was fetched.
private func pages() throws -> [[Item]] {
    [
        try mastodon("mastodon-example-social", exampleHome, host: "example.social"),
        try mastodon("mastodon-other-example", otherHome, host: "other.example"),
        try bluesky("bluesky-me", blueskyMe),
        try bluesky("bluesky-me2", blueskyMe2),
    ]
}

private func store(_ pages: [[Item]]) async throws -> InfluxStore {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [exampleHome, otherHome, blueskyMe, blueskyMe2])
    for page in pages {
        try await store.insert(page)
    }
    return store
}

@Suite struct MergedPostsAcrossAccounts {
    @Test func eachPostShowsOnceWithEveryBoosterNamedOnce() async throws {
        let rows = try await store(try pages()).rows()
        #expect(rows.map(\.mergeKey) == [photoKey, cyKey, samKey])

        let photo = rows[0]
        // Ana's boost reached both Mastodon accounts; it names her once.
        #expect(photo.boostedBy == ["Ana Ruiz", "Dee"])
        #expect(photo.body == "A photo from the hills.")

        let cy = rows[1]
        #expect(cy.boostedBy == ["Ed"])
        #expect(cy.body == "Hello from Bluesky")

        let sam = rows[2]
        // Ana's repost reached both Bluesky accounts.
        #expect(sam.boostedBy == ["Ana Ruiz", "Lee"])
    }

    @Test func laterCopiesNeverMoveTheRowsAlreadyShown() async throws {
        let pages = try pages()
        let store = try await store([pages[0]])
        let first = try await store.rows()
        #expect(first.map(\.mergeKey) == [photoKey, cyKey])

        // The original of Bo's photo (dated before Ana's boost of it) and
        // Cy's post straight from Bluesky (dated before Ed's boost) arrive
        // later, along with more boosts.
        for page in pages.dropFirst() {
            try await store.insert(page)
        }
        let after = try await store.rows()
        let kept = after.filter { first.map(\.mergeKey).contains($0.mergeKey) }
        #expect(kept.map(\.id) == first.map(\.id))
        #expect(kept.map(\.sortDate) == first.map(\.sortDate))
        #expect(kept.map(\.sourceID) == [exampleHome.id, exampleHome.id])
        // Only Sam's post is new, and it comes after both.
        #expect(after.map(\.mergeKey) == [photoKey, cyKey, samKey])
    }

    @Test func fetchOrderChangesWhereRowsSitButNotWhatMerges() async throws {
        let rows = try await store(try pages().reversed()).rows()
        #expect(Set(rows.map(\.mergeKey)) == [photoKey, cyKey, samKey])
        let boosters = Dictionary(uniqueKeysWithValues: rows.map { ($0.mergeKey, $0.boostedBy) })
        #expect(boosters[photoKey] == ["Ana Ruiz", "Dee"])
        #expect(boosters[cyKey] == ["Ed"])
        #expect(boosters[samKey] == ["Ana Ruiz", "Lee"])
        // Fetched first this time, Cy's own post places its row before
        // Ed's boost of it.
        let cy = try #require(rows.first { $0.mergeKey == cyKey })
        #expect(cy.sourceID == blueskyMe.id)
    }

    @Test func oneAccountsViewNamesOnlyTheBoostsItSaw() async throws {
        let store = try await store(try pages())
        let rows = try await store.rows(in: .sources([otherHome.id]))
        #expect(rows.map(\.mergeKey) == [photoKey])
        #expect(rows[0].boostedBy == ["Ana Ruiz", "Dee"])
        #expect(rows[0].sourceID == otherHome.id)
    }

    @Test func sameNamedBoostersFromDifferentAccountsAreBothNamed() async throws {
        // Ana on Mastodon and Ana on Bluesky are different accounts.
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [exampleHome, blueskyMe])
        try await store.insert(try mastodon("mastodon-example-social", exampleHome, host: "example.social"))
        var other = try #require(try bluesky("bluesky-me", blueskyMe).first { $0.mergeKey == samKey })
        other.mergeKey = photoKey
        try await store.insert([other])
        let photo = try #require(try await store.rows().first { $0.mergeKey == photoKey })
        #expect(photo.boostedBy == ["Ana Ruiz", "Ana Ruiz"])
    }
}

@Suite struct BoosterIdentity {
    @Test func mastodonBoostersAreNamedByProfile() throws {
        let example = try mastodon("mastodon-example-social", exampleHome, host: "example.social")
        let other = try mastodon("mastodon-other-example", otherHome, host: "other.example")
        // Ana is local on one instance and remote on the other.
        #expect(example.first { $0.mergeKey == photoKey }?.boostedByID == "https://example.social/@ana")
        #expect(other.first { $0.boostedBy == "Ana Ruiz" }?.boostedByID == "https://example.social/@ana")
        // Bo's own post isn't a boost.
        #expect(other.first { $0.boostedBy == nil }?.boostedByID == nil)
    }

    @Test func mastodonBoosterWithoutAProfileURLUsesTheFullHandle() {
        let account = Mastodon.Account(id: "1", acct: "dee", username: "dee", displayName: "Dee", url: nil)
        #expect(MastodonMapper.accountKey(account, instanceHost: "other.example") == "@dee@other.example")
    }

    @Test func blueskyBoostersAreNamedByDID() throws {
        let items = try bluesky("bluesky-me2", blueskyMe2)
        #expect(items.map(\.boostedByID) == ["did:plc:lee", "did:plc:ana"])
    }

    @Test func storedBoostersWithoutAnIDFallBackToTheirName() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [exampleHome, otherHome])
        func boost(_ remoteID: String, in source: Source, by name: String, at offset: TimeInterval) -> Item {
            Item(
                sourceID: source.id, remoteID: remoteID, kind: .post, mergeKey: "p",
                authorName: "Bo", authorHandle: "@bo", body: "Post",
                publishedAt: fetchedAt, fetchedAt: fetchedAt.addingTimeInterval(offset), sortDate: fetchedAt.addingTimeInterval(offset),
                boostedBy: name
            )
        }
        try await store.insert([
            boost("1", in: exampleHome, by: "Ana Ruiz", at: 10),
            boost("2", in: otherHome, by: "Ana Ruiz", at: 10),
            boost("3", in: otherHome, by: "Dee", at: 20),
        ])
        #expect(try await store.rows().first?.boostedBy == ["Ana Ruiz", "Dee"])
    }
}

@Suite struct BridgedPosts {
    @Test(arguments: [
        ("https://bsky.brid.gy/convert/ap/at://did:plc:cy/app.bsky.feed.post/3lcy1", cyKey),
        ("https://bsky.brid.gy/convert/ap/at%3A%2F%2Fdid%3Aplc%3Acy%2Fapp.bsky.feed.post%2F3lcy1", cyKey),
        // Anything else stays the ActivityPub URI.
        ("https://other.example/users/bo/statuses/4400", photoKey),
        ("https://bsky.brid.gy/convert/ap/https://example.com/post", "https://bsky.brid.gy/convert/ap/https://example.com/post"),
        ("https://bsky.brid.gy/r/https://example.com/post", "https://bsky.brid.gy/r/https://example.com/post"),
    ])
    func mastodonMergeKey(uri: String, expected: String) {
        #expect(MastodonMapper.mergeKey(uri: uri) == expected)
    }
}

// Ana posts on example.social; Bridgy Fed copies the post into Bluesky,
// where the copy names the original only by its web address. The reader
// follows Ana from a Mastodon account and from a Bluesky account.
private let anaKey = "https://example.social/users/ana/statuses/5500"
private let anaURL = "https://example.social/@ana/5500"
private let anaCopyKey = "at://did:plc:anabridged/app.bsky.feed.post/3lana5"
private let anaFullText = String(repeating: "Long words ", count: 40) + "end"

private func mastodonStatus(uri: String = anaKey, url: String? = anaURL, text: String = anaFullText, spoiler: String = "") -> String {
    """
    {"id": "5500", "created_at": "2026-10-24T09:00:00.000Z", "in_reply_to_id": null, "in_reply_to_account_id": null,
     "spoiler_text": "\(spoiler)", "uri": "\(uri)", "url": \(url.map { "\"\($0)\"" } ?? "null"), "content": "<p>\(text)</p>",
     "account": {"id": "1", "username": "ana", "acct": "ana", "display_name": "Ana", "url": "https://example.social/@ana"},
     "mentions": [], "media_attachments": [], "card": null, "filtered": [], "reblog": null}
    """
}

private func blueskyEntry(uri: String = anaCopyKey, original: String? = anaURL, text: String = "Long words… [bridged]",
                          indexedAt: String = "2026-10-24T09:00:05.000Z", repostedBy: String? = nil) -> String {
    let originalField = original.map { #", "bridgyOriginalUrl": "\#($0)""# } ?? ""
    let reason = repostedBy.map {
        #", "reason": {"$type": "app.bsky.feed.defs#reasonRepost", "by": {"did": "did:plc:\#($0)", "handle": "\#($0).bsky.social", "displayName": "\#($0)"}, "uri": "at://did:plc:\#($0)/app.bsky.feed.repost/3lrep", "cid": "bafyrep", "indexedAt": "2026-10-24T09:30:00.000Z"}"#
    } ?? ""
    return """
    {"post": {"uri": "\(uri)", "cid": "bafyana", "author": {"did": "did:plc:anabridged", "handle": "ana.example.social.ap.brid.gy", "displayName": "Ana"},
              "record": {"$type": "app.bsky.feed.post", "text": "\(text)", "createdAt": "2026-10-24T09:00:00Z"\(originalField)},
              "indexedAt": "\(indexedAt)"}\(reason)}
    """
}

private func mastodonItems(_ statuses: [String], _ source: Source = exampleHome) throws -> [Item] {
    let decoded = try Mastodon.decoder().decode([Mastodon.Status].self, from: Data("[\(statuses.joined(separator: ","))]".utf8))
    return MastodonMapper.items(from: decoded, source: source.id, instanceHost: "example.social", fetchedAt: fetchedAt)
}

private func blueskyItems(_ entries: [String], _ source: Source = blueskyMe) throws -> [Item] {
    let page = try JSONDecoder().decode(FeedPage.self, from: Data(#"{"feed": [\#(entries.joined(separator: ","))]}"#.utf8))
    return BlueskyMapping.items(page, sourceID: source.id, fetchedAt: fetchedAt)
}

private func bridgedStore() async throws -> InfluxStore {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [exampleHome, otherHome, blueskyMe, blueskyMe2])
    return store
}

@Suite struct FediversePostsBridgedIntoBluesky {
    @Test func aBridgedCopyLinksToTheOriginal() throws {
        let copy = try #require(try blueskyItems([blueskyEntry()]).first)
        #expect(copy.mergeKey == anaCopyKey)
        #expect(copy.url == anaURL)
        // A post written on Bluesky still opens there, and an original
        // that isn't a web address is ignored.
        let native = try #require(try blueskyItems([blueskyEntry(original: nil)]).first)
        #expect(native.url == "https://bsky.app/profile/did:plc:anabridged/post/3lana5")
        let odd = try #require(try blueskyItems([blueskyEntry(original: "javascript:alert(1)")]).first)
        #expect(odd.url == "https://bsky.app/profile/did:plc:anabridged/post/3lana5")
    }

    @Test(arguments: [
        // Anyone can write the field: only Bridgy Fed's own accounts count.
        "mallory.bsky.social",
        "ana.example.social.ap.brid.gy.evil.example",
        // A bridged account names its own instance, and no other.
        "ana.other.example.ap.brid.gy",
        "example.social.ap.brid.gy",
    ])
    func anOriginalCountsOnlyFromItsBridgedAccount(handle: String) async throws {
        let entry = blueskyEntry().replacingOccurrences(of: "ana.example.social.ap.brid.gy", with: handle)
        let copy = try #require(try blueskyItems([entry]).first)
        #expect(copy.url == "https://bsky.app/profile/did:plc:anabridged/post/3lana5")
        let store = try await bridgedStore()
        try await store.insert(try mastodonItems([mastodonStatus()]))
        try await store.insert([copy])
        #expect(try await store.rows().count == 2)
    }

    @Test(arguments: [true, false])
    func thePostAndItsCopyShowAsOneRowWhicheverArrivesFirst(mastodonFirst: Bool) async throws {
        let store = try await bridgedStore()
        let fromMastodon = try mastodonItems([mastodonStatus()])
        let fromBluesky = try blueskyItems([blueskyEntry()])
        for page in mastodonFirst ? [fromMastodon, fromBluesky] : [fromBluesky, fromMastodon] {
            try await store.insert(page)
        }
        let rows = try await store.rows()
        #expect(rows.count == 1)
        // The copy stored first keeps its key; nothing stored is re-keyed.
        #expect(rows.first?.mergeKey == (mastodonFirst ? anaKey : anaCopyKey))
        // Shown from the Mastodon copy, with the text Bridgy Fed cut.
        #expect(rows.first?.sourceID == exampleHome.id)
        #expect(rows.first?.body == anaFullText)
        // Each side still holds its own copy, for its account's actions.
        #expect(try await store.viewer(mergeKey: rows[0].mergeKey, sourceID: blueskyMe.id) != nil)
        #expect(try await store.viewer(mergeKey: rows[0].mergeKey, sourceID: exampleHome.id) != nil)
    }

    @Test func moreCopiesFromOtherAccountsAndBoostsJoinTheSameRow() async throws {
        let store = try await bridgedStore()
        try await store.insert(try blueskyItems([blueskyEntry()]))
        try await store.insert(try mastodonItems([mastodonStatus()]))
        try await store.insert(try blueskyItems([blueskyEntry(repostedBy: "dee")], blueskyMe2))
        try await store.insert(try mastodonItems([mastodonStatus()], otherHome))
        let rows = try await store.rows()
        #expect(rows.map(\.mergeKey) == [anaCopyKey])
        #expect(rows.first?.boostedBy == ["dee"])
        #expect(rows.first?.body == anaFullText)
    }

    @Test(arguments: [true, false])
    func aPairStaysJoinedAfterTheOtherSideHasGone(mastodonFirst: Bool) async throws {
        let store = try await bridgedStore()
        let fromMastodon = try mastodonItems([mastodonStatus()])
        let fromBluesky = try blueskyItems([blueskyEntry()])
        for page in mastodonFirst ? [fromMastodon, fromBluesky] : [fromBluesky, fromMastodon] {
            try await store.insert(page)
        }
        let key = try #require(try await store.rows().first?.mergeKey)
        // The first side's source goes; its other copies come in later.
        try await store.delete(sourceID: mastodonFirst ? exampleHome.id : blueskyMe.id)
        if mastodonFirst {
            try await store.insert(try mastodonItems([mastodonStatus()], otherHome))
        } else {
            try await store.insert(try blueskyItems([blueskyEntry()], blueskyMe2))
        }
        #expect(try await store.rows().map(\.mergeKey) == [key])
    }

    @Test func onlyTheSameAddressMerges() async throws {
        let store = try await bridgedStore()
        // Same words, same author, same minute, but a different post.
        try await store.insert(try mastodonItems([mastodonStatus()]))
        try await store.insert(try blueskyItems([blueskyEntry(original: "https://example.social/@ana/5501")]))
        // And a Bluesky post written on Bluesky, with the same text.
        try await store.insert(try blueskyItems([blueskyEntry(uri: "at://did:plc:anabridged/app.bsky.feed.post/3lana6", original: nil, text: anaFullText)]))
        #expect(try await store.rows().count == 3)
    }

    @Test func twoPostsOnOneServiceWithTheSameLinkStayApart() async throws {
        let store = try await bridgedStore()
        try await store.insert(try mastodonItems([mastodonStatus()]))
        try await store.insert(try mastodonItems([mastodonStatus(uri: "https://example.social/users/ana/statuses/5500/other")], otherHome))
        #expect(try await store.rows().count == 2)
    }

    @Test(arguments: [(true, false), (true, true), (false, false)])
    func anotherPostWithTheSameLinkStaysApartFromAJoinedPair(mastodonFirst: Bool, bridgeRemoved: Bool) async throws {
        let store = try await bridgedStore()
        let fromMastodon = try mastodonItems([mastodonStatus()])
        let fromBluesky = try blueskyItems([blueskyEntry()])
        for page in mastodonFirst ? [fromMastodon, fromBluesky] : [fromBluesky, fromMastodon] {
            try await store.insert(page)
        }
        if bridgeRemoved { try await store.delete(sourceID: blueskyMe.id) }
        // A different post on the same server claiming the same link.
        // Same author and time, too: only its ID tells it apart.
        let other = mastodonStatus(uri: "https://example.social/users/ana/statuses/5599")
        try await store.insert(try mastodonItems([other], otherHome))
        #expect(try await store.rows().count == 2)
    }

    @Test(arguments: [true, false])
    func anotherPostStaysApartAfterTheFirstStoredSideHasGone(mastodonFirst: Bool) async throws {
        let store = try await bridgedStore()
        let fromMastodon = try mastodonItems([mastodonStatus()])
        let fromBluesky = try blueskyItems([blueskyEntry()])
        for page in mastodonFirst ? [fromMastodon, fromBluesky] : [fromBluesky, fromMastodon] {
            try await store.insert(page)
        }
        try await store.delete(sourceID: mastodonFirst ? exampleHome.id : blueskyMe.id)
        if mastodonFirst {
            try await store.insert(try mastodonItems([mastodonStatus(uri: "https://example.social/users/ana/statuses/5599")], otherHome))
        } else {
            try await store.insert(try blueskyItems([blueskyEntry(uri: "at://did:plc:anabridged/app.bsky.feed.post/3lana9")], blueskyMe2))
        }
        #expect(try await store.rows().count == 2)
    }

    @Test func twoPostsInOnePageClaimingThePairsLinkDontBothJoin() async throws {
        let store = try await bridgedStore()
        try await store.insert(try blueskyItems([blueskyEntry()]))
        let other = mastodonStatus(uri: "https://example.social/users/ana/statuses/5599")
            .replacingOccurrences(of: "\"id\": \"5500\"", with: "\"id\": \"5599\"")
        try await store.insert(try mastodonItems([mastodonStatus(), other]))
        #expect(try await store.rows().count == 2)
    }

    @Test func aLinkOnAnotherServerIsNotTrusted() async throws {
        let store = try await bridgedStore()
        // Another server's post claims Ana's link; the real copy arrives
        // from Bluesky, and the genuine Mastodon post after it.
        try await store.insert(try mastodonItems([mastodonStatus(uri: "https://evil.example/users/x/statuses/1")], otherHome))
        try await store.insert(try blueskyItems([blueskyEntry()]))
        try await store.insert(try mastodonItems([mastodonStatus()]))
        let rows = try await store.rows()
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.mergeKey)) == ["https://evil.example/users/x/statuses/1", anaCopyKey])
    }

    @Test func aContentWarningShowsFromTheMastodonCopy() async throws {
        let store = try await bridgedStore()
        try await store.insert(try blueskyItems([blueskyEntry()]))
        try await store.insert(try mastodonItems([mastodonStatus(spoiler: "Spoilers")]))
        let row = try #require(try await store.rows().first)
        #expect(row.sourceID == exampleHome.id)
        #expect(row.body.contains("Spoilers"))
    }

    @Test func aPostInAThreadIsFiledUnderItsStoredKey() async throws {
        let store = try await bridgedStore()
        try await store.insert(try blueskyItems([blueskyEntry()]))
        let inThread = try #require(try mastodonItems([mastodonStatus()]).first)
        #expect(try await store.joined(inThread).mergeKey == anaCopyKey)
        let unrelated = try #require(try mastodonItems([mastodonStatus(uri: "https://example.social/users/ana/statuses/9", url: "https://example.social/@ana/9")]).first)
        #expect(try await store.joined(unrelated).mergeKey == "https://example.social/users/ana/statuses/9")
    }

    @Test func copiesStoredApartBeforeThisStayApartAndKeepTheirBookmarks() async throws {
        let store = try await bridgedStore()
        // Stored before copies took the original's link.
        var old = try #require(try blueskyItems([blueskyEntry(original: nil)]).first)
        old.viewer = Item.Viewer(bookmarked: true)
        try await store.insert([old])
        try await store.insert(try mastodonItems([mastodonStatus()]))
        // The bookmark list now gives the copy with the original's link.
        var listed = try #require(try blueskyItems([blueskyEntry()]).first)
        listed.viewer = Item.Viewer(bookmarked: true)
        try await store.storeBookmarks([listed], isComplete: true, in: blueskyMe.id, fetchedAt: fetchedAt.addingTimeInterval(60))
        #expect(try await store.viewer(mergeKey: anaCopyKey, sourceID: blueskyMe.id)?.bookmarked == true)
        #expect(try await store.rows().count == 2)
    }

    @Test func aBookmarkListKeepsItsBookmarkOnTheJoinedCopy() async throws {
        let store = try await bridgedStore()
        try await store.insert(try blueskyItems([blueskyEntry()]))
        var bookmarked = try #require(try mastodonItems([mastodonStatus()]).first)
        bookmarked.viewer = Item.Viewer(bookmarked: true)
        try await store.storeBookmarks([bookmarked], isComplete: true, in: exampleHome.id, fetchedAt: fetchedAt)
        let viewer = try await store.viewer(mergeKey: anaCopyKey, sourceID: exampleHome.id)
        #expect(viewer?.bookmarked == true)
    }
}
