import Foundation
import GRDB

/// The one-time repair for stores where a rich feed's catch-up read stored
/// days of older posts as new rows at the bottom, before catch-ups kept only
/// joins and newer posts (ADR 0031 § Since reads, `FetchedPage.catchUpFrom`).
/// Run once, by the store's migration "v27: posts a catch-up read added".
enum CatchUpRepair {
    /// How many such posts one fetch of a source must have brought for its
    /// posts to count as a catch-up's. An ordinary fetch brings a few late
    /// posts at most; the read of a busy feed's whole window brought
    /// thousands.
    static let batch = 100

    /// How many rows after the furthest a reader has been in a view are
    /// kept, as ones that may have been on screen: more than any screen
    /// shows.
    static let onScreen = 100

    /// Removes the posts a catch-up read added that the reader can't have
    /// seen or used, and returns how many went. A post goes only when all of
    /// these hold:
    ///
    /// - It is a rich feed's post, not a bookmark list's copy, and the only
    ///   item in its row: one that joined another copy's row is kept.
    /// - It fixed its row's place, and that place is below its own date:
    ///   it was placed at the bottom (ADR 0022), not by its date.
    /// - When it was fetched its source already had a newer item, and the
    ///   same fetch brought at least `batch` posts like it. That fetch is
    ///   the source's first such fetch, or one in an unbroken run of such
    ///   fetches right after it (a catch-up cut at the page limit carries on
    ///   at the next fetch): since reads begin only after the catch-up, so a
    ///   since read that brought as many late posts is never the first, and
    ///   the first fetch after the catch-up that isn't one ends the run.
    /// - It has no bookmark or read state, which is all a reader can leave
    ///   on a rich post.
    /// - In every view that shows it, it is below the furthest the reader
    ///   has been (the last-read marker or the reading place) by more than
    ///   `onScreen` rows; in a view with neither, which opens on its newest
    ///   rows, it is above the last `onScreen`.
    ///
    /// Each removed row's position goes from iCloud too, as an aged-out
    /// row's does in `prune`; another device's copy of the row keeps its
    /// place, and its own repair decides by its own reader's places.
    @discardableResult
    static func run(_ db: Database, at now: Date) throws -> Int {
        let candidates = try olderPostsInBatches(db)
        guard !candidates.isEmpty else { return 0 }
        var removable = try untouched(candidates, db)
        guard !removable.isEmpty else { return 0 }
        for view in try views(db) {
            removable.removeAll(where: view.protects)
            if removable.isEmpty { return 0 }
        }
        let ids = removable.map(\.id), keys = removable.map(\.mergeKey)
        // A migration runs with foreign keys off, so nothing cascades: the
        // items' identities and positions go first, by hand. Each removed
        // item is alone in its row.
        try db.execute(literal: "DELETE FROM timelinePosition WHERE mergeKey IN \(keys)")
        try db.execute(literal: "DELETE FROM \(sql: PostIdentity.tableName) WHERE itemID IN \(ids)")
        try db.execute(literal: "DELETE FROM item WHERE id IN \(ids)")
        for key in keys {
            try SyncLog.recordDeletion(db, .timelinePosition, key: key, at: now)
        }
        return removable.count
    }

    /// A post that may be removed, with its row's place.
    struct Candidate: Hashable {
        var id: Int64
        var sourceID: String
        var mergeKey: String
        var placedAt: Date
    }

    /// The IDs of rich posts that their source already had a newer item
    /// than when they were fetched, in the source's first fetch that brought
    /// at least `batch` of them and the unbroken run of such fetches after
    /// it.
    private static func olderPostsInBatches(_ db: Database) throws -> [Int64] {
        let rows = try SQLRequest<Row>(literal: """
            SELECT item.id, item.sourceID, item.fetchedAt, MIN(item.sortDate, item.fetchedAt) AS placement
            FROM item JOIN source ON source.id = item.sourceID
            WHERE source.kind = \(Source.Kind.sammyFeed.rawValue) AND item.kind = \(Item.Kind.post.rawValue) AND item.onlyInBookmarks = 0
            """).fetchAll(db)
        var found: [Int64] = []
        let bySource = Dictionary(grouping: rows) { $0["sourceID"] as String }
        for items in bySource.values {
            // Fetches in order, each with its items' IDs and placements.
            let fetches = Dictionary(grouping: items) { $0["fetchedAt"] as Date }.sorted { $0.key < $1.key }
            // The newest placement among the source's earlier fetches.
            var newestBefore: Date?
            // Whether the run of catch-up fetches has begun.
            var inRun = false
            for (_, fetched) in fetches {
                let placed = fetched.map { (id: $0["id"] as Int64, placement: $0["placement"] as Date) }
                let older = newestBefore.map { newest in placed.filter { $0.placement <= newest } } ?? []
                if older.count >= batch {
                    found += older.map(\.id)
                    inRun = true
                } else if inRun {
                    break
                }
                if let newest = placed.map(\.placement).max() { newestBefore = max(newestBefore ?? newest, newest) }
            }
        }
        return found
    }

    /// Of `ids`, the posts alone in their rows, placed at the bottom by
    /// them, with no bookmark or read state.
    private static func untouched(_ ids: [Int64], _ db: Database) throws -> [Candidate] {
        try SQLRequest<Row>(literal: """
            SELECT item.id, item.sourceID, item.mergeKey, p.sortDate AS placedAt
            FROM item JOIN timelinePosition p ON p.itemID = item.id AND p.mergeKey = item.mergeKey
            WHERE item.id IN \(ids)
                AND p.sortDate > MIN(item.sortDate, item.fetchedAt)
                AND NOT EXISTS (SELECT 1 FROM item other WHERE other.mergeKey = item.mergeKey AND other.id <> item.id)
                AND NOT \(InfluxStore.isBookmarked)
                AND item.mergeKey NOT IN (SELECT mergeKey FROM articleBookmark)
                AND item.mergeKey NOT IN (SELECT mergeKey FROM articleReadState)
            """).fetchAll(db).map { Candidate(id: $0["id"], sourceID: $0["sourceID"], mergeKey: $0["mergeKey"], placedAt: $0["placedAt"]) }
    }

    /// A view a rich post can show in, and the rows of it the reader may
    /// have seen.
    struct View {
        /// Nil for the All view.
        var sourceIDs: Set<String>?
        /// The rows that may have been on screen: up to `last`, the
        /// `onScreen`th row after the furthest the reader has been, or from
        /// `first`, the `onScreen`th row from the end, in a view they have
        /// been nowhere in. Every row when the view has too few.
        var last: Date?
        var first: Date?
        var all: Bool

        /// Whether `candidate` shows in this view among the rows the reader
        /// may have seen there.
        func protects(_ candidate: Candidate) -> Bool {
            if let sourceIDs, !sourceIDs.contains(candidate.sourceID) { return false }
            if all { return true }
            if let last { return candidate.placedAt <= last }
            if let first { return candidate.placedAt >= first }
            return true
        }

        init(sourceIDs: Set<String>?, furthest: Date?, _ db: Database) throws {
            self.sourceIDs = sourceIDs
            let inScope: SQL = sourceIDs.map { "AND p.mergeKey IN (SELECT mergeKey FROM item WHERE sourceID IN \(Array($0)) AND onlyInBookmarks = 0)" } ?? ""
            if let furthest {
                last = try SQLRequest<Date>(literal: """
                    SELECT p.sortDate FROM timelinePosition p WHERE p.sortDate > \(furthest) \(inScope)
                    ORDER BY p.sortDate, p.mergeKey LIMIT 1 OFFSET \(CatchUpRepair.onScreen - 1)
                    """).fetchOne(db)
                all = last == nil
            } else {
                first = try SQLRequest<Date>(literal: """
                    SELECT p.sortDate FROM timelinePosition p WHERE 1 = 1 \(inScope)
                    ORDER BY p.sortDate DESC, p.mergeKey DESC LIMIT 1 OFFSET \(CatchUpRepair.onScreen - 1)
                    """).fetchOne(db)
                all = first == nil
            }
        }
    }

    /// The All view and every saved view, with the furthest the reader has
    /// been in each.
    private static func views(_ db: Database) throws -> [View] {
        let markers = Dictionary(try LastReadMarker.fetchAll(db).map { ($0.viewID, ($0.sortDate, $0.mergeKey)) }, uniquingKeysWith: { first, _ in first })
        let places = Dictionary(try ReadingPlace.fetchAll(db).map { ($0.viewID, ($0.sortDate, $0.mergeKey)) }, uniquingKeysWith: { first, _ in first })
        func furthest(_ viewID: String) throws -> Date? {
            try [markers[viewID], places[viewID]].compactMap { $0 }.map { sortDate, mergeKey in
                // The row's place here, else the date it was given.
                try Date.fetchOne(db, sql: "SELECT sortDate FROM timelinePosition WHERE mergeKey = ?", arguments: [mergeKey]) ?? sortDate
            }.max()
        }
        var views = [try View(sourceIDs: nil, furthest: try furthest(SavedView.allID), db)]
        for view in try SavedView.fetchAll(db) {
            views.append(try View(sourceIDs: Set(view.sourceIDs), furthest: try furthest(view.id), db))
        }
        return views
    }
}
