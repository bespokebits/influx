import Foundation
import Testing
@testable import InfluxKit

@Suite struct LoadFailureWaits {
    let start = ContinuousClock.now

    @Test func anImageThatNeverFailedHasNoWait() {
        let failures = LoadFailures()
        #expect(!failures.contains("a"))
        #expect(failures.wait(for: "a", now: start) == nil)
    }

    @Test func aFailedImageIsTriedAgainAfterItsWait() {
        var failures = LoadFailures()
        failures.record("a", now: start)
        #expect(failures.contains("a"))
        #expect(failures.wait(for: "a", now: start) == LoadFailures.firstWait)
        #expect(failures.wait(for: "a", now: start + .seconds(2)) == .seconds(3))
        #expect(failures.wait(for: "a", now: start + .seconds(60)) == .zero)
        #expect(failures.wait(for: "b", now: start) == nil)
    }

    @Test func theWaitDoublesUpToTheLongest() {
        let waits = (1...12).map { LoadFailures.waitAfter($0) }
        #expect(Array(waits.prefix(4)) == [.seconds(5), .seconds(10), .seconds(20), .seconds(40)])
        #expect(waits.allSatisfy { $0 <= LoadFailures.longestWait })
        #expect(waits.last == LoadFailures.longestWait)
        #expect(LoadFailures.waitAfter(1_000_000) == LoadFailures.longestWait)
    }

    @Test func eachFailureInARowWaitsLonger() {
        var failures = LoadFailures()
        failures.record("a", now: start)
        failures.record("a", now: start)
        #expect(failures.wait(for: "a", now: start) == .seconds(10))
    }

    @Test func aLoadThatWorksForgetsTheFailures() {
        var failures = LoadFailures()
        failures.record("a", now: start)
        failures.clear("a")
        #expect(!failures.contains("a"))
        failures.record("a", now: start)
        #expect(failures.wait(for: "a", now: start) == LoadFailures.firstWait)
    }
}
