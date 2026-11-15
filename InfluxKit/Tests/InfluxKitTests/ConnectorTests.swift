import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
private let day: TimeInterval = 24 * 60 * 60

private let home = Source(id: "test:home", kind: .mastodonHome, accountID: "test", title: "Home", colorIndex: 1)
private let feed = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 3)

private func post(_ remoteID: String, in source: Source = home, at date: Date) -> Item {
    Item(
        sourceID: source.id, remoteID: remoteID, kind: source.kind == .rss ? .article : .post, mergeKey: "post:\(remoteID)",
        authorName: "Ana Ruiz", authorHandle: "@ana", body: "Post \(remoteID)", publishedAt: date, fetchedAt: t0
    )
}

/// A connector that answers each fetch with the next scripted result and
/// keeps the requests it was given.
private final class ScriptedConnector: Connector, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<FetchedPage, any Error>]
    private var _requests: [FetchRequest] = []

    var requests: [FetchRequest] { lock.withLock { _requests } }

    init(_ results: [Result<FetchedPage, any Error>]) {
        self.results = results
    }

    func handles(_ source: Source) -> Bool { true }

    func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage {
        let result = lock.withLock {
            _requests.append(request)
            return results.removeFirst()
        }
        return try result.get()
    }
}

private func store() async throws -> InfluxStore {
    let store = try InfluxStore.inMemory()
    try await store.save(sources: [home, feed])
    return store
}

@Suite struct Refreshing {
    @Test func firstFetchAsksForTheNewestPageAndStoresIt() async throws {
        let store = try await store()
        let connector = ScriptedConnector([.success(FetchedPage(items: [post("1", at: t0), post("2", at: t0)], newer: Cursor(rawValue: "2"), older: Cursor(rawValue: "1")))])
        let outcome = try await Refresher(store: store).refresh(home, with: connector, now: t0)
        #expect(outcome == .fetched(newItems: 2))
        #expect(connector.requests.first?.cursor == nil)
        #expect(connector.requests.first?.direction == .newer)
        let state = try #require(try await store.fetchState(sourceID: home.id))
        #expect(state.newerCursor == Cursor(rawValue: "2"))
        #expect(state.olderCursor == Cursor(rawValue: "1"))
        #expect(state.reachedOldest == false)
        #expect(state.lastSuccessAt == t0)
        #expect(state.problem == nil)
        #expect(try await store.rows().count == 2)
    }

    @Test func signingInAgainClearsOnlyTheSignedOutState() async throws {
        let store = try await store()
        let refresher = Refresher(store: store)
        _ = try? await refresher.refresh(home, with: ScriptedConnector([.success(FetchedPage(items: [post("1", at: t0)], newer: Cursor(rawValue: "1"), older: nil))]), now: t0)
        _ = try? await refresher.refresh(home, with: ScriptedConnector([.failure(ConnectorError.unauthorized)]), now: t0.addingTimeInterval(60))
        _ = try? await refresher.refresh(feed, with: ScriptedConnector([.failure(ConnectorError.offline)]), now: t0)
        try await store.clearSignedOut(sourceIDs: [home.id, feed.id])
        let state = try #require(try await store.fetchState(sourceID: home.id))
        #expect(state.problem == nil)
        #expect(state.problemSince == nil)
        // The cursor stays, so the next fetch fills the gap.
        #expect(state.newerCursor == Cursor(rawValue: "1"))
        #expect(try await store.fetchState(sourceID: feed.id)?.problem == .offline)
    }

    @Test func laterFetchesContinueFromTheStoredCursors() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [post("5", at: t0)], newer: Cursor(rawValue: "5"), older: Cursor(rawValue: "5"))),
            .success(FetchedPage(items: [post("6", at: t0)], newer: Cursor(rawValue: "6"), older: Cursor(rawValue: "6"))),
            .success(FetchedPage(items: [post("4", at: t0)], newer: nil, older: nil)),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        _ = try await refresher.refresh(home, with: connector, direction: .older, now: t0)
        #expect(connector.requests.map(\.cursor) == [nil, Cursor(rawValue: "5"), Cursor(rawValue: "5")])
        let state = try #require(try await store.fetchState(sourceID: home.id))
        // Newer pages never move the older cursor after the first fetch.
        #expect(state.newerCursor == Cursor(rawValue: "6"))
        #expect(state.olderCursor == nil)
        #expect(state.reachedOldest)
        #expect(try await refresher.refresh(home, with: connector, direction: .older, now: t0) == .reachedOldest)
    }

    @Test func aSourceThatStartsEmptyCanStillBePagedBack() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [], newer: nil, older: nil)),
            .success(FetchedPage(items: [post("9", at: t0)], newer: Cursor(rawValue: "9"), older: Cursor(rawValue: "8"))),
            .success(FetchedPage(items: [post("10", at: t0)], newer: Cursor(rawValue: "10"), older: Cursor(rawValue: "10"))),
            .success(FetchedPage(items: [post("8", at: t0)], newer: nil, older: nil)),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        #expect(try await store.fetchState(sourceID: home.id)?.reachedOldest == true)
        _ = try await refresher.refresh(home, with: connector, now: t0 + 60)
        _ = try await refresher.refresh(home, with: connector, now: t0 + 120)
        var state = try #require(try await store.fetchState(sourceID: home.id))
        // The first page with items set where paging back starts; later
        // ones don't move it.
        #expect(state.olderCursor == Cursor(rawValue: "8"))
        #expect(state.reachedOldest == false)
        #expect(try await refresher.refresh(home, with: connector, direction: .older, now: t0 + 180) == .fetched(newItems: 1))
        #expect(connector.requests.last?.cursor == Cursor(rawValue: "8"))
        state = try #require(try await store.fetchState(sourceID: home.id))
        #expect(state.reachedOldest)
    }

    @Test func itemsPastTheRetentionWindowAreDropped() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [post("old", at: t0 - 8 * day), post("new", at: t0 - 6 * day)], newer: nil, older: nil)),
            .success(FetchedPage(items: [post("a", in: feed, at: t0 - 31 * day), post("b", in: feed, at: t0 - 29 * day)], newer: nil, older: nil)),
        ])
        let refresher = Refresher(store: store)
        #expect(try await refresher.refresh(home, with: connector, now: t0) == .fetched(newItems: 1))
        #expect(try await refresher.refresh(feed, with: connector, now: t0) == .fetched(newItems: 1))
        #expect(connector.requests.map(\.notBefore) == [t0 - 7 * day, t0 - 30 * day])
        #expect(Set(try await store.rows().map(\.body)) == ["Post new", "Post b"])
    }

    @Test func failuresShowOnTheSourceAndKeepTheCursor() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [], newer: Cursor(rawValue: "1"), older: nil)),
            .failure(ConnectorError.offline),
            .failure(ConnectorError.offline),
            .failure(ConnectorError.badResponse("HTTP 500")),
            .success(FetchedPage(items: [], newer: Cursor(rawValue: "2"), older: nil)),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        #expect(try await refresher.refresh(home, with: connector, now: t0 + 60) == .failed(.offline))
        _ = try await refresher.refresh(home, with: connector, now: t0 + 120)
        var state = try #require(try await store.fetchState(sourceID: home.id))
        #expect(state.problem == .offline)
        // Repeats of the same problem keep when it started.
        #expect(state.problemSince == t0 + 60)
        #expect(state.newerCursor == Cursor(rawValue: "1"))
        #expect(state.lastSuccessAt == t0)

        _ = try await refresher.refresh(home, with: connector, now: t0 + 180)
        state = try #require(try await store.fetchState(sourceID: home.id))
        #expect(state.problem == .badResponse)
        #expect(state.problemDetail == "HTTP 500")
        #expect(state.problemSince == t0 + 180)

        _ = try await refresher.refresh(home, with: connector, now: t0 + 240)
        state = try #require(try await store.fetchState(sourceID: home.id))
        #expect(state.problem == nil)
        #expect(state.problemSince == nil)
        #expect(state.newerCursor == Cursor(rawValue: "2"))
        #expect(connector.requests.map(\.cursor) == [nil, Cursor(rawValue: "1"), Cursor(rawValue: "1"), Cursor(rawValue: "1"), Cursor(rawValue: "1")])
    }

    @Test func rateLimitsPauseTheSource() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .failure(ConnectorError.rateLimited(retryAfter: t0 + 900)),
            .failure(ConnectorError.rateLimited(retryAfter: nil)),
        ])
        let refresher = Refresher(store: store)
        #expect(try await refresher.refresh(home, with: connector, now: t0) == .failed(.rateLimited(retryAfter: t0 + 900)))
        #expect(try await refresher.refresh(home, with: connector, now: t0 + 60) == .waiting(until: t0 + 900))
        #expect(connector.requests.count == 1)
        _ = try await refresher.refresh(home, with: connector, now: t0 + 900)
        let state = try #require(try await store.fetchState(sourceID: home.id))
        #expect(state.problem == .rateLimited)
        #expect(state.retryAfter == t0 + 900 + SourceFetchState.defaultRateLimitPause)
    }

    @Test func otherErrorsAreBadResponsesAndCancellationIsNotAProblem() async throws {
        struct Garbled: Error {}
        let store = try await store()
        let connector = ScriptedConnector([.failure(CancellationError()), .failure(Garbled())])
        let refresher = Refresher(store: store)
        #expect(try await refresher.refresh(home, with: connector, now: t0) == .cancelled)
        #expect(try await store.fetchState(sourceID: home.id) == nil)
        guard case .failed(.badResponse) = try await refresher.refresh(home, with: connector, now: t0) else {
            Issue.record("expected a bad response")
            return
        }
    }

    @Test func aPageThatArrivesAfterCancellationIsNotStored() async throws {
        /// Cancels its own task mid-fetch, then returns a page anyway.
        struct CancellingConnector: Connector {
            func handles(_ source: Source) -> Bool { true }
            func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage {
                withUnsafeCurrentTask { $0?.cancel() }
                return FetchedPage(items: [post("1", at: t0)], newer: Cursor(rawValue: "1"), older: nil)
            }
        }
        let store = try await store()
        let refresher = Refresher(store: store)
        #expect(try await Task { try await refresher.refresh(home, with: CancellingConnector(), now: t0) }.value == .cancelled)
        #expect(try await store.fetchState(sourceID: home.id) == nil)
        #expect(try await store.rows().isEmpty)
    }

    @Test func aRefreshCancelledBeforeItStartsIsCancelled() async throws {
        let store = try await store()
        let connector = ScriptedConnector([])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await Refresher(store: store).refresh(home, with: connector, now: t0)
        }
        #expect(try await task.value == .cancelled)
        #expect(connector.requests.isEmpty)
    }

    @Test func overlappingRefreshesOfOneSourceRunOnce() async throws {
        /// Holds its fetch open until released, so a second refresh starts
        /// while the first is in flight.
        final class GatedConnector: Connector, @unchecked Sendable {
            let started: AsyncStream<Void>
            private let startedContinuation: AsyncStream<Void>.Continuation
            private let lock = NSLock()
            private var release: CheckedContinuation<Void, Never>?
            private var fetches = 0

            init() {
                (started, startedContinuation) = AsyncStream.makeStream()
            }

            var fetchCount: Int { lock.withLock { fetches } }

            func handles(_ source: Source) -> Bool { true }

            func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage {
                await withCheckedContinuation { continuation in
                    lock.withLock {
                        fetches += 1
                        release = continuation
                    }
                    startedContinuation.yield()
                }
                return FetchedPage(items: [post("1", at: t0)], newer: Cursor(rawValue: "slow"), older: nil)
            }

            func open() {
                lock.withLock { release }?.resume()
            }
        }
        let store = try await store()
        let connector = GatedConnector()
        let first = Task { try await Refresher(store: store).refresh(home, with: connector, now: t0) }
        var started = connector.started.makeAsyncIterator()
        await started.next()
        // A second Refresher on the same store still sees the first.
        #expect(try await Refresher(store: store).refresh(home, with: connector, now: t0 + 60) == .alreadyRefreshing)
        #expect(try await Refresher(store: store).record(FetchedPage(items: [], newer: Cursor(rawValue: "other"), older: nil), for: home, request: Refresher.request(for: home, direction: .newer, cursor: nil, now: t0)) == 0)
        connector.open()
        #expect(try await first.value == .fetched(newItems: 1))
        #expect(connector.fetchCount == 1)
        #expect(try await store.fetchState(sourceID: home.id)?.newerCursor == Cursor(rawValue: "slow"))
        // Once it finishes, the source can be refreshed again.
        #expect(try await Refresher(store: store).refresh(home, with: ScriptedConnector([.success(FetchedPage(items: [], newer: Cursor(rawValue: "next"), older: nil))]), now: t0 + 120) == .fetched(newItems: 0))
    }

    @Test func pagesFetchedBeforeTheCursorMovedAreStale() async throws {
        let store = try await store()
        let refresher = Refresher(store: store)
        // A page fetched from the start, held while a refresh moves on.
        let staleRequest = Refresher.request(for: home, direction: .newer, cursor: nil, now: t0)
        let connector = ScriptedConnector([.success(FetchedPage(items: [post("2", at: t0)], newer: Cursor(rawValue: "2"), older: nil))])
        _ = try await refresher.refresh(home, with: connector, now: t0 + 60)
        let stale = FetchedPage(items: [post("1", at: t0)], newer: Cursor(rawValue: "1"), older: nil)
        #expect(try await refresher.record(stale, for: home, request: staleRequest) == 0)
        #expect(try await store.fetchState(sourceID: home.id)?.newerCursor == Cursor(rawValue: "2"))
        #expect(try await store.rows().map(\.body) == ["Post 2"])
        // A page from the current cursor still lands.
        let current = Refresher.request(for: home, direction: .newer, cursor: Cursor(rawValue: "2"), now: t0 + 120)
        #expect(try await refresher.record(FetchedPage(items: [post("3", at: t0)], newer: Cursor(rawValue: "3"), older: nil), for: home, request: current) == 1)
        #expect(try await store.fetchState(sourceID: home.id)?.newerCursor == Cursor(rawValue: "3"))
    }

    @Test func pagesForADeletedSourceAreDropped() async throws {
        let store = try await store()
        try await store.delete(sourceID: home.id)
        let inserted = try await store.record(FetchedPage(items: [post("1", at: t0)], newer: nil, older: nil), for: Refresher.request(for: home, direction: .newer, cursor: nil, now: t0), sourceID: home.id)
        #expect(inserted == 0)
        try await store.recordFailure(.offline, sourceID: home.id, at: t0)
        #expect(try await store.fetchState(sourceID: home.id) == nil)
    }

    @Test func deletingASourceForgetsItsFetchState() async throws {
        let store = try await store()
        try await store.recordFailure(.offline, sourceID: home.id, at: t0)
        try await store.delete(sourceID: home.id)
        #expect(try await store.fetchState(sourceID: home.id) == nil)
    }

    @Test func fetchStatesAreObservable() async throws {
        let store = try await store()
        var states = store.observeFetchStates().makeAsyncIterator()
        #expect(try await states.next() == [])
        try await store.recordFailure(.unauthorized, sourceID: home.id, at: t0)
        #expect(try await states.next()?.map(\.problem) == [.signedOut])
    }
}

@Suite struct FillingTheGap {
    @Test func pagesBackUntilItReachesTheReadersPlace() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [post("5", at: t0 - 60)], newer: Cursor(rawValue: "5"), older: Cursor(rawValue: "5"))),
            .success(FetchedPage(items: [post("4", at: t0 - 3_600)], newer: nil, older: Cursor(rawValue: "4"))),
            .success(FetchedPage(items: [post("3", at: t0 - 7_200)], newer: nil, older: Cursor(rawValue: "3"))),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        let pages = try await refresher.fillGap(of: home, with: connector, backTo: t0 - 5_000, now: t0)
        #expect(pages == 2)
        #expect(connector.requests.dropFirst().allSatisfy { $0.direction == .older })
        #expect(try await store.rows().count == 3)
    }

    @Test func stopsWhenNothingOlderComes() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [post("5", at: t0 - 60)], newer: Cursor(rawValue: "5"), older: Cursor(rawValue: "5"))),
            .success(FetchedPage(items: [], newer: nil, older: nil)),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        #expect(try await refresher.fillGap(of: home, with: connector, backTo: t0 - day, now: t0) == 1)
        // Reached the oldest: nothing more is asked for.
        #expect(try await refresher.fillGap(of: home, with: connector, backTo: t0 - day, now: t0) == 0)
        #expect(connector.requests.count == 2)
    }

    @Test func aFreshBoostOfAnOldPostDoesNotCountAsFetchedBack() async throws {
        let store = try await store()
        var boost = post("5", at: t0 - 30 * day)
        boost.sortDate = t0 - 60
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [boost], newer: Cursor(rawValue: "5"), older: Cursor(rawValue: "5"))),
            .success(FetchedPage(items: [post("4", at: t0 - 7_200)], newer: nil, older: Cursor(rawValue: "4"))),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        #expect(try await refresher.fillGap(of: home, with: connector, backTo: t0 - 5_000, now: t0) == 1)
    }

    @Test func aBookmarkKeptPastTheRetentionWindowDoesNotCountAsFetchedBack() async throws {
        let store = try await store()
        var kept = post("1", at: t0 - InfluxStore.postRetention - day)
        kept.fetchedAt = kept.publishedAt
        kept.viewer = Item.Viewer(bookmarked: true)
        try await store.insert([kept])
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [post("5", at: t0 - 60)], newer: Cursor(rawValue: "5"), older: Cursor(rawValue: "5"))),
            .success(FetchedPage(items: [post("4", at: t0 - 7_200)], newer: nil, older: Cursor(rawValue: "4"))),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        #expect(try await refresher.fillGap(of: home, with: connector, backTo: t0 - 5_000, now: t0) == 1)
    }

    @Test func aPageOfBookmarkCopiesStillCountsAsProgress() async throws {
        let store = try await store()
        var copy = post("4", at: t0 - 7_200)
        copy.onlyInBookmarks = true
        copy.viewer = Item.Viewer(bookmarked: true)
        try await store.insert([copy])
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [post("5", at: t0 - 60)], newer: Cursor(rawValue: "5"), older: Cursor(rawValue: "5"))),
            .success(FetchedPage(items: [post("4", at: t0 - 7_200)], newer: nil, older: Cursor(rawValue: "4"))),
            .success(FetchedPage(items: [post("3", at: t0 - 10_000)], newer: nil, older: Cursor(rawValue: "3"))),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        #expect(try await refresher.fillGap(of: home, with: connector, backTo: t0 - 9_000, now: t0) == 2)
    }

    @Test func aSourceAlreadyPastThePlaceFetchesNothing() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [post("5", at: t0 - 7_200)], newer: Cursor(rawValue: "5"), older: Cursor(rawValue: "5"))),
        ])
        let refresher = Refresher(store: store)
        _ = try await refresher.refresh(home, with: connector, now: t0)
        #expect(try await refresher.fillGap(of: home, with: connector, backTo: t0 - 3_600, now: t0) == 0)
    }
}

@Suite struct Actions {
    @Test func rowsNameTheirItemWithItsActionRef() async throws {
        let store = try await store()
        var boost = post("wrapper", at: t0)
        boost.actionRef = "original"
        try await store.insert([boost])
        let row = try #require(try await store.rows().first)
        #expect(try await store.itemReference(id: row.id) == ItemReference(sourceID: home.id, remoteID: "wrapper", actionRef: "original"))
        #expect(try await store.itemReference(id: row.id + 100) == nil)
    }

    @Test func connectorsSupportNoActionsUnlessTheySayso() async throws {
        let connector = ScriptedConnector([])
        #expect(connector.supportedActions.isEmpty)
        #expect(try await connector.availableSources().isEmpty)
        await #expect(throws: ConnectorError.unsupported) {
            try await connector.perform(.like, on: ItemReference(sourceID: home.id, remoteID: "1"))
        }
        await #expect(throws: ConnectorError.unsupported) {
            try await connector.thread(of: ItemReference(sourceID: home.id, remoteID: "1"))
        }
    }

    @Test func togglesFlipAndUndoForgetsTheRecord() {
        let viewer = Item.Viewer(liked: true, likeRef: "at://me/like/1")
        #expect(viewer.action(.like) == .unlike)
        #expect(viewer.action(.boost) == .boost)
        #expect(viewer.action(.bookmark) == .bookmark)
        #expect(viewer.applying(.unlike) == Item.Viewer())
        #expect(viewer.applying(.bookmark).isOn(.bookmark))
        #expect(viewer.applying(.boost).isOn(.boost) && viewer.applying(.boost).likeRef == "at://me/like/1")
    }

    @Test func rowsCarryTheViewerAndARefetchUpdatesOnlyThat() async throws {
        let store = try await store()
        var first = post("1", at: t0)
        first.viewer = Item.Viewer()
        try await store.insert([first])
        var again = first
        again.viewer = Item.Viewer(liked: true)
        again.body = "Edited"
        again.fetchedAt = t0.addingTimeInterval(60)
        #expect(try await store.insert([again]) == 0)
        let row = try #require(try await store.rows().first)
        #expect(row.viewer == Item.Viewer(liked: true))
        // The rest of the row, and so its height, stays as first stored.
        #expect(row.body == "Post 1")
    }

    @Test func aFetchFromBeforeALocalChangeCantUndoIt() async throws {
        let store = try await store()
        var item = post("1", at: t0)
        item.viewer = Item.Viewer()
        try await store.insert([item])
        try await store.setViewer(Item.Viewer(liked: true), mergeKey: item.mergeKey, sourceID: home.id, at: t0.addingTimeInterval(10))

        item.fetchedAt = t0.addingTimeInterval(5)
        try await store.insert([item])
        #expect(try await store.rows().first?.viewer?.liked == true)

        item.fetchedAt = t0.addingTimeInterval(20)
        try await store.insert([item])
        #expect(try await store.rows().first?.viewer?.liked == false)
    }

    @Test func aFetchThatBeganEarlierCantOverwriteALaterOne() async throws {
        let store = try await store()
        var item = post("1", at: t0)
        item.viewer = Item.Viewer()
        try await store.insert([item])

        // A thread fetch that began at +20 finds it liked, with the record
        // an undo needs.
        var thread = item
        thread.viewer = Item.Viewer(liked: true, likeRef: "at://me/like/1")
        thread.fetchedAt = t0.addingTimeInterval(20)
        try await store.applyFetchedViewer(of: thread)

        // A refresh that began at +10 finishes after it: older news.
        var refresh = item
        refresh.fetchedAt = t0.addingTimeInterval(10)
        try await store.insert([refresh])
        try await store.applyFetchedViewer(of: refresh)
        #expect(try await store.viewer(mergeKey: item.mergeKey, sourceID: home.id) == thread.viewer)

        // A fetch that began later still wins, even when it changes nothing
        // and the one after it is older again.
        var later = thread
        later.fetchedAt = t0.addingTimeInterval(30)
        try await store.insert([later])
        refresh.fetchedAt = t0.addingTimeInterval(25)
        try await store.insert([refresh])
        #expect(try await store.viewer(mergeKey: item.mergeKey, sourceID: home.id) == thread.viewer)

        var unliked = item
        unliked.fetchedAt = t0.addingTimeInterval(40)
        try await store.insert([unliked])
        #expect(try await store.viewer(mergeKey: item.mergeKey, sourceID: home.id) == Item.Viewer())
    }

    @Test func aNewCopyFetchedEarlierTakesALaterFetchedState() async throws {
        let store = try await store()
        let list = Source(id: "test:list", kind: .mastodonList, accountID: "test", title: "List", colorIndex: 2)
        try await store.save(sources: [list])
        var original = post("1", at: t0)
        original.viewer = Item.Viewer(bookmarked: true)
        original.fetchedAt = t0.addingTimeInterval(20)
        try await store.insert([original])

        // The list's page began before the home page that stored it.
        var copy = post("1", in: list, at: t0)
        copy.viewer = Item.Viewer()
        copy.fetchedAt = t0.addingTimeInterval(10)
        try await store.insert([copy])
        #expect(try await store.viewer(mergeKey: original.mergeKey, sourceID: list.id) == Item.Viewer(bookmarked: true))
        #expect(try await store.viewer(mergeKey: original.mergeKey, sourceID: home.id) == Item.Viewer(bookmarked: true))
    }

    @Test func aFetchedStateReachesEveryCopyFromTheSameAccount() async throws {
        let store = try await store()
        let list = Source(id: "test:list", kind: .mastodonList, accountID: "test", title: "List", colorIndex: 2)
        let other = Source(id: "other:home", kind: .mastodonHome, accountID: "other", title: "Home", colorIndex: 3)
        try await store.save(sources: [list, other])
        var original = post("1", at: t0)
        original.viewer = Item.Viewer()
        var theirs = post("1", in: other, at: t0)
        theirs.viewer = Item.Viewer()
        try await store.insert([original, theirs])

        // A boost of the post, fetched later through a list, says it's liked.
        var boost = post("boost-1", in: list, at: t0)
        boost.mergeKey = original.mergeKey
        boost.viewer = Item.Viewer(liked: true)
        boost.fetchedAt = t0.addingTimeInterval(10)
        try await store.insert([boost])
        #expect(try await store.viewer(mergeKey: original.mergeKey, sourceID: home.id) == Item.Viewer(liked: true))
        #expect(try await store.viewer(mergeKey: original.mergeKey, sourceID: other.id) == Item.Viewer())

        // The reader unlikes it; a copy fetched before that takes the change.
        try await store.setViewer(Item.Viewer(), mergeKey: original.mergeKey, sourceID: home.id, at: t0.addingTimeInterval(20))
        var late = post("boost-2", at: t0)
        late.mergeKey = original.mergeKey
        late.viewer = Item.Viewer(liked: true)
        late.fetchedAt = t0.addingTimeInterval(15)
        try await store.insert([late])
        let copies = try await store.rows(in: .sources([home.id, list.id]))
        #expect(copies.allSatisfy { $0.viewer == Item.Viewer() })
        #expect(try await store.viewer(mergeKey: original.mergeKey, sourceID: list.id) == Item.Viewer())
    }

    @Test func aChangeReachesEveryCopyFromTheSameAccountOnly() async throws {
        let store = try await store()
        let list = Source(id: "test:list", kind: .mastodonList, accountID: "test", title: "List", colorIndex: 2)
        let other = Source(id: "other:home", kind: .mastodonHome, accountID: "other", title: "Home", colorIndex: 3)
        try await store.save(sources: [list, other])
        let copies = [home, list, other].map { source in
            var item = post("1", in: source, at: t0)
            item.viewer = Item.Viewer()
            return item
        }
        try await store.insert(copies)
        try await store.setViewer(Item.Viewer(bookmarked: true), mergeKey: "post:1", sourceID: list.id, at: t0)
        #expect(try await store.rows(in: .sources([home.id])).first?.viewer?.bookmarked == true)
        #expect(try await store.rows(in: .sources([list.id])).first?.viewer?.bookmarked == true)
        #expect(try await store.rows(in: .sources([other.id])).first?.viewer?.bookmarked == false)
    }
}

/// Answers every action with `answer`, after `gate` lets it go.
private final class ActingConnector: Connector, @unchecked Sendable {
    private let lock = NSLock()
    private var _actions: [(ConnectorAction, ItemReference)] = []
    var answer: Result<Item.Viewer, ConnectorError>
    let gate = AsyncStream<Void>.makeStream()
    var waits = false

    var actions: [(ConnectorAction, ItemReference)] { lock.withLock { _actions } }

    init(_ answer: Result<Item.Viewer, ConnectorError>) {
        self.answer = answer
    }

    func handles(_ source: Source) -> Bool { true }
    func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage { throw ConnectorError.unsupported }

    /// What `viewer(of:)` answers.
    var current = Item.Viewer()

    func viewer(of item: ItemReference) async throws -> Item.Viewer { current }

    /// What `thread(of:)` answers.
    var fetchedThread: PostThread?

    func thread(of item: ItemReference) async throws -> PostThread {
        guard let fetchedThread else { throw ConnectorError.unsupported }
        return fetchedThread
    }

    func perform(_ action: ConnectorAction, on item: ItemReference) async throws -> Item.Viewer {
        lock.withLock { _actions.append((action, item)) }
        if waits {
            var gate = gate.stream.makeAsyncIterator()
            _ = await gate.next()
        }
        return try answer.get()
    }
}

@Suite struct SendingActions {
    private func stored(_ store: InfluxStore) async throws -> Item {
        var item = post("1", at: t0)
        item.viewer = Item.Viewer()
        try await store.insert([item])
        let row = try #require(try await store.rows().first)
        return try #require(try await store.item(id: row.id))
    }

    @Test func theServicesAnswerIsKept() async throws {
        let store = try await store()
        let item = try await stored(store)
        let connector = ActingConnector(.success(Item.Viewer(liked: true, likeRef: "like-1")))
        let after = try await PostActions(store: store).toggle(.like, on: item, with: connector)
        #expect(after == Item.Viewer(liked: true, likeRef: "like-1"))
        #expect(connector.actions.map(\.0) == [.like])
        #expect(connector.actions.first?.1 == ItemReference(item))
        #expect(try await store.rows().first?.viewer == after)
    }

    @Test func theChangeShowsBeforeTheServiceAnswersAndGoesBackIfItRefuses() async throws {
        let store = try await store()
        let item = try await stored(store)
        let connector = ActingConnector(.failure(.offline))
        connector.waits = true
        let actions = PostActions(store: store)
        let sent = Task { try await actions.toggle(.boost, on: item, with: connector) }
        while connector.actions.isEmpty { await Task.yield() }
        #expect(try await store.rows().first?.viewer?.boosted == true)
        // A second tap on the same toggle meanwhile does nothing.
        #expect(try await actions.toggle(.boost, on: item, with: connector) == nil)
        connector.gate.continuation.yield()
        await #expect(throws: ConnectorError.offline) { try await sent.value }
        #expect(try await store.rows().first?.viewer?.boosted == false)
        #expect(connector.actions.count == 1)
    }

    @Test func anAccountSignedOutShowsNothingUntilTheServiceAnswers() async throws {
        let store = try await store()
        var item = try await stored(store)
        try await store.recordFailure(.unauthorized, sourceID: item.sourceID, at: t0)
        #expect(try await store.fetchState(sourceID: item.sourceID)?.problem == .signedOut)
        let refusing = ActingConnector(.failure(.unauthorized))
        refusing.waits = true
        let actions = PostActions(store: store)
        let sent = Task { [item] in try await actions.toggle(.bookmark, on: item, with: refusing) }
        while refusing.actions.isEmpty { await Task.yield() }
        // Nothing moves while the refusal is on its way.
        #expect(try await store.rows().first?.viewer?.bookmarked == false)
        refusing.gate.continuation.yield()
        await #expect(throws: ConnectorError.unauthorized) { try await sent.value }
        #expect(try await store.rows().first?.viewer?.bookmarked == false)

        // Signed in again before a fetch cleared the problem: the change still goes through.
        item = try #require(try await store.item(id: item.id!))
        let accepting = ActingConnector(.success(Item.Viewer(bookmarked: true)))
        #expect(try await actions.toggle(.bookmark, on: item, with: accepting) == Item.Viewer(bookmarked: true))
        #expect(try await store.rows().first?.viewer?.bookmarked == true)
    }

    @Test func differentTogglesSentTogetherKeepEachOthersOutcome() async throws {
        let store = try await store()
        let item = try await stored(store)
        let liking = ActingConnector(.success(Item.Viewer(liked: true, likeRef: "like-1")))
        liking.waits = true
        // The bookmark's answer lags: it doesn't know about the like yet.
        let bookmarking = ActingConnector(.success(Item.Viewer(bookmarked: true)))
        let actions = PostActions(store: store)
        let liked = Task { try await actions.toggle(.like, on: item, with: liking) }
        while liking.actions.isEmpty { await Task.yield() }
        // Tapped from the same, now stale, row.
        let bookmarked = try await actions.toggle(.bookmark, on: item, with: bookmarking)
        #expect(bookmarked == Item.Viewer(liked: true, bookmarked: true))
        #expect(bookmarking.actions.map(\.0) == [.bookmark])
        liking.gate.continuation.yield()
        #expect(try await liked.value == Item.Viewer(liked: true, bookmarked: true, likeRef: "like-1"))
        #expect(try await store.rows().first?.viewer == Item.Viewer(liked: true, bookmarked: true, likeRef: "like-1"))
    }

    @Test func theFirstToggleFinishingFirstKeepsTheLaterOne() async throws {
        let store = try await store()
        let item = try await stored(store)
        let liking = ActingConnector(.success(Item.Viewer(liked: true, likeRef: "like-1")))
        liking.waits = true
        let boosting = ActingConnector(.success(Item.Viewer(boosted: true, boostRef: "boost-1")))
        boosting.waits = true
        let actions = PostActions(store: store)
        let liked = Task { try await actions.toggle(.like, on: item, with: liking) }
        while liking.actions.isEmpty { await Task.yield() }
        let boosted = Task { try await actions.toggle(.boost, on: item, with: boosting) }
        while boosting.actions.isEmpty { await Task.yield() }
        liking.gate.continuation.yield()
        _ = try await liked.value
        #expect(try await store.rows().first?.viewer == Item.Viewer(liked: true, boosted: true, likeRef: "like-1"))
        boosting.gate.continuation.yield()
        _ = try await boosted.value
        #expect(try await store.rows().first?.viewer == Item.Viewer(liked: true, boosted: true, likeRef: "like-1", boostRef: "boost-1"))
    }

    @Test func aRefusedToggleGoesBackWithoutTakingTheOtherWithIt() async throws {
        let store = try await store()
        let item = try await stored(store)
        let liking = ActingConnector(.success(Item.Viewer(liked: true, likeRef: "like-1")))
        liking.waits = true
        let boosting = ActingConnector(.failure(.offline))
        boosting.waits = true
        let actions = PostActions(store: store)
        let liked = Task { try await actions.toggle(.like, on: item, with: liking) }
        while liking.actions.isEmpty { await Task.yield() }
        let boosted = Task { try await actions.toggle(.boost, on: item, with: boosting) }
        while boosting.actions.isEmpty { await Task.yield() }
        liking.gate.continuation.yield()
        _ = try await liked.value
        boosting.gate.continuation.yield()
        await #expect(throws: ConnectorError.offline) { try await boosted.value }
        #expect(try await store.rows().first?.viewer == Item.Viewer(liked: true, likeRef: "like-1"))
    }

    @Test func anotherAccountsCopyOfThePostIsItsOwn() async throws {
        let store = try await store()
        let other = Source(id: "other:home", kind: .mastodonHome, accountID: "other", title: "Home", colorIndex: 3)
        try await store.save(sources: [other])
        let mine = try await stored(store)
        var theirs = post("1", in: other, at: t0)
        theirs.viewer = Item.Viewer(bookmarked: true)
        try await store.insert([theirs])
        let liking = ActingConnector(.success(Item.Viewer(liked: true)))
        liking.waits = true
        let actions = PostActions(store: store)
        let liked = Task { try await actions.toggle(.like, on: mine, with: liking) }
        while liking.actions.isEmpty { await Task.yield() }
        // The other account's like isn't held up, and its bookmark is its own.
        let theirLike = ActingConnector(.success(Item.Viewer(liked: true, bookmarked: true)))
        #expect(try await actions.toggle(.like, on: theirs, with: theirLike) != nil)
        let unbookmarking = ActingConnector(.success(Item.Viewer(liked: true)))
        _ = try await actions.toggle(.bookmark, on: theirs, with: unbookmarking)
        #expect(unbookmarking.actions.map(\.0) == [.unbookmark])
        liking.gate.continuation.yield()
        _ = try await liked.value
        #expect(try await store.rows(in: .sources([home.id])).first?.viewer == Item.Viewer(liked: true))
        #expect(try await store.rows(in: .sources([other.id])).first?.viewer == Item.Viewer(liked: true))
    }

    @Test func aStaleCopyOfAPostActsOnItsCurrentState() async throws {
        let store = try await store()
        let reply = post("not-stored", at: t0)
        let actions = PostActions(store: store)
        let liking = ActingConnector(.success(Item.Viewer(liked: true, likeRef: "like-1")))
        _ = try await actions.toggle(.like, on: reply, with: liking)
        // Another thread page still holds the post as it was.
        let unliking = ActingConnector(.success(Item.Viewer()))
        _ = try await actions.toggle(.like, on: reply, with: unliking)
        #expect(unliking.actions.map(\.0) == [.unlike])
        #expect(unliking.actions.first?.1.viewer?.likeRef == "like-1")
        #expect(try await actions.viewer(of: reply) == Item.Viewer())

        // A stored post goes by the store, not the row it was tapped from.
        let item = try await stored(store)
        try await store.setViewer(Item.Viewer(bookmarked: true), mergeKey: item.mergeKey, sourceID: item.sourceID)
        let bookmarking = ActingConnector(.success(Item.Viewer()))
        _ = try await actions.toggle(.bookmark, on: item, with: bookmarking)
        #expect(bookmarking.actions.map(\.0) == [.unbookmark])
    }

    @Test func anUnconfirmedPostAsksTheServiceFirst() async throws {
        let store = try await store()
        var item = post("1", at: t0)
        item.viewer = Item.Viewer()
        item.viewer?.unconfirmed = true
        try await store.insert([item])
        let connector = ActingConnector(.success(Item.Viewer(bookmarked: true)))
        connector.current = Item.Viewer(liked: true, likeRef: "like-1")
        let after = try await PostActions(store: store).toggle(.like, on: item, with: connector)
        #expect(connector.actions.map(\.0) == [.unlike])
        #expect(connector.actions.first?.1.viewer == Item.Viewer(liked: true, likeRef: "like-1"))
        #expect(after == Item.Viewer())
        #expect(try await store.rows().first?.viewer == Item.Viewer())
    }

    @Test func aThreadsFreshStateIsWhatTheNextActionGoesBy() async throws {
        let store = try await store()
        let item = try await stored(store)
        var fresh = item
        fresh.viewer = Item.Viewer(liked: true, likeRef: "like-1")
        var reply = post("2", at: t0)
        reply.viewer = Item.Viewer(bookmarked: true)
        let connector = ActingConnector(.success(Item.Viewer()))
        connector.fetchedThread = PostThread(ancestors: [], post: fresh, replies: [PostThread.Reply(item: reply, depth: 1)])
        let actions = PostActions(store: store)
        let thread = try await actions.thread(of: item, with: connector)
        #expect(thread.post.viewer == Item.Viewer(liked: true, likeRef: "like-1"))
        #expect(try await store.rows().first?.viewer == Item.Viewer(liked: true, likeRef: "like-1"))

        // Liked on another device: the stale row's tap undoes the like.
        _ = try await actions.toggle(.like, on: item, with: connector)
        #expect(connector.actions.map(\.0) == [.unlike])
        #expect(connector.actions.first?.1.viewer?.likeRef == "like-1")
        // A post only in the thread goes by the thread too.
        _ = try await actions.toggle(.bookmark, on: post("2", at: t0), with: connector)
        #expect(connector.actions.map(\.0) == [.unlike, .unbookmark])
    }

    @Test func aThreadFetchedBeforeALocalChangeCantUndoIt() async throws {
        let store = try await store()
        let item = try await stored(store)
        var stale = item
        stale.viewer = Item.Viewer()
        let connector = ActingConnector(.success(Item.Viewer(liked: true)))
        connector.fetchedThread = PostThread(ancestors: [], post: stale, replies: [])
        let actions = PostActions(store: store)
        _ = try await actions.toggle(.like, on: item, with: connector, now: Date().addingTimeInterval(60))
        let thread = try await actions.thread(of: item, with: connector)
        #expect(thread.post.viewer?.liked == true)
        #expect(try await store.rows().first?.viewer?.liked == true)
    }

    @Test func togglesOfAPostThatIsntStoredKeepEachOthersOutcome() async throws {
        let store = try await store()
        let reply = post("not-stored", at: t0)
        let liking = ActingConnector(.success(Item.Viewer(liked: true)))
        liking.waits = true
        let boosting = ActingConnector(.failure(.offline))
        let actions = PostActions(store: store)
        let liked = Task { try await actions.toggle(.like, on: reply, with: liking) }
        while liking.actions.isEmpty { await Task.yield() }
        await #expect(throws: ConnectorError.offline) { try await actions.toggle(.boost, on: reply, with: boosting) }
        liking.gate.continuation.yield()
        #expect(try await liked.value == Item.Viewer(liked: true))
    }

    @Test func postsThatArentStoredCanBeActedOnToo() async throws {
        let store = try await store()
        var reply = post("not-stored", at: t0)
        reply.viewer = Item.Viewer(bookmarked: true)
        let connector = ActingConnector(.success(Item.Viewer()))
        _ = try await PostActions(store: store).toggle(.bookmark, on: reply, with: connector)
        #expect(connector.actions.map(\.0) == [.unbookmark])
        #expect(try await store.rows().isEmpty)
    }
}

@Suite struct RefreshingMany {
    @Test func eachSourceGetsItsOwnOutcome() async throws {
        let store = try await store()
        let connector = ScriptedConnector([
            .success(FetchedPage(items: [post("1", at: t0)], newer: nil, older: nil)),
            .failure(ConnectorError.notFound),
        ])
        let outcomes = try await Refresher(store: store).refreshAll([home, feed], with: connector, maxConcurrent: 1, now: t0)
        #expect(outcomes == [home.id: .fetched(newItems: 1), feed.id: .failed(.notFound)])
        #expect(try await store.fetchState(sourceID: feed.id)?.problem == .notFound)
    }
}

@Suite struct HTTPResponses {
    private func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    @Test func statusesMapToConnectorErrors() throws {
        try ConnectorError.check(response(200), now: t0)
        try ConnectorError.check(response(304), now: t0)
        #expect(throws: ConnectorError.unauthorized) { try ConnectorError.check(response(401), now: t0) }
        #expect(throws: ConnectorError.unauthorized) { try ConnectorError.check(response(403), now: t0) }
        #expect(throws: ConnectorError.notFound) { try ConnectorError.check(response(410), now: t0) }
        #expect(throws: ConnectorError.badResponse("HTTP 500")) { try ConnectorError.check(response(500), now: t0) }
        #expect(throws: ConnectorError.badResponse("HTTP 503")) { try ConnectorError.check(response(503), now: t0) }
    }

    @Test func retryAfterIsSecondsOrAnHTTPDate() {
        #expect(throws: ConnectorError.rateLimited(retryAfter: t0 + 120)) {
            try ConnectorError.check(response(429, ["Retry-After": "120"]), now: t0)
        }
        #expect(throws: ConnectorError.rateLimited(retryAfter: Date(timeIntervalSince1970: 784_111_777))) {
            try ConnectorError.check(response(503, ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"]), now: t0)
        }
        #expect(throws: ConnectorError.rateLimited(retryAfter: nil)) {
            try ConnectorError.check(response(429), now: t0)
        }
    }

    @Test func httpDatesRoundTrip() {
        let date = Date(timeIntervalSince1970: 784_111_777)
        #expect(HTTPDate.format(date) == "Sun, 06 Nov 1994 08:49:37 GMT")
        #expect(HTTPDate.parse("Sun, 06 Nov 1994 08:49:37 GMT") == date)
    }

    @Test func fakeClientRecordsRequests() async throws {
        let client = FakeHTTPClient(routes: ["https://example.com/a": .init(text: "hello")])
        let (body, response) = try await client.send(URLRequest(url: URL(string: "https://example.com/a")!))
        #expect(String(decoding: body, as: UTF8.self) == "hello")
        #expect(response.statusCode == 200)
        let (_, missing) = try await client.send(URLRequest(url: URL(string: "https://example.com/b")!))
        #expect(missing.statusCode == 404)
        #expect(client.requests.map(\.url?.path) == ["/a", "/b"])
    }
}
