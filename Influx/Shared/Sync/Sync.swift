import Foundation
import InfluxKit
import Synchronization
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// iCloud sync, as the app drives it: it hands the store's pending changes
/// to the InfluxSync framework and the framework's reports back to the store,
/// which decides everything. The framework holds CloudKit and is
/// loaded on the first sync, after the first screen, so CloudKit stays out
/// of launch.
///
/// Sync is off unless a container is configured for this build
/// (`InfluxCloudKitContainer` in Info.plist), so local and test builds, and
/// anything signed without the container's entitlement, run as before.
@MainActor
final class Sync {
    /// The container the build syncs with, or nil when it has none.
    static var containerID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "InfluxCloudKitContainer") as? String)?.nilIfBlank
    }

    /// One zone holds every record; CloudKit fetches a zone's changes in
    /// one pass, and nothing here needs sharing.
    private static let zoneName = "Flux"
    /// How many records go in one batch. CloudKit's limit is 400 changes
    /// per request.
    private nonisolated static let batchLimit = 400

    private let store: InfluxStore
    private let containerID: String
    /// Watches the store for changes to send.
    private var watching: Task<Void, Never>?
    /// Asks for changes from other devices every `pollInterval` while the
    /// app runs. iCloud's pushes usually say first, but a push can be
    /// late, dropped, or held while the device is busy, and a Mac that
    /// isn't the active app mostly gets none (influx-dev #140, which chose
    /// to keep the poll for that reason). Short enough that a second open
    /// device follows the reader's place within a few seconds; one
    /// zone-changes fetch with nothing new is tiny.
    private var polling: Task<Void, Never>?
    static let pollInterval: Duration = .seconds(5)
    private var didStart = false
    /// What the sync button shows.
    let status = SyncStatus()
    /// The "Syncing in Progress" screen, up from launch until the first
    /// sync lands.
    let gate = SyncingGate()
    /// Called when sources arrive from another device, so the feeds and
    /// accounts that fetch them refresh now rather than on their timers.
    var onSourcesChanged: (() -> Void)?

    init(store: InfluxStore, containerID: String) {
        self.store = store
        self.containerID = containerID
        status.onCaughtUp = { [weak gate] phase in gate?.syncFinished(phase) }
        gate.show()
        gate.retry = { [weak self] in self?.syncNow() }
        gate.onLift = { [weak self] how in self?.note("the syncing screen lifted: \(how)") }
    }

    /// Adds a line about the app to the sync journal.
    func note(_ message: String) {
        let now = Date()
        Task { [store] in await store.noteInJournal(.app, message, at: now) }
    }

    /// The failure the last pass ended with, so a failure that repeats on
    /// every poll, as offline does, is in the journal once.
    private var lastFailure: String?

    private func passFinished(failure: String?) {
        guard failure != lastFailure else { return }
        lastFailure = failure
        note(failure.map { "sync failed: \($0)" } ?? "sync reached iCloud again")
    }

    /// Starts syncing: loads the framework, hands it the engine's saved
    /// state, and then tells it whenever the store has something to send.
    /// Called after the first screen is up, never during launch.
    func start() async {
        guard !didStart else { return }
        didStart = true
        let state = try? await store.syncEngineState(for: containerID)
        // What an earlier build on this device couldn't read, this one may.
        if let read = try? await store.readKeptSyncRecords(), read.changed.contains(.source) {
            onSourcesChanged?()
        }
        guard let start = InfluxSyncFramework.start else {
            didStart = false
            status.finished(failure: "iCloud sync couldn't load", began: .now)
            return
        }
        let nextBatch: InfluxSyncFramework.NextBatch = { [store] limit in Sync.batch(from: store, limit: limit) }
        let didChange: InfluxSyncFramework.DidChange = { [store, weak self] report in
            Sync.report(report as Data, to: store, sourcesChanged: {
                Task { @MainActor in self?.onSourcesChanged?() }
            }, tallied: { sent, received in
                Task { @MainActor in self?.status.tally(sent: sent, received: received) }
            })
        }
        let saveState: InfluxSyncFramework.SaveState = { [store, containerID] data in
            let data = data as Data
            Task.detached { try? await store.saveSyncEngineState(data, for: containerID) }
        }
        let finished: InfluxSyncFramework.Finished = { [weak self] failure, began in
            let failure = failure as String?
            let began = Date(timeIntervalSince1970: began)
            Task { @MainActor in
                self?.status.finished(failure: failure, began: began)
                self?.passFinished(failure: failure)
            }
        }
        let containerID = containerID, zoneName = Self.zoneName
        // Off the main thread: starting queues the pending changes, which
        // reads them from the store and waits.
        let started = await Task.detached {
            start(containerID as NSString, zoneName as NSString, state as NSData?, nextBatch, didChange, saveState, finished)
        }.value
        guard started else {
            // The button offers to try again.
            didStart = false
            status.finished(failure: "iCloud sync couldn't start", began: .now)
            note("iCloud sync couldn't start")
            return
        }
        note("Influx \(BuildInfo.versionLine) started sync with \(containerID), \(state == nil ? "from the beginning" : "from its saved state")")
        // Pushes from iCloud wake the engine when another device changes
        // something. Registered only now, after the first screen and
        // once sync is running, so launch stays as lean as before.
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #else
        NSApplication.shared.registerForRemoteNotifications()
        #endif
        polling = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                Self.nudge()
            }
        }
        // A change made here, by the reader or a fetch, wakes the engine.
        watching = Task { [store, status] in
            do {
                for try await pending in store.observePendingSyncChanges() {
                    guard !Task.isCancelled else { return }
                    status.waiting = pending.count
                    Self.nudge()
                }
            } catch {
                // The observation ends only with the store; nothing to do.
            }
        }
    }

    /// Syncs now: for the reader's refresh, and for coming back to the
    /// foreground. The button shows it until it finishes.
    func syncNow() {
        guard didStart else { return }
        status.began()
        Self.nudge()
    }

    /// Coming back to the foreground after `away`: syncs now, behind the
    /// "Syncing in Progress" screen when the app was away long enough for
    /// another device to have moved the place. `waitingForNetwork` after a
    /// wake, when the network may take a moment to return.
    func cameBack(after away: Duration, waitingForNetwork: Bool = false) {
        gate.cameBack(after: away, waitingForNetwork: waitingForNetwork)
        if away >= .seconds(1) {
            note("came back after \(away.components.seconds) s\(gate.isShowing ? ", behind the syncing screen" : "")")
        }
        syncNow()
        // Nothing to wait for when sync couldn't start.
        if gate.isShowing, !status.isCatchingUp { gate.syncFinished(status.phase) }
    }

    /// Sends what's waiting now, and returns once iCloud has all of it or
    /// `limit` has passed: for when the app is put away, so the reader's
    /// last place is in iCloud before another device opens.
    func sendWaiting(limit: Duration = .seconds(10)) async {
        guard didStart else { return }
        Self.nudge()
        let sent = await Self.outboxEmptied(in: store, within: limit)
        await store.noteInJournal(.app, sent ? "put away with everything sent" : "put away with changes still waiting to send")
    }

    // MARK: Diagnostics

    /// How far back, and how many lines, a copy of the journal goes.
    nonisolated static let diagnosticsWindow: TimeInterval = 48 * 3_600

    /// Everything that explains what sync did lately, as text to copy: the
    /// build, the status, the journal's last two days, and iCloud's own
    /// events. It names posts by their addresses, so the reader decides
    /// who sees it.
    func diagnostics() async -> String {
        var header = ["Influx \(BuildInfo.versionLine), \(Self.platform)", "iCloud container \(containerID)"]
        header.append("Status: \(status.phase); last reached iCloud \(status.lastSynced.map { $0.ISO8601Format() } ?? "never"); "
            + "\(status.waiting.map(String.init) ?? "?") waiting to send")
        return await Self.diagnostics(from: store, header: header)
    }

    nonisolated static func diagnostics(from store: InfluxStore, header: [String], now: Date = Date(),
                                        defaults: UserDefaults = .standard) async -> String {
        var lines = ["Influx sync diagnostics, copied \(now.ISO8601Format())"] + header
        let journal = (try? await store.syncJournal(since: now.addingTimeInterval(-diagnosticsWindow))) ?? []
        lines += ["", "Journal, last 48 hours (\(journal.count) line\(journal.count == 1 ? "" : "s"))"] + journal.map(\.line)
        let events = defaults.stringArray(forKey: "InfluxSyncEvents") ?? []
        lines += ["", "iCloud events (\(events.count))"] + events
        if let merge = defaults.string(forKey: "InfluxSyncLastMerge") {
            lines += ["", "Last merge", merge]
        }
        if let probe = defaults.dictionary(forKey: "InfluxTimelineProbe"),
           let data = try? JSONSerialization.data(withJSONObject: probe, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            lines += ["", "Timeline now", text]
        }
        return lines.joined(separator: "\n")
    }

    private nonisolated static var platform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }

    /// Waits until the store has nothing left to send, looking every
    /// `poll`; false when `limit` passed first, as it does offline.
    nonisolated static func outboxEmptied(in store: InfluxStore, within limit: Duration,
                                          poll: Duration = .milliseconds(100)) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while true {
            // A store that can't be read has nothing this can wait for.
            guard let pending = try? await store.pendingSyncChanges() else { return false }
            if pending.isEmpty { return true }
            guard ContinuousClock.now + poll < deadline else { return false }
            try? await Task.sleep(for: poll)
        }
    }

    /// The sync button: syncs now, or starts sync again if it couldn't.
    func tapped() {
        if didStart {
            syncNow()
        } else {
            status.began()
            Task { await start() }
        }
    }

    /// Asks the framework to sync, off the main thread: it reads the next
    /// batch from the store and waits for it. On a queue of its own rather
    /// than Swift concurrency's pool, which must never be kept waiting, and
    /// one at a time: a nudge made while another is waiting to run joins
    /// it, so polls can't pile up behind a busy store.
    private nonisolated static func nudge() {
        let alreadyQueued = nudgeQueued.withLock { queued in
            defer { queued = true }
            return queued
        }
        guard !alreadyQueued else { return }
        nudges.async {
            // Cleared before the pass starts, so a nudge made during it
            // queues one more pass, which begins after the request.
            nudgeQueued.withLock { $0 = false }
            InfluxSyncFramework.now?()
        }
    }

    private nonisolated static let nudges = DispatchQueue(label: "dev.bespokebits.influx.sync-nudge", qos: .utility)
    private nonisolated static let nudgeQueued = Mutex(false)

    func stop() {
        watching?.cancel()
        watching = nil
        polling?.cancel()
        polling = nil
        guard didStart else { return }
        didStart = false
        InfluxSyncFramework.stop?()
    }

    // MARK: Across the framework boundary

    /// The next records to send, as the framework's JSON. Called on the
    /// framework's thread, so it reads the store synchronously; the reads
    /// are small and sync never runs during launch.
    private nonisolated static func batch(from store: InfluxStore, limit: Int) -> NSData? {
        let payload = SyncBoundary.batch(from: store, limit: min(limit, batchLimit))
        return payload as NSData?
    }

    /// Called on the framework's thread with what the server did. Waits
    /// for the store to take it, so the framework only moves its place in
    /// the server's changes (the engine's state, the direct fetch's token)
    /// past records the store has kept.
    /// Returns whether the store kept it.
    private nonisolated static func report(
        _ data: Data, to store: InfluxStore,
        sourcesChanged: @escaping @Sendable () -> Void,
        tallied: @escaping @Sendable (_ sent: Int, _ received: Int) -> Void
    ) -> Bool {
        let applied = SyncBoundary.apply(data, to: store)
        if applied.sourcesChanged { sourcesChanged() }
        if applied.sent > 0 || applied.received > 0 { tallied(applied.sent, applied.received) }
        return applied.kept
    }
}

/// Turns the store's records into the framework's JSON, and its reports back
/// into store calls. Nothing here decides anything: the rules are in
/// InfluxKit.
///
/// The framework calls in on its own threads, often Swift concurrency's
/// pool, and waits for the answer, so everything here uses the store's
/// blocking calls. Waiting there on a task instead deadlocked sync once
/// every pool thread was waiting.
enum SyncBoundary {
    static func batch(from store: InfluxStore, limit: Int) -> Data? {
        guard let pending = try? store.blocking.pendingBatch(limit: limit) else { return nil }
        var batch = Batch()
        for (change, record) in pending {
            if change.isDeletion {
                batch.delete.append(change.name)
            } else if let record {
                batch.save.append(OutgoingRecord(
                    name: record.record.name, type: record.record.type.rawValue, key: record.record.key,
                    payload: record.record.payload, systemFields: record.systemFields, version: record.version
                ))
            }
        }
        guard !batch.save.isEmpty || !batch.delete.isEmpty else { return nil }
        return try? JSONEncoder().encode(batch)
    }

    struct Applied: Sendable {
        /// False when the store couldn't take what was fetched, so the
        /// framework must fetch it again.
        var kept: Bool
        var sourcesChanged: Bool
        /// Changes iCloud took from this device, and changes it brought.
        var sent = 0
        var received = 0
    }

    /// Applies a report from the framework.
    static func apply(_ data: Data, to store: InfluxStore, defaults: UserDefaults = .standard) -> Applied {
        let report: Report
        do {
            report = try JSONDecoder().decode(Report.self, from: data)
        } catch {
            defaults.set("\(Date().ISO8601Format()) unreadable report: \(error)", forKey: "InfluxSyncLastMerge")
            return Applied(kept: false, sourcesChanged: false)
        }
        if report.wasReset {
            let reset = (try? store.blocking.resetSync(uploadingEverything: true)) != nil
            return Applied(kept: reset, sourcesChanged: false)
        }
        try? store.blocking.didSaveSyncRecords(report.saved.map {
            SavedSyncRecord(name: $0.name, version: $0.version, systemFields: $0.systemFields)
        })
        try? store.blocking.didDeleteSyncRecords(named: report.deleted)
        try? store.blocking.forgetSyncSystemFields(named: report.unknown)
        var fetched: [FetchedSyncRecord] = []
        // Types a newer Influx on another device added: the store keeps
        // them as they came, for the build that reads them.
        var unknown: [UnknownSyncRecord] = []
        for record in report.fetched {
            if let type = SyncRecordType(rawValue: record.type) {
                fetched.append(FetchedSyncRecord(
                    record: SyncRecord(type: type, key: record.key, payload: record.payload),
                    systemFields: record.systemFields
                ))
            } else {
                unknown.append(UnknownSyncRecord(
                    name: record.name, type: record.type, key: record.key, payload: record.payload, systemFields: record.systemFields
                ))
            }
        }
        let merged: SyncMergeResult?
        do {
            merged = try store.blocking.mergeSyncRecords(fetched, unknown: unknown, deletions: report.removed)
        } catch {
            merged = nil
            defaults.set("\(Date().ISO8601Format()) merging \(fetched.count) failed: \(error)", forKey: "InfluxSyncLastMerge")
        }
        if let merged, !report.fetched.isEmpty || !report.removed.isEmpty {
            // Read back with the framework's InfluxSyncEvents when a device's
            // sync needs explaining.
            let types = Set(merged.changed.map(\.rawValue)).sorted()
            defaults.set(
                "\(Date().ISO8601Format()) merged \(fetched.count) of \(report.fetched.count) fetched, \(report.removed.count) removed, \(merged.unread) kept unread; changed \(types)",
                forKey: "InfluxSyncLastMerge"
            )
        }
        return Applied(
            kept: merged != nil, sourcesChanged: merged?.changed.contains(.source) ?? false,
            sent: report.saved.count + report.deleted.count,
            received: merged == nil ? 0 : fetched.count + report.removed.count
        )
    }

    // The JSON the framework reads and writes (Influx/Sync/InfluxSync.swift).

    struct Batch: Encodable {
        var save: [OutgoingRecord] = []
        var delete: [String] = []
    }

    struct OutgoingRecord: Encodable {
        var name: String
        var type: String
        var key: String
        var payload: Data
        var systemFields: Data?
        var version: Int64
    }

    struct Report: Decodable {
        var saved: [SavedRecord] = []
        var deleted: [String] = []
        var unknown: [String] = []
        var fetched: [FetchedRecord] = []
        var removed: [String] = []
        var wasReset = false
    }

    struct SavedRecord: Decodable {
        var name: String
        var version: Int64
        var systemFields: Data
    }

    struct FetchedRecord: Decodable {
        var name: String
        var type: String
        var key: String
        var payload: Data
        var systemFields: Data
    }
}

/// The InfluxSync framework's entry points, found by name the first time
/// (`EmbeddedFramework`).
private enum InfluxSyncFramework {
    typealias NextBatch = @Sendable @convention(block) (Int) -> NSData?
    typealias DidChange = @Sendable @convention(block) (NSData) -> Bool
    typealias SaveState = @Sendable @convention(block) (NSData) -> Void
    typealias Finished = @Sendable @convention(block) (NSString?, Double) -> Void
    typealias Start = @convention(c) (
        NSString, NSString, NSData?,
        @escaping NextBatch, @escaping DidChange, @escaping SaveState, @escaping Finished
    ) -> Bool
    typealias Now = @convention(c) () -> Void

    static var start: Start? {
        EmbeddedFramework.symbol("influx_sync_start", in: "InfluxSync").map { unsafeBitCast($0, to: Start.self) }
    }

    static var now: Now? {
        EmbeddedFramework.symbol("influx_sync_now", in: "InfluxSync").map { unsafeBitCast($0, to: Now.self) }
    }

    static var stop: Now? {
        EmbeddedFramework.symbol("influx_sync_stop", in: "InfluxSync").map { unsafeBitCast($0, to: Now.self) }
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
