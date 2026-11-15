import Foundation
@testable import InfluxKit

// Pretend devices for testing the reading place between them: each has a
// real store with its own posts in it, syncs through the stand-in iCloud,
// and runs the same place rules as the app's timeline, on a screen that is
// only the store's rows and the index of the one at its top. What a timeline's view and timers do in
// the app, a test does here by calling the device: the reader scrolls, the
// scroll pauses, posts arrive, the app is put away, comes back, or syncs.
//
// Devices need not have the same rows. That is how the app is: each device
// fetches its own posts, so a place one sets can name a row another lacks.

let simStart = Date(timeIntervalSince1970: 1_793_000_000)

private let simSource = Source(id: "mastodon:@me@example.social:home", kind: .mastodonHome, accountID: "@me@example.social",
                               title: "Mastodon", colorIndex: 1)

/// The merge key of the post dated `minute` minutes after the start.
func simKey(_ minute: Int) -> String {
    String(format: "post:%03d", minute)
}

/// A post dated `minute` minutes after the start, named by it.
private func simPost(_ minute: Int) -> Item {
    let date = simStart.addingTimeInterval(Double(minute) * 60)
    return Item(
        sourceID: simSource.id, remoteID: simKey(minute), kind: .post, mergeKey: simKey(minute),
        authorName: "Ana Ruiz", authorHandle: "@ana", body: "Post \(minute)",
        publishedAt: date, fetchedAt: date
    )
}

/// The time every device goes by. Tests move it on themselves.
final class SimClock {
    private let base = ContinuousClock.now
    private(set) var seconds = 0.0

    var now: Date { simStart.addingTimeInterval(seconds) }
    var instant: ContinuousClock.Instant { base + .milliseconds(Int(seconds * 1000)) }

    func advance(by seconds: Double) {
        self.seconds += seconds
    }
}

/// A screen of rows that are all one unit high, `height` of them showing.
final class SimScreen: PlaceScreen {
    var rows: [TimelineRow] = []
    /// The index of the row at the top.
    var top = 0
    let height: Int
    var isScrolling = false

    init(height: Int) {
        self.height = height
    }

    /// The furthest down the top of the screen goes.
    private var bottomTop: Int { max(0, rows.count - height) }
    var isAtBottom: Bool { top >= rows.count - height }
    var topRow: Int { top }

    func isOnScreen(row index: Int) -> Bool {
        index >= top && index < top + height
    }
    var rowToSave: Int { top }

    func shows(row index: Int) -> Bool {
        index <= rows.count - height && top == index
    }

    func clamp(_ index: Int) -> Int {
        max(0, min(index, bottomTop))
    }

    @discardableResult
    func go(toRow index: Int, to move: PlaceMove) -> Bool {
        let target = clamp(index)
        if move == .opening {
            top = target
            return true
        }
        guard target != top else { return false }
        top = target
        return true
    }

    func goToNewest() {
        top = bottomTop
    }

    /// Shows a new set of rows, holding a row where it was on the screen,
    /// as the timeline does when rows change: the row at the top, or the
    /// next that hasn't moved when sync moved that one (`HeldRow`).
    func replace(_ newRows: [TimelineRow]) {
        var now: [String: Int] = [:]
        for (index, row) in newRows.enumerated() { now[row.mergeKey] = index }
        let held = rows.indices.contains(top)
            ? HeldRow.choose(in: rows, visible: top..<min(rows.count, top + height)) { key in now[key].map { newRows[$0] } } ?? top
            : nil
        let index = held.flatMap { held in now[rows[held].mergeKey].map { $0 - (held - top) } } ?? min(top, max(0, newRows.count - 1))
        rows = newRows
        top = clamp(index)
    }

    var topKey: String? { rows.indices.contains(top) ? rows[top].mergeKey : nil }
}

/// One device: a store, its sync, a screen and the place rules.
final class SimDevice {
    static let viewID = ReadingPosition.allViewID

    let name: String
    let store: InfluxStore
    let screen: SimScreen
    private let coordinator: SyncCoordinator
    private let clock: SimClock
    private(set) var tracker = PlaceTracker(viewID: SimDevice.viewID)
    /// What the timeline tells the store it has on the screen.
    private let onScreen: TimelineOnScreen

    /// Whether the timeline has shown its first rows.
    private(set) var isOpen = false
    /// The furthest marker the timeline knows of.
    private(set) var marker: LastReadMarker?
    /// The place the store last delivered to the timeline.
    private var delivered: ReadingPlace?
    /// The row the reader's scrolling last left them past, not yet saved.
    private var pendingMarker: TimelineRow?
    private var hasSource = false

    /// What the place rules wrote to the journal.
    private(set) var notes: [String] = []
    /// Every move this device sent to its store, oldest first, and what
    /// the store made of each.
    private(set) var saves: [PlaceSave] = []
    private(set) var outcomes: [ReadingPlaceMove] = []
    /// Whether the reader's last move stayed on this device, so its screen
    /// needn't be on the shared place.
    private(set) var readsApart = false
    /// How many times the reader moved this device's screen.
    private(set) var readerMoves = 0

    init(_ name: String, server: InMemorySyncServer, clock: SimClock, screenHeight: Int = 5) throws {
        self.name = name
        self.clock = clock
        store = try InfluxStore.inMemory()
        coordinator = SyncCoordinator(store: store, server: server)
        screen = SimScreen(height: screenHeight)
        onScreen = store.timelineOnScreen(viewID: Self.viewID)
        listen()
    }

    private func listen() {
        tracker.note = { [unowned self] message in notes.append(message) }
    }

    /// The place this device's store holds.
    func storedPlace() async throws -> ReadingPlace? {
        try await store.readingPlace(viewID: Self.viewID)
    }

    // MARK: What happens to a device

    /// The device's fetch brings the posts dated these minutes. A timeline
    /// that hasn't opened opens once it has rows. With `belowTheLine`,
    /// they are placed as the app places posts a refresh brings: by their
    /// own times, but never above what the reader has read or the last
    /// row on the screen (ADR 0041).
    func fetch(_ minutes: some Sequence<Int>, belowTheLine: Bool = false) async throws {
        if !hasSource {
            try await store.save(sources: [simSource], at: simStart)
            hasSource = true
        }
        // The app's timeline says what it shows as it changes; here the
        // store only needs it when rows arrive.
        let last = isOpen ? screen.rows.indices.clamped(to: 0..<(screen.top + screen.height)).last : nil
        onScreen.show(downTo: last.map { screen.rows[$0].sortDate })
        try await store.insert(minutes.map(simPost), belowTheLine: belowTheLine)
        try await showRows()
    }

    /// Shows the rows the store holds now.
    private func showRows() async throws {
        let rows = try await store.rows(inView: Self.viewID)
        if isOpen {
            screen.replace(rows)
        } else {
            guard !rows.isEmpty else { return }
            marker = furthest(marker, try await store.lastReadMarker(viewID: Self.viewID))
            tracker.begin(with: try await storedPlace())
            screen.rows = rows
            isOpen = true
            tracker.open(on: screen, marker: marker)
        }
        tracker.rowsChanged(on: screen)
    }

    /// The reader scrolls so that the row at `index` is at the top.
    func scroll(to index: Int) {
        guard isOpen, !screen.rows.isEmpty else { return }
        let before = screen.top
        // The first scroll callback comes a few points in, with the rows
        // that were on the screen still on it.
        tracker.readerScrolled(at: clock.now, on: screen)
        screen.top = screen.clamp(index)
        readerMoves += 1
        // Reading is going down: the row just above the screen is read, or
        // the last row at the bottom.
        if screen.top > before {
            let read = screen.isAtBottom ? screen.rows.count - 1 : screen.top - 1
            if read >= 0 { pendingMarker = screen.rows[read] }
        }
    }

    /// A sync pass lands while the reader is still scrolling to `index`.
    func scrollThroughSync(to index: Int) async throws {
        scroll(to: index)
        screen.isScrolling = true
        defer { screen.isScrolling = false }
        try await sync()
    }

    /// The reader jumps to the row at `index`, as Jump to Newest does.
    func jump(to index: Int) {
        guard isOpen, !screen.rows.isEmpty, screen.clamp(index) != screen.top else { return }
        readerMoves += 1
        tracker.readerMoved(at: clock.now, on: screen)
        tracker.letGo()
        screen.top = screen.clamp(index)
    }

    /// The scroll has paused: the place and the marker are saved.
    func pause() async throws {
        guard isOpen else { return }
        try await perform(savePlace(because: "the scroll paused"))
        try await saveMarker()
        try await deliver()
    }

    /// The app is put away: the place is saved at once, and sent.
    func putAway(sending: Bool = true) async throws {
        guard isOpen else { return }
        try await perform(savePlace(because: "the app was put away"))
        try await saveMarker()
        try await deliver()
        if sending { try await coordinator.sync() }
    }

    /// A sync pass. Whatever arrived reaches the timeline.
    func sync() async throws {
        try await coordinator.sync()
        try await deliver()
        // Positions agreed through iCloud can move rows.
        try await showRows()
    }

    /// The app quits and starts again, with the posts in its store.
    func relaunch() async throws {
        if isOpen {
            tracker.stop()
            try await perform(savePlace(because: "the timeline closed"))
            try await saveMarker()
        }
        tracker = PlaceTracker(viewID: Self.viewID)
        listen()
        isOpen = false
        delivered = nil
        screen.rows = []
        screen.top = 0
        try await showRows()
    }

    /// Whether anything of this device's still waits to go to iCloud.
    func hasUnsent() async throws -> Bool {
        try await !store.pendingSyncChanges().isEmpty
    }

    // MARK: The timeline's part

    private func savePlace(because reason: String) -> PlaceSaveOutcome {
        guard isOpen, !screen.rows.isEmpty else { return .nothing }
        return tracker.save(from: screen, at: clock.now, because: reason)
    }

    private func perform(_ outcome: PlaceSaveOutcome) async throws {
        switch outcome {
        case .nothing:
            return
        case .stayedLocal:
            readsApart = true
        case .save(let save):
            saves.append(save)
            let place = save.place
            let made = try await store.moveReadingPlace(viewID: Self.viewID, to: (place.sortDate, place.mergeKey), at: place.updatedAt,
                                                        knowing: save.knowing, because: save.why)
            outcomes.append(made)
            tracker.saved(save, as: made, on: screen)
            if case .stayedLocal = made { readsApart = true } else { readsApart = false }
        }
    }

    private func saveMarker() async throws {
        guard let row = pendingMarker else { return }
        pendingMarker = nil
        let read = LastReadMarker(viewID: Self.viewID, sortDate: row.sortDate, mergeKey: row.mergeKey, updatedAt: clock.now)
        marker = furthest(marker, read)
        _ = try await store.moveLastReadMarker(viewID: Self.viewID, to: (row.sortDate, row.mergeKey), at: clock.now)
    }

    /// Gives the timeline the place and marker the store holds now, as the
    /// store's observations do, until nothing more comes of it.
    private func deliver() async throws {
        marker = furthest(marker, try await store.lastReadMarker(viewID: Self.viewID))
        while let stored = try await storedPlace(), stored != delivered {
            delivered = stored
            guard isOpen, !screen.rows.isEmpty else {
                tracker.arrivedBeforeOpening(stored)
                continue
            }
            if tracker.arrived(stored, on: screen) == .followed {
                readsApart = false
            }
        }
    }

    private func furthest(_ a: LastReadMarker?, _ b: LastReadMarker?) -> LastReadMarker? {
        guard let a else { return b }
        guard let b else { return a }
        return b.isAhead(of: a) ? b : a
    }
}

/// A seeded source of random numbers, so a run that fails can be run again.
struct SimRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
