// The Timeline menu's jumps and the unread pill, driven through the shared controller with
// a stand-in for the platform view.
import CoreGraphics
import Foundation
import InfluxKit
import Testing
@testable import Influx

@MainActor
@Test func jumpsGoToTheNewestRowsTheMarkerAndBack() async throws {
    let (timeline, surface, _) = try await openTimeline()
    let model = timeline.model
    let bottom = model.totalHeight - surface.viewportHeight
    // No marker yet, so it opened on the newest rows, with nowhere to go back to.
    #expect(isNear(surface.viewportTop, bottom))
    #expect(!timeline.canJumpBack)

    // The reader reads from the top down to the middle, then goes back up
    // to look at something older; the marker stays where they had got to.
    let middle = model.count / 2, early = model.count / 10
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[middle])
    surface.scroll(to: model.offsets[early])

    timeline.jumpToMarker()
    #expect(isNear(surface.viewportTop, model.offsets[middle]))
    #expect(timeline.canJumpBack)
    timeline.jumpBack()
    #expect(isNear(surface.viewportTop, model.offsets[early]))
    // Going back is a jump too, so going back again returns.
    timeline.jumpBack()
    #expect(isNear(surface.viewportTop, model.offsets[middle]))

    timeline.jumpToNewest()
    #expect(isNear(surface.viewportTop, bottom))
    timeline.jumpBack()
    #expect(isNear(surface.viewportTop, model.offsets[middle]))
}

@MainActor
@Test func aJumpThatGoesNowhereKeepsThePlaceToGoBackTo() async throws {
    let (timeline, surface, _) = try await openTimeline()
    let model = timeline.model
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[model.count / 2])
    timeline.jumpToNewest()
    // Already at the newest rows: nothing moves, and Jump Back still
    // returns to the middle.
    timeline.jumpToNewest()
    timeline.jumpBack()
    #expect(isNear(surface.viewportTop, model.offsets[model.count / 2]))
}

/// The iOS status bar goes to the marker when the reader is back above it,
/// and to the newest rows otherwise, never to the oldest row at the top.
@MainActor
@Test func theStatusBarGoesToTheMarkerOrTheNewestRows() async throws {
    let (timeline, surface, _) = try await openTimeline()
    let model = timeline.model
    let bottom = model.totalHeight - surface.viewportHeight
    let middle = model.count / 2
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[middle])

    // At the marker already: on to the newest rows.
    timeline.statusBarTapped()
    #expect(isNear(surface.viewportTop, bottom))

    // Back above the marker: down to it.
    surface.scroll(to: model.offsets[model.count / 10])
    timeline.statusBarTapped()
    #expect(isNear(surface.viewportTop, model.offsets[middle]))
}

/// Reading on and then back up before the save still saves how far the
/// reader got.
@MainActor
@Test func readingOnThenBackUpSavesTheFurthestRow() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    let readUpTo = model.rows[middle - 1].mergeKey
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[middle])
    surface.scroll(to: model.offsets[model.count / 10])
    timeline.stop()
    var saved: LastReadMarker?
    for _ in 0..<200 where saved?.mergeKey != readUpTo {
        try await Task.sleep(for: .milliseconds(10))
        saved = try await store.lastReadMarker(viewID: timeline.viewID)
    }
    #expect(saved?.mergeKey == readUpTo)
}

/// Only the reader's own scrolling moves the marker: jumping to the newest
/// rows and leaving doesn't mark everything read.
@MainActor
@Test func jumpingToTheNewestRowsLeavesTheMarker() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    let readUpTo = model.rows[middle - 1].mergeKey
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[middle])
    timeline.jumpToNewest()
    timeline.stop()

    var saved: LastReadMarker?
    for _ in 0..<200 where saved?.mergeKey != readUpTo {
        try await Task.sleep(for: .milliseconds(10))
        saved = try await store.lastReadMarker(viewID: timeline.viewID)
    }
    #expect(saved?.mergeKey == readUpTo)
}

/// Going up from the newest rows a timeline opened on reads nothing: the
/// first steps are still at the bottom, and once counted they held the
/// marker on the last row, so the view reopened at the bottom. With
/// no marker yet, the place the reader went back to is the one kept.
@MainActor
@Test func goingUpFromTheNewestRowsKeepsThatPlace() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let bottom = model.totalHeight - surface.viewportHeight
    let target = model.count / 2
    // Up a few points at a time at first, as a drag starts.
    var top = bottom
    for step: CGFloat in [2, 4, 8, 16, 40, 80] {
        top -= step
        surface.scroll(to: top)
    }
    surface.scroll(to: model.offsets[target] + 300)
    surface.scroll(to: model.offsets[target])
    timeline.stop()

    let place = model.rows[target - 1].mergeKey
    var saved: LastReadMarker?
    for _ in 0..<200 where saved?.mergeKey != place {
        try await Task.sleep(for: .milliseconds(10))
        saved = try await store.lastReadMarker(viewID: timeline.viewID)
    }
    #expect(saved?.mergeKey == place)
}

/// Going back up after reading on keeps the furthest row read, even in a
/// timeline that had no marker yet.
@MainActor
@Test func goingUpAfterReadingDownToTheBottomKeepsTheLastRow() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let bottom = model.totalHeight - surface.viewportHeight
    surface.scroll(to: 0)
    surface.scroll(to: bottom)
    surface.scroll(to: bottom - 1000)
    timeline.stop()

    let last = try #require(model.rows.last).mergeKey
    var saved: LastReadMarker?
    for _ in 0..<200 where saved?.mergeKey != last {
        try await Task.sleep(for: .milliseconds(10))
        saved = try await store.lastReadMarker(viewID: timeline.viewID)
    }
    #expect(saved?.mergeKey == last)
}

// MARK: - Unread pill

/// The pill counts the rows below the screen, and shows the count once
/// scrolling pauses.
@MainActor
@Test func theUnreadPillCountsRowsBelowTheScreenAfterTheMarker() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    // Opened on the newest rows: nothing below.
    #expect(surface.unread == 0)

    // Read from the top down to the middle: everything below the screen
    // is unread.
    let middle = model.count / 2
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[middle])
    let below = model.count - (model.row(at: surface.viewportTop + surface.viewportHeight - 0.5) + 1)
    try await waitFor { surface.unread == below }

    // Back up: every row below the screen is left to read from here, so
    // the count goes up.
    surface.scroll(to: model.offsets[model.count / 10])
    let belowEarly = model.count - (model.row(at: surface.viewportTop + surface.viewportHeight - 0.5) + 1)
    #expect(belowEarly > below)
    try await waitFor { surface.unread == belowEarly }

    // New rows arriving below add to it.
    let last = try #require(model.rows.last)
    let before = model.count
    _ = try await store.insert(SeedFeed.newer(count: 20, after: last.sortDate, batch: 1))
    try await waitFor { model.count == before + 20 && surface.unread == belowEarly + 20 }

    // The pill's jump to the newest rows leaves nothing below.
    timeline.jumpToNewest()
    try await waitFor { surface.unread == 0 }
}

// MARK: - The reading place

/// The row at the top of the screen is saved as the place once scrolling
/// pauses, going back up as well as down.
@MainActor
@Test func thePlaceFollowsTheReaderBothWays() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2, early = model.count / 10
    surface.scroll(to: model.offsets[middle])
    try await waitForPlace(model.rows[middle].mergeKey, in: store)
    surface.scroll(to: model.offsets[early])
    try await waitForPlace(model.rows[early].mergeKey, in: store)
    // The marker stays where the reader had read to.
    #expect(timeline.markerKey == model.rows[middle - 1].mergeKey)
}

/// A place another device moved to takes a still reader there, forward
/// or back, and Jump Back returns.
@MainActor
@Test func aPlaceFromAnotherDeviceMovesAStillReaderEitherWay() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await waitFor { timeline.placeKey == model.rows[middle].mergeKey }
    // Stored too, before another device's place arrives: a save still on
    // its way would land after it and put this row back.
    try await waitForPlace(model.rows[middle].mergeKey, in: store)

    let ahead = model.rows[middle + 30]
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (ahead.sortDate, ahead.mergeKey), at: Date().addingTimeInterval(1))
    try await waitFor { isNear(surface.viewportTop, model.offsets[middle + 30]) }
    #expect(timeline.canJumpBack)

    let back = model.rows[10]
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (back.sortDate, back.mergeKey), at: Date().addingTimeInterval(2))
    try await waitFor { isNear(surface.viewportTop, model.offsets[10]) }
    timeline.jumpBack()
    #expect(isNear(surface.viewportTop, model.offsets[middle + 30]))
    // Going back was the reader's own move, so it's the place now.
    try await waitForPlace(ahead.mergeKey, in: store)
}

/// A place whose row isn't here yet goes to the nearest row, and then to
/// its own row once that arrives.
@MainActor
@Test func aPlaceWhoseRowArrivesLaterIsReachedWhenItDoes() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await waitFor { timeline.placeKey == model.rows[middle].mergeKey }
    // Stored too, before another device's place arrives: a save still on
    // its way would land after it and put this row back.
    try await waitForPlace(model.rows[middle].mergeKey, in: store)

    let last = try #require(model.rows.last)
    let newer = SeedFeed.newer(count: 20, after: last.sortDate, batch: 1)
    let target = newer[10]
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (target.publishedAt, target.mergeKey), at: Date().addingTimeInterval(1))
    // Not here yet: the newest row stands in.
    try await waitFor { isNear(surface.viewportTop, model.totalHeight - surface.viewportHeight) }

    _ = try await store.insert(newer)
    try await waitFor { model.index(of: target.mergeKey).map { isNear(surface.viewportTop, model.offsets[$0]) } ?? false }
}

/// A place whose own row this device doesn't have yet stands in at the
/// row nearest its date. Rows that arrive before its own row moves that
/// row, and the screen goes with it rather than holding the row that
/// stood in before. On opening, the rest of the timeline filling in
/// around the first rows did this: the place stood in at the last of those
/// rows, the rows after them went in below it, and the screen stayed 31
/// rows above the newest (influx-dev #125).
@MainActor
@Test func aPlaceWithoutItsRowFollowsTheRowStandingInForIt() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await waitForPlace(model.rows[middle].mergeKey, in: store)

    // The other device's place, a day on from this device's newest row,
    // and not on this device yet: the newest row stands in.
    let last = try #require(model.rows.last)
    let target = try #require(SeedFeed.newer(count: 1, after: last.sortDate.addingTimeInterval(86_400), batch: 1).first)
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (target.publishedAt, target.mergeKey), at: Date().addingTimeInterval(1))
    try await waitFor { isNear(surface.viewportTop, model.totalHeight - surface.viewportHeight) }

    // Posts from before the place arrive after the row standing in, but
    // not the place's own: the newest of them stands in now.
    let between = SeedFeed.newer(count: 40, after: last.sortDate, batch: 2)
    #expect(between.allSatisfy { $0.publishedAt < target.publishedAt })
    _ = try await store.insert(between)
    try await waitFor { model.index(of: between[39].mergeKey) != nil }
    try await waitFor { isNear(surface.viewportTop, model.totalHeight - surface.viewportHeight) }

    // Nothing the reader did, so nothing goes up over the place.
    try await Task.sleep(for: .milliseconds(800))
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.mergeKey == target.mergeKey)
}

/// A place among this device's newest rows can't be brought to the top of
/// the screen, which stops at the bottom with older rows above it. When
/// the rows this device was missing before it arrive, the screen goes on
/// to the place rather than holding the row that was at the top, and no
/// older place is sent over it (influx-dev #111).
@MainActor
@Test func aPlaceAmongTheNewestRowsIsKeptAsMissingRowsArriveBeforeIt() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    // Taller than any one row, so at the bottom of the timeline the row at
    // the top of the screen is an older one, as on a phone with short rows.
    surface.viewportHeight = 3_000
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await waitForPlace(model.rows[middle].mergeKey, in: store)

    // The other device's place, a day on from this device's newest row.
    let last = try #require(model.rows.last)
    let target = try #require(SeedFeed.newer(count: 1, after: last.sortDate.addingTimeInterval(86_400), batch: 1).first)
    _ = try await store.insert([target])
    try await waitFor { model.rows.last?.mergeKey == target.mergeKey }
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (target.publishedAt, target.mergeKey), at: Date().addingTimeInterval(1))
    try await waitFor { isNear(surface.viewportTop, model.totalHeight - surface.viewportHeight) }
    let top = model.row(at: surface.viewportTop)
    try #require(model.rows[top].mergeKey != target.mergeKey)

    // The posts in between, which this device hadn't fetched yet.
    let between = SeedFeed.newer(count: 40, after: last.sortDate, batch: 2)
    #expect(between.allSatisfy { $0.publishedAt < target.publishedAt })
    _ = try await store.insert(between)
    try await waitFor { model.index(of: between[39].mergeKey) != nil }
    try await waitFor { isNear(surface.viewportTop, model.totalHeight - surface.viewportHeight) }
    #expect(model.row(at: surface.viewportTop) > model.index(of: between[0].mergeKey) ?? .max)

    // Nothing the reader did, so nothing goes up over the place.
    try await Task.sleep(for: .milliseconds(800))
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.mergeKey == target.mergeKey)
}

/// A place from another device that the screen can't show at its top yet
/// waits for the posts before it, which holds the "Syncing in Progress"
/// screen while a fetch runs; once newer rows let it reach the top, it no
/// longer does (influx-dev #119).
@MainActor
@Test func aPlaceAmongTheNewestRowsWaitsForThePostsBeforeIt() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    surface.viewportHeight = 3_000
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await waitForPlace(model.rows[middle].mergeKey, in: store)
    #expect(!timeline.waitsForPostsBeforePlace)

    let last = try #require(model.rows.last)
    let target = try #require(SeedFeed.newer(count: 1, after: last.sortDate.addingTimeInterval(86_400), batch: 1).first)
    _ = try await store.insert([target])
    try await waitFor { model.rows.last?.mergeKey == target.mergeKey }
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (target.publishedAt, target.mergeKey), at: Date().addingTimeInterval(1))
    try await waitFor { timeline.waitsForPostsBeforePlace }

    // Enough newer rows that the place can be at the top.
    _ = try await store.insert(SeedFeed.newer(count: 40, after: target.publishedAt, batch: 2))
    try await waitFor { model.index(of: target.mergeKey).map { isNear(surface.viewportTop, model.offsets[$0]) } ?? false }
    #expect(!timeline.waitsForPostsBeforePlace)
}

/// A follow that stops short of the place, as when rows arrive while it
/// animates and the timeline holds the row at the top by then, still ends
/// on the place, and no older row is sent over it (influx-dev #119).
@MainActor
@Test func aFollowCutShortStillEndsOnThePlace() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await waitForPlace(model.rows[middle].mergeKey, in: store)

    // Close enough that the follow animates, and the animation hasn't run
    // when the next rows go in.
    surface.animationsLand = false
    let ahead = model.rows[middle + 1]
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (ahead.sortDate, ahead.mergeKey), at: Date().addingTimeInterval(1))
    try await waitFor { surface.pendingAnimation != nil }
    #expect(isNear(surface.viewportTop, model.offsets[middle]))

    // A relayout holds the row at the top, which ends the animation there.
    timeline.use(RowEnvironment(width: 375, scale: 2, dark: false, typography: Typography()))
    try await waitFor { surface.pendingAnimation == nil && isNear(surface.viewportTop, model.offsets[middle + 1]) }
    #expect(model.rows[model.row(at: surface.viewportTop)].mergeKey == ahead.mergeKey)

    // Nothing the reader did, so nothing goes up over the place.
    try await Task.sleep(for: .milliseconds(800))
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.mergeKey == ahead.mergeKey)
}

/// A place arrives from another device while the reader here is mid-move.
/// They aren't taken anywhere until they stop. Where they stop is short of
/// that place, which this screen never showed, so the move stays on this
/// device and the screen is taken to the place (ADR 0028). Before, the
/// later move won by the clock and took every device back with it.
@MainActor
@Test func aMoveMadeWithoutSeeingThePlaceStaysHereAndTheScreenGoesToIt() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])

    let other = model.rows[middle + 30]
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (other.sortDate, other.mergeKey))
    #expect(isNear(surface.viewportTop, model.offsets[middle]))
    try await waitFor { isNear(surface.viewportTop, model.offsets[middle + 30]) }
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.mergeKey == other.mergeKey)

    // Going back from the place itself is the reader's choice, and stands.
    surface.scroll(to: model.offsets[middle])
    try await waitForPlace(model.rows[middle].mergeKey, in: store)
    #expect(isNear(surface.viewportTop, model.offsets[middle]))
}

/// The same, but the reader stops beyond the place that arrived: reading
/// on stands, seen or not.
@MainActor
@Test func readingOnPastAPlaceThatArrivedMidMoveStands() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])

    let behind = model.rows[middle - 30]
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (behind.sortDate, behind.mergeKey))
    try await waitForPlace(model.rows[middle].mergeKey, in: store)
    #expect(isNear(surface.viewportTop, model.offsets[middle]))
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.move == 2)
}

/// A place this device hasn't reached: its post isn't here, and is dated
/// after every row that is, as when another device has fetched further.
/// The newest rows stand in. Scrolling about there moves nothing anywhere
/// else, and the reader isn't pulled back each time they stop
/// (influx-dev #131).
@MainActor
@Test func aDeviceThatHasNotReachedThePlaceCannotMoveIt() async throws {
    let (timeline, surface, store) = try await openTimeline { store in
        try await store.moveReadingPlace(viewID: SavedView.allID, to: (Date().addingTimeInterval(86_400), "post:not-here-yet"))
    }
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await Task.sleep(for: .milliseconds(900))
    #expect(isNear(surface.viewportTop, model.offsets[middle]))
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.mergeKey == "post:not-here-yet")
    #expect(try await store.pendingSyncChanges().filter { $0.type == .readingPlace }.count == 1)
}

/// The view moving itself, as when a device comes back after a gap and
/// re-anchors while rows load, isn't the reader moving: a newer place from
/// another device still takes the reader there, and the old place isn't
/// sent over it.
@MainActor
@Test func aViewThatMovesItselfStillFollowsAnotherDevice() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await waitForPlace(model.rows[middle].mergeKey, in: store)

    surface.nudge(to: model.offsets[middle - 20])
    let newer = model.rows[middle + 30]
    try await store.moveReadingPlace(viewID: timeline.viewID, to: (newer.sortDate, newer.mergeKey), at: Date().addingTimeInterval(1))
    try await waitFor { isNear(surface.viewportTop, model.offsets[middle + 30]) }
    // The pause after the nudge must not send the old row back up.
    try await Task.sleep(for: .milliseconds(800))
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.mergeKey == newer.mergeKey)
}

/// A save runs after the move, once the scroll has paused, and is stamped
/// with when the reader moved, not when it ran (influx-dev #125).
@MainActor
@Test func aSaveIsStampedWithWhenTheReaderMoved() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    let before = Date()
    surface.scroll(to: model.offsets[middle])
    let moved = Date()
    try await waitForPlace(model.rows[middle].mergeKey, in: store)
    let saved = try #require(try await store.readingPlace(viewID: timeline.viewID))
    // It waited 500 ms for the pause. The store keeps milliseconds, so a
    // stamp from the same millisecond as `before` reads a little earlier.
    #expect(saved.updatedAt >= before.addingTimeInterval(-0.001))
    #expect(saved.updatedAt <= moved.addingTimeInterval(0.25))
    #expect(saved.move == 1)
}

/// A phone locked straight after a scroll: the place is saved as the app
/// is put away, without the pause after the scroll, and is ready to go to
/// iCloud. Left to the pause, it stayed on the phone and the Mac opened on
/// the place before it (influx-dev #125).
@MainActor
@Test func leavingSavesThePlaceAtOnce() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    let before = Date()
    surface.scroll(to: model.offsets[middle])
    let moved = Date()
    await TimelineController.saveAllForLeaving()
    let saved = try #require(try await store.readingPlace(viewID: timeline.viewID))
    #expect(saved.mergeKey == model.rows[middle].mergeKey)
    // Stamped with the move, for the journal, to the millisecond.
    #expect(saved.updatedAt >= before.addingTimeInterval(-0.001))
    #expect(saved.updatedAt <= moved.addingTimeInterval(0.25))
    #expect(try await store.pendingSyncChanges().contains { $0.type == .readingPlace })
}

/// Leaving a timeline the reader hasn't moved writes no place: opening and
/// following aren't moves, and a place written for them would be the
/// latest and win everywhere.
@MainActor
@Test func leavingWithoutMovingSavesNoPlace() async throws {
    let (timeline, surface, store) = try await openTimeline()
    surface.nudge(to: timeline.model.offsets[timeline.model.count / 2])
    await TimelineController.saveAllForLeaving()
    #expect(try await store.readingPlace(viewID: timeline.viewID) == nil)
    #expect(try await store.pendingSyncChanges().contains { $0.type == .readingPlace } == false)
}

/// The reader reads on at the Mac. The phone hasn't synced, and still
/// shows where it was; a scroll there, short of the Mac's place, is saved
/// and waits to go up. When the two meet, neither device knew of the
/// other's move, and the one further along stands: both end on the Mac's
/// place. Decided by the clock, the phone's scroll was the later move and
/// took both devices back to old posts (influx-dev #125).
@MainActor
@Test func aScrollOnAPhoneThatHadNotCaughtUpLosesToReadingOnAtTheMac() async throws {
    let server = InMemorySyncServer()
    let mac = try InfluxStore.inMemory()
    try await SeedFeed.load(into: mac, count: 200)
    let (timeline, surface, phone) = try await openTimeline()
    let phoneSync = SyncCoordinator(store: phone, server: server)
    let macSync = SyncCoordinator(store: mac, server: server)
    try await macSync.sync()
    try await phoneSync.sync()

    let model = timeline.model
    let middle = model.count / 2
    let later = model.rows[middle + 30]
    try await mac.moveReadingPlace(viewID: timeline.viewID, to: (later.sortDate, later.mergeKey))
    try await macSync.sync()

    surface.scroll(to: model.offsets[middle])
    try await waitForPlace(model.rows[middle].mergeKey, in: phone)
    for _ in 0..<2 {
        try await phoneSync.sync()
        try await macSync.sync()
    }
    #expect(try await mac.readingPlace(viewID: timeline.viewID)?.mergeKey == later.mergeKey)
    try await waitForPlace(later.mergeKey, in: phone)
    try await waitFor { isNear(surface.viewportTop, model.offsets[middle + 30]) }
}

/// A marker from another device moves what Jump to Marker goes to, not
/// the reader.
@MainActor
@Test func aMarkerFromAnotherDeviceLeavesTheReaderWhereTheyAre() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle])
    try await waitFor { timeline.markerKey == model.rows[middle - 1].mergeKey }

    let read = model.rows[middle + 29]
    try await store.moveLastReadMarker(viewID: timeline.viewID, to: (read.sortDate, read.mergeKey))
    try await waitFor { timeline.markerKey == read.mergeKey }
    #expect(isNear(surface.viewportTop, model.offsets[middle]))
    timeline.jumpToMarker()
    #expect(isNear(surface.viewportTop, model.offsets[middle + 30]))
}

/// The row at the top of the reader's screen, mostly scrolled past, is one
/// another device stored first and put far earlier. Sync moves it there.
/// The screen stays on the rows that didn't move: it used to hold the row
/// at the top wherever it went, which took the reader back to posts they
/// had read hours before, and their next pause there became the place on
/// every device (influx-dev #125).
@MainActor
@Test func aTopRowThatSyncMovesAwayLeavesTheReaderWhereTheyWere() async throws {
    let server = InMemorySyncServer()
    let mac = try InfluxStore.inMemory()
    try await SeedFeed.load(into: mac, count: 200)
    let (timeline, surface, phone) = try await openTimeline()
    let model = timeline.model
    let source = try #require(SeedFeed.sources.first { $0.kind != .rss })
    let newest = try #require(model.rows.last).sortDate
    func boosted(by booster: String, at date: Date) -> Item {
        Item(sourceID: source.id, remoteID: "boost-\(booster)", kind: .post, mergeKey: "post:moved",
             authorName: "Ana Ruiz", authorHandle: "@ana", body: "Boosted",
             publishedAt: model.rows[0].sortDate, fetchedAt: date, sortDate: date, boostedBy: booster)
    }
    // The Mac saw the post first, boosted early on, and says where it put it.
    try await mac.insert([boosted(by: "Ben", at: model.rows[10].sortDate.addingTimeInterval(1))])
    try await SyncCoordinator(store: mac, server: server).sync()
    // The phone hasn't heard: it sees a later boost, among its newest rows.
    let count = model.count
    try await phone.insert([boosted(by: "Cal", at: newest.addingTimeInterval(60))])
    try await phone.insert(SeedFeed.newer(count: 20, after: newest.addingTimeInterval(120), batch: 1))
    try await waitFor { model.count == count + 21 }
    let index = try #require(model.index(of: "post:moved"))
    try #require(index == count)

    // The reader has read most of the way past it, so the place is the next row.
    let next = model.rows[index + 1].mergeKey
    surface.scroll(to: model.offsets[index] + model.geometries[index].height * 0.75)
    try await waitForPlace(next, in: phone)
    let inset = model.offsets[index + 1] - surface.viewportTop

    try await SyncCoordinator(store: phone, server: server).sync()
    try await waitFor { (model.index(of: "post:moved") ?? index) < 20 }
    let nextIndex = try #require(model.index(of: next))
    #expect(isNear(model.offsets[nextIndex] - surface.viewportTop, inset))
    // Nothing was saved for it: the place is still the row they had reached.
    try await Task.sleep(for: .milliseconds(700))
    #expect(try await phone.readingPlace(viewID: timeline.viewID)?.mergeKey == next)
}

/// A timeline opens on its reading place, even with a marker elsewhere.
@MainActor
@Test func aTimelineOpensOnItsReadingPlace() async throws {
    let (timeline, surface, _) = try await openTimeline { store in
        let rows = try await store.rows(inView: SavedView.allID)
        try await store.moveLastReadMarker(viewID: SavedView.allID, to: (rows[150].sortDate, rows[150].mergeKey))
        try await store.moveReadingPlace(viewID: SavedView.allID, to: (rows[60].sortDate, rows[60].mergeKey))
    }
    try await waitFor { isNear(surface.viewportTop, timeline.model.offsets[60]) }
}

/// New rows at the bottom don't carry a reader there with them: the pill
/// counts them instead.
@MainActor
@Test func newRowsDoNotMoveAReaderAtTheBottom() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let bottom = model.totalHeight - surface.viewportHeight
    #expect(isNear(surface.viewportTop, bottom))
    let last = try #require(model.rows.last)
    let before = model.count
    _ = try await store.insert(SeedFeed.newer(count: 20, after: last.sortDate, batch: 1))
    try await waitFor { model.count == before + 20 && surface.unread == 20 }
    #expect(isNear(surface.viewportTop, bottom))
}

// MARK: - Support


/// Waits up to 10 s for `condition`, which the pause after scrolling or an
/// update from the store makes true.
// MARK: - Find in timeline

/// A Find result is a jump that marks nothing read and leaves the reading
/// place, highlights the row, and offers the way back, which returns.
@MainActor
@Test func aFindResultMarksNothingAndGoesBack() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let early = model.count / 10, late = model.count * 9 / 10
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[early])
    try await waitForPlace(model.rows[early].mergeKey, in: store)
    let marker = timeline.markerKey

    #expect(timeline.jump(toResult: model.rows[late].mergeKey))
    #expect(model.row(at: surface.viewportTop + surface.viewportHeight / 4) == late)
    #expect(surface.flashed == [model.frame(ofRow: late)])
    #expect(timeline.offersReturn)
    // Past the save pause: still nothing read, and the place hasn't moved.
    try await Task.sleep(for: .milliseconds(700))
    #expect(timeline.markerKey == marker)
    #expect(try await store.readingPlace(viewID: SavedView.allID)?.mergeKey == model.rows[early].mergeKey)

    timeline.returnFromResult()
    #expect(isNear(surface.viewportTop, model.offsets[early]))
    #expect(!timeline.offersReturn)
    timeline.stop()
    try await Task.sleep(for: .milliseconds(100))
    #expect(try await store.lastReadMarker(viewID: SavedView.allID)?.mergeKey == marker)
    #expect(try await store.readingPlace(viewID: SavedView.allID)?.mergeKey == model.rows[early].mergeKey)
}

/// Scrolling on from a result makes that the reading place, and the way
/// back goes. A second result in a row still goes back to before the first.
@MainActor
@Test func scrollingOnFromAFindResultMakesItThePlace() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let early = model.count / 10, middle = model.count / 2, late = model.count * 9 / 10
    surface.scroll(to: model.offsets[early])
    try await waitForPlace(model.rows[early].mergeKey, in: store)

    timeline.jump(toResult: model.rows[late].mergeKey)
    timeline.jump(toResult: model.rows[middle].mergeKey)
    #expect(timeline.offersReturn)
    let resultTop = surface.viewportTop
    surface.scroll(to: resultTop + 40)
    #expect(!timeline.offersReturn)
    // Saved once scrolling pauses: a row by the result, not the old place.
    let near = Set(model.rows[(middle - 2)...(middle + 2)].map(\.mergeKey))
    var saved: ReadingPlace?
    for _ in 0..<1000 where !(saved.map { near.contains($0.mergeKey) } ?? false) {
        try await Task.sleep(for: .milliseconds(10))
        saved = try await store.readingPlace(viewID: SavedView.allID)
    }
    #expect(saved.map { near.contains($0.mergeKey) } == true)
    // Jump Back still knows where the reader was before the first result.
    timeline.jumpBack()
    #expect(isNear(surface.viewportTop, model.offsets[early]))
}

/// A result already on screen where it would go isn't a move, so there's
/// nothing to go back to; one no longer in the timeline goes nowhere.
@MainActor
@Test func aFindResultWhereTheReaderIsOffersNoWayBack() async throws {
    let (timeline, surface, _) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: model.offsets[middle] - surface.viewportHeight / 4)
    timeline.jumpToNewest()
    surface.scroll(to: model.offsets[middle] - surface.viewportHeight / 4)
    timeline.jump(toResult: model.rows[middle].mergeKey)
    #expect(!timeline.offersReturn)
    #expect(surface.flashed.count == 1)
    #expect(!timeline.jump(toResult: "no such row"))
}

/// A link back to a bookmark asks a timeline still opening to go to its row:
/// it goes there, highlighted, once the row is on screen. A row that isn't
/// in the timeline leaves the reader where they are.
@MainActor
@Test func aRevealBeforeTheTimelineOpensGoesToTheRow() async throws {
    let store = try InfluxStore.inMemory()
    try await SeedFeed.load(into: store, count: 200)
    let rows = try await store.rows(inView: SavedView.allID)
    let late = rows.count * 9 / 10
    let timeline = TimelineController(store: store)
    let surface = FakeSurface()
    surface.timeline = timeline
    timeline.surface = surface
    timeline.reveal(rows[late].mergeKey)
    timeline.start()
    timeline.use(RowEnvironment(width: 390, scale: 2, dark: false, typography: Typography()))
    let model = timeline.model
    for _ in 0..<500 where surface.flashed.isEmpty || model.count != rows.count {
        try await Task.sleep(for: .milliseconds(10))
    }
    let index = try #require(model.index(of: rows[late].mergeKey))
    // On screen, highlighted once. (Rows filled in around the opening
    // window after the jump move its frame, but not what is on screen.)
    #expect(model.offsets[index] >= surface.viewportTop)
    #expect(model.offsets[index] < surface.viewportTop + surface.viewportHeight)
    #expect(surface.flashed.count == 1)

    let top = surface.viewportTop
    timeline.reveal("no such row")
    #expect(surface.viewportTop == top)
    #expect(surface.flashed.count == 1)
}

/// Typing searches the rows on screen off the main thread; choosing a
/// result closes Find and takes the timeline there.
@MainActor
@Test func findSearchesTheTimelineAndChoosingAResultGoesThere() async throws {
    let (timeline, surface, _) = try await openTimeline()
    let jumps = TimelineJumps()
    jumps.attach(timeline)
    let find = TimelineFind(jumps: jumps)
    find.begin()
    #expect(find.isPresented)
    #expect(!find.showsResults)
    find.query = "hairlines serifs"
    #expect(find.showsResults)
    try await waitFor { find.isCurrent }
    let expected = try SearchableRows(timeline.model.rows).results(for: TimelineSearch("hairlines serifs"))
    #expect(!expected.isEmpty)
    #expect(find.results.map(\.mergeKey) == expected.map(\.mergeKey))
    #expect(find.words == ["hairlines", "serifs"])

    // A word nothing has.
    find.query = "zyzzyva"
    try await waitFor { find.isCurrent }
    #expect(find.results.isEmpty)

    find.query = "hairlines"
    try await waitFor { find.isCurrent && !find.results.isEmpty }
    let chosen = try #require(find.results.first)
    find.choose(chosen)
    #expect(!find.isPresented)
    #expect(find.query.isEmpty)
    try await waitFor { jumps.offersReturn }
    let index = try #require(timeline.model.index(of: chosen.mergeKey))
    #expect(timeline.model.row(at: surface.viewportTop + surface.viewportHeight / 4) == index || isNear(surface.viewportTop, timeline.model.totalHeight - surface.viewportHeight))
}

/// Find's prepared rows belong to one timeline: another view's timeline,
/// even with the same row version, is searched afresh, so a row it doesn't
/// show is never offered. An open search runs again when rows change.
@MainActor
@Test func findSearchesTheTimelineShowingNow() async throws {
    let (all, _, store) = try await openTimeline()
    let jumps = TimelineJumps()
    jumps.attach(all)
    let find = TimelineFind(jumps: jumps)
    find.begin()
    find.query = "hairlines"
    try await waitFor { find.isCurrent && !find.results.isEmpty }
    let everywhere = find.results.map(\.mergeKey)

    let bookmarks = TimelineController(store: store, viewID: SavedView.bookmarksID)
    let surface = FakeSurface()
    surface.timeline = bookmarks
    bookmarks.surface = surface
    bookmarks.start()
    bookmarks.use(RowEnvironment(width: 390, scale: 2, dark: false, typography: Typography()))
    let expected = try await store.rows(inView: SavedView.bookmarksID).count
    try await waitFor { bookmarks.model.count == expected }
    jumps.detach(all)
    jumps.attach(bookmarks)
    find.rowsChanged()
    let shown = Set(bookmarks.model.rows.map(\.mergeKey))
    try await waitFor { find.isCurrent && find.results.allSatisfy { shown.contains($0.mergeKey) } }
    #expect(find.results.count < everywhere.count)
    #expect(find.results.allSatisfy { shown.contains($0.mergeKey) })
    bookmarks.stop()
}

/// A result's text starts near the match when it's far in, and the
/// matching words are bold, ignoring case and accents.
@MainActor
@Test func aResultShowsTheTextAroundItsMatch() {
    let long = String(repeating: "word ", count: 40) + "the Café is open"
    let excerpt = FindResultRow.excerpt(of: ["", long], words: ["cafe"])
    #expect(excerpt.hasPrefix("…"))
    #expect(excerpt.hasSuffix("the Café is open"))
    #expect(excerpt.count < 70)
    let marked = FindResultRow.marked("the Café is open", ["cafe"])
    let bold = marked.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(marked[$0.range].characters) }
    #expect(bold == ["Café"])
    // Whole words only, as the search matches.
    let cats = FindResultRow.marked("A category of cats, and one cat.", ["cat"])
    let boldCats = cats.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }.map { String(cats[$0.range].characters) }
    #expect(boldCats == ["cat"])
    #expect(FindResultRow.firstMatch(of: "#swift", in: "Loving #SwiftUI and #swift") != nil)
    #expect(FindResultRow.firstMatch(of: "cat", in: "category") == nil)
}

@MainActor
private func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 where !condition() {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(condition())
}

/// Waits up to 10 s for the store's reading place to be the row `key`.
@MainActor
private func waitForPlace(_ key: String, in store: InfluxStore) async throws {
    var saved: ReadingPlace?
    for _ in 0..<1000 where saved?.mergeKey != key {
        try await Task.sleep(for: .milliseconds(10))
        saved = try await store.readingPlace(viewID: SavedView.allID)
    }
    #expect(saved?.mergeKey == key)
}

/// A switch a test flips while the timeline reads it.
@MainActor
private final class Flag {
    var on: Bool
    init(_ on: Bool) { self.on = on }
}

/// Which catch-up a test says is under way.
@MainActor
private final class Box {
    var value: Int?
    init(_ value: Int?) { self.value = value }
}

/// Within a point: holding a row in place adds heights up again.
/// A post from the sample feed's first source, dated an hour before the
/// timeline's first row and fetched now: a row that arrives late.
private func latePost(_ id: String, in store: InfluxStore) async throws -> Item {
    let first = try #require(try await store.rows(inView: SavedView.allID).first)
    return Item(sourceID: first.sourceID, remoteID: id, kind: .post, mergeKey: id, authorName: "Late", authorHandle: "@late",
                body: id, publishedAt: first.sortDate.addingTimeInterval(-3_600), fetchedAt: Date())
}

/// Waits until the timeline shows the row `key`, and returns its index.
@MainActor
private func index(of key: String, in timeline: TimelineController) async throws -> Int {
    for _ in 0..<500 where timeline.model.index(of: key) == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    return try #require(timeline.model.index(of: key))
}


/// The timeline tells the store the last row on its screen, so a row that
/// a refresh brings late lands directly below it: not above the screen,
/// not between two rows on it, and not at the bottom of the timeline
/// (ADR 0041). The rows on screen stay where they are.
@MainActor
@Test func aLateRowLandsDirectlyBelowTheLastRowOnScreen() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[model.count / 2])
    // The scroll pauses, as it does half a second after the last scroll.
    timeline.scrollPaused()
    let top = surface.viewportTop
    let visible = model.rows(in: top, height: surface.viewportHeight)
    let shown = model.rows[visible].map(\.mergeKey)
    let count = model.count
    try #require(visible.upperBound < count - 10)

    try await store.insert([latePost("late-1", in: store)], belowTheLine: true)
    #expect(try await index(of: "late-1", in: timeline) == visible.upperBound)
    #expect(model.count == count + 1)
    #expect(model.rows[visible].map(\.mergeKey) == shown)
    #expect(isNear(surface.viewportTop, top))
    #expect(timeline.unreadCount() == count + 1 - visible.upperBound)

    // The reader scrolls on a screen: the next late row lands below what
    // they see now.
    surface.scroll(to: top + surface.viewportHeight)
    // The scroll pauses, as it does half a second after the last scroll.
    timeline.scrollPaused()
    let later = model.rows(in: surface.viewportTop, height: surface.viewportHeight)
    try await store.insert([latePost("late-2", in: store)], belowTheLine: true)
    #expect(try await index(of: "late-2", in: timeline) == later.upperBound)
    timeline.stop()
}

/// While the reader scrolls, the screen moves on before a row being stored
/// is shown. A late row then lands two screens further down, so that it is
/// still below the screen when it arrives, not on it or above it.
@MainActor
@Test func aLateRowLandsFurtherDownWhileTheReaderScrolls() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    surface.scroll(to: 0)
    // Still scrolling when the row arrives.
    surface.isScrolling = true
    surface.isReaderInput = true
    surface.setViewportTop(model.offsets[model.count / 3], animated: false)
    let top = surface.viewportTop, height = surface.viewportHeight
    let ahead = model.row(at: top + height * (1 + TimelineController.scrollLead) - 0.5)
    try #require(ahead > model.rows(in: top, height: height).upperBound)
    try #require(ahead < model.count - 10)

    try await store.insert([latePost("late-1", in: store)], belowTheLine: true)
    #expect(try await index(of: "late-1", in: timeline) == ahead + 1)
    // The reader goes on a screen and a half before it is shown: it is
    // still below what they see.
    #expect(model.offsets[ahead + 1] >= top + height * 2.5)
    timeline.stop()
}

/// A reader at the bottom of the timeline sees what they always did: a late
/// row lands below the newest row.
@MainActor
@Test func aLateRowLandsBelowTheNewestRowForAReaderAtTheBottom() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let count = timeline.model.count
    let top = surface.viewportTop
    try await store.insert([latePost("late-1", in: store)], belowTheLine: true)
    #expect(try await index(of: "late-1", in: timeline) == count)
    #expect(isNear(surface.viewportTop, top))
    timeline.stop()
}

/// At launch the rows are read ahead, and the timeline shows its first
/// screen in the call that starts it. It tells the store what that screen
/// shows then, not at the reader's first scroll: a row that arrives late
/// before they touch it still lands below the screen.
@MainActor
@Test func aTimelineOpenedFromRowsReadAheadHoldsALateRowBeforeAnyScroll() async throws {
    let store = try InfluxStore.inMemory()
    try await SeedFeed.load(into: store, count: 200)
    let all = try await store.rows(inView: SavedView.allID)
    // The reader left off in the middle.
    let place = all[all.count / 2]
    _ = try await store.moveReadingPlace(viewID: SavedView.allID, to: (place.sortDate, place.mergeKey))
    let environment = RowEnvironment(width: 390, scale: 2, dark: false, typography: Typography())
    let pending = TimelineOpening.read(from: store, expected: (environment, 600))
    _ = await pending.value
    let timeline = TimelineController(store: store, opening: pending)
    let surface = FakeSurface()
    surface.timeline = timeline
    timeline.surface = surface
    timeline.start()
    timeline.use(environment)
    for _ in 0..<500 where timeline.model.count != all.count {
        try await Task.sleep(for: .milliseconds(10))
    }
    let model = timeline.model
    try #require(model.count == all.count)
    try #require(isNear(surface.viewportTop, model.offsets[all.count / 2]))
    let visible = model.rows(in: surface.viewportTop, height: surface.viewportHeight)

    try await store.insert([latePost("late-1", in: store)], belowTheLine: true)
    #expect(try await index(of: "late-1", in: timeline) == visible.upperBound)
    timeline.stop()
}

/// A timeline that has closed holds no row down: only what its reader read
/// and where they stopped does, so a late row lands directly below the row
/// the view will open on.
@MainActor
@Test func aClosedTimelineHoldsOnlyByWhatWasReadAndWhereItStopped() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let middle = model.count / 2
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[middle])
    let place = model.rows[middle].mergeKey
    // The scroll pauses, as it does half a second after the last scroll.
    timeline.scrollPaused()
    let last = model.rows(in: surface.viewportTop, height: surface.viewportHeight).upperBound - 1
    let before = try await store.insert([latePost("late-0", in: store)], belowTheLine: true)
    try #require(before == 1)
    timeline.stop()
    // It holds its screen until the place and marker it saved are stored,
    // so no row can go by the ones from before them.
    await timeline.closing?.value
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.mergeKey == place)
    #expect(try await store.lastReadMarker(viewID: timeline.viewID)?.mergeKey == model.rows[middle - 1].mergeKey)

    try await store.insert([latePost("late-1", in: store)], belowTheLine: true)
    let rows = try await store.rows(inView: SavedView.allID).map(\.mergeKey)
    // While it was open: below the last row on its screen. Closed: below
    // the row it will open on.
    #expect(rows.firstIndex(of: "late-1") == middle + 1)
    #expect(rows.firstIndex(of: "late-0") == last + 2)
}

/// A timeline that closes while a place is still being written, after the
/// reader has moved again, saves that last move only when the first write
/// has answered. It holds its screen until that write has landed too.
@MainActor
@Test func aClosingTimelineWaitsForTheLastPlaceItSaves() async throws {
    let (timeline, surface, store) = try await openTimeline()
    let model = timeline.model
    let first = model.count / 3, last = model.count / 2
    surface.scroll(to: 0)
    surface.scroll(to: model.offsets[first])
    // The pause starts the write of the first place; the reader moves on
    // and the timeline closes before it has answered.
    timeline.scrollPaused()
    surface.scroll(to: model.offsets[last])
    timeline.stop()
    await timeline.closing?.value
    #expect(try await store.readingPlace(viewID: timeline.viewID)?.mergeKey == model.rows[last].mergeKey)

    try await store.insert([latePost("late-1", in: store)], belowTheLine: true)
    let rows = try await store.rows(inView: SavedView.allID).map(\.mergeKey)
    #expect(rows.firstIndex(of: "late-1") == last + 1)
}

private func isNear(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1 }

/// Opens the sample timeline and waits until every row is in.
@MainActor
private func openTimeline(count: Int = 200, before: (InfluxStore) async throws -> Void = { _ in }) async throws -> (TimelineController, FakeSurface, InfluxStore) {
    let store = try InfluxStore.inMemory()
    try await SeedFeed.load(into: store, count: count)
    try await before(store)
    let expected = try await store.rows(inView: SavedView.allID).count
    let timeline = TimelineController(store: store)
    let surface = FakeSurface()
    surface.timeline = timeline
    timeline.surface = surface
    timeline.start()
    timeline.use(RowEnvironment(width: 390, scale: 2, dark: false, typography: Typography()))
    for _ in 0..<500 where timeline.model.count != expected {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(timeline.model.count == expected)
    try #require(timeline.model.totalHeight > surface.viewportHeight * 10)
    return (timeline, surface, store)
}

/// A viewport with no view behind it. Moves land at once, animated or not,
/// and report the scroll the way the platform views do.
@MainActor
private final class FakeSurface: TimelineSurface {
    weak var timeline: TimelineController?
    var viewportTop: CGFloat = 0
    var viewportHeight: CGFloat = 600
    var isScrolling = false
    var isReaderInput = false
    var unread = 0
    /// False holds animated moves back, as a view still animating does:
    /// the target waits in `pendingAnimation`, and the next move without
    /// animation ends it where the view is, as setting the offset does.
    var animationsLand = true
    private(set) var pendingAnimation: CGFloat?

    func setViewportTop(_ y: CGFloat, animated: Bool) {
        let bottom = (timeline?.model.totalHeight ?? 0) - viewportHeight
        if animated, !animationsLand {
            pendingAnimation = max(0, min(y, bottom))
            return
        }
        pendingAnimation = nil
        viewportTop = max(0, min(y, bottom))
        timeline?.scrolled()
    }

    func show(_ keys: [String], reload: Bool, reconfigure: [String]) async {}
    func refreshCell(_ key: String) {}
    func showUnread(_ count: Int) { unread = count }
    var flashed: [CGRect] = []
    func flash(_ frame: CGRect) { flashed.append(frame) }

    /// The reader scrolling to `y`.
    func scroll(to y: CGFloat) {
        isScrolling = true
        isReaderInput = true
        setViewportTop(y, animated: false)
        isScrolling = false
        isReaderInput = false
    }

    /// The view moving itself, as a relayout or the system restoring the
    /// app does: not the reader.
    func nudge(to y: CGFloat) {
        setViewportTop(y, animated: false)
    }
}
