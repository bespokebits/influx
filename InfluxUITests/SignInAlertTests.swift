// The sign-in alert over the sample timeline, with its accounts shown as
// signed out (they have no credentials). Sample runs never reach the
// network, so this checks what shows, not a real sign-in.
import XCTest

final class SignInAlertTests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxSeedTimeline", "YES", "-InfluxSampleSignedOut", "YES"]
        app.launch()
        return app
    }

    /// A signed-out account puts a bar above the timeline that names it
    /// and offers Sign in again.
    @MainActor
    func testASignedOutAccountShowsTheAlertWithSignInAgain() throws {
        let app = launch()
        let alert = app.otherElements["sign-in-alert"]
        XCTAssertTrue(alert.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "isn't signed in on this device")).firstMatch.exists)
        let button = app.buttons["sign-in-again"].firstMatch
        XCTAssertTrue(button.exists)
        XCTAssertTrue(button.isHittable)
        // The timeline starts below the bar, not under it.
        let timeline = app.collectionViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(timeline.frame.minY, alert.frame.maxY - 1)
    }

    /// The default sample run has no alert.
    @MainActor
    func testNoAlertWhenAccountsAreFine() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-InfluxSeedTimeline", "YES"]
        app.launch()
        XCTAssertTrue(app.collectionViews["timeline"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.otherElements["sign-in-alert"].exists)
    }
}
