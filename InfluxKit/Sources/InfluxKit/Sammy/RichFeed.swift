import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// How Influx asks a Sammy server for a feed, and how it tells what came
/// back (ADR 0031). A feed is a rich feed of authored posts or an article
/// feed, and only the response says which: its `Content-Type` and the
/// body's `format` and `version`. What Influx knows of a feed beforehand
/// (`Source.itemKind`) only picks the `Accept` it sends and the window it
/// fetches; it never makes a response an article.
enum SammyNegotiation {
    /// The one rich representation this build reads.
    static let rich = "application/vnd.sammy.rich-feed+json; version=1"
    static let article = "application/feed+json"
    /// Either: a rich feed answers rich, an article feed as an article.
    static let either = "\(rich), \(article)"
    /// The weak `ETag` prefix of a rich page, its proof of format on a 304.
    static let richETagPrefix = "W/\"rich-v1-"

    /// What a feed request sends: the rich value alone for a feed known to
    /// be posts, else either.
    static func accept(for kind: Item.Kind?) -> String {
        kind == .post ? rich : either
    }

    /// What a response says it is, by its `Content-Type` alone.
    enum Representation: Sendable, Hashable {
        case rich
        case article
    }

    /// `.rich` only for exactly the rich value: its type and one
    /// `version=1`, nothing else. `.article` for `application/feed+json`
    /// or `application/json`, whatever their parameters. Anything else,
    /// a missing header included, is nil.
    static func representation(of response: HTTPURLResponse) -> Representation? {
        guard let value = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let type = parts[0].lowercased()
        switch type {
        case "application/feed+json", "application/json":
            return .article
        case "application/vnd.sammy.rich-feed+json":
            let parameters = parts.dropFirst().map { part -> (String, String)? in
                guard let equals = part.firstIndex(of: "=") else { return nil }
                return (part[..<equals].trimmingCharacters(in: .whitespaces).lowercased(),
                        part[part.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            }
            guard parameters.count == 1, let only = parameters[0], only == ("version", "1") else { return nil }
            return .rich
        default:
            return nil
        }
    }

    /// Throws the error a response stands for, as `ConnectorError.check`
    /// does, except that a 406 is `.unsupported`: the server serves this
    /// feed in no form this build reads.
    static func check(_ response: HTTPURLResponse, now: Date) throws {
        if response.statusCode == 406 { throw ConnectorError.unsupported }
        try ConnectorError.check(response, now: now)
    }

    /// The top of a JSON body: whether it names a `format`, and what format
    /// and version it names.
    struct Envelope: Decodable {
        var namesFormat: Bool
        var format: String?
        var version: Int?

        enum CodingKeys: String, CodingKey { case format, version }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            namesFormat = container.contains(.format)
            format = (try? container.decodeIfPresent(String.self, forKey: .format)) ?? nil
            version = (try? container.decodeIfPresent(Int.self, forKey: .version)) ?? nil
        }

        /// The envelope of `data`, or nil when it isn't a JSON object.
        static func of(_ data: Data) -> Envelope? {
            try? JSONDecoder().decode(Envelope.self, from: data)
        }
    }

    /// Whether `data` is an article body: a JSON object with no `format`.
    static func isArticleBody(_ data: Data) -> Bool {
        Envelope.of(data).map { !$0.namesFormat } ?? false
    }
}

/// A page of a rich feed, version 1, as far as Influx reads it. The
/// envelope is checked strictly and refuses the whole page; a post that
/// breaks a rule, its media's included, is dropped alone. `capabilities`,
/// `extensions` and the page's `source` are not used.
struct RichFeedPage: Sendable, Hashable {
    /// The most links the contract lets a post carry. A post with more
    /// breaks it and is dropped, so a row never decodes an unbounded list.
    static let maxLinks = 64
    /// The most aliases the contract lets a post carry. A post with more
    /// breaks it and is dropped: its aliases are never cut short.
    static let maxAliases = 16
    /// The most attachments the contract lets a post carry.
    static let maxMedia = 8
    /// The largest side, in pixels, an attachment may have.
    static let maxMediaSide = 16384
    /// The longest alt text, in code points.
    static let maxAltLength = 1500
    /// The longest video or GIF: a day.
    static let maxDurationMs = 86_400_000

    static let format = "sammy.rich-feed"
    static let version = 1

    struct Post: Sendable, Hashable {
        /// The row's identity within its feed (`items[].id`).
        var id: String
        /// The post's identity across feeds (`items[].canonicalId`).
        var canonicalID: String
        /// The post's other identities (`items[].aliases`), each a
        /// lower-case `urn:uuid:`, none repeated and none its canonical ID.
        var aliases: [String] = []
        var url: String
        var authorName: String
        var authorURL: String?
        /// The author's picture (`author.avatar.id`): a media ID, read
        /// through a grant like an attachment, never a URL.
        var authorAvatarID: String?
        /// The author's handle as the source shows it (`author.handle`),
        /// kept only when it fits the contract's grammar.
        var authorHandle: String?
        /// Exactly as sent: plain text, line breaks and all.
        var text: String
        var links: [Link]
        /// The post's attachments in authored order; empty without any.
        var media: [Media] = []
        var publishedAt: Date
        /// Who reposted the post into the feed; the post itself stays the
        /// original, its author's.
        var repostedBy: Person?
        /// The one post this one quotes, one level deep.
        var quote: Quote?
        /// The post's thread, as the thread route names it
        /// (`[A-Za-z0-9_-]{1,256}`), when the source says it has one.
        var threadRef: String?
        /// The source's preview of one of the post's links, on a post with
        /// no media and no quote.
        var card: Card?
    }

    /// A link card (`card`): one of the post's links, as the source shows
    /// it under the post.
    struct Card: Sendable, Hashable {
        /// One of the post's links, exactly.
        var url: String
        var title: String
        var description: String?
        /// The name or host the source shows the link as.
        var site: String?
        var image: CardImage?
    }

    /// A card's picture: a media ID and the size to lay it out at, read
    /// through a grant like an attachment, never a URL.
    struct CardImage: Sendable, Hashable {
        var id: String
        var width: Int
        var height: Int
    }

    /// Someone a post names: its author, or who reposted it.
    struct Person: Sendable, Hashable {
        var name: String
        /// Kept only when it is a safe https URL.
        var url: String?
        /// Their picture's media ID, kept only when it is one.
        var avatarID: String?
        /// Their handle, kept only when it fits the contract's grammar.
        var handle: String?
    }

    /// The post a post quotes.
    enum Quote: Sendable, Hashable {
        case post(QuotedPost)
        /// A post the source can't show (deleted, private or unreachable):
        /// only where it was is known.
        case unavailable(url: String)
    }

    /// A quoted post: never a repost, and quoting nothing itself.
    struct QuotedPost: Sendable, Hashable {
        var url: String
        /// The quoted post's identity, when the source knows it.
        var canonicalID: String?
        var author: Person
        var text: String
        var media: [Media]
        var publishedAt: Date
    }

    /// One attachment as the page describes it: no URL, only what to lay
    /// it out with and the ID to ask for its bytes with.
    struct Media: Sendable, Hashable {
        var id: String
        var kind: Item.Media.Kind
        var width: Int
        var height: Int
        var alt: String?
        var durationMs: Int?
        /// Whether a video or GIF has a still preview.
        var preview: Bool
    }

    struct Link: Sendable, Hashable {
        var url: String
        var text: String?
    }

    var feedID: String
    /// The page after this one, checked to be on the feed's own origin and
    /// path.
    var nextURL: String?
    /// Where the posts that enter the feed after this read are read from,
    /// whatever their `publishedAt` (a since read), checked to be on the
    /// feed's own origin and path. Nil when the server offers none.
    var sinceURL: String?
    var posts: [Post]

    /// The page in `data`, for the feed `feedID` at `feedURL`. Throws
    /// `.badResponse` for a body of another format or version, for another
    /// feed, or with a `nextUrl` off the feed's own origin and path.
    static func decode(_ data: Data, feedID: String, feedURL: URL) throws -> RichFeedPage {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw ConnectorError.badResponse("not a rich feed page")
        }
        guard raw.format == format, raw.version == version else {
            throw ConnectorError.badResponse("a rich feed page of another format or version")
        }
        guard raw.feed.id == feedID else { throw ConnectorError.badResponse("a page of another feed") }
        if let next = raw.nextURL {
            guard isSafeHTTPS(next), let url = URL(string: next), ServerAddress.isSameOrigin(url, feedURL), url.path == feedURL.path else {
                throw ConnectorError.badResponse("a next page off the feed")
            }
        }
        // A since link off the feed is left out, not the page: without it
        // the feed is read as before.
        let since = raw.sinceURL.flatMap { link -> String? in
            guard isSafeHTTPS(link), let url = URL(string: link), ServerAddress.isSameOrigin(url, feedURL), url.path == feedURL.path else {
                return nil
            }
            return link
        }
        return RichFeedPage(feedID: raw.feed.id, nextURL: raw.nextURL, sinceURL: since, posts: raw.items.compactMap { $0.value?.post })
    }

    private struct Raw: Decodable {
        struct Feed: Decodable { var id: String }
        var format: String
        var version: Int
        var feed: Feed
        var nextURL: String?
        var sinceURL: String?
        var items: [Lenient<RawPost>]

        enum CodingKeys: String, CodingKey {
            case format, version, feed, items
            case nextURL = "nextUrl"
            case sinceURL = "sinceUrl"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decode(String.self, forKey: .format)
            version = try container.decode(Int.self, forKey: .version)
            feed = try container.decode(Feed.self, forKey: .feed)
            nextURL = try container.decodeIfPresent(String.self, forKey: .nextURL)
            // Optional, and never a reason to refuse the page.
            sinceURL = (try? container.decodeIfPresent(String.self, forKey: .sinceURL)) ?? nil
            items = try container.decode([Lenient<RawPost>].self, forKey: .items)
        }
    }

    /// A post as a page or a thread sends it, before its rules are checked
    /// (`post`).
    struct RawPost: Decodable {
        struct Classification: Decodable { var kind: String }
        /// An author as sent. Its picture (`avatar`, `{id}`) and handle
        /// (`handle`) are not part of the post: one that doesn't fit the
        /// contract is left out, and the post stays.
        struct Author: Decodable {
            var name: String
            var url: String?
            var avatarID: String?
            var handle: String?

            enum CodingKeys: String, CodingKey { case name, url, avatar, handle }
            struct Avatar: Decodable { var id: String }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                name = try container.decode(String.self, forKey: .name)
                url = try container.decodeIfPresent(String.self, forKey: .url)
                let avatar = (try? container.decodeIfPresent(Avatar.self, forKey: .avatar)) ?? nil
                avatarID = avatar.map(\.id).flatMap { SammyMediaReference.isMediaID($0) ? $0 : nil }
                let handle = (try? container.decodeIfPresent(String.self, forKey: .handle)) ?? nil
                self.handle = handle.flatMap { RichFeedPage.isHandle($0) ? $0 : nil }
            }
        }
        /// A link card as sent. It is not part of the post either: one that
        /// breaks the contract is left out, and the post stays, its link
        /// listed after its text.
        struct RawCard: Decodable {
            struct RawImage: Decodable { var id: String; var width: Int; var height: Int }
            var url: String
            var title: String
            var description: String?
            var site: String?
            var image: RawImage?
        }
        struct RawLink: Decodable { var url: String; var text: String? }
        struct RawThread: Decodable { var ref: String }

        /// Any key of an object, to tell which fields it has.
        struct AnyKey: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        /// A quote as sent: a post, or exactly `{url, unavailable: true}`.
        /// A quote can't carry a quote, a repost or a thread, so one that
        /// does fails its post, as does an unavailable one with any other
        /// field.
        enum RawQuote: Decodable {
            case post(url: String, canonicalId: String?, author: Author, text: String, media: [RawMedia]?, publishedAt: String)
            case unavailable(url: String)
            case invalid

            enum CodingKeys: String, CodingKey { case url, canonicalId, author, text, media, publishedAt, unavailable }

            init(from decoder: any Decoder) throws {
                let keys = Set(try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue))
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let url = try container.decode(String.self, forKey: .url)
                if keys.contains("unavailable") {
                    let unavailable = try container.decode(Bool.self, forKey: .unavailable)
                    self = unavailable && keys == ["url", "unavailable"] ? .unavailable(url: url) : .invalid
                    return
                }
                guard keys.isDisjoint(with: ["quote", "repostedBy", "thread"]) else {
                    self = .invalid
                    return
                }
                func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
                    container.contains(key) ? try container.decode(type, forKey: key) : nil
                }
                self = .post(
                    url: url, canonicalId: try optional(String.self, .canonicalId),
                    author: try container.decode(Author.self, forKey: .author), text: try container.decode(String.self, forKey: .text),
                    media: try optional([RawMedia].self, .media), publishedAt: try container.decode(String.self, forKey: .publishedAt)
                )
            }
        }
        /// An attachment, typed as the contract types it, so one of a kind
        /// this build reads with a field of the wrong type fails its post.
        /// One of another kind needs only its `id`.
        struct RawMedia: Decodable {
            var id: String
            var kind: String
            var width: Int?
            var height: Int?
            var alt: String?
            var durationMs: Int?
            var preview: Bool?

            enum CodingKeys: String, CodingKey { case id, kind, width, height, alt, durationMs, preview }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                kind = try container.decode(String.self, forKey: .kind)
                guard Item.Media.Kind(rawValue: kind) != nil else { return }
                width = try container.decode(Int.self, forKey: .width)
                height = try container.decode(Int.self, forKey: .height)
                // Each optional field is absent or of its type; a null is
                // neither, and fails the post.
                func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
                    container.contains(key) ? try container.decode(type, forKey: key) : nil
                }
                alt = try optional(String.self, .alt)
                durationMs = try optional(Int.self, .durationMs)
                preview = try optional(Bool.self, .preview)
            }
        }

        var id: String
        var canonicalId: String
        var aliases: [String]?
        var classification: Classification
        var url: String
        var author: Author
        var text: String
        var links: [Lenient<RawLink>]?
        var media: [RawMedia]?
        var publishedAt: String?
        var repostedBy: Author?
        var quote: RawQuote?
        var thread: RawThread?
        var card: RawCard?

        enum CodingKeys: String, CodingKey {
            case id, canonicalId, aliases, classification, url, author, text, links, media, publishedAt, repostedBy, quote, thread, card
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            canonicalId = try container.decode(String.self, forKey: .canonicalId)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases)
            classification = try container.decode(Classification.self, forKey: .classification)
            url = try container.decode(String.self, forKey: .url)
            author = try container.decode(Author.self, forKey: .author)
            text = try container.decode(String.self, forKey: .text)
            links = try container.decodeIfPresent([Lenient<RawLink>].self, forKey: .links)
            // `media` is absent or a list; a null is neither, and fails
            // the post as a list of the wrong type would.
            media = container.contains(.media) ? try container.decode([RawMedia].self, forKey: .media) : nil
            publishedAt = try container.decodeIfPresent(String.self, forKey: .publishedAt)
            // Each is absent or an object; a null is neither, and fails
            // the post.
            func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
                container.contains(key) ? try container.decode(type, forKey: key) : nil
            }
            repostedBy = try optional(Author.self, .repostedBy)
            quote = try optional(RawQuote.self, .quote)
            thread = try optional(RawThread.self, .thread)
            card = (try? container.decodeIfPresent(RawCard.self, forKey: .card)) ?? nil
        }

        /// The post, or nil when it breaks a rule of the contract.
        var post: Post? {
            guard RichFeedPage.isCanonicalURN(id), RichFeedPage.isCanonicalURN(canonicalId), classification.kind == "post",
                  !text.isEmpty, !author.name.isEmpty, RichFeedPage.isSafeHTTPS(url),
                  (links ?? []).count <= RichFeedPage.maxLinks,
                  RichFeedPage.areAliases(aliases ?? [], of: canonicalId),
                  let media = RichFeedPage.media(media),
                  let published = publishedAt.flatMap(RichFeedPage.publishTime) else { return nil }
            var repost: Person?
            if let repostedBy {
                guard let person = RichFeedPage.person(repostedBy) else { return nil }
                repost = person
            }
            var quoted: Quote?
            if let quote {
                guard let valid = RichFeedPage.quote(quote) else { return nil }
                quoted = valid
            }
            if let thread, !RichFeedPage.isThreadRef(thread.ref) { return nil }
            let links = (links ?? []).compactMap(\.value).filter { RichFeedPage.isSafeHTTPS($0.url) }.map { Link(url: $0.url, text: $0.text) }
            // A card only on a post that shows nothing else under its text.
            let shownCard = media.isEmpty && quoted == nil ? card.flatMap { RichFeedPage.card($0, links: links) } : nil
            return Post(
                id: id, canonicalID: canonicalId, aliases: aliases ?? [], url: url, authorName: author.name,
                authorURL: author.url.flatMap { RichFeedPage.isSafeHTTPS($0) ? $0 : nil }, authorAvatarID: author.avatarID,
                authorHandle: author.handle,
                text: text, links: links, media: media, publishedAt: published,
                repostedBy: repost, quote: quoted, threadRef: thread?.ref, card: shownCard
            )
        }
    }

    /// Someone a post names, held to the rules of a post's author: a name
    /// of 1 to 300 code points, and a URL kept only when it is safe https.
    private static func person(_ raw: RawPost.Author) -> Person? {
        guard (1...300).contains(raw.name.unicodeScalars.count) else { return nil }
        return Person(name: raw.name, url: raw.url.flatMap { isSafeHTTPS($0) ? $0 : nil }, avatarID: raw.avatarID, handle: raw.handle)
    }

    /// The longest card title, description and site, in code points.
    static let maxCardTitleLength = 300
    static let maxCardDescriptionLength = 1000
    static let maxCardSiteLength = 100

    /// A card, or nil when it breaks the contract: a URL that isn't one of
    /// the post's links, a title, description or site that is empty or too
    /// long, or a picture whose ID isn't one or whose side is out of range.
    private static func card(_ raw: RawPost.RawCard, links: [Link]) -> Card? {
        func fits(_ value: String?, _ limit: Int) -> Bool {
            value.map { (1...limit).contains($0.unicodeScalars.count) } ?? true
        }
        guard links.contains(where: { $0.url == raw.url }), isSafeHTTPS(raw.url),
              (1...maxCardTitleLength).contains(raw.title.unicodeScalars.count),
              fits(raw.description, maxCardDescriptionLength), fits(raw.site, maxCardSiteLength) else { return nil }
        var image: CardImage?
        if let raw = raw.image {
            guard SammyMediaReference.isMediaID(raw.id), (1...maxMediaSide).contains(raw.width),
                  (1...maxMediaSide).contains(raw.height) else { return nil }
            image = CardImage(id: raw.id, width: raw.width, height: raw.height)
        }
        return Card(url: raw.url, title: raw.title, description: raw.description, site: raw.site, image: image)
    }

    /// Whether `value` is a handle as the contract allows one: `@` and 1 to
    /// 64 of `[A-Za-z0-9_.@-]`.
    static func isHandle(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (2...65).contains(bytes.count), bytes[0] == UInt8(ascii: "@") else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || [UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "@"), UInt8(ascii: "-")].contains(byte)
        }
    }

    /// A quote, or nil when it breaks the contract: a URL that isn't safe
    /// https, a malformed identity, an author or text a post couldn't
    /// have, media a post couldn't carry or no publish time. One that
    /// carries a quote, a repost or a thread, or an unavailable one with
    /// another field, is already `.invalid`.
    private static func quote(_ raw: RawPost.RawQuote) -> Quote? {
        switch raw {
        case .invalid:
            return nil
        case .unavailable(let url):
            return isSafeHTTPS(url) ? .unavailable(url: url) : nil
        case let .post(url, canonicalID, author, text, media, publishedAt):
            guard isSafeHTTPS(url), canonicalID.map(isCanonicalURN) ?? true, let author = person(author),
                  (1...maxTextLength).contains(text.unicodeScalars.count), let media = self.media(media),
                  let published = publishTime(publishedAt) else { return nil }
            return .post(QuotedPost(url: url, canonicalID: canonicalID, author: author, text: text, media: media, publishedAt: published))
        }
    }

    /// The longest text a quoted post may have, in code points.
    static let maxTextLength = 100_000

    /// Whether `value` is a thread reference as the contract allows one:
    /// `[A-Za-z0-9_-]`, 1 to 256 bytes.
    static func isThreadRef(_ value: String) -> Bool {
        SammyMediaReference.isMediaID(value, upTo: 256)
    }

    /// A post's attachments, or nil when they break the contract: more than
    /// `maxMedia`, none at all where `media` is present, an ID that isn't
    /// one or is repeated, a side outside 1 to `maxMediaSide`, an empty or
    /// over-long alt text, a duration out of range, or a duration or
    /// preview on an image. An attachment of a kind this build doesn't
    /// know is left out, as the contract asks; it still counts and needs
    /// an ID of its own.
    private static func media(_ raw: [RawPost.RawMedia]?) -> [Media]? {
        guard let raw else { return [] }
        guard !raw.isEmpty, raw.count <= maxMedia else { return nil }
        var ids = Set<String>()
        var media: [Media] = []
        for entry in raw {
            guard SammyMediaReference.isMediaID(entry.id), ids.insert(entry.id).inserted else { return nil }
            guard let kind = Item.Media.Kind(rawValue: entry.kind) else { continue }
            guard let width = entry.width, let height = entry.height,
                  (1...maxMediaSide).contains(width), (1...maxMediaSide).contains(height),
                  entry.alt.map({ (1...maxAltLength).contains($0.unicodeScalars.count) }) ?? true,
                  entry.durationMs.map({ (1...maxDurationMs).contains($0) }) ?? true,
                  kind != .image || (entry.durationMs == nil && entry.preview == nil) else { return nil }
            media.append(Media(id: entry.id, kind: kind, width: width, height: height, alt: entry.alt,
                               durationMs: entry.durationMs, preview: entry.preview ?? false))
        }
        return media
    }

    /// Whether `aliases` are a post's other identities as the contract
    /// allows them: at most `maxAliases`, each a canonical `urn:uuid:`,
    /// none repeated and none the post's own `canonicalID`.
    static func areAliases(_ aliases: [String], of canonicalID: String) -> Bool {
        aliases.count <= maxAliases && aliases.allSatisfy(isCanonicalURN)
            && Set(aliases).count == aliases.count && !aliases.contains(canonicalID)
    }

    /// Whether `value` is `urn:uuid:` and a lower-case UUID, exactly: the
    /// only form a post's identities take.
    static func isCanonicalURN(_ value: String) -> Bool {
        let prefix = "urn:uuid:"
        guard value.hasPrefix(prefix) else { return false }
        let uuid = Array(value.utf8.dropFirst(prefix.utf8.count))
        guard uuid.count == 36 else { return false }
        for (index, byte) in uuid.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard byte == UInt8(ascii: "-") else { return false }
            } else {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte) else { return false }
            }
        }
        return true
    }

    /// Whether `value` is an absolute https URL with a host, no
    /// credentials and no whitespace or control characters.
    static func isSafeHTTPS(_ value: String) -> Bool {
        guard !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let url = URL(string: value), url.scheme == "https", let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    /// `2026-11-02T09:30:00Z`: RFC 3339 in UTC, to the second, as the
    /// contract sends it. Anything else is no time, and a post with no
    /// time is dropped rather than dated when it was fetched.
    static func publishTime(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        guard bytes.count == 20, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"), bytes[10] == UInt8(ascii: "T"),
              bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "Z") else { return nil }
        return FeedDate.iso8601(value)
    }
}

/// The merge key of a rich post, `sammy-post:<authority>:<canonical ID>`,
/// where the authority is the server named by the account's ID
/// (`<subject>@<host>`, ADR 0023). A post's canonical ID is the same in
/// every feed it appears in, so the same post in two of an account's feeds
/// is one row, while another server's posts can never share its key. The
/// store keeps this namespace for the posts of the account's own server
/// (`InfluxStore.reservingSammyPostKeys`).
enum SammyPostKey {
    static let prefix = "sammy-post:"

    /// The server part of a Sammy account ID: what follows its last `@`.
    static func authority(ofAccountID accountID: String?) -> String? {
        guard let accountID, let at = accountID.lastIndex(of: "@") else { return nil }
        let authority = accountID[accountID.index(after: at)...]
        return authority.isEmpty ? nil : String(authority)
    }

    static func make(authority: String, canonicalID: String) -> String {
        "\(prefix)\(authority):\(canonicalID)"
    }

    /// Whether `key` is a rich post's key for a post of the server that
    /// `accountID` belongs to.
    static func isOwn(_ key: String, accountID: String?) -> Bool {
        guard let authority = authority(ofAccountID: accountID) else { return false }
        let own = "\(prefix)\(authority):"
        return key.hasPrefix(own) && RichFeedPage.isCanonicalURN(String(key.dropFirst(own.count)))
    }

    /// The canonical ID a rich post's key names: its last 45 characters,
    /// when they are a `urn:uuid:`.
    static func canonicalID(of key: String) -> String? {
        guard key.hasPrefix(prefix) else { return nil }
        let canonical = String(key.suffix(45))
        return RichFeedPage.isCanonicalURN(canonical) && key.dropLast(45).hasSuffix(":") ? canonical : nil
    }

    /// The server part of a rich post's key, which says whose canonical
    /// IDs it names.
    static func authority(ofKey key: String) -> String? {
        guard canonicalID(of: key) != nil else { return nil }
        let authority = key.dropFirst(prefix.count).dropLast(46)
        return authority.isEmpty ? nil : String(authority)
    }
}

/// Turns a rich feed page's posts into timeline posts (ADR 0031): no title,
/// no actions, the author's picture when the page names one (a monogram
/// otherwise), and media laid out from the page
/// alone, each kept as a `SammyMediaReference`. Who reposted a post is its
/// booster, its quote the row's quote card, and its thread reference what
/// the connector reads its thread with (`SammyThreadRef`).
enum RichFeedMapper {
    static func items(from page: RichFeedPage, source: Source, fetchedAt: Date) -> [Item] {
        page.posts.map { item(from: $0, feedID: page.feedID, source: source, fetchedAt: fetchedAt) }
    }

    /// Each post's identities, `{canonicalId} ∪ aliases`, by its merge
    /// key, for the store to join it with other copies of the post
    /// (`PostIdentity`). A post whose key isn't a rich post's key (an
    /// account with no server in its ID) has none. Where a page repeats a
    /// canonical ID, its first set stands.
    static func identities(from page: RichFeedPage, source: Source) -> [String: [String]] {
        guard let authority = SammyPostKey.authority(ofAccountID: source.accountID) else { return [:] }
        var identities: [String: [String]] = [:]
        for post in page.posts {
            let key = SammyPostKey.make(authority: authority, canonicalID: post.canonicalID)
            if identities[key] == nil { identities[key] = [post.canonicalID] + post.aliases }
        }
        return identities
    }

    /// `post` as a timeline post. A post read in a thread names `thread`,
    /// whose grants its media, and its quote's, are asked for with.
    static func item(from post: RichFeedPage.Post, feedID: String, source: Source, fetchedAt: Date, thread: String? = nil) -> Item {
        // The card shows its own link, so it isn't listed again after the text.
        let (body, links) = textAndLinks(post.text, post.links, shownByCard: post.card?.url)
        // Without the account's server, the post can't be named across
        // feeds, so it merges only within its own.
        let authority = SammyPostKey.authority(ofAccountID: source.accountID)
        let mergeKey = authority.map { SammyPostKey.make(authority: $0, canonicalID: post.canonicalID) } ?? "\(source.id)#\(post.id)"
        return Item(
            sourceID: source.id,
            remoteID: post.id,
            kind: .post,
            mergeKey: mergeKey,
            authorName: post.authorName,
            authorHandle: post.authorHandle ?? handle(post.authorURL, else: post.url),
            authorAvatar: avatar(post.authorAvatarID, feedID: feedID, accountID: source.accountID, thread: thread),
            title: nil,
            body: body,
            url: post.url,
            publishedAt: post.publishedAt,
            fetchedAt: fetchedAt,
            // A repost is placed by the original post's time, as the
            // contract places it, so its row sits where the post's would.
            boostedBy: post.repostedBy?.name,
            boostedByID: post.repostedBy?.url,
            boostedByAvatar: avatar(post.repostedBy?.avatarID, feedID: feedID, accountID: source.accountID, thread: thread),
            linkCard: linkCard(post.card, feedID: feedID, accountID: source.accountID, thread: thread),
            media: media(post.media, feedID: feedID, accountID: source.accountID, thread: thread),
            actionRef: post.threadRef.map { SammyThreadRef(ref: $0).actionRef },
            quote: quote(post.quote, feedID: feedID, accountID: source.accountID, authority: authority, thread: thread),
            viewer: nil,
            links: links
        )
    }

    /// The row's link card: the source's own preview, its picture read
    /// through the same grant as the post's attachments and laid out at the
    /// card's size, so the row's height is final before any byte arrives.
    /// Without a site, the card names its link's host.
    static func linkCard(_ card: RichFeedPage.Card?, feedID: String, accountID: String?, thread: String?) -> Item.LinkCard? {
        guard let card else { return nil }
        let image = card.image.flatMap { image -> Item.Media? in
            guard let accountID,
                  let reference = SammyMediaReference(accountID: accountID, feedID: feedID, mediaID: image.id, thread: thread) else { return nil }
            return Item.Media(kind: .image, url: reference.string, width: image.width, height: image.height)
        }
        return Item.LinkCard(url: card.url, site: card.site ?? handle(card.url, else: card.url), title: card.title,
                             summary: card.description, image: image)
    }

    /// A picture's reference, read through the same grant as the post's
    /// attachments, the thread's for a thread post; nil without a picture or
    /// an account to ask with. It is drawn like any other profile picture,
    /// off the main thread at the avatar's size.
    static func avatar(_ mediaID: String?, feedID: String, accountID: String?, thread: String?) -> String? {
        guard let mediaID, let accountID else { return nil }
        return SammyMediaReference(accountID: accountID, feedID: feedID, mediaID: mediaID, thread: thread)?.string
    }

    /// What a row shows after a name: the host of `url`, else of
    /// `fallback`, without its `www.`.
    private static func handle(_ url: String?, else fallback: String) -> String {
        let host = (url.flatMap { URL(string: $0) } ?? URL(string: fallback))?.host()?.lowercased() ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The quote card: the quoted post's author, text and first picture (a
    /// video's or GIF's still), opening the quoted post's URL. A quote of
    /// a post the source can't show is an unavailable quote, whose card
    /// says so and opens its URL, as the contract asks.
    static func quote(_ quote: RichFeedPage.Quote?, feedID: String, accountID: String?, authority: String?,
                      thread: String?) -> Item.Quote? {
        let quoted: RichFeedPage.QuotedPost
        switch quote {
        case nil: return nil
        case .unavailable(let url)?: return .unavailable(url: url)
        case .post(let post)?: quoted = post
        }
        var mergeKey = quoted.url
        if let authority, let canonicalID = quoted.canonicalID {
            mergeKey = SammyPostKey.make(authority: authority, canonicalID: canonicalID)
        }
        return Item.Quote(
            mergeKey: mergeKey, url: quoted.url, authorName: quoted.author.name,
            authorHandle: quoted.author.handle ?? handle(quoted.author.url, else: quoted.url), body: quoted.text,
            image: still(of: quoted.media.first, feedID: feedID, accountID: accountID, thread: thread)
        )
    }

    /// An image's own reference, or a video's or GIF's preview, as an
    /// image at the attachment's size; nil for one with no still.
    private static func still(of entry: RichFeedPage.Media?, feedID: String, accountID: String?, thread: String?) -> Item.Media? {
        guard let entry, let accountID, entry.kind == .image || entry.preview,
              let reference = SammyMediaReference(accountID: accountID, feedID: feedID, mediaID: entry.id,
                                                  preview: entry.kind != .image, thread: thread) else { return nil }
        return Item.Media(kind: .image, url: reference.string, width: entry.width, height: entry.height, altText: entry.alt)
    }

    /// Each attachment at its own size, so the row's height is final before
    /// any byte arrives, with a reference in place of a URL: the
    /// attachment's, and its preview's for a video or GIF that has one.
    /// Without an account to ask with, there are none.
    static func media(_ media: [RichFeedPage.Media], feedID: String, accountID: String?, thread: String? = nil) -> [Item.Media] {
        guard let accountID else { return [] }
        return media.compactMap { entry in
            guard let reference = SammyMediaReference(accountID: accountID, feedID: feedID, mediaID: entry.id, thread: thread) else { return nil }
            let preview = entry.kind != .image && entry.preview
                ? SammyMediaReference(accountID: accountID, feedID: feedID, mediaID: entry.id, preview: true, thread: thread) : nil
            return Item.Media(kind: entry.kind, url: reference.string, previewURL: preview?.string, width: entry.width,
                              height: entry.height, altText: entry.alt, durationMs: entry.durationMs)
        }
    }

    /// The row's text and links. The text is the post's, exactly. A link
    /// whose URL, or else its own text, is in the text links that run, the
    /// first one no other link has taken; the rest are added after the
    /// text, after a blank line, one URL per line, each linked, except the
    /// one the row's link card shows (`shownByCard`). So the post's own text
    /// stays an exact prefix of the row's.
    static func textAndLinks(_ text: String, _ links: [RichFeedPage.Link], shownByCard: String? = nil) -> (String, [Item.Link]) {
        var placed: [Item.Link] = []
        var unplaced: [String] = []
        for link in links {
            let needles = [link.url] + [link.text].compactMap { $0?.isEmpty == false ? $0 : nil }
            if let found = needles.lazy.compactMap({ firstFree($0, in: text, taken: placed) }).first {
                placed.append(Item.Link(start: found.start, length: found.length, url: link.url))
            } else if !unplaced.contains(link.url), link.url != shownByCard {
                unplaced.append(link.url)
            }
        }
        guard !unplaced.isEmpty else { return (text, placed.sorted { $0.start < $1.start }) }
        var body = text + "\n\n"
        for (index, url) in unplaced.enumerated() {
            placed.append(Item.Link(start: body.utf16.count, length: url.utf16.count, url: url))
            body += url
            if index < unplaced.count - 1 { body += "\n" }
        }
        return (body, placed.sorted { $0.start < $1.start })
    }

    /// Where `needle` first occurs in `text` without overlapping a link
    /// already placed, in UTF-16 offsets.
    private static func firstFree(_ needle: String, in text: String, taken: [Item.Link]) -> (start: Int, length: Int)? {
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: needle, options: .literal, range: from..<text.endIndex) {
            let start = text.utf16.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.utf16.distance(from: range.lowerBound, to: range.upperBound)
            if !taken.contains(where: { $0.start < start + length && start < $0.start + $0.length }) {
                return (start, length)
            }
            from = text.index(after: range.lowerBound)
        }
        return nil
    }
}
