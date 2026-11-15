import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A rich post's thread reference, as an item keeps it in `actionRef`
/// (`thread:<ref>`): a rich post has no actions, so the field only ever
/// holds what the connector reads the post's thread with. A post without
/// one has no thread to open (ADR 0031).
struct SammyThreadRef: Sendable, Hashable {
    static let prefix = "thread:"

    /// `[A-Za-z0-9_-]{1,256}`, opaque: never built or changed here.
    let ref: String

    init(ref: String) {
        self.ref = ref
    }

    /// The reference `actionRef` holds; nil for anything else.
    init?(actionRef: String?) {
        guard let actionRef, actionRef.hasPrefix(Self.prefix) else { return nil }
        let ref = String(actionRef.dropFirst(Self.prefix.count))
        guard RichFeedPage.isThreadRef(ref) else { return nil }
        self.ref = ref
    }

    var actionRef: String { Self.prefix + ref }
}

/// One post's thread, as the thread route answers it
/// (`format: "sammy.rich-thread"`, version 1): the posts it replies to, the
/// post, its author's own posts that continue it, and what the source
/// knows is missing. Read on demand and never stored.
struct RichThread: Sendable, Hashable {
    static let format = "sammy.rich-thread"
    static let version = 1
    /// The weak `ETag` prefix of a thread, its proof of format on a 304.
    static let etagPrefix = "W/\"rich-thread-v1-"
    static let maxAncestors = 50
    static let maxContinuations = 100

    var ref: String
    /// Oldest first, none later than the focus.
    var ancestors: [RichFeedPage.Post]
    var focus: RichFeedPage.Post
    /// Oldest first, none earlier than the focus.
    var continuations: [RichFeedPage.Post]
    var gaps: [PostThread.Gap]

    /// The thread in `data`, asked for as `ref` on the post `focusID`.
    /// Unlike a page, a thread that breaks any rule is refused whole: the
    /// server answers 502 for one that does, so one that arrives comes
    /// from a broken server, and refusing costs only the thread view,
    /// while dropping a post would show an incomplete thread as whole.
    /// Throws `.badResponse` for a body of another format or version,
    /// another thread or another focus; a post that breaks a page's rules;
    /// a context post naming a thread, or a focus naming another; more
    /// than `maxAncestors` or `maxContinuations`; a repeated post; posts
    /// out of order or on the wrong side of the focus; or a gap of a
    /// position the contract doesn't have.
    static func decode(_ data: Data, ref: String, focusID: String) throws -> RichThread {
        let raw: Raw
        do {
            raw = try JSONDecoder().decode(Raw.self, from: data)
        } catch {
            throw ConnectorError.badResponse("not a rich thread")
        }
        guard raw.format == format, raw.version == version else {
            throw ConnectorError.badResponse("a rich thread of another format or version")
        }
        guard raw.ref == ref else { throw ConnectorError.badResponse("another thread") }
        guard raw.ancestors.count <= maxAncestors, raw.continuations.count <= maxContinuations else {
            throw ConnectorError.badResponse("a thread past its bounds")
        }
        guard let focus = raw.focus.post, focus.id == focusID, focus.threadRef == nil || focus.threadRef == ref else {
            throw ConnectorError.badResponse("a thread about another post")
        }
        let ancestors = raw.ancestors.compactMap(\.post), continuations = raw.continuations.compactMap(\.post)
        guard ancestors.count == raw.ancestors.count, continuations.count == raw.continuations.count,
              (ancestors + continuations).allSatisfy({ $0.threadRef == nil }) else {
            throw ConnectorError.badResponse("a thread with a post that breaks the contract")
        }
        let all = ancestors + [focus] + continuations
        guard Set(all.map(\.id)).count == all.count else { throw ConnectorError.badResponse("a thread that repeats a post") }
        // Oldest first throughout, the focus between its context.
        guard zip(all, all.dropFirst()).allSatisfy({ $0.publishedAt <= $1.publishedAt }) else {
            throw ConnectorError.badResponse("a thread out of order")
        }
        var gaps: [PostThread.Gap] = []
        for gap in raw.gaps ?? [] {
            let position: PostThread.Gap.Position
            switch gap.position {
            case "ancestors": position = .ancestors
            case "continuations": position = .replies
            default: throw ConnectorError.badResponse("a gap of an unknown position")
            }
            let reason: PostThread.Gap.Reason = switch gap.reason {
            case "deleted": .deleted
            case "unavailable": .unavailable
            case "not-collected": .notCollected
            default: .other
            }
            let found = PostThread.Gap(position: position, reason: reason)
            if !gaps.contains(found) { gaps.append(found) }
        }
        return RichThread(ref: ref, ancestors: ancestors, focus: focus, continuations: continuations, gaps: gaps)
    }

    private struct Raw: Decodable {
        struct Gap: Decodable {
            var position: String
            var reason: String
        }

        var format: String
        var version: Int
        var ref: String
        var ancestors: [RichFeedPage.RawPost]
        var focus: RichFeedPage.RawPost
        var continuations: [RichFeedPage.RawPost]
        var gaps: [Gap]?
    }

    /// The thread as a thread view shows it, its posts named after
    /// `source` so they act, and open, through the same connector. The
    /// continuations follow the post as its replies, each one level in:
    /// the contract says they continue it, not which one answers which.
    /// Every post's media, and its quote's, is granted by the thread.
    func postThread(feedID: String, source: Source, fetchedAt: Date) -> PostThread {
        let item = { (post: RichFeedPage.Post) in
            RichFeedMapper.item(from: post, feedID: feedID, source: source, fetchedAt: fetchedAt, thread: ref)
        }
        return PostThread(
            ancestors: ancestors.map(item), post: item(focus),
            replies: continuations.map { PostThread.Reply(item: item($0), depth: 1) }, gaps: gaps
        )
    }
}

/// The threads one account's connector has read, kept in memory only, with
/// the validator each came with, so opening a thread again costs a 304
/// while it is unchanged. Bounded, the oldest read going first; nothing is
/// written to the store, and a relaunch starts empty.
actor SammyThreads {
    static let limit = 16

    struct Key: Hashable {
        var feedID: String
        var ref: String
    }

    struct Kept: Sendable {
        var etag: String
        var thread: RichThread
    }

    private var kept: [Key: Kept] = [:]
    private var order: [Key] = []

    func kept(_ key: Key) -> Kept? {
        kept[key]
    }

    func keep(_ thread: RichThread, etag: String?, for key: Key) {
        order.removeAll { $0 == key }
        guard let etag else {
            kept[key] = nil
            return
        }
        kept[key] = Kept(etag: etag, thread: thread)
        order.append(key)
        while order.count > Self.limit { kept[order.removeFirst()] = nil }
    }

    func forget(_ key: Key) {
        kept[key] = nil
        order.removeAll { $0 == key }
    }
}
