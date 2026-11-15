import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Adds RSS subscriptions: by a feed's or a site's address, or from an
/// OPML file another reader exported. Each new feed is fetched straight
/// away, so its articles show up as soon as it is added.
public struct RSSSubscriptions: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// What was typed isn't a web address.
        case invalidURL
        /// Neither the address nor anything the page points to is a feed.
        case noFeedFound
    }

    public let store: InfluxStore
    public let connector: RSSConnector

    public init(store: InfluxStore, connector: RSSConnector = RSSConnector()) {
        self.store = store
        self.connector = connector
    }

    /// Subscribes to the feed at `address`, or to the first feed the page
    /// there advertises, and stores its articles. An address without a
    /// scheme is tried as https. Adding a feed twice returns the existing
    /// subscription. Errors are for the add sheet to show inline.
    @discardableResult
    public func add(_ address: String, now: Date = Date()) async throws -> Source {
        guard let url = Self.normalize(address) else { throw Failure.invalidURL }
        if let existing = try await existingSource(for: url) {
            return existing
        }
        let (feedURL, feed, response) = try await locateFeed(at: url, now: now)
        if let existing = try await existingSource(for: feedURL) {
            return existing
        }
        let source = Source(
            id: Self.sourceID(for: feedURL),
            kind: .rss,
            title: feed.title.map { HTMLText.plainText($0) }?.nilIfEmpty ?? feedURL.host ?? feedURL.absoluteString,
            url: feedURL.absoluteString,
            colorIndex: Source.colorIndex(for: Self.sourceID(for: feedURL))
        )
        try await store.save(sources: [source])
        // The feed is already in hand, so store it rather than fetch again.
        let request = Refresher.request(for: source, direction: .newer, cursor: nil, now: now)
        let page = await connector.page(feed, response: response, from: source, fetchedAt: now)
        try await Refresher(store: store).record(page, for: source, request: request)
        return source
    }

    /// Subscribes to every feed in an OPML file not already subscribed to,
    /// then fetches them. Returns the new subscriptions; a feed that fails
    /// to fetch is still subscribed, and shows its problem on the source.
    @discardableResult
    public func importOPML(_ data: Data, now: Date = Date()) async throws -> [Source] {
        let current = try await store.sources()
        // A feed that has moved keeps the ID its first address gave it, so
        // its old address is matched by ID as well as by address.
        var seenURLs = Set(current.flatMap(Self.addresses(of:)))
        var seenIDs = Set(current.map(\.id))
        var sources: [Source] = []
        for outline in try OPML.parse(data) {
            guard let url = Self.normalize(outline.feedURL) else { continue }
            let id = Self.sourceID(for: url)
            guard seenURLs.insert(url.absoluteString).inserted, seenIDs.insert(id).inserted else { continue }
            sources.append(Source(
                id: id, kind: .rss,
                title: outline.title ?? url.host ?? url.absoluteString,
                url: url.absoluteString,
                colorIndex: Source.colorIndex(for: id)
            ))
        }
        try await store.save(sources: sources)
        _ = try await Refresher(store: store).refreshAll(sources, with: connector, now: now)
        return sources
    }

    /// `rss:` and the feed's address: the same on every device, so synced
    /// state can name the subscription.
    static func sourceID(for feedURL: URL) -> String {
        "rss:" + feedURL.absoluteString
    }

    /// An https address for what the reader typed, an OPML file said or a
    /// page advertised. `feed://`, `http://` and a missing scheme all mean
    /// https.
    static func normalize(_ address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if text.lowercased().hasPrefix("feed://") {
            text = "https://" + text.dropFirst("feed://".count)
        } else if text.lowercased().hasPrefix("feed:") {
            text = String(text.dropFirst("feed:".count))
        }
        let lower = text.lowercased()
        let upgraded = lower.hasPrefix("http://")
        if upgraded {
            // Influx makes no cleartext loads, so http can only fail; try https.
            text = "https://" + text.dropFirst("http://".count)
        } else if !lower.hasPrefix("https://") {
            guard !lower.contains("://") else { return nil }
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host, host.contains(".") else {
            return nil
        }
        components.scheme = components.scheme?.lowercased()
        // Port 80 was http's default; an upgraded address uses https's.
        if upgraded, components.port == 80 { components.port = nil }
        components.host = host.lowercased()
        components.fragment = nil
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    /// The subscription at `url`, or the one first added from it and since
    /// moved elsewhere.
    private func existingSource(for url: URL) async throws -> Source? {
        let id = Self.sourceID(for: url)
        return try await store.sources().first {
            $0.kind == .rss && ($0.id == id || Self.addresses(of: $0).contains(url.absoluteString))
        }
    }

    /// Every address that names `source`: where it is now and where it was
    /// first added from (its ID), each as stored and normalized, since
    /// older subscriptions can hold http addresses.
    static func addresses(of source: Source) -> [String] {
        let first = source.id.hasPrefix("rss:") ? String(source.id.dropFirst("rss:".count)) : nil
        return [source.url, first].compactMap { $0 }.flatMap { [$0, Self.normalize($0)?.absoluteString].compactMap { $0 } }
    }

    /// The feed at `url`, or else the first one the page there points to,
    /// or else one at a usual place on the site.
    private func locateFeed(at url: URL, now: Date) async throws -> (URL, ParsedFeed, HTTPURLResponse) {
        let (data, response, movedTo) = try await get(url, now: now)
        if let feed = try? FeedParser.parse(data, baseURL: response.url ?? url, contentType: response.value(forHTTPHeaderField: "Content-Type")) {
            return (movedTo ?? url, feed, response)
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let pageURL = response.url ?? url
        let advertised = FeedDiscovery.feeds(inPage: html, at: pageURL)
        let candidates = (advertised + FeedDiscovery.guesses(for: pageURL)).compactMap { Self.normalize($0.absoluteString) }
        for candidate in candidates where candidate != url {
            guard let (data, response, movedTo) = try? await get(candidate, now: now),
                  let feed = try? FeedParser.parse(data, baseURL: response.url ?? candidate, contentType: response.value(forHTTPHeaderField: "Content-Type")) else { continue }
            return (movedTo ?? candidate, feed, response)
        }
        throw Failure.noFeedFound
    }

    /// The feed's bytes, and its https address after any permanent move.
    private func get(_ url: URL, now: Date) async throws -> (Data, HTTPURLResponse, URL?) {
        let (data, response, movedTo) = try await connector.get(url, validators: nil)
        try ConnectorError.check(response, now: now)
        return (data, response, movedTo.flatMap { $0.scheme == "https" ? Self.normalize($0.absoluteString) : nil })
    }
}

extension Source {
    /// How many colours the app's source-dot palette has.
    public static let paletteSize = 7

    /// A colour for a new source, worked out from its ID alone so every
    /// device picks the same one.
    public static func colorIndex(for id: String) -> Int {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in id.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return Int(hash % UInt64(paletteSize))
    }
}
