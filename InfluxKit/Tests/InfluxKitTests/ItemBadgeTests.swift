import Foundation
import Testing
@testable import InfluxKit

private let source = Source(
    id: SammyFeedConnector.sourceID(accountID: "s@example.com", feedID: "f1"), kind: .sammyFeed, accountID: "s@example.com",
    title: "Movies: first scores", url: "https://example.com/api/v1/feeds/f1", colorIndex: 0
)
private let fetchedAt = Date(timeIntervalSince1970: 1_793_000_000)

private func contract(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/SammyContract"))
    return try Data(contentsOf: url)
}

/// One feed item with `sammy` as its `_sammy` object, mapped.
private func mapped(sammy: Any?) throws -> Item? {
    var item: [String: Any] = ["id": "urn:uuid:1", "title": "Example Film", "content_text": "🟢 Metascore 74"]
    if let sammy { item["_sammy"] = sammy }
    let body: [String: Any] = ["version": "https://jsonfeed.org/version/1.1", "title": "Movies", "items": [item]]
    let feed = try JSONFeed.decode(JSONSerialization.data(withJSONObject: body))
    return try JSONFeedMapper.item(from: #require(feed.items.first), feed: feed, source: source, fetchedAt: fetchedAt)
}

private func score(_ value: Any, max: Any = 100, band: Any) -> [String: Any] {
    ["metascore": ["value": value, "max": max, "band": band]]
}

@Suite struct ItemBadgeTests {
    @Test func theContractPagesMapToTheirBadges() throws {
        let first = try JSONFeed.decode(contract("feed-page-1.json"))
        let badges = first.items.compactMap { JSONFeedMapper.item(from: $0, feed: first, source: source, fetchedAt: fetchedAt)?.badge }
        #expect(badges == [Item.Badge(text: "65", tone: .favorable), Item.Badge(text: "31", tone: .unfavorable)])
        // The second page's post has no `_sammy`: kept, with no badge.
        let second = try JSONFeed.decode(contract("feed-page-2.json"))
        let items = second.items.compactMap { JSONFeedMapper.item(from: $0, feed: second, source: source, fetchedAt: fetchedAt) }
        #expect(items.count == second.items.count && !items.isEmpty)
        #expect(items.allSatisfy { $0.badge == nil })
    }

    @Test(arguments: [
        (0, "unfavorable", Item.Badge.Tone.unfavorable),
        (39, "unfavorable", .unfavorable),
        (40, "mixed", .mixed),
        (60, "mixed", .mixed),
        (61, "favorable", .favorable),
        (100, "favorable", .favorable),
    ])
    func eachBandHasItsTone(value: Int, band: String, tone: Item.Badge.Tone) throws {
        let item = try #require(try mapped(sammy: score(value, band: band)))
        #expect(item.badge == Item.Badge(text: "\(value)", tone: tone))
    }

    @Test func aScoreOutOfSomethingElseSaysSo() throws {
        #expect(try mapped(sammy: score(7, max: 10, band: "favorable"))?.badge?.text == "7/10")
    }

    /// Each `_sammy` as JSON; nil leaves it out.
    @Test(arguments: [
        nil,
        #"{}"#,
        #"{"metascore": null}"#,
        #"{"metascore": "74"}"#,
        #"{"metascore": {"value": "74", "max": 100, "band": "favorable"}}"#,
        #"{"metascore": {"value": 74, "max": 100, "band": 3}}"#,
        #"{"metascore": {"value": 74, "max": 100, "band": "superb"}}"#,
        #"{"metascore": {"value": 74, "max": 100, "band": ""}}"#,
        #"{"metascore": {"value": 101, "max": 100, "band": "favorable"}}"#,
        #"{"metascore": {"value": -1, "max": 100, "band": "unfavorable"}}"#,
        #"{"metascore": {"value": 5, "max": 0, "band": "mixed"}}"#,
        #"{"metascore": {"value": 74, "band": "favorable"}}"#,
        #""not an object""#,
    ] as [String?])
    func aMissingOrMalformedScoreGivesNoBadgeAndKeepsTheItem(sammy: String?) throws {
        let object = try sammy.map { try JSONSerialization.jsonObject(with: Data($0.utf8), options: .fragmentsAllowed) }
        let item = try #require(try mapped(sammy: object))
        #expect(item.badge == nil)
        #expect(item.title == "Example Film")
        // The glyph in the text is the server's and stays either way.
        #expect(item.body.hasPrefix("🟢"))
    }

    @Test func theBadgeIsSpokenAsAScoreAndATone() {
        #expect(Item.Badge(text: "74", tone: .favorable).spoken == "Score 74, favorable")
        #expect(Item.Badge(text: "40", tone: .mixed).spoken == "Score 40, mixed")
    }

    @Test func anArticleStoredWithoutABadgeStillReads() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [source])
        let plain = try #require(try mapped(sammy: nil))
        var scored = try #require(try mapped(sammy: score(74, band: "favorable")))
        scored.remoteID = "urn:uuid:2"
        scored.mergeKey = "urn:uuid:2"
        _ = try await store.insert([plain, scored])
        let rows = try await store.rows()
        #expect(rows.count == 2)
        #expect(rows.first { $0.mergeKey == plain.mergeKey }?.badge == nil)
        #expect(rows.first { $0.mergeKey == "urn:uuid:2" }?.badge == Item.Badge(text: "74", tone: .favorable))

        // An item encoded before the badge existed has no key for it.
        var encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        encoded["badge"] = nil
        let decoded = try JSONDecoder().decode(Item.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded.badge == nil)
    }

    @Test func aToneALaterBuildAddsStillReads() throws {
        let badge = try JSONDecoder().decode(Item.Badge.self, from: Data(#"{"text":"9","tone":"universal-acclaim"}"#.utf8))
        #expect(badge.tone.rawValue == "universal-acclaim")
        #expect(!Item.Badge.Tone.known.contains(badge.tone))
    }
}
