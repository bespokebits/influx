import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Learns what a row needs before it is stored: the size of an
/// image the service gave no size for, and a link card for a post whose
/// service sent none. Connectors call it while fetching. Every lookup is
/// short and gives up quietly, so the row is stored without the card or
/// the image rather than later changing height.
public actor MediaResolver {
    /// How long one lookup may take in all, redirects and DNS included.
    static let timeout: Duration = .seconds(5)
    /// Pages are only read up to here; the tags are in the head.
    static let pageLimit = 256 * 1024
    /// Lookups remembered, so a link shared by many posts is fetched once.
    static let cacheLimit = 2_000
    /// Redirects followed before a lookup gives up.
    static let redirectLimit = 5

    private let client: any HTTPClient
    private let addresses: AddressLookup
    private let timeout: Duration
    // Lookups by URL, kept while in flight too, so posts sharing a link
    // that arrive together share one request.
    private var sizes: [String: Task<Size?, Never>] = [:]
    private var cards: [String: Task<Item.LinkCard?, Never>] = [:]
    private var icons: [String: Task<String?, Never>] = [:]

    private struct Fetched: Sendable {
        var data: Data
        var url: URL
        var status: Int
        var contentType: String?
        var contentLength: String?
        var contentRange: String?
        var response: HTTPURLResponse
    }

    struct Size: Hashable {
        var width: Int
        var height: Int
    }

    public init(client: any HTTPClient) {
        self.init(client: client, addresses: .system)
    }

    init(client: any HTTPClient, addresses: AddressLookup, timeout: Duration = MediaResolver.timeout) {
        self.client = client
        self.addresses = addresses
        self.timeout = timeout
    }

    /// `media` with every entry sized: an entry without a size is sized
    /// from its image's first bytes, and left out if that fails. Videos are
    /// sized from their preview image.
    func sized(_ media: [UnsizedMedia]) async -> [Item.Media] {
        var result: [Item.Media] = []
        for entry in media {
            if let sized = entry.sized {
                result.append(sized)
                continue
            }
            guard let probe = entry.kind == .image ? entry.url : entry.previewURL,
                  let size = await imageSize(at: probe),
                  let sized = Item.Media(kind: entry.kind, url: entry.url, previewURL: entry.previewURL,
                                         width: size.width, height: size.height, altText: entry.altText) else { continue }
            result.append(sized)
        }
        return result
    }

    /// The card for `url`: its Open Graph title, site, description and
    /// image, or the
    /// page's `<title>`. Nil for a page that can't be fetched or has no
    /// title.
    public func card(for url: String) async -> Item.LinkCard? {
        if let lookup = cards[url] {
            return await lookup.value
        }
        let lookup = Task { await self.fetchCard(url) }
        remember(&cards, url, lookup)
        return await lookup.value
    }

    /// The icon the page at `url` declares for its site (`SiteIcon`), or
    /// nil for a page that can't be fetched or declares none worth showing.
    /// Remembered, so each site's page is read once.
    func siteIcon(for url: String) async -> String? {
        if let lookup = icons[url] {
            return await lookup.value
        }
        let timeout = timeout
        let lookup = Task {
            await withDeadline(timeout) { () async -> String? in
                guard let target = URL(string: url),
                      let fetched = await self.get(target, limit: Self.pageLimit, headers: ["Accept": "text/html"]) else { return nil }
                return SiteIcon.parse(String(decoding: fetched.data, as: UTF8.self), at: fetched.url)
            }
        }
        remember(&icons, url, lookup)
        return await lookup.value
    }

    func imageSize(at url: String) async -> Size? {
        if let lookup = sizes[url] {
            return await lookup.value
        }
        let timeout = timeout
        let lookup = Task { await withDeadline(timeout) { await self.fetchSize(url) } }
        remember(&sizes, url, lookup)
        return await lookup.value
    }

    /// The first `limit` bytes of `url`, held to the same rules as every
    /// lookup: https to public addresses only, connected to the address
    /// that was checked, each redirect checked again. For the app's image
    /// loading, which shows images from links other people posted. Nil on
    /// any failure or after `timeout`; not cached here.
    public func fetch(_ url: String, upTo limit: Int, timeout: Duration) async -> Data? {
        guard let target = URL(string: url) else { return nil }
        return await withDeadline(timeout) {
            await self.get(target, limit: limit, headers: ["Accept": "image/*,video/*;q=0.8"], timeout: timeout)?.data
        }
    }

    /// Like `fetch(_:upTo:timeout:)`, for a player reading a video in
    /// pieces: asks for `range` of the file (or all of it when nil) and
    /// says what came back. A server that ignores ranges answers 200 with
    /// the file from its start.
    public func fetch(_ url: String, bytes range: ClosedRange<Int>?, upTo limit: Int, timeout: Duration) async -> RangedResponse? {
        guard let target = URL(string: url), range.map({ $0.lowerBound >= 0 }) ?? true else { return nil }
        var headers = ["Accept": "video/*,image/*;q=0.8"]
        if let range {
            headers["Range"] = "bytes=\(range.lowerBound)-\(range.upperBound)"
        }
        let request = headers
        guard let fetched = await withDeadline(timeout, {
            await self.get(target, limit: limit, headers: request, timeout: timeout)
        }) else { return nil }
        return RangedResponse(data: fetched.data, statusCode: fetched.status, contentType: fetched.contentType,
                              totalLength: RangedResponse.totalLength(status: fetched.status, contentLength: fetched.contentLength,
                                                                      contentRange: fetched.contentRange))
    }

    /// The successful answer to `url` and its body, at most `limit` bytes,
    /// under the same rules as every lookup: https to public addresses
    /// only, connected to the address that was checked, each redirect
    /// checked again, and nothing sent but `headers`, `Accept-Encoding` and
    /// the user agent: no cookie, credential or referrer, since the request
    /// is written by hand and no session stores anything. For a rich post's
    /// media read straight from its source (`SammyMediaGrants`, ADR 0040).
    /// Nil on any failure or after `timeout`.
    func response(_ url: URL, headers: [String: String], upTo limit: Int, timeout: Duration) async -> (Data, HTTPURLResponse)? {
        await withDeadline(timeout) {
            guard let fetched = await self.get(url, limit: limit, headers: headers, timeout: timeout) else { return nil }
            return (fetched.data, fetched.response)
        }
    }

    private func fetchSize(_ url: String) async -> Size? {
        guard let target = URL(string: url),
              let fetched = await get(target, limit: ImageSize.prefixLength, headers: ["Range": "bytes=0-\(ImageSize.prefixLength - 1)"]),
              let parsed = ImageSize.parse(fetched.data) else { return nil }
        return Size(width: parsed.width, height: parsed.height)
    }

    private func fetchCard(_ url: String) async -> Item.LinkCard? {
        // The page and its image are each held to the deadline, so an image
        // that is slow to size still leaves the card its title.
        let timeout = timeout
        guard let target = URL(string: url),
              let fetched = await withDeadline(timeout, {
                  await self.get(target, limit: Self.pageLimit, headers: ["Accept": "text/html"])
              }) else { return nil }
        let pageURL = fetched.url
        let html = String(decoding: fetched.data, as: UTF8.self)
        guard let page = OpenGraph.parse(html, at: pageURL) else { return nil }

        var image: Item.Media?
        if let imageURL = page.imageURL {
            if let width = page.imageWidth, let height = page.imageHeight {
                image = Item.Media(kind: .image, url: imageURL, width: width, height: height, altText: page.imageAlt)
            } else if let size = await imageSize(at: imageURL) {
                image = Item.Media(kind: .image, url: imageURL, width: size.width, height: size.height, altText: page.imageAlt)
            }
        }
        let host = pageURL.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? url
        return Item.LinkCard(url: page.url ?? pageURL.absoluteString, site: page.siteName ?? host, title: page.title,
                             summary: page.description, image: image)
    }

    /// The start of a successful response to `url` and the address it came
    /// from. Each hop, redirects included, must be https to a public name
    /// that resolves only to public addresses, and the request connects to
    /// the address that was checked rather than resolving the name again.
    private func get(_ url: URL, limit: Int, headers: [String: String], timeout: Duration? = nil) async -> Fetched? {
        var target = url
        for _ in 0...Self.redirectLimit {
            guard let address = await publicAddress(of: target), !Task.isCancelled else { return nil }
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: (timeout ?? self.timeout).seconds)
            // Pinned requests are written by hand, so nothing adds one for
            // us, and some hosts (Wikimedia) refuse requests without it.
            request.setValue(RSSConnector.userAgent, forHTTPHeaderField: "User-Agent")
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            guard let (data, response) = try? await client.send(request, upTo: limit, at: address) else { return nil }
            switch response.statusCode {
            case 200..<300:
                return Fetched(data: data, url: target, status: response.statusCode,
                               contentType: response.value(forHTTPHeaderField: "Content-Type"),
                               contentLength: response.value(forHTTPHeaderField: "Content-Length"),
                               contentRange: response.value(forHTTPHeaderField: "Content-Range"), response: response)
            case 300..<400:
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: target)?.absoluteURL else { return nil }
                target = next
            default:
                return nil
            }
        }
        return nil
    }

    /// The address to connect to for `url`, when it is https to a public
    /// name whose every address is public. IPv4 is preferred, as the one
    /// most likely to be reachable.
    private func publicAddress(of url: URL) async -> [UInt8]? {
        guard url.scheme == "https", let host = url.host, PublicAddress.isPublicName(host),
              let resolved = await addresses.resolve(host), !resolved.isEmpty,
              resolved.allSatisfy(PublicAddress.isPublic) else { return nil }
        return resolved.first { $0.count == 4 } ?? resolved.first
    }

    private func remember<Value>(_ cache: inout [String: Value], _ key: String, _ value: Value) {
        if cache.count >= Self.cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = value
    }
}

/// What a ranged fetch got back.
public struct RangedResponse: Sendable, Hashable {
    /// The bytes received, from the start of the range (206) or of the file (200).
    public var data: Data
    /// 206 when the server sent the range asked for, 200 when it sent the file.
    public var statusCode: Int
    public var contentType: String?
    /// The whole file's length, when the server says.
    public var totalLength: Int?

    public init(data: Data, statusCode: Int, contentType: String?, totalLength: Int?) {
        self.data = data
        self.statusCode = statusCode
        self.contentType = contentType
        self.totalLength = totalLength
    }

    /// From `Content-Range: bytes a-b/total` on a 206, or `Content-Length` on a 200.
    static func totalLength(status: Int, contentLength: String?, contentRange: String?) -> Int? {
        if status == 206 {
            guard let total = contentRange?.split(separator: "/").last.map({ $0.trimmingCharacters(in: .whitespaces) }) else { return nil }
            return Int(total).flatMap { $0 >= 0 ? $0 : nil }
        }
        return contentLength.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
    }
}

/// Media as a service describes it, before every entry has a size.
struct UnsizedMedia: Sendable, Hashable {
    var kind: Item.Media.Kind
    var url: String
    var previewURL: String?
    var width: Int?
    var height: Int?
    var altText: String?

    var sized: Item.Media? {
        guard let width, let height else { return nil }
        return Item.Media(kind: kind, url: url, previewURL: previewURL, width: width, height: height, altText: altText)
    }
}

/// The icon a page's head declares for its site, for a feed that names
/// none. A touch icon (`apple-touch-icon`, made for a home screen, so large
/// and opaque) is preferred: the largest declared, where one without
/// `sizes` counts as iOS's 180 points and a later one wins a tie, as a
/// browser takes the last. Without one, the largest plain `icon` that says
/// it is at least `smallest` pixels; favicons are too small for a row.
/// SVG, `data:` and plain-http icons are skipped, since the app can't
/// draw or load them.
enum SiteIcon {
    static let smallest = 64
    static let touchIconDefault = 180

    static func parse(_ html: String, at pageURL: URL) -> String? {
        let head = html.range(of: "</head", options: .caseInsensitive).map { html[..<$0.lowerBound] } ?? html[...]
        // Links resolve against the document's first <base href>, wherever
        // in the head it stands.
        let base = FeedDiscovery.tags(named: ["base"], in: head).lazy
            .compactMap { FeedDiscovery.attributes(of: $0.body)["href"].map(HTMLText.decodeEntities) }
            .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces), relativeTo: pageURL)?.absoluteURL }
            .first ?? pageURL
        var best: (touch: Int, size: Int, url: String)?
        for tag in FeedDiscovery.tags(named: ["link"], in: head) {
            let attributes = FeedDiscovery.attributes(of: tag.body)
            let rel = Set((attributes["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace).map(String.init))
            let touch = rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed")
            guard touch || rel.contains("icon"),
                  let href = attributes["href"].map(HTMLText.decodeEntities)?.trimmingCharacters(in: .whitespaces),
                  !href.isEmpty, !href.lowercased().hasPrefix("data:"),
                  attributes["type"]?.lowercased().contains("svg") != true,
                  let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  // The app loads pictures over https only.
                  url.scheme == "https", url.host != nil,
                  !url.path.lowercased().hasSuffix(".svg") else { continue }
            let declared = largestSize(attributes["sizes"])
            let size = declared ?? (touch ? touchIconDefault : 0)
            guard touch || size >= smallest else { continue }
            let rank = (touch ? 1 : 0, size)
            if let current = best, (current.touch, current.size) > rank { continue }
            best = (rank.0, rank.1, url.absoluteString)
        }
        return best?.url
    }

    /// The largest square side in a `sizes` attribute ("57x57 72x72"), or
    /// nil when it gives none ("any", or missing).
    static func largestSize(_ sizes: String?) -> Int? {
        sizes?.lowercased().split(whereSeparator: \.isWhitespace).compactMap { size -> Int? in
            let sides = size.split(separator: "x").compactMap { Int($0) }
            return sides.count == 2 ? min(sides[0], sides[1]) : nil
        }.max()
    }
}

/// The preview a page declares for itself in its head.
struct OpenGraph: Hashable {
    var title: String
    var siteName: String?
    /// The page's canonical address, when it names one.
    var url: String?
    var imageURL: String?
    var imageWidth: Int?
    var imageHeight: Int?
    var imageAlt: String?
    var description: String?

    /// Reads `og:` (and `twitter:`) meta tags, falling back to `<title>`.
    /// Nil when the page has no title at all.
    static func parse(_ html: String, at pageURL: URL) -> OpenGraph? {
        let head = html.range(of: "</head", options: .caseInsensitive).map { html[..<$0.lowerBound] } ?? html[...]
        var meta: [String: String] = [:]
        for tag in FeedDiscovery.tags(named: ["meta"], in: head) {
            let attributes = FeedDiscovery.attributes(of: tag.body)
            guard let key = (attributes["property"] ?? attributes["name"])?.lowercased(),
                  let content = attributes["content"] else { continue }
            let value = HTMLText.plainText(content)
            if meta[key] == nil, !value.isEmpty {
                meta[key] = value
            }
        }
        let fallbackTitle = documentTitle(in: head)
        guard let title = meta["og:title"] ?? meta["twitter:title"] ?? fallbackTitle else { return nil }

        func absolute(_ string: String?) -> String? {
            guard let string, let url = URL(string: string, relativeTo: pageURL)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http" else { return nil }
            return url.absoluteString
        }
        func positive(_ string: String?) -> Int? {
            string.flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        }
        let imageKey = meta["og:image:secure_url"] != nil ? "og:image:secure_url" : "og:image"
        return OpenGraph(
            title: title,
            siteName: meta["og:site_name"],
            url: absolute(meta["og:url"]),
            imageURL: absolute(meta[imageKey] ?? meta["og:image:url"] ?? meta["twitter:image"] ?? meta["twitter:image:src"]),
            imageWidth: positive(meta["og:image:width"]),
            imageHeight: positive(meta["og:image:height"]),
            imageAlt: meta["og:image:alt"] ?? meta["twitter:image:alt"],
            description: meta["og:description"] ?? meta["twitter:description"] ?? meta["description"]
        )
    }

    private static func documentTitle(in head: Substring) -> String? {
        guard let open = head.range(of: "<title", options: .caseInsensitive),
              let start = head[open.upperBound...].firstIndex(of: ">"),
              let close = head[start...].range(of: "</title", options: .caseInsensitive) else { return nil }
        let text = HTMLText.plainText(String(head[head.index(after: start)..<close.lowerBound]))
        return text.isEmpty ? nil : text
    }
}
