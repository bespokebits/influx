import Foundation
import GRDB
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private let rss = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 3)
private let mastodon = Source(id: "mastodon:@me@example.social:home", kind: .mastodonHome, accountID: "@me@example.social", title: "Mastodon", colorIndex: 1)

private func post(_ remoteID: String, in source: Source = mastodon, key: String? = nil, at offset: TimeInterval,
                  fetchedAt: TimeInterval? = nil, sortDate: TimeInterval? = nil, boostedBy: String? = nil) -> Item {
    Item(
        sourceID: source.id, remoteID: remoteID, kind: .post, mergeKey: key ?? "post:\(remoteID)",
        authorName: "Ana Ruiz", authorHandle: "@ana", body: "Post \(remoteID)",
        publishedAt: t0.addingTimeInterval(offset), fetchedAt: t0.addingTimeInterval(fetchedAt ?? offset),
        sortDate: sortDate.map(t0.addingTimeInterval),
        boostedBy: boostedBy
    )
}

private func article(_ remoteID: String, at offset: TimeInterval) -> Item {
    Item(
        sourceID: rss.id, remoteID: remoteID, kind: .article, mergeKey: "https://example.com/\(remoteID)",
        authorName: "Example", authorHandle: "example.com", title: "Article \(remoteID)", body: "Summary",
        url: "https://example.com/\(remoteID)",
        publishedAt: t0.addingTimeInterval(offset), fetchedAt: t0.addingTimeInterval(offset)
    )
}

/// Two devices on one stand-in iCloud.
private struct Pair {
    let server = InMemorySyncServer()
    let mac: InfluxStore
    let phone: InfluxStore
    private let macSync: SyncCoordinator
    private let phoneSync: SyncCoordinator

    init() throws {
        mac = try InfluxStore.inMemory()
        phone = try InfluxStore.inMemory()
        macSync = SyncCoordinator(store: mac, server: server)
        phoneSync = SyncCoordinator(store: phone, server: server)
    }

    /// Syncs both devices twice each, so everything either had reaches the
    /// other however the merges fall out.
    func settle() async throws {
        for _ in 0..<2 {
            try await macSync.sync()
            try await phoneSync.sync()
        }
    }

    func syncMac() async throws { try await macSync.sync() }
    func syncPhone() async throws { try await phoneSync.sync() }
}

@Suite struct SyncedSources {
    @Test func aFeedAddedOnTheMacArrivesOnThePhone() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss, mastodon])
        try await pair.settle()
        // Sources come back in title order: "Example", then "Mastodon".
        #expect(try await pair.phone.sources().map(\.id) == [rss.id, mastodon.id])
    }

    @Test func nothingIsSentTwice() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss])
        try await pair.settle()
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
        #expect(try await pair.phone.pendingSyncChanges().isEmpty)
        // Saving the same source again is not a change.
        try await pair.mac.save(sources: [rss])
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
    }

    @Test func aDeletedFeedGoesFromBothDevices() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss, mastodon])
        try await pair.settle()
        try await pair.mac.delete(sourceID: rss.id)
        try await pair.settle()
        #expect(try await pair.phone.sources().map(\.id) == [mastodon.id])
        // iCloud keeps a tombstone in its place.
        let sources = pair.server.records().filter { $0.type == .source }
        #expect(sources.count == 2)
        #expect(sources.filter { SyncCoding.decode(SyncTombstone.self, from: $0.payload) != nil }.map(\.key) == [rss.id])
    }

    @Test func anOlderDeletionReachingICloudLaterLosesToANewerChange() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        // Deleted on the Mac while offline, then renamed on the phone.
        try await pair.mac.delete(sourceID: rss.id, at: t0.addingTimeInterval(60))
        var renamed = rss
        renamed.title = "Renamed on the phone"
        try await pair.phone.save(sources: [renamed], at: t0.addingTimeInterval(120))
        try await pair.syncPhone()
        try await pair.settle()
        #expect(try await pair.mac.sources().map(\.title) == ["Renamed on the phone"])
        #expect(try await pair.phone.sources().map(\.title) == ["Renamed on the phone"])
    }

    @Test func aNewerDeletionWinsOverAnOlderChangeReachingICloudLater() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        var renamed = rss
        renamed.title = "Renamed on the phone"
        try await pair.phone.save(sources: [renamed], at: t0.addingTimeInterval(60))
        try await pair.mac.delete(sourceID: rss.id, at: t0.addingTimeInterval(120))
        try await pair.syncMac()
        try await pair.settle()
        #expect(try await pair.mac.sources().isEmpty)
        #expect(try await pair.phone.sources().isEmpty)
    }

    @Test func iCloudKeepsTheLaterOfTwoDeletions() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        try await pair.mac.delete(sourceID: rss.id, at: t0.addingTimeInterval(60))
        try await pair.phone.delete(sourceID: rss.id, at: t0.addingTimeInterval(120))
        try await pair.syncMac()
        try await pair.settle()
        let record = try #require(pair.server.records().first { $0.type == .source })
        #expect(SyncCoding.decode(SyncTombstone.self, from: record.payload)?.deletedAt == t0.addingTimeInterval(120))
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
        #expect(try await pair.phone.pendingSyncChanges().isEmpty)
    }

    @Test func aFeedAddedAgainAfterADeletionComesBack() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        try await pair.mac.delete(sourceID: rss.id, at: t0.addingTimeInterval(60))
        try await pair.settle()
        try await pair.phone.save(sources: [rss], at: t0.addingTimeInterval(120))
        try await pair.settle()
        #expect(try await pair.mac.sources().map(\.id) == [rss.id])
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
        #expect(try await pair.phone.pendingSyncChanges().isEmpty)
    }

    @Test func theLaterRenameWins() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        var onMac = rss
        onMac.title = "Renamed on the Mac"
        try await pair.mac.save(sources: [onMac], at: t0.addingTimeInterval(60))
        var onPhone = rss
        onPhone.title = "Renamed on the phone"
        try await pair.phone.save(sources: [onPhone], at: t0.addingTimeInterval(120))
        try await pair.settle()
        #expect(try await pair.mac.sources().map(\.title) == ["Renamed on the phone"])
        #expect(try await pair.phone.sources().map(\.title) == ["Renamed on the phone"])
    }

    @Test func aLateConfirmationDoesNotClearAChangeMadeAfterTheFetchCameBack() async throws {
        let mac = try InfluxStore.inMemory()
        try await mac.save(sources: [rss], at: t0)
        let name = SyncRecord.name(type: .source, key: rss.id)
        let sent = try #require(try await mac.syncRecordToSend(named: name))
        // The direct fetch brings the saved record back before the save's
        // confirmation arrives, which clears the pending change.
        _ = try await mac.mergeSyncRecords([FetchedSyncRecord(record: sent.record, systemFields: Data("1".utf8))])
        #expect(try await mac.pendingSyncChanges().isEmpty)
        var renamed = rss
        renamed.title = "Renamed"
        try await mac.save(sources: [renamed], at: t0.addingTimeInterval(60))
        try await mac.didSaveSyncRecords([SavedSyncRecord(name: name, version: sent.version, systemFields: Data("1".utf8))])
        #expect(try await mac.pendingSyncChanges().map(\.name) == [name])
    }

    @Test func aChangeMadeDuringASyncIsNotLost() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss])
        let record = try await pair.mac.syncRecordToSend(named: SyncRecord.name(type: .source, key: rss.id))
        var renamed = rss
        renamed.title = "Renamed while in flight"
        try await pair.mac.save(sources: [renamed])
        // The save confirms the version that was in flight, not the rename.
        try await pair.mac.didSaveSyncRecords([SavedSyncRecord(name: record!.record.name, version: record!.version, systemFields: Data("1".utf8))])
        #expect(try await pair.mac.pendingSyncChanges().count == 1)
    }

    @Test func aSourceSyncedBeforeSigningInHasNoCredentials() async throws {
        // Credentials never sync; the account arrives as its
        // sources, and the app shows it as not signed in on this device.
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.settle()
        let arrived = try await pair.phone.sources()
        #expect(arrived.map(\.accountID) == ["@me@example.social"])
        for record in pair.server.records() {
            let json = String(decoding: record.payload, as: UTF8.self)
            #expect(!json.contains("token"))
        }
    }
}

@Suite struct SyncedReadState {
    /// Both devices with the same three posts.
    private func pairWithPosts() async throws -> Pair {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon, rss])
        try await pair.phone.save(sources: [mastodon, rss])
        let items = [post("a", at: 10), post("b", at: 20), post("c", at: 30)]
        try await pair.mac.insert(items)
        try await pair.phone.insert(items)
        try await pair.settle()
        return pair
    }

    @Test func readingOnTheMacMovesThePhonesMarker() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        _ = try await pair.mac.moveLastReadMarker(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey))
        try await pair.settle()
        let marker = try await pair.phone.lastReadMarker(viewID: "all")
        #expect(marker?.mergeKey == "post:b")
    }

    @Test func theFurthestMarkerWins() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        // The phone read further, but wrote its marker first.
        _ = try await pair.phone.moveLastReadMarker(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey), at: t0)
        _ = try await pair.mac.moveLastReadMarker(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey), at: t0.addingTimeInterval(60))
        try await pair.settle()
        #expect(try await pair.mac.lastReadMarker(viewID: "all")?.mergeKey == "post:c")
        #expect(try await pair.phone.lastReadMarker(viewID: "all")?.mergeKey == "post:c")
    }

    @Test func aMarkerNeverMovesBackwards() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        _ = try await pair.mac.moveLastReadMarker(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey))
        try await pair.settle()
        _ = try await pair.phone.moveLastReadMarker(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey))
        try await pair.settle()
        #expect(try await pair.mac.lastReadMarker(viewID: "all")?.mergeKey == "post:c")
        #expect(try await pair.phone.lastReadMarker(viewID: "all")?.mergeKey == "post:c")
    }

    @Test func aMarkerForARowThisDeviceLacksIsPlacedWhenItArrives() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10), post("b", at: 20)])
        let rows = try await pair.mac.rows()
        _ = try await pair.mac.moveLastReadMarker(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey))
        try await pair.settle()
        // The phone has no posts yet, so the marker waits.
        #expect(try await pair.phone.lastReadMarker(viewID: "all") == nil)
        try await pair.phone.insert([post("a", at: 10), post("b", at: 20)])
        #expect(try await pair.phone.lastReadMarker(viewID: "all")?.mergeKey == "post:b")
    }

    @Test func aFurtherMarkerReachesICloudEvenIfTheOtherRowNeverArrives() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10)])
        try await pair.phone.insert([post("c", at: 30)])
        let macRows = try await pair.mac.rows(), phoneRows = try await pair.phone.rows()
        _ = try await pair.mac.moveLastReadMarker(viewID: "all", to: (macRows[0].sortDate, macRows[0].mergeKey))
        _ = try await pair.phone.moveLastReadMarker(viewID: "all", to: (phoneRows[0].sortDate, phoneRows[0].mergeKey))
        try await pair.syncMac()
        try await pair.settle()
        let marker = try #require(pair.server.records().first { $0.type == .lastReadMarker })
        #expect(SyncCoding.decode(LastReadMarkerPayload.self, from: marker.payload)?.mergeKey == "post:c")
        #expect(try await pair.phone.lastReadMarker(viewID: "all")?.mergeKey == "post:c")
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
        #expect(try await pair.phone.pendingSyncChanges().isEmpty)
    }

    /// A marker whose row is further back than this device has fetched
    /// still says how far back to fetch, so the row can arrive.
    @Test func aMarkerWaitingForItsRowSetsHowFarBackToFetch() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10), post("b", at: 20)])
        try await pair.phone.insert([post("b", at: 20)])
        let macRows = try await pair.mac.rows()
        _ = try await pair.mac.moveLastReadMarker(viewID: "all", to: (macRows[0].sortDate, macRows[0].mergeKey))
        try await pair.syncMac()
        try await pair.syncPhone()
        #expect(try await pair.phone.lastReadMarker(viewID: "all") == nil)
        #expect(try await pair.phone.earliestLastReadDate() == macRows[0].sortDate)
    }

    @Test func aMarkerThatArrivedBeforeItsRowStillLosesToAFurtherOne() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10)])
        try await pair.phone.insert([post("b", at: 20), post("c", at: 30)])
        let macRows = try await pair.mac.rows(), phoneRows = try await pair.phone.rows()
        _ = try await pair.mac.moveLastReadMarker(viewID: "all", to: (macRows[0].sortDate, macRows[0].mergeKey))
        _ = try await pair.phone.moveLastReadMarker(viewID: "all", to: (phoneRows[1].sortDate, phoneRows[1].mergeKey))
        // The Mac's marker reaches iCloud first and names a row the phone
        // lacks, so the phone can't compare them yet.
        try await pair.syncMac()
        try await pair.syncPhone()
        // Once it can, its own marker, further along, goes up again.
        try await pair.phone.insert([post("a", at: 10)])
        try await pair.settle()
        let marker = try #require(pair.server.records().first { $0.type == .lastReadMarker })
        #expect(SyncCoding.decode(LastReadMarkerPayload.self, from: marker.payload)?.mergeKey == "post:c")
        #expect(try await pair.phone.lastReadMarker(viewID: "all")?.mergeKey == "post:c")
        try await pair.mac.insert([post("b", at: 20), post("c", at: 30)])
        #expect(try await pair.mac.lastReadMarker(viewID: "all")?.mergeKey == "post:c")
    }

    @Test func anArticleReadOnOneDeviceIsReadOnBoth() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss])
        try await pair.phone.save(sources: [rss])
        try await pair.mac.insert([article("one", at: 10)])
        try await pair.phone.insert([article("one", at: 10)])
        try await pair.mac.setArticle(mergeKey: "https://example.com/one", read: true)
        try await pair.settle()
        #expect(try await pair.phone.rows().map(\.isRead) == [true])
    }

    @Test func theLaterReadChangeWins() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss])
        try await pair.phone.save(sources: [rss])
        try await pair.mac.insert([article("one", at: 10)])
        try await pair.phone.insert([article("one", at: 10)])
        let key = "https://example.com/one"
        try await pair.mac.setArticle(mergeKey: key, read: true, at: t0.addingTimeInterval(60))
        try await pair.phone.setArticle(mergeKey: key, read: false, at: t0)
        try await pair.settle()
        #expect(try await pair.mac.rows().map(\.isRead) == [true])
        #expect(try await pair.phone.rows().map(\.isRead) == [true])
    }
}

/// Article bookmarks, which no service keeps.
@Suite struct SyncedArticleBookmarks {
    private let key = "https://example.com/one"

    private func pairWithArticle() async throws -> Pair {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss])
        try await pair.phone.save(sources: [rss])
        try await pair.mac.insert([article("one", at: 10)])
        try await pair.phone.insert([article("one", at: 10)])
        return pair
    }

    @Test func anArticleBookmarkedOnOneDeviceIsInBookmarksOnBoth() async throws {
        let pair = try await pairWithArticle()
        try await pair.mac.toggleOwnBookmark(mergeKey: key)
        try await pair.settle()
        #expect(try await pair.phone.rows(inView: SavedView.bookmarksID).map(\.mergeKey) == [key])

        try await pair.phone.toggleOwnBookmark(mergeKey: key)
        try await pair.settle()
        #expect(try await pair.mac.rows(inView: SavedView.bookmarksID).isEmpty)
        #expect(try await pair.mac.rows().map { $0.viewer?.bookmarked } == [false])
    }

    @Test func theLaterBookmarkChangeWins() async throws {
        let pair = try await pairWithArticle()
        try await pair.mac.setArticle(mergeKey: key, bookmarked: false, at: t0.addingTimeInterval(60))
        try await pair.phone.setArticle(mergeKey: key, bookmarked: true, at: t0)
        try await pair.settle()
        #expect(try await pair.mac.rows(inView: SavedView.bookmarksID).isEmpty)
        #expect(try await pair.phone.rows(inView: SavedView.bookmarksID).isEmpty)
    }

    @Test func aBookmarkForAnArticleNotFetchedYetShowsWhenItArrives() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss])
        try await pair.phone.save(sources: [rss])
        try await pair.mac.insert([article("one", at: 10)])
        try await pair.mac.toggleOwnBookmark(mergeKey: key)
        try await pair.settle()
        try await pair.phone.insert([article("one", at: 10)])
        #expect(try await pair.phone.rows(inView: SavedView.bookmarksID).map(\.mergeKey) == [key])
    }
}

/// Where the reader is, which moves both ways, unlike the marker.
@Suite struct SyncedReadingPlaces {
    private func pairWithPosts() async throws -> Pair {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        let items = [post("a", at: 10), post("b", at: 20), post("c", at: 30)]
        try await pair.mac.insert(items)
        try await pair.phone.insert(items)
        try await pair.settle()
        return pair
    }

    @Test func goingBackUpOnTheMacTakesThePhoneThere() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey), at: t0)
        try await pair.settle()
        #expect(try await pair.phone.readingPlace(viewID: "all")?.mergeKey == "post:c")
        // Back up to an older post, from the place itself: the place
        // follows, the marker doesn't.
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey), at: t0.addingTimeInterval(60))
        try await pair.settle()
        #expect(try await pair.phone.readingPlace(viewID: "all")?.mergeKey == "post:a")
        #expect(try await pair.mac.readingPlace(viewID: "all")?.mergeKey == "post:a")
        #expect(try await pair.phone.readingPlace(viewID: "all")?.move == 2)
    }

    /// Two moves made without either device knowing of the other's: the
    /// one further along stands, whichever was made or sent last.
    @Test(arguments: [true, false])
    func ofTwoMovesUnknownToEachOtherTheOneFurtherAlongStands(macFirst: Bool) async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey), at: t0)
        try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey), at: t0.addingTimeInterval(30))
        if macFirst {
            try await pair.syncMac()
            try await pair.syncPhone()
        } else {
            try await pair.syncPhone()
            try await pair.syncMac()
        }
        try await pair.settle()
        #expect(try await pair.mac.readingPlace(viewID: "all")?.mergeKey == "post:c")
        #expect(try await pair.phone.readingPlace(viewID: "all")?.mergeKey == "post:c")
    }

    /// A move the reader made without having seen the place it would
    /// replace stands only if it goes further along (ADR 0028).
    @Test func aMoveFromAScreenThatHadNotSeenThePlaceStaysOnItsDevice() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        let first = try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey))
        guard case .moved(let b) = first else {
            Issue.record("the first move should stand")
            return
        }
        #expect(b.move == 1)
        try await pair.settle()

        // The phone's screen had not shown it. Back from it: stays local.
        let back = try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey), knowing: .seen(nil))
        #expect(back == .stayedLocal(current: try #require(try await pair.phone.readingPlace(viewID: "all"))))
        #expect(try await pair.phone.pendingSyncChanges().isEmpty)
        // On from it: stands, as the next move.
        let on = try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey), knowing: .seen(nil))
        #expect(on.changed)
        // And back, having seen the place it replaces: stands too.
        let seen = try #require(try await pair.phone.readingPlace(viewID: "all")).identity
        #expect(seen == ReadingPlace.Identity(move: 2, mergeKey: "post:c"))
        let chosen = try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey), knowing: .seen(seen))
        #expect(chosen.changed)
        try await pair.settle()
        #expect(try await pair.mac.readingPlace(viewID: "all")?.identity == ReadingPlace.Identity(move: 3, mergeKey: "post:a"))
    }

    /// A move made here that iCloud hasn't had goes back on purpose from a
    /// place both devices had. That place arriving again, as records do
    /// when they are fetched twice, is not news and doesn't undo it.
    @Test func thePlaceAMoveWasMadeFromDoesNotUndoItByArrivingAgain() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey))
        try await pair.settle()
        let shared = try #require(try await pair.phone.readingPlace(viewID: "all"))
        try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey), knowing: .seen(shared.identity))

        let again = ReadingPlacePayload(viewID: "all", mergeKey: shared.mergeKey, sortDate: shared.sortDate, updatedAt: shared.updatedAt,
                                        move: shared.move, device: shared.device)
        let result = try await pair.phone.mergeSyncRecords([FetchedSyncRecord(
            record: SyncRecord(type: .readingPlace, key: "all", payload: try SyncCoding.encode(again, for: .readingPlace)), systemFields: Data()
        )])
        #expect(result.toSend.count == 1)
        #expect(try await pair.phone.readingPlace(viewID: "all")?.mergeKey == "post:a")
        try await pair.settle()
        #expect(try await pair.mac.readingPlace(viewID: "all")?.mergeKey == "post:a")
    }

    /// The same for this device's own earlier move coming back while a
    /// later one waits to go up.
    @Test func aDevicesOwnEarlierMoveComingBackDoesNotUndoItsLaterOne() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.phone.rows()
        try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey))
        let earlier = try #require(try await pair.phone.readingPlace(viewID: "all"))
        #expect(earlier.device != nil)
        try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey))

        let echo = ReadingPlacePayload(viewID: "all", mergeKey: earlier.mergeKey, sortDate: earlier.sortDate, updatedAt: earlier.updatedAt,
                                       move: earlier.move, device: earlier.device)
        _ = try await pair.phone.mergeSyncRecords([FetchedSyncRecord(
            record: SyncRecord(type: .readingPlace, key: "all", payload: try SyncCoding.encode(echo, for: .readingPlace)), systemFields: Data()
        )])
        #expect(try await pair.phone.readingPlace(viewID: "all")?.mergeKey == "post:a")
    }

    /// A place that waits only to be sent again, because an older one
    /// arrived late, is not a move the reader made here. A move made
    /// elsewhere from that place stands over it, back or forward.
    @Test func aPlaceWaitingOnlyToBeSentAgainGivesWayToAMoveBackMadeElsewhere() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey))
        try await pair.settle()
        let earlier = try #require(try await pair.phone.readingPlace(viewID: "all"))
        try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey))
        try await pair.settle()
        let shared = try #require(try await pair.mac.readingPlace(viewID: "all"))
        #expect(shared.identity == ReadingPlace.Identity(move: 2, mergeKey: "post:c"))

        // The earlier place arrives at the Mac again: the Mac's stays, and
        // waits to go up again.
        func arriving(_ place: ReadingPlace) throws -> FetchedSyncRecord {
            let payload = ReadingPlacePayload(viewID: "all", mergeKey: place.mergeKey, sortDate: place.sortDate, updatedAt: place.updatedAt,
                                              move: place.move, device: "another")
            return FetchedSyncRecord(record: SyncRecord(type: .readingPlace, key: "all", payload: try SyncCoding.encode(payload, for: .readingPlace)), systemFields: Data())
        }
        #expect(try await pair.mac.mergeSyncRecords([try arriving(earlier)]).toSend.count == 1)
        #expect(try await pair.mac.readingPlace(viewID: "all")?.identity == shared.identity)

        // Before it has gone, the reader goes back on the phone, from the
        // place both devices have. Nobody moved on the Mac.
        try await pair.phone.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey), knowing: .seen(shared.identity))
        let back = try #require(try await pair.phone.readingPlace(viewID: "all"))
        _ = try await pair.mac.mergeSyncRecords([try arriving(back)])
        #expect(try await pair.mac.readingPlace(viewID: "all")?.identity == ReadingPlace.Identity(move: 3, mergeKey: "post:a"))
        try await pair.settle()
        #expect(try await pair.mac.readingPlace(viewID: "all")?.identity == ReadingPlace.Identity(move: 3, mergeKey: "post:a"))
        #expect(try await pair.phone.readingPlace(viewID: "all")?.identity == ReadingPlace.Identity(move: 3, mergeKey: "post:a"))
    }

    /// A store from before moves were counted has no record of the place
    /// iCloud had. Its place, if nothing waited to go up, is that place.
    @Test func aPlaceAlreadyInICloudBeforeMovesWereCountedIsTheSharedOne() throws {
        let db = try DatabaseQueue()
        try Schema.migrator.migrate(db, upTo: "v20: sync journal")
        try db.write { db in
            for (view, pending) in [("sent", nil), ("waiting", 7)] as [(String, Int?)] {
                try db.execute(sql: """
                    INSERT INTO readingPlace (viewID, mergeKey, sortDate, updatedAt) VALUES (?, 'post:b', '2026-10-24 00:00:00.000', '2026-10-24 00:00:00.000')
                    """, arguments: [view])
                try db.execute(sql: """
                    INSERT INTO syncRecord (recordName, type, key, modifiedAt, pending) VALUES (?, 'ReadingPlace', ?, '2026-10-24 00:00:00.000', ?)
                    """, arguments: [SyncRecord.name(type: .readingPlace, key: view), view, pending])
            }
            // Sync never ran for this one.
            try db.execute(sql: """
                INSERT INTO readingPlace (viewID, mergeKey, sortDate, updatedAt) VALUES ('local', 'post:b', '2026-10-24 00:00:00.000', '2026-10-24 00:00:00.000')
                """)
        }
        try Schema.migrator.migrate(db)
        let bases = try db.read { try ReadingPlaceBase.fetchAll($0) }
        #expect(bases.map(\.viewID) == ["sent"])
        #expect(bases.first?.place.identity == ReadingPlace.Identity(move: 0, mergeKey: "post:b"))
    }

    @Test func aPlaceFromAnotherDeviceIsNotSentBack() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey))
        try await pair.settle()
        #expect(try await pair.phone.pendingSyncChanges().isEmpty)
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
    }

    @Test func stayingOnTheSameRowChangesNothing() async throws {
        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        #expect(try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey)).changed)
        try await pair.settle()
        #expect(try await !pair.mac.moveReadingPlace(viewID: "all", to: (rows[1].sortDate, rows[1].mergeKey)).changed)
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
    }

    @Test func aPlaceWhoseRowIsMissingOpensAtItsDate() async throws {
        let pair = try await pairWithPosts()
        try await pair.mac.insert([post("b2", at: 25)])
        let macRows = try await pair.mac.rows()
        let b2 = try #require(macRows.first { $0.mergeKey == "post:b2" })
        try await pair.mac.moveReadingPlace(viewID: "all", to: (b2.sortDate, b2.mergeKey))
        try await pair.settle()
        let place = try #require(try await pair.phone.readingPlace(viewID: "all"))
        let phoneRows = try await pair.phone.rows()
        // The phone has no b2, so the first row after its date stands in.
        #expect(ReadingPosition.row(at: place, in: phoneRows).map { phoneRows[$0].mergeKey } == "post:c")
    }

    /// A place sent by a version from before moves were counted still
    /// reads, as move 0, and any counted move stands over it.
    @Test func anOlderPlaceRecordIsMoveZero() async throws {
        let old = #"{"mergeKey":"post:b","sortDate":0,"updatedAt":0,"viewID":"all","newestMergeKey":"post:c"}"#
        let payload = try #require(SyncCoding.decode(ReadingPlacePayload.self, from: Data(old.utf8)))
        #expect(payload.mergeKey == "post:b")
        #expect(payload.move == nil)

        let pair = try await pairWithPosts()
        let rows = try await pair.mac.rows()
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey))
        try await pair.settle()
        let late = ReadingPlacePayload(viewID: "all", mergeKey: "post:c", sortDate: rows[2].sortDate, updatedAt: Date().addingTimeInterval(3600))
        _ = try await pair.mac.mergeSyncRecords([FetchedSyncRecord(
            record: SyncRecord(type: .readingPlace, key: "all", payload: try SyncCoding.encode(late, for: .readingPlace)), systemFields: Data()
        )])
        #expect(try await pair.mac.readingPlace(viewID: "all")?.mergeKey == "post:a")
    }
}

@Suite struct SyncedTimelinePositions {
    /// Two devices first saw a post differently: the Mac saw the boost first and places
    /// the row at the boost's date; the phone saw the original, days
    /// earlier. Sync settles on one position, so both devices order the
    /// timeline the same way.
    @Test func devicesAgreeWhereABoostedPostSits() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        // The Mac's copy is a boost dated later than the post itself.
        try await pair.mac.insert([Item(
            sourceID: mastodon.id, remoteID: "boost", kind: .post, mergeKey: "post:original",
            authorName: "Ana Ruiz", authorHandle: "@ana", body: "Original",
            publishedAt: t0, fetchedAt: t0.addingTimeInterval(3_000), sortDate: t0.addingTimeInterval(3_000),
            boostedBy: "Ben"
        )])
        try await pair.mac.insert([post("later", at: 3_600)])
        try await pair.settle()
        // The phone then fetches the original itself.
        try await pair.phone.insert([Item(
            sourceID: mastodon.id, remoteID: "original", kind: .post, mergeKey: "post:original",
            authorName: "Ana Ruiz", authorHandle: "@ana", body: "Original",
            publishedAt: t0, fetchedAt: t0.addingTimeInterval(4_000)
        )])
        try await pair.phone.insert([post("later", at: 3_600)])
        try await pair.settle()
        let macRows = try await pair.mac.rows()
        let phoneRows = try await pair.phone.rows()
        #expect(macRows.map(\.mergeKey) == phoneRows.map(\.mergeKey))
        #expect(macRows.map(\.sortDate) == phoneRows.map(\.sortDate))
        // The Mac stored it first, at the boost's date, so that is where
        // the row sits on both: before the post that followed the boost.
        #expect(phoneRows.map(\.mergeKey) == ["post:original", "post:later"])
    }

    @Test func aPositionFromICloudIsUsedWhenTheRowArrivesLater() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10, fetchedAt: 600, sortDate: 500, boostedBy: "Ben")])
        try await pair.settle()
        // The phone fetched the post itself, which places it earlier;
        // iCloud's position wins.
        try await pair.phone.insert([post("a", at: 10, fetchedAt: 900)])
        let phoneDates = try await pair.phone.rows().map(\.sortDate)
        let macDates = try await pair.mac.rows().map(\.sortDate)
        #expect(phoneDates == macDates)
    }

    @Test func aLaterPlacedPositionArrivingSecondDoesNotReplaceOneWaitingForItsRow() async throws {
        let phone = try InfluxStore.inMemory()
        try await phone.save(sources: [mastodon])
        func position(_ sortDate: TimeInterval, placedAt: TimeInterval, tag: String) throws -> FetchedSyncRecord {
            let payload = try SyncCoding.encode(TimelinePositionPayload(
                mergeKey: "post:a", sortDate: t0.addingTimeInterval(sortDate), placedAt: t0.addingTimeInterval(placedAt)
            ), for: .timelinePosition)
            return FetchedSyncRecord(record: SyncRecord(type: .timelinePosition, key: "post:a", payload: payload), systemFields: Data(tag.utf8))
        }
        // The winning claim, then an older version of the record placed later.
        _ = try await phone.mergeSyncRecords([position(500, placedAt: 600, tag: "2")])
        _ = try await phone.mergeSyncRecords([position(800, placedAt: 900, tag: "1")])
        try await phone.insert([post("a", at: 10, fetchedAt: 1_000)])
        #expect(try await phone.rows().map(\.sortDate) == [t0.addingTimeInterval(500)])
    }

    @Test func markersStayOnTheSameRowWhenAPositionMoves() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10, fetchedAt: 600, sortDate: 500, boostedBy: "Ben")])
        try await pair.settle()
        try await pair.phone.insert([post("a", at: 10, fetchedAt: 900)])
        let row = try await pair.phone.rows()[0]
        _ = try await pair.phone.moveLastReadMarker(viewID: "all", to: (row.sortDate, row.mergeKey))
        try await pair.settle()
        let marker = try await pair.phone.lastReadMarker(viewID: "all")
        #expect(marker?.sortDate == row.sortDate)
        #expect(try await pair.mac.lastReadMarker(viewID: "all")?.mergeKey == "post:a")
    }

    /// A post dated in the future is placed at each device's fetch time.
    /// The Mac stored it first but was offline; the phone, which fetched it
    /// later, reached iCloud first. The Mac's earlier position still wins,
    /// so the row doesn't move on the device that saw it first.
    @Test func theEarliestStoredPositionWinsEvenWhenItReachesICloudLater() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 3_600, fetchedAt: 600)])
        try await pair.phone.insert([post("a", at: 3_600, fetchedAt: 900)])
        try await pair.syncPhone()
        try await pair.settle()
        #expect(try await pair.mac.rows().map(\.sortDate) == [t0.addingTimeInterval(600)])
        #expect(try await pair.phone.rows().map(\.sortDate) == [t0.addingTimeInterval(600)])
    }

    @Test func aResetOffersPositionsAgain() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 3_600, fetchedAt: 600)])
        try await pair.settle()
        try await pair.mac.resetSync(uploadingEverything: true)
        let pending = try await pair.mac.pendingSyncChanges()
        #expect(pending.contains { $0.type == .timelinePosition })
    }

    @Test func ordinaryPostsCostNoPositionRecords() async throws {
        // A post placed by its own publish date is in the same place on
        // every device, so there is nothing to agree.
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10), post("b", at: 20)])
        try await pair.settle()
        #expect(pair.server.records().filter { $0.type == .timelinePosition }.isEmpty)
    }

    /// An article published before the newest row here and fetched after it.
    private func lateArticle(fetchedAt: TimeInterval) -> Item {
        Item(
            sourceID: rss.id, remoteID: "late", kind: .article, mergeKey: "https://example.com/late",
            authorName: "Example", authorHandle: "example.com", title: "Late", body: "Summary",
            url: "https://example.com/late",
            publishedAt: t0.addingTimeInterval(300), fetchedAt: t0.addingTimeInterval(fetchedAt)
        )
    }

    /// The reader of `store` has read down to the post `id`.
    private func read(_ store: InfluxStore, to id: String, at offset: TimeInterval) async throws {
        #expect(try await store.moveLastReadMarker(viewID: SavedView.allID, to: (t0.addingTimeInterval(offset), "post:\(id)")))
    }

    /// A row that arrives late, dated above what the reader has read, goes
    /// directly below it (ADR 0041), and that is the position its device
    /// gives iCloud. The device used to say the row sat at its own date
    /// instead, so the first time the record came back the row went to
    /// wherever its date put it, hours above the reader, and a reader with
    /// that row at the top of their screen went back with it
    /// (influx-dev #125).
    @Test func aRowPlacedBelowTheLineStaysThereWhenItsOwnPositionComesBack() async throws {
        let pair = try Pair()
        try await pair.phone.save(sources: [rss, mastodon])
        try await pair.phone.insert([post("a", at: 0), post("b", at: 600)])
        try await read(pair.phone, to: "b", at: 600)
        try await pair.phone.insert([lateArticle(fetchedAt: 900)], belowTheLine: true)
        let placed = try await pair.phone.rows()
        #expect(placed.map(\.mergeKey) == ["post:a", "post:b", "https://example.com/late"])

        try await pair.syncPhone()
        // A fetch that asks iCloud for everything since some earlier point
        // hands a device its own saves back, as the app's direct fetch does.
        let own = pair.server.records().filter { $0.type == .timelinePosition }
        #expect(own.map(\.key) == ["https://example.com/late"])
        _ = try await pair.phone.mergeSyncRecords(own.map { FetchedSyncRecord(record: $0, systemFields: Data("9".utf8)) })

        let after = try await pair.phone.rows()
        #expect(after.map(\.mergeKey) == placed.map(\.mergeKey))
        #expect(after.map(\.sortDate) == placed.map(\.sortDate))
    }

    /// Two devices each fetched the same late article and put it below
    /// what their own reader had read, the Mac after a post the phone
    /// didn't have yet. They settle on where the device that stored it
    /// first put it, which is still below the rows it arrived after there,
    /// not back at the article's own date.
    @Test func devicesAgreeOnThePlaceOfALateArticle() async throws {
        let pair = try Pair()
        for store in [pair.mac, pair.phone] {
            try await store.save(sources: [rss, mastodon])
            try await store.insert([post("a", at: 0), post("b", at: 600)])
        }
        try await read(pair.phone, to: "b", at: 600)
        try await pair.phone.insert([lateArticle(fetchedAt: 900)], belowTheLine: true)
        let placed = try await pair.phone.rows()
        try await pair.mac.insert([post("c", at: 1_000)])
        try await read(pair.mac, to: "c", at: 1_000)
        try await pair.mac.insert([lateArticle(fetchedAt: 1_200)], belowTheLine: true)
        #expect(try await pair.mac.rows().map(\.mergeKey) == ["post:a", "post:b", "post:c", "https://example.com/late"])
        try await pair.settle()
        try await pair.phone.insert([post("c", at: 1_000)])

        let macRows = try await pair.mac.rows()
        let phoneRows = try await pair.phone.rows()
        #expect(phoneRows.map(\.mergeKey) == ["post:a", "post:b", "https://example.com/late", "post:c"])
        #expect(phoneRows.prefix(3).map(\.sortDate) == placed.map(\.sortDate))
        #expect(macRows.map(\.mergeKey) == phoneRows.map(\.mergeKey))
        #expect(macRows.map(\.sortDate) == phoneRows.map(\.sortDate))
    }

    /// One device's reader hadn't reached a late article's time, so it
    /// went by its own time there; the other's had read past it, so it
    /// went below what they had read. They settle as devices always have:
    /// on the place of the device that stored the article first.
    @Test(arguments: [true, false])
    func theDeviceThatStoredALateArticleFirstSettlesItsPlace(phoneFirst: Bool) async throws {
        let pair = try Pair()
        for store in [pair.mac, pair.phone] {
            try await store.save(sources: [rss, mastodon])
            try await store.insert([post("a", at: 0), post("b", at: 600)])
        }
        try await read(pair.mac, to: "b", at: 600)
        try await pair.phone.insert([lateArticle(fetchedAt: phoneFirst ? 900 : 1_200)], belowTheLine: true)
        try await pair.mac.insert([lateArticle(fetchedAt: phoneFirst ? 1_200 : 900)], belowTheLine: true)
        #expect(try await pair.phone.rows().map(\.mergeKey) == ["post:a", "https://example.com/late", "post:b"])
        #expect(try await pair.mac.rows().map(\.mergeKey) == ["post:a", "post:b", "https://example.com/late"])
        try await pair.settle()

        let expected = phoneFirst ? ["post:a", "https://example.com/late", "post:b"] : ["post:a", "post:b", "https://example.com/late"]
        let macRows = try await pair.mac.rows()
        let phoneRows = try await pair.phone.rows()
        #expect(macRows.map(\.mergeKey) == expected)
        #expect(phoneRows.map(\.mergeKey) == expected)
        #expect(macRows.map(\.sortDate) == phoneRows.map(\.sortDate))
    }

    /// Starting sync over offers a late row's position again: it sits
    /// below what the reader had read, not where its own date would put it
    /// on another device.
    @Test func aResetOffersThePlaceOfALateArticleAgain() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss, mastodon])
        try await pair.mac.insert([post("a", at: 0), post("b", at: 600)])
        try await read(pair.mac, to: "b", at: 600)
        try await pair.mac.insert([lateArticle(fetchedAt: 900)], belowTheLine: true)
        try await pair.settle()
        try await pair.mac.resetSync(uploadingEverything: true)
        let pending = try await pair.mac.pendingSyncChanges()
        #expect(pending.filter { $0.type == .timelinePosition }.map(\.name)
            == [SyncRecord.name(type: .timelinePosition, key: "https://example.com/late")])
    }
}

@Suite struct SyncedSettings {
    @Test func aSettingChangedOnOneDeviceArrivesOnTheOther() async throws {
        let pair = try Pair()
        try await pair.mac.setSetting("textSize", to: Data("large".utf8))
        try await pair.settle()
        #expect(try await pair.phone.setting("textSize") == Data("large".utf8))
    }

    @Test func clearingASettingSyncs() async throws {
        let pair = try Pair()
        try await pair.mac.setSetting("textSize", to: Data("large".utf8))
        try await pair.settle()
        try await pair.mac.setSetting("textSize", to: nil)
        try await pair.settle()
        #expect(try await pair.phone.setting("textSize") == nil)
    }
}

@Suite struct SyncMechanics {
    @Test func aConflictingSaveTakesTheServersCopyAndResends() async throws {
        let pair = try Pair()
        // Both devices save the same source without seeing each other.
        try await pair.mac.save(sources: [rss], at: t0)
        var onPhone = rss
        onPhone.title = "The phone's name"
        try await pair.phone.save(sources: [onPhone], at: t0.addingTimeInterval(60))
        try await pair.syncMac()
        try await pair.syncPhone()
        try await pair.settle()
        #expect(try await pair.mac.sources().map(\.title) == ["The phone's name"])
        #expect(try await pair.phone.sources().map(\.title) == ["The phone's name"])
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
        #expect(try await pair.phone.pendingSyncChanges().isEmpty)
    }

    @Test func aResetUploadsEverythingAgain() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss, mastodon])
        try await pair.settle()
        pair.server.reset()
        try await pair.syncMac()
        try await pair.settle()
        #expect(pair.server.records().filter { $0.type == .source }.count == 2)
        #expect(try await pair.phone.sources().count == 2)
    }

    @Test func aRecordTheServerForgotIsSentAgain() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss])
        try await pair.settle()
        // The server loses the row, and the device never hears that it did:
        // its next save of the record is rejected as unknown, and the record
        // has to go up again as new.
        pair.server.reset()
        _ = try await pair.server.fetchChanges(since: nil)
        var renamed = rss
        renamed.title = "Renamed"
        try await pair.mac.save(sources: [renamed])
        try await pair.syncMac()
        try await pair.syncMac()
        #expect(pair.server.records().filter { $0.type == .source }.count == 1)
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
    }

    @Test func theBlockingBatchHoldsWhatTheAsyncCallsSend() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss, mastodon])
        let batch = try store.blocking.pendingBatch(limit: 10)
        #expect(batch.map(\.change) == (try await store.pendingSyncChanges()))
        for (change, record) in batch {
            #expect(record == (try await store.syncRecordToSend(named: change.name)))
        }
        #expect(try store.blocking.pendingBatch(limit: 1).count == 1)
    }

    // The CloudKit framework calls the store from Swift concurrency's pool
    // and waits there. More callers than the pool has threads must all
    // finish, which waiting on a task from each of them never did.
    @Test(.timeLimit(.minutes(1)))
    func blockingCallsFinishWithEveryPoolThreadWaiting() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss, mastodon])
        let callers = ProcessInfo.processInfo.activeProcessorCount * 4
        let finished = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<callers {
                group.addTask {
                    let batch = try store.blocking.pendingBatch(limit: 400)
                    _ = try store.blocking.mergeSyncRecords([])
                    return batch.count
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }
        #expect(finished == Array(repeating: 2, count: callers))
    }

    @Test func recordNamesAreTheSameOnEveryDeviceAndFitCloudKit() async throws {
        let long = String(repeating: "x", count: 2_000)
        let name = SyncRecord.name(type: .articleReadState, key: "https://example.com/\(long)")
        #expect(name == SyncRecord.name(type: .articleReadState, key: "https://example.com/\(long)"))
        #expect(name.count <= 255)
        #expect(name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." })
    }

    @Test func recordNamesAreTheDigestTheyClaim() {
        // Known-answer tests for the hash the names rest on.
        #expect(RecordNameHash.hex("".utf8) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(RecordNameHash.hex("abc".utf8) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(RecordNameHash.hex(String(repeating: "a", count: 1_000).utf8)
            == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test func markersDoNotBounceBetweenDevicesThatOrderRowsDifferently() async throws {
        // Two devices that placed the same rows in opposite orders, before
        // positions were agreed: each thinks its own marker is ahead.
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10, fetchedAt: 10), post("b", at: 20, fetchedAt: 20)])
        try await pair.phone.insert([post("b", at: 20, fetchedAt: 5), post("a", at: 10, fetchedAt: 10)])
        let macRows = try await pair.mac.rows()
        let phoneRows = try await pair.phone.rows()
        _ = try await pair.mac.moveLastReadMarker(viewID: "all", to: (macRows[1].sortDate, macRows[1].mergeKey))
        _ = try await pair.phone.moveLastReadMarker(viewID: "all", to: (phoneRows[1].sortDate, phoneRows[1].mergeKey))
        try await pair.settle()
        try await pair.settle()
        // Both ended up with one marker, and neither has anything left to send.
        #expect(try await pair.mac.pendingSyncChanges().isEmpty)
        #expect(try await pair.phone.pendingSyncChanges().isEmpty)
        let macMarker = try await pair.mac.lastReadMarker(viewID: "all")?.mergeKey
        let phoneMarker = try await pair.phone.lastReadMarker(viewID: "all")?.mergeKey
        #expect(macMarker != nil)
        #expect(macMarker == phoneMarker)
    }

    @Test func prunedPositionsGoFromICloudToo() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10, fetchedAt: 600, sortDate: 500, boostedBy: "Ben")])
        try await pair.settle()
        #expect(pair.server.records().filter { $0.type == .timelinePosition }.count == 1)
        _ = try await pair.mac.prune(now: t0.addingTimeInterval(40 * 24 * 60 * 60))
        try await pair.settle()
        #expect(pair.server.records().filter { $0.type == .timelinePosition }.isEmpty)
    }
}

@Suite struct SyncedViewsAndFilters {
    @Test func aViewMadeOnTheMacArrivesOnThePhone() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss, mastodon])
        try await pair.mac.save(view: SavedView(id: "news", name: "News", sourceIDs: [rss.id], sortIndex: 0))
        try await pair.settle()
        #expect(try await pair.phone.savedViews().map(\.name) == ["News"])
    }

    @Test func theLaterViewEditWins() async throws {
        let pair = try Pair()
        try await pair.mac.save(view: SavedView(id: "news", name: "News", sourceIDs: [], sortIndex: 0))
        try await pair.settle()
        try await pair.mac.updateView(id: "news", at: Date().addingTimeInterval(60)) { $0.name = "Mac's name" }
        try await pair.phone.updateView(id: "news", at: Date().addingTimeInterval(120)) { $0.name = "Phone's name" }
        try await pair.settle()
        #expect(try await pair.mac.savedViews().map(\.name) == ["Phone's name"])
        #expect(try await pair.phone.savedViews().map(\.name) == ["Phone's name"])
    }

    @Test func deletingAViewDeletesItsFiltersAndMarkerEverywhere() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.mac.insert([post("a", at: 10)])
        try await pair.phone.insert([post("a", at: 10)])
        try await pair.mac.save(view: SavedView(id: "social", name: "Social", sourceIDs: [mastodon.id], sortIndex: 0))
        try await pair.mac.save(filter: ContentFilter(id: "f", pattern: "spoiler", match: .keyword, viewID: "social"))
        let row = try await pair.mac.rows()[0]
        _ = try await pair.mac.moveLastReadMarker(viewID: "social", to: (row.sortDate, row.mergeKey))
        try await pair.mac.moveReadingPlace(viewID: "social", to: (row.sortDate, row.mergeKey))
        try await pair.settle()
        #expect(try await pair.phone.readingPlace(viewID: "social") != nil)
        #expect(try await pair.phone.filters().map(\.id) == ["f"])
        #expect(try await pair.phone.lastReadMarker(viewID: "social") != nil)

        try await pair.mac.deleteView(id: "social")
        try await pair.settle()
        #expect(try await pair.phone.savedViews().isEmpty)
        #expect(try await pair.phone.filters().isEmpty)
        #expect(try await pair.phone.lastReadMarker(viewID: "social") == nil)
        #expect(try await pair.phone.readingPlace(viewID: "social") == nil)
        // Only the source is left, besides the view's and filter's tombstones.
        let left = pair.server.records().filter { SyncCoding.decode(SyncTombstone.self, from: $0.payload) == nil }
        #expect(left.map(\.type) == [.source])
        #expect(pair.server.records().filter { $0.type == .lastReadMarker }.isEmpty)
        #expect(pair.server.records().filter { $0.type == .readingPlace }.isEmpty)
    }

    @Test func aFilterAddedOnOneDeviceHidesPostsOnTheOther() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        try await pair.phone.insert([post("a", at: 10), post("b", at: 20)])
        try await pair.mac.save(filter: ContentFilter(id: "f", pattern: "Post a", match: .keyword))
        try await pair.settle()
        #expect(try await pair.phone.rows(inView: SavedView.allID).map(\.mergeKey) == ["post:b"])
    }
}

/// Sync starts over when iCloud loses the zone, the account changes, or the
/// engine has no saved state. Everything here goes up again, each thing
/// with when it last changed, so an old copy never beats a newer one.
@Suite struct SyncStartingOver {
    private func renamed(_ title: String) -> Source {
        var source = rss
        source.title = title
        return source
    }

    @Test func everythingIsQueuedWithWhenItLastChanged() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [rss], at: t0)
        try await store.resetSync(uploadingEverything: true, at: t0.addingTimeInterval(1_000))
        let change = try #require(try await store.pendingSyncChanges().first { $0.type == .source })
        let record = try #require(try await store.syncRecordToSend(named: change.name))
        #expect(record.systemFields == nil)
        #expect(SyncCoding.decode(SourcePayload.self, from: record.record.payload)?.modifiedAt == t0)
        #expect(try await store.syncJournal().last?.message.contains("each with when it last changed") == true)
    }

    @Test func aCopyThatMissedAChangeDoesNotBeatIt() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        try await pair.mac.save(sources: [renamed("Renamed")], at: t0.addingTimeInterval(100))
        try await pair.syncMac()
        // The phone hasn't heard of the new name when it starts over.
        try await pair.phone.resetSync(uploadingEverything: true, at: t0.addingTimeInterval(1_000))
        try await pair.settle()
        #expect(try await pair.phone.sources().map(\.title) == ["Renamed"])
        #expect(try await pair.mac.sources().map(\.title) == ["Renamed"])
    }

    @Test func aChangeMadeHereSinceStillWins() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        try await pair.mac.save(sources: [renamed("Mac")], at: t0.addingTimeInterval(100))
        try await pair.syncMac()
        try await pair.phone.save(sources: [renamed("Phone")], at: t0.addingTimeInterval(200))
        try await pair.phone.resetSync(uploadingEverything: true, at: t0.addingTimeInterval(1_000))
        try await pair.settle()
        #expect(try await pair.phone.sources().map(\.title) == ["Phone"])
        #expect(try await pair.mac.sources().map(\.title) == ["Phone"])
    }

    @Test func aSourceDeletedElsewhereDoesNotComeBack() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        try await pair.mac.delete(sourceID: rss.id, at: t0.addingTimeInterval(100))
        try await pair.syncMac()
        try await pair.phone.resetSync(uploadingEverything: true, at: t0.addingTimeInterval(1_000))
        try await pair.settle()
        #expect(try await pair.phone.sources().isEmpty)
        #expect(try await pair.mac.sources().isEmpty)
    }

    /// iCloud lost everything, the deletion with it. The device that
    /// deleted the source sends the deletion again, so the other device's
    /// copy doesn't bring the source back.
    @Test func aDeletionGoesUpAgainWhenICloudLostIt() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [rss], at: t0)
        try await pair.settle()
        try await pair.mac.delete(sourceID: rss.id, at: t0.addingTimeInterval(100))
        try await pair.syncMac()
        pair.server.reset()
        // The phone hears that iCloud started over and sends its copy.
        try await pair.syncPhone()
        #expect(pair.server.records().map(\.type) == [.source])
        try await pair.mac.resetSync(uploadingEverything: true, at: t0.addingTimeInterval(1_000))
        try await pair.settle()
        #expect(try await pair.mac.sources().isEmpty)
        #expect(try await pair.phone.sources().isEmpty)
    }

    /// A device that doesn't know when a thing last changed doesn't claim
    /// it changed now.
    @Test func aThingOfUnknownAgeLosesToICloudsCopy() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [renamed("Mac")], at: t0)
        try await pair.syncMac()
        try await pair.phone.save(sources: [renamed("Phone")], at: t0.addingTimeInterval(500))
        // Forgets everything it knew of sync, the times with it.
        try await pair.phone.resetSync(uploadingEverything: false)
        try await pair.phone.resetSync(uploadingEverything: true, at: t0.addingTimeInterval(1_000))
        try await pair.settle()
        #expect(try await pair.phone.sources().map(\.title) == ["Mac"])
        #expect(try await pair.mac.sources().map(\.title) == ["Mac"])
    }

    /// The reading place of a device nobody moved is still the one it and
    /// iCloud both had, so a move back made elsewhere stands over it.
    @Test func aPlaceNobodyMovedHereDoesNotUndoAMoveBackMadeElsewhere() async throws {
        let pair = try Pair()
        try await pair.mac.save(sources: [mastodon])
        try await pair.phone.save(sources: [mastodon])
        let items = [post("a", at: 10), post("b", at: 20), post("c", at: 30)]
        try await pair.mac.insert(items)
        try await pair.phone.insert(items)
        let rows = try await pair.mac.rows()
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[2].sortDate, rows[2].mergeKey))
        try await pair.settle()
        let shared = try #require(try await pair.mac.readingPlace(viewID: "all"))
        try await pair.mac.moveReadingPlace(viewID: "all", to: (rows[0].sortDate, rows[0].mergeKey), knowing: .seen(shared.identity))
        try await pair.syncMac()

        try await pair.phone.resetSync(uploadingEverything: true)
        try await pair.settle()
        #expect(try await pair.phone.readingPlace(viewID: "all")?.identity == ReadingPlace.Identity(move: 2, mergeKey: "post:a"))
        #expect(try await pair.mac.readingPlace(viewID: "all")?.identity == ReadingPlace.Identity(move: 2, mergeKey: "post:a"))
    }
}
