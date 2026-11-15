// The timeline over the sample feed. These run on a simulator or a device
// from the InfluxUITests-iOS scheme; the perf test only means anything on a
// device.
import XCTest

final class TimelineTests: XCTestCase {
    @MainActor
    private func launch(diagnostics: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxSeedTimeline", "YES", "-InfluxShowScrollDiagnostics", diagnostics ? "YES" : "NO"]
        app.launch()
        return app
    }

    /// The pill counts the unread rows below the screen, newer rows
    /// arriving while the reader is up the timeline among them, and takes
    /// the reader down to them. Opening at the newest rows doesn't mark
    /// them read, so the last of those may count too.
    @MainActor
    func testTheUnreadPillCountsNewerRowsAndJumpsToTheNewest() throws {
        let app = launch(diagnostics: true)
        let timeline = app.collectionViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        timeline.swipeDown(velocity: .fast)

        // The count settles once scrolling pauses; it may be 0 (no pill).
        let pill = app.buttons["unread-pill"]
        Thread.sleep(forTimeInterval: 2)
        let before = pill.exists ? Self.unreadCount(in: pill.label) : 0

        app.buttons["add-newer"].tap()
        expectation(for: NSPredicate(format: "label == %@", "\(before + 20) unread"), evaluatedWith: pill)
        waitForExpectations(timeout: 5)

        pill.tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: pill)
        waitForExpectations(timeout: 5)
    }

    /// While "Syncing in Progress" covers the timeline it can't be scrolled
    /// from a place another device may have moved on from; once it lifts,
    /// here after its limit as with a slow iCloud, it can (influx-dev #106).
    @MainActor
    func testTheSyncingScreenHoldsTheTimelineUntilItLifts() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxSeedTimeline", "YES", "-InfluxSyncingScreenFor", "25"]
        // Long enough for XCUITest's own queries and swipes, which take
        // around 12 s on a simulator, to finish well inside it.
        app.launch()
        let screen = app.descendants(matching: .any)["syncing-screen"]
        XCTAssertTrue(screen.waitForExistence(timeout: 5))
        let timeline = app.collectionViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let top = timeline.staticTexts.element(boundBy: 0)
        XCTAssertTrue(top.waitForExistence(timeout: 5))
        let before = top.label

        screen.swipeDown(velocity: .fast)
        screen.swipeDown(velocity: .fast)
        XCTAssertTrue(screen.exists, "the screen lifted before the swipes were tried")
        XCTAssertEqual(timeline.staticTexts.element(boundBy: 0).label, before)

        // The stand-in lifts as a slow iCloud would, and that lift is quiet
        // (no note, influx-dev #113), so wait for the screen itself to go.
        XCTAssertTrue(screen.waitForNonExistence(timeout: 30), "the screen never lifted")
        XCTAssertFalse(app.descendants(matching: .any)["syncing-note"].exists, "a slow lift showed a note")
        timeline.swipeDown(velocity: .fast)
        timeline.swipeDown(velocity: .fast)
        XCTAssertNotEqual(timeline.staticTexts.element(boundBy: 0).label, before)
    }

    /// The count in the unread pill's "N unread".
    private static func unreadCount(in label: String) -> Int {
        Int(label.split(separator: " ").first ?? "") ?? 0
    }

    /// A reply's "Replying to" chip opens its thread, and a post there can
    /// be liked and unliked (the sample timeline acts through a stand-in).
    @MainActor
    func testReplyChipOpensTheThread() throws {
        let app = launch()
        let timeline = app.collectionViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        // Rows are read as text, so they're static texts, not cells.
        let reply = timeline.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Replying to")).firstMatch
        for _ in 0..<8 where !(reply.exists && reply.isHittable) {
            timeline.swipeDown()
        }
        XCTAssertTrue(reply.isHittable)
        // The tap goes near the row's top, so bring its top well onto the
        // screen first: a tall row can be hittable with its top above it.
        let top = timeline.frame.minY + 200
        if abs(reply.frame.minY - top) > 100 {
            let start = timeline.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: timeline.frame.width / 2, dy: 450))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: top - reply.frame.minY)),
                        withVelocity: .slow, thenHoldForDuration: 0.5)
        }
        XCTAssertGreaterThan(reply.frame.minY, timeline.frame.minY)
        // The chip is the line under the author.
        reply.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 60, dy: 44)).tap()

        XCTAssertTrue(app.buttons["thread-done"].waitForExistence(timeout: 5))
        // The sample thread has posts missing at both edges, each noted with
        // a way to the whole thread, a quote and an unavailable quote.
        let thread = app.descendants(matching: .any)
        XCTAssertTrue(thread["thread-missing-ancestors"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Some earlier posts were deleted by their authors."].exists)
        XCTAssertTrue(thread["thread-whole-ancestors"].exists)
        XCTAssertTrue(thread["thread-quote"].exists)
        // The post that opens its own thread takes on the card's identifier
        // too, so the card is the one that reads as the card.
        let unavailable = thread.matching(NSPredicate(format: "identifier == %@ AND label == %@", "thread-quote-unavailable",
                                                      "Quoted post unavailable, example.net")).firstMatch
        for _ in 0..<4 where !unavailable.exists { app.swipeUp() }
        XCTAssertTrue(unavailable.exists)
        for _ in 0..<4 where !thread["thread-missing-replies"].exists { app.swipeUp() }
        XCTAssertTrue(thread["thread-missing-replies"].exists)
        XCTAssertTrue(app.staticTexts["The thread goes on past what was collected."].exists)
        let like = app.buttons["Like"].firstMatch
        XCTAssertTrue(like.waitForExistence(timeout: 5))
        like.tap()
        XCTAssertTrue(app.buttons["Unlike"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["thread-done"].tap()
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
    }

    /// Pulling up past the newest row refreshes. On the sample timeline a
    /// refresh adds 20 newer rows, which the hitch counter's row count shows.
    @MainActor
    func testPullingUpPastTheNewestRowRefreshes() throws {
        let app = launch(diagnostics: true)
        let timeline = app.collectionViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        // The HUD takes taps, so it may show as a button rather than static text.
        let hud = app.descendants(matching: .any)["hitch-hud"]
        XCTAssertTrue(hud.waitForExistence(timeout: 10))
        // The timeline opens on a window of rows, then fills in the rest;
        // wait for the count to settle. Boosts merge into their posts' rows,
        // so the sample makes fewer rows than its 2,000 items.
        var rows = 0
        for _ in 0..<30 {
            let now = Self.rowCount(in: hud.label)
            if now > 0, now == rows { break }
            rows = now
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertGreaterThan(rows, 100)

        let from = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let to = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        from.press(forDuration: 0.1, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)

        expectation(for: NSPredicate(format: "label CONTAINS %@", " \(rows + 20) rows"), evaluatedWith: hud)
        waitForExpectations(timeout: 10)
    }

    /// Find in Timeline: typing lists the matching rows, choosing one goes
    /// there with a way back, and Back returns.
    @MainActor
    func testFindInTimelineGoesToAResultAndBack() throws {
        let app = launch()
        let timeline = app.collectionViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        app.buttons["find-button"].tap()
        let field = app.textFields["find-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("hairlines serifs")

        let results = app.buttons.matching(identifier: "find-result")
        XCTAssertTrue(results.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["find-count"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["find-count"].label.hasSuffix("matches") || app.staticTexts["find-count"].label == "1 match")
        // The list opens at the newest match, at the bottom, like the
        // timeline; older ones are laid out above the screen.
        let onScreen = (0..<results.count).reversed().map { results.element(boundBy: $0) }.first { $0.isHittable }
        let result = try XCTUnwrap(onScreen)
        result.tap()

        XCTAssertFalse(field.exists)
        let back = app.buttons["find-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: back)
        waitForExpectations(timeout: 5)

        // A word nothing has says so; Cancel brings the timeline back.
        app.buttons["find-button"].tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("zyzzyva")
        XCTAssertTrue(app.descendants(matching: .any)["find-no-results"].waitForExistence(timeout: 5))
        app.buttons["find-cancel"].tap()
        XCTAssertTrue(app.buttons["find-button"].waitForExistence(timeout: 5))
    }

    /// The row count in the hitch counter's "… · N rows · …" line.
    private static func rowCount(in label: String) -> Int {
        guard let range = label.range(of: #"\d+ rows"#, options: .regularExpression) else { return 0 }
        return Int(label[range].split(separator: " ")[0]) ?? 0
    }

    /// Apple's scroll hitch metric. Run on the iPhone 15 Pro Max and read
    /// "Hitch Time Ratio" in the test report; the bar is under 5 ms/s.
    @MainActor
    func testFlingThroughTimeline() throws {
        let app = launch()
        let timeline = app.collectionViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))

        let options = XCTMeasureOptions()
        options.invocationOptions = [.manuallyStop]
        // The timeline opens at the newest row (the bottom), so flinging
        // down travels back through older rows.
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            timeline.swipeDown(velocity: .fast)
            stopMeasuring()
            timeline.swipeUp(velocity: .fast)
        }
    }
}
