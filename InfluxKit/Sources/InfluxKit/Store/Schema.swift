import Foundation
import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: Source.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("accountID", .text)
                t.column("title", .text).notNull()
                t.column("url", .text)
                t.column("colorIndex", .integer).notNull()
            }

            try db.create(table: Item.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("sourceID", .text)
                    .notNull()
                    .indexed()
                    .references(Source.databaseTableName, onDelete: .cascade)
                t.column("remoteID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("mergeKey", .text).notNull().indexed()
                t.column("authorName", .text).notNull()
                t.column("authorHandle", .text).notNull()
                t.column("title", .text)
                t.column("body", .text).notNull()
                t.column("url", .text)
                t.column("publishedAt", .datetime).notNull()
                t.column("fetchedAt", .datetime).notNull()
                t.column("sortDate", .datetime).notNull()
                t.column("boostedBy", .text)
                t.column("replyToHandle", .text)
                t.column("linkCard", .jsonText)
                t.column("mediaAspect", .double)
                t.uniqueKey(["sourceID", "remoteID"])
            }

            // Where each merge group sits in the timeline, fixed when the
            // group is first stored.
            try db.create(table: "timelinePosition") { t in
                t.primaryKey("mergeKey", .text)
                t.column("sortDate", .datetime).notNull()
                t.column("itemID", .integer).references(Item.databaseTableName, onDelete: .setNull)
            }
            try db.create(index: "timelinePosition_on_sortDate_mergeKey", on: "timelinePosition", columns: ["sortDate", "mergeKey"])

            try db.create(table: LastReadMarker.databaseTableName) { t in
                t.primaryKey("viewID", .text)
                t.column("sortDate", .datetime).notNull()
                t.column("mergeKey", .text).notNull()
                t.column("updatedAt", .datetime).notNull()
            }

            try db.create(table: PendingLastReadMarker.databaseTableName) { t in
                t.column("viewID", .text).notNull()
                t.column("mergeKey", .text).notNull().indexed()
                t.column("updatedAt", .datetime).notNull()
                t.primaryKey(["viewID", "mergeKey"])
            }

            try db.create(table: ArticleReadState.databaseTableName) { t in
                t.primaryKey("mergeKey", .text)
                t.column("isRead", .boolean).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2: source fetch state") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "actionRef", .text)
            }

            try db.create(table: SourceFetchState.databaseTableName) { t in
                t.primaryKey("sourceID", .text)
                    .references(Source.databaseTableName, onDelete: .cascade)
                t.column("newerCursor", .text)
                t.column("olderCursor", .text)
                t.column("reachedOldest", .boolean).notNull().defaults(to: false)
                t.column("hasFetchedItems", .boolean).notNull().defaults(to: false)
                t.column("lastAttemptAt", .datetime)
                t.column("lastSuccessAt", .datetime)
                t.column("problem", .text)
                t.column("problemSince", .datetime)
                t.column("problemDetail", .text)
                t.column("retryAfter", .datetime)
            }
        }
        migrator.registerMigration("v3: sized media") { db in
            // Media now carries its pixel size; old rows had only an aspect
            // ratio, and lose their media box rather than keep an unsized one.
            // They start with no media, so every item decodes.
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "media", .jsonText).notNull().defaults(sql: "'[]'")
                t.drop(column: "mediaAspect")
            }
        }

        // A quoted post, shown as a card in its row.
        migrator.registerMigration("v4: item quote") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "quote", .jsonText)
            }
        }

        // Who boosted an item, as an account ID, so a boost seen through two
        // of the reader's accounts names its booster once. Items
        // stored before have none and fall back to the booster's name.
        migrator.registerMigration("v5: booster ID") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "boostedByID", .text)
            }
        }

        // Likes, boosts and bookmarks, and the links in a post's text.
        // Rows stored before have no links; their text shows as it did.
        // Their posts get viewer state marked unconfirmed, so they show
        // their actions, and the service is asked before one is sent.
        migrator.registerMigration("v6: item viewer and links") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "viewer", .jsonText)
                t.add(column: "viewerChangedAt", .datetime)
                t.add(column: "links", .jsonText).notNull().defaults(sql: "'[]'")
            }
            try db.execute(sql: """
                UPDATE item SET viewer = '{"liked":false,"boosted":false,"bookmarked":false,"unconfirmed":true}'
                WHERE kind = 'post'
                """)
        }

        // Saved views and the reader's keyword and regex filters.
        migrator.registerMigration("v7: saved views and filters") { db in
            try db.create(table: SavedView.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sourceIDs", .jsonText).notNull()
                t.column("sortIndex", .integer).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: ContentFilter.databaseTableName) { t in
                t.primaryKey("id", .text)
                t.column("pattern", .text).notNull()
                t.column("match", .text).notNull()
                t.column("viewID", .text).indexed()
                t.column("isEnabled", .boolean).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        // iCloud sync: which records wait to go up, the server's
        // fields for each, positions learned from iCloud for rows not yet
        // stored, synced settings, and the sync engine's own state. Records
        // for everything already stored start out pending, so the first
        // sync uploads them.
        migrator.registerMigration("v8: sync") { db in
            try db.create(table: SyncRecordState.databaseTableName) { t in
                t.primaryKey("recordName", .text)
                t.column("type", .text).notNull()
                t.column("key", .text).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("systemFields", .blob)
                t.column("pending", .integer).indexed()
                t.column("isDeleted", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "syncRecord_on_type_key", on: SyncRecordState.databaseTableName, columns: ["type", "key"])

            try db.create(table: PendingTimelinePosition.databaseTableName) { t in
                t.primaryKey("mergeKey", .text)
                t.column("sortDate", .datetime).notNull()
                t.column("receivedAt", .datetime).notNull()
            }

            try db.create(table: SyncedSetting.databaseTableName) { t in
                t.primaryKey("key", .text)
                t.column("value", .blob)
            }

            try db.create(table: "syncEngineState") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("data", .blob).notNull()
            }

            try SyncLog.enqueueEverything(db, at: Date())
        }
        // Profile pictures: the author's (an article's feed icon) and a
        // booster's. Rows stored before have none and draw a monogram.
        migrator.registerMigration("v9: avatars") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "authorAvatar", .text)
                t.add(column: "boostedByAvatar", .text)
            }
        }
        // Positions stored before sync started, or forgotten by a reset,
        // were never offered, so another device's later position could
        // win; offering them lets the earliest win.
        migrator.registerMigration("v10: offer placed positions") { db in
            try SyncLog.offerPlacedPositions(db, at: Date())
        }
        // Change numbers that are never reused (`SyncLog.nextVersion`).
        migrator.registerMigration("v11: sync change numbers") { db in
            try db.create(table: "syncVersion") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("last", .integer).notNull()
            }
            try db.execute(sql: "INSERT INTO syncVersion (id, last) SELECT 1, COALESCE(MAX(pending), 0) FROM syncRecord")
        }
        // Posts stored from an account's bookmark list, shown only in
        // Bookmarks.
        migrator.registerMigration("v12: bookmark list") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "onlyInBookmarks", .boolean).notNull().defaults(to: false)
            }
        }
        // A set-aside marker's row date, so the timelines fetch back to it.
        migrator.registerMigration("v13: pending marker dates") { db in
            try db.alter(table: PendingLastReadMarker.databaseTableName) { t in
                t.add(column: "sortDate", .datetime)
            }
        }
        // Where the reader is in each view, synced both ways.
        // None to start with: a view opens on its marker until it has one.
        migrator.registerMigration("v14: reading places") { db in
            try db.create(table: ReadingPlace.databaseTableName) { t in
                t.primaryKey("viewID", .text)
                t.column("mergeKey", .text).notNull()
                t.column("sortDate", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        // Bookmarked articles, kept here and synced.
        migrator.registerMigration("v15: article bookmarks") { db in
            try db.create(table: ArticleBookmark.databaseTableName) { t in
                t.primaryKey("mergeKey", .text)
                t.column("isBookmarked", .boolean).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
        // When the viewer state, and the bookmark alone, were last
        // fetched, so an older fetch that finishes late doesn't overwrite a
        // newer one.
        migrator.registerMigration("v16: viewer fetch dates") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "viewerFetchedAt", .datetime)
                t.add(column: "viewerBookmarkFetchedAt", .datetime)
            }
        }
        // A bridged copy's own ID, when it is filed under its other copy's
        // merge key, so a later, different post can't join the pair.
        migrator.registerMigration("v17: bridged post keys") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "postKey", .text)
            }
        }
        // A score shown beside an article's title, from feeds that send
        // one (a Sammy feed's `_sammy.metascore`).
        migrator.registerMigration("v18: item badges") { db in
            try db.alter(table: Item.databaseTableName) { t in
                t.add(column: "badge", .text)
            }
        }
        // The newest row a place's device had when it was at the bottom
        // of its timeline, so a device with newer rows isn't taken back to
        // it (influx-dev #131).
        migrator.registerMigration("v19: reading place newest rows") { db in
            try db.alter(table: ReadingPlace.databaseTableName) { t in
                t.add(column: "newestMergeKey", .text)
                t.add(column: "newestSortDate", .datetime)
            }
        }
        // The sync journal: what this device did with the reader's place
        // and what iCloud sent it, kept for days (`SyncJournal`).
        migrator.registerMigration("v20: sync journal") { db in
            try db.create(table: SyncJournalEntry.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("at", .datetime).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("message", .text).notNull()
            }
        }
        // Which move of the shared place each reading place is, so that
        // devices agree on one without comparing clocks (ADR 0028). The
        // newest-row columns of v19 are no longer read or written.
        migrator.registerMigration("v21: reading place moves") { db in
            try db.alter(table: ReadingPlace.databaseTableName) { t in
                t.add(column: "move", .integer).notNull().defaults(to: 0)
                // Which install of Influx the reader was on.
                t.add(column: "device", .text)
            }
            // The last place each view had that iCloud had too.
            try db.create(table: ReadingPlaceBase.databaseTableName) { t in
                t.primaryKey("viewID", .text)
                t.column("mergeKey", .text).notNull()
                t.column("sortDate", .datetime).notNull()
                t.column("move", .integer).notNull()
            }
            // A place already here with nothing waiting to go up is the
            // one iCloud has.
            try db.execute(sql: """
                INSERT INTO readingPlaceBase (viewID, mergeKey, sortDate, move)
                SELECT place.viewID, place.mergeKey, place.sortDate, place.move
                FROM readingPlace place
                JOIN syncRecord sent ON sent.type = 'ReadingPlace' AND sent.key = place.viewID
                WHERE sent.pending IS NULL AND NOT sent.isDeleted
                """)
            // A name for this install, made here and never shown: it tells
            // a place this device set from one another device did.
            try db.create(table: "syncDevice") { t in
                t.primaryKey("id", .integer).check { $0 == 1 }
                t.column("name", .text).notNull()
            }
            try db.execute(sql: "INSERT INTO syncDevice (id, name) VALUES (1, lower(hex(randomblob(8))))")
        }
        // Records from iCloud this build couldn't read, kept as they
        // arrived for a build that can (`UnreadSyncRecord`).
        migrator.registerMigration("v22: unread sync records") { db in
            try db.create(table: UnreadSyncRecord.databaseTableName) { t in
                t.primaryKey("recordName", .text)
                t.column("type", .text).notNull()
                t.column("key", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("systemFields", .blob).notNull()
                t.column("isNewer", .boolean).notNull()
                t.column("receivedAt", .datetime).notNull()
            }
        }
        // What a source's items are, posts or articles, as its service
        // listed it; null when unknown (ADR 0031).
        migrator.registerMigration("v23: source item kind") { db in
            try db.alter(table: Source.databaseTableName) { t in
                t.add(column: "itemKind", .text)
            }
            // `sammy-post:` merge keys are a Sammy server's rich posts'
            // from this version on (ADR 0031), and only its own feeds may
            // hold one (`reservingSammyPostKeys`). No feed served rich posts
            // before, so any item stored with such a key came from a server
            // that sent the string as a post's URI. It goes back to a key
            // only its source uses, keeping its place: its timeline position
            // moves to the new key, so the row stays where it was. Nothing
            // is left under the old key, so a rich post that arrives later
            // can't take the row or its reading state. A reading place or
            // marker naming the old key waits for a post with that key, as
            // it does for any post not here yet.
            let claimed = { (column: String) in
                "substr(\(column), 1, \(SammyPostKey.prefix.count)) = '\(SammyPostKey.prefix)'"
            }
            let now = Date()
            // The reserved keys local items claim. Only these are claims: a
            // pending position under a reserved key with no item here may be
            // a genuine rich post's, synced from a device already upgraded,
            // and is left as it is.
            let claims = try String.fetchAll(db, sql: "SELECT DISTINCT mergeKey FROM item WHERE \(claimed("mergeKey"))")
            guard !claims.isEmpty else { return }
            let moved = try String.fetchAll(db, sql: """
                SELECT item.sourceID || '#' || item.remoteID
                FROM item JOIN timelinePosition AS position ON position.mergeKey = item.mergeKey
                WHERE \(claimed("item.mergeKey"))
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO timelinePosition (mergeKey, sortDate, itemID)
                SELECT item.sourceID || '#' || item.remoteID, position.sortDate, item.id
                FROM item JOIN timelinePosition AS position ON position.mergeKey = item.mergeKey
                WHERE \(claimed("item.mergeKey"))
                """)
            try db.execute(sql: "UPDATE item SET mergeKey = sourceID || '#' || remoteID, postKey = NULL WHERE \(claimed("mergeKey"))")
            // iCloud may hold a claim's position; its deletion goes up too,
            // so a full sync or a new device can't bring it back for a rich
            // post to take. The moved positions are offered under their
            // new keys.
            for key in claims { try SyncLog.recordDeletion(db, .timelinePosition, key: key, at: now) }
            for key in moved { try SyncLog.offerPosition(db, mergeKey: key, at: now) }
            try db.execute(literal: "DELETE FROM timelinePosition WHERE mergeKey IN \(claims)")
            try db.execute(literal: "DELETE FROM \(sql: PendingTimelinePosition.databaseTableName) WHERE mergeKey IN \(claims)")
        }
        // Each item's identities, by which a rich feed's post and other
        // copies of it show as one row (`PostIdentity`, ADR 0014, 0031): a
        // rich post's `{canonicalId} ∪ aliases`, a native post's legacy
        // identity. They go with their item.
        migrator.registerMigration("v24: post identities") { db in
            try db.create(table: PostIdentity.tableName) { t in
                t.column("itemID", .integer).notNull().references(Item.databaseTableName, onDelete: .cascade)
                t.column("identity", .text).notNull().indexed()
                t.primaryKey(["itemID", "identity"])
            }
            // A copy's own key, when it is filed under another's, is looked
            // up when another copy of its post arrives.
            try db.create(index: "item_on_postKey", on: Item.databaseTableName, columns: ["postKey"])
            // Native posts already stored can be named from now on. The
            // aliases of rich posts already stored weren't kept; their set
            // is recorded the next time their feed sends them.
            let rows = try Row.fetchAll(db, sql: """
                SELECT item.id, item.kind, item.mergeKey, item.postKey, source.kind AS sourceKind
                FROM item JOIN source ON source.id = item.sourceID
                """)
            for row in rows {
                guard let kind = Item.Kind(rawValue: row["kind"]), let sourceKind = Source.Kind(rawValue: row["sourceKind"]),
                      let own = PostIdentity.nativeIdentity(kind: kind, mergeKey: row["mergeKey"], postKey: row["postKey"], sourceKind: sourceKind),
                      let legacy = LegacyPostIdentity.alias(of: own) else { continue }
                let id: Int64 = row["id"]
                try db.execute(literal: "INSERT OR IGNORE INTO \(sql: PostIdentity.tableName) (itemID, identity) VALUES (\(id), \(legacy))")
            }
        }
        // Bookmarks to Sammy Inbox: the bookmarks this device has to send,
        // one row per bookmark and Sammy account, kept a while after they
        // are sent or dropped for the account screen to count. Local only:
        // nothing here is synced, so only the device that made a bookmark
        // ever sends it.
        migrator.registerMigration("v25: sammy outbox") { db in
            try db.create(table: SammyOutboxEntry.databaseTableName) { t in
                t.column("key", .text).notNull()
                t.column("accountID", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("fromLabel", .text).notNull()
                t.column("url", .text).notNull()
                t.column("bookmarkedAt", .datetime).notNull()
                t.column("queuedAt", .datetime).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextAttemptAt", .datetime)
                t.column("status", .text).notNull()
                t.column("dropReason", .text)
                t.column("settledAt", .datetime)
                t.primaryKey(["key", "accountID"])
            }
            try db.create(index: "sammyOutbox_on_accountID_status", on: SammyOutboxEntry.databaseTableName, columns: ["accountID", "status"])
        }
        // A Sammy account whose token Sammy refused while a bookmark was
        // being sent, by a hash of that token, so the account still asks to
        // be signed in again after a relaunch, and stops asking once a
        // different token is stored for it. Local only, never synced.
        migrator.registerMigration("v26: sammy refusals") { db in
            try db.create(table: SammyRefusal.databaseTableName) { t in
                t.primaryKey("accountID", .text)
                t.column("tokenHash", .text).notNull()
                t.column("refusedAt", .datetime).notNull()
            }
        }
        // Build 0.1.0 (9) stored every post a rich feed's catch-up read
        // brought, days of older ones the reader never had among them, as
        // new rows at the bottom. Those the reader can't have seen or used
        // go (`CatchUpRepair`, ADR 0031).
        migrator.registerMigration("v27: posts a catch-up read added") { db in
            try CatchUpRepair.run(db, at: Date())
        }
        // Why each row sits where it does: how it was placed, what joined
        // it, and when iCloud moved it (`RowEvent`, ADR 0043). Local only,
        // never synced; it goes with the row's last item.
        migrator.registerMigration("v28: row history") { db in
            try db.create(table: RowEvent.databaseTableName) { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("mergeKey", .text).notNull()
                t.column("at", .datetime).notNull()
                t.column("kind", .text).notNull()
                t.column("sortDate", .datetime).notNull()
                t.column("sourceID", .text)
                t.column("remoteID", .text)
                t.column("publishedAt", .datetime)
                t.column("fetchedAt", .datetime)
                t.column("via", .text)
                t.column("how", .text)
                t.column("lineView", .text)
                t.column("lineBound", .text)
                t.column("lineDate", .datetime)
                t.column("previous", .datetime)
                t.column("offered", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "rowEvent_on_mergeKey", on: RowEvent.databaseTableName, columns: ["mergeKey"])
            try db.create(index: "rowEvent_on_at", on: RowEvent.databaseTableName, columns: ["at"])
        }
        return migrator
    }
}
