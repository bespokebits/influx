import Foundation
import GRDB

/// How fetching a source last went, and where its next fetches continue
/// from. Local to this device and never synced: each device fetches its own
/// items, so its cursors only make sense here.
public struct SourceFetchState: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public var sourceID: String
    /// Where the next `.newer` fetch continues from.
    public var newerCursor: Cursor?
    /// Where the next `.older` fetch continues from; nil once nothing older
    /// is left, or before the first fetch.
    public var olderCursor: Cursor?
    /// Whether the source has been paged back as far as it goes.
    public var reachedOldest: Bool
    /// Whether any fetch has returned items yet. Until one does, each
    /// `.newer` page sets where paging back starts.
    public var hasFetchedItems: Bool
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    /// What is wrong with the source, shown as a quiet state on it; nil
    /// while it fetches fine.
    public var problem: SourceProblem?
    /// When the current problem started; repeats of it keep this date.
    public var problemSince: Date?
    /// More about a `.badResponse`, for the source's detail view.
    public var problemDetail: String?
    /// No fetch before this: the service's `Retry-After`, or a pause after
    /// a rate limit that gave none.
    public var retryAfter: Date?

    public init(sourceID: String) {
        self.sourceID = sourceID
        reachedOldest = false
        hasFetchedItems = false
    }

    public static let databaseTableName = "sourceFetchState"

    /// How long to wait after a rate limit that didn't say.
    static let defaultRateLimitPause: TimeInterval = 5 * 60

    /// How long a fetch that changed nothing but the state's times goes
    /// unrecorded. Its times only date the source's success, which the
    /// notice for failing sources counts in days, so a source fetched every
    /// 30 seconds writes them once an hour rather than every time.
    static let unchangedRecordingInterval: TimeInterval = 60 * 60

    /// Whether `next`, this state after a fetch at `now`, has to be stored:
    /// it differs in more than its times, or they were last stored
    /// `unchangedRecordingInterval` or longer ago.
    func needsRecording(_ next: SourceFetchState, at now: Date) -> Bool {
        var timesOnly = next
        timesOnly.lastAttemptAt = lastAttemptAt
        timesOnly.lastSuccessAt = lastSuccessAt
        guard timesOnly == self, let success = lastSuccessAt, let attempt = lastAttemptAt else { return true }
        let recorded = min(success, attempt)
        return now < recorded || now.timeIntervalSince(recorded) >= Self.unchangedRecordingInterval
    }

    /// The state after `page` was stored: the cursors move on and any
    /// problem clears. A `.newer` page only sets the older cursor until the
    /// source first returns items: that page fixes where paging back
    /// starts, so a source that was empty at first can still be paged back.
    func recording(_ page: FetchedPage, direction: FetchDirection, at now: Date) -> SourceFetchState {
        var next = self
        switch direction {
        case .newer:
            next.newerCursor = page.newer
            if !hasFetchedItems {
                next.olderCursor = page.older
                next.reachedOldest = page.older == nil
            }
        case .older:
            next.olderCursor = page.older
            next.reachedOldest = page.older == nil
        }
        next.hasFetchedItems = hasFetchedItems || !page.items.isEmpty
        next.lastAttemptAt = now
        next.lastSuccessAt = now
        next.problem = nil
        next.problemSince = nil
        next.problemDetail = nil
        next.retryAfter = nil
        return next
    }

    /// The state after a fetch failed with `error`. Cursors stay where they
    /// were, so the next fetch retries the same page.
    func recording(_ error: ConnectorError, at now: Date) -> SourceFetchState {
        var next = self
        let problem: SourceProblem
        var detail: String?
        var retryAfter: Date?
        switch error {
        case .offline:
            problem = .offline
        case .unauthorized:
            problem = .signedOut
        case .rateLimited(let until):
            problem = .rateLimited
            retryAfter = until ?? now.addingTimeInterval(Self.defaultRateLimitPause)
        case .notFound:
            problem = .notFound
        case .badResponse(let reason):
            problem = .badResponse
            detail = reason
        case .unsupported:
            problem = .badResponse
            detail = "unsupported"
        }
        if next.problem != problem {
            next.problemSince = now
        }
        next.problem = problem
        next.problemDetail = detail
        next.retryAfter = retryAfter
        next.lastAttemptAt = now
        return next
    }
}

/// The quiet state a source shows when fetching it fails.
public enum SourceProblem: String, Codable, Sendable, CaseIterable {
    /// No network, or the service didn't answer.
    case offline
    /// The account needs signing in again.
    case signedOut
    /// The service asked us to slow down.
    case rateLimited
    /// The feed or list is gone.
    case notFound
    /// The service sent something we can't read.
    case badResponse
}

extension Cursor: DatabaseValueConvertible {}
extension SourceProblem: DatabaseValueConvertible {}
