#if os(iOS)
import Foundation
import Testing
@testable import Influx

/// A launch lays out its opening rows before any window exists, for the
/// screen the last launch's timeline had.
@Suite struct TimelineOpeningScreen {
    private func scratchDefaults() throws -> UserDefaults {
        let name = "TimelineOpeningScreen-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aFirstLaunchHasNoGuess() throws {
        #expect(TimelineOpening.expectedEnvironment(defaults: try scratchDefaults()) == nil)
    }

    @Test func theNextLaunchExpectsTheLastTimelinesScreen() throws {
        let defaults = try scratchDefaults()
        let environment = RowEnvironment(width: 430, scale: 3, dark: true, typography: Typography(scale: 1.25))
        TimelineOpening.remember(environment, screenHeight: 932, defaults: defaults)

        let expected = try #require(TimelineOpening.expectedEnvironment(defaults: defaults))
        #expect(expected.0 == environment)
        #expect(expected.1 == 932)
    }
}
#endif
