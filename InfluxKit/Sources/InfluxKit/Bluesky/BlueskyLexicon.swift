import Foundation

// The parts of the app.bsky lexicons Influx reads. Unions decode by `$type`,
// and a type Influx doesn't know becomes `.other` rather than failing the page,
// because Bluesky adds embed and reason types without notice.

/// A page of `app.bsky.feed.getTimeline` or `app.bsky.feed.getFeed`, newest
/// first. `cursor` fetches the next, older page; nil means the end.
struct FeedPage: Decodable, Sendable {
    var cursor: String?
    var feed: [FeedViewPost]

    enum CodingKeys: String, CodingKey { case cursor, feed }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cursor = try container.decodeIfPresent(String.self, forKey: .cursor)
        // One malformed entry drops that entry, not the page.
        feed = try container.decode([Lenient<FeedViewPost>].self, forKey: .feed).compactMap(\.value)
    }
}

struct Lenient<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

private struct TypeTag: Decodable {
    var type: String?
    enum CodingKeys: String, CodingKey { case type = "$type" }
}

/// `app.bsky.feed.defs#feedViewPost`
struct FeedViewPost: Decodable, Sendable {
    var post: PostView
    var reply: ReplyRef?
    var reason: Reason?

    init(post: PostView, reply: ReplyRef? = nil, reason: Reason? = nil) {
        self.post = post
        self.reply = reply
        self.reason = reason
    }
}

/// `app.bsky.actor.defs#profileViewBasic`
struct ProfileBasic: Decodable, Sendable, Hashable {
    var did: String
    var handle: String
    var displayName: String?
    /// The profile picture's address on the app view's CDN.
    var avatar: String?

    /// The display name, or the handle when there is none.
    var name: String {
        let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? handle : trimmed
    }
}

/// `app.bsky.feed.defs#postView`
struct PostView: Decodable, Sendable {
    var uri: String
    var cid: String
    var author: ProfileBasic
    var record: PostRecord
    var embed: Embed?
    var indexedAt: String
    var viewer: ViewerState?
}

/// `app.bsky.feed.defs#viewerState`: what the signed-in reader has done to
/// a post. `like` and `repost` are the URIs of the reader's own records.
struct ViewerState: Decodable, Sendable, Hashable {
    var like: String?
    var repost: String?
    var bookmarked: Bool?

    enum CodingKeys: String, CodingKey { case like, repost, bookmarked }

    init(like: String? = nil, repost: String? = nil, bookmarked: Bool? = nil) {
        self.like = like
        self.repost = repost
        self.bookmarked = bookmarked
    }

    /// Lenient: a field of a shape Influx doesn't expect is left unset rather
    /// than dropping the post.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        like = try? container.decodeIfPresent(String.self, forKey: .like)
        repost = try? container.decodeIfPresent(String.self, forKey: .repost)
        bookmarked = try? container.decodeIfPresent(Bool.self, forKey: .bookmarked)
    }
}

/// `app.bsky.feed.getPostThread`: the post, the chain it answers through
/// `parent`, and its replies.
struct PostThreadResponse: Decodable, Sendable {
    var thread: ThreadNode
}

/// `#threadViewPost`, or a post Influx can't show (`#notFoundPost`,
/// `#blockedPost`, anything newer).
indirect enum ThreadNode: Decodable, Sendable {
    case post(PostView, parent: ThreadNode?, replies: [ThreadNode])
    case unavailable

    private enum CodingKeys: String, CodingKey { case post, parent, replies }

    init(from decoder: any Decoder) throws {
        let tag = try TypeTag(from: decoder).type
        guard tag == "app.bsky.feed.defs#threadViewPost" || tag == nil,
              let container = try? decoder.container(keyedBy: CodingKeys.self),
              let post = try? container.decode(PostView.self, forKey: .post) else {
            self = .unavailable
            return
        }
        let parent = try? container.decodeIfPresent(ThreadNode.self, forKey: .parent)
        let replies = (try? container.decodeIfPresent([Lenient<ThreadNode>].self, forKey: .replies))?.compactMap(\.value) ?? []
        self = .post(post, parent: parent ?? nil, replies: replies)
    }
}

/// The parts of an `app.bsky.feed.post` record Influx shows.
struct PostRecord: Decodable, Sendable {
    var text: String
    var createdAt: String?
    var facets: [Facet]
    /// Where the post was first written, when Bridgy Fed copied it in from
    /// the fediverse: the original's web address, as its own server gives it.
    var bridgyOriginalUrl: String?

    enum CodingKeys: String, CodingKey { case text, createdAt, facets, bridgyOriginalUrl }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        createdAt = try? container.decodeIfPresent(String.self, forKey: .createdAt)
        facets = ((try? container.decodeIfPresent([Lenient<Facet>].self, forKey: .facets)) ?? nil)?.compactMap(\.value) ?? []
        bridgyOriginalUrl = (try? container.decodeIfPresent(String.self, forKey: .bridgyOriginalUrl)) ?? nil
    }
}

/// `app.bsky.richtext.facet`: a run of the text, by UTF-8 byte offsets,
/// that links somewhere.
struct Facet: Decodable, Sendable, Hashable {
    var byteStart: Int
    var byteEnd: Int
    /// Where the run goes: a link's URI, a mention's DID, or a tag.
    var target: Target?

    enum Target: Hashable, Sendable {
        case link(String)
        case mention(did: String)
        case tag(String)
    }

    private enum CodingKeys: String, CodingKey { case index, features }
    private struct Index: Decodable { var byteStart: Int; var byteEnd: Int }
    private struct Feature: Decodable {
        var type: String?
        var uri: String?
        var did: String?
        var tag: String?
        enum CodingKeys: String, CodingKey { case type = "$type", uri, did, tag }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let index = try container.decode(Index.self, forKey: .index)
        byteStart = index.byteStart
        byteEnd = index.byteEnd
        let features = (try? container.decode([Lenient<Feature>].self, forKey: .features))?.compactMap(\.value) ?? []
        target = features.lazy.compactMap { feature -> Target? in
            switch feature.type {
            case "app.bsky.richtext.facet#link": feature.uri.map(Target.link)
            case "app.bsky.richtext.facet#mention": feature.did.map { Target.mention(did: $0) }
            case "app.bsky.richtext.facet#tag": feature.tag.map(Target.tag)
            default: nil
            }
        }.first
    }
}

/// `app.bsky.feed.defs#replyRef`
struct ReplyRef: Decodable, Sendable {
    var parent: ReplyPost
}

/// The post a reply answers: `#postView`, `#notFoundPost` or `#blockedPost`.
enum ReplyPost: Decodable, Sendable {
    case post(PostView)
    case unavailable

    init(from decoder: any Decoder) throws {
        let tag = try TypeTag(from: decoder).type
        if tag == "app.bsky.feed.defs#postView" || tag == nil, let post = try? PostView(from: decoder) {
            self = .post(post)
        } else {
            self = .unavailable
        }
    }
}

/// Why a post is in a feed when its author isn't the reason.
enum Reason: Decodable, Sendable {
    /// `#reasonRepost`: someone the reader follows boosted it.
    case repost(by: ProfileBasic, uri: String?, indexedAt: String)
    /// `#reasonPin` and anything newer.
    case other

    private enum CodingKeys: String, CodingKey { case by, uri, indexedAt }

    init(from decoder: any Decoder) throws {
        guard try TypeTag(from: decoder).type == "app.bsky.feed.defs#reasonRepost" else {
            self = .other
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .repost(
            by: try container.decode(ProfileBasic.self, forKey: .by),
            uri: try container.decodeIfPresent(String.self, forKey: .uri),
            indexedAt: try container.decode(String.self, forKey: .indexedAt)
        )
    }
}

/// `app.bsky.embed.defs#aspectRatio`
struct AspectRatio: Decodable, Sendable, Hashable {
    var width: Double
    var height: Double

    var value: Double? { width > 0 && height > 0 ? width / height : nil }

    /// The size in whole pixels, which is what the lexicon gives.
    var pixels: (width: Int, height: Int)? {
        guard width >= 1, height >= 1, width < 1_000_000, height < 1_000_000 else { return nil }
        return (Int(width), Int(height))
    }
}

/// External link preview: `app.bsky.embed.external#viewExternal`.
struct ExternalView: Decodable, Sendable, Hashable {
    var uri: String
    var title: String
    var description: String
    var thumb: String?
}

/// `app.bsky.embed.images#viewImage`
struct ImageView: Decodable, Sendable, Hashable {
    var thumb: String?
    var fullsize: String?
    var alt: String?
    var aspectRatio: AspectRatio?
}

/// `app.bsky.embed.video#view`
struct VideoView: Decodable, Sendable, Hashable {
    var playlist: String?
    var thumbnail: String?
    var alt: String?
    var aspectRatio: AspectRatio?
}

/// A post's embed, as the app view presents it.
indirect enum Embed: Decodable, Sendable {
    case images([ImageView])
    case video(VideoView)
    case external(ExternalView)
    case record(EmbeddedRecord)
    case recordWithMedia(record: EmbeddedRecord, media: Embed)
    case other

    private enum CodingKeys: String, CodingKey { case images, external, record, media }
    private struct RecordBox: Decodable { var record: EmbeddedRecord }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try TypeTag(from: decoder).type {
        case "app.bsky.embed.images#view":
            self = .images(try container.decode([ImageView].self, forKey: .images))
        case "app.bsky.embed.video#view":
            self = .video(try VideoView(from: decoder))
        case "app.bsky.embed.external#view":
            self = .external(try container.decode(ExternalView.self, forKey: .external))
        case "app.bsky.embed.record#view":
            self = .record(try container.decode(EmbeddedRecord.self, forKey: .record))
        case "app.bsky.embed.recordWithMedia#view":
            self = .recordWithMedia(
                record: try container.decode(RecordBox.self, forKey: .record).record,
                media: try container.decode(Embed.self, forKey: .media)
            )
        default:
            self = .other
        }
    }
}

/// The record a quote embeds: `app.bsky.embed.record#viewRecord` for a
/// post, a post the app view can't show (removed, blocked or detached by
/// its author), or something Influx doesn't show (a feed, a list, a
/// starter pack).
enum EmbeddedRecord: Decodable, Sendable {
    /// `embeds` are the quoted post's own pictures, links and quotes.
    case post(uri: String, author: ProfileBasic, record: PostRecord, embeds: [Embed] = [])
    /// `#viewNotFound`, `#viewBlocked` or `#viewDetached`: a quoted post
    /// that is gone or hidden, of which only its URI is known.
    case unavailablePost(uri: String)
    case other

    /// The views of a quoted post the app view won't show.
    static let unavailableTypes: Set<String> = [
        "app.bsky.embed.record#viewNotFound", "app.bsky.embed.record#viewBlocked", "app.bsky.embed.record#viewDetached",
    ]

    private enum CodingKeys: String, CodingKey { case uri, author, value, embeds }

    init(from decoder: any Decoder) throws {
        let type = try TypeTag(from: decoder).type
        guard type == "app.bsky.embed.record#viewRecord" else {
            if let type, Self.unavailableTypes.contains(type),
               let uri = try? decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .uri) {
                self = .unavailablePost(uri: uri)
            } else {
                self = .other
            }
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .post(
            uri: try container.decode(String.self, forKey: .uri),
            author: try container.decode(ProfileBasic.self, forKey: .author),
            record: try container.decode(PostRecord.self, forKey: .value),
            // Pictures only decorate the quote; ones Influx can't read are dropped.
            embeds: (try? container.decodeIfPresent([Lenient<Embed>].self, forKey: .embeds))?.compactMap(\.value) ?? []
        )
    }
}

/// `app.bsky.feed.defs#generatorView`, trimmed: a custom feed's name.
struct FeedGeneratorView: Decodable, Sendable, Hashable {
    var uri: String
    var displayName: String
}

/// A saved feed from `app.bsky.actor.defs#savedFeedsPrefV2`.
struct SavedFeed: Decodable, Sendable, Hashable {
    var type: String
    var value: String
    var pinned: Bool
}

/// `app.bsky.actor.getPreferences`, reduced to saved feeds.
struct Preferences: Decodable, Sendable {
    var savedFeeds: [SavedFeed]

    private enum CodingKeys: String, CodingKey { case preferences }
    private struct Preference: Decodable {
        var type: String?
        var items: [SavedFeed]?
        enum CodingKeys: String, CodingKey { case type = "$type", items }
    }

    init(from decoder: any Decoder) throws {
        let all = try decoder.container(keyedBy: CodingKeys.self)
            .decode([Lenient<Preference>].self, forKey: .preferences)
            .compactMap(\.value)
        savedFeeds = all.first { $0.type == "app.bsky.actor.defs#savedFeedsPrefV2" }?.items ?? []
    }
}
