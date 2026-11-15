import Foundation
import Observation

/// What the sync button shows. There is no idle state: sync is
/// starting, syncing, synced, or failed.
///
/// Only syncs the reader would notice are shown: start-up, a tap, and
/// coming back to the foreground. The background polls every few seconds
/// aren't, or the dots would never rest; a poll can still show a failure,
/// and the next poll that works clears it.
@MainActor
@Observable
final class SyncStatus {
    enum Phase: Equatable {
        /// From launch until the first sync finishes.
        case starting
        case syncing
        case synced
        /// The last sync failed; the text says why, for the reader.
        case failed(String)
    }

    private(set) var phase: Phase = .starting {
        didSet {
            let wasCatchingUp = oldValue == .starting || oldValue == .syncing
            if wasCatchingUp, !isCatchingUp { onCaughtUp?(phase) }
        }
    }
    /// Told when a catch-up ends, landed or failed, with how it ended.
    @ObservationIgnored var onCaughtUp: ((Phase) -> Void)?
    /// True from launch, a tap, or coming back until that sync finishes:
    /// the timeline holds its reading place until then, so a newer one
    /// from another device can arrive first.
    var isCatchingUp: Bool { phase == .starting || phase == .syncing }
    /// Which catch-up is under way, counting from 0 at launch, or nil.
    var catchUp: Int? { isCatchingUp ? round : nil }
    @ObservationIgnored private var round = 0

    /// What the sync status panel shows.
    struct Problem: Equatable {
        var at: Date
        var message: String
    }
    /// When a pass last reached iCloud, shown or not.
    private(set) var lastSynced: Date?
    /// The latest failures, newest first; a failure that repeats moves to
    /// the top rather than filling the list.
    private(set) var problems: [Problem] = []
    static let problemLimit = 8
    /// Changes sent and received since launch.
    private(set) var sent = 0
    private(set) var received = 0
    /// Local changes waiting to go up, or nil before the first count.
    var waiting: Int?
    /// When the shown sync began, so the dots circle at least one turn
    /// rather than flicker; nil when no shown sync is under way.
    @ObservationIgnored private var shownSince: ContinuousClock.Instant? = .now
    /// The same moment by the wall clock, which passes are stamped with: a
    /// pass that began before it is an older one that overlapped, and
    /// doesn't end the shown sync.
    @ObservationIgnored private var shownAt: Date? = .distantPast
    /// When the newest pass reported so far began: passes can finish out
    /// of order, and an older one's word never replaces a newer one's.
    @ObservationIgnored private var newestReported = Date.distantPast
    @ObservationIgnored private var settling: Task<Void, Never>?
    @ObservationIgnored private let minimumShown: Duration

    init(minimumShown: Duration = .milliseconds(1_200)) {
        self.minimumShown = minimumShown
    }

    /// A sync the reader asked for, or will notice, has begun.
    func began() {
        settling?.cancel()
        settling = nil
        if !isCatchingUp { round += 1 }
        // Start-up keeps its own animation until its first sync lands.
        if phase != .starting { phase = .syncing }
        // The circling counts from the first request; only passes begun
        // since the latest one can end it.
        if shownSince == nil { shownSince = .now }
        shownAt = .now
    }

    /// A sync pass that `began` then finished: `failure` is nil when it
    /// reached iCloud, or the framework's description of what went wrong.
    func finished(failure: String?, began: Date) {
        if let shownAt, began < shownAt {
            // An older pass that overlapped the shown one, which reports
            // for itself.
            return
        }
        guard began >= newestReported else { return }
        newestReported = began
        if let failure {
            note(Problem(at: .now, message: Self.message(for: failure)))
            settling?.cancel()
            settling = nil
            shownSince = nil
            shownAt = nil
            phase = .failed(Self.message(for: failure))
            return
        }
        lastSynced = .now
        guard let since = shownSince else {
            // A background poll: it only clears a failure.
            if case .failed = phase { phase = .synced }
            return
        }
        guard settling == nil else { return }
        let remaining = minimumShown - (ContinuousClock.now - since)
        guard remaining > .zero else { return settle() }
        settling = Task { [weak self] in
            try? await Task.sleep(for: remaining)
            guard !Task.isCancelled else { return }
            self?.settle()
        }
    }

    /// Counts what one pass sent and received.
    func tally(sent: Int, received: Int) {
        self.sent += sent
        self.received += received
    }

    private func note(_ problem: Problem) {
        problems.removeAll { $0.message == problem.message }
        problems.insert(problem, at: 0)
        if problems.count > Self.problemLimit { problems.removeLast(problems.count - Self.problemLimit) }
    }

    private func settle() {
        settling = nil
        shownSince = nil
        shownAt = nil
        phase = .synced
    }

    /// What a failure for want of a network says.
    nonisolated static let offlineMessage = "You're offline"

    /// The reader's words for a failure the framework describes as
    /// `CKError <code> <name> …`.
    nonisolated static func message(for failure: String) -> String {
        let reasons: [(String, String)] = [
            ("networkUnavailable", offlineMessage),
            ("networkFailure", offlineMessage),
            ("notAuthenticated", "Sign in to iCloud to sync"),
            ("quotaExceeded", "Your iCloud storage is full"),
            ("requestRateLimited", "iCloud asked Influx to wait"),
            ("zoneBusy", "iCloud asked Influx to wait"),
            ("serviceUnavailable", "iCloud isn't answering"),
            ("accountTemporarilyUnavailable", "Your iCloud account isn't ready"),
        ]
        if let reason = reasons.first(where: { failure.contains($0.0) }) { return reason.1 }
        return failure.hasPrefix("CKError") ? "iCloud didn't sync" : failure
    }
}
