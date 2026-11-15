import Foundation
import Observation

/// The "Syncing in Progress" screen, and when it shows. It covers the
/// timeline from launch, and on coming back after a while, until the
/// catch-up sync lands, so the reader can't scroll from a place another
/// device has since moved on from: a scroll then would be the last move,
/// win everywhere, and lose their place (influx-dev #106).
///
/// It lifts when the sync lands, at once when it fails (offline included),
/// and after `limit` at the most, when the timeline opens on this device's
/// own place. When the place another device sent is still stuck among
/// this device's newest rows while its own fetch brings the posts before
/// it, the screen waits for those too, up to `placeLimit` from when it
/// showed (influx-dev #119): a scroll in that time would lose the place.
@MainActor
@Observable
final class SyncingGate {
    /// How the screen last lifted, which says what the note under the bar
    /// tells the reader.
    enum Lift: Equatable {
        /// The sync landed: the timeline is on the place it brought.
        case synced
        /// No network: the timeline is on this device's own place.
        case offline
        /// The sync failed some other way.
        case failed
        /// iCloud took longer than `limit`.
        case slow
    }

    private(set) var isShowing = false
    /// The animation shown this time.
    private(set) var scene: SyncingScene = .inTray
    /// How it lifted last, or nil while showing or before it ever has.
    private(set) var lifted: Lift?

    /// The app's own screen. Gates made elsewhere, as in tests, hold nothing.
    static weak var app: SyncingGate?

    /// True while the app's screen is up. The timelines read it to refuse
    /// every way of moving the reader that the SwiftUI cover doesn't stop
    /// by itself: VoiceOver, keys, the Mac's wheel and scroller, the status
    /// bar and jumps from menus.
    static var holdsTimeline: Bool { app?.isShowing == true }

    /// The longest the screen waits for the sync.
    @ObservationIgnored let limit: Duration
    /// How long it stays after the sync lands, so the place it brought has
    /// reached the timeline before the screen goes.
    @ObservationIgnored let settle: Duration
    /// How long the app must have been away for coming back to show it.
    @ObservationIgnored let away: Duration
    /// How long a wait for the network leaves between tries.
    @ObservationIgnored let retryAfter: Duration
    /// The longest the screen stays up, from when it showed, while the
    /// place it brought waits for this device's own posts before it.
    @ObservationIgnored let placeLimit: Duration
    /// Whether a place from another device is still stuck among this
    /// device's newest rows, with a fetch under way that can bring the
    /// posts before it. Asked when the screen would lift, and every
    /// `placePoll` after that while it says yes.
    @ObservationIgnored var placeLoading: () -> Bool = { false }
    @ObservationIgnored let placePoll: Duration
    /// When the screen showed this time.
    @ObservationIgnored private var shownSince: ContinuousClock.Instant = .now
    @ObservationIgnored private var placeWait: Task<Void, Never>?
    /// Told how the screen lifted, each time it does.
    @ObservationIgnored var onLift: ((Lift) -> Void)?
    /// Asks for the sync again, while waiting for the network.
    @ObservationIgnored var retry: (() -> Void)?
    @ObservationIgnored private var waitsForNetwork = false
    /// Whether a sync found no network while waiting for it, so running out
    /// of time means offline rather than slow.
    @ObservationIgnored private var sawOffline = false
    @ObservationIgnored private let pick: (SyncingScene?) -> SyncingScene
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private var round = 0
    @ObservationIgnored private var timer: Task<Void, Never>?

    static let lastSceneKey = "InfluxSyncingSceneLast"

    init(limit: Duration = .seconds(3), settle: Duration = .milliseconds(250), away: Duration = .seconds(30),
         retryAfter: Duration = .milliseconds(500), placeLimit: Duration = .seconds(10),
         placePoll: Duration = .milliseconds(100), defaults: UserDefaults? = .standard,
         pick: @escaping (SyncingScene?) -> SyncingScene = { SyncingScene.random(after: $0) }) {
        self.limit = limit
        self.settle = settle
        self.away = away
        self.retryAfter = retryAfter
        self.placeLimit = placeLimit
        self.placePoll = placePoll
        self.defaults = defaults
        self.pick = pick
    }

    /// Covers the timeline until the sync under way lands: at launch, and
    /// on coming back. Asked again while up, as when the Mac wakes and its
    /// display wakes a moment later, it keeps its animation and waits for
    /// the sync asked for since.
    ///
    /// `waitingForNetwork`: just after a wake the network may not be back
    /// yet, so a sync that finds no network asks for another (`retry`)
    /// rather than lifting, until `limit`.
    func show(waitingForNetwork: Bool = false) {
        round += 1
        let mine = round
        if !isShowing {
            let last = defaults?.string(forKey: Self.lastSceneKey).flatMap(SyncingScene.init(rawValue:))
            scene = pick(last)
            defaults?.set(scene.rawValue, forKey: Self.lastSceneKey)
            sawOffline = false
            shownSince = .now
        }
        waitsForNetwork = waitingForNetwork || (isShowing && waitsForNetwork)
        lifted = nil
        isShowing = true
        timer?.cancel()
        placeWait?.cancel()
        placeWait = nil
        timer = Task { [weak self, limit] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled, let self else { return }
            if self.sawOffline {
                self.lift(.offline, round: mine)
            } else {
                self.liftOnPlace(.slow, round: mine)
            }
        }
    }

    /// Shows the screen again if the app was away for at least `away`.
    func cameBack(after time: Duration, waitingForNetwork: Bool = false) {
        guard time >= away else { return }
        show(waitingForNetwork: waitingForNetwork)
    }

    /// The sync the screen waits for has finished, in `phase`.
    func syncFinished(_ phase: SyncStatus.Phase) {
        guard isShowing else { return }
        let mine = round
        switch phase {
        case .failed(let message) where message == SyncStatus.offlineMessage && waitsForNetwork:
            // Waking, the network can take a few seconds to come back.
            sawOffline = true
            Task { [weak self, retryAfter] in
                try? await Task.sleep(for: retryAfter)
                guard let self, self.isShowing, self.round == mine else { return }
                self.retry?()
            }
        case .failed(let message):
            lift(message == SyncStatus.offlineMessage ? .offline : .failed, round: mine)
        case .synced, .starting, .syncing:
            // The network came back: running out of time now isn't offline.
            sawOffline = false
            guard settle > .zero else { return liftOnPlace(.synced, round: mine) }
            Task { [weak self, settle] in
                try? await Task.sleep(for: settle)
                self?.liftOnPlace(.synced, round: mine)
            }
        }
    }

    /// Lifts as `how`, unless the place is still waiting for the posts
    /// before it: then once it isn't, or at `placeLimit` from when the
    /// screen showed, whichever comes first.
    private func liftOnPlace(_ how: Lift, round: Int) {
        guard isShowing, round == self.round, placeWait == nil else { return }
        guard placeLoading(), ContinuousClock.now - shownSince < placeLimit else {
            return lift(how, round: round)
        }
        placeWait = Task { [weak self, placePoll] in
            while let self, !Task.isCancelled, self.isShowing, self.round == round {
                guard self.placeLoading(), ContinuousClock.now - self.shownSince < self.placeLimit else {
                    self.placeWait = nil
                    self.lift(how, round: round)
                    return
                }
                try? await Task.sleep(for: placePoll)
            }
        }
    }

    private func lift(_ how: Lift, round: Int) {
        guard isShowing, round == self.round else { return }
        timer?.cancel()
        timer = nil
        placeWait?.cancel()
        placeWait = nil
        waitsForNetwork = false
        isShowing = false
        lifted = how
        onLift?(how)
    }
}

/// The animations the screen rotates through, one picked at random each
/// time, never the same twice running.
enum SyncingScene: String, CaseIterable, Sendable {
    /// The icon: three slips drop into the tray.
    case inTray
    /// Dots in the source colours stream down into the tray.
    case confluence
    /// A broadsheet page prints line by line, and a row is marked.
    case pressRun
    /// A timeline scrolls, slows, and a bookmark drops on a row.
    case ribbon
    /// "Influx" inks in letter by letter over a running rule.
    case masthead
    /// The sync mark: the dots circle and drop into the tray.
    case threeSlips

    static func random(after last: SyncingScene?) -> SyncingScene {
        var generator = SystemRandomNumberGenerator()
        return random(after: last, using: &generator)
    }

    static func random(after last: SyncingScene?, using generator: inout some RandomNumberGenerator) -> SyncingScene {
        let choices = allCases.filter { $0 != last }
        return choices.randomElement(using: &generator)!
    }
}
