import Foundation
import Testing
@testable import InfluxKit

@Suite struct Deadline {
    /// Work that ignores cancellation and answers after 2 s, so finishing
    /// well before that shows the caller didn't wait for it.
    private static func stubborn() async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
        }
        return "late"
    }

    @Test func givesUpAtTheDeadline() async {
        let started = ContinuousClock.now
        #expect(await withDeadline(.milliseconds(50)) { await Self.stubborn() } == nil)
        #expect(ContinuousClock.now - started < .milliseconds(1900))
    }

    @Test func returnsAtOnceWhenTheCallerIsCancelled() async {
        let started = ContinuousClock.now
        let call = Task { await withDeadline(.seconds(60)) { await Self.stubborn() } }
        try? await Task.sleep(for: .milliseconds(50))
        call.cancel()
        #expect(await call.value == nil)
        #expect(ContinuousClock.now - started < .milliseconds(1900))
    }

    @Test func keepsTheAnswerWhenItComesInTime() async {
        #expect(await withDeadline(.seconds(5)) { "soon" } == "soon")
    }
}
