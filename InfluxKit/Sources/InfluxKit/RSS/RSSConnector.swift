import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// RSS, Atom and JSON Feed, fetched on the device. There is no account and
/// nothing to send back: read and unread live in the store
/// (`InfluxStore.setArticle`).
///
/// Every fetch is conditional. The cursor carries the feed's `ETag` and
/// `Last-Modified`, so an unchanged feed costs a 304 and no parsing. Feeds
/// can't be paged back, so a page never has an older cursor.
public struct RSSConnector: Connector {
    /// Longest summary kept for an article's row, in characters.
    static let summaryLimit = 400
    /// How Influx names itself to the sites it fetches from.
    static let userAgent = "Influx/1.0 (+https://bespokebits.dev)"
    /// Longest a feed fetch may take, start to finish. The request's own
    /// timeout only counts time with no data, so a server that trickles
    /// could otherwise hold a refresh pass open for good.
    static let fetchLimit: Duration = .seconds(60)

    public let client: any HTTPClient
    let resolver: MediaResolver
    let fetchLimit: Duration

    public init(client: any HTTPClient = URLSession.shared, resolver: MediaResolver? = nil) {
        self.init(client: client, resolver: resolver, fetchLimit: Self.fetchLimit)
    }

    init(client: any HTTPClient, resolver: MediaResolver? = nil, fetchLimit: Duration) {
        self.client = client
        self.resolver = resolver ?? MediaResolver(client: client)
        self.fetchLimit = fetchLimit
    }

    public func handles(_ source: Source) -> Bool {
        source.kind == .rss
    }

    public func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage {
        guard request.direction == .newer else {
            return FetchedPage(items: [], newer: request.cursor, older: nil)
        }
        guard let string = source.url, let stored = URL(string: string) else {
            throw ConnectorError.notFound
        }
        // Older subscriptions can hold http addresses, which can only fail
        // since Influx makes no cleartext loads, so they are fetched over https.
        let upgraded = HTTPRedirects.upgraded(stored)
        let url = upgraded ?? stored
        let validators = request.cursor.flatMap(Validators.init(cursor:))
        let (data, response, movedTo) = try await get(url, validators: validators)
        try ConnectorError.check(response, now: request.now)
        // Only an https address is kept: Influx makes no cleartext loads.
        // An upgraded address that answered is recorded as the source's own.
        let moved = movedTo.flatMap { $0.scheme == "https" ? $0.absoluteString : nil } ?? upgraded?.absoluteString
        if response.statusCode == 304 {
            return FetchedPage(items: [], newer: request.cursor, older: nil, movedTo: moved)
        }
        let feed: ParsedFeed
        do {
            feed = try FeedParser.parse(data, baseURL: response.url ?? url, contentType: response.value(forHTTPHeaderField: "Content-Type"))
        } catch FeedParser.Failure.notAJSONFeed(let reason) {
            throw ConnectorError.badResponse("not a JSON Feed: \(reason)")
        } catch {
            throw ConnectorError.badResponse("not a feed")
        }
        var fetched = await page(feed, response: response, from: source, fetchedAt: request.now, stored: request.storedRemoteIDs)
        fetched.movedTo = moved
        return fetched
    }

    /// Sends `request(for:validators:)`, giving up as `.offline` once
    /// `fetchLimit` has passed.
    func get(_ url: URL, validators: Validators?) async throws -> (data: Data, response: HTTPURLResponse, movedTo: URL?) {
        let client = client, request = Self.request(for: url, validators: validators)
        let answer = await withDeadline(fetchLimit) { () async -> Result<(data: Data, response: HTTPURLResponse, movedTo: URL?), any Error>? in
            do {
                return .success(try await client.sendNotingMove(request))
            } catch {
                return .failure(error)
            }
        }
        guard let answer else {
            try Task.checkCancellation()
            throw ConnectorError.offline
        }
        return try answer.get()
    }

    /// A conditional GET for a feed. The cache is skipped so a 304 comes
    /// back to us instead of being answered from a stale copy.
    static func request(for url: URL, validators: Validators?) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/rss+xml, application/atom+xml, application/feed+json, application/rdf+xml;q=0.9, application/xml;q=0.8, text/xml;q=0.8, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag = validators?.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let lastModified = validators?.lastModified {
            request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }

    /// The page a parsed feed makes, with the cursor its response's
    /// validators give (`ArticleMapper.items`).
    func page(_ feed: ParsedFeed, response: HTTPURLResponse, from source: Source, fetchedAt: Date, stored: Set<String> = []) async -> FetchedPage {
        // Where the feed ended up after redirects, so relative links point there.
        let feedURL = response.url ?? source.url.flatMap(URL.init(string:))
        // A feed that names no icon the app can load gets the one its
        // site's page declares; the resolver reads each page once.
        var siteIcon: String?
        if ArticleMapper.feedIcon(feed, feedURL: feedURL) == nil, let page = ArticleMapper.sitePage(feed, feedURL: feedURL) {
            siteIcon = await resolver.siteIcon(for: page)
        }
        let items = await ArticleMapper.items(from: feed, feedURL: feedURL, source: source, fetchedAt: fetchedAt, stored: stored,
                                              siteIcon: siteIcon, resolver: resolver)
        return FetchedPage(items: items, newer: Validators(response: response)?.cursor, older: nil,
                           articleIcon: ArticleMapper.declaredIcon(feed, siteIcon: siteIcon, feedURL: feedURL))
    }

    /// What a conditional request sends back: the `ETag` and
    /// `Last-Modified` the feed last answered with.
    struct Validators: Codable, Hashable {
        var etag: String?
        var lastModified: String?

        init?(response: HTTPURLResponse) {
            etag = response.value(forHTTPHeaderField: "ETag")
            lastModified = response.value(forHTTPHeaderField: "Last-Modified")
            if etag == nil, lastModified == nil { return nil }
        }

        init?(cursor: Cursor) {
            guard let decoded = try? JSONDecoder().decode(Validators.self, from: Data(cursor.rawValue.utf8)) else { return nil }
            self = decoded
        }

        var cursor: Cursor {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = (try? encoder.encode(self)) ?? Data()
            return Cursor(rawValue: String(decoding: data, as: UTF8.self))
        }
    }
}

/// Turns feed entries into articles.
enum ArticleMapper {
    /// Sites whose feeds write US daylight time with the standard-time
    /// name: ESPN's say "17:59 EST" in October for 17:59 EDT.
    static let daylightAsStandardHosts = ["espn.com"]

    /// Whether the feed at `url` is one of those. Every other feed keeps
    /// the fixed offsets RFC 822 gives the names (Arizona is on MST all
    /// year), since a wrong label can't be told from a right one.
    static func labelsDaylightTimeAsStandard(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return daylightAsStandardHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The feed's articles, in order. Each new article gets its picture
    /// (`image(for:feedURL:resolver:)`), or its video, or else a card for
    /// the YouTube video it embeds; articles in `stored` are already in the
    /// store, so their images aren't looked up again. `siteIcon` is as for
    /// `icon(_:siteIcon:entryURL:feedURL:)`.
    static func items(from feed: ParsedFeed, feedURL: URL?, source: Source, fetchedAt: Date, stored: Set<String>,
                      siteIcon: String? = nil, resolver: MediaResolver) async -> [Item] {
        let daylight = labelsDaylightTimeAsStandard(source.url.flatMap(URL.init(string:)))
        return await withTaskGroup(of: (Int, Item).self) { group in
            for (index, entry) in feed.entries.enumerated() {
                guard let item = item(from: entry, feed: feed, feedURL: feedURL, source: source, fetchedAt: fetchedAt,
                                      daylight: daylight, siteIcon: siteIcon) else { continue }
                group.addTask {
                    guard !stored.contains(item.remoteID) else { return (index, item) }
                    var withImage = item
                    withImage.media = await media(for: entry, feedURL: feedURL, resolver: resolver)
                    if withImage.media.isEmpty {
                        withImage.linkCard = await videoCard(for: entry, resolver: resolver)
                    }
                    return (index, withImage)
                }
            }
            var mapped: [(Int, Item)] = []
            for await entry in group { mapped.append(entry) }
            return mapped.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// The article for `entry`, or nil when it has nothing to show.
    /// `daylight` reads US standard-time names as daylight time, for a
    /// feed that `labelsDaylightTimeAsStandard`. `siteIcon` is as for
    /// `icon(_:siteIcon:entryURL:feedURL:)`.
    static func item(from entry: ParsedFeed.Entry, feed: ParsedFeed, feedURL: URL?, source: Source, fetchedAt: Date,
                     daylight: Bool = false, siteIcon: String? = nil) -> Item? {
        let link = entry.link.flatMap { resolve($0, against: feedURL) }
        // Only a GUID that is already a full address: a bare one like "42"
        // would resolve against the feed into a link nobody gave it.
        let permalinkGUID = entry.idIsPermaLink && feed.format == .rss ? entry.id.flatMap { resolve($0, against: nil) } : nil
        let url = link ?? permalinkGUID
        // Where the row opens; unlike `url`, never a merge key.
        let opens = url ?? entry.externalLink.flatMap { resolve($0, against: feedURL) }
        let title = entry.title.map { HTMLText.plainText($0) }.flatMap { $0.isEmpty ? nil : $0 }
        // The summary first: content is often the whole article.
        let body = [entry.summary, entry.content]
            .lazy
            .compactMap { $0.map { HTMLText.plainText($0, limit: RSSConnector.summaryLimit) } }
            .first { !$0.isEmpty } ?? ""
        guard title != nil || !body.isEmpty else { return nil }

        let id = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let remoteID = id ?? url?.absoluteString ?? fallbackID(entry)
        let published = (daylight ? entry.publishedAsDaylight : nil) ?? entry.published ?? entry.updated ?? fetchedAt
        let host = (url ?? feedURL)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? ""
        return Item(
            sourceID: source.id,
            remoteID: remoteID,
            kind: .article,
            mergeKey: mergeKey(id: id, url: url, source: source, remoteID: remoteID),
            authorName: entry.author.map { HTMLText.plainText($0) }?.nilIfEmpty ?? source.title,
            authorHandle: host,
            authorAvatar: icon(feed, siteIcon: siteIcon, entryURL: url, feedURL: feedURL),
            title: title,
            body: body,
            url: opens?.absoluteString,
            publishedAt: published,
            fetchedAt: fetchedAt
        )
    }

    /// The picture an article's row shows beside it: the feed's own icon,
    /// else `siteIcon` (the one the site's page declares), else the site's
    /// touch icon, which most sites serve at a fixed address. One that
    /// fails to load is drawn as a monogram.
    static func icon(_ feed: ParsedFeed, siteIcon: String? = nil, entryURL: URL?, feedURL: URL?) -> String? {
        if let declared = declaredIcon(feed, siteIcon: siteIcon, feedURL: feedURL) {
            return declared
        }
        let site = feed.link.flatMap { resolve($0, against: feedURL) } ?? entryURL ?? feedURL
        guard let host = site?.host, !host.isEmpty else { return nil }
        return "https://\(host)/apple-touch-icon.png"
    }

    /// An icon the feed or its site names, as opposed to the guessed
    /// touch-icon address.
    static func declaredIcon(_ feed: ParsedFeed, siteIcon: String?, feedURL: URL?) -> String? {
        feedIcon(feed, feedURL: feedURL) ?? siteIcon
    }

    /// The feed's own icon, when the app can show it (`showableIcon`).
    static func feedIcon(_ feed: ParsedFeed, feedURL: URL?) -> String? {
        feed.icon.flatMap { showableIcon($0, against: feedURL) }?.absoluteString
    }

    /// `string` as an icon address the app can show: pictures are loaded
    /// over https only and SVG isn't drawn, so either would only ever be a
    /// monogram (as for `SiteIcon`).
    static func showableIcon(_ string: String, against base: URL?) -> URL? {
        guard let icon = resolve(string, against: base), icon.scheme == "https",
              !icon.path.lowercased().hasSuffix(".svg") else { return nil }
        return icon
    }

    /// The page whose head declares the site's icon: the feed's link, else
    /// the root of the site the feed is on, always over https.
    static func sitePage(_ feed: ParsedFeed, feedURL: URL?) -> String? {
        let link = feed.link.flatMap { resolve($0, against: feedURL) }
        guard let base = link ?? feedURL,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: true),
              components.host?.isEmpty == false else { return nil }
        if link == nil {
            components.percentEncodedPath = "/"
            components.query = nil
        }
        components.fragment = nil
        if components.scheme == "http" {
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
        }
        return components.url?.absoluteString
    }

    /// A card for the first YouTube video an article embeds or links to,
    /// for articles with no picture of their own: a podcast post whose only
    /// image is its video's (The Verge's Vergecast). The card is the
    /// video page's own, else one made from YouTube's standard still.
    static func videoCard(for entry: ParsedFeed.Entry, resolver: MediaResolver) async -> Item.LinkCard? {
        guard let id = [entry.content, entry.summary].lazy.compactMap({ $0 }).compactMap(youTubeID(in:)).first else { return nil }
        let page = "https://www.youtube.com/watch?v=\(id)"
        if let card = await resolver.card(for: page), card.image != nil {
            return card
        }
        let still = Item.Media(kind: .image, url: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg", width: 480, height: 360)
        return Item.LinkCard(url: page, site: "YouTube", title: entry.title.map { HTMLText.plainText($0) }?.nilIfEmpty ?? "YouTube", image: still)
    }

    /// The ID of the first YouTube video in `html`, from an embed's
    /// `<iframe src>` or a link's `href`.
    static func youTubeID(in html: String) -> String? {
        let tags = FeedDiscovery.tags(named: ["iframe", "a"], in: html[...])
        for tag in tags {
            let attributes = FeedDiscovery.attributes(of: tag.body)
            guard let address = (attributes["src"] ?? attributes["href"]).map(HTMLText.decodeEntities),
                  let id = youTubeID(fromURL: address) else { continue }
            return id
        }
        return nil
    }

    /// `youtube.com/watch?v=ID`, `youtube.com/embed/ID`,
    /// `youtube-nocookie.com/embed/ID`, `youtube.com/shorts/ID` or
    /// `youtu.be/ID`; nil for anything else, such as a channel link.
    static func youTubeID(fromURL address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed),
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix("m.") { host.removeFirst(2) }
        let parts = url.path.split(separator: "/").map(String.init)
        var id: String?
        switch host {
        case "youtu.be":
            id = parts.first
        case "youtube.com", "youtube-nocookie.com":
            if parts.first == "watch" || parts.isEmpty {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
            } else if parts.count >= 2, ["embed", "shorts", "live", "v"].contains(parts[0]) {
                id = parts[1]
            }
        default:
            return nil
        }
        // Video IDs are 11 characters of base64url.
        guard let id, id.count == 11, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return id
    }

    /// Images smaller than this on either side are icons, spacers or
    /// tracking pixels, not something to show.
    static let smallestImage = 100
    /// How many of an article's images to try before giving up.
    static let imagesTried = 3
    /// An image at least this many pixels wide fills a row without
    /// looking soft, so no other image is tried.
    static let goodImageWidth = 600

    /// The shape a video tile takes when neither the feed nor a still
    /// gives one.
    static let defaultVideoSize = (width: 1280, height: 720)

    /// The article's video, when it names a movie file the app plays, else
    /// its picture. A video's still is the thumbnail given with it, else
    /// the first image the entry names outside its text. A video is kept
    /// even when nothing sizes it, as a 16:9 tile.
    static func media(for entry: ParsedFeed.Entry, feedURL: URL?, resolver: MediaResolver) async -> [Item.Media] {
        for candidate in entry.videos {
            guard let url = resolve(candidate.url, against: feedURL)?.absoluteString else { continue }
            let stills = [candidate.thumbnail].compactMap { $0 } + entry.images.map(\.url)
            let preview = stills.lazy.compactMap { resolve($0, against: feedURL)?.absoluteString }.first
            if let width = candidate.width, let height = candidate.height,
               let video = Item.Media(kind: .video, url: url, previewURL: preview, width: width, height: height) {
                return [video]
            }
            if let preview, let video = await resolver.sized([UnsizedMedia(kind: .video, url: url, previewURL: preview)]).first,
               video.width >= smallestImage, video.height >= smallestImage {
                return [video]
            }
            // A still too small to be one (or missing) isn't shown either.
            return Item.Media(kind: .video, url: url, width: defaultVideoSize.width, height: defaultVideoSize.height).map { [$0] } ?? []
        }
        return await image(for: entry, feedURL: feedURL, resolver: resolver)
    }

    /// The article's picture, from the images it names (Media RSS, then
    /// enclosures, then the `<img>`s in its text) that can be sized and
    /// aren't tiny: the first at least `goodImageWidth` wide, else the
    /// largest of the first `imagesTried`. Feeds often name a small
    /// thumbnail before the full picture.
    static func image(for entry: ParsedFeed.Entry, feedURL: URL?, resolver: MediaResolver) async -> [Item.Media] {
        var candidates = entry.images
        for html in [entry.content, entry.summary].compactMap({ $0 }) {
            candidates += inlineImages(in: html)
        }
        var tried = Set<String>()
        var best: Item.Media?
        for candidate in candidates {
            guard let url = resolve(candidate.url, against: feedURL)?.absoluteString, tried.insert(url).inserted else { continue }
            if tried.count > imagesTried { break }
            let media = await resolver.sized([UnsizedMedia(kind: .image, url: url, width: candidate.width, height: candidate.height)])
            guard let image = media.first, image.width >= smallestImage, image.height >= smallestImage else { continue }
            if image.width >= goodImageWidth { return [image] }
            // In Double: a feed's stated sizes can be anything, and an Int
            // product could overflow.
            if best.map({ Double(image.width) * Double(image.height) > Double($0.width) * Double($0.height) }) ?? true {
                best = image
            }
        }
        return best.map { [$0] } ?? []
    }

    /// `<img>` tags in an entry's HTML, with any width and height they give.
    static func inlineImages(in html: String) -> [ParsedFeed.Image] {
        FeedDiscovery.tags(named: ["img"], in: html[...]).compactMap { tag in
            let attributes = FeedDiscovery.attributes(of: tag.body)
            guard let src = attributes["src"].map(HTMLText.decodeEntities), !src.hasPrefix("data:") else { return nil }
            return ParsedFeed.Image(url: src, width: FeedParser.statedSide(attributes["width"]), height: FeedParser.statedSide(attributes["height"]))
        }
    }

    /// What makes an article the same in two feeds (a site's main feed and
    /// a category feed, say): an ID that is a global URI, else its link.
    /// A bare ID like "1234" only means something within its own feed.
    static func mergeKey(id: String?, url: URL?, source: Source, remoteID: String) -> String {
        if let id, isGlobalURI(id) {
            return id
        }
        if let url {
            return url.absoluteString
        }
        return "\(source.id)#\(remoteID)"
    }

    private static func isGlobalURI(_ id: String) -> Bool {
        let lower = id.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("tag:") || lower.hasPrefix("urn:")
    }

    /// An absolute http(s) URL for `string`, resolved against the feed.
    static func resolve(_ string: String, against base: URL?) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              url.scheme == "http" || url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    /// For entries with neither an ID nor a link: a stable hash of what
    /// they say, so a refetch doesn't store them twice.
    private static func fallbackID(_ entry: ParsedFeed.Entry) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        let text = [entry.title ?? "", entry.summary ?? entry.content ?? "", entry.published.map { "\($0.timeIntervalSince1970)" } ?? ""].joined(separator: "\u{1F}")
        for byte in text.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3
        }
        return "hash:" + String(hash, radix: 16)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
