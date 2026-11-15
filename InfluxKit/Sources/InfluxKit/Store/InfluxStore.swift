import Foundation
import GRDB
import Synchronization

/// The store: the one place posts, articles, sources and read state live
///. Writes run on GRDB's writer queue, never the caller's actor;
/// reads and observations see a consistent snapshot.
public final class InfluxStore: Sendable {
    /// Which sources a timeline shows.
    public enum Scope: Sendable, Hashable {
        case all
        case sources(Set<String>)
        /// The posts the reader has bookmarked, from any source.
        case bookmarked
    }

    /// How long items are kept.
    public static let postRetention: TimeInterval = 7 * 24 * 60 * 60
    public static let articleRetention: TimeInterval = 30 * 24 * 60 * 60

    /// How long an item of `kind` is kept, whichever source brought it:
    /// what `prune` deletes by, and what `Refresher` keeps of a page, so a
    /// fetch never stores what the next prune deletes.
    public static func retention(for kind: Item.Kind) -> TimeInterval {
        switch kind {
        case .post: postRetention
        case .article: articleRetention
        }
    }

    let writer: any DatabaseWriter
    /// Sources a `Refresher` is fetching right now, so two refreshes of one
    /// source never overlap and a slow response can't rewind a cursor a
    /// later one moved.
    private let refreshing = Mutex<Set<String>>([])
    /// What each timeline on a screen shows last, which new rows stay
    /// below (`PlacementLine`).
    private let onScreen = OnScreenTimelines()

    /// A store in a file, for the app.
    public convenience init(path: String) throws {
        try self.init(writer: DatabasePool(path: path))
    }

    /// A store in memory, for tests and previews.
    public static func inMemory() throws -> InfluxStore {
        try InfluxStore(writer: DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.migrator.migrate(writer)
    }

    // MARK: Sources

    /// Adds sources, or updates the ones that already exist. Sources that
    /// changed go to iCloud on the next sync.
    public func save(sources: [Source], at now: Date = Date()) async throws {
        try await writer.write { db in
            for source in sources where try Source.fetchOne(db, key: source.id) != source {
                try source.upsert(db)
                try SyncLog.recordChange(db, .source, key: source.id, at: now)
            }
        }
    }

    /// Points a source at its new address, keeping its ID and items. Does
    /// nothing, and returns false, when another source already has that
    /// address, so a move never makes two subscriptions to one feed.
    @discardableResult
    public func move(sourceID: String, to url: String) async throws -> Bool {
        try await writer.write { db in
            try Self.move(sourceID: sourceID, to: url, db)
        }
    }

    private static func move(sourceID: String, to url: String, _ db: Database) throws -> Bool {
        try db.execute(sql: """
            UPDATE source SET url = ?
            WHERE id = ? AND url IS NOT ? AND NOT EXISTS (SELECT 1 FROM source WHERE url = ? AND id != ?)
            """, arguments: [url, sourceID, url, url, sourceID])
        guard db.changesCount > 0 else { return false }
        try SyncLog.recordChange(db, .source, key: sourceID, at: Date())
        return true
    }

    /// Removes a source and every item it brought in, on every device.
    public func delete(sourceID: String, at now: Date = Date()) async throws {
        try await writer.write { db in
            try Source.deleteOne(db, key: sourceID)
            try Self.deleteEmptyPositions(db, at: now)
            try SyncLog.recordDeletion(db, .source, key: sourceID, at: now)
        }
    }

    /// Adds or updates `sources` and removes the sources `removing` names,
    /// with their items, in one transaction: either all of it happens, or
    /// none of it does.
    public func save(sources: [Source], removing: [String], at now: Date = Date()) async throws {
        try await writer.write { db in
            for source in sources where try Source.fetchOne(db, key: source.id) != source {
                try source.upsert(db)
                try SyncLog.recordChange(db, .source, key: source.id, at: now)
            }
            guard !removing.isEmpty else { return }
            for id in removing {
                try Source.deleteOne(db, key: id)
                try SyncLog.recordDeletion(db, .source, key: id, at: now)
            }
            try Self.deleteEmptyPositions(db, at: now)
        }
    }

    public func sources() async throws -> [Source] {
        try await writer.read { db in
            try Source.order(Column("title")).fetchAll(db)
        }
    }

    public func source(id: String) async throws -> Source? {
        try await writer.read { db in
            try Source.fetchOne(db, key: id)
        }
    }

    // MARK: Items

    /// Writes a batch of items in one transaction and returns how many were
    /// new. An item already stored (same source and remote ID) is left as it
    /// is: a row's content, and so its height, never changes once it can
    /// have been shown. Only `viewer` and a rich post's author and booster
    /// pictures are brought up to date: neither ever changes a height (a
    /// picture is drawn at the avatar's fixed size). `viewer` is kept so
    /// a like made on another device shows
    /// here too. It is the account's state, so it reaches every copy of the
    /// post the same account fetched (an original and its boosts, home and
    /// lists); a change the reader made here after the fetch began stays,
    /// and a new copy takes it.
    ///
    /// The first item stored for a merge key also fixes where its row sits
    /// and which item the row is shown from, except that a fediverse post
    /// is shown over its Bridgy Fed copy. Copies that arrive
    /// later, even earlier-dated ones, join the row without moving it, and
    /// a post bridged between Bluesky and the fediverse joins its other
    /// copy (`joiningBridgedCopies`), as does a copy that a rich feed's
    /// post names as itself (`PostIdentity`, with `identities` as
    /// `FetchedPage.identities`).
    /// Within one batch the earliest copy wins, so the order a service
    /// returns a page in doesn't matter. A position already agreed through
    /// iCloud for the merge key wins over all of them.
    ///
    /// With `belowTheLine`, a new row is placed by its own time unless
    /// that is at or above its line: the furthest the reader has read to
    /// or is, in any view that shows the row, and the last row on screen
    /// (`PlacementLine`, ADR 0041). Then it goes directly below the line,
    /// so nothing that arrives late lands where the reader won't see it.
    /// Rows placed that way keep the order of their own times, a
    /// millisecond apart.
    @discardableResult
    public func insert(_ items: [Item], identities: [String: [String]] = [:], belowTheLine: Bool = false) async throws -> Int {
        try await writer.write { [onScreen] db in
            try Self.insert(items, identities: identities, belowTheLine: belowTheLine ? onScreen.bottoms : nil, db)
        }
    }

    /// Says that a timeline showing the view `viewID` is on a screen. The
    /// timeline keeps what this returns for as long as it is, and tells it
    /// the last row it shows.
    public func timelineOnScreen(viewID: String) -> TimelineOnScreen {
        TimelineOnScreen(viewID: viewID, timelines: onScreen)
    }

    /// `belowTheLine` is what each timeline on a screen shows last, when
    /// new rows are to stay below their line; nil places every row by its
    /// own time.
    private static func insert(_ items: [Item], identities: [String: [String]] = [:], belowTheLine: [ScreenBottom]? = nil,
                               catchUpFrom: Date? = nil, _ db: Database) throws -> Int {
        var joined = try joiningCopies(items, identities: identities, db)
        if let catchUpFrom {
            joined = try keepingCatchUp(joined, from: catchUpFrom, db)
        }
        let ordered = joined.sorted { ($0.placement, $0.sourceID, $0.remoteID) < ($1.placement, $1.sourceID, $1.remoteID) }
        let sourceKinds = Dictionary(try Source.fetchAll(db, keys: Array(Set(items.map(\.sourceID)))).map { ($0.id, $0.kind) },
                                     uniquingKeysWith: { first, _ in first })
        var inserted = 0
        let now = Date()
        var line = try belowTheLine.map { try PlacementLine(db, onScreen: $0, placing: ordered, sourceKinds: sourceKinds) }
        for var item in ordered {
            item.id = nil
            item.viewerFetchedAt = item.viewer == nil ? nil : item.fetchedAt
            try item.insert(db, onConflict: .ignore)
            let isNew = db.changesCount > 0
            if !isNew, !item.onlyInBookmarks {
                // Stored from the bookmark list first; a timeline has it
                // now, so it shows in the other views too.
                try db.execute(literal: """
                    UPDATE item SET onlyInBookmarks = 0
                    WHERE sourceID = \(item.sourceID) AND remoteID = \(item.remoteID) AND onlyInBookmarks = 1
                    """)
            }
            if item.viewer != nil {
                try shareViewer(of: item, isNew: isNew, db)
            }
            if !isNew, let kind = sourceKinds[item.sourceID] {
                // A rich post stored before identities were kept gets them
                // the next time its feed sends it.
                try PostIdentity.recordMissing(item, sourceKind: kind, identities: identities, db)
                if kind == .sammyFeed, item.kind == .post {
                    // Its author's and booster's pictures follow the feed:
                    // one stored before the feed carried pictures, or
                    // since changed, is brought up to date. A picture is
                    // drawn at the avatar's fixed size, so the row's height
                    // stays the same.
                    try db.execute(literal: """
                        UPDATE item SET authorAvatar = \(item.authorAvatar), boostedByAvatar = \(item.boostedByAvatar)
                        WHERE sourceID = \(item.sourceID) AND remoteID = \(item.remoteID)
                            AND (authorAvatar IS NOT \(item.authorAvatar) OR boostedByAvatar IS NOT \(item.boostedByAvatar))
                        """)
                }
            }
            guard isNew, let id = item.id else { continue }
            inserted += 1
            if let kind = sourceKinds[item.sourceID] {
                try PostIdentity.record(item, id: id, sourceKind: kind, identities: identities, db)
            }
            let synced = try PendingTimelinePosition.fetchOne(db, key: item.mergeKey)
            // A position agreed through iCloud wins over the line.
            let position = synced == nil ? line?.position(of: item) : nil
            let placedAt = synced?.sortDate ?? position?.date ?? item.placement
            try db.execute(literal: """
                INSERT OR IGNORE INTO timelinePosition (mergeKey, sortDate, itemID)
                VALUES (\(item.mergeKey), \(placedAt), \(id))
                """)
            if db.changesCount > 0 {
                if let position { line?.placed(at: position) }
                if let synced {
                    try synced.delete(db)
                } else if placedAt != item.publishedAt {
                    // Placed by a boost's date, the fetch time or below the
                    // reader's line, which another device may not share, so
                    // iCloud gets this device's position in case it is the
                    // first.
                    try SyncLog.offerPosition(db, mergeKey: item.mergeKey, at: now)
                }
                // Markers synced before their row arrived can now be placed.
                let pending = try PendingLastReadMarker.filter(Column("mergeKey") == item.mergeKey).fetchAll(db)
                for marker in pending {
                    let advanced = try advance(db, to: LastReadMarker(viewID: marker.viewID, sortDate: placedAt, mergeKey: item.mergeKey, updatedAt: marker.updatedAt))
                    // Behind this device's marker, which then wins: iCloud
                    // has the other one, so this one goes up again.
                    if !advanced, let local = try LastReadMarker.fetchOne(db, key: marker.viewID), local.mergeKey != item.mergeKey {
                        try SyncLog.recordChange(db, .lastReadMarker, key: marker.viewID, at: now)
                    }
                    try marker.delete(db)
                }
            } else if try Date.fetchOne(db, sql: "SELECT sortDate FROM timelinePosition WHERE mergeKey = ?", arguments: [item.mergeKey]) != item.placement {
                // A copy that would have placed the row elsewhere: devices
                // that saw it first can disagree, so offer this position.
                try SyncLog.offerPosition(db, mergeKey: item.mergeKey, at: now)
            }
        }
        return inserted
    }

    /// Of a catch-up read's `items` (`FetchedPage.catchUpFrom`), already
    /// given the merge keys they join under, the ones to store: those
    /// already stored, which only bring their copies up to date; those
    /// placed after `start`, the newest the source had when the catch-up
    /// began, which are new to the feed; and those whose merge key already
    /// has a row in the timeline, which they join without moving it (a
    /// late repost whose Mastodon copy is here). The rest are older posts
    /// the reader never had. Stored, each would be a new row below the
    /// reader's line (ADR 0041; at the bottom of the timeline, when ADR
    /// 0022 placed them), and a whole window of them buried the reader's
    /// place under days of old posts, so they are left out (ADR 0031). A
    /// position synced from another device for one of them isn't a row
    /// here, so it doesn't keep the post.
    static func keepingCatchUp(_ items: [Item], from start: Date, _ db: Database) throws -> [Item] {
        let older = items.filter { $0.placement <= start }
        guard !older.isEmpty else { return items }
        var stored: Set<[String]> = []
        for (sourceID, group) in Dictionary(grouping: older, by: \.sourceID) {
            let remoteIDs = group.map(\.remoteID)
            for remoteID in try String.fetchAll(db, SQLRequest<String>(literal: """
                SELECT remoteID FROM item WHERE sourceID = \(sourceID) AND remoteID IN \(remoteIDs)
                """)) {
                stored.insert([sourceID, remoteID])
            }
        }
        let rows = try Set(String.fetchAll(db, SQLRequest<String>(literal: """
            SELECT mergeKey FROM timelinePosition WHERE mergeKey IN \(Array(Set(older.map(\.mergeKey))))
            """)))
        return items.filter { item in
            item.placement > start || stored.contains([item.sourceID, item.remoteID]) || rows.contains(item.mergeKey)
        }
    }

    /// Brings the viewer state of `item`, fetched outside a refresh (in a
    /// thread), to the stored copies of its post, as a refetch would.
    public func applyFetchedViewer(of item: Item) async throws {
        guard item.viewer != nil else { return }
        try await writer.write { db in
            guard try Source.exists(db, key: item.sourceID) else { return }
            try Self.shareViewer(of: Self.joiningCopies([item], db)[0], isNew: false, db)
        }
    }

    /// `item`, fetched outside a refresh (in a thread), with the merge key
    /// the store files its post under: the other copy's, for one half of a
    /// bridged pair (`joiningBridgedCopies`) or a post a rich feed names
    /// (`PostIdentity`), else its own.
    public func joined(_ item: Item) async throws -> Item {
        try await writer.read { db in
            try Self.joiningCopies([item], db)[0]
        }
    }

    /// `items`, each one already stored with its stored keys, and each new
    /// one with the merge key of the row its post already has: a key only
    /// its source uses for one claiming a rich post's key that isn't its
    /// own, then its bridged copy's (`joiningBridgedCopies`), then that of
    /// a copy it is the same post as by identity (`PostIdentity`), which
    /// is the only way an item from elsewhere comes to a rich post's key.
    static func joiningCopies(_ items: [Item], identities: [String: [String]] = [:], _ db: Database) throws -> [Item] {
        let (kept, isStored) = try keepingStoredKeys(items, db)
        let reserved = try reservingSammyPostKeys(kept, isStored: isStored, db)
        let bridged = try joiningBridgedCopies(reserved, isStored: isStored, db)
        return try PostIdentity.joining(bridged, isStored: isStored, identities: identities, db)
    }

    /// The source kinds that are Bluesky.
    private static let blueskyKinds = [Source.Kind.blueskyFollowing, .blueskyFeed].map(\.rawValue)

    /// `items`, with each copy of a post bridged by Bridgy Fed between the
    /// fediverse and Bluesky given the merge key of its other copy, when
    /// that is stored, so the two show as one row (ADR 0014). The two
    /// copies share no ID, but a Bluesky copy's link is the original's web
    /// address (`bridgyOriginalUrl`), which is the fediverse copy's link
    /// too: so a post joins the earliest stored post from the other side
    /// with the same link. Only exactly the same address matches, and a
    /// fediverse post's link counts only when it is on the server its own
    /// ID names, since any server can claim any link. A joined copy keeps
    /// its own ID as `postKey`, and a pair admits further copies from a
    /// side only when they have the same ID as that side's copies already
    /// in it, so two posts on one service never merge. The copy stored
    /// first keeps its key, and nothing stored is re-keyed.
    /// A copy already stored (`isStored`) keeps the key it was stored
    /// under, which can differ from a fresh join's: one stored before this
    /// rule, or one whose other side has since gone.
    private static func joiningBridgedCopies(_ items: [Item], isStored: [Bool], _ db: Database) throws -> [Item] {
        let links = Array(Set(items.indices.compactMap { !isStored[$0] && items[$0].kind == .post ? items[$0].url : nil }))
        guard !links.isEmpty else { return items }
        let stored = try SQLRequest<Row>(literal: """
            SELECT item.url, item.mergeKey, item.postKey, source.kind IN \(blueskyKinds) AS fromBluesky
            FROM item JOIN source ON source.id = item.sourceID
            WHERE item.kind = \(Item.Kind.post.rawValue) AND item.url IN \(links)
            ORDER BY item.id
            """).fetchAll(db)
        guard !stored.isEmpty else { return items }
        // For each link, the stored key a new copy on each side can join,
        // the earliest: the other side's copies, and copies on its own side
        // that already joined, so a pair stays joined after the other
        // side's copies have gone (a source removed, aged out).
        var keys: [Bool: [String: String]] = [true: [:], false: [:]]
        // For each stored key, the ID of the post each side holds under it.
        var posts: [Bool: [String: String]] = [true: [:], false: [:]]
        for row in stored {
            let url: String = row["url"], key: String = row["mergeKey"], fromBluesky: Bool = row["fromBluesky"]
            let postKey: String? = row["postKey"]
            let own = postKey ?? key
            guard fromBluesky || isOwnLink(url, of: own) else { continue }
            if keys[!fromBluesky]?[url] == nil { keys[!fromBluesky]?[url] = key }
            if postKey != nil, keys[fromBluesky]?[url] == nil { keys[fromBluesky]?[url] = key }
            if posts[fromBluesky]?[key] == nil { posts[fromBluesky]?[key] = own }
        }
        let sourceIDs = Array(Set(items.map(\.sourceID)))
        let blueskySources = try Set(String.fetchAll(db, SQLRequest<String>(literal: """
            SELECT id FROM source WHERE id IN \(sourceIDs) AND kind IN \(blueskyKinds)
            """)))
        var result = items
        for index in items.indices where !isStored[index] {
            let item = items[index]
            let fromBluesky = blueskySources.contains(item.sourceID)
            guard item.kind == .post, let url = item.url, fromBluesky || isOwnLink(url, of: item.mergeKey),
                  let key = keys[fromBluesky]?[url], key != item.mergeKey,
                  // A key from this side's own service is the ID of the
                  // post first stored for the pair, so it names the post
                  // even after that copy has gone.
                  (posts[fromBluesky]?[key] ?? (key.hasPrefix("at://") == fromBluesky ? key : nil)).map({ $0 == item.mergeKey }) ?? true
            else { continue }
            // Later items in this batch are checked against this one too.
            posts[fromBluesky]?[key] = item.mergeKey
            result[index].postKey = item.mergeKey
            result[index].mergeKey = key
        }
        return result
    }

    /// `items`, with every `sammy-post:` merge key that isn't the item's
    /// own replaced by one only its source uses, `<source ID>#<remote ID>`
    /// (ADR 0014, 0031). The namespace is a Sammy server's rich posts': a
    /// key there stands only on an item of a `.sammyFeed` source whose
    /// account is on the server the key names. So no other item can take
    /// the row of a rich post, or give its own reading state to one.
    ///
    /// Of the other connectors, RSS can never make such a key:
    /// `ArticleMapper.mergeKey` gives an ID only when it starts `http://`,
    /// `https://`, `tag:` or `urn:`, a link only as an http(s) URL, and
    /// otherwise `<source ID>#<remote ID>`, whose source ID starts `rss:`
    /// or `sammy:`. Mastodon and Bluesky can: `MastodonMapper.mergeKey(uri:)`
    /// and the Bluesky mapper take the post's URI as the server sends it,
    /// and a server can send any string, so this check is what keeps them
    /// out. Items already stored keep their keys, which were checked here
    /// when they were stored.
    private static func reservingSammyPostKeys(_ items: [Item], isStored: [Bool], _ db: Database) throws -> [Item] {
        let claiming = items.indices.filter { index in
            !(isStored.indices.contains(index) && isStored[index]) && items[index].mergeKey.hasPrefix(SammyPostKey.prefix)
        }
        guard !claiming.isEmpty else { return items }
        let sourceIDs = Array(Set(claiming.map { items[$0].sourceID }))
        let sources = Dictionary(try Source.fetchAll(db, keys: sourceIDs).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = items
        for index in claiming {
            let item = items[index]
            if let source = sources[item.sourceID], source.kind == .sammyFeed, SammyPostKey.isOwn(item.mergeKey, accountID: source.accountID) {
                continue
            }
            result[index].mergeKey = "\(item.sourceID)#\(item.remoteID)"
            result[index].postKey = nil
        }
        return result
    }

    /// `items`, with each one already stored given its stored merge key,
    /// and which of them are stored.
    private static func keepingStoredKeys(_ items: [Item], _ db: Database) throws -> ([Item], [Bool]) {
        let sourceIDs = Array(Set(items.map(\.sourceID))), remoteIDs = Array(Set(items.map(\.remoteID)))
        guard !remoteIDs.isEmpty else { return (items, []) }
        var stored: [String: [String: (mergeKey: String, postKey: String?)]] = [:]
        for row in try SQLRequest<Row>(literal: """
            SELECT sourceID, remoteID, mergeKey, postKey FROM item WHERE sourceID IN \(sourceIDs) AND remoteID IN \(remoteIDs)
            """).fetchAll(db) {
            stored[row["sourceID"], default: [:]][row["remoteID"]] = (row["mergeKey"], row["postKey"])
        }
        var isStored: [Bool] = []
        let kept = items.map { item in
            guard let keys = stored[item.sourceID]?[item.remoteID] else { isStored.append(false); return item }
            isStored.append(true)
            var kept = item
            kept.mergeKey = keys.mergeKey
            kept.postKey = keys.postKey
            return kept
        }
        return (kept, isStored)
    }

    /// Whether a fediverse post's link is on the server its ActivityPub ID
    /// names.
    private static func isOwnLink(_ url: String, of key: String) -> Bool {
        guard let link = URL(string: url)?.host()?.lowercased(), let own = URL(string: key)?.host()?.lowercased() else { return false }
        return !link.isEmpty && link == own
    }

    /// Brings `item`'s fetched viewer state to the same account's copies of
    /// its post, except those the reader changed after the fetch began or
    /// that a later-begun fetch already set; a new copy takes the newest
    /// such state instead.
    private static func shareViewer(of item: Item, isNew: Bool, _ db: Database) throws {
        let sameAccount: SQL = """
            sourceID IN (SELECT other.id FROM source other JOIN source this ON this.id = \(item.sourceID)
                         WHERE other.id = this.id OR other.accountID = this.accountID)
            """
        let viewer = try item.databaseDictionary["viewer"] ?? .null
        let fetchedAt = item.fetchedAt
        let notNewer: SQL = """
            (viewerChangedAt IS NULL OR viewerChangedAt < \(fetchedAt))
                AND (viewerFetchedAt IS NULL OR viewerFetchedAt <= \(fetchedAt))
            """
        // A complete bookmark list that began later knows the bookmark
        // better than this fetch does, but nothing else.
        let merged: SQL = """
            CASE WHEN viewerBookmarkFetchedAt > \(fetchedAt)
                THEN json_set(\(viewer), '$.bookmarked', json(CASE WHEN \(Self.isBookmarked) THEN 'true' ELSE 'false' END))
                ELSE \(viewer) END
            """
        try db.execute(literal: """
            UPDATE item SET viewer = \(merged)
            WHERE mergeKey = \(item.mergeKey) AND \(sameAccount) AND viewer IS NOT \(merged) AND \(notNewer)
            """)
        // Stamped apart from the change itself: the timeline doesn't read
        // the stamp, so a fetch that changes nothing redraws nothing.
        try db.execute(literal: """
            UPDATE item SET viewerFetchedAt = \(fetchedAt)
            WHERE mergeKey = \(item.mergeKey) AND \(sameAccount) AND viewerFetchedAt IS NOT \(fetchedAt) AND \(notNewer)
            """)
        guard isNew, let id = item.id else { return }
        let newer: SQL = """
            newer.mergeKey = \(item.mergeKey) AND newer.\(sameAccount) AND newer.id != \(id)
                AND (newer.viewerChangedAt >= \(fetchedAt) OR newer.viewerFetchedAt > \(fetchedAt))
            """
        try db.execute(literal: """
            UPDATE item SET (viewer, viewerChangedAt, viewerFetchedAt, viewerBookmarkFetchedAt) = (
                SELECT viewer, viewerChangedAt, viewerFetchedAt, viewerBookmarkFetchedAt FROM item AS newer
                WHERE \(newer)
                ORDER BY MAX(COALESCE(newer.viewerChangedAt, ''), COALESCE(newer.viewerFetchedAt, '')) DESC LIMIT 1)
            WHERE id = \(id) AND EXISTS (SELECT 1 FROM item AS newer WHERE \(newer))
            """)
        // Only a later bookmark list: the new copy takes its bookmark.
        let bookmarkNewer: SQL = """
            newer.mergeKey = \(item.mergeKey) AND newer.\(sameAccount) AND newer.id != \(id)
                AND newer.viewerBookmarkFetchedAt > MAX(\(fetchedAt), COALESCE(item.viewerBookmarkFetchedAt, ''))
            """
        try db.execute(literal: """
            UPDATE item SET (viewer, viewerBookmarkFetchedAt) = (
                SELECT json_set(item.viewer, '$.bookmarked', json(CASE WHEN COALESCE(json_extract(newer.viewer, '$.bookmarked'), 0) = 1 THEN 'true' ELSE 'false' END)),
                       newer.viewerBookmarkFetchedAt
                FROM item AS newer WHERE \(bookmarkNewer)
                ORDER BY newer.viewerBookmarkFetchedAt DESC LIMIT 1)
            WHERE id = \(id) AND viewer IS NOT NULL AND EXISTS (SELECT 1 FROM item AS newer WHERE \(bookmarkNewer))
            """)
    }

    /// Stores an account's bookmark list as the service has it now.
    /// `items` belong to `homeSourceID`, the account's home source; those
    /// a timeline hasn't stored are kept as `onlyInBookmarks` copies, and
    /// every copy the account holds takes the fetched viewer state, as a
    /// refetch would. When `isComplete`, the list is the whole of it, so a
    /// post the account holds as bookmarked but missing from it was
    /// unbookmarked elsewhere: it is unmarked, unless the reader changed it
    /// here after `fetchedAt`, and a bookmark-only copy of it goes. Returns
    /// how many items were new.
    @discardableResult
    public func storeBookmarks(_ items: [Item], isComplete: Bool, in homeSourceID: String, fetchedAt: Date) async throws -> Int {
        try await writer.write { db in
            guard let home = try Source.fetchOne(db, key: homeSourceID) else { return 0 }
            let items = try Self.joiningCopies(items, db)
            let inserted = try Self.insert(items.filter { $0.sourceID == homeSourceID }, db)
            guard isComplete else { return inserted }
            let sameAccount: SQL = if let accountID = home.accountID {
                "sourceID IN (SELECT id FROM source WHERE accountID = \(accountID))"
            } else {
                "sourceID = \(homeSourceID)"
            }
            let listed = Array(Set(items.map(\.mergeKey)))
            let notNewer: SQL = """
                (viewerChangedAt IS NULL OR viewerChangedAt < \(fetchedAt))
                    AND (viewerFetchedAt IS NULL OR viewerFetchedAt <= \(fetchedAt))
                    AND (viewerBookmarkFetchedAt IS NULL OR viewerBookmarkFetchedAt <= \(fetchedAt))
                """
            try db.execute(literal: """
                UPDATE item SET viewer = json_set(viewer, '$.bookmarked', json('false'))
                WHERE \(sameAccount) AND \(Self.isBookmarked) AND mergeKey NOT IN \(listed) AND \(notNewer)
                """)
            // The whole list says every other post isn't bookmarked, so a
            // fetch that began before it can't bring a bookmark back. It
            // says nothing of likes or boosts, which keep their own stamp.
            try db.execute(literal: """
                UPDATE item SET viewerBookmarkFetchedAt = \(fetchedAt)
                WHERE \(sameAccount) AND viewer IS NOT NULL AND mergeKey NOT IN \(listed)
                    AND (viewerBookmarkFetchedAt IS NULL OR viewerBookmarkFetchedAt < \(fetchedAt)) AND \(notNewer)
                """)
            try db.execute(literal: "DELETE FROM item WHERE \(sameAccount) AND onlyInBookmarks = 1 AND NOT (\(Self.isBookmarked))")
            try Self.deleteEmptyPositions(db, at: fetchedAt)
            return inserted
        }
    }

    /// How to name the item a row is shown from (`TimelineRow.id`) to its
    /// connector, for an action; nil if it has gone.
    public func itemReference(id: Int64) async throws -> ItemReference? {
        try await writer.read { db in
            try Item.fetchOne(db, key: id).map(ItemReference.init)
        }
    }

    /// Records what the reader has done to a post, on every stored copy of
    /// it that the same account fetched (its home feed and its lists can
    /// both hold the post); copies from other accounts keep their own. The
    /// change is stamped `now`, so a fetch that started earlier can't undo
    /// it. `sourceID` is the source the post was acted on from.
    public func setViewer(_ viewer: Item.Viewer, mergeKey: String, sourceID: String, at now: Date = Date()) async throws {
        try await updateViewer(mergeKey: mergeKey, sourceID: sourceID, at: now) { _ in viewer }
    }

    /// Changes the stored state of a post with `change`, read and written
    /// in one transaction, so two changes to different toggles of the same
    /// post can't overwrite each other. Copies as for `setViewer`; returns
    /// the new state of the copy in `sourceID`, or nil when it isn't
    /// stored (a post seen only in a thread).
    @discardableResult
    public func updateViewer(mergeKey: String, sourceID: String, at now: Date = Date(),
                             _ change: @escaping @Sendable (Item.Viewer) -> Item.Viewer) async throws -> Item.Viewer? {
        try await writer.write { db in
            guard let source = try Source.fetchOne(db, key: sourceID) else { return nil }
            let sameAccount: SQL = if let accountID = source.accountID {
                "sourceID IN (SELECT id FROM source WHERE accountID = \(accountID))"
            } else {
                "sourceID = \(sourceID)"
            }
            let copies = try Item.filter(literal: "mergeKey = \(mergeKey) AND \(sameAccount)").fetchAll(db)
            var result: Item.Viewer?
            for var copy in copies {
                let viewer = change(copy.viewer ?? Item.Viewer())
                if copy.sourceID == sourceID { result = viewer }
                copy.viewer = viewer
                copy.viewerChangedAt = now
                let encoded = try copy.databaseDictionary
                try db.execute(literal: """
                    UPDATE item SET viewer = \(encoded["viewer"] ?? .null), viewerChangedAt = \(encoded["viewerChangedAt"] ?? .null)
                    WHERE id = \(copy.id)
                    """)
            }
            return result
        }
    }

    /// What the reader has done to a post, as stored in `sourceID`'s copy
    /// of it; nil when that source doesn't hold the post.
    public func viewer(mergeKey: String, sourceID: String) async throws -> Item.Viewer? {
        try await writer.read { db in
            try Item.filter(Column("mergeKey") == mergeKey && Column("sourceID") == sourceID).fetchOne(db)
                .map { $0.viewer ?? Item.Viewer() }
        }
    }

    /// The item a row is shown from (`TimelineRow.id`), as stored.
    public func item(id: Int64) async throws -> Item? {
        try await writer.read { db in
            try Item.fetchOne(db, key: id)
        }
    }

    /// Deletes posts older than 7 days and articles older than 30 days,
    /// measured from `now`, and returns how many items went. An item's age
    /// counts from when it entered its source (`Item.retainedFrom`). A
    /// bookmarked post or article is kept, so it stays in Bookmarks
    ///; once the
    /// bookmark is removed it goes at the next prune, and a post stored
    /// only from the bookmark list goes then whatever its age.
    @discardableResult
    public func prune(now: Date = Date()) async throws -> Int {
        try await writer.write { db in
            let expired = Item.Kind.allCases.map { kind -> SQL in
                "(kind = \(kind.rawValue) AND MIN(MAX(publishedAt, sortDate), fetchedAt) < \(now.addingTimeInterval(-Self.retention(for: kind))))"
            }.joined(separator: " OR ")
            // A copy from the bookmark list whose bookmark has gone shows
            // nowhere, so it goes too.
            let expiredAndNotBookmarked: SQL = "((\(expired)) OR onlyInBookmarks = 1) AND NOT \(Self.inBookmarks)"
            let deleted = try Item.filter(expiredAndNotBookmarked).deleteAll(db)
            // Aged-out rows' positions go from iCloud too, so its records
            // don't outlive the posts.
            let aged = try String.fetchAll(db, sql: "SELECT mergeKey FROM timelinePosition WHERE mergeKey NOT IN (SELECT mergeKey FROM item)")
            try db.execute(sql: "DELETE FROM timelinePosition WHERE mergeKey NOT IN (SELECT mergeKey FROM item)")
            // A synced marker or position whose row never turned up within
            // the longest retention window never will.
            let longAgo = now.addingTimeInterval(-Self.articleRetention)
            try PendingLastReadMarker.filter(Column("updatedAt") < longAgo).deleteAll(db)
            let unplaced = try PendingTimelinePosition.select(Column("mergeKey"), as: String.self).filter(Column("receivedAt") < longAgo).fetchAll(db)
            try PendingTimelinePosition.filter(keys: unplaced).deleteAll(db)
            for mergeKey in aged + unplaced {
                try SyncLog.recordDeletion(db, .timelinePosition, key: mergeKey, at: now)
            }
            return deleted
        }
    }

    /// Forgets the position of every merge group that has no items left.
    /// Positions agreed through iCloud are kept aside, so the row goes back
    /// to the same place if it is fetched again, from another source.
    static func deleteEmptyPositions(_ db: Database, at now: Date) throws {
        try db.execute(literal: """
            INSERT OR REPLACE INTO pendingTimelinePosition (mergeKey, sortDate, receivedAt)
            SELECT p.mergeKey, p.sortDate, \(now) FROM timelinePosition p
            JOIN syncRecord s ON s.type = \(SyncRecordType.timelinePosition.rawValue) AND s.key = p.mergeKey
            WHERE s.systemFields IS NOT NULL AND p.mergeKey NOT IN (SELECT mergeKey FROM item)
            """)
        try db.execute(sql: "DELETE FROM timelinePosition WHERE mergeKey NOT IN (SELECT mergeKey FROM item)")
    }

    // MARK: Fetching

    /// How fetching `sourceID` last went, or nil before its first fetch.
    /// The `remoteID`s of every item stored for a source.
    public func remoteIDs(sourceID: String) async throws -> Set<String> {
        try await writer.read { db in
            try Set(String.fetchAll(db, sql: "SELECT remoteID FROM item WHERE sourceID = ?", arguments: [sourceID]))
        }
    }

    public func fetchState(sourceID: String) async throws -> SourceFetchState? {
        try await writer.read { db in
            try SourceFetchState.fetchOne(db, key: sourceID)
        }
    }

    /// Clears `.signedOut` from these sources once their account has signed
    /// in again, so the alert goes at once instead of at the next fetch.
    /// Their cursors stay, so the next fetch fills the gap.
    public func clearSignedOut(sourceIDs: [String]) async throws {
        try await writer.write { db in
            for id in sourceIDs {
                guard var state = try SourceFetchState.fetchOne(db, key: id), state.problem == .signedOut else { continue }
                state.problem = nil
                state.problemSince = nil
                state.problemDetail = nil
                try state.update(db)
            }
        }
    }

    /// Every source's fetch state, delivered again after each change, for
    /// showing problems as a quiet state on the source.
    public func observeFetchStates() -> AsyncValueObservation<[SourceFetchState]> {
        ValueObservation
            .tracking { db in try SourceFetchState.order(Column("sourceID")).fetchAll(db) }
            .removeDuplicates()
            .values(in: writer)
    }

    /// Claims `sourceID` for one refresh; false while another holds it.
    func beginRefresh(of sourceID: String) -> Bool {
        refreshing.withLock { $0.insert(sourceID).inserted }
    }

    func endRefresh(of sourceID: String) {
        _ = refreshing.withLock { $0.remove(sourceID) }
    }

    /// Stores a page fetched for `request` and moves the source's cursors
    /// on, in one transaction, so a cursor never gets ahead of the items it
    /// covers. Returns how many items were new. Nothing is stored when the
    /// source was deleted while the page was in flight, or when its cursor
    /// has moved since `request` was made: the page is stale, and storing
    /// it would wind the cursor back.
    @discardableResult
    public func record(_ page: FetchedPage, for request: FetchRequest, sourceID: String) async throws -> Int {
        try await writer.write { [onScreen] db in
            guard try Source.exists(db, key: sourceID) else { return 0 }
            let state = try SourceFetchState.fetchOne(db, key: sourceID) ?? SourceFetchState(sourceID: sourceID)
            let current = request.direction == .newer ? state.newerCursor : state.olderCursor
            guard current == request.cursor else { return 0 }
            // Once a source has given items, what a refresh brings is new
            // to the reader whatever its date, so it stays below their
            // line. A source's first items, and older pages, keep their
            // own dates.
            let belowTheLine = request.direction == .newer && state.hasFetchedItems
            let inserted = try Self.insert(page.items.filter { $0.sourceID == sourceID }, identities: page.identities,
                                           belowTheLine: belowTheLine ? onScreen.bottoms : nil, catchUpFrom: page.catchUpFrom, db)
            let next = state.recording(page, direction: request.direction, at: request.now)
            // A state that moved only its times is left for a while, so a
            // page of posts already stored wakes nothing that observes it.
            if state.needsRecording(next, at: request.now) {
                try next.upsert(db)
            }
            if let icon = page.articleIcon {
                // The feed's icon is every article's picture, and may be
                // known better now than when older rows were stored.
                try db.execute(literal: """
                    UPDATE item SET authorAvatar = \(icon)
                    WHERE sourceID = \(sourceID) AND kind = \(Item.Kind.article.rawValue) AND authorAvatar IS NOT \(icon)
                    """)
            }
            // Only a page that was accepted may move its source.
            if let movedTo = page.movedTo {
                _ = try Self.move(sourceID: sourceID, to: movedTo, db)
            }
            return inserted
        }
    }

    /// Records a failed fetch as the source's problem; its cursors stay put.
    public func recordFailure(_ error: ConnectorError, sourceID: String, at now: Date = Date()) async throws {
        try await writer.write { db in
            guard try Source.exists(db, key: sourceID) else { return }
            let state = try SourceFetchState.fetchOne(db, key: sourceID) ?? SourceFetchState(sourceID: sourceID)
            try state.recording(error, at: now).upsert(db)
        }
    }

    // MARK: Timeline

    /// The timeline's rows, oldest first.
    public func rows(in scope: Scope = .all) async throws -> [TimelineRow] {
        try await writer.read { db in
            try Self.rowsRequest(scope).fetchAll(db)
        }
    }

    /// The timeline's rows, oldest first, delivered again after every write
    /// that changes them. Iterate it off the main actor; the first value is
    /// the current timeline.
    public func observeRows(in scope: Scope = .all) -> AsyncValueObservation<[TimelineRow]> {
        ValueObservation
            .tracking { db in try Self.rowsRequest(scope).fetchAll(db) }
            .removeDuplicates()
            .values(in: writer)
    }

    /// One row per merge key, at the position fixed when the group was first
    /// stored, ordered by that position's date and then merge key. The row
    /// is shown from a rich feed's post over any other copy of it
    /// (`isRichPost`), then from a fediverse post over its Bridgy Fed copy
    /// (`isBridgedCopy`), then from the item that fixed the position while it is in scope;
    /// otherwise from the in-scope item with the earliest sort date, ties
    /// broken on source and remote ID. Each booster is named
    /// once, at their earliest boost, however many of the reader's accounts
    /// saw it. A row shown from a rich post with no picture shows another
    /// copy's, a rich post's first.
    /// Whether an item's stored viewer state says the reader bookmarked it.
    static let isBookmarked: SQL = "COALESCE(json_extract(viewer, '$.bookmarked'), 0) = 1"

    /// Whether an item belongs in Bookmarks: its service says the reader
    /// bookmarked it, or it keeps its own bookmark (an article, or a rich
    /// feed's post) and its merge key has one. A joined row whose only
    /// bookmark is a service copy's is then shown from that copy, so it
    /// shows its bookmark on; and a Mastodon or Bluesky copy never stays
    /// in Bookmarks for an own bookmark its controls can't remove, as when
    /// the rich feed it joined was removed.
    static let inBookmarks: SQL = """
        (\(isBookmarked) OR (
            (item.kind = \(Item.Kind.article.rawValue) OR item.sourceID IN (SELECT id FROM source WHERE kind = \(Source.Kind.sammyFeed.rawValue)))
            AND item.mergeKey IN (SELECT mergeKey FROM articleBookmark WHERE isBookmarked = 1)
        ))
        """

    /// Whether an item in the rows query is a rich feed's post. A row with
    /// one is shown from it: it is the fullest copy of the post, and the
    /// other copies are what it names as itself (ADR 0031).
    static let isRichPost: SQL = "(source.kind = \(Source.Kind.sammyFeed.rawValue) AND item.kind = \(Item.Kind.post.rawValue))"

    /// Whether an item in the rows query is a Bridgy Fed copy of a
    /// fediverse post: a Bluesky item linked anywhere but bsky.app. A row
    /// with the fediverse copy too is shown from that, which has the full
    /// text, links and content warning that the Bluesky copy cuts (ADR 0014).
    static let isBridgedCopy: SQL = """
        (source.kind IN \(blueskyKinds) AND item.url IS NOT NULL AND item.url NOT LIKE 'https://bsky.app/%')
        """

    /// With `mergeKey`, only that merge group's row, as `scope` shows it.
    /// `bookmarkOnlyCopies` lets `.all` include items stored only from a
    /// bookmark list (the item link's lookup); timelines never set it.
    static func rowsRequest(_ scope: Scope, mergeKey: String? = nil, bookmarkOnlyCopies: Bool = false) -> SQLRequest<TimelineRow> {
        let onlyKey: SQL = mergeKey.map { "AND item.mergeKey = \($0)" } ?? ""
        let inScope: SQL
        switch scope {
        case .all:
            inScope = bookmarkOnlyCopies ? "1 = 1" : "onlyInBookmarks = 0"
        case .sources(let ids):
            inScope = "sourceID IN \(Array(ids)) AND onlyInBookmarks = 0"
        case .bookmarked:
            inScope = inBookmarks
        }
        return """
            WITH ranked AS (
                SELECT item.id, row_number() OVER (
                    PARTITION BY item.mergeKey
                    ORDER BY \(isRichPost) DESC, \(isBridgedCopy), COALESCE(item.id = p.itemID, 0) DESC, item.sortDate, item.sourceID, remoteID
                ) AS rank
                FROM item
                JOIN timelinePosition p ON p.mergeKey = item.mergeKey
                JOIN source ON source.id = item.sourceID
                WHERE \(inScope) \(onlyKey)
            )
            SELECT
                i.id, i.kind, i.mergeKey, i.sourceID, s.title AS sourceTitle, s.colorIndex, s.kind AS sourceKind,
                i.authorName, i.authorHandle,
                -- The shown copy's picture. A row shown from a rich post
                -- with none takes another in-scope copy's, a rich post's
                -- first (its Mastodon copy may have one). Any other row is
                -- shown from its fullest copy as before, and never pays for
                -- the lookup.
                CASE
                    WHEN i.authorAvatar IS NOT NULL OR s.kind <> \(Source.Kind.sammyFeed.rawValue) OR i.kind <> \(Item.Kind.post.rawValue)
                        THEN i.authorAvatar
                    ELSE (
                        SELECT item.authorAvatar FROM item JOIN source ON source.id = item.sourceID
                        WHERE item.mergeKey = i.mergeKey AND item.authorAvatar IS NOT NULL AND \(inScope)
                        ORDER BY \(isRichPost) DESC, item.sortDate, item.sourceID, item.remoteID
                        LIMIT 1
                    )
                END AS authorAvatar,
                i.title,
                -- No more of the body than a row can show (TimelineRow.bodyLimit
                -- UTF-16 units, so at most that many characters, and one more
                -- to tell it was cut): a row is never built from a whole
                -- 100,000-character post.
                substr(i.body, 1, \(TimelineRow.bodyLimit + 1)) AS body, i.url,
                i.publishedAt, p.sortDate, MIN(i.sortDate, i.fetchedAt) AS postedAt, i.replyToHandle, i.linkCard, i.media, i.quote, i.viewer, i.links, i.badge,
                -- A rich post's thread: from any of its rich copies in scope
                -- that names one, its own first (TimelineRow.threadItemID).
                CASE
                    WHEN s.kind <> \(Source.Kind.sammyFeed.rawValue) OR i.kind <> \(Item.Kind.post.rawValue) THEN NULL
                    WHEN i.actionRef GLOB 'thread:?*' THEN i.id
                    ELSE (
                        SELECT id FROM item
                        WHERE mergeKey = i.mergeKey AND kind = \(Item.Kind.post.rawValue) AND actionRef GLOB 'thread:?*'
                            AND sourceID IN (SELECT id FROM source WHERE kind = \(Source.Kind.sammyFeed.rawValue)) AND \(inScope)
                        ORDER BY sortDate, sourceID, remoteID
                        LIMIT 1
                    )
                END AS threadItemID,
                (
                    SELECT group_concat(boostedBy, \(TimelineRow.boosterSeparator))
                    FROM (
                        SELECT boostedBy FROM (
                            SELECT boostedBy, sortDate, sourceID, remoteID, row_number() OVER (
                                PARTITION BY COALESCE(boostedByID, boostedBy)
                                ORDER BY sortDate, sourceID, remoteID
                            ) AS boost
                            FROM item
                            WHERE mergeKey = i.mergeKey AND boostedBy IS NOT NULL AND \(inScope)
                        )
                        WHERE boost = 1
                        ORDER BY sortDate, sourceID, remoteID
                    )
                ) AS boosters,
                (
                    SELECT boostedByAvatar FROM item
                    WHERE mergeKey = i.mergeKey AND boostedBy IS NOT NULL AND \(inScope)
                    ORDER BY sortDate, sourceID, remoteID
                    LIMIT 1
                ) AS boosterAvatar,
                COALESCE(r.isRead, 0) AS isRead,
                COALESCE(b.isBookmarked, 0) AS articleBookmarked
            FROM ranked
            JOIN item i ON i.id = ranked.id AND ranked.rank = 1
            JOIN timelinePosition p ON p.mergeKey = i.mergeKey
            JOIN source s ON s.id = i.sourceID
            LEFT JOIN articleReadState r ON r.mergeKey = i.mergeKey
            LEFT JOIN articleBookmark b ON b.mergeKey = i.mergeKey
            ORDER BY p.sortDate, i.mergeKey
            """
    }

    /// A saved view's rows, oldest first, without the ones its filters
    /// hide. A view that no longer exists has none.
    public func rows(inView viewID: String) async throws -> [TimelineRow] {
        try await writer.read { db in
            try Self.rows(inView: viewID, db)
        }
    }

    /// A saved view's rows as `rows(inView:)` reads them, delivered again
    /// after every write that changes them, including a change to the view
    /// or its filters. Filtered rows never reach the timeline, so they are
    /// never laid out and never take space.
    public func observeRows(inView viewID: String) -> AsyncValueObservation<[TimelineRow]> {
        ValueObservation
            .tracking { db in try Self.rows(inView: viewID, db) }
            .removeDuplicates()
            .values(in: writer)
    }

    private static func rows(inView viewID: String, _ db: Database) throws -> [TimelineRow] {
        let scope: Scope
        if viewID == SavedView.allID {
            scope = .all
        } else if viewID == SavedView.bookmarksID {
            scope = .bookmarked
        } else {
            guard let view = try SavedView.fetchOne(db, key: viewID) else { return [] }
            scope = .sources(Set(view.sourceIDs))
        }
        let rows = try rowsRequest(scope).fetchAll(db)
        let filters = try ContentFilter.filter(Column("isEnabled") == true).fetchAll(db).filter { $0.applies(in: viewID) }
        return TimelineFilter(filters).apply(to: rows)
    }

    // MARK: Saved views and filters

    /// The saved views, in list order; the All view isn't among them.
    public func savedViews() async throws -> [SavedView] {
        try await writer.read { db in
            try Self.savedViewsRequest.fetchAll(db)
        }
    }

    /// The saved views, in list order, delivered again after each change.
    public func observeSavedViews() -> AsyncValueObservation<[SavedView]> {
        ValueObservation
            .tracking { db in try Self.savedViewsRequest.fetchAll(db) }
            .removeDuplicates()
            .values(in: writer)
    }

    private static var savedViewsRequest: QueryInterfaceRequest<SavedView> {
        SavedView.order(Column("sortIndex"), Column("name"))
    }

    /// Adds a saved view, or updates the one with its ID.
    public func save(view: SavedView) async throws {
        try await writer.write { db in
            guard try SavedView.fetchOne(db, key: view.id) != view else { return }
            try view.upsert(db)
            try SyncLog.recordChange(db, .savedView, key: view.id, at: Date())
        }
    }

    /// Changes a saved view as it is stored now, in one write, so two
    /// changes made in quick succession (a rename and a source switched on)
    /// never start from the same old copy and undo each other. Does nothing
    /// if the view has gone.
    public func updateView(id: String, at now: Date = Date(), _ change: @escaping @Sendable (inout SavedView) -> Void) async throws {
        try await writer.write { db in
            guard var view = try SavedView.fetchOne(db, key: id) else { return }
            change(&view)
            view.id = id
            view.updatedAt = now
            try view.update(db)
            try SyncLog.recordChange(db, .savedView, key: id, at: now)
        }
    }

    /// Removes a saved view with its own filters, last-read marker and
    /// reading place, on every device.
    public func deleteView(id: String, at now: Date = Date()) async throws {
        guard !SavedView.isBuiltIn(id) else { return }
        try await writer.write { db in
            let filterIDs = try String.fetchAll(db, sql: "SELECT id FROM contentFilter WHERE viewID = ?", arguments: [id])
            try Self.deleteView(id: id, db)
            try SyncLog.recordDeletion(db, .savedView, key: id, at: now)
            try SyncLog.recordDeletion(db, .lastReadMarker, key: id, at: now)
            try SyncLog.recordDeletion(db, .readingPlace, key: id, at: now)
            for filterID in filterIDs {
                try SyncLog.recordDeletion(db, .contentFilter, key: filterID, at: now)
            }
        }
    }

    static func deleteView(id: String, _ db: Database) throws {
        try SavedView.deleteOne(db, key: id)
        try ContentFilter.filter(Column("viewID") == id).deleteAll(db)
        try LastReadMarker.deleteOne(db, key: id)
        try PendingLastReadMarker.filter(Column("viewID") == id).deleteAll(db)
        try ReadingPlace.deleteOne(db, key: id)
    }

    /// Every filter, for every view, by pattern.
    public func filters() async throws -> [ContentFilter] {
        try await writer.read { db in
            try Self.filtersRequest.fetchAll(db)
        }
    }

    /// Every filter, delivered again after each change.
    public func observeFilters() -> AsyncValueObservation<[ContentFilter]> {
        ValueObservation
            .tracking { db in try Self.filtersRequest.fetchAll(db) }
            .removeDuplicates()
            .values(in: writer)
    }

    private static var filtersRequest: QueryInterfaceRequest<ContentFilter> {
        ContentFilter.order(Column("pattern").collating(.nocase), Column("id"))
    }

    /// Adds a filter, or updates the one with its ID.
    public func save(filter: ContentFilter) async throws {
        try await writer.write { db in
            guard try ContentFilter.fetchOne(db, key: filter.id) != filter else { return }
            try filter.upsert(db)
            try SyncLog.recordChange(db, .contentFilter, key: filter.id, at: Date())
        }
    }

    public func deleteFilter(id: String, at now: Date = Date()) async throws {
        try await writer.write { db in
            _ = try ContentFilter.deleteOne(db, key: id)
            try SyncLog.recordDeletion(db, .contentFilter, key: id, at: now)
        }
    }

    // MARK: Read state

    /// Moves a saved view's last-read marker to `row`, unless the marker is
    /// already further along; returns whether it moved. A move goes to
    /// iCloud on the next sync, where the furthest marker wins.
    ///
    /// A row's date can differ between devices, so the marker
    /// always takes this store's date for the row, never the one it arrived
    /// with. A marker for a row this store doesn't have yet is set aside,
    /// leaving the current marker where it is, and placed by `insert` when
    /// the row arrives; the next synced marker usually names a row this
    /// store has anyway.
    @discardableResult
    public func moveLastReadMarker(viewID: String, to row: (sortDate: Date, mergeKey: String), at now: Date = Date()) async throws -> Bool {
        try await writer.write { db in
            guard let localDate = try Date.fetchOne(db, sql: "SELECT sortDate FROM timelinePosition WHERE mergeKey = ?", arguments: [row.mergeKey]) else {
                try PendingLastReadMarker(viewID: viewID, mergeKey: row.mergeKey, updatedAt: now, sortDate: row.sortDate).upsert(db)
                return false
            }
            let marker = LastReadMarker(viewID: viewID, sortDate: localDate, mergeKey: row.mergeKey, updatedAt: now)
            guard try Self.advance(db, to: marker) else {
                return false
            }
            try SyncLog.recordChange(db, .lastReadMarker, key: viewID, at: now)
            try SyncJournal.note(db, .place, "marker of \(viewID) read on to \(SyncJournal.describe(marker))", at: now)
            return true
        }
    }

    /// Stores `candidate` if it is further along than the view's marker.
    @discardableResult
    static func advance(_ db: Database, to candidate: LastReadMarker) throws -> Bool {
        if let current = try LastReadMarker.fetchOne(db, key: candidate.viewID), !candidate.isAhead(of: current) {
            return false
        }
        try candidate.upsert(db)
        return true
    }

    /// The earliest of the views' last-read markers, counting those set
    /// aside until their row arrives: how far back every timeline needs its
    /// posts, so each view's unread rows, and a set-aside marker's row, are
    /// all here.
    public func earliestLastReadDate() async throws -> Date? {
        try await writer.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MIN(sortDate) FROM (
                    SELECT sortDate FROM lastReadMarker
                    UNION ALL SELECT sortDate FROM pendingLastReadMarker WHERE sortDate IS NOT NULL
                )
                """)
        }
    }

    /// How far back a source's timeline has been fetched: the earliest
    /// placement (its timeline date, never later than its fetch) of the
    /// items kept from it, or nil when there are none. Not the publish
    /// date, which a fresh boost of an old post would make look further
    /// back than the pages fetched. Items placed before `notBefore` (the
    /// retention floor) don't count: the only ones left are bookmarks kept
    /// past it, which say nothing about the pages since.
    public func oldestItemDate(sourceID: String, notBefore: Date = .distantPast) async throws -> Date? {
        try await writer.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MIN(MIN(sortDate, fetchedAt)) FROM item
                WHERE sourceID = ? AND onlyInBookmarks = 0 AND MIN(sortDate, fetchedAt) >= ?
                """, arguments: [sourceID, notBefore])
        }
    }

    /// The latest placement (`Item.placement`) of the items kept from a
    /// source's timeline, or nil when there are none: where a catch-up
    /// read of it begins (`FetchedPage.catchUpFrom`).
    public func newestItemDate(sourceID: String) async throws -> Date? {
        try await writer.read { db in
            try Date.fetchOne(db, sql: """
                SELECT MAX(MIN(sortDate, fetchedAt)) FROM item WHERE sourceID = ? AND onlyInBookmarks = 0
                """, arguments: [sourceID])
        }
    }

    public func lastReadMarker(viewID: String) async throws -> LastReadMarker? {
        try await writer.read { db in
            try LastReadMarker.fetchOne(db, key: viewID)
        }
    }

    /// A view's marker, delivered again whenever it moves, whether this
    /// device's reader moved it or one arrived from another device.
    public func observeLastReadMarker(viewID: String) -> AsyncValueObservation<LastReadMarker?> {
        ValueObservation
            .tracking { db in try LastReadMarker.fetchOne(db, key: viewID) }
            .removeDuplicates()
            .values(in: writer)
    }

    // MARK: Reading place

    /// Moves a saved view's reading place to `row`, which is at the top of
    /// the reader's screen, if the move may replace the shared place
    /// (ADR 0028): the reader had seen the place it replaces, or the row
    /// is further along than it. Any other move stays on this device: it
    /// was made from a screen that hadn't caught up, and must not take
    /// every device back with it. A move that stands is one more than the
    /// place it replaces, and goes to iCloud on the next sync.
    ///
    /// The rule is applied here, in the same write, because the place may
    /// have changed since the timeline last heard of it. `knowledge` is
    /// what the reader had seen when they moved. `because` says what made
    /// the timeline save, for the sync journal.
    @discardableResult
    public func moveReadingPlace(viewID: String, to row: (sortDate: Date, mergeKey: String), at now: Date = Date(),
                                 knowing knowledge: PlaceKnowledge = .current,
                                 because reason: String? = nil) async throws -> ReadingPlaceMove {
        try await writer.write { db in
            let current = try ReadingPlace.fetchOne(db, key: viewID)
            if let current, current.mergeKey == row.mergeKey {
                return .unchanged(current)
            }
            var place = ReadingPlace(viewID: viewID, mergeKey: row.mergeKey, sortDate: row.sortDate, updatedAt: now,
                                     move: (current?.move ?? 0) + 1, device: try SyncLog.device(db))
            let why = reason.map { " (\($0))" } ?? ""
            var basis = "the first place"
            if let current {
                if knowledge.includes(current) {
                    basis = "the reader had seen the place before it"
                } else if try SyncMerge.furtherAlong(place, than: current, db) {
                    basis = "further along than the place here, which the reader hadn't seen"
                } else {
                    try SyncJournal.note(db, .place, """
                        move of \(viewID) to \(row.mergeKey) stays on this device\(why): the reader hadn't seen the \
                        place \(SyncJournal.describe(current)), and this isn't further along
                        """)
                    return .stayedLocal(current: current)
                }
            }
            try SyncLog.recordChange(db, .readingPlace, key: viewID, at: now)
            place.updatedAt = try SyncRecordState.fetchOne(db, key: SyncRecord.name(type: .readingPlace, key: viewID))?.modifiedAt ?? now
            try place.upsert(db)
            try SyncJournal.note(db, .place, """
                place of \(viewID) set here\(why): \(SyncJournal.describe(place)); \(basis); \
                was \(SyncJournal.describe(current))
                """)
            return .moved(place)
        }
    }

    public func readingPlace(viewID: String) async throws -> ReadingPlace? {
        try await writer.read { db in
            try ReadingPlace.fetchOne(db, key: viewID)
        }
    }

    /// A view's reading place, delivered again whenever it changes, whether
    /// this device's reader moved it or it arrived from another device.
    public func observeReadingPlace(viewID: String) -> AsyncValueObservation<ReadingPlace?> {
        ValueObservation
            .tracking { db in try ReadingPlace.fetchOne(db, key: viewID) }
            .removeDuplicates()
            .values(in: writer)
    }

    /// Marks an article read or unread. A change only applies when it
    /// supersedes the one stored: last writer wins, and a tie goes to
    /// "read", so changes from other devices settle the same way.
    public func setArticle(mergeKey: String, read: Bool, at now: Date = Date()) async throws {
        let change = ArticleReadState(mergeKey: mergeKey, isRead: read, updatedAt: now)
        try await writer.write { db in
            if let current = try ArticleReadState.fetchOne(db, key: mergeKey), !change.supersedes(current) {
                return
            }
            try change.upsert(db)
            try SyncLog.recordChange(db, .articleReadState, key: mergeKey, at: now)
        }
    }

    /// Bookmarks an article or removes its bookmark. As
    /// with read state, a change only applies when it supersedes the one
    /// stored: last writer wins, and a tie goes to the bookmark.
    public func setArticle(mergeKey: String, bookmarked: Bool, at now: Date = Date()) async throws {
        let change = ArticleBookmark(mergeKey: mergeKey, isBookmarked: bookmarked, updatedAt: now)
        try await writer.write { db in
            if let current = try ArticleBookmark.fetchOne(db, key: mergeKey), !change.supersedes(current) {
                return
            }
            try change.upsert(db)
            try SyncLog.recordChange(db, .articleBookmark, key: mergeKey, at: now)
        }
    }

    /// Flips Influx's own bookmark of an article or a rich feed's post
    /// (`TimelineRow.keepsOwnBookmark`), as it is stored now, in one write, so
    /// two quick taps never start from the same old state. Returns whether
    /// it is bookmarked now. The change is stamped no earlier than the one
    /// it replaces, so a tap always wins even if another device's clock
    /// ran ahead.
    @discardableResult
    public func toggleOwnBookmark(mergeKey: String, at now: Date = Date()) async throws -> Bool {
        try await writer.write { db in
            let current = try ArticleBookmark.fetchOne(db, key: mergeKey)
            let isBookmarked = !(current?.isBookmarked ?? false)
            let at = max(now, current.map { $0.updatedAt.addingTimeInterval(0.001) } ?? now)
            try ArticleBookmark(mergeKey: mergeKey, isBookmarked: isBookmarked, updatedAt: at).upsert(db)
            try SyncLog.recordChange(db, .articleBookmark, key: mergeKey, at: at)
            return isBookmarked
        }
    }
}
