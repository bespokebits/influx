// The performance bar, checked by the machine instead of by hand. Run
// these on an iPhone 15 Pro Max in a Release build. Each test flings the
// sample timeline itself, reads the app's own hitch counter and prints an
// INFLUX-PERF line. On a
// simulator they run but don't hold the numbers to the bar.
import XCTest

final class PerformanceTests: XCTestCase {
    /// Under 5 ms of hitches per second of scrolling, at 120 Hz.
    private static let hitchBar = 5.0
    /// The cached timeline on screen under 300 ms from Influx's first code
    /// in a cold launch (the breakdown still shows time from process start).
    private static let launchBar = 300.0
    /// Long enough for a fast fling to come to rest.
    private static let flingSettle: TimeInterval = 3

    override func setUp() {
        continueAfterFailure = false
    }

    /// The sample timeline (about 1,900 rows), flung through for 45 seconds.
    @MainActor
    func testScrollHitches() throws {
        try flingAndCheck(name: "scroll", seconds: 45)
    }

    /// The same at the largest text size the type scale goes to, so taller
    /// rows and more text per row still hold the bar.
    @MainActor
    func testScrollHitchesAtLargeText() throws {
        try flingAndCheck(name: "large-text", seconds: 24,
                          extraArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL"])
    }

    /// Cold launch to a cached timeline read from disk. The first launch
    /// fills the perf store; the measured ones read it back.
    @MainActor
    func testColdLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxPerfStore", "YES"]
        app.launch()
        XCTAssertTrue(app.collectionViews["timeline"].staticTexts.firstMatch.waitForExistence(timeout: 30))
        app.terminate()

        // The system's launch metric, for context, and the app's own time
        // from its first code to the first cached rows, which is the bar.
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var firstRows: [Double] = []
        var breakdowns: [String] = []
        measure(metrics: [XCTApplicationLaunchMetric(waitUntilResponsive: true)], options: options) {
            app.launch()
            let timeline = app.collectionViews["timeline"]
            XCTAssertTrue(timeline.staticTexts.firstMatch.waitForExistence(timeout: 10))
            // Set once every visible row shows its bitmap.
            let timed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'first rows'"), object: timeline)
            XCTAssertEqual(XCTWaiter().wait(for: [timed], timeout: 10), .completed, "rows never finished drawing")
            if let value = timeline.value as? String, let ms = Self.number(before: " ms", in: value) {
                firstRows.append(ms)
                breakdowns.append(value)
            }
            app.terminate()
        }
        XCTAssertFalse(firstRows.isEmpty, "the app reported no launch time")
        let median = firstRows.sorted()[firstRows.count / 2]
        // Where the time went on each launch, from process start (ms).
        for (run, value) in breakdowns.enumerated() { print("INFLUX-PERF launch \(run + 1): \(value)") }
        print("INFLUX-PERF launch: first cached rows \(firstRows.map { String(format: "%.0f", $0) }.joined(separator: ", ")) ms · median \(String(format: "%.0f", median)) ms")
        #if !targetEnvironment(simulator)
        XCTAssertLessThan(median, Self.launchBar, "cold launch, from Influx's first code to cached rows, over the bar")
        #endif
    }

    // MARK: -

    @MainActor
    private func flingAndCheck(name: String, seconds: TimeInterval, extraArguments: [String] = []) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxSeedTimeline", "YES", "-InfluxShowScrollDiagnostics", "YES"] + extraArguments
        app.launch()
        let timeline = app.collectionViews["timeline"]
        // A label that takes taps (to reset); XCUITest has reported it as a
        // button, so match it by identifier whatever its element type.
        let hud = app.descendants(matching: .any)["hitch-hud"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        XCTAssertTrue(hud.waitForExistence(timeout: 15))
        // The sample's 2,000 items merge into a little under 2,000 rows.
        let loaded = NSPredicate(format: "label MATCHES '(?s).*[0-9]{4} rows.*'")
        expectation(for: loaded, evaluatedWith: hud)
        waitForExpectations(timeout: 30)

        // Start the count from here, past launch and the first layout.
        hud.tap()
        // The timeline opens at the newest row, at the bottom: long flings
        // up and down the list, through photo and video rows. Each fling
        // runs out before the next: XCUITest reads the app's accessibility
        // tree on its main thread before every gesture, and doing that
        // mid-fling would count the test's own stalls against the app.
        let end = Date().addingTimeInterval(seconds)
        var upward = true
        var flings = 0
        while Date() < end {
            if upward { timeline.swipeDown(velocity: .fast) } else { timeline.swipeUp(velocity: .fast) }
            Thread.sleep(forTimeInterval: Self.flingSettle)
            flings += 1
            if flings % 4 == 0 { upward.toggle() }
        }
        // Let the last fling settle and the counter catch up.
        Thread.sleep(forTimeInterval: 2)

        let report = hud.label
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "\(name) counter"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("INFLUX-PERF \(name): \(report.replacingOccurrences(of: "\n", with: " · "))")

        let hitch = try XCTUnwrap(Self.number(before: " ms/s", in: report), "no hitch figure in: \(report)")
        let hertz = try XCTUnwrap(Self.number(before: " Hz", in: report), "no frame rate in: \(report)")
        #if targetEnvironment(simulator)
        _ = (hitch, hertz)
        #else
        XCTAssertGreaterThanOrEqual(hertz, 110, "the display isn't running at 120 Hz")
        XCTAssertLessThan(hitch, Self.hitchBar, "hitches over the bar: \(report)")
        #endif
    }

    /// The number just before `unit` in the counter's text, as in
    /// "hitch 2.1 ms/s" or "120 Hz".
    static func number(before unit: String, in text: String) -> Double? {
        guard let range = text.range(of: unit) else { return nil }
        let digits = text[..<range.lowerBound].reversed().prefix { $0.isNumber || $0 == "." }
        return Double(String(digits.reversed()))
    }
}
