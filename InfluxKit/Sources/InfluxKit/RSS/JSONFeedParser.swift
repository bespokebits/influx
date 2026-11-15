import Foundation

/// Parses JSON Feed 1.0 and 1.1 (jsonfeed.org) into the `ParsedFeed` the
/// XML formats give, so an RSS subscription maps its items the same way.
/// `ParsedFeed.next` is only kept when it stays on the feed's own https
/// origin. Sammy feeds, which carry a token, are read by `JSONFeed` and
/// `JSONFeedMapper` instead.
///
/// Reading is as forgiving as it is for XML: a field of the wrong type
/// counts as missing and an item that isn't an object is skipped. Only a
/// body that isn't JSON, or isn't a JSON Feed, fails. Plain-text fields
/// (titles, `summary`, `content_text`, names) are escaped, so that like
/// every other feed's text they can go through the HTML step.
enum JSONFeedParser {
    /// `baseURL` is where the feed was fetched from, which relative URLs
    /// are resolved against. The spec wants them absolute; not every feed
    /// does that.
    static func parse(_ data: Data, baseURL: URL? = nil) throws -> ParsedFeed {
        let body = data.starts(with: byteOrderMark) ? data.dropFirst(byteOrderMark.count) : data[...]
        let root: Value
        do {
            root = try JSONDecoder().decode(Value.self, from: body)
        } catch {
            throw FeedParser.Failure.notAJSONFeed("malformed JSON")
        }
        guard case .object = root else {
            throw FeedParser.Failure.notAJSONFeed("not an object")
        }
        guard let version = root["version"]?.string?.lowercased(),
              versionPrefixes.contains(where: { version.hasPrefix($0) }) else {
            throw FeedParser.Failure.notAJSONFeed("no JSON Feed version")
        }

        func url(_ value: Value?) -> String? {
            guard let text = value?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return baseURL.flatMap { URL(string: text, relativeTo: $0)?.absoluteString } ?? text
        }

        var feed = ParsedFeed(format: .json)
        feed.title = root["title"]?.string.map(HTMLText.escaped)
        feed.link = url(root["home_page_url"])
        // The body can name any address, and an authenticated reader sends
        // its token along when it follows `next_url`: only https is kept,
        // and the next page only on the origin the feed came from.
        feed.feedURL = url(root["feed_url"]).flatMap { secure($0) }
        feed.next = url(root["next_url"]).flatMap { secure($0) }.flatMap { next in
            baseURL.flatMap { sameOrigin(next, $0) ? next : nil }
        }
        // `icon` is the large square one; `favicon` is for small sizes. An
        // icon the row couldn't load doesn't hide a favicon it could.
        feed.icon = [url(root["icon"]), url(root["favicon"])]
            .lazy
            .compactMap { $0 }
            .first { ArticleMapper.showableIcon($0, against: baseURL) != nil }
        // Items without their own authors have the feed's.
        let feedAuthor = author(of: root)

        for item in root["items"]?.array ?? [] {
            guard case .object = item else { continue }
            var entry = ParsedFeed.Entry()
            entry.id = item["id"]?.identifier
            entry.idIsPermaLink = false
            entry.link = url(item["url"])
            entry.externalLink = url(item["external_url"])
            entry.title = item["title"]?.string.map(HTMLText.escaped)
            entry.summary = item["summary"]?.string.map(HTMLText.escaped)
            // Some generators send both keys, the HTML one empty.
            entry.content = item["content_html"]?.string.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                ?? item["content_text"]?.string.map(HTMLText.escaped)
            entry.author = author(of: item) ?? feedAuthor
            entry.published = item["date_published"]?.string.flatMap(FeedDate.parse)
            entry.updated = item["date_modified"]?.string.flatMap(FeedDate.parse)
            // The item's own picture, then its banner, then any image
            // attachment; movie attachments the app plays become videos.
            entry.images = [url(item["image"]), url(item["banner_image"])].compactMap { $0 }.map { ParsedFeed.Image(url: $0) }
            for attachment in item["attachments"]?.array ?? [] {
                guard let address = url(attachment["url"]) else { continue }
                let type = attachment["mime_type"]?.string.map(FeedParser.mimeType) ?? ""
                if type.hasPrefix("image/") {
                    entry.images.append(ParsedFeed.Image(url: address))
                } else if FeedParser.isPlayableVideo(type: type.isEmpty ? nil : type, url: address) {
                    entry.videos.append(ParsedFeed.Video(url: address))
                }
            }
            feed.entries.append(entry)
        }
        return feed
    }

    /// `string` if it is an absolute https address with a host.
    private static func secure(_ string: String) -> String? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return string
    }

    /// Whether `string` has the scheme, host and port of `base`.
    private static func sameOrigin(_ string: String, _ base: URL) -> Bool {
        guard let url = URL(string: string) else { return false }
        func origin(_ url: URL) -> (String?, String?, Int?) {
            let scheme = url.scheme?.lowercased()
            return (scheme, url.host?.lowercased(), url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil))
        }
        return origin(url) == origin(base)
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let versionPrefixes = ["https://jsonfeed.org/version/", "http://jsonfeed.org/version/"]

    /// The first named author: 1.1's `authors`, else 1.0's `author`.
    private static func author(of object: Value) -> String? {
        let authors = object["authors"]?.array ?? []
        let name = (authors + [object["author"]].compactMap { $0 })
            .lazy
            .compactMap { $0["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return name.map(HTMLText.escaped)
    }

    /// Any JSON value, so a field of an unexpected type reads as missing
    /// instead of failing the whole feed.
    private enum Value: Decodable {
        case string(String)
        case integer(Int64)
        case number(Double)
        case bool(Bool)
        case null
        case array([Value])
        case object([String: Value])

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode([String: Value].self) {
                self = .object(value)
            } else if let value = try? container.decode([Value].self) {
                self = .array(value)
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Int64.self) {
                self = .integer(value)
            } else if let value = try? container.decode(Double.self) {
                self = .number(value)
            } else {
                // A number too large to hold, say: missing, like any other
                // value Influx can't read.
                self = .null
            }
        }

        subscript(key: String) -> Value? {
            if case .object(let fields) = self { return fields[key] }
            return nil
        }

        var string: String? {
            if case .string(let value) = self { return value }
            return nil
        }

        var array: [Value]? {
            if case .array(let values) = self { return values }
            return nil
        }

        /// An item `id`, which the spec says is a string but which readers
        /// must accept as a number too.
        var identifier: String? {
            switch self {
            case .string(let value): value
            case .integer(let value): String(value)
            case .number(let value): value == value.rounded() && abs(value) < 1e15 ? String(Int64(value)) : String(value)
            default: nil
            }
        }
    }
}
