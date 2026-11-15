import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import InfluxKit

// A rich feed's post and a copy of the same post from another connector
// show as one row (ADR 0014, 0031). Posts arrive through the real
// connectors, refresher and store; only HTTP is faked.

private let now = RichFixtures.now
private let published = "2026-11-02T09:30:00Z"

/// The native identity the legacy fixture's rich item names, and its alias.
private let nativeKey = "https://posts.example.com/authors/ada/posts/1001"
private let nativeAlias = "urn:uuid:69f10a5e-8115-56eb-9d22-d7c2280512ad"
private let richCanonical = "urn:uuid:0193a1b2-0000-7000-8000-000000000030"
private let richKey = "sammy-post:example.com:\(richCanonical)"

private let mastodonAccount = "@reader@example.social"
private let mastodon = MastodonMapper.homeSource(accountID: mastodonAccount, colorIndex: 2)
private let bluesky = Source(id: "bluesky:did:plc:reader:following", kind: .blueskyFollowing, accountID: "did:plc:reader", title: "Bluesky", colorIndex: 3)
private let rss = Source(id: "rss:https://www.example.com/feed.xml", kind: .rss, title: "Example", url: "https://www.example.com/feed.xml", colorIndex: 4)
private let rich = RichFixtures.source(.post)
private let otherRichFeedID = "0193a1b2-0000-7000-8000-00000000f004"
private let otherRich = RichFixtures.source(.post, feedID: otherRichFeedID)

/// A rich post as the contract sends it.
private func richPost(id: String = "urn:uuid:7bba3b0c-45df-8386-8c67-1dafda0e9042", canonical: String = richCanonical,
                      aliases: [String] = [nativeAlias], text: String = "A post the source also knows by its legacy identity.") -> [String: Any] {
    [
        "id": id, "canonicalId": canonical, "aliases": aliases,
        "classification": ["kind": "post", "retentionDays": 7], "capabilities": ["text"],
        "url": "https://www.example.com/author/posts/legacy", "author": ["name": "Example Author"],
        "text": text, "links": [] as [Any], "publishedAt": published,
    ]
}

/// The legacy fixture's rich item, exactly as the server generated it.
private func fixtureRichItem() throws -> [String: Any] {
    let legacy = try RichFixtures.object("rich-feed-legacy-identity.json")
    return try #require((legacy["storedIdentity"] as? [String: Any])?["richItem"] as? [String: Any])
}

/// A Sammy server serving each feed one rich page of `posts`.
private func richConnector(_ feeds: [String: [[String: Any]]]) throws -> SammyFeedConnector {
    let headers = try RichFixtures.headers("page")
    var pages: [String: Data] = [:]
    for (feedID, posts) in feeds {
        pages[feedID] = try JSONSerialization.data(withJSONObject: [
            "format": "sammy.rich-feed", "version": 1,
            "feed": ["id": feedID, "title": "Feed", "feedUrl": "\(RichFixtures.origin)/api/v1/feeds/\(feedID)"],
            "items": posts,
        ] as [String: Any])
    }
    let http = FakeHTTPClient { [pages] request in
        guard let path = request.url?.path, path.hasPrefix("/api/v1/feeds/"),
              let page = pages[String(path.dropFirst("/api/v1/feeds/".count))] else { return .init(status: 404) }
        return .init(headers: headers, body: page)
    }
    return try RichFixtures.connector(http)
}

/// A Mastodon status as the API sends it.
private func status(_ id: String, uri: String = nativeKey, url: String? = "https://posts.example.com/@ada/1001",
                    at date: String = "2026-11-02T09:30:00.000Z", text: String = "Short native copy") -> [String: Any] {
    var status: [String: Any] = [
        "id": id, "uri": uri, "created_at": date, "content": "<p>\(text)</p>", "spoiler_text": "",
        "account": ["id": "109", "username": "ada", "acct": "ada@posts.example.com", "display_name": "Ada"],
        "mentions": [] as [Any], "media_attachments": [] as [Any], "favourited": false, "reblogged": false, "bookmarked": false,
    ]
    if let url { status["url"] = url }
    return status
}

/// A Mastodon server whose home timeline is `statuses`.
private func mastodonConnector(_ statuses: [[String: Any]]) -> MastodonConnector {
    let timeline = try! JSONSerialization.data(withJSONObject: statuses)
    let http = FakeHTTPClient { request in
        guard request.url?.path == "/api/v1/timelines/home" else { return .init(status: 404) }
        return .init(body: timeline)
    }
    return MastodonConnector(accountID: mastodonAccount, instance: URL(string: "https://example.social")!, accessToken: "t", http: http, resolver: .testing(http))
}

/// A store with the Mastodon home, Bluesky, an RSS feed and two rich feeds.
private func makeStore() async throws -> InfluxStore {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [mastodon, bluesky, rss, rich, otherRich], at: now)
    return store
}

/// The posts around the joined one, so there is an unread boundary.
private var before: [String: Any] { status("900", uri: "https://posts.example.com/authors/ada/posts/900", url: nil, at: "2026-11-02T08:00:00.000Z", text: "Earlier") }
private var after: [String: Any] { status("901", uri: "https://posts.example.com/authors/ada/posts/901", url: nil, at: "2026-11-02T11:00:00.000Z", text: "Later") }

/// The bytes a hex string spells, or nil when it doesn't.
private func hexBytes(_ hex: String) -> [UInt8]? {
    let digits = Array(hex.utf8)
    guard digits.count % 2 == 0 else { return nil }
    var bytes: [UInt8] = []
    for index in stride(from: 0, to: digits.count, by: 2) {
        guard let byte = UInt8(String(decoding: digits[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
        bytes.append(byte)
    }
    return bytes
}

private func refresh(_ store: InfluxStore, _ source: Source, _ connector: any Connector, at offset: TimeInterval = 0) async throws -> Int {
    guard case .fetched(let new) = try await Refresher(store: store).refresh(source, with: connector, now: now.addingTimeInterval(offset)) else {
        Issue.record("refresh of \(source.id) failed")
        return -1
    }
    return new
}

/// How the store files each item: its merge key and own key.
private func keys(_ store: InfluxStore) async throws -> [String: (mergeKey: String, postKey: String?)] {
    try await store.writer.read { db in
        var keys: [String: (String, String?)] = [:]
        for item in try Item.fetchAll(db) { keys[item.remoteID] = (item.mergeKey, item.postKey) }
        return keys
    }
}

@Suite struct LegacyPostIdentities {
    @Test func everyVectorIsComputedFromItsExactBytes() throws {
        let legacy = try RichFixtures.object("rich-feed-legacy-identity.json")
        #expect(legacy["algorithm"] as? String == "uuidv5")
        #expect(LegacyPostIdentity.uuidBytes(try #require(legacy["namespace"] as? String)) == LegacyPostIdentity.namespace)
        // The namespace is UUIDv5 of the URL namespace and the fixed name.
        let derivation = try #require(legacy["namespaceDerivation"] as? [String: String])
        #expect(LegacyPostIdentity.uuidBytes(try #require(derivation["namespace"])) == LegacyPostIdentity.urlNamespace)
        #expect(LegacyPostIdentity.uuidV5(namespace: LegacyPostIdentity.urlNamespace, name: Array(try #require(derivation["name"]).utf8))
            == legacy["namespace"] as? String)

        let vectors = try #require(legacy["vectors"] as? [[String: String]])
        #expect(vectors.count == 10)
        var aliases: [String: String] = [:]
        for vector in vectors {
            let label = try #require(vector["label"]), alias = try #require(vector["alias"])
            var key = try #require(vector["key"])
            if let hex = vector["utf8Hex"] {
                // The bytes the server hashed, whatever a copy of the file
                // did to the key's text.
                let bytes = try #require(hexBytes(hex))
                key = String(decoding: bytes, as: UTF8.self)
                #expect(Array(key.utf8) == bytes, "\(label)")
            }
            #expect(LegacyPostIdentity.alias(of: key) == alias, "\(label)")
            aliases[label] = alias
        }
        // G and H are the same text to Swift and two identities here.
        let hexes = vectors.reduce(into: [String: String]()) { $0[$1["label"] ?? ""] = $1["utf8Hex"] }
        let g = String(decoding: try #require(hexes["G"].flatMap(hexBytes)), as: UTF8.self)
        let h = String(decoding: try #require(hexes["H"].flatMap(hexBytes)), as: UTF8.self)
        #expect(g == h)
        #expect(aliases["G"] != aliases["H"])
        #expect(Set(aliases.values).count == vectors.count)
    }

    @Test func emptyAndInvalidKeysHaveNoAlias() throws {
        let legacy = try RichFixtures.object("rich-feed-legacy-identity.json")
        let refused = try #require(legacy["refused"] as? [[String: String]])
        #expect(refused.count == 2)
        for entry in refused {
            let hex = try #require(entry["utf16Hex"])
            let bytes = try #require(hexBytes(hex))
            let units = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) << 8 | UInt16(bytes[$0 + 1]) }
            #expect(LegacyPostIdentity.alias(utf16: units) == nil, "\(hex)")
        }
        #expect(LegacyPostIdentity.alias(of: "") == nil)
    }

    @Test func aJoinedRowIsNamedByItsOwnKeyNotTheRowsKey() throws {
        let legacy = try RichFixtures.object("rich-feed-legacy-identity.json")
        let joined = try #require(legacy["alreadyJoined"] as? [String: String])
        let native = try #require(joined["nativeIdentity"]), reading = try #require(joined["readingKey"])
        let own = PostIdentity.nativeIdentity(kind: .post, mergeKey: reading, postKey: native, sourceKind: .mastodonHome)
        #expect(own == native)
        #expect(own.flatMap(LegacyPostIdentity.alias(of:)) == joined["alias"])
        #expect(LegacyPostIdentity.alias(of: reading) != joined["alias"])
    }

    @Test func onlyANativePostsOwnURIIsEligible() {
        let eligible: [(Source.Kind, String)] = [
            (.mastodonHome, "https://posts.example.com/1"), (.mastodonList, "https://posts.example.com/1"),
            (.mastodonHome, "at://did:plc:a/app.bsky.feed.post/1"), (.blueskyFollowing, "at://did:plc:a/app.bsky.feed.post/1"),
            (.blueskyFeed, "at://did:plc:a/app.bsky.feed.post/1"),
        ]
        for (kind, key) in eligible {
            #expect(PostIdentity.nativeIdentity(kind: .post, mergeKey: key, postKey: nil, sourceKind: kind) == key, "\(kind) \(key)")
        }
        let ineligible: [(Item.Kind, Source.Kind, String)] = [
            // An article, an RSS item, a rich post, a key only its source
            // uses, an ID a Bluesky service gave that isn't `at://`.
            (.article, .mastodonHome, "https://posts.example.com/1"),
            (.post, .rss, "https://posts.example.com/1"),
            (.post, .sammyFeed, "https://posts.example.com/1"),
            (.post, .mastodonHome, "mastodon:@reader@example.social:home#1"),
            (.post, .blueskyFollowing, "https://posts.example.com/1"),
            (.post, .mastodonHome, "https://"),
            (.post, .mastodonHome, richKey),
        ]
        for (itemKind, sourceKind, key) in ineligible {
            #expect(PostIdentity.nativeIdentity(kind: itemKind, mergeKey: key, postKey: nil, sourceKind: sourceKind) == nil, "\(sourceKind) \(key)")
        }
    }

    @Test(arguments: [
        ("", "da39a3ee5e6b4b0d3255bfef95601890afd80709"),
        ("abc", "a9993e364706816aba3e25717850c26c9cd0d89d"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "84983e441c3bd26ebaae4aa1f95129e5e54670f1"),
        (String(repeating: "a", count: 1000), "291e9a6c66994949b57ba5e650361e98fc36b1ba"),
    ])
    func sha1MatchesItsStandardVectors(message: String, digest: String) {
        #expect(SHA1.hash(Array(message.utf8)).map { String(format: "%02x", $0) }.joined() == digest)
    }
}

@Suite struct RichPostsJoinTheirOtherCopies {
    @Test func aRichPostArrivingAfterItsNativeCopyJoinsItsRowAndKeepsThePlace() async throws {
        let store = try await makeStore()
        #expect(try await refresh(store, mastodon, mastodonConnector([before, status("1001"), after])) == 3)
        let rows = try await store.rows()
        let native = try #require(rows.first { $0.mergeKey == nativeKey })
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (native.sortDate, native.mergeKey), at: now))
        _ = try await store.moveReadingPlace(viewID: SavedView.allID, to: (native.sortDate, native.mergeKey), at: now)

        #expect(try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]]), at: 60) == 1)
        let joined = try await store.rows()
        #expect(joined.map(\.mergeKey) == rows.map(\.mergeKey))
        #expect(joined.map(\.sortDate) == rows.map(\.sortDate))
        // The row is shown from the rich copy now.
        let row = try #require(joined.first { $0.mergeKey == nativeKey })
        #expect(row.sourceID == rich.id)
        #expect(row.body == "A post the source also knows by its legacy identity.")
        // The rich copy is filed under the row's key and keeps its own.
        #expect(try await keys(store)["urn:uuid:7bba3b0c-45df-8386-8c67-1dafda0e9042"]! == (nativeKey, richKey))
        // The place and the unread boundary are where they were.
        #expect(try await store.lastReadMarker(viewID: SavedView.allID)?.mergeKey == nativeKey)
        #expect(try await store.readingPlace(viewID: SavedView.allID)?.mergeKey == nativeKey)
        #expect(joined.drop { $0.mergeKey != nativeKey }.dropFirst().count == 1)
        // A view of the native source alone still shows its own copy.
        #expect(try await store.rows(in: .sources([mastodon.id])).first { $0.mergeKey == nativeKey }?.sourceID == mastodon.id)
    }

    @Test func aNativePostArrivingAfterItsRichCopyJoinsTheRichRow() async throws {
        let store = try await makeStore()
        #expect(try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]])) == 1)
        #expect(try await refresh(store, mastodon, mastodonConnector([before])) == 1)
        let rows = try await store.rows()
        let post = try #require(rows.first { $0.mergeKey == richKey })
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (post.sortDate, post.mergeKey), at: now))
        _ = try await store.moveReadingPlace(viewID: SavedView.allID, to: (post.sortDate, post.mergeKey), at: now)

        #expect(try await refresh(store, mastodon, mastodonConnector([before, status("1001"), after]), at: 60) == 2)
        let joined = try await store.rows()
        #expect(joined.count == 3)
        let row = try #require(joined.first { $0.mergeKey == richKey })
        #expect(row.sortDate == post.sortDate)
        #expect(row.sourceID == rich.id)
        // Exactly this verified join gives a native post a rich post's key,
        // and it keeps its own.
        #expect(try await keys(store)["1001"]! == (richKey, nativeKey))
        #expect(try await store.lastReadMarker(viewID: SavedView.allID)?.mergeKey == richKey)
        #expect(try await store.readingPlace(viewID: SavedView.allID)?.mergeKey == richKey)
        #expect(joined.last?.body == "Later")
    }

    @Test func aJoinedRowShowsThePictureOfWhicheverCopyHasOneTheRichCopysFirst() async throws {
        var native = status("1001")
        var account = try #require(native["account"] as? [String: Any])
        account["avatar"] = "https://posts.example.com/avatars/ada.png"
        account["avatar_static"] = "https://posts.example.com/avatars/ada.png"
        native["account"] = account
        let store = try await makeStore()
        #expect(try await refresh(store, mastodon, mastodonConnector([native])) == 1)
        // The rich copy has no picture: the row, shown from it, has the Mastodon copy's.
        #expect(try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]]), at: 60) == 1)
        var row = try #require(try await store.rows().first { $0.mergeKey == nativeKey })
        #expect(row.sourceID == rich.id)
        #expect(row.authorAvatar == "https://posts.example.com/avatars/ada.png")
        // Once the rich copy has one, the row has the rich copy's.
        var pictured = try fixtureRichItem()
        pictured["author"] = ["name": "Example Author", "avatar": ["id": "example-avatar-9"]]
        _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [pictured]]), at: 120)
        row = try #require(try await store.rows().first { $0.mergeKey == nativeKey })
        let accountID = try #require(rich.accountID)
        let reference = try #require(SammyMediaReference(accountID: accountID, feedID: RichFixtures.richFeedID, mediaID: "example-avatar-9"))
        #expect(row.authorAvatar == reference.string)
        // A view of the Mastodon source alone keeps its own copy's picture.
        #expect(try await store.rows(in: .sources([mastodon.id])).first { $0.mergeKey == nativeKey }?.authorAvatar
            == "https://posts.example.com/avatars/ada.png")
    }

    @Test func bothJoinedInOneBatchWhicheverComesFirst() async throws {
        for nativeFirst in [true, false] {
            let store = try await makeStore()
            let page = try await richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]]).fetch(RichFixtures.request(rich), from: rich)
            let native = try await mastodonConnector([status("1001", at: nativeFirst ? "2026-11-02T09:29:00.000Z" : "2026-11-02T09:31:00.000Z")])
                .fetch(FetchRequest(direction: .newer, cursor: nil, notBefore: now.addingTimeInterval(-InfluxStore.postRetention), now: now), from: mastodon)
            try await store.insert(page.items + native.items, identities: page.identities)
            let rows = try await store.rows()
            #expect(rows.count == 1, "\(nativeFirst)")
            #expect(rows.first?.mergeKey == (nativeFirst ? nativeKey : richKey), "\(nativeFirst)")
            #expect(rows.first?.sourceID == rich.id, "\(nativeFirst)")
        }
    }

    @Test func theRowSurvivesARefetchAndAReopen() async throws {
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("RichPostIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("influx.sqlite").path
        let before: [TimelineRow]
        do {
            let store = try InfluxStore(path: path)
            try await store.save(sources: [mastodon, rich], at: now)
            _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]]))
            _ = try await refresh(store, mastodon, mastodonConnector([status("1001")]))
            before = try await store.rows()
            #expect(before.count == 1)
        }
        let reopened = try InfluxStore(path: path)
        #expect(try await reopened.rows() == before)
        #expect(try await refresh(reopened, rich, try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]]), at: 60) == 0)
        #expect(try await refresh(reopened, mastodon, mastodonConnector([status("1001")]), at: 60) == 0)
        #expect(try await reopened.rows() == before)
    }

    @Test func anotherFeedsCopyOfTheRichPostJoinsTheSameRow() async throws {
        let store = try await makeStore()
        _ = try await refresh(store, mastodon, mastodonConnector([status("1001")]))
        _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]]))
        // The same post in another feed: another row ID, the same canonical
        // ID, and an alias set that differs from the stored one, which
        // stands.
        let copy = richPost(id: "urn:uuid:7bba3b0c-45df-8386-8c67-1dafda0e9043", aliases: [])
        _ = try await refresh(store, otherRich, try richConnector([otherRichFeedID: [copy]]))
        let rows = try await store.rows()
        #expect(rows.count == 1)
        #expect(rows.first?.mergeKey == nativeKey)
        #expect(try await keys(store)["urn:uuid:7bba3b0c-45df-8386-8c67-1dafda0e9043"]! == (nativeKey, richKey))
        let set = try await store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT identity FROM itemIdentity JOIN item ON item.id = itemID WHERE item.remoteID = ? ORDER BY identity",
                                arguments: ["urn:uuid:7bba3b0c-45df-8386-8c67-1dafda0e9043"])
        }
        #expect(set == [richCanonical, nativeAlias].sorted())
        // A later native copy, from another account, joins it too.
        let second = MastodonMapper.homeSource(accountID: "@other@example.social", colorIndex: 5)
        try await store.save(sources: [second], at: now)
        let items = try await mastodonConnector([status("77")]).fetch(FetchRequest(direction: .newer, cursor: nil, notBefore: .distantPast, now: now), from: second)
        try await store.insert(items.items.map { var item = $0; item.sourceID = second.id; return item })
        #expect(try await store.rows().count == 1)
    }

    @Test func aChainOfRichPostsJoinsInOneBatchAndALateLinkJoinsTheEarlierEnd() async throws {
        let first = richPost(id: "urn:uuid:00000000-0000-8000-8000-000000000001", canonical: "urn:uuid:0193a1b2-0000-7000-8000-000000000015",
                             aliases: ["urn:uuid:0193a1b2-0000-7000-8000-000000000016"], text: "One post, three identities.")
        let middle = richPost(id: "urn:uuid:00000000-0000-8000-8000-000000000002", canonical: "urn:uuid:0193a1b2-0000-7000-8000-000000000016",
                              aliases: ["urn:uuid:0193a1b2-0000-7000-8000-000000000017"], text: "One post, three identities.")
        let last = richPost(id: "urn:uuid:00000000-0000-8000-8000-000000000003", canonical: "urn:uuid:0193a1b2-0000-7000-8000-000000000017",
                            aliases: [], text: "One post, three identities.")
        // In one page, in any order, the three are one row.
        for order in [[first, middle, last], [last, middle, first], [first, last, middle]] {
            let store = try await makeStore()
            _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: order]))
            #expect(try await store.rows().count == 1)
        }
        // Each end on its own first, then the link: it joins the earlier
        // row, and the ends stay apart, since nothing stored is re-keyed.
        let store = try await makeStore()
        _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [first]]))
        _ = try await refresh(store, otherRich, try richConnector([otherRichFeedID: [last]]), at: 60)
        #expect(try await store.rows().count == 2)
        let feedThree = RichFixtures.source(.post, feedID: "0193a1b2-0000-7000-8000-00000000f006")
        try await store.save(sources: [feedThree], at: now)
        _ = try await refresh(store, feedThree, try richConnector(["0193a1b2-0000-7000-8000-00000000f006": [middle]]), at: 120)
        #expect(try await store.rows().count == 2)
        #expect(try await keys(store)["urn:uuid:00000000-0000-8000-8000-000000000002"]?.mergeKey
            == "sammy-post:example.com:urn:uuid:0193a1b2-0000-7000-8000-000000000015")
        // Arriving the other way round, each copy joins the one before.
        let ordered = try await makeStore()
        _ = try await refresh(ordered, rich, try richConnector([RichFixtures.richFeedID: [first]]))
        _ = try await refresh(ordered, otherRich, try richConnector([otherRichFeedID: [middle]]), at: 60)
        try await ordered.save(sources: [feedThree], at: now)
        _ = try await refresh(ordered, feedThree, try richConnector(["0193a1b2-0000-7000-8000-00000000f006": [last]]), at: 120)
        #expect(try await ordered.rows().count == 1)
    }

}

@Suite struct OnlyTheSamePostJoins {
    @Test func articlesRSSItemsAndLookalikeKeysNeverJoin() async throws {
        let store = try await makeStore()
        // An RSS article whose GUID is the native key; a Mastodon post whose
        // URI differs only in case, and one only by a trailing slash; a
        // Bluesky item whose service sent the native key as its ID.
        let article = Item(sourceID: rss.id, remoteID: nativeKey, kind: .article, mergeKey: nativeKey, authorName: "Example", authorHandle: "example.com",
                           title: "An article", body: "", url: nativeKey, publishedAt: now, fetchedAt: now)
        _ = try await refresh(store, mastodon, mastodonConnector([
            status("1", uri: "https://Posts.example.com/authors/ada/posts/1001"),
            status("2", uri: "https://posts.example.com/authors/ada/posts/1001/"),
        ]))
        let lookalike = Item(sourceID: bluesky.id, remoteID: "b1", kind: .post, mergeKey: nativeKey, authorName: "Ada", authorHandle: "@ada",
                             body: "Lookalike", url: "https://bsky.app/profile/ada/post/1", publishedAt: now, fetchedAt: now)
        try await store.insert([article, lookalike])
        // The article and the lookalike share a key, so a row.
        #expect(try await store.rows().count == 3)
        _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]]))
        let rows = try await store.rows()
        #expect(rows.count == 4)
        #expect(rows.filter { $0.sourceID == rich.id }.map(\.mergeKey) == [richKey])
        // Nor does one stored after it.
        let late = Item(sourceID: bluesky.id, remoteID: "b2", kind: .post, mergeKey: nativeKey, authorName: "Ada", authorHandle: "@ada",
                        body: "Lookalike", publishedAt: now, fetchedAt: now)
        try await store.insert([late])
        #expect(try await keys(store)["b2"]?.mergeKey == nativeKey)
    }

    @Test func twoPostsSharingADisplayURLJoinOnlyTheOneNamed() async throws {
        let legacy = try RichFixtures.object("rich-feed-legacy-identity.json")
        let shared = try #require((legacy["sharedDisplayUrl"] as? [String: Any])?["posts"] as? [[String: String]])
        let store = try await makeStore()
        _ = try await refresh(store, mastodon, mastodonConnector(shared.enumerated().map { index, post in
            status("\(index + 1)", uri: post["key"]!, url: post["displayUrl"])
        }))
        #expect(try await store.rows().count == 2)
        _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [richPost(aliases: [shared[0]["alias"]!])]]))
        let rows = try await store.rows()
        #expect(rows.count == 2)
        #expect(rows.first { $0.sourceID == rich.id }?.mergeKey == shared[0]["key"])
    }

    @Test func idsThatDifferOnlyInTheirBytesAreTwoPosts() async throws {
        let legacy = try RichFixtures.object("rich-feed-legacy-identity.json")
        let vectors = try #require(legacy["vectors"] as? [[String: String]])
        let composed = try #require(vectors.first { $0["label"] == "G" }), decomposed = try #require(vectors.first { $0["label"] == "H" })
        let g = String(decoding: try #require(composed["utf8Hex"].flatMap(hexBytes)), as: UTF8.self)
        let h = String(decoding: try #require(decomposed["utf8Hex"].flatMap(hexBytes)), as: UTF8.self)
        #expect(g == h && Array(g.utf8) != Array(h.utf8))
        func native(_ id: String, _ key: String) -> Item {
            Item(sourceID: mastodon.id, remoteID: id, kind: .post, mergeKey: key, authorName: "Ada", authorHandle: "@ada", body: id,
                 publishedAt: now, fetchedAt: now)
        }
        // In one batch with a rich post naming only the composed one.
        let store = try await makeStore()
        let page = try await richConnector([RichFixtures.richFeedID: [richPost(aliases: [try #require(composed["alias"])])]])
            .fetch(RichFixtures.request(rich), from: rich)
        try await store.insert([native("g", g), native("h", h)] + page.items, identities: page.identities)
        let stored = try await keys(store)
        #expect(Array(try #require(stored["h"]).mergeKey.utf8) == Array(h.utf8))
        #expect(stored["h"]?.postKey == nil)
        // The rich post is the earlier, so the composed one joins its row.
        #expect(stored["g"]?.mergeKey == richKey)
        #expect(Array(try #require(stored["g"]?.postKey).utf8) == Array(g.utf8))
        #expect(try await store.rows().count == 2)
    }

    @Test func aliasesCountOnlyFromAConnectedRichFeed() async throws {
        let store = try await makeStore()
        _ = try await refresh(store, mastodon, mastodonConnector([status("1001")]))
        // Another server's feed, and an RSS item, offering the alias.
        let elsewhere = Source(id: SammyFeedConnector.sourceID(accountID: "s1@other.example.com", feedID: "f1"), kind: .sammyFeed,
                               accountID: "s1@other.example.com", title: "Elsewhere", colorIndex: 6, itemKind: .post)
        try await store.save(sources: [elsewhere], at: now)
        let claimed = Item(sourceID: elsewhere.id, remoteID: "x1", kind: .post, mergeKey: richKey, authorName: "A", authorHandle: "a",
                           body: "Claim", publishedAt: now, fetchedAt: now)
        let article = Item(sourceID: rss.id, remoteID: "r1", kind: .post, mergeKey: "https://www.example.com/r1", authorName: "A", authorHandle: "a",
                           body: "Claim", publishedAt: now, fetchedAt: now)
        try await store.insert([claimed, article], identities: [richKey: [richCanonical, nativeAlias], "https://www.example.com/r1": [nativeAlias]])
        #expect(try await store.rows().count == 3)
        #expect(try await keys(store)["x1"]?.mergeKey == "\(elsewhere.id)#x1")
        #expect(try await keys(store)["r1"]?.mergeKey == "https://www.example.com/r1")
    }

    @Test func richPostsOfAnotherServerDoNotJoinByTheirOwnIdentities() async throws {
        let store = try await makeStore()
        let elsewhere = Source(id: SammyFeedConnector.sourceID(accountID: "s1@other.example.com", feedID: "f1"), kind: .sammyFeed,
                               accountID: "s1@other.example.com", title: "Elsewhere", colorIndex: 6, itemKind: .post)
        try await store.save(sources: [elsewhere], at: now)
        let canonical = "urn:uuid:0193a1b2-0000-7000-8000-000000000099"
        let theirs = Item(sourceID: elsewhere.id, remoteID: "x1", kind: .post, mergeKey: "sammy-post:other.example.com:\(canonical)",
                          authorName: "A", authorHandle: "a", body: "Theirs", publishedAt: now, fetchedAt: now)
        try await store.insert([theirs], identities: [theirs.mergeKey: [canonical, richCanonical]])
        _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [richPost(aliases: [])]]))
        #expect(try await store.rows().count == 2)
    }

}

@Suite struct RemovingASourceOfAJoinedPost {
    @Test(arguments: [true, false])
    func eachCopyKeepsItsRowWhenTheOtherSourceGoes(nativeFirst: Bool) async throws {
        for removing in [rich, mastodon] {
            let store = try await makeStore()
            let richConnector = try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]])
            let nativeConnector = mastodonConnector([status("1001")])
            if nativeFirst {
                _ = try await refresh(store, mastodon, nativeConnector)
                _ = try await refresh(store, rich, richConnector)
            } else {
                _ = try await refresh(store, rich, richConnector)
                _ = try await refresh(store, mastodon, nativeConnector)
            }
            let joined = try #require(try await store.rows().first)
            #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (joined.sortDate, joined.mergeKey), at: now))
            try await store.delete(sourceID: removing.id, at: now)
            let rows = try await store.rows()
            #expect(rows.count == 1)
            #expect(rows.first?.mergeKey == joined.mergeKey && rows.first?.sortDate == joined.sortDate)
            #expect(rows.first?.sourceID == (removing.id == rich.id ? mastodon.id : rich.id))
            #expect(try await store.lastReadMarker(viewID: SavedView.allID)?.mergeKey == joined.mergeKey)
            // Its identities went with it.
            let left = try await store.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM itemIdentity JOIN item ON item.id = itemID WHERE item.sourceID = ?", arguments: [removing.id])
            }
            #expect(left == 0)
            // The source added back, its copy joins the row again.
            try await store.save(sources: [removing], at: now)
            _ = try await refresh(store, removing, removing.id == rich.id ? richConnector : nativeConnector, at: 60)
            #expect(try await store.rows().map(\.mergeKey) == [joined.mergeKey])
        }
    }
}

/// Two devices on one stand-in iCloud.
private struct Pair {
    let server = InMemorySyncServer()
    let mac: InfluxStore
    let phone: InfluxStore
    private let macSync: SyncCoordinator
    private let phoneSync: SyncCoordinator

    init() throws {
        mac = try InfluxStore.inMemory()
        phone = try InfluxStore.inMemory()
        macSync = SyncCoordinator(store: mac, server: server)
        phoneSync = SyncCoordinator(store: phone, server: server)
    }

    func settle() async throws {
        for _ in 0..<2 {
            try await macSync.sync()
            try await phoneSync.sync()
        }
    }
}

@Suite struct JoinedPostsOnTwoDevices {
    @Test func theReadingPlaceOnAJoinedRowReachesTheOtherDevice() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon, rich], at: now)
        try await pair.settle()
        let richConnector = try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]])
        let nativeConnector = mastodonConnector([before, status("1001"), after])
        for store in [pair.mac, pair.phone] {
            _ = try await refresh(store, mastodon, nativeConnector)
            _ = try await refresh(store, rich, richConnector, at: 60)
        }
        let row = try #require(try await pair.mac.rows().first { $0.sourceID == rich.id })
        #expect(row.mergeKey == nativeKey)
        #expect(try await pair.mac.moveLastReadMarker(viewID: SavedView.allID, to: (row.sortDate, row.mergeKey), at: now.addingTimeInterval(120)))
        _ = try await pair.mac.moveReadingPlace(viewID: SavedView.allID, to: (row.sortDate, row.mergeKey), at: now.addingTimeInterval(120))
        try await pair.settle()
        #expect(try await pair.phone.rows().map(\.mergeKey) == pair.mac.rows().map(\.mergeKey))
        #expect(try await pair.phone.rows().first { $0.mergeKey == nativeKey }?.sourceID == rich.id)
        #expect(try await pair.phone.lastReadMarker(viewID: SavedView.allID)?.mergeKey == nativeKey)
        #expect(try await pair.phone.readingPlace(viewID: SavedView.allID)?.mergeKey == nativeKey)
    }

    @Test func aDeviceThatSawTheCopiesTheOtherWayRoundStillShowsOneRow() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon, rich], at: now)
        try await pair.settle()
        let richConnector = try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]])
        let nativeConnector = mastodonConnector([status("1001")])
        _ = try await refresh(pair.mac, mastodon, nativeConnector)
        _ = try await refresh(pair.mac, rich, richConnector, at: 60)
        _ = try await refresh(pair.phone, rich, richConnector)
        _ = try await refresh(pair.phone, mastodon, nativeConnector, at: 60)
        try await pair.settle()
        // Each shows one row, under the key of the copy it stored first
        // (ADR 0014): only the synced place of this post can disagree.
        #expect(try await pair.mac.rows().map(\.mergeKey) == [nativeKey])
        #expect(try await pair.phone.rows().map(\.mergeKey) == [richKey])
    }
}

/// A store from before identities were kept names its native posts by
/// their legacy identity once migrated, so a rich post can join them.
@Suite struct MigratingToPostIdentities {
    @Test func storedNativePostsGetTheirLegacyIdentity() throws {
        let db = try DatabaseQueue()
        try Schema.migrator.migrate(db, upTo: "v23: source item kind")
        try db.write { db in
            try db.execute(sql: "INSERT INTO source (id, kind, title, colorIndex) VALUES ('m', 'mastodonHome', 'M', 0), ('r', 'rss', 'R', 1)")
            for (id, source, kind, key) in [("1", "m", "post", nativeKey), ("2", "r", "article", "https://posts.example.com/authors/ada/posts/2"),
                                            ("3", "m", "post", "m#3")] {
                try db.execute(sql: """
                    INSERT INTO item (sourceID, remoteID, kind, mergeKey, authorName, authorHandle, body, publishedAt, fetchedAt, sortDate)
                    VALUES (?, ?, ?, ?, 'A', '@a', 'b', '2026-11-01 00:00:00.000', '2026-11-01 00:00:00.000', '2026-11-01 00:00:00.000')
                    """, arguments: [source, id, kind, key])
            }
        }
        try Schema.migrator.migrate(db)
        let identities = try db.read {
            try Row.fetchAll($0, sql: "SELECT item.remoteID, identity FROM itemIdentity JOIN item ON item.id = itemID")
                .map { [$0["remoteID"] as String, $0["identity"] as String] }
        }
        #expect(identities == [["1", nativeAlias]])
    }

    @Test func aRichPostStoredWithoutItsIdentitiesGetsThemWhenSentAgain() async throws {
        let store = try await makeStore()
        let connector = try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]])
        _ = try await refresh(store, rich, connector)
        // As a build from before kept them would have stored it.
        try await store.writer.write { db in try db.execute(sql: "DELETE FROM itemIdentity") }
        #expect(try await refresh(store, rich, connector, at: 60) == 0)
        _ = try await refresh(store, mastodon, mastodonConnector([status("1001")]), at: 120)
        #expect(try await store.rows().map(\.mergeKey) == [richKey])
    }
}

/// A repost seen twice: a rich feed's repost, placed at the original's
/// date, and a bridged Mastodon boost of the same original, streamed in
/// while the timeline is on screen. Both name the original post, so they
/// are one row, shown from the rich copy, whichever arrives first.
@Suite struct ARepostSeenFromABridgeAndARichFeed {
    /// The bridged original, as the reader's instance names it, and its
    /// alias, which the rich repost lists.
    private static let originalURI = "https://bridge.example.net/users/ada/statuses/1001"
    private static let originalAlias = LegacyPostIdentity.alias(of: originalURI)!
    private static let original = "2026-11-02T09:30:00.000Z"
    /// The repost, 1 hour 47 minutes after the original.
    private static let reposted = "2026-11-02T11:17:00.000Z"

    /// The rich feed's item: the original post, reposted by someone else.
    private static func richRepost() -> [String: Any] {
        var post = richPost(aliases: [originalAlias], text: "The original post, reposted.")
        post["repostedBy"] = ["name": "Booster", "url": "https://www.example.com/booster"]
        return post
    }

    /// The boost the home timeline carries: a status of the bridged
    /// booster's wrapping the bridged original.
    private static func boost() -> [String: Any] {
        var original = status("1001", uri: originalURI, url: "https://bridge.example.net/@ada/1001", at: original, text: "The original post, reposted.")
        original["account"] = ["id": "209", "username": "ada", "acct": "ada@bridge.example.net", "display_name": "Ada"]
        var boost = status("2001", uri: "https://bridge.example.net/users/booster/statuses/2001/activity", url: nil, at: reposted, text: "")
        boost["account"] = ["id": "210", "username": "booster", "acct": "booster@bridge.example.net", "display_name": "Booster"]
        boost["reblog"] = original
        return boost
    }

    /// Streams `statuses` into the home timeline, as `MastodonHomeStream`
    /// stores a burst.
    private static func stream(_ statuses: [[String: Any]], into store: InfluxStore, at offset: TimeInterval) async throws {
        let decoded = try Mastodon.decoder().decode([Mastodon.Status].self, from: JSONSerialization.data(withJSONObject: statuses))
        let at = now.addingTimeInterval(offset)
        let items = await mastodonConnector([]).streamedItems(decoded, home: mastodon, now: at, stored: try await store.remoteIDs(sourceID: mastodon.id))
        #expect(try await Refresher(store: store).recordStreamed(items, for: mastodon, now: at) { $0 } == .stored(newItems: items.count))
    }

    /// The rows that show the reposted post.
    private static func repostRows(_ store: InfluxStore) async throws -> [TimelineRow] {
        try await store.rows().filter { $0.body == "The original post, reposted." }
    }

    @Test func theStreamedBoostFirstThenTheRichRepost() async throws {
        let store = try await makeStore()
        #expect(try await refresh(store, mastodon, mastodonConnector([before])) == 1)
        try await Self.stream([Self.boost()], into: store, at: 22)
        #expect(try await Self.repostRows(store).map(\.sourceID) == [mastodon.id])

        #expect(try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [Self.richRepost()]]), at: 720) == 1)
        let rows = try await Self.repostRows(store)
        #expect(rows.count == 1)
        #expect(rows.first?.sourceID == rich.id)
        #expect(rows.first?.mergeKey == Self.originalURI)
    }

    @Test func theRichRepostFirstThenTheStreamedBoost() async throws {
        let store = try await makeStore()
        #expect(try await refresh(store, mastodon, mastodonConnector([before])) == 1)
        #expect(try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [Self.richRepost()]]), at: 22) == 1)
        try await Self.stream([Self.boost()], into: store, at: 720)
        let rows = try await Self.repostRows(store)
        #expect(rows.count == 1)
        #expect(rows.first?.sourceID == rich.id)
        #expect(rows.first?.mergeKey == richKey)
    }
}

/// A joined row's bookmark is the one of the copy it is shown from: Influx's
/// own when that is the rich copy, the service's when it is a Mastodon or
/// Bluesky copy (ADR 0031). One tap changes one of them, never both.
@Suite struct JoinedPostBookmarks {
    /// The Mastodon copy stored first, so the row's key is its URI, then
    /// the rich copy that names it.
    private func joinedStore(bookmarkedOnMastodon: Bool) async throws -> InfluxStore {
        let store = try await makeStore()
        var native = status("1001")
        native["bookmarked"] = bookmarkedOnMastodon
        _ = try await refresh(store, mastodon, mastodonConnector([native]))
        _ = try await refresh(store, rich, try richConnector([RichFixtures.richFeedID: [try fixtureRichItem()]]), at: 60)
        return store
    }

    @Test func aRowShownFromItsRichCopyTogglesOnlyInfluxsOwnBookmark() async throws {
        let store = try await joinedStore(bookmarkedOnMastodon: false)
        let row = try #require(try await store.rows().first)
        #expect(row.mergeKey == nativeKey && row.sourceID == rich.id)
        #expect(row.keepsOwnBookmark && row.viewer == Item.Viewer())

        #expect(try await store.toggleOwnBookmark(mergeKey: row.mergeKey))
        #expect(try await store.rows().first?.viewer == Item.Viewer(bookmarked: true))
        let bookmarks = try await store.rows(inView: SavedView.bookmarksID)
        #expect(bookmarks.map(\.sourceID) == [rich.id])
        #expect(try await store.isBookmarked(mergeKey: nativeKey, kind: .post) == true)
        // Nothing went to Mastodon: its copy's bookmark is as it was, and a
        // view without the rich feed shows that copy with all its actions.
        #expect(try await store.viewer(mergeKey: nativeKey, sourceID: mastodon.id)?.bookmarked == false)
        let mastodonOnly = try #require(try await store.rows(in: .sources([mastodon.id])).first)
        #expect(!mastodonOnly.keepsOwnBookmark && mastodonOnly.viewer?.bookmarked == false)
    }

    @Test func aMastodonBookmarkKeepsTheRowInBookmarksShownFromThatCopy() async throws {
        let store = try await joinedStore(bookmarkedOnMastodon: true)
        // Everywhere else the row is shown from the rich copy, whose own
        // bookmark is off.
        #expect(try await store.rows().map(\.sourceID) == [rich.id])
        #expect(try await store.rows().first?.viewer == Item.Viewer())
        // In Bookmarks it is shown from the copy that is bookmarked, so its
        // icon is on and a tap there removes that bookmark.
        func bookmarks() async throws -> [TimelineRow] { try await store.rows(inView: SavedView.bookmarksID) }
        #expect(try await bookmarks().map(\.sourceID) == [mastodon.id])
        #expect(try await bookmarks().first?.viewer?.bookmarked == true)

        // Bookmarked here too, then not: Mastodon's stays, and so does the row.
        #expect(try await store.toggleOwnBookmark(mergeKey: nativeKey))
        #expect(try await bookmarks().map(\.sourceID) == [rich.id])
        #expect(try await !store.toggleOwnBookmark(mergeKey: nativeKey))
        #expect(try await bookmarks().map(\.sourceID) == [mastodon.id])
        #expect(try await store.isBookmarked(mergeKey: nativeKey, kind: .post) == true)

        // Removed on Mastodon as well: no copy is bookmarked.
        try await store.setViewer(Item.Viewer(), mergeKey: nativeKey, sourceID: mastodon.id)
        #expect(try await bookmarks().isEmpty)
        #expect(try await store.isBookmarked(mergeKey: nativeKey, kind: .post) == false)
    }

    /// With the rich feed removed, the row is its Mastodon copy, whose
    /// controls are Mastodon's: Influx's own bookmark no longer keeps it in
    /// Bookmarks, or past its retention, where nothing could remove it.
    @Test func removingTheRichFeedLeavesOnlyTheServiceBookmark() async throws {
        let store = try await joinedStore(bookmarkedOnMastodon: false)
        #expect(try await store.toggleOwnBookmark(mergeKey: nativeKey))
        try await store.delete(sourceID: rich.id)
        #expect(try await store.rows().map(\.sourceID) == [mastodon.id])
        #expect(try await store.rows(inView: SavedView.bookmarksID).isEmpty)
        #expect(try await store.prune(now: now.addingTimeInterval(30 * 24 * 60 * 60)) == 1)
    }
}
