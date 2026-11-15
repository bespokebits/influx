import Foundation
import Observation
import InfluxKit

/// RSS subscriptions for the app: adding feeds, importing OPML, keeping
/// them fresh, and each source's quiet problem state. Fetching and writing
/// happen off the main actor in InfluxKit; only the source list and problem
/// states land here, once per change.
@MainActor
@Observable
final class Feeds {
    private(set) var sources: [Source] = []
    private(set) var states: [String: SourceFetchState] = [:]
    private(set) var isRefreshing = false

    /// Feeds that have kept failing for more than a day, oldest problem
    /// first, for the notice that names them. Every source's state counts
    /// towards telling a feed that is down from a device that is offline.
    var failing: [Source] {
        let ids = FailingSources.ids(in: Array(states.values))
        let feeds = Dictionary(uniqueKeysWithValues: sources.filter { $0.kind == .rss }.map { ($0.id, $0) })
        return ids.compactMap { feeds[$0] }
    }

    @ObservationIgnored private let store: InfluxStore
    @ObservationIgnored private let subscriptions: RSSSubscriptions
    @ObservationIgnored private let connector = RSSConnector()
    /// Sample runs show SeedFeed and never fetch on their own; only a feed
    /// the reader adds by hand reaches the network.
    @ObservationIgnored private let isSample: Bool
    @ObservationIgnored private var loop: Task<Void, Never>?
    /// When each feed is next fetched: every 15 minutes, jittered, on
    /// screen or off (`RefreshCadence`, ADR 0036).
    @ObservationIgnored let timer = RefreshTimer()
    @ObservationIgnored private var prunedAt: Date?
    @ObservationIgnored private var watching: Task<Void, Never>?
    /// The fetch under way, which overlapping calls join.
    @ObservationIgnored private var pass: Task<Void, Never>?

    init(store: InfluxStore, isSample: Bool) {
        self.store = store
        self.isSample = isSample
        subscriptions = RSSSubscriptions(store: store, connector: connector)
    }

    /// Starts watching the store, and refreshing every feed now and then
    /// each one as it falls due (`RefreshCadence`). Calling it again does
    /// nothing.
    func start() {
        guard watching == nil else { return }
        let store = store
        watching = Task { [weak self] in
            do {
                for try await states in store.observeFetchStates() {
                    // Stops watching once the app model is gone (a retry
                    // after the library failed to open makes a new one).
                    if self == nil { return }
                    let sources = (try? await store.sources()) ?? []
                    self?.update(sources: sources, states: states)
                }
            } catch {}
        }
        guard !isSample else { return }
        loop = Task { [weak self] in
            await self?.refresh()
            while !Task.isCancelled, let feeds = self {
                await feeds.refreshDue()
            }
        }
    }

    /// Waits for the next feed to fall due, then fetches every feed due.
    private func refreshDue() async {
        await timer.sleep(until: rssSources)
        let due = timer.begin(rssSources)
        guard !due.isEmpty else { return }
        let store = store, connector = connector
        isRefreshing = true
        let outcomes = (try? await Refresher(store: store).refreshAll(due, with: connector)) ?? [:]
        timer.finish(outcomes, begun: due)
        await pruneNowAndThen()
        isRefreshing = pass != nil
    }

    private var rssSources: [Source] { sources.filter { $0.kind == .rss } }

    /// Fetches every RSS subscription once. Overlapping calls (Refresh,
    /// sources arriving by sync) share one pass, and each returns when it
    /// ends.
    func refresh() async {
        guard !isSample else { return }
        if let pass { return await pass.value }
        isRefreshing = true
        let pass = Task { [weak self] in
            await self?.fetchAll()
            self?.isRefreshing = false
            self?.pass = nil
        }
        self.pass = pass
        await pass.value
    }

    private func fetchAll() async {
        let store = store, connector = connector
        let feeds = ((try? await store.sources()) ?? []).filter { $0.kind == .rss }
        let outcomes = (try? await Refresher(store: store).refreshAll(feeds, with: connector)) ?? [:]
        timer.record(outcomes)
        await pruneNowAndThen(force: true)
        await reloadSources()
    }

    /// Drops what has aged out of the retention window, at most once per
    /// RSS interval outside a full pass.
    private func pruneNowAndThen(force: Bool = false) async {
        let now = Date()
        guard force || prunedAt.map({ now.timeIntervalSince($0) >= RefreshCadence.feeds }) ?? true else { return }
        prunedAt = now
        _ = try? await store.prune()
    }

    /// Subscribes to a feed or site address; throws for the sheet to show.
    func add(_ address: String) async throws {
        let source = try await subscriptions.add(address)
        // Adding it stored its first page, so it isn't fetched again at once.
        timer.record([source.id: .fetched(newItems: 0)])
        await reloadSources()
    }

    /// Subscribes to every feed in the OPML file at `url` and returns how
    /// many were new.
    func importOPML(at url: URL) async throws -> Int {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Off the main actor: a file in iCloud Drive may have to download.
        let data = try await Task.detached { try Data(contentsOf: url) }.value
        let imported = try await subscriptions.importOPML(data)
        await reloadSources()
        return imported.count
    }

    func delete(_ source: Source) async {
        try? await store.delete(sourceID: source.id)
        await reloadSources()
    }

    private func reloadSources() async {
        setSources((try? await store.sources()) ?? sources)
    }

    private func update(sources: [Source], states: [SourceFetchState]) {
        setSources(sources)
        self.states = Dictionary(uniqueKeysWithValues: states.map { ($0.sourceID, $0) })
    }
}

extension Feeds {
    /// A new or removed feed changes what the timer waits for: a new one
    /// is fetched at once.
    fileprivate func setSources(_ sources: [Source]) {
        let ids = { (sources: [Source]) in Set(sources.lazy.filter { $0.kind == .rss }.map(\.id)) }
        let changed = ids(sources) != ids(self.sources)
        self.sources = sources
        if changed {
            timer.keep(only: ids(sources))
            timer.wake()
        }
    }
}

extension SourceProblem {
    /// The quiet line shown under a source that is having trouble.
    var message: String {
        switch self {
        case .offline: "Can't reach it right now"
        case .signedOut: "Needs signing in again"
        case .rateLimited: "Paused for a while by the service"
        case .notFound: "This feed has gone"
        case .badResponse: "Sent something Influx can't read"
        }
    }
}

extension RSSSubscriptions.Failure {
    var message: String {
        switch self {
        case .invalidURL: "That doesn't look like a web address."
        case .noFeedFound: "No feed found at that address."
        }
    }
}

/// What the add sheet says when adding a feed fails.
func addFeedMessage(for error: any Error) -> String {
    switch error {
    case let failure as RSSSubscriptions.Failure:
        failure.message
    case let failure as ConnectorError:
        switch failure {
        case .offline: "Couldn't connect. Check the address and your connection."
        case .notFound: "Nothing at that address."
        case .unauthorized: "That site needs a sign-in Influx doesn't support."
        case .rateLimited: "The site is busy. Try again in a few minutes."
        case .badResponse, .unsupported: "No feed found at that address."
        }
    default:
        "Couldn't add that feed."
    }
}
