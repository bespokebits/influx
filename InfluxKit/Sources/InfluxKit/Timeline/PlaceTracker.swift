import Foundation

// The rules for the reader's place on one timeline: when the row at the top
// of the screen is saved as the place, when a place from another device is
// followed, and when the screen has caught up with a place it couldn't show
// at first.
//
// They know nothing of views, timers or the store: the timeline says what
// happened, the rules ask the screen what it shows through `PlaceScreen`
// and tell it where to go, and what should be saved comes back as a value.
// The same rules then run in tests on several pretend devices at once
// (ADR 0027).
//
// One rule decides whose move the shared place takes (ADR 0028). A move
// replaces the shared place only if the reader had seen that place on this
// device's screen before they moved, or if the move goes further along
// than it. Any other move was made from a screen that hadn't caught up: it
// stays on this device, and the screen is taken to the shared place. So a
// scroll on a device still showing an old place can't take every other
// device back to it, and going back on purpose, from the place itself,
// still does. The store applies the same rule again when it writes, since
// the place may have changed by then, and when two devices' moves meet.

/// What the place rules ask of a timeline's screen, and how they move it.
public protocol PlaceScreen {
    /// The rows shown, in timeline order.
    var rows: [TimelineRow] { get }
    /// True while the reader drags or the view decelerates.
    var isScrolling: Bool { get }
    /// The index of the row at the top of the screen.
    var topRow: Int { get }
    /// The index of the row a save names: the row at the top, or the next
    /// one when more than half of the top row is above the screen.
    var rowToSave: Int { get }
    /// Whether the row at `index` is at the top of the screen now, and
    /// could be: not further down a screen stopped at the bottom of the
    /// timeline.
    func shows(row index: Int) -> Bool
    /// Whether any of the row at `index` is on the screen.
    func isOnScreen(row index: Int) -> Bool
    /// Scrolls so that the row at `index` is at the top of the screen, or
    /// as near as the bottom of the timeline allows. Returns whether the
    /// screen had to move.
    @discardableResult
    func go(toRow index: Int, to move: PlaceMove) -> Bool
    /// Scrolls to the newest rows, for a timeline with nowhere to open.
    func goToNewest()
}

/// Why the place rules move the screen.
public enum PlaceMove: Sendable, Hashable {
    /// The timeline is opening: the move is made whether or not the screen
    /// is already there, and at once.
    case opening
    /// The shared place is somewhere else: another device moved it, or a
    /// move here didn't stand. The reader can go back to where they were,
    /// and a short move may be animated.
    case following
    /// The row of a place the screen couldn't show has arrived, or another
    /// row now stands in for it. At once.
    case resolving
}

/// A move to send to the store, which decides whether it stands.
public struct PlaceSave: Sendable, Hashable {
    /// The place as it will be if the move stands.
    public var place: ReadingPlace
    /// What the reader had seen when they moved, for the store's rule.
    public var knowing: PlaceKnowledge
    /// The index of the place's row, and how many rows the screen had.
    public var row: Int
    public var count: Int
    /// What made the timeline save it.
    public var reason: String

    /// The reason as the sync journal records it.
    public var why: String { "\(reason), row \(row) of \(count)" }
}

/// What came of asking for the place to be saved.
public enum PlaceSaveOutcome: Sendable, Hashable {
    /// The reader hasn't moved, is on the place already, or an earlier
    /// save is still with the store: ask again when it has answered.
    case nothing
    /// The move doesn't stand, and stays on this device. The screen went
    /// to the shared place, unless it had been taken there before.
    case stayedLocal
    /// The store's to write; tell `saved` what it answered.
    case save(PlaceSave)
}

/// What a timeline did with a place the store delivered.
public enum PlaceArrival: Sendable, Hashable {
    /// The place this timeline already holds.
    case ignored
    /// The reader here is scrolling, or has moved and not yet paused: the
    /// screen stays, and their pause decides between the two.
    case stayed
    /// The screen went to the place, or was already on it.
    case followed
}

/// The reading place of one timeline. Not safe to share between threads:
/// the app keeps one per timeline on the main actor.
public final class PlaceTracker {
    public let viewID: String

    /// The shared reading place as this timeline knows it: the one the
    /// store last delivered, or a move of its own that the store is
    /// writing.
    public private(set) var place: ReadingPlace?
    /// The reading place the timeline opens on, when it has one.
    public private(set) var openingPlace: ReadingPlace?
    /// Whether the place the timeline opens on came from another device
    /// after this one had read its own.
    private var openingPlaceArrived = false
    /// The last shared place whose row was on this screen, or that the
    /// reader set here. A move made from it was made knowing it.
    public private(set) var seen: ReadingPlace.Identity?
    /// The last shared place the screen was taken to, whether or not its
    /// row was here to show: the screen is taken to each place once, and
    /// after that the reader may stay elsewhere.
    private var wentTo: ReadingPlace.Identity?
    /// Whether the reader has moved since the place was last saved,
    /// followed or opened on, so the next pause saves where they are.
    public private(set) var moved = false
    /// When the reader last moved, by this device's clock. A saved place
    /// is stamped with it, for the journal.
    private var readerMovedAt = Date.distantPast
    /// A move the store is writing, and the place it replaces. The next
    /// save waits for the store's answer, so two can't land out of order.
    private var saving: (place: ReadingPlace, replaced: ReadingPlace?)?

    /// A place followed or opened on that the screen can't show at its top
    /// yet: its own row isn't here, so the timeline went to the row nearest
    /// its date, or it's among the newest rows, so the screen stopped at
    /// the bottom with older rows above it. Rows still on their way can
    /// arrive in between; the timeline then goes to the place's row, not
    /// the row that was at the top, unless the reader has moved since.
    public private(set) var unresolved: ReadingPlace? {
        didSet { if unresolved == nil { waitsForPosts = false } }
    }
    /// Whether `unresolved` came from another device: the posts before it
    /// may still be on their way here, so the "Syncing in Progress" screen
    /// waits for them while a fetch runs (influx-dev #119).
    public private(set) var waitsForPosts = false {
        didSet { if waitsForPosts != oldValue { onWaitsForPostsChange?(waitsForPosts) } }
    }
    public var onWaitsForPostsChange: ((Bool) -> Void)?
    /// Takes the lines these rules write to the sync journal.
    public var note: (String) -> Void = { _ in }

    public init(viewID: String) {
        self.viewID = viewID
    }

    // MARK: Opening

    /// Takes the place the store held when the timeline was read. One the
    /// store delivered since may have replaced it.
    public func begin(with stored: ReadingPlace?) {
        let opened = Self.standing(stored, place)
        openingPlace = opened
        place = opened
    }

    /// Opens the screen on the reading place, or on the first row after
    /// the last-read marker, or on the newest rows when there is neither or
    /// nothing after the marker.
    public func open(on screen: some PlaceScreen, marker: LastReadMarker?) {
        let rows = screen.rows
        guard let index = ReadingPosition.openingRow(in: rows, place: openingPlace, marker: marker) else {
            screen.goToNewest()
            return
        }
        screen.go(toRow: index, to: .opening)
        guard let openingPlace else { return }
        took(openingPlace, in: rows)
        if !shows(openingPlace, at: index, on: screen) {
            unresolved = openingPlace
            waitsForPosts = openingPlaceArrived
        }
    }

    // MARK: The reader

    /// The reader is moving the screen themselves: a scroll, a jump, or
    /// anything standing in for one. Call it before a jump moves the
    /// screen, so what they had seen is what was there when they chose to.
    public func readerMoved(at now: Date, on screen: some PlaceScreen) {
        // Once per move: the place's row on the screen as the reader sets
        // off is a place they have seen.
        if !moved { noteSeen(on: screen) }
        moved = true
        readerMovedAt = now
    }

    /// The reader scrolled: where they are now is theirs, whatever place
    /// the screen was still on its way to.
    public func readerScrolled(at now: Date, on screen: some PlaceScreen) {
        readerMoved(at: now, on: screen)
        if let pending = unresolved {
            note("place \(pending.mergeKey) let go: the reader scrolled")
            unresolved = nil
        }
    }

    /// Stops going to a place the screen couldn't show yet, because the
    /// reader chose to be somewhere else.
    public func letGo() {
        unresolved = nil
    }

    // MARK: Saving

    /// Saves the row at the top of the screen as the reading place, if the
    /// reader moved since the last one and the move may stand: they had
    /// seen the shared place here, or the row is further along than it.
    ///
    /// `reason` says what made it save, for the sync journal: a place that
    /// every device takes should be traceable to something the reader did.
    public func save(from screen: some PlaceScreen, at now: Date, because reason: String) -> PlaceSaveOutcome {
        let rows = screen.rows
        guard moved, !rows.isEmpty, saving == nil else { return .nothing }
        moved = false
        let index = screen.rowToSave
        let row = rows[index]
        let known = place
        if let known, known.mergeKey == row.mergeKey {
            // Back on the place itself: nothing to save, and they see it.
            seen = known.identity
            return .nothing
        }
        // The place's row on the screen where they stopped counts too.
        noteSeen(on: screen)
        let hasSeen = known.map { seen == $0.identity } ?? true
        if let known, !hasSeen, !isFurtherAlong(index, than: known, in: rows) {
            note("move to \(row.mergeKey) stays on this device: the reader hadn't seen the place \(known.mergeKey), move \(known.move), and this isn't further along")
            goToPlaceOnce(on: screen)
            return .stayedLocal
        }
        // Stamped with when the reader moved here, not when the save runs,
        // which can be long after: it waits for the pause, and on a phone
        // put away mid-scroll, until the app comes back (influx-dev #125).
        let stamp = min(readerMovedAt == .distantPast ? now : readerMovedAt, now)
        let moving = ReadingPlace(viewID: viewID, mergeKey: row.mergeKey, sortDate: row.sortDate, updatedAt: stamp,
                                  move: (known?.move ?? 0) + 1)
        saving = (moving, known)
        place = moving
        seen = moving.identity
        wentTo = moving.identity
        return .save(PlaceSave(place: moving, knowing: .seen(hasSeen ? known?.identity : nil),
                               row: index, count: rows.count, reason: reason))
    }

    /// The store's answer to a save, or nil if it couldn't write. Returns
    /// whether the screen moved: a move the store didn't let stand, because
    /// the place had changed by the time it wrote, takes the screen to the
    /// shared place. Ask for a save again afterwards, in case the reader
    /// moved on while the store was writing.
    @discardableResult
    public func saved(_ save: PlaceSave, as outcome: ReadingPlaceMove?, on screen: (some PlaceScreen)?) -> Bool {
        guard let sent = saving, sent.place == save.place else { return false }
        saving = nil
        // The store may have delivered a place since; only a move this
        // timeline still holds is corrected here.
        let holds = place == sent.place
        switch outcome {
        case .moved(let stored), .unchanged(let stored):
            if holds { take(stored) }
            return false
        case .stayedLocal(let current):
            guard holds else { return false }
            place = current
            note("move to \(save.place.mergeKey) stays on this device: the place had moved to \(current.mergeKey), move \(current.move), by the time it was saved")
            guard let screen, !moved else { return false }
            return goToPlaceOnce(on: screen)
        case nil:
            // Tried again at the next pause or when the timeline stops,
            // even if the reader is still on this row.
            guard holds else { return false }
            place = sent.replaced
            seen = sent.replaced?.identity
            wentTo = sent.replaced?.identity
            moved = true
            return false
        }
    }

    /// Whether the row at `index` is further along the timeline than the
    /// row that stands for `known` here. A place past the end of this
    /// device's rows is further along than all of them.
    private func isFurtherAlong(_ index: Int, than known: ReadingPlace, in rows: [TimelineRow]) -> Bool {
        guard let found = ReadingPosition.find(known, in: rows) else { return true }
        return index > found.index
    }

    // MARK: A place from the store

    /// Takes a reading place the store now holds, before the timeline has
    /// shown its first rows: it opens there instead.
    public func arrivedBeforeOpening(_ stored: ReadingPlace) {
        if let place, place.mergeKey == stored.mergeKey {
            take(stored)
            return
        }
        openingPlace = stored
        openingPlaceArrived = true
        place = stored
    }

    /// Takes a reading place the store now holds. This timeline's own
    /// moves come back here and change nothing. Any other is the shared
    /// place now, and the timeline goes there, so open devices keep up
    /// with each other. Not while the reader here is scrolling, or has
    /// moved and not yet paused: where they stop is then weighed against
    /// it, by the rule.
    public func arrived(_ stored: ReadingPlace, on screen: some PlaceScreen) -> PlaceArrival {
        if let place, place.mergeKey == stored.mergeKey {
            take(stored)
            return .ignored
        }
        place = stored
        guard !screen.isScrolling, !moved else {
            note("no follow: place \(stored.mergeKey), scrolling \(screen.isScrolling), moved \(moved)")
            // Their pause saves where they are, or takes them to it.
            moved = true
            return .stayed
        }
        go(to: stored, on: screen)
        return .followed
    }

    /// The same row under the store's own record of it: a move of this
    /// timeline's as the store wrote it, or the same place moved again.
    private func take(_ stored: ReadingPlace) {
        guard let held = place else { return }
        if seen == held.identity { seen = stored.identity }
        if wentTo == held.identity { wentTo = stored.identity }
        if unresolved?.identity == held.identity { unresolved = stored }
        place = stored
    }

    /// Takes the screen to the shared place, if it hasn't been taken there
    /// before. Returns whether the screen moved.
    @discardableResult
    private func goToPlaceOnce(on screen: some PlaceScreen) -> Bool {
        guard let place, wentTo != place.identity, !screen.isScrolling else { return false }
        return go(to: place, on: screen)
    }

    /// Takes the screen to `place`; returns whether it had to move.
    @discardableResult
    private func go(to place: ReadingPlace, on screen: some PlaceScreen) -> Bool {
        let rows = screen.rows
        guard let index = ReadingPosition.row(at: place, in: rows) else { return false }
        let top = screen.topRow
        let went = screen.go(toRow: index, to: .following)
        if went {
            note("follow: place \(place.mergeKey), move \(place.move), row \(top) → \(index) of \(rows.count)")
        }
        took(place, in: rows)
        // Settled only once the screen is seen with the row at its top. A
        // move can fall short of it: rows that arrive while it animates
        // hold whatever row is at the top by then, and a view can stop
        // before its target. Rows arriving later would then hold that row
        // and push the place off the screen (influx-dev #119).
        unresolved = shows(place, at: index, on: screen) ? nil : place
        waitsForPosts = unresolved != nil
        return went
    }

    /// The screen's rows changed, or were laid out again. Goes to the row
    /// of a place that a row stood in for, now it's here, or, while it
    /// isn't, to the row that stands in for it now. Rows that arrive before
    /// the place's own row move which row that is: on opening, the rest of
    /// the timeline filling in around the first rows put newer rows after
    /// the one that stood in, and holding that row left the screen short of
    /// both the place and the newest rows (influx-dev #125).
    public func rowsChanged(on screen: some PlaceScreen) {
        defer { if !moved { noteSeen(on: screen) } }
        guard let pending = unresolved else { return }
        guard !moved, pending.mergeKey == place?.mergeKey else {
            note("place \(pending.mergeKey) let go: moved \(moved), place now \(place?.mergeKey ?? "none")")
            unresolved = nil
            return
        }
        let rows = screen.rows
        guard !screen.isScrolling, let index = ReadingPosition.row(at: pending, in: rows) else { return }
        if screen.go(toRow: index, to: .resolving) {
            if rows[index].mergeKey == pending.mergeKey {
                note("follow: place \(pending.mergeKey) arrived, row \(index) of \(rows.count)")
            } else {
                note("follow: place \(pending.mergeKey) not here yet, row \(index) of \(rows.count) stands in")
            }
        }
        took(pending, in: rows)
        // Still among the newest rows, older ones can still arrive above
        // it; and a move the view didn't finish is tried again next time.
        if shows(pending, at: index, on: screen) { unresolved = nil }
    }

    /// The timeline is leaving the screen for good.
    public func stop() {
        unresolved = nil
    }

    /// The screen was taken to `place`. The reader has seen it if the row
    /// that stands for it is here: its own row, or, on a device that
    /// doesn't have the post, the first row after where it would be. A
    /// place past the end of this device's rows hasn't been reached, so a
    /// device with fewer posts can't take one with more back
    /// (influx-dev #131). An animated move counts from its start: the
    /// reader is shown the row a moment later.
    private func took(_ place: ReadingPlace, in rows: [TimelineRow]) {
        wentTo = place.identity
        if let found = ReadingPosition.find(place, in: rows), found.standing != .pastTheEnd {
            seen = place.identity
        }
    }

    /// Notes that the reader has seen the shared place, if the row that
    /// stands for it has come onto the screen some other way: the reader
    /// scrolled to it, or its post arrived where they already were.
    private func noteSeen(on screen: some PlaceScreen) {
        guard let place, seen != place.identity,
              let found = ReadingPosition.find(place, in: screen.rows), found.standing != .pastTheEnd,
              screen.isOnScreen(row: found.index) else { return }
        seen = place.identity
    }

    /// Whether the screen shows `place` where it should be now: its own
    /// row, at `index`, at the top of the screen, where nothing still to
    /// arrive can come between them.
    private func shows(_ place: ReadingPlace, at index: Int, on screen: some PlaceScreen) -> Bool {
        screen.rows[index].mergeKey == place.mergeKey && screen.shows(row: index)
    }

    /// Whichever of two places stands over the other, as the store would
    /// have it.
    public static func standing(_ a: ReadingPlace?, _ b: ReadingPlace?) -> ReadingPlace? {
        guard let a else { return b }
        guard let b else { return a }
        return b.supersedes(a) ? b : a
    }
}
