import Foundation

/// Turns a Sammy feed page's items into articles. They are merged as RSS
/// articles are (ADR 0014): Sammy's `urn:uuid:` item IDs are global URIs,
/// so they are the merge key as they are, and survive a change of the
/// server's address.
enum JSONFeedMapper {
    /// The longest body a row shows, as for RSS.
    static let bodyLimit = RSSConnector.summaryLimit

    /// The article for `item`, without its picture, or nil when it has no
    /// ID or nothing to show.
    ///
    /// - The body is the first of `summary`, `content_text` and
    ///   `content_html` that has text, always as plain text of at most
    ///   `bodyLimit` characters.
    /// - The title is plain text: JSON Feed titles aren't HTML.
    /// - The author is the feed, by its title.
    static func item(from item: JSONFeed.Item, feed: JSONFeed, source: Source, fetchedAt: Date) -> Item? {
        guard let remoteID = item.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
        let title = item.title.map { HTMLText.plainText(HTMLText.escaped($0)) }?.nilIfEmpty
        let body = [
            item.summary.map(HTMLText.escaped),
            item.contentText.map(HTMLText.escaped),
            item.contentHTML,
        ]
        .lazy
        .compactMap { $0.map { HTMLText.plainText($0, limit: bodyLimit) } }
        .first { !$0.isEmpty } ?? ""
        guard title != nil || !body.isEmpty else { return nil }

        let url = item.url.flatMap { ArticleMapper.resolve($0, against: nil) }
        let host = url?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? source.url.flatMap { URL(string: $0)?.host } ?? ""
        let feedTitle = feed.title.map { HTMLText.plainText(HTMLText.escaped($0)) }?.nilIfEmpty
        return Item(
            sourceID: source.id,
            remoteID: remoteID,
            kind: .article,
            mergeKey: ArticleMapper.mergeKey(id: remoteID, url: url, source: source, remoteID: remoteID),
            authorName: feedTitle ?? source.title,
            authorHandle: host,
            authorAvatar: avatar(feed, itemURL: url),
            title: title,
            body: body,
            url: url?.absoluteString,
            publishedAt: item.datePublished ?? item.dateModified ?? fetchedAt,
            fetchedAt: fetchedAt,
            badge: badge(item.sammy)
        )
    }

    /// The score badge for `_sammy.metascore`, or nil when there is none
    /// to show: no extension, no score, a value outside 0...max, or a band
    /// this build doesn't know. The band says the tone; the server decides
    /// it. A missing or odd score never drops the item, only its badge,
    /// and the colour glyph the server puts in the text stays either way.
    static func badge(_ sammy: JSONFeed.SammyExtension?) -> Item.Badge? {
        guard let score = sammy?.metascore, score.max > 0, (0...score.max).contains(score.value) else { return nil }
        let tone = Item.Badge.Tone(rawValue: score.band.trimmingCharacters(in: .whitespaces).lowercased())
        guard Item.Badge.Tone.known.contains(tone) else { return nil }
        let text = score.max == 100 ? "\(score.value)" : "\(score.value)/\(score.max)"
        return Item.Badge(text: text, tone: tone)
    }

    /// The page's articles, in order. Each new one gets its `image`, sized
    /// through the public-only media path (ADR 0012), which never sends
    /// the account's token; articles in `stored` are already in the store,
    /// so their images aren't looked up again.
    static func items(from feed: JSONFeed, source: Source, fetchedAt: Date, stored: Set<String>, resolver: MediaResolver) async -> [Item] {
        await withTaskGroup(of: (Int, Item).self) { group in
            for (index, entry) in feed.items.enumerated() {
                guard let mapped = item(from: entry, feed: feed, source: source, fetchedAt: fetchedAt) else { continue }
                group.addTask {
                    guard !stored.contains(mapped.remoteID) else { return (index, mapped) }
                    var withImage = mapped
                    withImage.media = await image(entry, resolver: resolver)
                    return (index, withImage)
                }
            }
            var mapped: [(Int, Item)] = []
            for await entry in group { mapped.append(entry) }
            return mapped.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The item's `image`, when it is https and sizes to something that
    /// isn't an icon.
    static func image(_ item: JSONFeed.Item, resolver: MediaResolver) async -> [Item.Media] {
        guard let url = item.image.flatMap({ ArticleMapper.resolve($0, against: nil) }), url.scheme == "https" else { return [] }
        let media = await resolver.sized([UnsizedMedia(kind: .image, url: url.absoluteString)])
        guard let image = media.first, image.width >= ArticleMapper.smallestImage, image.height >= ArticleMapper.smallestImage else { return [] }
        return [image]
    }

    /// The picture beside an article's row: the feed's icon, else the
    /// linked site's touch icon. One that fails to load is a monogram.
    private static func avatar(_ feed: JSONFeed, itemURL: URL?) -> String? {
        if let icon = feed.icon.flatMap({ ArticleMapper.resolve($0, against: nil) }), icon.scheme == "https" {
            return icon.absoluteString
        }
        guard let host = itemURL?.host, !host.isEmpty else { return nil }
        return "https://\(host)/apple-touch-icon.png"
    }
}
