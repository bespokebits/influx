import Foundation
import Testing
@testable import Influx

/// Images load nearest the screen first (#263): a free download slot goes
/// to the lowest priority, the longest waiting among equals, and a waiting
/// download moves when its rows do.
@Suite struct DownloadOrder {
    /// Starts a waiter for `key` and returns once it is queued.
    private func wait(_ slots: DownloadSlots, _ key: String, priority: Int, granted: @escaping @Sendable (String) -> Void) async {
        let before = await slots.queue.count
        Task { if await slots.acquire(key, priority: { priority }) { granted(key) } }
        while await slots.queue.count == before { await Task.yield() }
    }

    @Test func aFreeSlotGoesToTheLowestPriorityThenTheOldest() async {
        let slots = DownloadSlots(limit: 1)
        #expect(await slots.acquire("held", priority: { 0 }))
        let order = Order()
        await wait(slots, "far", priority: 40) { order.add($0) }
        await wait(slots, "near", priority: 2) { order.add($0) }
        await wait(slots, "also-near", priority: 2) { order.add($0) }
        #expect(await slots.queue == ["near", "also-near", "far"])
        for _ in 0..<3 {
            let granted = order.count
            await slots.release()
            while order.count == granted { await Task.yield() }
        }
        #expect(order.keys == ["near", "also-near", "far"])
    }

    @Test func aWaitingDownloadMovesWithItsRow() async {
        let slots = DownloadSlots(limit: 1)
        #expect(await slots.acquire("held", priority: { 0 }))
        await wait(slots, "a", priority: 1) { _ in }
        await wait(slots, "b", priority: 30) { _ in }
        // The reader scrolled: b's row is now on screen, a's is far behind.
        await slots.prioritize("b", 0)
        await slots.prioritize("a", 90)
        #expect(await slots.queue == ["b", "a"])
    }

    /// Two moves of one download that reach the queue out of order still
    /// leave the latest priority: each reads the priority when it lands.
    @Test func movesArrivingOutOfOrderLeaveTheLatest() async {
        let slots = DownloadSlots(limit: 1)
        #expect(await slots.acquire("held", priority: { 0 }))
        await wait(slots, "a", priority: 5) { _ in }
        await wait(slots, "b", priority: 10) { _ in }
        let latest = Latest(90)
        // The move to 0 was sent first but lands second; the latest is 90.
        await slots.prioritize("a") { latest.value }
        await slots.prioritize("a") { latest.value }
        #expect(await slots.queue == ["b", "a"])
        await slots.prioritize("gone") { nil }
        #expect(await slots.queue == ["b", "a"])
    }

    /// Two timelines (or a thread and a timeline) waiting for one image:
    /// one moving its own row away never pushes back the other's, and the
    /// rest keep theirs when one stops waiting.
    @Test func aDownloadWaitsAtTheLowestOfItsCallers() {
        let window = UUID(), other = UUID()
        var priorities = CallerPriorities()
        priorities.add(window, 0)
        priorities.add(other, 40)
        #expect(priorities.lowest == 0)
        let movedOther = priorities.move(other, to: 90)
        #expect(movedOther)
        #expect(priorities.lowest == 0)
        let movedWindow = priorities.move(window, to: 70)
        #expect(movedWindow)
        #expect(priorities.lowest == 70)
        let movedStranger = priorities.move(UUID(), to: 1)
        #expect(!movedStranger)
        priorities.remove(window)
        #expect(priorities.lowest == 90)
        priorities.add(other, 5)
        priorities.remove(other)
        #expect(priorities.lowest == 5)
        priorities.remove(other)
        #expect(priorities.lowest == 0)
    }

    @MainActor @Test func rowsOnScreenComeFirstThenOnwardThenBehind() {
        let visible = 100..<104
        let onScreen = visible.map { RowImageCache.distance($0, visible: visible, down: true) }
        #expect(onScreen == [0, 1, 2, 3])
        let ahead = (104..<152).map { RowImageCache.distance($0, visible: visible, down: true) }
        #expect(ahead == ahead.sorted() && ahead.first! > onScreen.last!)
        let behind = RowImageCache.distance(99, visible: visible, down: true)
        #expect(behind > ahead.last!)
        // Scrolling up, the rows above are onward.
        #expect(RowImageCache.distance(99, visible: visible, down: false) < RowImageCache.distance(104, visible: visible, down: false))
    }
}

/// The keys granted a slot, in order.
private final class Order: @unchecked Sendable {
    private let lock = NSLock()
    private var granted: [String] = []
    func add(_ key: String) { lock.withLock { granted.append(key) } }
    var keys: [String] { lock.withLock { granted } }
    var count: Int { lock.withLock { granted.count } }
}

/// A priority as the loader holds it, read when a move lands.
private final class Latest: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Int?
    init(_ value: Int?) { current = value }
    var value: Int? { lock.withLock { current } }
}
