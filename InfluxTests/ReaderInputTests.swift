// What the platform views count as the reader's own scroll: only that
// moves the reading place, so a relayout can't send an old place over a
// newer one from another device.
#if os(iOS)
import Testing
import UIKit
@testable import Influx

/// A VoiceOver or Switch Control scroll has no touch, but it is the reader's.
/// (A keyboard scroll is marked the same way, from `pressesBegan`; UIPress
/// can't be made in a test.)
@MainActor
@Test func anAccessibilityScrollCountsAsTheReaders() {
    let view = TimelineCollectionView(frame: CGRect(x: 0, y: 0, width: 390, height: 800),
                                      collectionViewLayout: UICollectionViewFlowLayout())
    #expect(!view.handledReaderInputRecently)
    _ = view.accessibilityScroll(.down)
    #expect(view.handledReaderInputRecently)
}
#else
import AppKit
import Testing
@testable import Influx

/// A wheel notch or scrolling key marks the scroll that follows as the
/// reader's, for a moment and no longer.
@MainActor
@Test func readerInputLastsAMoment() async throws {
    let view = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
    #expect(!view.handledReaderInputRecently)
    view.noteReaderInput()
    #expect(view.handledReaderInputRecently)
    try await Task.sleep(for: .milliseconds(600))
    #expect(!view.handledReaderInputRecently)
}

/// The scroller is the timeline's own, so a click or drag on it is marked
/// as the reader's.
@MainActor
@Test func theScrollerMarksReaderInput() {
    let view = TimelineScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
    let scroller = view.verticalScroller as? TimelineScroller
    #expect(scroller != nil)
    scroller?.onReaderInput?()
    #expect(view.handledReaderInputRecently)
}
#endif
