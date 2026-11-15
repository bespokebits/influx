// Saved views and filters over the sample feed. Sample runs use an
// in-memory store, so every launch starts with no views and no filters.
import XCTest

final class ViewsTests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxSeedTimeline", "YES", "-InfluxSelectedView", "all"]
        app.launch()
        return app
    }

    /// The top row on screen, read from its accessibility label. Rows are
    /// static text to accessibility, not cells.
    @MainActor
    private func topRow(_ timeline: XCUIElement) -> XCUIElement {
        timeline.staticTexts.element(boundBy: 0)
    }

    @MainActor
    private func addView(named name: String, source: String, in app: XCUIApplication) {
        app.buttons["views-menu"].tap()
        app.buttons["edit-views"].tap()
        app.buttons["new-view"].tap()
        let field = app.textFields["new-view-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Return ends editing, so the keyboard isn't over the sheet.
        field.typeText(name + "\n")
        // The switch sits at the row's trailing edge; tapping the row's
        // middle lands on its label, which doesn't toggle it.
        let toggle = app.switches["source-\(source)"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let confirm = app.buttons["new-view-confirm"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        confirm.tap()
        let done = app.buttons["views-done"]
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: done)
        waitForExpectations(timeout: 5)
        done.tap()
    }

    /// Leaving a view and coming back opens it where the reader left it,
    /// and each view keeps its own place.
    @MainActor
    func testSwitchingViewsKeepsEachPlace() throws {
        let app = launch()
        let timeline = app.collectionViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 15))
        // Up the timeline, away from the newest rows it opens on.
        timeline.swipeDown(velocity: .fast)
        timeline.swipeDown(velocity: .fast)
        // The marker saves once scrolling has paused.
        sleep(2)
        // The timeline reopens on the first row after its marker, the row
        // above the top of the viewport, so it comes back to the row at the
        // top edge. A row half under the bar there may or may not be first
        // to accessibility, so either of the first two counts as the place.
        let placeInAll = [topRow(timeline).label, timeline.staticTexts.element(boundBy: 1).label]

        addView(named: "Daring Fireball", source: "seed:daringfireball.net", in: app)
        let switched = NSPredicate(format: "label CONTAINS 'Daring Fireball'")
        expectation(for: switched, evaluatedWith: app.buttons["views-menu"])
        waitForExpectations(timeout: 5)
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertTrue(topRow(timeline).waitForExistence(timeout: 5))
        XCTAssertFalse(placeInAll.contains(topRow(timeline).label), "the new view shows only its own source")

        app.buttons["views-menu"].tap()
        // The menu's own label can read "All" too; tap the item in it.
        app.buttons.matching(NSPredicate(format: "label == 'All' AND identifier != 'views-menu'")).firstMatch.tap()
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        let back = NSPredicate(format: "label IN %@", placeInAll)
        expectation(for: back, evaluatedWith: topRow(timeline))
        waitForExpectations(timeout: 5)
    }

    /// Select All turns on every source, then reads Select None, which
    /// turns them all off again.
    @MainActor
    func testSelectAllSources() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["views-menu"].waitForExistence(timeout: 15))
        app.buttons["views-menu"].tap()
        app.buttons["edit-views"].tap()
        app.buttons["new-view"].tap()
        let field = app.textFields["new-view-name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Everything\n")

        let toggle = app.switches["source-seed:daringfireball.net"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let selectAll = app.buttons["select-all-sources"]
        XCTAssertEqual(selectAll.label, "Select All")
        selectAll.tap()
        let confirm = app.buttons["new-view-confirm"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        let switches = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'source-'"))
        XCTAssertGreaterThan(switches.count, 1)
        for index in 0..<switches.count {
            XCTAssertEqual(switches.element(boundBy: index).value as? String, "1")
        }

        XCTAssertEqual(selectAll.label, "Select None")
        selectAll.tap()
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: confirm)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(selectAll.label, "Select All")
    }

    /// An invalid regular expression can't be saved, and says why.
    @MainActor
    func testInvalidRegexSaysSo() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["views-menu"].waitForExistence(timeout: 15))
        app.buttons["views-menu"].tap()
        app.buttons["edit-views"].tap()
        app.buttons["add-filter"].firstMatch.tap()

        let pattern = app.textFields["filter-pattern"]
        XCTAssertTrue(pattern.waitForExistence(timeout: 5))
        app.buttons["filter-match"].firstMatch.tap()
        app.buttons["Regular Expression"].firstMatch.tap()
        pattern.tap()
        pattern.typeText("(unclosed")
        XCTAssertTrue(app.staticTexts["filter-error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["add-filter-confirm"].isEnabled)
    }
}
