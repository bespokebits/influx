// The sync button: which state it shows, and where the mark's dots go.
import CoreGraphics
import Foundation
import Testing
@testable import Influx

@MainActor
@Suite struct SyncStatusTests {
    @Test func startsAsStartingAndRestsOnceTheFirstSyncLands() async throws {
        let status = SyncStatus(minimumShown: .zero)
        #expect(status.phase == .starting)
        status.finished(failure: nil, began: .now)
        #expect(status.phase == .synced)
    }

    @Test func aShownSyncCirclesForAtLeastAMoment() async throws {
        let status = SyncStatus(minimumShown: .milliseconds(300))
        status.finished(failure: nil, began: .now)
        try await Task.sleep(for: .milliseconds(350))
        #expect(status.phase == .synced)
        status.began()
        #expect(status.phase == .syncing)
        status.finished(failure: nil, began: .now)
        #expect(status.phase == .syncing)
        try await Task.sleep(for: .milliseconds(400))
        #expect(status.phase == .synced)
    }

    /// The background polls don't animate, but they report failures, and
    /// the next one that works clears it.
    @Test func backgroundPollsOnlyShowAndClearFailures() async throws {
        let status = SyncStatus(minimumShown: .zero)
        status.finished(failure: nil, began: .now)
        status.finished(failure: nil, began: .now)
        #expect(status.phase == .synced)
        status.finished(failure: "CKError 3 networkUnavailable Network Unavailable", began: .now)
        #expect(status.phase == .failed("You're offline"))
        status.finished(failure: nil, began: .now)
        #expect(status.phase == .synced)
    }

    @Test func aFailureWinsOverTheWaitToRest() async throws {
        let status = SyncStatus(minimumShown: .milliseconds(300))
        status.finished(failure: nil, began: .now)
        try await Task.sleep(for: .milliseconds(350))
        status.began()
        status.finished(failure: nil, began: .now)
        status.finished(failure: "CKError 9 notAuthenticated", began: .now)
        try await Task.sleep(for: .milliseconds(400))
        #expect(status.phase == .failed("Sign in to iCloud to sync"))
        // Tapping retries.
        status.began()
        #expect(status.phase == .syncing)
    }

    /// An older pass that overlapped neither ends a shown sync nor clears
    /// a newer failure.
    @Test func anOlderPassDoesntSpeakForANewerOne() async throws {
        let status = SyncStatus(minimumShown: .zero)
        status.finished(failure: nil, began: .now)
        let olderPoll = Date.now
        try await Task.sleep(for: .milliseconds(20))
        status.began()
        status.finished(failure: nil, began: olderPoll)
        #expect(status.phase == .syncing)
        status.finished(failure: nil, began: .now)
        #expect(status.phase == .synced)

        // Tapped twice: the pass from the first tap doesn't end the second.
        status.began()
        let firstTap = Date.now
        try await Task.sleep(for: .milliseconds(20))
        status.began()
        status.finished(failure: nil, began: firstTap)
        #expect(status.phase == .syncing)
        status.finished(failure: nil, began: .now)
        #expect(status.phase == .synced)

        let anotherOlderPoll = Date.now
        try await Task.sleep(for: .milliseconds(20))
        status.finished(failure: "CKError 4 networkFailure", began: .now)
        status.finished(failure: nil, began: anotherOlderPoll)
        #expect(status.phase == .failed("You're offline"))
        status.finished(failure: nil, began: .now)
        #expect(status.phase == .synced)

        // A newer pass finished first: the older one's failure is stale.
        let olderStill = Date.now
        try await Task.sleep(for: .milliseconds(20))
        status.finished(failure: nil, began: .now)
        status.finished(failure: "CKError 4 networkFailure", began: olderStill)
        #expect(status.phase == .synced)
    }

    /// The timeline holds its reading place while a sync is under way.
    @Test func catchingUpLastsUntilTheSyncLands() async throws {
        let status = SyncStatus(minimumShown: .zero)
        #expect(status.isCatchingUp)
        status.finished(failure: nil, began: .now)
        #expect(!status.isCatchingUp)
        status.began()
        #expect(status.isCatchingUp)
        status.finished(failure: "CKError 4 networkFailure", began: .now)
        #expect(!status.isCatchingUp)
    }

    /// Each catch-up has its own number, so one that ran long doesn't
    /// stop the next from holding the place.
    @Test func eachCatchUpIsCountedOnce() async throws {
        let status = SyncStatus(minimumShown: .zero)
        #expect(status.catchUp == 0)
        status.finished(failure: nil, began: .now)
        #expect(status.catchUp == nil)
        status.began()
        status.began()
        #expect(status.catchUp == 1)
        status.finished(failure: nil, began: .now)
        status.began()
        #expect(status.catchUp == 2)
    }

    /// The status panel: when sync last worked, the latest problems with
    /// repeats moved to the top, and what went up and came down.
    @Test func thePanelKeepsTheLastSyncProblemsAndCounts() async throws {
        let status = SyncStatus(minimumShown: .zero)
        #expect(status.lastSynced == nil)
        status.finished(failure: "CKError 4 networkFailure", began: .now)
        #expect(status.lastSynced == nil)
        status.finished(failure: "CKError 9 notAuthenticated", began: .now)
        status.finished(failure: "CKError 3 networkUnavailable", began: .now)
        #expect(status.problems.map(\.message) == ["You're offline", "Sign in to iCloud to sync"])
        status.finished(failure: nil, began: .now)
        #expect(status.lastSynced != nil)
        #expect(status.problems.count == 2)
        for i in 0..<20 { status.finished(failure: "iCloud trouble \(i)", began: .now) }
        #expect(status.problems.count == SyncStatus.problemLimit)
        #expect(status.problems.first?.message == "iCloud trouble 19")

        status.tally(sent: 3, received: 0)
        status.tally(sent: 1, received: 5)
        #expect(status.sent == 4 && status.received == 5)
    }

    @Test func failuresReadAsPlainWords() {
        #expect(SyncStatus.message(for: "CKError 25 quotaExceeded") == "Your iCloud storage is full")
        #expect(SyncStatus.message(for: "CKError 15 serverRejectedRequest") == "iCloud didn't sync")
        #expect(SyncStatus.message(for: "iCloud sync couldn't start") == "iCloud sync couldn't start")
    }
}

@Suite struct SlipsMarkTests {
    @Test func startUpDrawsTheTrayAndFliesTheDotsIn() {
        let first = SlipsMark.frame(.starting, elapsed: 0)
        #expect(first.trayDrawn == 0)
        #expect(first.dots.allSatisfy { $0.radius == 0 && $0.opacity == 0 })
        let landed = SlipsMark.frame(.starting, elapsed: SlipsMark.introLength)
        #expect(landed.trayDrawn == 1)
        for (dot, home) in zip(landed.dots, SlipsMark.orbitCenters(at: 0)) {
            #expect(close(dot.center, home))
            #expect(dot.radius == SlipsMark.dotRadius)
        }
    }

    @Test func syncingCirclesAboveTheTray() {
        for t in stride(from: 0.5, to: 3, by: 0.1) {
            for dot in SlipsMark.frame(.syncing, elapsed: t).dots {
                let distance = hypot(dot.center.x - SlipsMark.orbitCenter.x, dot.center.y - SlipsMark.orbitCenter.y)
                #expect(abs(distance - SlipsMark.orbitRadius) < 0.01)
            }
        }
    }

    @Test func syncedDropsTheDotsIntoTheTrayAndRests() {
        let from = SlipsMark.orbitCenters(at: 0.4, stagger: true)
        let done = SlipsMark.frame(.synced, elapsed: SlipsMark.settleTime(.synced)!, from: from)
        for (dot, rest) in zip(done.dots, SlipsMark.restingCenters) {
            #expect(close(dot.center, rest))
            #expect(dot.opacity == 1)
        }
        #expect(done.trayScale == CGSize(width: 1, height: 1))
        #expect(done.trayOpacity == 1)
        #expect(done.pointScale == 0)
    }

    @Test func failedBecomesAnExclamationMark() {
        let from = SlipsMark.orbitCenters(at: 0.7, stagger: true)
        let midway = SlipsMark.frame(.failed, elapsed: 0.6, from: from)
        for (dot, spot) in zip(midway.dots, SlipsMark.columnCenters) {
            #expect(close(dot.center, spot, within: 0.5))
        }
        let done = SlipsMark.frame(.failed, elapsed: SlipsMark.settleTime(.failed)!, from: from)
        #expect(done.trayOpacity == 0)
        #expect(done.barOpacity == 1)
        #expect(done.barScale == CGSize(width: 1, height: 1))
        #expect(done.pointScale == 1)
        #expect(done.dots.allSatisfy { $0.opacity == 0 && $0.alarm == 1 })
    }

    @Test func reduceMotionNeverOvershoots() {
        let from = SlipsMark.orbitCenters(at: 0)
        for t in stride(from: 0, to: 1, by: 0.02) {
            let frame = SlipsMark.frame(.synced, elapsed: t, from: from, reduceMotion: true)
            for (dot, rest) in zip(frame.dots, SlipsMark.restingCenters) {
                #expect(dot.center.y <= rest.y + 0.001)
            }
            #expect(frame.trayScale == CGSize(width: 1, height: 1))
        }
    }

    private func close(_ a: CGPoint, _ b: CGPoint, within limit: CGFloat = 0.01) -> Bool {
        hypot(a.x - b.x, a.y - b.y) < limit
    }
}
