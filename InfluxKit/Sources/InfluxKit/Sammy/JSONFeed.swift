import Foundation

/// The part of JSON Feed 1.1 (jsonfeed.org) a Sammy feed page uses, as it
/// arrives. Decoding is lenient, as for every feed: a field of the wrong
/// type reads as missing, and an item that doesn't decode is left out. Only
/// a body that isn't a JSON Feed object fails. `_sammy`, the server's
/// extension object, is decoded the same way; its score becomes the
/// row's badge (`JSONFeedMapper.badge`).
///
/// Public JSON Feeds in RSS subscriptions go through `JSONFeedParser`
/// instead; this one keeps the fields as given, so `JSONFeedMapper` can
/// choose between them, and leaves every URL for the connector to check.
struct JSONFeed: Decodable, Sendable, Hashable {
    var version: String
    var title: String?
    var feedURL: String?
    /// The page after this one, older posts. The connector follows it only
    /// on the server's own origin.
    var nextURL: String?
    var icon: String?
    var items: [Item]

    struct Item: Decodable, Sendable, Hashable {
        /// A string, or a number written as one.
        var id: String?
        var url: String?
        var title: String?
        var summary: String?
        var contentText: String?
        var contentHTML: String?
        var image: String?
        var datePublished: Date?
        var dateModified: Date?
        var sammy: SammyExtension?

        enum CodingKeys: String, CodingKey {
            case id, url, title, summary, image
            case contentText = "content_text"
            case contentHTML = "content_html"
            case datePublished = "date_published"
            case dateModified = "date_modified"
            case sammy = "_sammy"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = container.lenientIdentifier(.id)
            url = container.lenient(.url)
            title = container.lenient(.title)
            summary = container.lenient(.summary)
            contentText = container.lenient(.contentText)
            contentHTML = container.lenient(.contentHTML)
            image = container.lenient(.image)
            datePublished = container.lenient(String.self, .datePublished).flatMap(FeedDate.iso8601)
            dateModified = container.lenient(String.self, .dateModified).flatMap(FeedDate.iso8601)
            sammy = container.lenient(SammyExtension.self, .sammy)
        }

        init(id: String?, url: String? = nil, title: String? = nil, summary: String? = nil, contentText: String? = nil,
             contentHTML: String? = nil, image: String? = nil, datePublished: Date? = nil) {
            self.id = id
            self.url = url
            self.title = title
            self.summary = summary
            self.contentText = contentText
            self.contentHTML = contentHTML
            self.image = image
            self.datePublished = datePublished
        }
    }

    /// `_sammy`: what the server knows about a post beyond JSON Feed. Every
    /// field is optional and read leniently, so a change here never drops
    /// a post.
    struct SammyExtension: Decodable, Sendable, Hashable {
        struct Metascore: Decodable, Sendable, Hashable {
            var value: Int
            var max: Int
            var band: String
        }

        struct ImageSize: Decodable, Sendable, Hashable {
            var width: Int
            var height: Int
        }

        var metascore: Metascore?
        var releaseDate: String?
        var kind: String?
        var imageSize: ImageSize?

        enum CodingKeys: String, CodingKey {
            case metascore, kind
            case releaseDate = "release_date"
            case imageSize = "image_size"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metascore = container.lenient(Metascore.self, .metascore)
            releaseDate = container.lenient(.releaseDate)
            kind = container.lenient(.kind)
            imageSize = container.lenient(ImageSize.self, .imageSize)
        }
    }

    enum CodingKeys: String, CodingKey {
        case version, title, icon, items
        case feedURL = "feed_url"
        case nextURL = "next_url"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(String.self, forKey: .version)
        guard version.hasPrefix("https://jsonfeed.org/version/1") else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "not JSON Feed 1.x")
        }
        title = container.lenient(.title)
        feedURL = container.lenient(.feedURL)
        nextURL = container.lenient(.nextURL)
        icon = container.lenient(.icon)
        items = (container.lenient([Lenient<Item>].self, .items) ?? []).compactMap(\.value)
    }

    static func decode(_ data: Data) throws -> JSONFeed {
        try JSONDecoder().decode(JSONFeed.self, from: data)
    }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or nil when it is missing or of another type.
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    fileprivate func lenient(_ key: Key) -> String? {
        lenient(String.self, key)
    }

    /// An ID sent as a string or a whole number.
    fileprivate func lenientIdentifier(_ key: Key) -> String? {
        if let text = lenient(String.self, key) { return text }
        if let number = lenient(Int64.self, key) { return String(number) }
        return nil
    }
}
