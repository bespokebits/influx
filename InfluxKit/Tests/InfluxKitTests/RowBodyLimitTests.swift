import Foundation
import Testing
@testable import InfluxKit

/// A row is drawn into one bitmap, so its body is bounded however long the
/// post; the item keeps the whole text.
@Suite struct RowBodyLimitTests {
    private let limit = TimelineRow.bodyLimit

    @Test func aBodyWithinTheLimitIsShownWhole() {
        let body = String(repeating: "a", count: limit)
        let links = [Item.Link(start: 0, length: 5, url: "https://example.com/a")]
        let (shown, kept) = TimelineRow.bounded(body, links)
        #expect(shown == body)
        #expect(kept == links)
    }

    @Test func aLongBodyIsCutAtASpaceNearTheLimitWithAnEllipsis() {
        let word = "word "
        let body = String(repeating: word, count: limit / word.count * 3)
        let (shown, _) = TimelineRow.bounded(body, [])
        #expect(shown.hasSuffix("word…"))
        #expect(shown.utf16.count <= limit + 1)
        #expect(shown.utf16.count >= limit * 9 / 10)
    }

    @Test func aBodyWithNoSpaceNearTheEndIsCutAtTheLimit() {
        let body = String(repeating: "x", count: limit * 2)
        let (shown, _) = TimelineRow.bounded(body, [])
        #expect(shown == String(repeating: "x", count: limit) + "…")
    }

    @Test func theCutNeverSplitsACharacter() {
        // Each flag is four UTF-16 units; the limit falls inside one.
        let body = "a" + String(repeating: "🇺🇳", count: limit)
        let (shown, _) = TimelineRow.bounded(body, [])
        #expect(shown.hasSuffix("🇺🇳…"))
        #expect(shown.utf16.count <= limit + 1)
    }

    @Test func linksThatNoLongerFitWholeAreDroppedAndTheRestKeepTheirPlaces() {
        // Leading space stays, so offsets counted from the start still hold.
        let body = "  " + String(repeating: "y", count: limit * 2)
        let inside = Item.Link(start: 2, length: 10, url: "https://example.com/in")
        let across = Item.Link(start: limit - 5, length: 10, url: "https://example.com/across")
        let after = Item.Link(start: limit + 100, length: 10, url: "https://example.com/after")
        let (shown, kept) = TimelineRow.bounded(body, [inside, across, after])
        #expect(shown.hasPrefix("  y"))
        #expect(kept == [inside])
    }
}
