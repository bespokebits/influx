// The Sources sheet over the sample feed. Sample runs never fetch, so these
// stay off the network.
import XCTest

final class SourcesTests: XCTestCase {
    /// An address that can't be a feed gets a quiet inline message, and the
    /// sheet stays open to fix it.
    @MainActor
    func testBadAddressSaysSoInline() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxSeedTimeline", "YES"]
        app.launch()

        let sources = app.buttons["sources-button"]
        XCTAssertTrue(sources.waitForExistence(timeout: 15))
        sources.tap()
        app.buttons["add-feed"].tap()

        let address = app.textFields["feed-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("not a feed")
        app.buttons["add-feed-confirm"].tap()

        let error = app.staticTexts["add-feed-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertEqual(error.label, "That doesn't look like a web address.")
    }

    /// The last line of Sources says which build this is.
    @MainActor
    func testSourcesShowTheVersionLine() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxSeedTimeline", "YES"]
        app.launch()

        let sources = app.buttons["sources-button"]
        XCTAssertTrue(sources.waitForExistence(timeout: 15))
        sources.tap()

        // The version line is the last row, below the fold once there
        // are a few sources, and a List builds only the rows on screen.
        let version = app.staticTexts["version-line"]
        for _ in 0..<6 where !version.exists {
            app.swipeUp()
        }
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertTrue(version.label.hasPrefix("Influx "), version.label)
    }
}
