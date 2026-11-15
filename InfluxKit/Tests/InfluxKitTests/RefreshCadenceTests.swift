import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private let rss = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 1)
private let mastodonHome = MastodonMapper.homeSource(accountID: "@me@example.social", colorIndex: 2)
private let mastodonList = Source(id: "mastodon:@me@example.social:list:1", kind: .mastodonList, accountID: "@me@example.social", title: "Friends", colorIndex: 3)
private let following = Source(id: "bluesky:did:plc:me:following", kind: .blueskyFollowing, accountID: "did:plc:me", title: "Following", colorIndex: 4)
private let customFeed = Source(id: "bluesky:did:plc:me:feed", kind: .blueskyFeed, accountID: "did:plc:me", title: "Feed", colorIndex: 5)

private func sammy(_ id: String, _ kind: Item.Kind?, account: String = "1@example.com") -> Source {
    Source(id: "sammy:\(account):\(id)", kind: .sammyFeed, accountID: account, title: id, url: "https://example.com/\(id)", colorIndex: 6, itemKind: kind)
}

@Suite struct RefreshCadencePolicy {
    @Test(arguments: [
        (rss, 900.0, 900.0),
        (mastodonHome, 60, 300),
        (mastodonList, 60, 300),
        (following, 60, 300),
        (customFeed, 60, 300),
        (sammy("posts", .post), 30, 300),
        (sammy("articles", .article), 300, 300),
        (sammy("unclassified", nil), 300, 300),
    ])
    func eachSourceHasItsIntervalOnAndOffScreen(source: Source, onScreen: TimeInterval, offScreen: TimeInterval) {
        #expect(RefreshCadence.interval(for: source, onScreen: true) == onScreen)
        #expect(RefreshCadence.interval(for: source, onScreen: false) == offScreen)
    }

    @Test func aSammyAccountsPostFeedsStayWithinItsAllowance() {
        // One or two feeds every 30 s; more share 300 reads an hour.
        #expect(RefreshCadence.sammyPostFeedInterval(feeds: 1) == 30)
        #expect(RefreshCadence.sammyPostFeedInterval(feeds: 2) == 30)
        #expect(RefreshCadence.sammyPostFeedInterval(feeds: 3) == 36)
        #expect(RefreshCadence.sammyPostFeedInterval(feeds: 5) == 60)
        let feeds = (1...5).map { sammy("p\($0)", .post) } + [sammy("a", .article), sammy("other", .post, account: "2@example.com")]
        let intervals = RefreshCadence.intervals(for: feeds, onScreen: true)
        #expect(feeds.prefix(5).allSatisfy { intervals[$0.id] == 60 })
        #expect(intervals[feeds[5].id] == 300)
        #expect(intervals[feeds[6].id] == 30)
        let readsPerHour = feeds.prefix(5).reduce(0) { $0 + 3600 / intervals[$1.id]! }
        #expect(readsPerHour <= RefreshCadence.sammyReadsPerHour)
        // Off screen, they are all slow.
        #expect(RefreshCadence.intervals(for: feeds, onScreen: false).values.allSatisfy { $0 == 300 })
    }

    @Test func aLiveStreamSlowsOnlyTheMastodonHomeTimelineToASafetyPoll() {
        let streaming: Set<String> = [mastodonHome.id]
        let intervals = RefreshCadence.intervals(for: [mastodonHome, mastodonList, following], onScreen: true, streaming: streaming)
        #expect(intervals == [mastodonHome.id: 300, mastodonList.id: 60, following.id: 60])
        // When it drops, the home timeline polls every minute again.
        #expect(RefreshCadence.intervals(for: [mastodonHome], onScreen: true)[mastodonHome.id] == 60)
        var schedule = RefreshSchedule(jitter: { 1 })
        schedule.finish(mastodonHome.id, .fetched(newItems: 0), at: t0)
        #expect(schedule.nextDue([mastodonHome], onScreen: true, streaming: streaming, after: t0) == t0 + 300)
        #expect(schedule.nextDue([mastodonHome], onScreen: true, after: t0) == t0 + 60)
    }

    @Test func aLiveChangeStreamSlowsSammyPostFeedsToASafetyPoll() {
        let posts = sammy("posts", .post), more = sammy("more", .post), articles = sammy("articles", .article)
        let streaming: Set<String> = [posts.id, more.id]
        let intervals = RefreshCadence.intervals(for: [posts, more, articles], onScreen: true, streaming: streaming)
        #expect(intervals == [posts.id: 300, more.id: 300, articles.id: 300])
        // When it drops, back to every 30 seconds.
        #expect(RefreshCadence.intervals(for: [posts, more], onScreen: true)[posts.id] == 30)
        // So many feeds that the allowance stretches them past it: that wins.
        let many = (0..<30).map { sammy("p\($0)", .post) }
        #expect(RefreshCadence.intervals(for: many, onScreen: true, streaming: Set(many.map(\.id)))[many[0].id] == 360)
        // Reads the stream asks for keep an account within the same allowance.
        #expect(RefreshCadence.sammyChangeReadGap(feeds: 1) == 12)
        #expect(RefreshCadence.sammyChangeReadGap(feeds: 3) == 36)
        #expect(RefreshCadence.sammyChangeReadGap(feeds: 0) == 12)
    }

    @Test func failuresDoubleTheWaitUpToFiveMinutes() {
        #expect((0...6).map { RefreshCadence.wait(interval: 30, failures: $0) } == [30, 60, 120, 240, 300, 300, 300])
        #expect((0...3).map { RefreshCadence.wait(interval: 60, failures: $0) } == [60, 120, 240, 300])
        // A source slower than the cap is never fetched more often for failing.
        #expect((0...3).map { RefreshCadence.wait(interval: 900, failures: $0) } == [900, 900, 900, 900])
        #expect(RefreshCadence.wait(interval: 30, failures: 10_000) == 300)
    }

    @Test func theDefaultJitterStaysWithinTenPercent() {
        for _ in 0..<1_000 {
            let factor = RefreshSchedule.randomJitter()
            #expect(factor >= 0.9 && factor <= 1.1)
        }
    }
}

@Suite struct RefreshScheduling {
    private let posts = sammy("posts", .post)

    @Test func aSourceNeverFetchedIsDueAtOnce() {
        var schedule = RefreshSchedule(jitter: { 1 })
        #expect(schedule.begin([posts, rss], onScreen: true, at: t0).map(\.id) == [posts.id, rss.id])
    }

    @Test func aSourceIsDueOnceItsJitteredIntervalHasPassed() {
        var schedule = RefreshSchedule(jitter: { 1.1 })
        schedule.finish(posts.id, .fetched(newItems: 1), at: t0)
        #expect(schedule.dueAt(posts.id, interval: 30) == t0 + 33)
        #expect(schedule.begin([posts], onScreen: true, at: t0 + 32).isEmpty)
        #expect(schedule.begin([posts], onScreen: true, at: t0 + 33) == [posts])
    }

    @Test func aSourceBeingFetchedIsNeverBegunAgain() {
        var schedule = RefreshSchedule(jitter: { 1 })
        #expect(schedule.begin([posts], onScreen: true, at: t0) == [posts])
        #expect(schedule.isFetching(posts.id))
        // However long the fetch takes, it isn't started twice.
        #expect(schedule.begin([posts], onScreen: true, at: t0 + 600).isEmpty)
        #expect(schedule.nextDue([posts], onScreen: true, after: t0 + 600) == nil)
        schedule.finish(posts.id, .fetched(newItems: 0), at: t0 + 601)
        #expect(!schedule.isFetching(posts.id))
        #expect(schedule.nextDue([posts], onScreen: true, after: t0 + 601) == t0 + 631)
    }

    @Test func anotherPassHoldingTheSourceDoesNotMakeItDueAgainAtOnce() {
        var schedule = RefreshSchedule(jitter: { 1 })
        _ = schedule.begin([posts], onScreen: true, at: t0)
        schedule.finish(posts.id, .alreadyRefreshing, at: t0)
        #expect(schedule.dueAt(posts.id, interval: 30) == t0 + 30)
    }

    @Test func failuresBackOffAndASuccessRecovers() {
        var schedule = RefreshSchedule(jitter: { 1 })
        var now = t0
        var waits: [TimeInterval] = []
        for _ in 0..<5 {
            schedule.finish(posts.id, .failed(.offline), at: now)
            let due = schedule.dueAt(posts.id, interval: 30)!
            waits.append(due.timeIntervalSince(now))
            now = due
        }
        #expect(waits == [60, 120, 240, 300, 300])
        #expect(schedule.failures(of: posts.id) == 5)
        schedule.finish(posts.id, .fetched(newItems: 2), at: now)
        #expect(schedule.failures(of: posts.id) == 0)
        #expect(schedule.dueAt(posts.id, interval: 30) == now + 30)
    }

    @Test func aRateLimitWaitsForTheServicesRetryAfter() {
        var schedule = RefreshSchedule(jitter: { 1 })
        schedule.finish(posts.id, .failed(.rateLimited(retryAfter: t0 + 900)), at: t0)
        #expect(schedule.dueAt(posts.id, interval: 30) == t0 + 900)
        // Without one, the store's pause.
        schedule.finish(mastodonHome.id, .failed(.rateLimited(retryAfter: nil)), at: t0)
        #expect(schedule.dueAt(mastodonHome.id, interval: 60) == t0 + SourceFetchState.defaultRateLimitPause)
        // A refresh that found the source still waiting keeps the pause.
        schedule.finish(following.id, .waiting(until: t0 + 400), at: t0)
        #expect(schedule.dueAt(following.id, interval: 60) == t0 + 400)
    }

    @Test func comingOnScreenMakesEverySourceOlderThanItsFastIntervalDue() {
        var schedule = RefreshSchedule(jitter: { 1 })
        let sources = [posts, mastodonHome, following, sammy("articles", .article), rss]
        schedule.finish(Dictionary(uniqueKeysWithValues: sources.map { ($0.id, Refresher.Outcome.fetched(newItems: 0)) }), at: t0)
        // Off screen for 90 s: nothing is due yet; the next wake is the slow cadence.
        #expect(schedule.begin(sources, onScreen: false, at: t0 + 90).isEmpty)
        #expect(schedule.nextDue(sources, onScreen: false, after: t0 + 90) == t0 + 300)
        // On screen: the 30 s and 60 s sources at once; articles and RSS keep their time.
        #expect(Set(schedule.begin(sources, onScreen: true, at: t0 + 90).map(\.id)) == [posts.id, mastodonHome.id, following.id])
        for source in [posts, mastodonHome, following] {
            schedule.finish(source.id, .fetched(newItems: 0), at: t0 + 91)
        }
        #expect(schedule.nextDue(sources, onScreen: true, after: t0 + 91) == t0 + 121)
        // Off screen again: the fast sources go back to five minutes.
        #expect(schedule.nextDue(sources, onScreen: false, after: t0 + 91) == t0 + 300)
        #expect(schedule.dueAt(posts.id, interval: RefreshCadence.interval(for: posts, onScreen: false)) == t0 + 391)
    }

    @Test func aLeadTakesAlongASourceDueAMomentLater() {
        var schedule = RefreshSchedule(jitter: { 1 })
        schedule.finish(posts.id, .fetched(newItems: 0), at: t0)
        schedule.finish(mastodonHome.id, .fetched(newItems: 0), at: t0 - 28)
        #expect(schedule.begin([posts, mastodonHome], onScreen: true, at: t0 + 30, lead: 5).map(\.id) == [posts.id, mastodonHome.id])
    }

    @Test func forgottenSourcesLeaveTheSchedule() {
        var schedule = RefreshSchedule(jitter: { 1 })
        schedule.finish(posts.id, .failed(.offline), at: t0)
        _ = schedule.begin([rss], onScreen: true, at: t0)
        schedule.keep(only: [])
        #expect(schedule.failures(of: posts.id) == 0)
        #expect(!schedule.isFetching(rss.id))
    }
}

/// Unchanged answers through the real connectors and store, with HTTP faked.
@Suite struct UnchangedAnswers {
    private let feed = """
        <?xml version="1.0"?><rss version="2.0"><channel><title>Example</title><link>https://example.com/</link>
        <item><title>One</title><link>https://example.com/1</link><guid>https://example.com/1</guid><pubDate>Mon, 26 Oct 2026 08:00:00 GMT</pubDate></item>
        </channel></rss>
        """

    private func changes(_ store: InfluxStore) async throws -> Int {
        try await store.writer.read { $0.totalChangesCount }
    }

    @Test func a304WritesNothingAndWakesNoObserver() async throws {
        let client = FakeHTTPClient { [feed] request in
            if request.value(forHTTPHeaderField: "If-None-Match") == "\"v1\"" { return .init(status: 304) }
            return .init(headers: ["ETag": "\"v1\""], text: feed)
        }
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss])
        let refresher = Refresher(store: store)
        let connector = RSSConnector(client: client)
        #expect(try await refresher.refresh(rss, with: connector, now: t0) == .fetched(newItems: 1))
        let state = try await store.fetchState(sourceID: rss.id)
        let observed = Observed(store)
        try await observed.settle()
        let before = try await changes(store)

        #expect(try await refresher.refresh(rss, with: connector, now: t0 + 30) == .fetched(newItems: 0))
        #expect(try await refresher.refresh(rss, with: connector, now: t0 + 60) == .fetched(newItems: 0))
        #expect(try await changes(store) == before)
        #expect(try await store.fetchState(sourceID: rss.id) == state)
        try await observed.settle()
        #expect(observed.counts == Observed.Counts(rows: 1, states: 1))

        // An hour on, the success is dated again, so the notice for failing
        // sources still sees this one fetching.
        #expect(try await refresher.refresh(rss, with: connector, now: t0 + 3600) == .fetched(newItems: 0))
        #expect(try await store.fetchState(sourceID: rss.id)?.lastSuccessAt == t0 + 3600)
        try await observed.settle()
        #expect(observed.counts == Observed.Counts(rows: 1, states: 2))
    }

    @Test func anEmptyMastodonPageWritesNothing() async throws {
        let page = try Data(contentsOf: try #require(Bundle.module.url(forResource: "home-timeline", withExtension: "json", subdirectory: "Fixtures/mastodon")))
        let http = FakeHTTPClient { request in
            guard request.url!.path() == "/api/v1/timelines/home" else { return .init(status: 404) }
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return query.contains { $0.name == "min_id" || $0.name == "since_id" } ? .init(text: "[]") : .init(body: page)
        }
        let connector = MastodonConnector(accountID: "@me@example.social", instance: URL(string: "https://example.social")!,
                                          accessToken: "t", colorIndex: 2, http: http, resolver: .testing(http))
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [mastodonHome])
        let refresher = Refresher(store: store)
        guard case .fetched(let first) = try await refresher.refresh(mastodonHome, with: connector, now: t0), first > 0 else {
            Issue.record("the first page stored nothing")
            return
        }
        let before = try await changes(store)
        #expect(try await refresher.refresh(mastodonHome, with: connector, now: t0 + 60) == .fetched(newItems: 0))
        #expect(try await changes(store) == before)
    }

    @Test func aRateLimitIsHonouredWithoutAskingAgain() async throws {
        let client = FakeHTTPClient { _ in .init(status: 429, headers: ["Retry-After": "120"]) }
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss])
        let refresher = Refresher(store: store)
        let connector = RSSConnector(client: client)
        var schedule = RefreshSchedule(jitter: { 1 })
        let outcome = try await refresher.refresh(rss, with: connector, now: t0)
        #expect(outcome == .failed(.rateLimited(retryAfter: t0 + 120)))
        schedule.finish(rss.id, outcome, at: t0)
        // RSS waits its own 15 minutes, longer than the service asked.
        #expect(schedule.dueAt(rss.id, interval: 900) == t0 + 900)
        #expect(try await refresher.refresh(rss, with: connector, now: t0 + 60) == .waiting(until: t0 + 120))
        #expect(client.requests.count == 1)
    }
    // Two refreshes of one source: `Refresher` refuses the second
    // (`ConnectorTests`), and the schedule never begins it (above).
}

/// Counts what the timeline's and the sources' observations deliver.
private final class Observed: @unchecked Sendable {
    struct Counts: Hashable {
        var rows = 0
        var states = 0
    }

    private let lock = NSLock()
    private var _counts = Counts()
    private var tasks: [Task<Void, Never>] = []
    private let store: InfluxStore

    var counts: Counts { lock.withLock { _counts } }

    init(_ store: InfluxStore) {
        self.store = store
        let rows = store.observeRows(), states = store.observeFetchStates()
        tasks = [
            Task { [weak self] in
                do { for try await _ in rows { self?.count(\.rows) } } catch {}
            },
            Task { [weak self] in
                do { for try await _ in states { self?.count(\.states) } } catch {}
            },
        ]
    }

    deinit { tasks.forEach { $0.cancel() } }

    private func count(_ key: WritableKeyPath<Counts, Int>) {
        lock.withLock { _counts[keyPath: key] += 1 }
    }

    /// Gives the observations time to deliver what the writes so far changed.
    func settle() async throws {
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(100))
    }
}
