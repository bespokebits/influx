// iCloud sync, in a framework of its own: the app embeds it without linking
// it and loads it after the first screen, so CloudKit stays out of launch
// (as InfluxVideo does for AVFoundation and InfluxWebSignIn for
// AuthenticationServices). The app calls `influx_sync_start`, `influx_sync_now`
// and `influx_sync_stop` through dlsym.
//
// This file holds only CloudKit: a `CKSyncEngine` and its delegate. Every
// decision about what a record means, and which of two changes wins, is in
// InfluxKit, which this framework must not link, because the app
// links it statically. So records cross this boundary as JSON, in the shape
// InfluxKit's `SyncRecord` and friends encode, and this side treats a
// payload as opaque bytes.
import CloudKit
import Foundation
import os

/// Asks the app for the next records to send, as JSON:
/// `{"save": [{"name", "type", "key", "payload", "systemFields"?, "version"}],
///   "delete": ["name"]}`, at most `limit` entries in all. Empty when there
/// is nothing to send.
public typealias NextBatch = @Sendable @convention(block) (Int) -> NSData?
/// Tells the app what the server did, as JSON:
/// `{"saved": [{"name", "version", "systemFields"}], "deleted": ["name"],
///   "unknown": ["name"], "fetched": [{"name", "type", "key", "payload", "systemFields"}],
///   "removed": ["name"], "wasReset": false}`. Returns whether the app kept
/// it: false when its store couldn't merge what was fetched, so the
/// framework mustn't move its place in the server's changes past it.
public typealias DidChange = @Sendable @convention(block) (NSData) -> Bool
/// Hands the app the engine's state to keep, and asks for it at startup.
public typealias SaveState = @Sendable @convention(block) (NSData) -> Void
/// Tells the app a sync pass (one `influx_sync_now`, or the first one at
/// start) has finished: nil when it reached iCloud, or what went wrong,
/// as the log shows it (`CKError <code> <name> …`); and when the pass
/// began, in seconds since 1970, so the app can tell an older pass that
/// overlapped from the one it asked for.
public typealias Finished = @Sendable @convention(block) (NSString?, Double) -> Void

/// The engine running now, if any.
private let engine = OSAllocatedUnfairLock<Engine?>(initialState: nil)

/// Starts syncing the container, continuing from `state` (the bytes last
/// given to `saveState`, or nil the first time). False when CloudKit
/// wouldn't start, e.g. the container isn't available to this build.
@_cdecl("influx_sync_start")
public func influx_sync_start(
    _ container: NSString, _ zone: NSString, _ state: NSData?,
    _ nextBatch: @escaping NextBatch, _ didChange: @escaping DidChange, _ saveState: @escaping SaveState,
    _ finished: @escaping Finished
) -> Bool {
    // Bridged before the lock, since NSString and NSData aren't Sendable.
    let container = container as String, zone = zone as String, state = state as Data?
    return engine.withLock { current in
        current?.stop()
        let started = Engine(
            container: container, zone: zone, state: state,
            nextBatch: nextBatch, didChange: didChange, saveState: saveState, finished: finished
        )
        current = started
        return started != nil
    }
}

/// Asks for one sync now: sends what's pending and fetches what's new. The
/// engine syncs on its own too; this is for the reader pulling to refresh,
/// and for the app coming back to the foreground.
@_cdecl("influx_sync_now")
public func influx_sync_now() {
    engine.withLock { $0 }?.syncNow()
}

/// Stops syncing, as when the reader turns sync off.
@_cdecl("influx_sync_stop")
public func influx_sync_stop() {
    engine.withLock { current in
        current?.stop()
        current = nil
    }
}

// MARK: The engine

private let log = Logger(subsystem: "dev.bespokebits.influx", category: "Sync")

/// Logs a sync event publicly, and keeps the last few in the app's
/// defaults (`InfluxSyncEvents`), so a device's sync can be read from a copy
/// of its container when its logs can't be reached. `kept` false only
/// logs: a pass that found nothing says so every few seconds, and kept,
/// those lines pushed everything else out in under two minutes.
private func note(_ message: String, error: Bool = false, kept: Bool = true) {
    if error { log.error("\(message, privacy: .public)") } else { log.notice("\(message, privacy: .public)") }
    guard kept else { return }
    let line = "\(Date().ISO8601Format()) \(message)"
    recentEvents.withLock { events in
        events.append(line)
        if events.count > 200 { events.removeFirst(events.count - 200) }
        UserDefaults.standard.set(events, forKey: "InfluxSyncEvents")
    }
}

private let recentEvents = OSAllocatedUnfairLock<[String]>(
    initialState: UserDefaults.standard.stringArray(forKey: "InfluxSyncEvents") ?? []
)

/// One `CKSyncEngine` over one custom zone, with the app's callbacks.
private final class Engine: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    /// What a record's fields are called in CloudKit. The payload is the
    /// JSON InfluxKit encoded, and `key` is its key. Both are written to
    /// encrypted fields, so iCloud holds them encrypted with a key from the
    /// reader's iCloud Keychain; a field's type is fixed once the schema has
    /// it, so the encrypted ones have names of their own. Records saved
    /// before still have the plain fields until they next change, and are
    /// read from those. CloudKit/schema.ckdb declares all four on every
    /// record type (CloudKitSchemaTests reads them from here).
    private enum Field {
        static let key = "encryptedKey"
        static let payload = "encryptedPayload"
        static let plainKey = "key"
        static let plainPayload = "payload"
    }

    private let zoneID: CKRecordZone.ID
    private let nextBatch: NextBatch
    private let didChange: DidChange
    private let saveState: SaveState
    private let finished: Finished
    private var syncEngine: CKSyncEngine?
    private let database: CKDatabase
    /// The change tag of each record this device last saved, so a direct
    /// fetch skips its own saves coming back instead of merging them again.
    private let savedTags = OSAllocatedUnfairLock<[String: String]>(initialState: [:])
    /// Failures the engine reported record by record (a save it rejected, a
    /// zone it couldn't fetch or save), numbered, so each pass, overlapping
    /// or not, reports the first one since it began even when its fetch
    /// and send returned.
    private let reportedFailures = OSAllocatedUnfairLock(initialState: ReportedFailures())
    /// Who waits on the direct fetch under way, or nil when none runs, so
    /// overlapping requests share it.
    private let directFetch = OSAllocatedUnfairLock<[@Sendable (String?) -> Void]?>(initialState: nil)
    /// Fetches from the engine the app couldn't keep, delivered again at
    /// the next sync: the engine has already moved past them.
    private let undelivered = OSAllocatedUnfairLock<[Report]>(initialState: [])
    /// The version of each record last handed to CloudKit, so a save it
    /// confirms clears that version and no later one (the app keeps a
    /// record pending until the version it sent is confirmed).
    private let sentVersions = OSAllocatedUnfairLock<[String: Int64]>(initialState: [:])

    init?(container: String, zone: String, state: Data?,
          nextBatch: @escaping NextBatch, didChange: @escaping DidChange, saveState: @escaping SaveState,
          finished: @escaping Finished) {
        self.zoneID = CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
        self.nextBatch = nextBatch
        self.didChange = didChange
        self.saveState = saveState
        self.finished = finished
        let cloud = CKContainer(identifier: container)
        let database = cloud.privateCloudDatabase
        self.database = database
        super.init()

        cloud.accountStatus { status, error in
            note("iCloud account status \(status.rawValue)\(error.map { " error \(Self.describe($0))" } ?? "")")
        }
        var configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: state.flatMap { Self.deserializedState($0) },
            delegate: self
        )
        configuration.automaticallySync = true
        let syncEngine = CKSyncEngine(configuration)
        self.syncEngine = syncEngine
        note("started for \(container), with \(state == nil ? "no saved state" : "saved state")")
        // The zone is created with the first batch; a zone already there is
        // left alone. Pending changes from the app go in now, so a device
        // that was off catches up on the first pass.
        queuePendingWork()
        // Every start fetches once, then sends.
        syncNow()
    }

    func stop() {
        syncEngine = nil
    }

    /// One pass: the direct fetch, and the engine's fetch and send, side
    /// by side. Tells the app when all three are done, and the first thing
    /// that failed.
    func syncNow() {
        queuePendingWork()
        guard let syncEngine else { return }
        retryUndelivered()
        let finished = finished
        let firstFailure = reportedFailures.withLock { $0.next }
        let began = Date().timeIntervalSince1970
        Task {
            async let direct: String? = withCheckedContinuation { done in
                self.fetchDirectly { done.resume(returning: $0) }
            }
            var failure: String?
            do {
                try await syncEngine.fetchChanges()
            } catch {
                note("fetch failed: \(Self.describe(error))", error: true)
                failure = Self.describe(error)
            }
            do {
                try await syncEngine.sendChanges()
            } catch {
                note("send failed: \(Self.describe(error))", error: true)
                failure = failure ?? Self.describe(error)
            }
            let directFailure = await direct
            let reported = self.reportedFailures.withLock { $0.first(since: firstFailure) }
            finished((directFailure ?? failure ?? reported) as NSString?, began)
        }
    }

    // MARK: Fetching without waiting for a push

    /// The zone's change token from the last direct fetch.
    /// Renamed when a Influx needs every record fetched once more: v2, so a
    /// device compares each position by when it was placed.
    private static let tokenKey = "FluxSyncZoneToken.v2"

    /// Fetches the zone's changes since the last direct fetch, without the
    /// engine. `CKSyncEngine.fetchChanges()` only reaches the server when a
    /// push has told it something changed (or, now and then, at launch and
    /// on foreground), and pushes don't always come. On two devices they
    /// were prompt on an iPhone in front and on a Mac that was the active
    /// app, but a Mac that wasn't the active app got one push for seven
    /// changes, and would have shown the rest only when it was next
    /// brought to the front (influx-dev #140). This asks the server every
    /// time, so it must stay until pushes are shown to cover that case.
    /// What it finds goes to the app like the engine's fetches; the merges
    /// don't mind seeing a record twice.
    /// `done` gets nil when the fetch reached the zone, or what failed.
    private func fetchDirectly(then done: @escaping @Sendable (String?) -> Void) {
        let started = directFetch.withLock { waiting in
            if waiting != nil {
                waiting?.append(done)
                return false
            }
            waiting = [done]
            return true
        }
        guard started else { return }
        let token = UserDefaults.standard.data(forKey: Self.tokenKey).flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        fetchZone(since: token, retried: false)
    }

    private func fetchZone(since token: CKServerChangeToken?, retried: Bool) {
        let zoneID = zoneID
        let found = OSAllocatedUnfairLock(initialState: Report())
        // Kept archived: the token type isn't Sendable.
        let latest = OSAllocatedUnfairLock<Data?>(initialState: nil)
        let configuration = CKFetchRecordZoneChangesOperation.ZoneConfiguration(previousServerChangeToken: token)
        let operation = CKFetchRecordZoneChangesOperation(
            recordZoneIDs: [zoneID], configurationsByRecordZoneID: [zoneID: configuration]
        )
        operation.fetchAllChanges = true
        operation.qualityOfService = .userInitiated
        let savedTags = savedTags
        // A record that failed to come keeps the token where it was, so the
        // next fetch asks for it again.
        let missed = OSAllocatedUnfairLock(initialState: 0)
        operation.recordWasChangedBlock = { id, result in
            guard case .success(let record) = result else {
                if case .failure(let error) = result {
                    note("direct fetch missed \(id.recordName): \(Self.describe(error))", error: true)
                }
                missed.withLock { $0 += 1 }
                return
            }
            let name = record.recordID.recordName
            let own = savedTags.withLock { tags in
                guard let tag = record.recordChangeTag, tags[name] == tag else { return false }
                tags[name] = nil
                return true
            }
            guard !own, let fetched = Self.fetched(record) else { return }
            found.withLock { $0.fetched.append(fetched) }
        }
        operation.recordWithIDWasDeletedBlock = { id, _ in
            found.withLock { $0.removed.append(id.recordName) }
        }
        operation.recordZoneChangeTokensUpdatedBlock = { _, token, _ in
            let data = token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
            if let data { latest.withLock { $0 = data } }
        }
        operation.recordZoneFetchResultBlock = { _, result in
            if case .success(let done) = result,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: done.serverChangeToken, requiringSecureCoding: true) {
                latest.withLock { $0 = data }
            }
        }
        operation.fetchRecordZoneChangesResultBlock = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                let report = found.withLock { $0 }
                let types = Dictionary(grouping: report.fetched, by: \.type).mapValues(\.count)
                note("fetched directly: \(report.fetched.count) records \(types.sorted { $0.key < $1.key }), \(report.removed.count) deletions",
                     kept: !report.isEmpty)
                // The app has stored them when this returns, so the token
                // only moves past records that are kept. If they weren't,
                // the next fetch asks for them again.
                let complete = self.deliver(report) && missed.withLock({ $0 }) == 0
                if complete, let data = latest.withLock({ $0 }) {
                    UserDefaults.standard.set(data, forKey: Self.tokenKey)
                }
                self.finishDirectFetch(complete ? nil : "Some changes didn't arrive")
            case .failure(let error):
                let code = (error as? CKError)?.code
                let partial = (error as? CKError)?.partialErrorsByItemID?.values.compactMap { ($0 as? CKError)?.code } ?? []
                if !retried, code == .changeTokenExpired || partial.contains(.changeTokenExpired) {
                    // Start over from the beginning of the zone.
                    UserDefaults.standard.removeObject(forKey: Self.tokenKey)
                    self.fetchZone(since: nil, retried: true)
                    return
                }
                if code == .zoneNotFound || partial.contains(.zoneNotFound) {
                    // No device has created the zone yet: nothing to fetch.
                    note("fetched directly: no zone yet")
                    self.finishDirectFetch(nil)
                } else {
                    note("direct fetch failed: \(Self.describe(error))", error: true)
                    self.finishDirectFetch(Self.describe(error))
                }
            }
        }
        database.add(operation)
    }

    /// Ends the direct fetch, telling everyone who waited on it.
    private func finishDirectFetch(_ failure: String?) {
        let waiting = directFetch.withLock { waiting in
            defer { waiting = nil }
            return waiting ?? []
        }
        for done in waiting { done(failure) }
    }

    /// Forgets the direct fetch's place, as when the account changes.
    private static func forgetFetchToken() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
    }

    /// Tells the engine which records have local changes, so it asks for
    /// them in `nextRecordZoneChangeBatch`.
    private func queuePendingWork() {
        guard let syncEngine, let data = nextBatch(Self.batchLimit) else { return }
        guard let batch = Self.decodeBatch(data) else { return }
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        syncEngine.state.add(pendingRecordZoneChanges:
            batch.save.map { .saveRecord(CKRecord.ID(recordName: $0.name, zoneID: zoneID)) }
            + batch.delete.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
    }

    private static let batchLimit = 400

    // MARK: Sending

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard let data = nextBatch(Self.batchLimit), let batch = Self.decodeBatch(data) else { return nil }
        let records = Dictionary(batch.save.map { ($0.name, $0) }) { _, latest in latest }
        let scope = context.options.scope
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            guard let outgoing = records[id.recordName] else { return nil }
            self.sentVersions.withLock { $0[id.recordName] = outgoing.version }
            // Saving on top of the server's version needs the fields that
            // came with it; without them CloudKit treats this as new.
            let record = outgoing.systemFields.flatMap { Self.record(from: $0) }
                ?? CKRecord(recordType: outgoing.type, recordID: id)
            record.encryptedValues[Field.key] = outgoing.key
            record.encryptedValues[Field.payload] = outgoing.payload
            // Saved on top of a record from before, the plain copies go.
            record[Field.plainKey] = nil
            record[Field.plainPayload] = nil
            return record
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = Self.serialized(update.stateSerialization) {
                saveState(data)
            }

        case .sentRecordZoneChanges(let sent):
            note("sent \(sent.savedRecords.count) records, \(sent.failedRecordSaves.count) failed")
            var report = Report()
            for saved in sent.savedRecords {
                guard let fields = Self.systemFields(of: saved) else { continue }
                let name = saved.recordID.recordName
                if let tag = saved.recordChangeTag {
                    savedTags.withLock { $0[name] = tag }
                }
                // A version it no longer knows (-1) still updates the change tag.
                let version = sentVersions.withLock { $0.removeValue(forKey: name) } ?? -1
                report.saved.append(SavedRecord(name: name, version: version, systemFields: fields))
            }
            for failed in sent.failedRecordSaves {
                if let failure = Self.classify(failed, into: &report, syncEngine: syncEngine, zoneID: zoneID) {
                    noteFailure(failure)
                }
            }
            report.deleted = sent.deletedRecordIDs.map(\.recordName)
            for failed in sent.failedRecordDeletes {
                // A record the server doesn't have is already deleted.
                if failed.value.code == .unknownItem {
                    report.deleted.append(failed.key.recordName)
                } else {
                    note("delete failed for \(failed.key.recordName): \(Self.describe(failed.value))", error: true)
                    noteFailure(Self.describe(failed.value))
                }
            }
            deliver(report)

        case .fetchedRecordZoneChanges(let changes):
            note("fetched \(changes.modifications.count) records, \(changes.deletions.count) deletions")
            var report = Report()
            for record in changes.modifications {
                // This device's own save coming back: it already has it.
                let name = record.record.recordID.recordName
                let own = savedTags.withLock { tags in
                    guard let tag = record.record.recordChangeTag, tags[name] == tag else { return false }
                    tags[name] = nil
                    return true
                }
                guard !own, let fetched = Self.fetched(record.record) else { continue }
                report.fetched.append(fetched)
            }
            report.removed = changes.deletions.map(\.recordID.recordName)
            let fetched = report
            if !deliver(fetched) {
                note("app couldn't keep \(fetched.fetched.count) fetched records; retrying at the next sync", error: true)
                undelivered.withLock { $0.append(fetched) }
            }

        case .fetchedDatabaseChanges(let changes):
            note("fetched database changes: zones \(changes.modifications.map(\.zoneID.zoneName)), deleted \(changes.deletions.map(\.zoneID.zoneName))")
            // The zone went: on this device's own doing or another's, sync
            // starts over, and the app uploads everything again.
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                Self.forgetFetchToken()
                deliver(Report(wasReset: true))
            }

        case .accountChange(let change):
            note("iCloud account changed: \(change.changeType)")
            switch change.changeType {
            case .signIn, .switchAccounts, .signOut:
                // Another iCloud account, or none: nothing kept about the
                // old one applies.
                Self.forgetFetchToken()
                deliver(Report(wasReset: true))
            @unknown default:
                break
            }

        case .didFetchRecordZoneChanges(let done):
            if let error = done.error {
                note("fetching zone \(done.zoneID.zoneName) failed: \(Self.describe(error))", error: true)
                noteFailure(Self.describe(error))
            }

        case .sentDatabaseChanges(let sent):
            for failed in sent.failedZoneSaves {
                note("saving zone \(failed.zone.zoneID.zoneName) failed: \(Self.describe(failed.error))", error: true)
                noteFailure(Self.describe(failed.error))
            }

        case .didFetchChanges:
            note("fetch finished", kept: false)

        case .willFetchChanges, .willFetchRecordZoneChanges,
             .willSendChanges, .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    /// Sorts a failed save: a record the server has a newer version of comes
    /// back as a conflict to merge; a lost record is sent again as new;
    /// anything else is left pending for the engine to retry, and returned
    /// as the pass's failure.
    private static func classify(
        _ failed: CKSyncEngine.Event.SentRecordZoneChanges.FailedRecordSave, into report: inout Report,
        syncEngine: CKSyncEngine, zoneID: CKRecordZone.ID
    ) -> String? {
        let id = failed.record.recordID
        let error = failed.error
        switch error.code {
        case .serverRecordChanged:
            if let server = error.serverRecord, let fetched = fetched(server) {
                report.fetched.append(fetched)
            }
        case .unknownItem:
            report.unknown.append(id.recordName)
        case .zoneNotFound, .userDeletedZone:
            syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        default:
            note("save failed for \(id.recordName): \(describe(error))", error: true)
            return describe(error)
        }
        return nil
    }

    /// Keeps the first failure the engine reports during a pass.
    private func noteFailure(_ failure: String) {
        reportedFailures.withLock { $0.add(failure) }
    }

    /// An error as the log shows it: CloudKit's code by number and name,
    /// since the description alone is often private.
    private static func describe(_ error: any Error) -> String {
        if let error = error as? CKError {
            return "CKError \(error.code.rawValue) \(error.code) \(error.localizedDescription)"
        }
        return String(describing: error)
    }

    /// Hands `report` to the app; returns whether the app kept it.
    @discardableResult
    private func deliver(_ report: Report) -> Bool {
        guard !report.isEmpty, let data = try? JSONEncoder().encode(report) else { return true }
        let kept = didChange(data as NSData)
        queuePendingWork()
        return kept
    }

    /// Delivers the engine's fetches the app couldn't keep before. The
    /// merges don't mind a record twice, so ones a later fetch also brought
    /// do no harm.
    private func retryUndelivered() {
        let reports = undelivered.withLock { reports in
            defer { reports = [] }
            return reports
        }
        let failed = reports.filter { !deliver($0) }
        guard !failed.isEmpty else { return }
        undelivered.withLock { $0.insert(contentsOf: failed, at: 0) }
    }

    // MARK: CKRecord and the app's JSON

    private static func fetched(_ record: CKRecord) -> FetchedRecord? {
        guard let key = record.encryptedValues[Field.key] as? String ?? record[Field.plainKey] as? String,
              let payload = record.encryptedValues[Field.payload] as? Data ?? record[Field.plainPayload] as? Data,
              let fields = systemFields(of: record) else { return nil }
        return FetchedRecord(
            name: record.recordID.recordName, type: record.recordType, key: key,
            payload: payload, systemFields: fields
        )
    }

    /// A record's system fields (its change tag and identity), archived, so
    /// the app can hand them back on the next save.
    private static func systemFields(of record: CKRecord) -> Data? {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private static func record(from systemFields: Data) -> CKRecord? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: systemFields) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    private static func serialized(_ state: CKSyncEngine.State.Serialization?) -> NSData? {
        guard let state else { return nil }
        return try? JSONEncoder().encode(state) as NSData
    }

    private static func deserializedState(_ data: Data) -> CKSyncEngine.State.Serialization? {
        try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
    }

    private static func decodeBatch(_ data: NSData) -> Batch? {
        try? JSONDecoder().decode(Batch.self, from: data as Data)
    }
}

/// The engine's recent failures, numbered in the order they came.
private struct ReportedFailures {
    var next = 0
    var recent: [(number: Int, failure: String)] = []

    mutating func add(_ failure: String) {
        recent.append((next, failure))
        next += 1
        if recent.count > 20 { recent.removeFirst(recent.count - 20) }
    }

    func first(since number: Int) -> String? {
        recent.first { $0.number >= number }?.failure
    }
}

// MARK: The JSON across the boundary

private struct Batch: Decodable {
    var save: [OutgoingRecord] = []
    var delete: [String] = []
}

private struct OutgoingRecord: Decodable {
    var name: String
    var type: String
    var key: String
    var payload: Data
    var systemFields: Data?
    var version: Int64
}

private struct SavedRecord: Encodable, Sendable {
    var name: String
    var version: Int64
    var systemFields: Data
}

private struct FetchedRecord: Encodable, Sendable {
    var name: String
    var type: String
    var key: String
    var payload: Data
    var systemFields: Data
}

private struct Report: Encodable, Sendable {
    var saved: [SavedRecord] = []
    var deleted: [String] = []
    var unknown: [String] = []
    var fetched: [FetchedRecord] = []
    var removed: [String] = []
    var wasReset = false

    var isEmpty: Bool {
        saved.isEmpty && deleted.isEmpty && unknown.isEmpty && fetched.isEmpty && removed.isEmpty && !wasReset
    }
}
