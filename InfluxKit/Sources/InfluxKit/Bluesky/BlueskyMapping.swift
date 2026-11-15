import Foundation

/// Turns app view feed pages into store items. Pure, so it runs wherever the
/// fetch finished, off the main actor, and tests feed it recorded pages.
enum BlueskyMapping {
    /// A page's items, in the page's order. Entries Influx can't show (no
    /// usable date) are dropped.
    static func items(_ page: FeedPage, sourceID: String, fetchedAt: Date) -> [Item] {
        mapped(page, sourceID: sourceID, fetchedAt: fetchedAt).map(\.item)
    }

    /// A page's items with what each still needs looked up before it is
    /// stored: sizes the app view didn't give.
    static func mapped(_ page: FeedPage, sourceID: String, fetchedAt: Date) -> [Mapped] {
        page.feed.compactMap { entry in
            item(entry, sourceID: sourceID, fetchedAt: fetchedAt).map { Mapped(item: $0, lookups: Media.of(entry.post.embed).lookups) }
        }
    }

    struct Mapped: Sendable {
        var item: Item
        var lookups: Lookups
    }

    /// Media the app view gave without a size. Until a lookup sizes them
    /// they are left out of the row, never boxed at a guess.
    struct Lookups: Sendable, Hashable {
        var media: [UnsizedMedia] = []
        var cardImage: String?
        /// The quoted post's picture, when the app view gave it no size.
        var quoteImage: UnsizedMedia?

        var isEmpty: Bool { !media.contains { $0.sized == nil } && cardImage == nil && quoteImage == nil }
    }

    /// `mapped.item` with its lookups done.
    static func completing(_ mapped: Mapped, with resolver: MediaResolver) async -> Item {
        var item = mapped.item
        if mapped.lookups.media.contains(where: { $0.sized == nil }) {
            item.media = await resolver.sized(mapped.lookups.media)
        }
        if let thumb = mapped.lookups.cardImage {
            item.linkCard?.image = await resolver.sized([UnsizedMedia(kind: .image, url: thumb)]).first
        }
        if let still = mapped.lookups.quoteImage, item.quote != nil {
            item.quote?.image = await resolver.sized([still]).first
        }
        return item
    }

    static func item(_ entry: FeedViewPost, sourceID: String, fetchedAt: Date) -> Item? {
        let post = entry.post
        guard let indexedAt = ATDate.parse(post.indexedAt) else { return nil }

        // A boost is its own item, dated when it was boosted, and merges with
        // the original by the post's URI.
        var remoteID = post.uri
        var sortDate = indexedAt
        var boostedBy: String?
        var boostedByID: String?
        var boostedByAvatar: String?
        if case .repost(let by, let uri, let boostedAt) = entry.reason, let boostedDate = ATDate.parse(boostedAt) {
            remoteID = uri ?? "\(post.uri)#repost:\(by.did)"
            sortDate = boostedDate
            boostedBy = by.name
            boostedByID = by.did
            boostedByAvatar = by.avatar?.nilIfEmpty
        }

        var replyToHandle: String?
        if case .post(let parent) = entry.reply?.parent {
            replyToHandle = "@" + parent.author.handle
        }

        let media = Media.of(post.embed)
        return Item(
            sourceID: sourceID, remoteID: remoteID, kind: .post, mergeKey: post.uri,
            authorName: post.author.name, authorHandle: "@" + post.author.handle,
            authorAvatar: post.author.avatar?.nilIfEmpty,
            body: post.record.text, url: url(of: post),
            publishedAt: publishedAt(post.record.createdAt, indexedAt: indexedAt),
            fetchedAt: fetchedAt, sortDate: sortDate,
            boostedBy: boostedBy, boostedByID: boostedByID, boostedByAvatar: boostedByAvatar, replyToHandle: replyToHandle,
            linkCard: media.linkCard, media: media.lookups.media.compactMap(\.sized),
            actionRef: actionRef(uri: post.uri, cid: post.cid), quote: media.quote,
            viewer: viewer(post.viewer),
            links: links(post.record)
        )
    }

    /// The record's facets as links into its text, in UTF-16 offsets. A
    /// facet whose bytes don't fall on character boundaries, or run past
    /// the text, is dropped. Mentions and tags open on bsky.app.
    static func links(_ record: PostRecord) -> [Item.Link] {
        let text = record.text
        let utf8 = text.utf8
        return record.facets.compactMap { facet in
            guard let target = facet.target, facet.byteStart >= 0, facet.byteEnd > facet.byteStart, facet.byteEnd <= utf8.count,
                  let start = utf8.index(utf8.startIndex, offsetBy: facet.byteStart).samePosition(in: text),
                  let end = utf8.index(utf8.startIndex, offsetBy: facet.byteEnd).samePosition(in: text)
            else { return nil }
            let url: String? = switch target {
            case .link(let uri): URL(string: uri).flatMap { ["https", "http"].contains($0.scheme?.lowercased()) ? uri : nil }
            case .mention(let did): "https://bsky.app/profile/\(did)"
            case .tag(let tag): tag.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).map { "https://bsky.app/hashtag/\($0)" }
            }
            guard let url else { return nil }
            let offset = text.utf16.distance(from: text.utf16.startIndex, to: start)
            return Item.Link(start: offset, length: text.utf16.distance(from: start, to: end), url: url)
        }
    }

    /// One post on its own, as a thread shows it, with its lookups.
    static func mapped(_ post: PostView, sourceID: String, fetchedAt: Date) -> Mapped? {
        item(FeedViewPost(post: post), sourceID: sourceID, fetchedAt: fetchedAt).map { Mapped(item: $0, lookups: Media.of(post.embed).lookups) }
    }

    static func viewer(_ state: ViewerState?) -> Item.Viewer {
        Item.Viewer(liked: state?.like != nil, boosted: state?.repost != nil, bookmarked: state?.bookmarked ?? false,
                    likeRef: state?.like, boostRef: state?.repost)
    }

    /// What likes and boosts need: a strong reference to the post itself
    /// (never the boost record), as JSON.
    struct ActionRef: Codable, Hashable {
        var uri: String
        var cid: String

        init(uri: String, cid: String) {
            self.uri = uri
            self.cid = cid
        }

        /// Read back from `Item.actionRef`.
        init?(_ stored: String?) {
            guard let stored, let ref = try? JSONDecoder().decode(ActionRef.self, from: Data(stored.utf8)) else { return nil }
            self = ref
        }
    }

    static func actionRef(uri: String, cid: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(ActionRef(uri: uri, cid: cid)), as: UTF8.self)
    }

    /// The date a post shows: when its author says they wrote it, unless
    /// that is missing, later than when the network first saw it, or more
    /// than a day before (a backdated or imported post). Then it is the
    /// date the network saw it, which also keeps an old import from
    /// expiring the moment it arrives.
    static func publishedAt(_ createdAt: String?, indexedAt: Date) -> Date {
        guard let created = createdAt.flatMap(ATDate.parse), created <= indexedAt,
              indexedAt.timeIntervalSince(created) <= 24 * 60 * 60 else {
            return indexedAt
        }
        return created
    }

    /// The bsky.app address of a post, for opening and sharing.
    /// Where the post opens on the web: for a copy Bridgy Fed made of a
    /// fediverse post, the original on its own server, which is also the
    /// address the store joins the two copies on (ADR 0014); else bsky.app.
    static func url(of post: PostView) -> String? {
        bridgedOriginal(of: post) ?? webURL(postURI: post.uri)
    }

    /// The original of a post Bridgy Fed copied in from the fediverse. Any
    /// record can carry `bridgyOriginalUrl`, so it counts only from an
    /// author whose handle only Bridgy Fed can give (the app view checks
    /// handles), `user.instance.ap.brid.gy`, and only on that instance.
    static func bridgedOriginal(of post: PostView) -> String? {
        let suffix = ".ap.brid.gy"
        let handle = post.author.handle.lowercased()
        guard handle.hasSuffix(suffix), let original = post.record.bridgyOriginalUrl,
              let url = URL(string: original), url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(), !host.isEmpty
        else { return nil }
        let account = handle.dropLast(suffix.count)
        return account.hasSuffix("." + host) && account.count > host.count + 1 ? original : nil
    }

    static func webURL(postURI: String) -> String? {
        // at://did:plc:abc/app.bsky.feed.post/3k...
        let parts = postURI.split(separator: "/", omittingEmptySubsequences: true)
        guard postURI.hasPrefix("at://"), parts.count == 4, parts[2] == "app.bsky.feed.post" else { return nil }
        return "https://bsky.app/profile/\(parts[1])/post/\(parts[3])"
    }

    /// What a post's embed adds to its row.
    struct Media {
        var linkCard: Item.LinkCard?
        var quote: Item.Quote?
        var lookups = Lookups()

        static func of(_ embed: Embed?) -> Media {
            var media = Media()
            switch embed {
            case .recordWithMedia(let record, let inner):
                media = of(inner)
                media.setQuote(record)
            case .record(let record):
                media.setQuote(record)
            case .images(let images):
                media.lookups.media = images.compactMap { image in
                    guard let url = image.fullsize ?? image.thumb else { return nil }
                    let size = image.aspectRatio?.pixels
                    return UnsizedMedia(kind: .image, url: url, previewURL: image.thumb, width: size?.width, height: size?.height, altText: image.alt)
                }
            case .video(let video):
                if let playlist = video.playlist {
                    let size = video.aspectRatio?.pixels
                    media.lookups.media = [UnsizedMedia(kind: .video, url: playlist, previewURL: video.thumbnail, width: size?.width, height: size?.height, altText: video.alt)]
                }
            case .external(let external):
                media.linkCard = linkCard(external)
                // The app view gives the card's image no size.
                if media.linkCard != nil, let thumb = external.thumb, !thumb.isEmpty { media.lookups.cardImage = thumb }
            case .other, nil:
                break
            }
            return media
        }

        static func linkCard(_ external: ExternalView) -> Item.LinkCard? {
            guard let url = URL(string: external.uri), let scheme = url.scheme, scheme == "https" || scheme == "http",
                  var site = url.host, !site.isEmpty else {
                return nil
            }
            if site.hasPrefix("www.") { site.removeFirst(4) }
            let title = external.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return Item.LinkCard(url: external.uri, site: site, title: title.isEmpty ? site : title, summary: external.description)
        }

        /// The quote, with its picture sized now or left for a lookup.
        mutating func setQuote(_ record: EmbeddedRecord) {
            quote = Self.quote(record)
            guard case .post(_, _, _, let embeds) = record, let still = Self.still(embeds) else { return }
            if let sized = still.sized {
                quote?.image = sized
            } else if quote != nil {
                lookups.quoteImage = still
            }
        }

        /// The quote card, or an unavailable quote, with its post's web
        /// address, for a post the app view won't show. A feed, list or
        /// other record has no card.
        static func quote(_ record: EmbeddedRecord) -> Item.Quote? {
            if case .unavailablePost(let uri) = record {
                guard uri.hasPrefix("at://") else { return nil }
                return .unavailable(url: BlueskyMapping.webURL(postURI: uri))
            }
            guard case .post(let uri, let author, let quoted, _) = record else { return nil }
            return Item.Quote(
                mergeKey: uri, url: BlueskyMapping.webURL(postURI: uri),
                authorName: author.name, authorHandle: "@" + author.handle, body: quoted.text
            )
        }

        /// The first picture among a quoted post's embeds: an image, a
        /// video's still, or a link card's thumbnail.
        static func still(_ embeds: [Embed]) -> UnsizedMedia? {
            for embed in embeds {
                switch embed {
                case .images(let images):
                    guard let image = images.first, let url = image.fullsize ?? image.thumb else { continue }
                    let size = image.aspectRatio?.pixels
                    return UnsizedMedia(kind: .image, url: url, width: size?.width, height: size?.height, altText: image.alt)
                case .video(let video):
                    guard let thumbnail = video.thumbnail else { continue }
                    let size = video.aspectRatio?.pixels
                    return UnsizedMedia(kind: .image, url: thumbnail, width: size?.width, height: size?.height, altText: video.alt)
                case .external(let external):
                    guard let thumb = external.thumb, !thumb.isEmpty else { continue }
                    return UnsizedMedia(kind: .image, url: thumb)
                case .recordWithMedia(_, let media):
                    if let still = still([media]) { return still }
                case .record, .other:
                    continue
                }
            }
            return nil
        }
    }
}

/// AT Protocol datetimes: RFC 3339, usually with milliseconds and "Z", but
/// any number of fractional digits and an offset are valid.
enum ATDate {
    static func format(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    static func parse(_ text: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let date = try? withFraction.parse(text) { return date }
        if let date = try? Date.ISO8601FormatStyle().parse(text) { return date }
        // Some parsers stop at three digits; keep the whole seconds instead.
        if let dot = text.firstIndex(of: "."),
           let end = text[dot...].dropFirst().firstIndex(where: { !$0.isNumber }) {
            return try? Date.ISO8601FormatStyle().parse(String(text[..<dot] + text[end...]))
        }
        return nil
    }
}
