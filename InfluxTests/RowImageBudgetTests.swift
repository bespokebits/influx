import CoreGraphics
import Testing
@testable import Influx

/// Row bitmaps are kept within a byte budget, so reading on doesn't hold
/// hundreds of MB of rows scrolled past.
@MainActor @Suite struct RowImageBudgetTests {
    private let mb = 1024 * 1024

    @Test func keepsTheWholeKeepRangeWhenItFits() {
        let kept = RowImageCache.keptRows(around: 100..<104, down: true, count: 1_000, budget: 1_000 * mb) { _ in mb }
        #expect(Set(kept) == Set((100 - RowImageCache.keep)..<(104 + RowImageCache.keep)))
    }

    @Test func staysWithinTheBudget() {
        let kept = RowImageCache.keptRows(around: 100..<104, down: true, count: 1_000, budget: 40 * mb) { _ in 3 * mb }
        #expect(kept.count == 13)
        #expect(kept.count * 3 * mb <= 40 * mb)
    }

    @Test func visibleRowsFirstThenOnward() {
        let down = RowImageCache.keptRows(around: 100..<104, down: true, count: 1_000, budget: 10 * mb) { _ in mb }
        #expect(down == Array(100..<110))
        let up = RowImageCache.keptRows(around: 100..<104, down: false, count: 1_000, budget: 10 * mb) { _ in mb }
        #expect(up == [100, 101, 102, 103, 99, 98, 97, 96, 95, 94])
    }

    @Test func prefetchWindowComesBeforeFarRowsOnward() {
        let budget = (4 + RowImageCache.ahead + RowImageCache.behind) * mb
        let kept = RowImageCache.keptRows(around: 100..<104, down: true, count: 1_000, budget: budget) { _ in mb }
        #expect(Set(kept) == Set((100 - RowImageCache.behind)..<(104 + RowImageCache.ahead)))
    }

    @Test func visibleRowsStayEvenOverBudget() {
        let kept = RowImageCache.keptRows(around: 10..<14, down: true, count: 20, budget: mb) { _ in 5 * mb }
        #expect(kept == [10, 11, 12, 13])
    }

    @Test func clampsAtTheEnds() {
        let kept = RowImageCache.keptRows(around: 0..<3, down: false, count: 5, budget: 100 * mb) { _ in mb }
        #expect(Set(kept) == Set(0..<5))
        #expect(kept.count == 5)
    }

    @Test func bitmapBytesAtScale() {
        #expect(RowImageCache.bytes(width: 900, height: 200, scale: 2) == 1_800 * 400 * 4)
    }
}
