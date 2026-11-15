// Keeps the timeline on screen in step with the store. It watches the
// store's rows, lays out new and changed rows off the main thread, and hands
// the platform view the row order to show, keeping the reader's place:
//
// - Rows the store adds after the last one are appended below, and the
//   unread pill counts them. The view stays where it is, even at the
//   bottom, so new posts never carry the reader past where they were.
// - Rows added, removed, resized or reordered above the viewport don't move
//   what the reader is looking at: they wait until scrolling stops, then go
//   in with the top visible row held where it was on screen, in the same
//   frame. A row that sync moved elsewhere isn't held: the next row that
//   stayed is, so the screen never follows a row up the timeline.
// - A row on screen never changes height. If its content changes
//   in a way that would, such as a first boost adding a line, the change
//   waits until the row is off screen.
// - A change of width, text size or appearance lays everything out again
//   off main, anchored on the top visible row.
// - Two things say where the reader is. The reading place is
//   the row at the top of the screen: once the reader's scrolling pauses,
//   or after a jump, it's saved, going back up as well as down. The
//   last-read marker says what has been read: it moves to the row just
//   above the top of the screen, or to the last row at the bottom, and
//   never moves back. Both sync, and each saved view has its own,
//   so switching views opens each where its reader left it.
// - The timeline opens on the reading place, or with no place yet on the
//   first row after the marker.
// - The shared place moves when the reader moves on from it, on any
//   device, or reads on past it (ADR 0028). When another device moves it,
//   the timeline goes there, so open devices keep up with each other,
//   unless the reader here is scrolling: where they stop is then weighed
//   against it. A scroll that didn't start from the shared place and
//   doesn't pass it stays on this device, which is taken to the shared
//   place once. Jump Back returns. A marker from another device only
//   changes what Jump to Marker and the unread rows go by.
// - Jumps go to the newest row, to the first row after the marker,
//   and back to where the reader was before the last jump. None of them
//   moves the marker: only the reader's own scrolling does.
// - The unread pill counts every row below the screen, so how much
//   is left to read from where the reader is: scrolling back up raises it.
//   It jumps to the newest. It's recounted at most five times a second while scrolling,
//   and once scrolling pauses.
// - The store is told the last row on screen whenever it changes, so a row
//   that arrives late is never placed above it or between two rows on
//   screen (ADR 0041). While the reader scrolls it is told a row two
//   screens further down, since the screen moves on before a row being
//   stored is shown.
//
// The iOS and macOS view controllers implement `TimelineSurface`; everything
// else is shared.
import CoreGraphics
import Foundation
import InfluxKit
import os

@MainActor
protocol TimelineSurface: AnyObject {
    /// The content y at the top of the visible area, below any bar.
    var viewportTop: CGFloat { get }
    var viewportHeight: CGFloat { get }
    /// True while the reader drags or the view decelerates.
    var isScrolling: Bool { get }
    /// True when the scroll being reported comes from the reader's own
    /// input: a drag, a fling, the wheel, the keyboard or the scroller.
    /// Offset changes the view makes itself (a relayout, a content size
    /// change, the system restoring the app) are not the reader.
    var isReaderInput: Bool { get }
    func setViewportTop(_ y: CGFloat, animated: Bool)
    /// Briefly marks `frame`, in timeline coordinates, to show where a Find
    /// result is.
    func flash(_ frame: CGRect)
    /// Shows `keys` in order. `reload` drops every cell (a full relayout);
    /// otherwise the change is diffed and `reconfigure` cells are refreshed.
    func show(_ keys: [String], reload: Bool, reconfigure: [String]) async
    /// Puts the current bitmap into the visible cell for `key`, if any.
    func refreshCell(_ key: String)
    /// How many unread rows wait below; 0 hides the pill.
    func showUnread(_ count: Int)
}

@MainActor
final class TimelineController {
    let model = TimelineModel()
    let images = RowImageCache()
    weak var surface: (any TimelineSurface)?
    /// Set when scroll diagnostics are on.
    var monitor: HitchMonitor?

    private let store: InfluxStore
    /// The saved view shown; its filters are applied by the store, so
    /// hidden rows never get here.
    let viewID: String
    /// The marker the timeline opened with, read before the first rows.
    private var openingMarker: LastReadMarker?
    /// The rules for the reading place: when it's saved, when a place from
    /// another device is followed, and when the screen has caught up with
    /// one it couldn't show at first. They are InfluxKit's, so they can be
    /// tested on several pretend devices at once; this timeline tells them
    /// what happened and does what they decide.
    private let tracker: PlaceTracker
    /// What this timeline tells the store it has on screen, so that rows
    /// arriving never land above the last of them (ADR 0041), and the
    /// position it last told.
    private let onScreen: TimelineOnScreen
    private var toldDownTo: Date?
    /// Whether the timeline is open: between `start()` and `stop()`.
    private var isOpen = false
    /// Whether the reader is moving the view: from their first scroll
    /// until the scroll's pause.
    private var readerIsMoving = false
    /// Lets go of the store once a closed timeline's last place and marker
    /// are saved; tests wait for it.
    private(set) var closing: Task<Void, Never>?
    /// The timelines whose place from another device can't be shown at the
    /// top of the screen yet.
    private static var placesLoading: Set<ObjectIdentifier> = []
    /// The timelines on screen, so all of them can be saved when the app is
    /// put away.
    private static let started = NSHashTable<TimelineController>.weakObjects()
    /// The writes of the place and marker last saved, while they run, so
    /// leaving can wait for the store to have them.
    private var placeWrite: Task<Void, Never>?
    private var markerWrite: Task<Void, Never>?
    /// Whether any timeline is waiting for the posts before a place that
    /// another device sent, so a scroll now would lose that place.
    static var waitsForPostsBeforeAPlace: Bool { !placesLoading.isEmpty }
    /// The same for this timeline, for tests.
    var waitsForPostsBeforePlace: Bool { tracker.waitsForPosts }
    /// The furthest marker this timeline knows of: the one it opened with,
    /// or the furthest row the reader has since scrolled past, saved or not.
    private var marker: LastReadMarker?
    /// Where the reader was before the last jump, for Jump Back.
    private var jumpOrigin: Anchor? {
        didSet { if (jumpOrigin == nil) != (oldValue == nil) { onCanJumpBackChange?(jumpOrigin != nil) } }
    }
    /// Told when Jump Back becomes possible or stops being so.
    var onCanJumpBackChange: ((Bool) -> Void)?
    /// Whether the reader is looking at a Find result they haven't scrolled
    /// on from, so "Back to where you were" shows.
    private(set) var offersReturn = false {
        didSet { if offersReturn != oldValue { onOffersReturnChange?(offersReturn) } }
    }
    var onOffersReturnChange: ((Bool) -> Void)?
    /// The row last sent to the store as the marker, and the pass that
    /// sends the next one once scrolling has paused.
    private var savedMarkerKey: String?
    private var markerSave: Task<Void, Never>?
    private var lastScroll = ContinuousClock.now
    /// The row the reader's own scrolling last left them past, waiting to
    /// be saved as the marker. The timeline's own moves (opening, following
    /// appends, holding the anchor) never change it; these tell them apart.
    private var pendingMarker: TimelineRow?
    /// Whether `pendingMarker` is a row the reader read past going down,
    /// rather than one scrolling up left above the screen. Only a read row
    /// holds against scrolling back up before the save.
    private var pendingMarkerWasRead = false
    /// The viewport top at the last scroll callback, to tell reading on
    /// (down) from going back (up).
    private var lastViewportTop: CGFloat?
    private var isPlacing = false
    /// The target of an animated move still under way.
    private var animatingTo: CGFloat?
    /// Ends `animatingTo` if the move never reports reaching its target, as
    /// when the surface clamps it short near the bottom.
    private var animationEnd: Task<Void, Never>?
    private var environment: RowEnvironment?
    private var laidOutEnvironment: RowEnvironment?
    /// The newest rows from the store, not yet shown.
    private var latest: [TimelineRow]?
    private var isUpdating = false
    private var didInitialScroll = false
    /// A row a link asked to go to before this timeline had it on screen.
    private var pendingReveal: String?
    /// Waits for the "Syncing in Progress" screen to lift, which nothing
    /// else tells the timeline, to go to `pendingReveal` then.
    private var revealWait: Task<Void, Never>?
    /// The count the unread pill shows, and when it last changed.
    private var shownUnread = 0
    private var unreadShownAt = ContinuousClock.now
    private var observation: Task<Void, Never>?
    private var markerObservation: Task<Void, Never>?
    private var placeObservation: Task<Void, Never>?
    private var driving: Task<Void, Never>?
    /// The row last clicked, tapped or pressed, for the Item menu.
    private var chosenKey: String?
    /// Rows whose changes were held back, because they were on screen or
    /// would land above the viewport mid-scroll, and the pass that retries
    /// them once scrolling pauses.
    private var heldBack: [TimelineRow]?
    private var retry: Task<Void, Never>?
    /// Set while only the opening window is shown: the next pass fills in
    /// the rows around it, which are neither newer nor a reason to move.
    private var showsOpeningWindow = false
    /// A read of the marker and rows started before the view existed.
    private var opening: TimelineOpening.Pending?
    /// The opening window as laid out and drawn ahead, until the first pass
    /// uses it or finds it doesn't fit.
    private var prepared: TimelineOpening.Prepared?

    /// The marker each view last sent to the store, kept until the write
    /// lands: a view opened again straight after it was left must not read
    /// the marker from before.
    private static var recentMarkers: [RecentKey: LastReadMarker] = [:]
    /// The same for each view's reading place.
    private static var recentPlaces: [RecentKey: ReadingPlace] = [:]
    /// A view of one store. The app has one store, but tests open many at
    /// once with the same views and rows, and must not open on each
    /// other's places.
    private struct RecentKey: Hashable {
        let store: ObjectIdentifier
        let viewID: String
    }
    private let recentKey: RecentKey

    init(store: InfluxStore, viewID: String = SavedView.allID, opening: TimelineOpening.Pending? = nil) {
        self.opening = opening
        self.store = store
        self.viewID = viewID
        tracker = PlaceTracker(viewID: viewID)
        onScreen = store.timelineOnScreen(viewID: viewID)
        recentKey = RecentKey(store: ObjectIdentifier(store), viewID: viewID)
        images.onReady = { [weak self] key in self?.surface?.refreshCell(key) }
        tracker.note = { [weak self] message in self?.note(message) }
        // Whether this timeline waits for the posts before a place that
        // another device sent, for the "Syncing in Progress" screen.
        let id = ObjectIdentifier(self)
        tracker.onWaitsForPostsChange = { waits in
            if waits {
                Self.placesLoading.insert(id)
            } else {
                Self.placesLoading.remove(id)
            }
        }
    }

    func start() {
        guard observation == nil else { return }
        // Before the first pass, which can run within this call when the
        // rows were read ahead, and must tell the store what it shows.
        isOpen = true
        Self.started.add(self)
        let rows = store.observeRows(inView: viewID)
        let store = store, viewID = viewID, pending = opening, recentKey = recentKey
        self.opening = nil
        // A read already done opens the timeline now, with no wait.
        let ready = pending?.ready
        if let ready { begin(with: ready) }
        observation = Task.immediate { [weak self] in
            // Where the timeline opens depends on the marker, so it comes
            // first, with the rows when they were read ahead.
            if ready == nil {
                if let pending {
                    let early = await pending.value
                    self?.begin(with: early)
                } else {
                    async let stored = try? store.lastReadMarker(viewID: viewID)
                    async let place = try? store.readingPlace(viewID: viewID)
                    let opening = await TimelineOpening(marker: Self.furthest(stored, Self.recentMarkers[recentKey]),
                                                        place: PlaceTracker.standing(place, Self.recentPlaces[recentKey]), rows: [])
                    self?.begin(with: opening)
                }
            }
            if let self, self.latest != nil { await self.update() }
            do {
                for try await value in rows {
                    guard let self else { return }
                    if !value.isEmpty { LaunchClock.mark("rows") }
                    // The newest rows supersede any held back.
                    self.heldBack = nil
                    self.retry?.cancel()
                    self.latest = value
                    await self.update()
                }
            } catch {
                // The store only fails here if the database itself does;
                // the timeline keeps what it has.
            }
        }
        let markers = store.observeLastReadMarker(viewID: viewID)
        markerObservation = Task { [weak self] in
            do {
                for try await stored in markers {
                    guard let self else { return }
                    if let stored { self.markerMoved(stored) }
                }
            } catch {
                // As above: the timeline keeps the marker it has.
            }
        }
        let places = store.observeReadingPlace(viewID: viewID)
        placeObservation = Task { [weak self] in
            do {
                for try await stored in places {
                    guard let self else { return }
                    if let stored { self.placeArrived(stored) }
                }
            } catch {
                // As above: the timeline stays where it is.
            }
        }
        if AppSettings.syncDrivePeriod > 0 {
            drive(every: AppSettings.syncDrivePeriod, offset: AppSettings.syncDriveOffset)
        }
    }

    /// Takes the marker the timeline opens on, and any rows read ahead.
    private func begin(with opening: TimelineOpening) {
        LaunchClock.mark("marker")
        // A marker the store delivered first may be further along.
        let opened = Self.furthest(opening.marker, marker)
        openingMarker = opened
        marker = opened
        savedMarkerKey = opened?.mergeKey
        tracker.begin(with: opening.place)
        guard !opening.rows.isEmpty else { return }
        LaunchClock.mark("rows")
        prepared = opening.prepared
        latest = opening.rows
    }

    /// Call when the timeline leaves the screen for good.
    func stop() {
        Self.started.remove(self)
        revealWait?.cancel()
        revealWait = nil
        observation?.cancel()
        observation = nil
        markerObservation?.cancel()
        markerObservation = nil
        placeObservation?.cancel()
        placeObservation = nil
        driving?.cancel()
        driving = nil
        retry?.cancel()
        retry = nil
        markerSave?.cancel()
        markerSave = nil
        tracker.stop()
        savePlace(because: "the timeline closed")
        saveReadingPosition()
        isOpen = false
        readerIsMoving = false
        toldDownTo = nil
        stopHoldingRows()
        monitor?.stop()
    }

    /// Call when the width, display scale, appearance or text size changes.
    func use(_ newEnvironment: RowEnvironment) {
        guard newEnvironment != environment, newEnvironment.width > 0 else { return }
        environment = newEnvironment
        // Runs at once up to its first real wait, so a timeline whose rows
        // are ready shows them in this turn of the main thread.
        Task.immediate { await update() }
    }

    func image(forRow index: Int) -> CGImage? {
        guard index < model.count else { return nil }
        return images.image(for: model.rows[index], geometry: model.geometries[index])
    }

    func accessibilityLabel(forRow index: Int) -> String {
        guard index < model.count else { return "" }
        return RowText.accessibilityLabel(model.rows[index])
    }

    /// The row's VoiceOver text, built only when something asks for it:
    /// formatting its dates on every cell a fling brings on screen costs
    /// main-thread time that nothing reads unless VoiceOver is on.
    func accessibilityLabelSource(forRow index: Int) -> () -> String {
        guard index < model.count else { return { "" } }
        let row = model.rows[index]
        return { RowText.accessibilityLabel(row) }
    }

    /// What a tap at `point`, in content coordinates, reaches. Rows are
    /// bitmaps, so this reads the row's geometry instead of asking views.
    func hit(at point: CGPoint) -> RowHit? {
        guard model.count > 0, let environment = laidOutEnvironment else { return nil }
        let index = model.row(at: point.y)
        let geometry = model.geometries[index]
        let local = CGPoint(x: point.x, y: point.y - model.offsets[index])
        guard local.y >= 0, local.y < geometry.height else { return nil }
        return RowHit.at(local, in: model.rows[index], geometry: geometry, typography: environment.typography)
    }

    /// Remembers the row at `point`, in content coordinates, as the one the
    /// Item menu acts on, and returns it. Called for every click, tap, right
    /// click and long press on a row.
    @discardableResult
    func choose(at point: CGPoint) -> TimelineRow? {
        guard model.count > 0 else { return nil }
        let index = model.row(at: point.y)
        guard point.y >= 0, point.y < model.offsets[index] + model.geometries[index].height else { return nil }
        chosenKey = model.rows[index].mergeKey
        return model.rows[index]
    }

    /// The row the Item menu acts on: the one last chosen while any of it is
    /// on screen, or else the row at the top of the screen.
    var currentRow: TimelineRow? {
        guard model.count > 0, let surface else { return nil }
        let top = surface.viewportTop, bottom = top + surface.viewportHeight
        if let key = chosenKey, let index = model.index(of: key),
           model.offsets[index] + model.geometries[index].height > top, model.offsets[index] < bottom {
            return model.rows[index]
        }
        return model.rows[model.row(at: top)]
    }

    /// The part of `row` on screen, in content coordinates, for anchoring a
    /// share picker; nil when it's off screen.
    func visibleFrame(of row: TimelineRow) -> CGRect? {
        guard let surface, let index = model.index(of: row.mergeKey) else { return nil }
        let visible = CGRect(x: 0, y: surface.viewportTop, width: model.geometries[index].width, height: surface.viewportHeight)
        let frame = model.frame(ofRow: index).intersection(visible)
        return frame.isNull ? nil : frame
    }

    /// What VoiceOver offers on a row besides reading it, the same things a
    /// tap reaches; built only when VoiceOver asks, like the row's label.
    func accessibilityActionsSource(forRow index: Int) -> () -> [(name: String, hit: RowHit)] {
        guard index < model.count else { return { [] } }
        let row = model.rows[index]
        return { RowHit.accessibilityActions(for: row) }
    }

    func scrolled() {
        monitor?.noteScroll()
        prefetch()
        if heldBack != nil { scheduleRetry() }
        noteWhoMoved()
        if surface?.isReaderInput == true { readerIsMoving = true }
        updateUnread()
        lastScroll = .now
        if markerSave == nil { scheduleMarkerSave() }
    }

    // MARK: - Jumps

    var canJumpBack: Bool { jumpOrigin != nil }

    /// The row of the furthest marker this timeline knows of.
    var markerKey: String? { marker?.mergeKey }

    /// Jump to Newest, and the pill: the bottom of the timeline.
    func jumpToNewest() {
        guard let surface, didInitialScroll else { return }
        jump(surface, to: model.totalHeight - surface.viewportHeight)
    }

    /// Jump to Marker: the first row after the last-read marker at the top
    /// of the screen, or the newest rows when nothing comes after it.
    func jumpToMarker() {
        guard let surface, didInitialScroll, model.count > 0 else { return }
        if let index = firstUnreadRow() {
            jump(surface, to: model.offsets[index])
        } else {
            jump(surface, to: model.totalHeight - surface.viewportHeight)
        }
    }

    /// Jump Back: to where the reader was before the last jump. Going back
    /// is a jump too, so doing it twice returns.
    func jumpBack() {
        guard let surface, let origin = jumpOrigin, model.count > 0 else { return }
        let index = model.index(of: origin.key) ?? min(origin.index, model.count - 1)
        jump(surface, to: model.offsets[index] - origin.inset)
    }

    // MARK: - Find in timeline

    /// The rows on screen, for Find in Timeline, and a number that changes
    /// whenever they do.
    var searchRows: (rows: [TimelineRow], version: Int) { (model.rows, model.version) }

    /// Goes to a Find result: the row a quarter of the way down the screen,
    /// with a brief highlight. Like any jump it marks nothing read, and
    /// unlike the others it doesn't move the reading place, so going back
    /// leaves everything as it was. Returns false when the row isn't in
    /// the timeline (any more).
    @discardableResult
    func jump(toResult key: String) -> Bool {
        guard let surface, didInitialScroll, !SyncingGate.holdsTimeline, let index = model.index(of: key) else { return false }
        let top = max(0, min(model.offsets[index] - surface.viewportHeight / 4, model.totalHeight - surface.viewportHeight))
        let distance = abs(top - surface.viewportTop)
        if distance > 1 {
            // A second result in a row still goes back to where the reader
            // was before the first.
            if !offersReturn { jumpOrigin = topVisibleRow() }
            tracker.letGo()
            move(surface, to: top, animated: distance <= surface.viewportHeight * 2)
        }
        // Already there: nowhere new to go back to.
        offersReturn = offersReturn || distance > 1
        surface.flash(model.frame(ofRow: index))
        return true
    }

    /// Goes to the row with merge key `key` as to a Find result: a link
    /// back to a bookmark, from Sammy. A timeline still opening goes there
    /// once the row is on screen; one whose rows are all shown without it
    /// stays where it is.
    func reveal(_ key: String) {
        pendingReveal = key
        revealPending()
    }

    /// Goes to the row a link asked for, if it is on screen now. Asking
    /// stops once every row is shown, found or not.
    private func revealPending() {
        guard let key = pendingReveal, didInitialScroll else { return }
        // A link that launched the app arrives under the syncing screen,
        // which holds every jump: go once it lifts.
        if SyncingGate.holdsTimeline {
            waitForGateToReveal()
            return
        }
        if jump(toResult: key) {
            pendingReveal = nil
        } else if !showsOpeningWindow, model.count > 0 {
            pendingReveal = nil
        }
    }

    /// Tries `pendingReveal` again once the syncing screen has lifted. The
    /// screen stays up 10 s at the most (`SyncingGate.placeLimit`).
    private func waitForGateToReveal() {
        guard revealWait == nil else { return }
        revealWait = Task { [weak self] in
            while SyncingGate.holdsTimeline, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            revealWait = nil
            revealPending()
        }
    }

    /// "Back to where you were", from a Find result.
    func returnFromResult() {
        guard offersReturn else { return }
        jumpBack()
        offersReturn = false
    }

    /// A tap on the iOS status bar. The top is the oldest row, which is
    /// rarely where anyone wants to go, so it goes to the marker when the
    /// reader is back above it, and to the newest rows otherwise.
    func statusBarTapped() {
        guard let surface, didInitialScroll, model.count > 0 else { return }
        if let index = firstUnreadRow(), model.offsets[index] > surface.viewportTop + 1 {
            jumpToMarker()
        } else {
            jumpToNewest()
        }
    }

    /// The first row after the marker, or nil when there is none, or no
    /// marker yet (the timeline opened at the newest rows).
    private func firstUnreadRow() -> Int? {
        marker.flatMap { ReadingPosition.firstRow(after: $0, in: model.rows) }
    }

    // MARK: - Unread

    /// The rows below the screen, all still to read from here, even those
    /// above the marker that the reader went back up past.
    func unreadCount() -> Int {
        lastRowOnScreen().map { model.count - ($0 + 1) } ?? 0
    }

    /// The last row with any part on the screen: the one before the first
    /// whose top is at or below the bottom of the screen. Nil before the
    /// timeline has shown its rows.
    private func lastRowOnScreen() -> Int? {
        guard let surface, didInitialScroll, model.count > 0 else { return nil }
        return model.row(at: surface.viewportTop + surface.viewportHeight - 0.5)
    }

    /// Stops holding rows below this timeline's last screen, once the place
    /// and the marker it saved on closing are in the store. Until then they
    /// are only on their way there, and a refresh in between would go by
    /// the ones before them: a late row could land above the place this
    /// timeline is saving, and never be seen when the view opens there.
    private func stopHoldingRows() {
        let lastPlace = placeWrite, lastMarker = markerWrite
        closing = Task { [weak self, onScreen] in
            var place = lastPlace, marker = lastMarker
            // A place write that ends can start the next: a move made while
            // it ran is saved only when it has answered (`wrote`). So wait
            // until the writes that ended are still the latest.
            while true {
                await place?.value
                await marker?.value
                guard let self, self.placeWrite != place || self.markerWrite != marker else { break }
                place = self.placeWrite
                marker = self.markerWrite
            }
            // Started again meanwhile: what it shows now stands.
            if self?.isOpen != true { onScreen.close() }
        }
    }

    /// How many screens below the screen the row told to the store is
    /// while the reader moves the view.
    static let scrollLead: CGFloat = 2

    /// The row the store keeps new rows below: the last row on screen, or
    /// while the reader is moving the view, the row `scrollLead` screens
    /// further down. A row being stored is placed by what the store was
    /// last told, and shown a moment later; by then a reader scrolling
    /// down has moved on, and a row placed directly below where the screen
    /// was would arrive on it or above it. The scroll's pause tells the
    /// last row on screen again (`scrollPaused`).
    private func rowToHoldBelow(lastOnScreen last: Int?) -> Int? {
        guard let last, let surface, readerIsMoving else { return last }
        return model.row(at: surface.viewportTop + surface.viewportHeight * (1 + Self.scrollLead) - 0.5)
    }

    /// Tells the store the position of the row new rows go below, when it
    /// has changed (ADR 0041). It costs a comparison per scroll event, and
    /// a value kept in memory when the row changes; nothing is written to
    /// the database. A timeline keeps what it last told until it closes,
    /// so one put away behind the lock screen or in a hidden window comes
    /// back to the rows it left.
    private func tellStore(rowToHoldBelow index: Int?) {
        // A timeline that has closed shows nothing, whatever a write that
        // was still under way goes on to do.
        guard isOpen else { return }
        let position = index.map { model.rows[$0].sortDate }
        guard position != toldDownTo else { return }
        toldDownTo = position
        onScreen.show(downTo: position)
    }

    /// Shows the unread count, if it changed: at once with `now`, when it
    /// reaches 0, or 200 ms since the last change, so a fling doesn't
    /// redraw the pill for every row it passes. The pause after scrolling
    /// shows the final count. It runs whenever what is on screen may have
    /// changed, so it also tells the store the last row there.
    private func updateUnread(now: Bool = false) {
        guard let surface else { return }
        let last = lastRowOnScreen()
        tellStore(rowToHoldBelow: rowToHoldBelow(lastOnScreen: last))
        let count = last.map { model.count - ($0 + 1) } ?? 0
        probe()
        guard count != shownUnread else { return }
        let time = ContinuousClock.now
        guard now || count == 0 || unreadShownAt.duration(to: time) >= .milliseconds(200) else { return }
        shownUnread = count
        unreadShownAt = time
        surface.showUnread(count)
    }

    /// Moves to `top` for a jump, keeping where the reader was for Jump
    /// Back. Animated when it's close enough to follow, at once otherwise,
    /// so a long jump doesn't draw every row on the way. A jump to where
    /// the reader already is does nothing, and keeps the place to go back to.
    private func jump(_ surface: any TimelineSurface, to top: CGFloat) {
        // Under the "Syncing in Progress" screen nothing moves the reader:
        // a jump from a stale place would win over the one on its way.
        guard !SyncingGate.holdsTimeline else { return }
        offersReturn = false
        let top = max(0, min(top, model.totalHeight - surface.viewportHeight))
        let distance = abs(top - surface.viewportTop)
        guard distance > 1 else { return }
        jumpOrigin = topVisibleRow()
        // The reader's own choice of where to be, saved as the place. Said
        // before the screen moves: what they had seen is what was on it.
        readerMoved(surface)
        tracker.letGo()
        move(surface, to: top, animated: distance <= surface.viewportHeight * 2)
    }

    func resetDiagnostics() {
        images.resetCounters()
        monitor?.misses = 0
        monitor?.reset()
    }

    // MARK: - Updates

    /// Brings the screen up to date with the latest environment and rows,
    /// one pass at a time. A pass that finds more work waiting goes again.
    private func update() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        while let environment, surface != nil {
            if environment != laidOutEnvironment {
                await relayout(environment)
            } else if let rows = latest {
                latest = nil
                await apply(rows, environment: environment)
            } else {
                return
            }
        }
    }

    /// Lays out every row again, for a new width, text size or appearance.
    /// Rows waiting from the store go in afterwards through `apply`, which
    /// keeps the newer pill's count.
    private func relayout(_ environment: RowEnvironment) async {
        let rows = model.rows
        let start = ContinuousClock.now
        // Nothing to lay out at launch, before the first rows: skip the hop
        // off main, since getting back means waiting for the main thread.
        let geometries = rows.isEmpty ? [] : await Task.detached(priority: .userInitiated) {
            RowLayout.geometries(for: rows, in: environment)
        }.value
        if !rows.isEmpty { LaunchClock.mark("laid out") }
        guard environment == self.environment, let surface else {
            // Superseded while laying out; the next pass covers it.
            return
        }
        let elapsed = start.duration(to: .now)

        let anchor = didInitialScroll ? topVisibleRow() : nil
        let wasAtBottom = isAtBottom
        laidOutEnvironment = environment
        model.replace(rows, geometries: geometries)
        images.use(environment)
        monitor?.exclude()
        monitor?.rows = model.count
        monitor?.layoutMilliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000

        // A content size change can scroll the view; that isn't the reader.
        isPlacing = true
        await surface.show(model.keys, reload: true, reconfigure: [])
        isPlacing = false
        if !didInitialScroll {
            if !rows.isEmpty { didInitialScroll = true; LaunchClock.mark("shown") }
            scrollToReadingPosition()
        } else if wasAtBottom {
            scrollToBottom(animated: false)
        } else if let anchor {
            restore(anchor)
        }
        resolvePlace()
        revealPending()
        updateUnread(now: true)
        prefetch()
    }

    /// Shows a new set of rows from the store with the current layout.
    private func apply(_ allRows: [TimelineRow], environment: RowEnvironment) async {
        // The first rows go in as a window around where the timeline opens,
        // so only those wait on layout; the rest follow in the next pass,
        // held in place like any rows added above and below.
        var rows = allRows
        var ahead: TimelineOpening.Prepared?
        if !didInitialScroll, model.count == 0, !allRows.isEmpty {
            let window = TimelineOpening.window(in: allRows, place: tracker.openingPlace, marker: openingMarker)
            rows = Array(allRows[window])
            if rows.count < allRows.count, latest == nil { latest = allRows }
            // Laid out ahead, if for these exact rows and this environment.
            if let prepared, prepared.environment == environment, prepared.rows == rows {
                ahead = prepared
            } else if let prepared {
                // Says why in the perf run's launch breakdown.
                let e = prepared.environment
                LaunchClock.mark("unprepared w\(Int(e.width))/\(Int(environment.width)) s\(e.scale)/\(environment.scale) "
                    + "d\(e.dark)/\(environment.dark) t\(e.typography.scale)/\(environment.typography.scale) "
                    + "rows\(prepared.rows == rows)")
            }
        }
        prepared = nil
        let fillsOpeningWindow = showsOpeningWindow
        let diff = TimelineDiff(from: model.rows, to: rows)
        guard !diff.isEmpty else { return }
        let jobs = (diff.inserted + diff.changed).map { rows[$0] }
        let laidOut: [RowGeometry]
        if let ahead, jobs.count == rows.count {
            laidOut = ahead.geometries
        } else {
            ahead = nil
            laidOut = await Task.detached(priority: .userInitiated) {
                RowLayout.geometries(for: jobs, in: environment)
            }.value
        }
        if !jobs.isEmpty { LaunchClock.mark("laid out") }
        guard environment == laidOutEnvironment, let surface else {
            if latest == nil { latest = rows }
            return
        }
        var newGeometry: [String: RowGeometry] = [:]
        for (row, geometry) in zip(jobs, laidOut) { newGeometry[row.mergeKey] = geometry }
        // Moving rows above the viewport mid-scroll would mean setting the
        // offset to hold the reader's place, which stops a fling.
        if surface.isScrolling, movesRowsAboveViewport(diff, newGeometry: newGeometry) {
            heldBack = rows
            scheduleRetry()
            return
        }

        // Rows on screen must not change height; hold those changes back.
        let visible = visibleKeys()
        var finalRows: [TimelineRow] = []
        var finalGeometries: [RowGeometry] = []
        var reconfigure: [String] = []
        var didHoldBack = false
        finalRows.reserveCapacity(rows.count)
        finalGeometries.reserveCapacity(rows.count)
        for row in rows {
            let key = row.mergeKey
            if let oldIndex = model.index(of: key) {
                let oldGeometry = model.geometries[oldIndex]
                guard let geometry = newGeometry[key] else {
                    finalRows.append(model.rows[oldIndex])
                    finalGeometries.append(oldGeometry)
                    continue
                }
                if geometry.height != oldGeometry.height, visible.contains(key) {
                    finalRows.append(model.rows[oldIndex])
                    finalGeometries.append(oldGeometry)
                    didHoldBack = true
                } else {
                    finalRows.append(row)
                    finalGeometries.append(geometry)
                    reconfigure.append(key)
                }
            } else if let geometry = newGeometry[key] {
                finalRows.append(row)
                finalGeometries.append(geometry)
            }
        }

        let shown = didInitialScroll ? shownRows() : nil
        model.replace(finalRows, geometries: finalGeometries)
        let anchor = shown.map { rowToHold(from: $0, now: rows) }
        images.forget(diff.removed + diff.inserted.map { rows[$0].mergeKey })
        if let ahead {
            images.seed(ahead.images, rows: Dictionary(uniqueKeysWithValues: zip(rows, ahead.geometries).map { ($0.mergeKey, ($0, $1)) }))
        }
        monitor?.exclude()
        monitor?.rows = model.count
        if !reconfigure.isEmpty {
            var current: [String: (TimelineRow, RowGeometry)] = [:]
            for key in reconfigure {
                if let index = model.index(of: key) { current[key] = (model.rows[index], model.geometries[index]) }
            }
            images.invalidate(reconfigure, visible: visible, rows: current)
        }

        // A content size change can scroll the view; that isn't the reader.
        isPlacing = true
        await surface.show(model.keys, reload: false, reconfigure: reconfigure)
        isPlacing = false
        if !didInitialScroll {
            if !finalRows.isEmpty { didInitialScroll = true; LaunchClock.mark("shown") }
            showsOpeningWindow = rows.count < allRows.count
            scrollToReadingPosition()
        } else if fillsOpeningWindow {
            showsOpeningWindow = false
            if let anchor { restore(anchor) }
        } else if let anchor {
            // Rows added at the bottom included: the pill counts them, and
            // the reader stays on the row they were on.
            restore(anchor)
        }
        resolvePlace()
        revealPending()
        updateUnread(now: true)
        prefetch()
        // Retried from `scrolled()` once the reader scrolls and pauses.
        heldBack = didHoldBack ? rows : nil
    }

    // MARK: - Position

    private struct Anchor {
        var key: String
        var index: Int
        /// The row's top, measured from the top of the viewport.
        var inset: CGFloat
        /// False when the row at the top had moved, and this one is held
        /// in its stead.
        var isTop = true
    }

    /// The rows on the screen and near it before a change of rows, from
    /// which the row to hold through the change is chosen.
    private struct ShownRows {
        /// The rows as they were, with where each began.
        var rows: [TimelineRow]
        var offsets: [CGFloat]
        /// The index the first of `rows` had in the timeline.
        var first: Int
        /// The rows on the screen, as indexes into `rows`.
        var visible: Range<Int>
        var viewportTop: CGFloat
    }

    private func shownRows() -> ShownRows? {
        guard let surface, model.count > 0 else { return nil }
        let visible = model.rows(in: surface.viewportTop, height: surface.viewportHeight)
        let near = max(0, visible.lowerBound - HeldRow.reach)..<min(model.count, visible.upperBound + HeldRow.reach)
        return ShownRows(rows: Array(model.rows[near]), offsets: Array(model.offsets[near]), first: near.lowerBound,
                         visible: (visible.lowerBound - near.lowerBound)..<(visible.upperBound - near.lowerBound),
                         viewportTop: surface.viewportTop)
    }

    /// The row to hold where it was on screen now that the model has the
    /// store's `rows`: the one that was at the top, unless sync moved it
    /// (two devices settling where a post sits), when it's the first row
    /// near it that stayed. Holding a row that moved took the reader with
    /// it, hours back up the timeline (influx-dev #125).
    private func rowToHold(from shown: ShownRows, now rows: [TimelineRow]) -> Anchor {
        let top = shown.visible.lowerBound
        let held = HeldRow.choose(in: shown.rows, visible: shown.visible) { key in
            guard let index = model.index(of: key), index < rows.count, rows[index].mergeKey == key else { return nil }
            return rows[index]
        } ?? top
        if held != top {
            let key = shown.rows[top].mergeKey
            let went = model.index(of: key).map { "moved \(shown.first + top) → \($0)" } ?? "went"
            note("hold: top row \(key) \(went); row \(shown.first + held) is held instead")
        }
        return Anchor(key: shown.rows[held].mergeKey, index: shown.first + held,
                      inset: shown.offsets[held] - shown.viewportTop, isTop: held == top)
    }

    private func topVisibleRow() -> Anchor? {
        guard let surface, model.count > 0 else { return nil }
        let index = model.row(at: surface.viewportTop)
        return Anchor(key: model.rows[index].mergeKey, index: index, inset: model.offsets[index] - surface.viewportTop)
    }

    /// Scrolls so the anchored row is where it was on screen. If it has gone,
    /// the row that took its place stands in.
    private func restore(_ anchor: Anchor) {
        guard let surface, model.count > 0 else { return }
        let index = model.index(of: anchor.key) ?? min(anchor.index, model.count - 1)
        let top = model.offsets[index] - anchor.inset
        // Setting the offset stops a fling, so leave it alone when nothing
        // above the viewport moved.
        guard abs(top - surface.viewportTop) > 0.5 else { return }
        let name = anchor.isTop ? "top row" : "held row"
        if model.index(of: anchor.key) == nil {
            note("hold: \(name) \(anchor.key) went; row \(index) stands in")
        } else if abs(index - anchor.index) > 0 {
            note("hold: \(name) moved \(anchor.index) → \(index), offset \(Int(top - surface.viewportTop)) pt")
        }
        move(surface, to: top, animated: false)
    }

    // MARK: - Diagnostics

    private static let log = Logger(subsystem: "dev.bespokebits.influx", category: "Timeline")
    private static var events = UserDefaults.standard.stringArray(forKey: "InfluxTimelineEvents") ?? []

    /// Logs a move the timeline made on its own, in the sync journal, so
    /// a device says why the reader's place moved days later. The last 60
    /// also stay in UserDefaults (InfluxTimelineEvents), which can be read
    /// from a copy of the app's container without opening its store.
    private func note(_ message: String) {
        let now = Date()
        Self.log.notice("\(message, privacy: .public)")
        Self.events.append("\(now.ISO8601Format()) \(message)")
        if Self.events.count > 60 { Self.events.removeFirst(Self.events.count - 60) }
        UserDefaults.standard.set(Self.events, forKey: "InfluxTimelineEvents")
        Task { [store] in await store.noteInJournal(.timeline, message, at: now) }
    }

    /// Scrolls down 60% of a screen at each whole multiple of `period`
    /// seconds, shifted by `offset`, the way a reader reading on would, so
    /// two devices can be checked against each other with nobody at either.
    /// The scroll goes through the surface like the reader's own, so it
    /// moves the marker the same way.
    private func drive(every period: Int, offset: Int) {
        driving = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date().timeIntervalSince1970
                let next = (floor((now - Double(offset)) / Double(period)) + 1) * Double(period) + Double(offset)
                try? await Task.sleep(for: .seconds(next - now))
                guard let self, let surface = self.surface, self.didInitialScroll, !surface.isScrolling else { continue }
                let bottom = max(0, self.model.totalHeight - surface.viewportHeight)
                let top = min(surface.viewportTop + surface.viewportHeight * 0.6, bottom)
                guard top > surface.viewportTop + 1 else {
                    if AppSettings.driveWraps, surface.viewportTop > 1 {
                        self.note("drive: wrapped to the top")
                        self.readerMoved(surface)
                        surface.setViewportTop(0, animated: false)
                    }
                    continue
                }
                self.note("drive: scrolled down \(Int(top - surface.viewportTop)) pt")
                // Stands in for the reader, so it moves the place as theirs would.
                self.readerMoved(surface)
                surface.setViewportTop(top, animated: true)
            }
        }
    }

    /// When the probe was last written, and the pass that writes the next.
    private var probedAt = ContinuousClock.now - .seconds(1)
    private var probeWrite: Task<Void, Never>?

    /// Writes where this timeline is to UserDefaults (InfluxTimelineProbe) at
    /// most once a second, so a script reading two devices' copies can see
    /// whether they agree: the marker, the top row, the unread count, and
    /// the first rows after the marker.
    private func probe(now: Bool = false) {
        guard probeWrite == nil else { return }
        let due = now ? ContinuousClock.now : probedAt + .seconds(1)
        probeWrite = Task { [weak self] in
            try? await Task.sleep(until: due)
            guard let self else { return }
            self.probeWrite = nil
            self.probedAt = .now
            self.writeProbe()
        }
    }

    private func writeProbe() {
        guard didInitialScroll, model.count > 0 else { return }
        let first = firstUnreadRow() ?? model.count
        let top = topVisibleRow()
        var probe: [String: Any] = [
            "at": Date().ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
            "view": viewID,
            "rows": model.count,
            "unread": unreadCount(),
            "firstUnread": first,
            "next": model.rows[first...].prefix(12).map(\.mergeKey),
        ]
        if let marker {
            probe["marker"] = marker.mergeKey
            probe["markerDate"] = marker.sortDate.ISO8601Format()
        }
        if let place = tracker.place {
            probe["place"] = place.mergeKey
            probe["placeDate"] = place.updatedAt.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        }
        if let top {
            probe["top"] = top.key
            probe["topIndex"] = top.index
            probe["topInset"] = Int(top.inset)
        }
        UserDefaults.standard.set(probe, forKey: "InfluxTimelineProbe")
    }

    private var isAtBottom: Bool {
        guard let surface else { return false }
        return surface.viewportTop >= model.totalHeight - surface.viewportHeight - 8
    }

    /// Opens on the reading place, or on the first row after the last-read
    /// marker, or on the newest rows when there is neither or nothing after
    /// the marker.
    private func scrollToReadingPosition() {
        guard let surface else { return }
        tracker.open(on: Screen(timeline: self, surface: surface), marker: openingMarker)
    }

    /// Saves the reading position once scrolling has paused for 500 ms.
    private func scheduleMarkerSave() {
        markerSave = Task { [weak self] in
            while let self, !Task.isCancelled {
                let due = self.lastScroll + .milliseconds(500)
                if ContinuousClock.now >= due {
                    self.markerSave = nil
                    self.scrollPaused()
                    return
                }
                try? await Task.sleep(until: due)
            }
        }
    }

    /// The reader's scrolling has paused: the place and the marker are
    /// saved, the unread count is final, and the store is told the last
    /// row on screen again. Called 500 ms after the last scroll, and by
    /// tests in its stead.
    func scrollPaused() {
        readerIsMoving = false
        savePlace()
        saveReadingPosition()
        updateUnread(now: true)
    }

    /// Moves the marker to the row the reader has scrolled past: the one
    /// just above the top of the screen, or the last row at the bottom. The
    /// store keeps whichever marker is further along, so scrolling back up
    /// leaves it where it was.
    private func saveReadingPosition() {
        // Only rows the reader scrolled past themselves: opening near the
        // end clamps to the bottom, and appends follow it there, but neither
        // means the reader has read those rows.
        guard let row = pendingMarker else { return }
        pendingMarker = nil
        pendingMarkerWasRead = false
        guard row.mergeKey != savedMarkerKey else { return }
        savedMarkerKey = row.mergeKey
        let store = store, viewID = viewID, recentKey = recentKey
        let marker = LastReadMarker(viewID: viewID, sortDate: row.sortDate, mergeKey: row.mergeKey, updatedAt: Date())
        self.marker = Self.furthest(self.marker, marker)
        Self.recentMarkers[recentKey] = Self.furthest(Self.recentMarkers[recentKey], marker)
        markerWrite = Task { [weak self] in
            defer { if Self.recentMarkers[recentKey] == marker { Self.recentMarkers[recentKey] = nil } }
            do {
                _ = try await store.moveLastReadMarker(viewID: viewID, to: (row.sortDate, row.mergeKey), at: marker.updatedAt)
            } catch {
                // Try again at the next save.
                guard let self, self.savedMarkerKey == row.mergeKey else { return }
                self.savedMarkerKey = nil
                if self.pendingMarker == nil { self.pendingMarker = row }
            }
        }
    }

    /// Takes a marker the store now holds. This device's own saves are never
    /// ahead of `marker`, which they come from, so one that is ahead came
    /// from another device. It moves what Jump to Marker goes to, but not
    /// the reader: the reading place does that.
    private func markerMoved(_ stored: LastReadMarker) {
        // The same row, with a new date because its synced position moved
        // it, or one further along.
        if let marker, stored.mergeKey != marker.mergeKey, !stored.isAhead(of: marker) { return }
        marker = stored
        savedMarkerKey = stored.mergeKey
        guard didInitialScroll else {
            // Not open yet: open on it instead, if there's no place.
            openingMarker = stored
            return
        }
        updateUnread(now: true)
        probe(now: true)
    }

    // MARK: - Reading place

    /// The reading place this timeline holds, for tests.
    var placeKey: String? { tracker.place?.mergeKey }

    /// Saves the row at the top of the screen as the reading place, if the
    /// reader moved since the last one and the move may stand (ADR 0028):
    /// a row more than half above the screen gives way to the next.
    ///
    /// `reason` says what made it save, for the sync journal: a place that
    /// every device takes should be traceable to something the reader did.
    private func savePlace(because reason: String = "the scroll paused") {
        guard didInitialScroll, let surface, model.count > 0 else { return }
        switch tracker.save(from: Screen(timeline: self, surface: surface), at: Date(), because: reason) {
        case .nothing:
            return
        case .stayedLocal:
            // The screen may have gone to the shared place.
            updateUnread(now: true)
            probe(now: true)
        case .save(let save):
            write(save)
        }
    }

    /// Sends a move to the store, which decides whether it stands: the
    /// place may have changed since this timeline last heard of it.
    private func write(_ save: PlaceSave) {
        let place = save.place
        Self.recentPlaces[recentKey] = place
        probe(now: true)
        let store = store, viewID = viewID, recentKey = recentKey
        placeWrite = Task { [weak self] in
            defer { if Self.recentPlaces[recentKey] == place { Self.recentPlaces[recentKey] = nil } }
            let outcome = try? await store.moveReadingPlace(viewID: viewID, to: (place.sortDate, place.mergeKey), at: place.updatedAt,
                                                            knowing: save.knowing, because: save.why)
            self?.wrote(save, as: outcome)
        }
    }

    /// Takes the store's answer to a save; nil when it couldn't write.
    private func wrote(_ save: PlaceSave, as outcome: ReadingPlaceMove?) {
        let screen = didInitialScroll && model.count > 0 ? surface.map { Screen(timeline: self, surface: $0) } : nil
        if tracker.saved(save, as: outcome, on: screen) {
            updateUnread(now: true)
            probe(now: true)
        }
        // The reader may have moved on while the store was writing. A
        // write that failed is tried again at the next pause instead.
        if outcome != nil, let surface, !surface.isScrolling {
            savePlace()
        }
    }

    /// The app is being put away: the phone locked or switched from, the
    /// Mac going to sleep. Saves where the reader is now, without waiting
    /// for the pause after a scroll, and returns once the store has it, so
    /// it can be sent before the app stops running. Left to the pause, a
    /// place moved in the last seconds stayed on this device until it next
    /// opened, and the other device opened on the one before it
    /// (influx-dev #125).
    func saveForLeaving() async {
        guard didInitialScroll else { return }
        let before = tracker.place
        // A save already with the store answers first.
        await placeWrite?.value
        savePlace(because: "the app was put away")
        saveReadingPosition()
        if let place = tracker.place, place != before {
            note("leaving: saved place \(place.mergeKey)")
        }
        await placeWrite?.value
        await markerWrite?.value
    }

    /// Saves every timeline on screen, as `saveForLeaving` does.
    static func saveAllForLeaving() async {
        for timeline in started.allObjects {
            await timeline.saveForLeaving()
        }
    }

    /// The reader is moving the place themselves; call it before the
    /// screen moves.
    private func readerMoved(_ surface: any TimelineSurface) {
        tracker.readerMoved(at: Date(), on: Screen(timeline: self, surface: surface))
    }

    /// Takes a reading place the store now holds: this timeline's own
    /// moves coming back, and the shared place when another device moved
    /// it, which the place rules follow or not.
    private func placeArrived(_ stored: ReadingPlace) {
        guard didInitialScroll, let surface, model.count > 0 else {
            // Not open yet: open on it instead.
            tracker.arrivedBeforeOpening(stored)
            return
        }
        if tracker.arrived(stored, on: Screen(timeline: self, surface: surface)) == .followed {
            updateUnread(now: true)
            probe(now: true)
        }
    }

    /// Lets the place rules go to a place the screen couldn't show yet,
    /// now that the rows have changed.
    private func resolvePlace() {
        guard let surface, didInitialScroll else { return }
        tracker.rowsChanged(on: Screen(timeline: self, surface: surface))
    }

    /// The timeline's screen, as the place rules see and move it.
    @MainActor
    private struct Screen: @MainActor PlaceScreen {
        let timeline: TimelineController
        let surface: any TimelineSurface

        var rows: [TimelineRow] { timeline.model.rows }
        var isScrolling: Bool { surface.isScrolling }
        var topRow: Int { timeline.model.row(at: surface.viewportTop) }

        var rowToSave: Int {
            let model = timeline.model
            var index = model.row(at: surface.viewportTop)
            if index + 1 < model.count, model.offsets[index] + model.geometries[index].height / 2 < surface.viewportTop {
                index += 1
            }
            return index
        }

        /// Whether the screen has the row at its top, and can: it hasn't
        /// stopped at the bottom of the timeline with the row further down.
        func shows(row index: Int) -> Bool {
            let model = timeline.model
            return model.offsets[index] <= model.totalHeight - surface.viewportHeight + 1
                && abs(model.offsets[index] - surface.viewportTop) <= 1
        }

        func isOnScreen(row index: Int) -> Bool {
            let model = timeline.model
            let top = model.offsets[index]
            return top + model.geometries[index].height > surface.viewportTop && top < surface.viewportTop + surface.viewportHeight
        }

        func go(toRow index: Int, to move: PlaceMove) -> Bool {
            timeline.go(toRow: index, to: move, on: surface)
        }

        func goToNewest() {
            timeline.scrollToBottom(animated: false)
        }
    }

    /// Moves the screen for the place rules, and says whether it had to.
    private func go(toRow index: Int, to kind: PlaceMove, on surface: any TimelineSurface) -> Bool {
        if kind == .opening {
            move(surface, to: model.offsets[index], animated: false)
            return true
        }
        let top = max(0, min(model.offsets[index], model.totalHeight - surface.viewportHeight))
        let distance = abs(top - surface.viewportTop)
        guard distance > 1 else { return false }
        if kind == .following {
            jumpOrigin = topVisibleRow()
            // At once under the "Syncing in Progress" screen, where nobody
            // sees it, and where rows still arriving would cut it short.
            move(surface, to: top, animated: !SyncingGate.holdsTimeline && distance <= surface.viewportHeight * 2)
        } else {
            move(surface, to: top, animated: false)
        }
        return true
    }

    /// Whichever of two markers is further along, as the store keeps it.
    private static func furthest(_ a: LastReadMarker?, _ b: LastReadMarker?) -> LastReadMarker? {
        guard let a else { return b }
        guard let b else { return a }
        return b.isAhead(of: a) ? b : a
    }

    /// Moves the viewport on the timeline's behalf, not the reader's.
    private func move(_ surface: any TimelineSurface, to top: CGFloat, animated: Bool) {
        isPlacing = true
        surface.setViewportTop(top, animated: animated)
        isPlacing = false
        lastViewportTop = surface.viewportTop
        // Scroll callbacks of an animated move arrive later. It usually
        // ends at its target, but a surface may clamp it short, so it's
        // over after a second whatever it reports.
        animatingTo = animated ? top : nil
        animationEnd?.cancel()
        animationEnd = animated ? Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.animatingTo == top else { return }
            self.animatingTo = nil
        } : nil
    }

    /// Called on every scroll callback: counts it as the reader's unless
    /// the timeline is moving the viewport itself. A reader who takes hold
    /// of an animated move makes it theirs.
    ///
    /// Reading is going down. Going up only reveals rows that were already
    /// above the screen, so it never counts as reading them: going up from
    /// the newest rows a timeline opened on, the first callbacks are still
    /// at the bottom, and once counted they would hold the marker there.
    /// Going up still moves the pending marker back when nothing was read
    /// since the last save, so a timeline with no marker yet keeps the
    /// place the reader went back to; the store never moves an existing
    /// marker back.
    private func noteWhoMoved() {
        guard let surface else { return }
        let previousTop = lastViewportTop
        lastViewportTop = surface.viewportTop
        guard !isPlacing else { return }
        if let target = animatingTo, !surface.isScrolling {
            if abs(surface.viewportTop - target) < 1 { animatingTo = nil }
            return
        }
        animatingTo = nil
        // Only the reader moves the place. A device coming back after a gap
        // re-anchors as rows load; counted as a move, that would hold off a
        // newer place from another device and then send the old one over it.
        // Any scroll that reaches the timeline under the "Syncing in
        // Progress" screen, by whatever input, isn't the reader's move: the
        // place on its way from another device still gets followed.
        if surface.isReaderInput, !SyncingGate.holdsTimeline {
            tracker.readerScrolled(at: Date(), on: Screen(timeline: self, surface: surface))
            // Scrolling on from a Find result: here is where they are now.
            offersReturn = false
        }
        let readingOn = previousTop.map { surface.viewportTop > $0 } ?? false
        guard let row = rowScrolledPast(readingOn: readingOn) else { return }
        let scrolledPast = LastReadMarker(viewID: viewID, sortDate: row.sortDate, mergeKey: row.mergeKey, updatedAt: Date())
        if readingOn {
            // Reading on and then back up before the save keeps the furthest.
            if !pendingMarkerWasRead || pendingMarker.map({ !ReadingPosition.isAfter($0, scrolledPast) }) ?? true {
                pendingMarker = row
                pendingMarkerWasRead = true
            }
            // Kept here as well as saved, so a jump finds it before the save.
            marker = Self.furthest(marker, scrolledPast)
        } else if !pendingMarkerWasRead {
            pendingMarker = row
        }
    }

    /// The row just above the top of the screen, or the last row once the
    /// reader has read down to the bottom.
    private func rowScrolledPast(readingOn: Bool) -> TimelineRow? {
        guard didInitialScroll, let surface, model.count > 0 else { return nil }
        let index = readingOn && isAtBottom ? model.count - 1 : model.row(at: surface.viewportTop) - 1
        return index >= 0 ? model.rows[index] : nil
    }

    private func scrollToBottom(animated: Bool) {
        guard let surface else { return }
        move(surface, to: max(0, model.totalHeight - surface.viewportHeight), animated: animated)
    }

    /// Whether `diff` would move the top visible row: a row above it is
    /// added, removed, resized, or moved past it. The row stays put only if
    /// exactly the same rows, at the same heights, sit above it.
    private func movesRowsAboveViewport(_ diff: TimelineDiff, newGeometry: [String: RowGeometry]) -> Bool {
        guard let anchor = topVisibleRow() else { return false }
        guard let newIndex = diff.rows.firstIndex(where: { $0.mergeKey == anchor.key }),
              newIndex == anchor.index
        else { return true }
        for row in diff.rows[..<newIndex] {
            guard let oldIndex = model.index(of: row.mergeKey), oldIndex < anchor.index else { return true }
            if let geometry = newGeometry[row.mergeKey], geometry.height != model.geometries[oldIndex].height {
                return true
            }
        }
        return false
    }

    /// Tries the held-back rows again once scrolling has paused for 300 ms.
    /// A pass that finds the view still scrolling holds them back again.
    private func scheduleRetry() {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, let rows = self.heldBack else { return }
            self.heldBack = nil
            if self.latest == nil { self.latest = rows }
            await self.update()
        }
    }

    private func visibleKeys() -> Set<String> {
        guard let surface else { return [] }
        return Set(model.rows(in: surface.viewportTop, height: surface.viewportHeight).map { model.rows[$0].mergeKey })
    }

    private func prefetch() {
        guard let surface, model.count > 0 else { return }
        images.prefetch(around: model.rows(in: surface.viewportTop, height: surface.viewportHeight), in: model)
        monitor?.misses = images.misses
    }
}
