import Foundation

/// How often each source is fetched (ADR 0036): as often as its service
/// comfortably allows while the app is on screen, and at the slow cadence
/// while it isn't, when nobody is there to see a new post arrive.
///
/// | Source                                  | On screen | Off screen |
/// | --------------------------------------- | --------- | ---------- |
/// | Sammy feed of posts (rich)              | 30 s      | 5 min      |
/// | Sammy feed of posts, change stream live | 5 min     | 5 min      |
/// | Bluesky Following, custom feeds         | 60 s      | 5 min      |
/// | Mastodon home, lists                    | 60 s      | 5 min      |
/// | Mastodon home, stream live              | 5 min     | 5 min      |
/// | Sammy feed of articles                  | 5 min     | 5 min      |
/// | RSS feed                                | 15 min    | 15 min     |
///
/// A Sammy account's post feeds share its token's allowance, so with more
/// than two of them each waits longer (`sammyPostFeedInterval`). A Mastodon
/// home timeline whose stream is live polls only every 5 minutes, as a
/// safety net (ADR 0037), and so does a Sammy post feed while its account's
/// change stream is live (ADR 0038).
public enum RefreshCadence {
    /// A Sammy feed of posts, on screen.
    public static let sammyPosts: TimeInterval = 30
    /// A Bluesky or Mastodon source, on screen.
    public static let social: TimeInterval = 60
    /// Every account's source off screen, and a Sammy article feed always.
    public static let slow: TimeInterval = 5 * 60
    /// An RSS feed, on screen or off.
    public static let feeds: TimeInterval = 15 * 60
    /// The longest a failing source waits between tries, unless its
    /// service asks for longer or its interval is longer anyway.
    public static let longestBackoff: TimeInterval = 5 * 60
    /// Each wait is stretched or shortened by up to this fraction, so the
    /// sources of one service don't all ask at the same moment.
    public static let jitter = 0.1
    /// The feed reads an hour that one Sammy token's post feeds keep under
    /// on screen: half of the 600 the server allows, leaving room for
    /// threads, article feeds and another device.
    public static let sammyReadsPerHour: TimeInterval = 300

    /// How long `source` waits between fetches. `sammyPostFeeds` is how
    /// many feeds of posts the source's Sammy account has, counting it.
    /// `streaming` says the source's stream is live.
    public static func interval(for source: Source, onScreen: Bool, sammyPostFeeds: Int = 1, streaming: Bool = false) -> TimeInterval {
        switch source.kind {
        case .mastodonHome where streaming:
            slow
        case .sammyFeed where streaming:
            // The change stream reads it as it changes; this is the safety net.
            max(slow, sammyPostFeedInterval(feeds: sammyPostFeeds))
        case .rss:
            feeds
        case .sammyFeed:
            onScreen && source.itemKind == .post ? sammyPostFeedInterval(feeds: sammyPostFeeds) : slow
        case .mastodonHome, .mastodonList, .blueskyFollowing, .blueskyFeed:
            onScreen ? social : slow
        }
    }

    /// The least time between two reads of one Sammy feed that its
    /// account's change stream asks for (ADR 0038): the account's `feeds`
    /// feeds read back to back would spend at most `sammyReadsPerHour`.
    /// The first hint after a quiet spell is read at once.
    public static func sammyChangeReadGap(feeds: Int) -> TimeInterval {
        3600 * TimeInterval(max(1, feeds)) / sammyReadsPerHour
    }

    /// Each of an account's `feeds` post feeds, on screen: every 30 s, or
    /// longer when that would spend more than `sammyReadsPerHour`.
    public static func sammyPostFeedInterval(feeds: Int) -> TimeInterval {
        max(sammyPosts, 3600 * TimeInterval(max(1, feeds)) / sammyReadsPerHour)
    }

    /// The interval of each of `sources`, by ID, counting each Sammy
    /// account's post feeds among them.
    /// `streaming` names the sources whose stream is live.
    public static func intervals(for sources: [Source], onScreen: Bool, streaming: Set<String> = []) -> [String: TimeInterval] {
        var postFeeds: [String: Int] = [:]
        for source in sources where source.kind == .sammyFeed && source.itemKind == .post {
            postFeeds[source.accountID ?? "", default: 0] += 1
        }
        var intervals: [String: TimeInterval] = [:]
        for source in sources {
            intervals[source.id] = interval(for: source, onScreen: onScreen, sammyPostFeeds: postFeeds[source.accountID ?? ""] ?? 1,
                                            streaming: streaming.contains(source.id))
        }
        return intervals
    }

    /// How long a source with this `interval` waits after `failures`
    /// failures in a row: the interval doubled for each, up to
    /// `longestBackoff`, and never less than the interval itself.
    public static func wait(interval: TimeInterval, failures: Int) -> TimeInterval {
        guard failures > 0 else { return interval }
        let doubled = interval * pow(2, TimeInterval(min(failures, 16)))
        return max(interval, min(doubled, longestBackoff))
    }
}
