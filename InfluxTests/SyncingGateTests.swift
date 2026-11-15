// The "Syncing in Progress" screen: when it covers the timeline, when it
// lifts, and which animation it shows (influx-dev #106).
import Foundation
import Testing
@testable import Influx

@MainActor
@Suite(.serialized) struct SyncingGateTests {
    private func gate(limit: Duration = .seconds(3), settle: Duration = .zero, away: Duration = .seconds(30),
                      retryAfter: Duration = .milliseconds(500), placeLimit: Duration = .seconds(10),
                      defaults: UserDefaults? = nil) -> SyncingGate {
        SyncingGate(limit: limit, settle: settle, away: away, retryAfter: retryAfter, placeLimit: placeLimit,
                    placePoll: .milliseconds(20), defaults: defaults)
    }

    // MARK: A place waiting for the posts before it (influx-dev #119)

    /// The sync brought a place this device can't show at the top yet,
    /// with its own fetch still bringing the posts before it: the screen
    /// stays until they're in.
    @Test func waitsForThePostsBeforeAStuckPlace() async throws {
        let gate = gate()
        var loading = true
        gate.placeLoading = { loading }
        gate.show()
        gate.syncFinished(.synced)
        try await Task.sleep(for: .milliseconds(200))
        #expect(gate.isShowing)
        loading = false
        try await Task.sleep(for: .milliseconds(200))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .synced)
    }

    /// A slow or stuck fetch holds the screen only up to `placeLimit`
    /// from when it showed.
    @Test func waitsForThePostsOnlySoLong() async throws {
        let gate = gate(placeLimit: .milliseconds(300))
        gate.placeLoading = { true }
        gate.show()
        gate.syncFinished(.synced)
        #expect(gate.isShowing)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .synced)
    }

    /// With nothing stuck, the screen lifts as soon as the sync lands.
    @Test func doesntWaitWhenNoPlaceIsStuck() {
        let gate = gate()
        gate.placeLoading = { false }
        gate.show()
        gate.syncFinished(.synced)
        #expect(!gate.isShowing)
    }

    /// A sync that fails lifts at once: the timeline stays on this
    /// device's own place.
    @Test func aFailedSyncDoesntWaitForPosts() {
        let gate = gate()
        gate.placeLoading = { true }
        gate.show()
        gate.syncFinished(.failed("Sign in to iCloud to sync"))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .failed)
    }

    /// After a wake, a sync that found no network and then landed on a
    /// retry still waits for a stuck place, rather than lifting as offline
    /// at the limit.
    @Test func aSyncThatLandsAfterNoNetworkStillWaitsForThePlace() async throws {
        let gate = gate(limit: .milliseconds(200), retryAfter: .milliseconds(20))
        var loading = true
        gate.placeLoading = { loading }
        gate.show(waitingForNetwork: true)
        gate.syncFinished(.failed(SyncStatus.offlineMessage))
        try await Task.sleep(for: .milliseconds(50))
        gate.syncFinished(.synced)
        try await Task.sleep(for: .milliseconds(400))
        #expect(gate.isShowing)
        loading = false
        try await Task.sleep(for: .milliseconds(200))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .synced)
    }

    /// The limit for the sync running out while the place waits doesn't
    /// lift the screen early.
    @Test func theSyncLimitDoesntCutTheWaitShort() async throws {
        let gate = gate(limit: .milliseconds(150))
        var loading = true
        gate.placeLoading = { loading }
        gate.show()
        gate.syncFinished(.synced)
        try await Task.sleep(for: .milliseconds(400))
        #expect(gate.isShowing)
        loading = false
        try await Task.sleep(for: .milliseconds(200))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .synced)
    }

    @Test func coversTheTimelineUntilTheSyncLands() {
        let gate = gate()
        gate.show()
        #expect(gate.isShowing)
        gate.syncFinished(.synced)
        #expect(!gate.isShowing)
        #expect(gate.lifted == .synced)
    }

    @Test func staysAMomentAfterTheSyncSoThePlaceReachesTheTimeline() async throws {
        let gate = gate(settle: .milliseconds(200))
        gate.show()
        gate.syncFinished(.synced)
        #expect(gate.isShowing)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .synced)
    }

    @Test func liftsAtOnceOfflineOnThisDevicesPlace() {
        let gate = gate(settle: .seconds(10))
        gate.show()
        gate.syncFinished(.failed(SyncStatus.offlineMessage))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .offline)
        #expect(SyncingOverlay.text(for: .offline)?.hasPrefix("Offline") == true)
    }

    @Test func liftsAtOnceWhenTheSyncFailsAnotherWay() {
        let gate = gate()
        gate.show()
        gate.syncFinished(.failed("Sign in to iCloud to sync"))
        #expect(gate.lifted == .failed)
    }

    @Test func givesUpWaitingAfterTheLimit() async throws {
        let gate = gate(limit: .milliseconds(200))
        gate.show()
        try await Task.sleep(for: .milliseconds(400))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .slow)
    }

    /// A sync that lands, or a limit that runs out, from an earlier showing
    /// doesn't lift the screen shown since.
    @Test func anEarlierShowingDoesntLiftALaterOne() async throws {
        let gate = gate(limit: .milliseconds(300), settle: .milliseconds(150))
        gate.show()
        gate.syncFinished(.synced)
        try await Task.sleep(for: .milliseconds(50))
        gate.show()
        try await Task.sleep(for: .milliseconds(200))
        #expect(gate.isShowing)
        #expect(gate.lifted == nil)
        // Lifted before leaving, so no other test meets a held timeline.
        gate.syncFinished(.failed("done"))
    }

    /// Only the app's own screen holds its timelines, so a gate made in a
    /// test never stops another test's timeline. Checked without a pause,
    /// so no other test runs while it holds.
    @Test func onlyTheAppsScreenHoldsTheTimeline() {
        let gate = gate()
        gate.show()
        #expect(!SyncingGate.holdsTimeline)
        SyncingGate.app = gate
        #expect(SyncingGate.holdsTimeline)
        gate.syncFinished(.synced)
        #expect(!SyncingGate.holdsTimeline)
        SyncingGate.app = nil
    }

    @Test func comingBackShowsItOnlyAfterAWhileAway() {
        let gate = gate(away: .seconds(30))
        gate.cameBack(after: .seconds(5))
        #expect(!gate.isShowing)
        gate.cameBack(after: .seconds(45))
        #expect(gate.isShowing)
        gate.syncFinished(.synced)
    }

    /// Just after a wake the network may not be back: finding none, the
    /// screen asks for the sync again rather than lifting.
    @Test func wakingWaitsForTheNetwork() async throws {
        let gate = gate(limit: .seconds(2), retryAfter: .milliseconds(50))
        var retries = 0
        gate.retry = { retries += 1 }
        gate.show(waitingForNetwork: true)
        gate.syncFinished(.failed(SyncStatus.offlineMessage))
        #expect(gate.isShowing)
        try await Task.sleep(for: .milliseconds(200))
        #expect(retries == 1)
        gate.syncFinished(.synced)
        #expect(!gate.isShowing)
        #expect(gate.lifted == .synced)
    }

    @Test func runningOutOfTimeWithNoNetworkSaysOffline() async throws {
        let gate = gate(limit: .milliseconds(200), retryAfter: .seconds(10))
        gate.show(waitingForNetwork: true)
        gate.syncFinished(.failed(SyncStatus.offlineMessage))
        try await Task.sleep(for: .milliseconds(400))
        #expect(!gate.isShowing)
        #expect(gate.lifted == .offline)
    }

    /// Waiting for the network is only for the showing that asked for it.
    @Test func otherShowingsLiftAtOnceOffline() {
        let gate = gate()
        gate.show(waitingForNetwork: true)
        gate.syncFinished(.synced)
        gate.show()
        gate.syncFinished(.failed(SyncStatus.offlineMessage))
        #expect(gate.lifted == .offline)
    }

    /// Asked again while up, as when the Mac and then its display wake, the
    /// screen keeps its animation.
    @Test func askedAgainWhileUpKeepsItsAnimation() throws {
        let defaults = try #require(UserDefaults(suiteName: "SyncingGateTests-\(UUID())"))
        let gate = gate(defaults: defaults)
        gate.show()
        let first = gate.scene
        gate.show(waitingForNetwork: true)
        #expect(gate.scene == first)
        #expect(gate.isShowing)
        gate.syncFinished(.synced)
    }

    @Test func aSyncNoOneWaitsForChangesNothing() {
        let gate = gate()
        gate.syncFinished(.failed(SyncStatus.offlineMessage))
        #expect(!gate.isShowing)
        #expect(gate.lifted == nil)
    }

    @Test func aLandedOrSlowSyncNeedsNoNote() {
        #expect(SyncingOverlay.text(for: .synced) == nil)
        #expect(SyncingOverlay.text(for: .slow) == nil)
        #expect(SyncingOverlay.text(for: .offline) != nil)
        #expect(SyncingOverlay.text(for: .failed) != nil)
    }

    @Test func neverShowsTheSameAnimationTwiceRunning() throws {
        let defaults = try #require(UserDefaults(suiteName: "SyncingGateTests-\(UUID())"))
        let gate = gate(defaults: defaults)
        var last: SyncingScene?
        var seen: Set<SyncingScene> = []
        for _ in 0..<60 {
            gate.show()
            #expect(gate.scene != last)
            last = gate.scene
            seen.insert(gate.scene)
            gate.syncFinished(.synced)
        }
        // All six take turns.
        #expect(seen == Set(SyncingScene.allCases))
    }

    @Test func remembersTheLastAnimationAcrossLaunches() throws {
        let defaults = try #require(UserDefaults(suiteName: "SyncingGateTests-\(UUID())"))
        defaults.set(SyncingScene.ribbon.rawValue, forKey: SyncingGate.lastSceneKey)
        var picked: SyncingScene?
        let gate = SyncingGate(settle: .zero, defaults: defaults) { last in
            picked = last
            return .masthead
        }
        gate.show()
        #expect(picked == .ribbon)
        #expect(defaults.string(forKey: SyncingGate.lastSceneKey) == SyncingScene.masthead.rawValue)
        gate.syncFinished(.synced)
    }

    /// The catch-up ending is what lifts the screen.
    @Test func statusTellsWhenACatchUpEnds() async throws {
        let status = SyncStatus(minimumShown: .zero)
        var ended: [SyncStatus.Phase] = []
        status.onCaughtUp = { ended.append($0) }
        status.finished(failure: nil, began: .now)
        #expect(ended == [.synced])
        // A background poll while not catching up says nothing.
        status.finished(failure: nil, began: .now)
        #expect(ended == [.synced])
        status.began()
        status.finished(failure: "CKError 3 networkUnavailable", began: .now)
        #expect(ended == [.synced, .failed(SyncStatus.offlineMessage)])
    }

    /// Each scene keeps its motion in the loop: the same moment one period
    /// on looks the same.
    @Test func scenesLoop() {
        typealias M = SyncingMotion
        #expect(M.loop(0.5, 2) == M.loop(2.5, 2))
        #expect(M.loop(0.1, 2, delay: 0.3) == 0)
        #expect(SyncingScenes.fall(0.9, from: 0.55, depth: 52) == 52)
        #expect(SyncingScenes.fall(0.5, from: 0.55, depth: 52) == 0)
    }
}
