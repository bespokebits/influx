import Foundation
import InfluxKit
#if canImport(UIKit)
import UIKit
#endif

/// Run-time switches, read from UserDefaults so a launch argument such as
/// `-InfluxSeedTimeline YES` sets one for a single run (the Debug and perf
/// schemes pass them).
enum AppSettings {
    /// Show the sample timeline (`SeedFeed`) from an in-memory store instead
    /// of the reader's own. For previews, UI tests and scroll performance runs.
    static var seedTimeline: Bool { UserDefaults.standard.bool(forKey: "InfluxSeedTimeline") }
    /// With the sample timeline, show its accounts as signed out
    /// (`-InfluxSampleSignedOut YES`), and have their actions refused as a
    /// signed-out account's are, for trying the sign-in alert and the
    /// refused-action notice.
    static var sampleSignedOut: Bool { UserDefaults.standard.bool(forKey: "InfluxSampleSignedOut") }
    /// Show the hitch counter over the timeline.
    static var showScrollDiagnostics: Bool { UserDefaults.standard.bool(forKey: "InfluxShowScrollDiagnostics") }
    /// Run on a separate on-disk store filled with the sample timeline, so
    /// the launch test reads a cached timeline from disk the way a reader's
    /// launch does, without touching the reader's own library.
    static var perfStore: Bool { UserDefaults.standard.bool(forKey: "InfluxPerfStore") }
    /// Read on by itself, for checking sync between two devices:
    /// `-InfluxSyncDrivePeriod 40` scrolls the
    /// timeline down part of a screen at each whole multiple of 40 s, and
    /// `-InfluxSyncDriveOffset 20` shifts that, so two devices take turns.
    /// 0, the default, leaves the reader's timeline alone.
    static var syncDrivePeriod: Int { UserDefaults.standard.integer(forKey: "InfluxSyncDrivePeriod") }
    static var syncDriveOffset: Int { UserDefaults.standard.integer(forKey: "InfluxSyncDriveOffset") }
    /// With a drive on, `-InfluxDriveWrap YES` goes back to the top once
    /// the drive reaches the bottom, so a memory soak can read on for as
    /// long as it runs. Leave it off on a reader's timeline.
    static var driveWraps: Bool { UserDefaults.standard.bool(forKey: "InfluxDriveWrap") }
    /// `-InfluxSyncingScreenFor 3` shows the "Syncing in Progress" screen
    /// at launch in a run without sync, lifting after that many seconds as
    /// a slow iCloud would, so UI tests can try it. 0, the default, doesn't.
    static var syncingScreenFor: Double { UserDefaults.standard.double(forKey: "InfluxSyncingScreenFor") }
    /// `-InfluxSyncingScene ribbon` shows that animation on the stand-in
    /// screen, for screenshots of each. Unset, it picks at random as usual.
    static var syncingScene: SyncingScene? {
        UserDefaults.standard.string(forKey: "InfluxSyncingScene").flatMap(SyncingScene.init(rawValue:))
    }
    /// The app is only hosting unit tests (xcodebuild sets
    /// `XCTestConfigurationFilePath` in the host it launches; a UI test's
    /// app never sees it). The host then skips the launch work: no library,
    /// refresh, sync or timeline, so nothing can hold up the runner
    /// attaching. Tests build the models they need themselves.
    static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// What the app runs on: the store, and for sample runs a way to add rows.
@MainActor
final class AppModel {
    let store: InfluxStore
    /// RSS subscriptions and their refresh loop. Idle on sample runs and
    /// when the library didn't open, so nothing writes to a stand-in store.
    lazy var feeds = Feeds(store: store, isSample: isSample)
    /// Bluesky and Mastodon accounts and their refresh loop, idle in the
    /// same cases as `feeds`.
    lazy var accounts = Accounts(store: store, isSample: isSample)
    /// Sends likes, boosts and bookmarks, showing them at once.
    lazy var postActions = PostActions(store: store)
    /// Bookmarks to Sammy Inbox: the switch and the outbox, idle in the
    /// same cases as `accounts`.
    lazy var sammyInbox = SammyInbox(store: store, accounts: accounts, isSample: isSample)
    /// Saved views and filters, and which view the timeline shows.
    let views: Views
    /// iCloud sync, or nil when this build has no container configured, or
    /// on a sample or stand-in store.
    lazy var sync: Sync? = {
        guard !isSample, let containerID = Sync.containerID else { return nil }
        return Sync(store: store, containerID: containerID)
    }()
    /// The "Syncing in Progress" screen: sync's, or with
    /// `-InfluxSyncingScreenFor` a stand-in that only waits out its limit.
    lazy var syncingGate: SyncingGate? = {
        let gate: SyncingGate
        if let sync {
            gate = sync.gate
        } else {
            let seconds = AppSettings.syncingScreenFor
            guard seconds > 0 else { return nil }
            gate = SyncingGate(limit: .milliseconds(Int(seconds * 1000)), defaults: nil) { last in
                AppSettings.syncingScene ?? SyncingScene.random(after: last)
            }
            gate.show()
        }
        // A place from another device stuck among this device's newest
        // rows waits for the posts before it, while a fetch can bring them.
        gate.placeLoading = { [weak self] in
            guard let self, TimelineController.waitsForPostsBeforeAPlace else { return false }
            return self.feeds.isRefreshing || self.accounts.isRefreshing
        }
        SyncingGate.app = gate
        return gate
    }()
    #if os(macOS)
    /// Whether one of the Mac app's windows can be seen, for how often
    /// sources are fetched.
    lazy var screenPresence = ScreenPresence { [weak self] in self?.setOnScreen($0) }
    #endif

    /// Says whether the reader can see the app: on iOS, the scene is
    /// active; on the Mac, a window is visible (`ScreenPresence`). On
    /// screen, sources are fetched as often as their services allow, and
    /// coming on screen fetches each one older than that at once
    /// (`RefreshCadence`, ADR 0036); Mastodon home timelines stream
    /// (ADR 0037), and Sammy accounts hold their change stream (ADR 0038).
    func setOnScreen(_ onScreen: Bool) {
        feeds.timer.setOnScreen(onScreen)
        accounts.setOnScreen(onScreen)
    }

    #if os(macOS)
    /// Coming back to the Mac app, which shows the "Syncing in Progress"
    /// screen: switching back after a while, waking, reopening the window.
    lazy var syncReturns: SyncReturns? = sync.map { sync in
        SyncReturns(wentAway: { [weak self] in
            Task { await self?.putAway() }
        }) { away, waitingForNetwork in sync.cameBack(after: away, waitingForNetwork: waitingForNetwork) }
    }
    #endif

    /// The app is being put away: saves where the reader is and sends it
    /// to iCloud now, rather than after the pause that follows a scroll,
    /// so another device opened next finds it (influx-dev #125).
    func putAway() async {
        await TimelineController.saveAllForLeaving()
        await sync?.sendWaiting()
    }

    #if canImport(UIKit)
    /// The same when the phone is locked or switched from, asking iOS for
    /// the time to finish: it stops the app within seconds otherwise, and
    /// the place then waited on the phone until it was next opened.
    func putAwayInBackground() {
        let grant = BackgroundGrant()
        grant.id = UIApplication.shared.beginBackgroundTask(withName: "Send the reading place") {
            grant.end()
        }
        Task {
            await putAway()
            grant.end()
        }
    }

    /// Time iOS grants to finish after the app leaves the screen. Ended
    /// once, by the work finishing or by iOS running out of patience.
    @MainActor
    private final class BackgroundGrant {
        var id = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
    #endif
    /// Sample runs only: adds 20 newer sample rows, to try appends.
    let addSampleRows: (@MainActor () async -> Void)?
    /// What the File menu asks of the Sources screen.
    let sourcesRequests = SourcesRequests()
    /// Set when the library file couldn't be opened. `store` is then an
    /// empty in-memory stand-in that nothing should write to, and the shell
    /// shows the error instead of the timeline.
    let storeError: (any Error)?
    /// The selected view's marker and rows, read as soon as the store opens
    /// so the read overlaps the shell's setup. Taken by the first timeline.
    private var opening: TimelineOpening.Pending?

    private var isSample: Bool {
        AppSettings.seedTimeline || AppSettings.perfStore || AppSettings.isUnitTestHost || storeError != nil
    }

    /// Field performance reports (ADR 0034), from a TestFlight install's
    /// own timeline only: never a sample, perf or stand-in store's.
    func startFieldPerformance() {
        guard !isSample else { return }
        FieldPerformance.start()
    }

    private init(store: InfluxStore, addSampleRows: (@MainActor () async -> Void)?, storeError: (any Error)? = nil,
                 readsOpening: Bool = false) {
        self.store = store
        self.addSampleRows = addSampleRows
        self.storeError = storeError
        views = Views(store: store)
        opening = readsOpening
            ? TimelineOpening.read(from: store, viewID: views.selectedID, expected: TimelineOpening.expectedEnvironment())
            : nil
    }

    /// The connector that acts for posts from `sourceID`: its account's,
    /// if the account is signed in on this device. Sample runs act through
    /// a stand-in, so the seeded timeline's posts can be tried.
    func connector(forSource sourceID: String) -> (any Connector)? {
        if AppSettings.seedTimeline || AppSettings.perfStore {
            return SampleConnector(refuses: AppSettings.sampleSignedOut)
        }
        return accounts.connector(forSource: sourceID)
    }

    /// Fetches every feed and account now, for Refresh and for pulling up
    /// past the newest row, and returns when done. A pass already under way
    /// is joined, not doubled. Sample runs add 20 newer sample rows instead,
    /// so tests can refresh without the network. New rows land like any
    /// others: below, followed only when the reader is at the bottom.
    func refreshNow() async {
        if let addSampleRows { return await addSampleRows() }
        let feeds = feeds, accounts = accounts
        async let feedsDone: Void = feeds.refresh()
        async let accountsDone: Void = accounts.refresh()
        _ = await (feedsDone, accountsDone)
    }

    /// The opening read, for the first timeline that asks, if it shows the
    /// view that was read; nil after.
    func takeOpening(for viewID: String) -> TimelineOpening.Pending? {
        defer { opening = nil }
        return opening?.viewID == viewID ? opening : nil
    }

    static func launch() -> AppModel {
        LaunchClock.mark("app")
        defer { LaunchClock.mark("store") }
        if AppSettings.isUnitTestHost {
            return AppModel(store: try! InfluxStore.inMemory(), addSampleRows: nil)
        }
        if AppSettings.seedTimeline {
            return sample()
        }
        do {
            // A perf run never falls back to the reader's own library: if its
            // store can't open, it fails like any library that can't.
            let store = try InfluxStore(path: try storePath(file: AppSettings.perfStore ? "Influx-perf.sqlite" : "Influx.sqlite"))
            if AppSettings.perfStore {
                // Filled once; every later launch reads it back from disk.
                Task {
                    guard (try? await store.rows().isEmpty) ?? false else { return }
                    try? await SeedFeed.load(into: store)
                }
                return AppModel(store: store, addSampleRows: nil, readsOpening: true)
            }
            // Retention: drop what has aged out, after launch so
            // it never delays the first screen. Pruned rows are the oldest,
            // above the reading position, so the timeline holds its place.
            Task.detached(priority: .utility) { _ = try? await store.prune() }
            return AppModel(store: store, addSampleRows: nil, readsOpening: true)
        } catch {
            // Without its library the app can't keep anything, so it says so
            // rather than quietly running on a store that forgets.
            return AppModel(store: try! InfluxStore.inMemory(), addSampleRows: nil, storeError: error)
        }
    }

    /// The sample timeline in an in-memory store.
    static func sample(count: Int = 2_000) -> AppModel {
        let store = try! InfluxStore.inMemory()
        var batch = 0
        let model = AppModel(store: store) {
            batch += 1
            // Taken before the await, so overlapping taps never share a batch.
            let thisBatch = batch
            guard let last = try? await store.rows().last else { return }
            _ = try? await store.insert(SeedFeed.newer(count: 20, after: last.sortDate, batch: thisBatch))
        }
        Task { try? await SeedFeed.load(into: store, count: count) }
        return model
    }

    /// Application Support/<bundle ID>/Influx.sqlite. The bundle ID differs
    /// per configuration, so Debug and Test builds never share the store.
    private static func storePath(file: String) throws -> String {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "dev.bespokebits.influx", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent(file).path
        try moveRenamedStore(from: folder.appendingPathComponent(file.replacingOccurrences(of: "Influx", with: "Flux")).path, to: path)
        return path
    }

    /// Builds from before the rename kept the library as Flux.sqlite. It
    /// moves across once, before anything opens it, with its WAL and
    /// shared-memory files, which go first so the main file never arrives
    /// without them.
    static func moveRenamedStore(from old: String, to path: String) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: path), files.fileExists(atPath: old) else { return }
        for suffix in ["-wal", "-shm"] where files.fileExists(atPath: old + suffix) {
            try? files.removeItem(atPath: path + suffix)
            try files.moveItem(atPath: old + suffix, toPath: path + suffix)
        }
        try files.moveItem(atPath: old, toPath: path)
    }
}
