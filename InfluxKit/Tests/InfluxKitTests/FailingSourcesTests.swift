import Foundation
import Testing
@testable import InfluxKit

/// A source is raised only once its problem has outlasted a day by its own
/// fetch attempts, and an unreachable one only while others still fetch.
@Suite struct FailingSourcesTests {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private let day = FailingSources.threshold

    private func state(_ id: String, failing problem: SourceProblem? = nil, since: Date? = nil, tried: Date? = nil, succeeded: Date? = nil) -> SourceFetchState {
        var state = SourceFetchState(sourceID: id)
        state.problem = problem
        state.problemSince = since
        state.lastAttemptAt = tried ?? succeeded
        state.lastSuccessAt = succeeded
        return state
    }

    @Test func aProblemUnderADayIsQuiet() {
        let states = [
            state("feed", failing: .offline, since: t0, tried: t0 + day - 60),
            state("other", succeeded: t0 + day),
        ]
        #expect(FailingSources.ids(in: states).isEmpty)
    }

    @Test func anUnreachableFeedIsRaisedWhileOthersFetch() {
        let states = [
            state("feed", failing: .offline, since: t0, tried: t0 + day + 60),
            state("other", succeeded: t0 + day + 30),
        ]
        #expect(FailingSources.ids(in: states) == ["feed"])
    }

    @Test func aDeviceThatWasOfflineRaisesNothing() {
        let states = [
            state("feed", failing: .offline, since: t0, tried: t0 + day + 60),
            state("other", failing: .offline, since: t0 + 10, tried: t0 + day + 60, succeeded: t0 - 60),
        ]
        #expect(FailingSources.ids(in: states).isEmpty)
    }

    @Test func aDeviceThatWentOfflineSinceRaisesNothing() {
        // Another source fetched after the day was up, then the device lost
        // its connection and every source failed.
        let states = [
            state("feed", failing: .offline, since: t0, tried: t0 + day + 600),
            state("other", failing: .offline, since: t0 + day + 600, tried: t0 + day + 600, succeeded: t0 + day + 30),
        ]
        #expect(FailingSources.ids(in: states).isEmpty)
    }

    @Test func aDayWithoutTryingAgainRaisesNothing() {
        // The app was closed: the problem is old, but no attempt has
        // failed since a day after it started.
        let states = [
            state("feed", failing: .offline, since: t0, tried: t0),
            state("other", succeeded: t0 + 2 * day),
        ]
        #expect(FailingSources.ids(in: states).isEmpty)
    }

    @Test func anAnsweringServerNeedsNoOtherSource() {
        let states = [state("gone", failing: .notFound, since: t0, tried: t0 + day)]
        #expect(FailingSources.ids(in: states) == ["gone"])
    }

    @Test func oldestProblemFirst() {
        let states = [
            state("newer", failing: .badResponse, since: t0 + 60, tried: t0 + 2 * day),
            state("older", failing: .notFound, since: t0, tried: t0 + 2 * day),
        ]
        #expect(FailingSources.ids(in: states) == ["older", "newer"])
    }
}
