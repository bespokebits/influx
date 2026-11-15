import Foundation

/// A deterministic mixed timeline for previews, UI tests and scroll
/// performance runs: the same seed always gives the same sources and items,
/// so hitch numbers from two runs compare like for like.
public enum SeedFeed {
    public static let sources: [Source] = [
        Source(id: "seed:bluesky", kind: .blueskyFollowing, accountID: "seed:bsky.social", title: "Bluesky", colorIndex: 0),
        Source(id: "seed:mastodon.social", kind: .mastodonHome, accountID: "seed:mastodon.social", title: "Mastodon", colorIndex: 1),
        Source(id: "seed:hachyderm.io", kind: .mastodonHome, accountID: "seed:hachyderm.io", title: "Mastodon", colorIndex: 2),
        Source(id: "seed:daringfireball.net", kind: .rss, title: "Daring Fireball", url: "https://daringfireball.net/feeds/main", colorIndex: 3),
        Source(id: "seed:theverge.com", kind: .rss, title: "The Verge", url: "https://www.theverge.com/rss/index.xml", colorIndex: 4),
        Source(id: "seed:sixcolors.com", kind: .rss, title: "Six Colors", url: "https://sixcolors.com/feed/", colorIndex: 5),
        Source(id: "seed:arstechnica.com", kind: .rss, title: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", colorIndex: 6),
    ]

    /// `count` items, oldest first, ending at `end`. About one in fifteen
    /// posts is the same post again from a second source, so merged posts
    /// show up in every seeded timeline.
    public static func items(count: Int = 2_000, seed: UInt64 = 42, end: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> [Item] {
        items(count: count, seed: seed, start: end.addingTimeInterval(-Double(count) * 210), batch: "")
    }

    /// `count` more items, all dated after `date`, for trying out newer rows
    /// arriving. Each `batch` gives different items with their own IDs. A
    /// batch has no boosts, which would merge into an earlier post's row, so
    /// `count` items are always `count` new rows.
    public static func newer(count: Int = 20, after date: Date, batch: Int) -> [Item] {
        items(count: count, seed: 1_000 + UInt64(batch), start: date, batch: "b\(batch)-", boosts: false)
    }

    private static func items(count: Int, seed: UInt64, start: Date, batch: String, boosts: Bool = true) -> [Item] {
        var rng = SplitMix64(seed: seed)
        var items: [Item] = []
        items.reserveCapacity(count)
        // Roughly 3.5 minutes apart on average: 2,000 items cover about five days.
        var date = start
        for index in 0..<count {
            date = date.addingTimeInterval(Double(rng.next(in: 30...390)))
            if boosts, let earlier = items.last(where: { $0.kind == .post }), rng.next(in: 0...14) == 0 {
                items.append(boost(of: earlier, id: "\(batch)\(index)", date: date, rng: &rng))
            } else {
                items.append(item(id: "\(batch)\(index)", date: date, rng: &rng))
            }
        }
        return items
    }

    /// Writes the seed sources and items into `store`.
    public static func load(into store: InfluxStore, count: Int = 2_000, seed: UInt64 = 42, end: Date = Date(timeIntervalSince1970: 1_793_000_000)) async throws {
        try await store.save(sources: sources)
        try await store.insert(items(count: count, seed: seed, end: end))
    }

    private static func item(id: String, date: Date, rng: inout SplitMix64) -> Item {
        let isArticle = rng.next(in: 0...9) < 2
        let social = sources.filter { $0.kind != .rss }
        let feeds = sources.filter { $0.kind == .rss }
        let source = isArticle ? feeds[rng.next(in: 0...(feeds.count - 1))] : social[rng.next(in: 0...(social.count - 1))]
        let sentenceCount = isArticle ? rng.next(in: 1...3) : rng.next(in: 1...6)
        let body = (0..<sentenceCount).map { _ in pick(sentences, &rng) }.joined(separator: " ")
        let person = pick(people, &rng)
        let hasLink = rng.next(in: 0...9) < 3
        let hasMedia = !isArticle && rng.next(in: 0...9) < 3
        let site = pick(sites, &rng)
        let host = source.id.replacingOccurrences(of: "seed:", with: "")
        let link = "https://\(host)/\(id)"
        return Item(
            sourceID: source.id,
            remoteID: id,
            kind: isArticle ? .article : .post,
            mergeKey: link,
            authorName: isArticle ? source.title : person,
            authorHandle: isArticle ? host : "@\(person.lowercased().replacingOccurrences(of: " ", with: "."))",
            title: isArticle ? pick(headlines, &rng) : nil,
            body: body,
            url: link,
            publishedAt: date,
            fetchedAt: date,
            replyToHandle: !isArticle && rng.next(in: 0...9) == 1 ? pick(people, &rng) : nil,
            linkCard: hasLink ? .init(url: "https://\(site)/", site: site, title: pick(headlines, &rng)) : nil,
            media: hasMedia ? seedMedia(id: id, aspect: pick([16.0 / 9.0, 4.0 / 3.0, 1.0, 3.0 / 4.0], &rng)) : [],
            quote: isArticle ? nil : seedQuote(id: id, host: host),
            viewer: isArticle ? nil : seedViewer(id: id)
        )
    }

    /// Some posts quote another, and a few quote one that is unavailable,
    /// chosen from the ID, as the viewer state is, so the rest of the seed
    /// stays as it was.
    private static func seedQuote(id: String, host: String) -> Item.Quote? {
        let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }
        let url = "https://\(host)/quoted/\(id)"
        if hash % 23 == 0 { return .unavailable(url: url) }
        guard hash % 17 == 0 else { return nil }
        return Item.Quote(mergeKey: url, url: url, authorName: "Riverside Trust", authorHandle: "@trust@\(host)",
                          body: "The boardwalk works finish this week. Thank you for your patience while the path is rebuilt.")
    }

    /// Some posts liked, boosted or bookmarked, chosen from the ID rather
    /// than the generator, so the rest of the seed stays as it was.
    private static func seedViewer(id: String) -> Item.Viewer {
        let hash = id.utf8.reduce(UInt64(5381)) { ($0 &* 33) ^ UInt64($1) }
        return Item.Viewer(liked: hash % 5 == 0, boosted: hash % 11 == 0, bookmarked: hash % 13 == 0)
    }

    /// One sized image with a `seed:` URL, which loads nothing.
    private static func seedMedia(id: String, aspect: Double) -> [Item.Media] {
        [Item.Media(kind: .image, url: "seed:image/\(id)", width: 1200, height: Int((1200 / aspect).rounded()))].compactMap { $0 }
    }

    /// The same post seen again through another social source, boosted.
    private static func boost(of original: Item, id: String, date: Date, rng: inout SplitMix64) -> Item {
        let others = sources.filter { $0.kind != .rss && $0.id != original.sourceID }
        var copy = original
        copy.id = nil
        copy.sourceID = others[rng.next(in: 0...(others.count - 1))].id
        copy.remoteID = id
        copy.fetchedAt = date
        copy.sortDate = date
        copy.boostedBy = pick(people, &rng)
        return copy
    }

    private static func pick<T>(_ values: [T], _ rng: inout SplitMix64) -> T {
        values[rng.next(in: 0...(values.count - 1))]
    }

    private static let people = [
        "Ines Moreau", "Sam Okafor", "Priya Natarajan", "Tom Lindqvist", "Ana Ruiz", "Kenji Watanabe",
        "Lena Fischer", "Omar Haddad", "Grace Liu", "Marco Bianchi", "Zoe Adams", "Ravi Mehta",
    ]
    private static let sites = ["nytimes.com", "theguardian.com", "macstories.net", "atp.fm", "github.com", "apple.com"]
    private static let headlines = [
        "The quiet return of the RSS reader",
        "What a 120 Hz display asks of your layout code",
        "Inside the protocol that lets Bluesky and Mastodon talk",
        "A field guide to reading less, better",
        "Why the best apps measure before they draw",
        "The long tail of independent publishing",
        "Notes on building for one person first",
        "Hairlines, serifs and the case for calm interfaces",
    ]
    private static let sentences = [
        "Spent the morning rewriting the sync engine and it finally feels right.",
        "Hot take: most feeds would be better if they just showed things in order.",
        "The new release is out, and the changelog is longer than the code.",
        "If you only read one thing about typography this week, make it this.",
        "Every frame you drop is a promise you broke to the person scrolling.",
        "Coffee, a long train ride, and three hundred unread posts. Perfect.",
        "We measured it: the slow part was never the network, it was layout.",
        "Reminder that the open web is still here, and it is still good.",
        "Shipping is a habit. So is not shipping. Choose carefully.",
        "Someone asked why the app keeps its place when you come back. Because it should.",
        "Thread on what we learned moving a decade of posts between servers. 🧵",
        "Small screens deserve big type. Fight me.",
        "Today I learned that ✨ emoji ✨ change line height in some fonts. Wonderful.",
        "Long posts are fine. Long posts that jump around while you read them are not.",
    ]
}

/// SplitMix64: small, fast and identical on every platform.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(nextUInt64() % span)
    }
}
