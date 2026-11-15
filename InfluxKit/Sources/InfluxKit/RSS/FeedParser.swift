import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A feed as its XML or JSON says it, before mapping to items. Text is
/// raw: titles and summaries may still hold HTML.
struct ParsedFeed: Sendable, Hashable {
    enum Format: Sendable, Hashable {
        case rss, rdf, atom
        /// JSON Feed 1.0 or 1.1 (`JSONFeedParser`).
        case json
    }

    var format: Format
    var title: String?
    /// The site the feed belongs to.
    var link: String?
    /// The feed's own picture: Atom `icon` (else `logo`), RSS
    /// `<image><url>`, or the podcast `itunes:image`. Possibly relative.
    var icon: String?
    /// Where the feed says it lives: JSON Feed's `feed_url`, when it is an
    /// absolute https address.
    var feedURL: String?
    /// The page of older items: JSON Feed's `next_url`, kept only when it
    /// is https on the same origin (scheme, host and port) as the address
    /// the feed was fetched from, so a request carrying that origin's
    /// bearer token may follow it. XML feeds can't be paged back, so
    /// theirs is always nil.
    var next: String?
    var entries: [Entry] = []

    struct Entry: Sendable, Hashable {
        /// The RSS `guid`, Atom `id` or JSON Feed `id`.
        var id: String?
        /// RSS `guid isPermaLink`, which defaults to true.
        var idIsPermaLink = true
        var link: String?
        /// JSON Feed's `external_url`: the page a link post is about. It
        /// is where the row opens when there is no `link`, but never what
        /// the entry merges by, since it is someone else's article.
        var externalLink: String?
        var title: String?
        /// RSS `description`, Atom `summary` or JSON Feed `summary`.
        var summary: String?
        /// `content:encoded`, Atom `content`, or JSON Feed `content_html`
        /// (else `content_text`).
        var content: String?
        var author: String?
        var published: Date?
        /// `published` with a US standard-time zone read as daylight
        /// time, when that differs (`FeedDate.daylightReading`).
        var publishedAsDaylight: Date?
        var updated: Date?
        /// Images the entry names outside its text (Media RSS, enclosures),
        /// best first.
        var images: [Image] = []
        /// Movie files the entry names (Media RSS, then enclosures), best
        /// first.
        var videos: [Video] = []
    }

    struct Image: Sendable, Hashable {
        var url: String
        var width: Int?
        var height: Int?
    }

    struct Video: Sendable, Hashable {
        var url: String
        var width: Int?
        var height: Int?
        /// A `media:thumbnail` given inside its `media:content`.
        var thumbnail: String?
    }
}

/// Parses RSS 2.0, RSS 1.0 (RDF) and Atom 1.0, and hands JSON Feeds to
/// `JSONFeedParser`.
enum FeedParser {
    enum Failure: Error, Equatable {
        /// The XML doesn't parse, or its root isn't a feed.
        case notAFeed
        /// The body was taken for JSON but isn't a JSON Feed, and why.
        case notAJSONFeed(String)
    }

    /// `baseURL` is where the feed was fetched from, which Atom's
    /// `xml:base` attributes and JSON Feed's relative URLs are resolved
    /// against. `contentType` is the response's `Content-Type`; see
    /// `isJSON(_:contentType:)`.
    static func parse(_ data: Data, baseURL: URL? = nil, contentType: String? = nil) throws -> ParsedFeed {
        if isJSON(data, contentType: contentType) {
            return try JSONFeedParser.parse(data, baseURL: baseURL)
        }
        if let feed = try? parseOnce(data, baseURL: baseURL) {
            return feed
        }
        // Many feeds use HTML entities that XML doesn't define (&nbsp;,
        // &mdash;); spell them as numeric references and try again.
        guard let repaired = repairingEntities(data), repaired != data else {
            throw Failure.notAFeed
        }
        return try parseOnce(repaired, baseURL: baseURL)
    }

    private static func parseOnce(_ data: Data, baseURL: URL?) throws -> ParsedFeed {
        let parser = XMLParser(data: data)
        let delegate = Delegate(baseURL: baseURL)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let feed = delegate.feed else {
            throw Failure.notAFeed
        }
        return feed
    }

    /// Rewrites named entities outside the XML five as numeric references.
    /// Inside CDATA this turns `&nbsp;` into `&#160;`, which the HTML step
    /// decodes to the same text.
    static func repairingEntities(_ data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") {
                let name = String(text[text.index(after: index)..<semicolon])
                if !xmlEntities.contains(name), !name.hasPrefix("#"), let value = HTMLText.named[name] {
                    result += value.unicodeScalars.map { "&#\($0.value);" }.joined()
                    index = text.index(after: semicolon)
                    continue
                }
                if !xmlEntities.contains(name), !name.hasPrefix("#") {
                    // An entity we don't know at all: escape the ampersand.
                    result += "&amp;"
                    index = text.index(after: index)
                    continue
                }
            } else if character == "&" {
                result += "&amp;"
                index = text.index(after: index)
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }
        // The declaration may name another encoding; the text is UTF-8 now.
        if let declaration = result.range(of: #"^<\?xml[^>]*\?>"#, options: .regularExpression) {
            result.replaceSubrange(declaration, with: #"<?xml version="1.0" encoding="UTF-8"?>"#)
        }
        return Data(result.utf8)
    }

    private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    /// Whether a body is read as JSON Feed: it starts with `{`, or the
    /// server calls it JSON and it doesn't start with `<`. Servers often
    /// send feeds as `text/plain` or `text/html`, so the body counts more
    /// than the label.
    static func isJSON(_ data: Data, contentType: String?) -> Bool {
        // Leading whitespace and a UTF-8 byte order mark.
        let skipped: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF]
        let first = data.first { !skipped.contains($0) }
        if first == UInt8(ascii: "{") { return true }
        guard first != UInt8(ascii: "<"), let type = contentType.map(mimeType) else { return false }
        return jsonTypes.contains(type)
    }

    /// JSON Feed's own type, and the plain JSON one 1.0 recommended.
    static let jsonTypes: Set<String> = ["application/feed+json", "application/json"]

    static let atomNamespace = "http://www.w3.org/2005/Atom"
    static let rdfNamespace = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let rss1Namespace = "http://purl.org/rss/1.0/"
    static let dcNamespace = "http://purl.org/dc/elements/1.1/"
    static let contentNamespace = "http://purl.org/rss/1.0/modules/content/"
    static let mediaNamespace = "http://search.yahoo.com/mrss/"
    static let itunesNamespace = "http://www.itunes.com/dtds/podcast-1.0.dtd"

    /// The namespaces feeds conventionally write with these prefixes.
    /// Some feeds use a prefix without declaring it (AV Club writes
    /// `media:content` with no `xmlns:media`), which the XML parser reports
    /// as no namespace at all.
    static let conventionalPrefixes = [
        "media": mediaNamespace, "content": contentNamespace, "dc": dcNamespace,
        "itunes": itunesNamespace, "atom": atomNamespace,
    ]

    /// An element's namespace: the one the parser reports, else the
    /// conventional one for a prefix the feed never declared.
    static func namespace(_ uri: String?, qualifiedName: String?) -> String {
        if let uri, !uri.isEmpty { return uri }
        guard let qualifiedName, let colon = qualifiedName.firstIndex(of: ":") else { return "" }
        return conventionalPrefixes[String(qualifiedName[..<colon])] ?? ""
    }

    /// The largest side a feed may state for a picture or video. Beyond it
    /// the stated size is ignored and the file is measured instead, so a
    /// malformed value such as `Int.max` never reaches layout (the same
    /// bound `MastodonMapper.pixels` keeps).
    static let largestStatedSide = 100_000

    /// A width or height as a feed states it, when it is a sane pixel count.
    static func statedSide(_ value: String?) -> Int? {
        guard let side = value.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) }),
              (1...largestStatedSide).contains(side) else { return nil }
        return side
    }

    /// Whether an untyped address names a picture, by its file extension.
    static func looksLikeImage(_ url: String) -> Bool {
        let path = (URL(string: url)?.path ?? url).lowercased()
        return [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif", ".heic"].contains { path.hasSuffix($0) }
    }

    /// Whether the app plays it: a movie file, by its type or, without
    /// one, its file extension. Not HLS, which the app only plays from
    /// hosts it knows, nor WebM, Flash or audio.
    /// A MIME type as compared: trimmed, lowercased, without parameters
    /// such as `; codecs="avc1.42E01E"`.
    static func mimeType(_ type: String) -> String {
        (type.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func isPlayableVideo(type: String?, url: String) -> Bool {
        if let type = type.map(mimeType), !type.isEmpty {
            return ["video/mp4", "video/quicktime", "video/x-m4v", "video/mpeg4"].contains(type)
        }
        let path = (URL(string: url)?.path ?? url).lowercased()
        return [".mp4", ".m4v", ".mov"].contains { path.hasSuffix($0) }
    }
}

private final class Delegate: NSObject, XMLParserDelegate {
    private(set) var feed: ParsedFeed?
    private var entry: ParsedFeed.Entry?
    /// The open elements, as namespace and local name.
    private var path: [(namespace: String, name: String)] = []
    private var text = ""
    /// Inside Atom XHTML content: the path length of the content element.
    /// Elements below it only add their text.
    private var xhtmlDepth: Int?
    private var atomTextType: String?
    /// The `xml:base` in force for each open element.
    private var bases: [URL?] = []
    /// The rank of each of the open entry's images.
    private var imageRanks: [Int] = []
    /// The rank of each of the open entry's videos.
    private var videoRanks: [Int] = []
    /// The path length of the open video `media:content`, whose
    /// thumbnail is that video's still.
    private var videoContentDepth: Int?
    private let baseURL: URL?

    init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    /// The name of the open element's parent, `levels` up.
    private func ancestor(_ levels: Int = 1) -> String? {
        let index = path.count - 1 - levels
        return index >= 0 ? path[index].name : nil
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let namespace = FeedParser.namespace(namespaceURI, qualifiedName: qualifiedName)
        let inherited = bases.last ?? baseURL
        // Foundation names the attribute "xml:base" or just "base",
        // depending on the platform.
        if let base = attributes["xml:base"] ?? attributes["base"] {
            bases.append(URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: inherited)?.absoluteURL ?? inherited)
        } else {
            bases.append(inherited)
        }
        if let depth = xhtmlDepth, path.count >= depth {
            path.append((namespace, name))
            text.append(" ")
            return
        }
        path.append((namespace, name))
        text = ""

        if path.count == 1 {
            switch (namespace, name) {
            case ("", "rss"):
                feed = ParsedFeed(format: .rss)
            case (FeedParser.rdfNamespace, "RDF"):
                feed = ParsedFeed(format: .rdf)
            case (FeedParser.atomNamespace, "feed"):
                feed = ParsedFeed(format: .atom)
            default:
                parser.abortParsing()
            }
            return
        }
        guard let format = feed?.format else { return }
        if entry != nil {
            noteImage(namespace: namespace, name: name, attributes: attributes)
            noteVideo(namespace: namespace, name: name, attributes: attributes)
        }

        switch format {
        case .rss, .rdf:
            if entry == nil, path.count == 3, namespace == FeedParser.itunesNamespace, name == "image",
               let href = attributes["href"], feed?.icon == nil {
                feed?.icon = href
            }
            if name == "item", namespace == "" || namespace == FeedParser.rss1Namespace {
                entry = ParsedFeed.Entry()
                imageRanks = []
                videoRanks = []
            } else if name == "guid", entry != nil, ancestor() == "item" {
                entry?.idIsPermaLink = attributes["isPermaLink"]?.lowercased() != "false"
            }
        case .json:
            break
        case .atom:
            guard namespace == FeedParser.atomNamespace else { return }
            if name == "entry" {
                entry = ParsedFeed.Entry()
                imageRanks = []
                videoRanks = []
            } else if name == "link" {
                let rel = attributes["rel"] ?? "alternate"
                let type = attributes["type"] ?? "text/html"
                if rel == "alternate", type.contains("html"), var href = attributes["href"] {
                    if let base = bases.last ?? nil, let resolved = URL(string: href, relativeTo: base)?.absoluteURL {
                        href = resolved.absoluteString
                    }
                    if entry != nil {
                        if ancestor() == "entry", entry?.link == nil { entry?.link = href }
                    } else if path.count == 2, feed?.link == nil {
                        feed?.link = href
                    }
                }
            } else if ["title", "summary", "content"].contains(name) {
                atomTextType = attributes["type"]
                if atomTextType == "xhtml" {
                    xhtmlDepth = path.count
                }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        text += String(decoding: data, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let namespace = FeedParser.namespace(namespaceURI, qualifiedName: qualifiedName)
        defer {
            if path.count == videoContentDepth { videoContentDepth = nil }
            path.removeLast()
            bases.removeLast()
        }
        if let depth = xhtmlDepth {
            if path.count > depth {
                text.append(" ")
                return
            }
            xhtmlDepth = nil
        }
        guard let format = feed?.format else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        let inEntry = entry != nil
        // The element's parent: the channel, the feed, or the entry.
        let depthInParent = path.count

        switch format {
        case .rss, .rdf:
            if name == "item", inEntry {
                if let entry { feed?.entries.append(finished(entry)) }
                entry = nil
                return
            }
            // Only the item's own fields: not those of an element nested in
            // it, such as a <source> naming another feed.
            if inEntry, ancestor() == "item" {
                switch (namespace, name) {
                case ("", "title"), (FeedParser.rss1Namespace, "title"):
                    entry?.title = value
                case ("", "link"), (FeedParser.rss1Namespace, "link"):
                    entry?.link = value
                case ("", "guid"):
                    entry?.id = value
                case ("", "description"), (FeedParser.rss1Namespace, "description"):
                    entry?.summary = value
                case (FeedParser.contentNamespace, "encoded"):
                    entry?.content = value
                case ("", "author"), (FeedParser.dcNamespace, "creator"):
                    if entry?.author == nil { entry?.author = value }
                case ("", "pubDate"):
                    entry?.published = FeedDate.parse(value)
                    entry?.publishedAsDaylight = FeedDate.daylightReading(value)
                case (FeedParser.dcNamespace, "date"):
                    if entry?.published == nil { entry?.published = FeedDate.parse(value) }
                default:
                    break
                }
            } else if !inEntry, depthInParent == 4, name == "url", path[2].name == "image", path[2].namespace != FeedParser.itunesNamespace {
                // <channel><image><url> in RSS 2.0; RSS 1.0 puts <image> beside the channel.
                if !value.isEmpty { feed?.icon = value }
            } else if !inEntry, depthInParent == 3, name == "url", path[1].name == "image" {
                if !value.isEmpty, feed?.icon == nil { feed?.icon = value }
            } else if !inEntry, depthInParent == 3, path[1].name == "channel" {
                switch name {
                case "title" where feed?.title == nil:
                    feed?.title = value
                case "link" where feed?.link == nil && namespace != FeedParser.atomNamespace:
                    feed?.link = value
                default:
                    break
                }
            }
        case .atom:
            guard namespace == FeedParser.atomNamespace else { return }
            if name == "entry", inEntry {
                if let entry { feed?.entries.append(finished(entry)) }
                entry = nil
                return
            }
            let content = atomText(value)
            // An entry's own fields, not those of its <source> (the feed it
            // was copied from), which has an id, title and dates too.
            if inEntry, ancestor() == "entry" {
                switch name {
                case "id": entry?.id = value
                case "title": entry?.title = content
                case "summary": entry?.summary = content
                case "content": entry?.content = content
                case "published": entry?.published = FeedDate.parse(value)
                case "updated": entry?.updated = FeedDate.parse(value)
                default: break
                }
            } else if inEntry, name == "name", ancestor() == "author", ancestor(2) == "entry" {
                if entry?.author == nil { entry?.author = value }
            } else if depthInParent == 2, name == "title" {
                feed?.title = content
            } else if depthInParent == 2, name == "icon" || name == "logo", !value.isEmpty {
                // An icon is square, a logo wide; take the icon when there is one.
                let resolved = (bases.last ?? nil).flatMap { URL(string: value, relativeTo: $0)?.absoluteString } ?? value
                if name == "icon" || feed?.icon == nil { feed?.icon = resolved }
            }
        case .json:
            break
        }
    }

    /// Media RSS content and thumbnails, then image enclosures (RSS
    /// `<enclosure>` or Atom `<link rel="enclosure">`), in that order of
    /// preference.
    private func noteImage(namespace: String, name: String, attributes: [String: String]) {
        let type = attributes["type"]?.lowercased() ?? ""
        let rank: Int
        let urlKey: String
        switch (namespace, name) {
        case (FeedParser.mediaNamespace, "content"):
            let medium = attributes["medium"]?.lowercased()
            if medium == nil, type.isEmpty {
                // Untyped, as AV Club writes its lead picture: kept when
                // the address names a picture file.
                guard FeedParser.looksLikeImage(attributes["url"] ?? "") else { return }
            } else {
                guard medium == "image" || type.hasPrefix("image/") else { return }
            }
            (rank, urlKey) = (0, "url")
        case (FeedParser.mediaNamespace, "thumbnail"):
            (rank, urlKey) = (1, "url")
        case ("", "enclosure"):
            guard type.hasPrefix("image/") else { return }
            (rank, urlKey) = (2, "url")
        case (FeedParser.atomNamespace, "link") where attributes["rel"] == "enclosure":
            guard type.hasPrefix("image/") else { return }
            (rank, urlKey) = (2, "href")
        default:
            return
        }
        guard var url = attributes[urlKey]?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return }
        if let base = bases.last ?? nil, let resolved = URL(string: url, relativeTo: base)?.absoluteURL {
            url = resolved.absoluteString
        }
        let image = ParsedFeed.Image(url: url, width: FeedParser.statedSide(attributes["width"]), height: FeedParser.statedSide(attributes["height"]))
        imageRanks.append(rank)
        entry?.images.append(image)
        // Keep them best first, in document order within a rank.
        let order = zip(imageRanks, entry?.images ?? []).enumerated().sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
        imageRanks = order.map(\.element.0)
        entry?.images = order.map(\.element.1)
    }

    /// Media RSS video content and video enclosures the app plays: movie
    /// files, see `FeedParser.isPlayableVideo`. Noted in
    /// document order; `finished(_:)` puts them best first.
    private func noteVideo(namespace: String, name: String, attributes: [String: String]) {
        if namespace == FeedParser.mediaNamespace, name == "thumbnail", let depth = videoContentDepth, path.count == depth + 1 {
            // The still of the video this thumbnail sits in.
            if let url = resolved(attributes["url"]), let last = entry?.videos.indices.last, entry?.videos[last].thumbnail == nil {
                entry?.videos[last].thumbnail = url
            }
            return
        }
        let type = attributes["type"].map(FeedParser.mimeType)
        let rank: Int
        let urlKey: String
        switch (namespace, name) {
        case (FeedParser.mediaNamespace, "content"):
            guard attributes["medium"]?.lowercased() == "video" || type?.hasPrefix("video/") == true else { return }
            (rank, urlKey) = (0, "url")
        case ("", "enclosure"):
            (rank, urlKey) = (1, "url")
        case (FeedParser.atomNamespace, "link") where attributes["rel"] == "enclosure":
            (rank, urlKey) = (1, "href")
        default:
            return
        }
        guard let url = resolved(attributes[urlKey]), FeedParser.isPlayableVideo(type: type, url: url) else { return }
        entry?.videos.append(ParsedFeed.Video(url: url, width: FeedParser.statedSide(attributes["width"]), height: FeedParser.statedSide(attributes["height"])))
        videoRanks.append(rank)
        if rank == 0 { videoContentDepth = path.count }
    }

    /// The entry with its videos best first, in document order within a rank.
    private func finished(_ entry: ParsedFeed.Entry) -> ParsedFeed.Entry {
        var entry = entry
        entry.videos = zip(videoRanks, entry.videos).enumerated()
            .sorted { ($0.element.0, $0.offset) < ($1.element.0, $1.offset) }
            .map(\.element.1)
        return entry
    }

    /// An attribute's URL, trimmed and resolved against the `xml:base`.
    private func resolved(_ value: String?) -> String? {
        guard var url = value?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return nil }
        if let base = bases.last ?? nil, let resolved = URL(string: url, relativeTo: base)?.absoluteURL {
            url = resolved.absoluteString
        }
        return url
    }

    /// Atom text as the HTML step expects it. Plain text, and XHTML (whose
    /// tags are already dropped here), may hold a literal "<", so they are
    /// escaped; only html passes through.
    private func atomText(_ value: String) -> String {
        defer { atomTextType = nil }
        guard atomTextType != "html" else { return value }
        return HTMLText.escaped(value)
    }
}
