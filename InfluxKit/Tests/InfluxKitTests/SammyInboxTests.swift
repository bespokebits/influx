import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import GRDB
import Testing
@testable import InfluxKit

// Bookmarks to Sammy Inbox: what is sent for a bookmark, the outbox that
// sends it, and connecting again for `inbox:add`.

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
private let accountID = "sub42@sammy.example"

private func capture(key: String = "https://example.com/a", title: String = "A title") -> SammyCapture {
    SammyCapture(key: key, kind: .article, title: title, from: "River Notes", url: "https://example.com/a", bookmarkedAt: t0)
}

/// A Sammy account that answers each capture with what `answer` says, and
/// keeps every capture it was sent.
private final class FakeInboxAccount: SammyInboxAccount, @unchecked Sendable {
    func refusedToken() async -> String? { nil }
    private let lock = NSLock()
    private var _sent: [SammyCapture] = []
    private var _answer: SammyCaptureResult
    private var _mayAdd: Bool

    init(answer: SammyCaptureResult = .accepted, mayAdd: Bool = true) {
        _answer = answer
        _mayAdd = mayAdd
    }

    var sent: [SammyCapture] { lock.withLock { _sent } }
    var answer: SammyCaptureResult {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    var mayAdd: Bool {
        get { lock.withLock { _mayAdd } }
        set { lock.withLock { _mayAdd = newValue } }
    }

    func mayAddToInbox() async -> Bool { mayAdd }
    func sendCapture(_ capture: SammyCapture, now: Date) async -> SammyCaptureResult {
        lock.withLock {
            _sent.append(capture)
            return _answer
        }
    }
}

/// A clock tests move by hand.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = t0
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

/// The accounts the outbox said were signed out.
private final class SignedOut: @unchecked Sendable {
    private let lock = NSLock()
    private var _ids: [String] = []
    var ids: [String] { lock.withLock { _ids } }
    func add(_ id: String) { lock.withLock { _ids.append(id) } }
}

private struct Outbox {
    let store: InfluxStore
    let account: FakeInboxAccount
    let clock: Clock
    let signedOut: SignedOut
    let outbox: SammyInboxOutbox

    init(answer: SammyCaptureResult = .accepted, mayAdd: Bool = true, hasSession: Bool = true, on: Bool = true) async throws {
        let store = try InfluxStore.inMemory()
        let account = FakeInboxAccount(answer: answer, mayAdd: mayAdd)
        let clock = Clock()
        let signedOut = SignedOut()
        outbox = SammyInboxOutbox(
            store: store,
            account: { id in hasSession && id == accountID ? account : nil },
            signedOut: { id, _ in signedOut.add(id) },
            now: { clock.now }
        )
        self.store = store
        self.account = account
        self.clock = clock
        self.signedOut = signedOut
        if on { try await store.setSammyInbox(accountID, on: true, at: t0) }
    }

    func summary() async throws -> SammyInboxSummary {
        try await store.sammyInboxSummary(accountID, since: t0.addingTimeInterval(-60))
    }
}

@Suite struct SammyCaptureTests {
    // MARK: What is sent

    @Test func anArticleSendsItsTitleFeedAndLink() throws {
        let made = try SammyCapture.make(
            key: "rss:key", kind: .article, title: "  The quiet return\nof the paper notebook ", body: "Sales are up.",
            url: "https://example.com/notebooks", from: "Slow Reading", bookmarkedAt: t0
        )
        #expect(made == SammyCapture(key: "rss:key", kind: .article, title: "The quiet return of the paper notebook", from: "Slow Reading", url: "https://example.com/notebooks", bookmarkedAt: t0))
    }

    @Test func aPostIsTitledByItsFirstLineUpToEightyCharacters() throws {
        let short = try SammyCapture.make(key: "k", kind: .post, title: nil, body: "\n\n  Ferry times change Monday.  \nSecond line", url: "https://example.com/p", from: "x", bookmarkedAt: t0)
        #expect(short.title == "Ferry times change Monday.")
        let line = "The ferry timetable changes on Monday: the 7:10 becomes 7:25, and the last boat back is 22:40 now."
        let long = try SammyCapture.make(key: "k", kind: .post, title: nil, body: line, url: "https://example.com/p", from: "x", bookmarkedAt: t0)
        #expect(long.title.count <= SammyCapture.Limit.firstLine)
        #expect(long.title.hasSuffix("…"))
        #expect(line.hasPrefix(String(long.title.dropLast())))
        // A post that has a title (a rich feed's can) is titled by its
        // title's first line.
        let titled = try SammyCapture.make(key: "k", kind: .post, title: "Rich title\nsecond", body: "Body line", url: "https://example.com/p", from: "x", bookmarkedAt: t0)
        #expect(titled.title == "Rich title")
    }

    @Test func anArticleWithOnlyABodyIsTitledByItsFirstLine() throws {
        let made = try SammyCapture.make(key: "k", kind: .article, title: "  ", body: "First line\nmore", url: "https://example.com/a", from: "Feed", bookmarkedAt: t0)
        #expect(made.title == "First line")
    }

    @Test func noTextAtAllIsABookmarkFromItsSource() throws {
        let made = try SammyCapture.make(key: "k", kind: .post, title: nil, body: " \n ", url: "https://example.com/p", from: "@mira@harbour.example on Mastodon", bookmarkedAt: t0)
        #expect(made.title == "Bookmark from @mira@harbour.example on Mastodon")
    }

    @Test func whereItCameFrom() {
        #expect(SammyCapture.from(sourceKind: .mastodonHome, sourceTitle: "Home", authorHandle: "@mira@harbour.example") == "@mira@harbour.example on Mastodon")
        #expect(SammyCapture.from(sourceKind: .mastodonList, sourceTitle: "List", authorHandle: "@a@b.example") == "@a@b.example on Mastodon")
        #expect(SammyCapture.from(sourceKind: .blueskyFollowing, sourceTitle: "Following", authorHandle: "@a.bsky.social") == "@a.bsky.social on Bluesky")
        #expect(SammyCapture.from(sourceKind: .blueskyFeed, sourceTitle: "Feed", authorHandle: "@a.bsky.social") == "@a.bsky.social on Bluesky")
        #expect(SammyCapture.from(sourceKind: .rss, sourceTitle: "River Notes", authorHandle: "example.com") == "River Notes")
        #expect(SammyCapture.from(sourceKind: .sammyFeed, sourceTitle: "Movies: first scores", authorHandle: "@x") == "Movies: first scores")
        #expect(SammyCapture.from(sourceKind: .mastodonHome, sourceTitle: "Home", authorHandle: " ") == "Home")
    }

    // MARK: Limits, in UTF-16 code units

    @Test func titlesAndSourcesAreCutToTheLimitsWithoutSplittingACharacter() throws {
        // Each family emoji is 11 UTF-16 code units and one character.
        let family = "👨‍👩‍👧‍👦"
        #expect(family.utf16.count == 11)
        let title = String(repeating: family, count: 60)
        let made = try SammyCapture.make(key: "k", kind: .article, title: title, body: "", url: "https://example.com/a", from: String(repeating: "é", count: 200), bookmarkedAt: t0)
        #expect(made.title.utf16.count <= SammyCapture.Limit.title)
        #expect(made.title.utf16.count == 45 * 11)
        #expect(made.title.allSatisfy { String($0) == family })
        #expect(made.from.utf16.count == SammyCapture.Limit.from)
        // A post's first line is 80 characters, but more code units.
        let post = try SammyCapture.make(key: "k", kind: .post, title: nil, body: title, url: "https://example.com/p", from: "x", bookmarkedAt: t0)
        #expect(post.title.utf16.count <= SammyCapture.Limit.title)
        #expect(post.title.unicodeScalars.allSatisfy { family.unicodeScalars.contains($0) })
    }

    @Test func aLinkThatIsNotHTTPSOrTooLongIsNotQueued() {
        func make(key: String = "k", url: String?) throws(SammyCapture.Refusal) -> SammyCapture {
            try SammyCapture.make(key: key, kind: .article, title: "t", body: "", url: url, from: "f", bookmarkedAt: t0)
        }
        #expect(throws: SammyCapture.Refusal.notHTTPS) { try make(url: nil) }
        #expect(throws: SammyCapture.Refusal.notHTTPS) { try make(url: "http://example.com/a") }
        #expect(throws: SammyCapture.Refusal.notHTTPS) { try make(url: "https:///nohost") }
        let path = String(repeating: "a", count: SammyCapture.Limit.url)
        #expect(throws: SammyCapture.Refusal.urlTooLong) { try make(url: "https://example.com/\(path)") }
        #expect(throws: SammyCapture.Refusal.badKey) { try make(key: "", url: "https://example.com/a") }
        #expect(throws: SammyCapture.Refusal.badKey) { try make(key: String(repeating: "k", count: 1025), url: "https://example.com/a") }
        #expect((try? make(key: String(repeating: "k", count: 1024), url: "https://example.com/a")) != nil)
    }

    // MARK: The request and its answers

    @Test func theRequestIsAJSONPostToCaptures() throws {
        let request = capture().request(issuer: URL(string: "https://sammy.example")!)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://sammy.example/api/v1/captures")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body == [
            "key": "https://example.com/a", "kind": "article", "title": "A title", "from": "River Notes",
            "url": "https://example.com/a", "bookmarkedAt": "2026-10-26T07:33:20Z",
        ])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func eachAnswerMeansWhatTheDesignSays() {
        func result(_ status: Int, _ headers: [String: String] = [:]) -> SammyCaptureResult {
            SammyCaptureResult(HTTPURLResponse(url: URL(string: "https://sammy.example/api/v1/captures")!, statusCode: status, httpVersion: nil, headerFields: headers)!, now: t0)
        }
        #expect(result(200) == .accepted)
        #expect(result(401) == .signedOut)
        #expect(result(403) == .missingScope)
        #expect(result(400) == .refused(status: 400))
        #expect(result(404) == .refused(status: 404))
        #expect(result(413) == .refused(status: 413))
        #expect(result(429, ["Retry-After": "120"]) == .retry(after: t0.addingTimeInterval(120)))
        #expect(result(500) == .retry(after: nil))
        #expect(result(503) == .retry(after: nil))
    }

    @Test func theBackoffDoublesFromAMinuteToAnHour() {
        #expect(SammyInboxOutbox.backoff(afterAttempts: 1) == 60)
        #expect(SammyInboxOutbox.backoff(afterAttempts: 2) == 120)
        #expect(SammyInboxOutbox.backoff(afterAttempts: 4) == 480)
        #expect(SammyInboxOutbox.backoff(afterAttempts: 20) == 3600)
    }
}

@Suite struct SammyInboxOutboxTests {
    @Test func theSwitchIsOffByDefaultAndNothingIsQueued() async throws {
        let box = try await Outbox(on: false)
        #expect(try await box.store.isSammyInboxOn(accountID) == false)
        #expect(await box.outbox.bookmarked(.success(capture())) == .off)
        #expect(box.account.sent.isEmpty)
        #expect(try await box.store.waitingCaptures().isEmpty)
    }

    @Test func aBookmarkIsSentAtOnceAndOnlyOnce() async throws {
        let box = try await Outbox()
        #expect(await box.outbox.bookmarked(.success(capture())) == .sent)
        #expect(box.account.sent == [capture()])
        // Again, or at the next pass: nothing more is sent.
        #expect(await box.outbox.bookmarked(.success(capture())) == .sent)
        await box.outbox.run()
        #expect(box.account.sent.count == 1)
        #expect(try await box.summary() == SammyInboxSummary(isOn: true, sent: 1))
    }

    @Test func aRefusedTokenIsRememberedByItsHashUntilAnotherIsStored() async throws {
        let store = try InfluxStore.inMemory()
        try await store.recordSammyRefusal(accountID: accountID, token: "sao_refused", at: t0)
        // Only a hash is kept, never the token.
        let kept = try await store.writer.read { db in try SammyRefusal.fetchAll(db) }
        #expect(kept.map(\.tokenHash) == [SammyRefusal.hash("sao_refused")])
        #expect(kept.first?.tokenHash.count == 64)
        #expect(kept.first?.tokenHash.contains("sao_refused") == false)
        #expect(try await store.sammyRefusalAccounts() == [accountID])
        // Still the stored token: still refused, as after a relaunch.
        #expect(try await store.stillRefusedSammyAccounts(storedTokens: [accountID: "sao_refused"]) == [accountID])
        // A credential that couldn't be read says nothing: kept.
        #expect(try await store.stillRefusedSammyAccounts(storedTokens: [:]) == [])
        #expect(try await store.sammyRefusalAccounts() == [accountID])
        // Another token stored since (signed in again here or elsewhere):
        // forgotten.
        #expect(try await store.stillRefusedSammyAccounts(storedTokens: [accountID: "sao_new"]) == [])
        #expect(try await store.sammyRefusalAccounts().isEmpty)
        // No session at all any more: forgotten too.
        try await store.recordSammyRefusal(accountID: accountID, token: "sao_refused", at: t0)
        let noSession: [String: String?] = [accountID: String?.none]
        #expect(try await store.stillRefusedSammyAccounts(storedTokens: noSession) == [])
        #expect(try await store.sammyRefusalAccounts().isEmpty)
        try await store.recordSammyRefusal(accountID: accountID, token: "sao_refused", at: t0)
        try await store.clearSammyRefusal(accountID: accountID)
        #expect(try await store.sammyRefusalAccounts().isEmpty)
    }

    @Test func theSwitchIsASyncedSetting() async throws {
        let box = try await Outbox(on: false)
        try await box.store.setSammyInbox(accountID, on: true, at: t0)
        #expect(try await box.store.setting(InfluxStore.sammyInboxSettingKey(accountID)) == Data("on".utf8))
        #expect(try await box.store.sammyInboxAccounts() == [accountID])
        let changes = try await box.store.writer.read { db in try SyncRecordState.fetchAll(db) }
        #expect(changes.map(\.type) == [.setting])
        // The outbox itself never syncs.
        _ = await box.outbox.bookmarked(.success(capture()))
        #expect(try await box.store.writer.read { db in try SyncRecordState.fetchCount(db) } == 1)
        try await box.store.setSammyInbox(accountID, on: false, at: t0)
        #expect(try await box.store.setting(InfluxStore.sammyInboxSettingKey(accountID)) == nil)
    }

    @Test func aBookmarkThatCantGoToSammyIsNotQueued() async throws {
        let box = try await Outbox()
        #expect(await box.outbox.bookmarked(.failure(.notHTTPS)) == .cannotSend(.notHTTPS))
        #expect(try await box.store.waitingCaptures().isEmpty)
    }

    @Test func offlineItWaitsAndGoesWhenTheBackoffIsUp() async throws {
        let box = try await Outbox(answer: .offline)
        #expect(await box.outbox.bookmarked(.success(capture())) == .waiting(.offline))
        let waiting = try #require(try await box.store.waitingCaptures().first)
        #expect(waiting.attempts == 1)
        #expect(waiting.nextAttemptAt == t0.addingTimeInterval(60))
        // Not before the backoff is up.
        box.account.answer = .accepted
        #expect(await box.outbox.run() == t0.addingTimeInterval(60))
        #expect(box.account.sent.count == 1)
        box.clock.advance(61)
        #expect(await box.outbox.run() == nil)
        #expect(box.account.sent.count == 2)
        #expect(try await box.summary() == SammyInboxSummary(isOn: true, sent: 1))
    }

    @Test func aRetryAfterIsHonoured() async throws {
        let box = try await Outbox(answer: .retry(after: t0.addingTimeInterval(600)))
        #expect(await box.outbox.bookmarked(.success(capture())) == .waiting(.busy))
        #expect(try await box.store.waitingCaptures().first?.nextAttemptAt == t0.addingTimeInterval(600))
    }

    @Test func aRefusalDropsItAtOnceAndTheAccountScreenSaysSo() async throws {
        let box = try await Outbox(answer: .refused(status: 400))
        #expect(await box.outbox.bookmarked(.success(capture())) == .refused)
        #expect(try await box.store.waitingCaptures().isEmpty)
        #expect(try await box.summary() == SammyInboxSummary(isOn: true, refused: 1))
        await box.outbox.run()
        #expect(box.account.sent.count == 1)
    }

    @Test func aMissingScopeKeepsIt() async throws {
        let box = try await Outbox(answer: .missingScope)
        #expect(await box.outbox.bookmarked(.success(capture())) == .waiting(.approval))
        #expect(try await box.store.waitingCaptures().count == 1)
        box.account.answer = .accepted
        box.clock.advance(61)
        await box.outbox.run()
        #expect(try await box.summary() == SammyInboxSummary(isOn: true, sent: 1))
    }

    @Test func aSessionWithoutInboxAddHoldsItUnsent() async throws {
        let box = try await Outbox(mayAdd: false)
        #expect(await box.outbox.bookmarked(.success(capture())) == .waiting(.approval))
        await box.outbox.run()
        #expect(box.account.sent.isEmpty)
        let waiting = try #require(try await box.store.waitingCaptures().first)
        #expect(waiting.attempts == 0)
        // The upgraded session reaches this device: the next pass sends it.
        box.account.mayAdd = true
        await box.outbox.run()
        #expect(box.account.sent.count == 1)
    }

    @Test func noSessionOnThisDeviceHoldsItToo() async throws {
        let box = try await Outbox(hasSession: false)
        #expect(await box.outbox.bookmarked(.success(capture())) == .waiting(.approval))
        #expect(try await box.store.waitingCaptures().count == 1)
    }

    @Test func aRevokedTokenKeepsItAndAsksForApproval() async throws {
        let box = try await Outbox(answer: .signedOut)
        #expect(await box.outbox.bookmarked(.success(capture())) == .waiting(.signedOut))
        #expect(box.signedOut.ids == [accountID])
        #expect(try await box.store.waitingCaptures().count == 1)
        // Not tried again until approved again…
        box.account.answer = .accepted
        await box.outbox.run()
        #expect(box.account.sent.count == 1)
        // …then the waiting bookmarks go.
        await box.outbox.wake(accountID: accountID)
        await box.outbox.run()
        #expect(box.account.sent.count == 2)
        #expect(try await box.summary() == SammyInboxSummary(isOn: true, sent: 1))
    }

    @Test func afterSevenDaysItIsDroppedAndTheAccountScreenSaysSo() async throws {
        let box = try await Outbox(answer: .retry(after: nil))
        _ = await box.outbox.bookmarked(.success(capture()))
        box.clock.advance(SammyInboxOutbox.expiry - 1)
        await box.outbox.run()
        #expect(try await box.store.waitingCaptures().count == 1)
        box.clock.advance(2)
        await box.outbox.run()
        #expect(try await box.store.waitingCaptures().isEmpty)
        #expect(try await box.store.sammyInboxSummary(accountID, since: box.clock.now.addingTimeInterval(-86_400)) == SammyInboxSummary(isOn: true, expired: 1))
        // Forgotten a week later.
        box.clock.advance(SammyInboxOutbox.expiry + 1)
        await box.outbox.run()
        #expect(try await box.store.sammyInboxSummary(accountID, since: .distantPast) == SammyInboxSummary(isOn: true))
    }

    @Test func removingTheBookmarkBeforeItIsSentRemovesIt() async throws {
        let box = try await Outbox(answer: .retry(after: nil))
        _ = await box.outbox.bookmarked(.success(capture()))
        await box.outbox.unbookmarked(key: capture().key)
        #expect(try await box.store.waitingCaptures().isEmpty)
        #expect(try await box.summary() == SammyInboxSummary(isOn: true))
    }

    @Test func removingItAfterItWasSentLeavesIt() async throws {
        let box = try await Outbox()
        _ = await box.outbox.bookmarked(.success(capture()))
        await box.outbox.unbookmarked(key: capture().key)
        #expect(try await box.summary() == SammyInboxSummary(isOn: true, sent: 1))
    }

    @Test func aBookmarkRemovedElsewhereIsNotSent() async throws {
        let box = try await Outbox(answer: .retry(after: nil))
        try await box.store.setArticle(mergeKey: capture().key, bookmarked: true, at: t0)
        _ = await box.outbox.bookmarked(.success(capture()))
        // Sync takes the removal from another device.
        try await box.store.setArticle(mergeKey: capture().key, bookmarked: false, at: t0.addingTimeInterval(1))
        box.account.answer = .accepted
        box.clock.advance(61)
        await box.outbox.run()
        #expect(box.account.sent.count == 1)
        #expect(try await box.store.waitingCaptures().isEmpty)
    }

    @Test func switchingOffDropsTheWaitingOnes() async throws {
        let box = try await Outbox(answer: .retry(after: nil))
        _ = await box.outbox.bookmarked(.success(capture(key: "a")))
        _ = await box.outbox.bookmarked(.success(capture(key: "b")))
        #expect(try await box.store.waitingCaptures().count == 2)
        try await box.store.setSammyInbox(accountID, on: false)
        #expect(try await box.store.waitingCaptures().isEmpty)
        #expect(try await box.summary() == SammyInboxSummary())
    }

    @Test func theSwitchIsCheckedAgainBeforeEverySend() async throws {
        let box = try await Outbox(answer: .retry(after: nil))
        _ = await box.outbox.bookmarked(.success(capture()))
        // The switch-off arrives by sync: a plain setting change, not
        // through setSammyInbox, so the row is still there.
        try await box.store.setSetting(InfluxStore.sammyInboxSettingKey(accountID), to: nil)
        #expect(try await box.store.waitingCaptures().count == 1)
        box.account.answer = .accepted
        box.clock.advance(61)
        await box.outbox.run()
        #expect(box.account.sent.count == 1)
        #expect(try await box.store.waitingCaptures().isEmpty)
    }

    @Test func aBookmarkDroppedBeforeIsQueuedAfresh() async throws {
        let box = try await Outbox(answer: .refused(status: 400))
        _ = await box.outbox.bookmarked(.success(capture()))
        box.account.answer = .accepted
        #expect(await box.outbox.bookmarked(.success(capture())) == .sent)
        #expect(try await box.summary() == SammyInboxSummary(isOn: true, sent: 1))
    }

    @Test func aSlowFirstSendGoesOnAfterTheNoticeStopsWaiting() async throws {
        let store = try InfluxStore.inMemory()
        try await store.setSammyInbox(accountID, on: true)
        let slow = SlowInboxAccount()
        let outbox = SammyInboxOutbox(store: store, account: { _ in slow })
        #expect(await outbox.bookmarked(.success(capture()), limit: .milliseconds(50)) == .waiting(.offline))
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await store.sammyInboxSummary(accountID, since: .distantPast).sent == 1)
    }
}

private struct SlowInboxAccount: SammyInboxAccount {
    var answer: SammyCaptureResult = .accepted
    func mayAddToInbox() async -> Bool { true }
    func refusedToken() async -> String? { nil }
    func sendCapture(_ capture: SammyCapture, now: Date) async -> SammyCaptureResult {
        try? await Task.sleep(for: .milliseconds(300))
        return answer
    }
}

/// The retry dates an outbox reported.
private final class RetryDates: @unchecked Sendable {
    private let lock = NSLock()
    private var _dates: [Date] = []
    var dates: [Date] { lock.withLock { _dates } }
    func add(_ date: Date) { lock.withLock { _dates.append(date) } }
}

@Suite struct SammyInboxRetryWakeTests {
    @Test func aSlowFirstSendThatFailsStillAsksForItsPass() async throws {
        let store = try InfluxStore.inMemory()
        try await store.setSammyInbox(accountID, on: true)
        let retries = RetryDates()
        let outbox = SammyInboxOutbox(
            store: store, account: { _ in SlowInboxAccount(answer: .offline) },
            retryAt: { retries.add($0) }, now: { t0 }
        )
        // The notice stops waiting before the send has an answer…
        #expect(await outbox.bookmarked(.success(capture()), limit: .milliseconds(50)) == .waiting(.offline))
        #expect(retries.dates.isEmpty)
        // …and a pass meanwhile finds it being sent, with no date yet, so
        // it only asks to look again after the recheck.
        #expect(await outbox.run() == t0.addingTimeInterval(SammyInboxOutbox.approvalRecheck))
        // When it fails, its backoff is recorded and reported, so the app
        // can run again then.
        try await Task.sleep(for: .milliseconds(600))
        #expect(try await store.waitingCaptures().first?.nextAttemptAt == t0.addingTimeInterval(60))
        #expect(retries.dates == [t0.addingTimeInterval(60)])
    }

    @Test func aBookmarkHeldForApprovalIsLookedAtAgain() async throws {
        let box = try await Outbox(mayAdd: false)
        let retries = RetryDates()
        let account = box.account
        let outbox = SammyInboxOutbox(store: box.store, account: { _ in account }, retryAt: { retries.add($0) }, now: { t0 })
        let recheck = t0.addingTimeInterval(SammyInboxOutbox.approvalRecheck)
        #expect(await outbox.bookmarked(.success(capture())) == .waiting(.approval))
        // The app is asked to look again, with no backoff spent…
        #expect(retries.dates == [recheck])
        #expect(await outbox.run() == recheck)
        #expect(try await box.store.waitingCaptures().first?.attempts == 0)
        // …and once the upgraded session has reached this device by
        // iCloud Keychain, that look sends it.
        account.mayAdd = true
        #expect(await outbox.run() == nil)
        #expect(account.sent.count == 1)
    }

    @Test func aDistantRetryAfterStillWakesForTheExpiry() async throws {
        let far = t0.addingTimeInterval(30 * 86_400)
        let box = try await Outbox(answer: .retry(after: far))
        let retries = RetryDates()
        let account = box.account, clock = box.clock
        let outbox = SammyInboxOutbox(store: box.store, account: { _ in account }, retryAt: { retries.add($0) }, now: { clock.now })
        let expires = t0.addingTimeInterval(SammyInboxOutbox.expiry + 1)
        #expect(await outbox.bookmarked(.success(capture())) == .waiting(.busy))
        // The server's date is kept for the send…
        #expect(try await box.store.waitingCaptures().first?.nextAttemptAt == far)
        // …but the app is woken when the bookmark expires, sooner.
        #expect(retries.dates == [expires])
        #expect(await outbox.run() == expires)
        clock.advance(SammyInboxOutbox.expiry + 1)
        #expect(await outbox.run() == nil)
        #expect(account.sent.count == 1)
        #expect(try await box.store.sammyInboxSummary(accountID, since: .distantPast).expired == 1)
    }

    @Test func everyRecordedRetryIsReported() async throws {
        let box = try await Outbox(answer: .retry(after: t0.addingTimeInterval(600)))
        let retries = RetryDates()
        let account = box.account
        let outbox = SammyInboxOutbox(store: box.store, account: { _ in account }, retryAt: { retries.add($0) }, now: { t0 })
        _ = await outbox.bookmarked(.success(capture()))
        #expect(retries.dates == [t0.addingTimeInterval(600)])
        box.account.answer = .signedOut
        try await box.store.wakeCaptures(accountID: accountID)
        await outbox.run()
        #expect(retries.dates == [t0.addingTimeInterval(600), t0.addingTimeInterval(3600)])
    }
}

// MARK: SammyAccount as the real sender

@Suite struct SammyAccountCaptureTests {
    private let issuer = URL(string: "https://sammy.example")!

    private func session(_ token: String, scope: String = SammyOAuth.inboxScopes) -> SammySession {
        SammySession(issuer: issuer, revocationEndpoint: URL(string: "https://sammy.example/oauth/revoke"), accessToken: token, scope: scope, subject: "sub42")
    }

    @Test func aCaptureGoesWithTheBearerToTheAccountsServer() async throws {
        let http = FakeHTTPClient { request in
            request.url?.path == "/api/v1/captures" ? .init(text: #"{"ok":true}"#) : .init(status: 404)
        }
        let credentials = InMemoryCredentialStore()
        try credentials.save(session("sao_new"), for: accountID)
        let account = SammyAccount(session: session("sao_new"), http: http, credentials: credentials)
        #expect(await account.mayAddToInbox())
        #expect(await account.sendCapture(capture(), now: t0) == .accepted)
        let sent = try #require(http.requests.first)
        #expect(sent.url?.absoluteString == "https://sammy.example/api/v1/captures")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sao_new")
    }

    @Test func anUpgradedSessionFromAnotherDeviceIsTakenUpBeforeSending() async throws {
        let http = FakeHTTPClient { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer sao_new" ? .init(text: "{}") : .init(status: 403)
        }
        let credentials = InMemoryCredentialStore()
        let account = SammyAccount(session: session("sao_old", scope: SammyOAuth.scope), http: http, credentials: credentials)
        try credentials.save(session("sao_old", scope: SammyOAuth.scope), for: accountID)
        #expect(await account.mayAddToInbox() == false)
        // iCloud Keychain brings the upgraded session.
        try credentials.save(session("sao_new"), for: accountID)
        #expect(await account.mayAddToInbox())
        #expect(await account.sendCapture(capture(), now: t0) == .accepted)
    }

    @Test func aRevokedTokenIsSignedOut() async throws {
        let http = FakeHTTPClient { _ in .init(status: 401) }
        let credentials = InMemoryCredentialStore()
        try credentials.save(session("sao_new"), for: accountID)
        let account = SammyAccount(session: session("sao_new"), http: http, credentials: credentials)
        #expect(await account.sendCapture(capture(), now: t0) == .signedOut)
        #expect(await account.refusedToken() == "sao_new")
    }

    @Test func theOutboxPassesOnTheTokenSammyRefused() async throws {
        let http = FakeHTTPClient { _ in .init(status: 401) }
        let credentials = InMemoryCredentialStore()
        try credentials.save(session("sao_refused"), for: accountID)
        let account = SammyAccount(session: session("sao_refused"), http: http, credentials: credentials)
        let store = try InfluxStore.inMemory()
        try await store.setSammyInbox(accountID, on: true)
        let refused = RefusedTokens()
        let outbox = SammyInboxOutbox(store: store, account: { _ in account }, signedOut: { id, token in refused.add(id, token) })
        #expect(await outbox.bookmarked(.success(capture())) == .waiting(.signedOut))
        #expect(refused.calls == ["\(accountID) sao_refused"])
    }

    @Test func noAnswerIsRetried() async throws {
        let http = FakeHTTPClient { _ in throw ConnectorError.offline }
        let credentials = InMemoryCredentialStore()
        try credentials.save(session("sao_new"), for: accountID)
        let account = SammyAccount(session: session("sao_new"), http: http, credentials: credentials)
        #expect(await account.sendCapture(capture(), now: t0) == .offline)
    }

    @Test func signingOutAlsoRevokesAReplacedTokenNotYetConfirmed() async throws {
        let http = FakeHTTPClient { _ in .init() }
        let credentials = InMemoryCredentialStore()
        var upgraded = session("sao_new")
        upgraded.replacesToken = "sao_old"
        try credentials.save(upgraded, for: accountID)
        let account = SammyAccount(session: upgraded, http: http, credentials: credentials)
        await account.signOut()
        let revoked = http.requests.filter { $0.url?.path == "/oauth/revoke" }.map { form($0)["token"] }
        #expect(Set(revoked) == ["sao_new", "sao_old"])
    }
}

/// The accounts and refused tokens an outbox reported, as "<id> <token>".
private final class RefusedTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    var calls: [String] { lock.withLock { _calls } }
    func add(_ id: String, _ token: String?) { lock.withLock { _calls.append("\(id) \(token ?? "-")") } }
}

private extension SammySession {
    func with(token: String) -> SammySession {
        var copy = self
        copy.accessToken = token
        return copy
    }
}

private func form(_ request: URLRequest) -> [String: String] {
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    return Dictionary((components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
}

// MARK: Connecting again for inbox:add

/// The contract server, answering the token request with `scope`, and the
/// feed list as `subject`'s.
private enum Upgrade {
    static let origin = "https://example.com"
    static let subject = "AbCdEfGhIjKlMnOpQrStUv"
    static let accountID = "\(subject)@example.com"

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/SammyContract"))
        return try Data(contentsOf: url)
    }

    /// `scope` nil answers the token request without one.
    static func server(scope: String?, subject: String = Upgrade.subject, replace: Int = 204) throws -> FakeHTTPClient {
        let metadata = try data("oauth-authorization-server.json")
        var list = try #require(try JSONSerialization.jsonObject(with: data("feed-list-oauth.json")) as? [String: Any])
        list["account"] = ["id": subject, "server": origin]
        let listData = try JSONSerialization.data(withJSONObject: list)
        var answer = ["access_token": "sao_upgraded", "token_type": "Bearer"]
        if let scope { answer["scope"] = scope }
        let token = try JSONSerialization.data(withJSONObject: answer)
        return FakeHTTPClient { request in
            switch request.url?.path {
            case "/.well-known/oauth-authorization-server": return .init(body: metadata)
            case "/oauth/token": return .init(body: token)
            case "/oauth/revoke": return .init()
            case "/oauth/replace": return .init(status: replace)
            case "/api/v1/feeds": return .init(headers: ["Content-Type": "application/json"], body: listData)
            default: return .init(status: 404)
            }
        }
    }

    static func approved(for authorizeURL: URL) throws -> URL {
        let state = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value
        let object = try #require(try JSONSerialization.jsonObject(with: data("callback-approved.json")) as? [String: Any])
        // One #require at a time: one nested in another's argument is a
        // recursive macro expansion to the Linux toolchain.
        let address = try #require(object["url"] as? String)
        var callback = try #require(URLComponents(string: address))
        callback.queryItems = callback.queryItems?.map { $0.name == "state" ? URLQueryItem(name: "state", value: state) : $0 }
        return try #require(callback.url)
    }

    static let old = SammySession(
        issuer: URL(string: origin)!, revocationEndpoint: URL(string: "\(origin)/oauth/revoke"),
        accessToken: "sao_feeds-only", subject: subject
    )

    struct Setup {
        let http: FakeHTTPClient
        let credentials = InMemoryCredentialStore()
        let store: InfluxStore
        let signIn: SammySignIn
        let flow: SammyConnectFlow

        init(scope: String?, subject: String = Upgrade.subject, replace: Int = 204) async throws {
            http = try server(scope: scope, subject: subject, replace: replace)
            store = try InfluxStore.inMemory()
            signIn = SammySignIn(http: http, crypto: .fake(), credentials: credentials)
            flow = SammyConnectFlow(connector: signIn, credentials: credentials, sources: store)
            try credentials.save(Upgrade.old, for: Upgrade.accountID)
            try await store.save(sources: [Source(
                id: SammyFeedConnector.sourceID(accountID: Upgrade.accountID, feedID: "0193a1b2-0000-7000-8000-00000000f001"),
                kind: .sammyFeed, accountID: Upgrade.accountID, title: "Movies: first scores",
                url: "\(origin)/api/v1/feeds/0193a1b2-0000-7000-8000-00000000f001", colorIndex: 0
            )])
        }

        /// Connects again asking for feeds and the Inbox, and comes back
        /// approved.
        func connectAgain() async throws -> URL {
            let page = try await flow.begin(server: origin, scope: SammyOAuth.inboxScopes)
            _ = try await flow.complete(callbackURL: approved(for: page))
            return page
        }

        var stored: SammySession? { get throws { try credentials.load(SammySession.self, for: Upgrade.accountID) } }
        var revoked: [String] { http.requests.filter { $0.url?.path == "/oauth/revoke" }.compactMap { form($0)["token"] } }
    }
}

@Suite struct SammyUpgradeTests {
    @Test func theContractOffersInboxAdd() throws {
        let metadata = try #require(try JSONSerialization.jsonObject(with: Upgrade.data("oauth-authorization-server.json")) as? [String: Any])
        #expect((metadata["scopes_supported"] as? [String])?.contains(SammyOAuth.inboxScope) == true)
        let clients = try #require((try JSONSerialization.jsonObject(with: Upgrade.data("client-registration.json")) as? [String: Any])?["clients"] as? [[String: Any]])
        let influx = try #require(clients.first { $0["clientId"] as? String == SammyOAuth.clientID || $0["client_id"] as? String == SammyOAuth.clientID })
        #expect((influx["scopes"] as? [String])?.contains(SammyOAuth.inboxScope) == true)
        let manifest = try #require(try JSONSerialization.jsonObject(with: Upgrade.data("manifest.json")) as? [String: Any])
        #expect(manifest["contractVersion"] as? Int == 5)
    }

    @Test func connectingAgainAsksForFeedsAndTheInbox() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes)
        let page = try await setup.connectAgain()
        let scope = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
        #expect(scope == "feeds:read inbox:add")
        // A new connection still asks for feeds alone.
        let first = try await setup.flow.begin(server: Upgrade.origin)
        #expect(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value == "feeds:read")
    }

    @Test func bothScopesForTheSameAccountStoreTheNewSessionAndKeepTheOldTokenLive() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes)
        _ = try await setup.connectAgain()
        let session = try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        #expect(session.accessToken == "sao_upgraded")
        #expect(session.addsToInbox)
        #expect(session.replacesToken == "sao_feeds-only")
        #expect(try setup.stored == session)
        // Nothing revoked: other devices read feeds with the old token
        // until the new session reaches them.
        #expect(setup.revoked.isEmpty)
        // The account's feed sources are as they were.
        let sources = try await setup.store.sources()
        #expect(sources.count == 1)
    }

    @Test func anUntickedInboxRevokesTheNewTokenAndKeepsTheOld() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.scope)
        _ = try await setup.connectAgain()
        await #expect(throws: SammyConnectFlow.FlowError.missingScope(SammyOAuth.inboxScope)) {
            try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        }
        #expect(setup.revoked == ["sao_upgraded"])
        #expect(try setup.stored == Upgrade.old)
    }

    @Test func untickedFeedsRevokeTheNewTokenAndKeepTheOld() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScope)
        let page = try await setup.flow.begin(server: Upgrade.origin, scope: SammyOAuth.inboxScopes)
        await #expect(throws: SammySignInError.missingScope(SammyOAuth.scope)) {
            _ = try await setup.flow.complete(callbackURL: Upgrade.approved(for: page))
        }
        #expect(setup.revoked == ["sao_upgraded"])
        #expect(try setup.stored == Upgrade.old)
    }

    @Test func anotherSammyAccountRevokesTheNewTokenAndKeepsTheOld() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes, subject: "SomeoneElse0123456789")
        _ = try await setup.connectAgain()
        await #expect(throws: SammyConnectFlow.FlowError.differentAccount("SomeoneElse0123456789@example.com")) {
            try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        }
        #expect(setup.revoked == ["sao_upgraded"])
        #expect(try setup.stored == Upgrade.old)
        #expect(try setup.credentials.load(SammySession.self, for: "SomeoneElse0123456789@example.com") == nil)
    }

    @Test func aTokenAnswerWithoutAScopeGrantedWhatWasAskedFor() async throws {
        // RFC 6749 §5.1: an answer that leaves `scope` out granted the
        // scope requested.
        let setup = try await Upgrade.Setup(scope: nil)
        _ = try await setup.connectAgain()
        let session = try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        #expect(session.scope == SammyOAuth.inboxScopes)
        #expect(session.addsToInbox)
        #expect(setup.revoked.isEmpty)
        // A first connection that asked for feeds alone still has feeds alone.
        let first = try await Upgrade.Setup(scope: nil)
        let page = try await first.flow.begin(server: Upgrade.origin)
        _ = try await first.flow.complete(callbackURL: Upgrade.approved(for: page))
        let feedsOnly = try await first.flow.saveSignInAgain(expecting: Upgrade.accountID)
        #expect(feedsOnly.scope == SammyOAuth.scope)
    }

    @Test func aServerOfferingInboxAddGetsToTheApprovalPage() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes)
        // What discovery read from the metadata reaches the sign-in.
        let found = try await setup.signIn.discover(server: Upgrade.origin)
        #expect(found.scopesSupported.contains(SammyOAuth.inboxScope))
        let pending = try await setup.signIn.begin(server: Upgrade.origin, scope: SammyOAuth.inboxScopes)
        let page = URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false)
        #expect(page?.path == "/oauth/authorize")
        #expect(page?.queryItems?.first { $0.name == "scope" }?.value == "feeds:read inbox:add")
    }

    @Test func aServerWithoutInboxAddIsSaidSo() async throws {
        let http = FakeHTTPClient { request in
            guard request.url?.path == "/.well-known/oauth-authorization-server" else { return .init(status: 404) }
            var metadata = try JSONSerialization.jsonObject(with: Upgrade.data("oauth-authorization-server.json")) as! [String: Any]
            metadata["scopes_supported"] = ["feeds:read"]
            return .init(body: try JSONSerialization.data(withJSONObject: metadata))
        }
        let signIn = SammySignIn(http: http, crypto: .fake(), credentials: InMemoryCredentialStore())
        await #expect(throws: SammySignInError.scopeNotOffered(SammyOAuth.inboxScope)) {
            _ = try await signIn.begin(server: Upgrade.origin, scope: SammyOAuth.inboxScopes)
        }
    }

    // MARK: Confirming the replacement

    @Test func theReplacementIsConfirmedOnceStoredWithTheOldTokenInTheBody() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes)
        _ = try await setup.connectAgain()
        try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        #expect(await setup.signIn.confirmReplacement(for: Upgrade.accountID) == .confirmed)
        let sent = try #require(setup.http.requests.first { $0.url?.path == "/oauth/replace" })
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.absoluteString == "https://example.com/oauth/replace")
        #expect(sent.url?.query == nil)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer sao_upgraded")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(form(sent) == ["replaces_token": "sao_feeds-only"])
        #expect(try setup.stored?.replacesToken == nil)
        #expect(try setup.stored?.accessToken == "sao_upgraded")
        // Nothing left to confirm.
        #expect(await setup.signIn.confirmReplacement(for: Upgrade.accountID) == .nothingPending)
        #expect(setup.revoked.isEmpty)
    }

    @Test func replacingASessionEndsItsUnconfirmedPredecessorToo() {
        let issuer = URL(string: Upgrade.origin)!
        var upgraded = SammySession(issuer: issuer, revocationEndpoint: nil, accessToken: "new", subject: "s")
        upgraded.replacesToken = "old"
        // Replaced by another session, or removed: both go.
        let other = SammySession(issuer: issuer, revocationEndpoint: nil, accessToken: "other", subject: "s")
        #expect(upgraded.endedBy(other).map(\.accessToken) == ["new", "old"])
        #expect(upgraded.endedBy(nil).map(\.accessToken) == ["new", "old"])
        #expect(upgraded.endedBy(nil).allSatisfy { $0.replacesToken == nil })
        // The same token stored again, without the pending confirmation:
        // only the predecessor goes.
        #expect(upgraded.endedBy(other.with(token: "new")).map(\.accessToken) == ["old"])
        // Upgraded again: the new session names this one's token, which
        // stays; the one two back goes.
        var again = other
        again.replacesToken = "new"
        #expect(upgraded.endedBy(again).map(\.accessToken) == ["old"])
        // Nothing pending: as before, only its own token.
        #expect(other.endedBy(upgraded).map(\.accessToken) == ["other"])
    }

    @Test func signingInAgainBeforeTheConfirmationLandsEndsTheOldTokenToo() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes, replace: 503)
        _ = try await setup.connectAgain()
        try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        #expect(await setup.signIn.confirmReplacement(for: Upgrade.accountID) == .retryLater)
        #expect(try setup.stored?.replacesToken == "sao_feeds-only")
        // Signed in again (the server grants the same token here): the
        // credential no longer names the old token, so it is revoked.
        let page = try await setup.flow.begin(server: Upgrade.origin)
        _ = try await setup.flow.complete(callbackURL: Upgrade.approved(for: page))
        try await setup.flow.saveSignInAgain(expecting: Upgrade.accountID)
        #expect(try setup.stored?.replacesToken == nil)
        #expect(setup.revoked == ["sao_feeds-only"])
    }

    @Test func disconnectingBeforeTheConfirmationLandsEndsBothTokens() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes, replace: 503)
        _ = try await setup.connectAgain()
        try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        await setup.flow.disconnect(accountID: Upgrade.accountID)
        #expect(Set(setup.revoked) == ["sao_upgraded", "sao_feeds-only"])
        #expect(try setup.stored == nil)
    }

    @Test func aLostConfirmationKeepsTheOldTokenForTheNextLaunch() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes, replace: 503)
        _ = try await setup.connectAgain()
        try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        #expect(await setup.signIn.confirmReplacement(for: Upgrade.accountID) == .retryLater)
        #expect(try setup.stored?.replacesToken == "sao_feeds-only")
    }

    @Test func aRefusedConfirmationIsGivenUp() async throws {
        let setup = try await Upgrade.Setup(scope: SammyOAuth.inboxScopes, replace: 401)
        _ = try await setup.connectAgain()
        try await setup.flow.saveUpgrade(expecting: Upgrade.accountID)
        #expect(await setup.signIn.confirmReplacement(for: Upgrade.accountID) == .abandoned)
        #expect(try setup.stored?.replacesToken == nil)
    }

    @Test func aSessionStoredBeforeReplacesTokenExistedStillDecodes() throws {
        let old = #"{"issuer":"https://example.com","clientID":"influx","accessToken":"t","scope":"feeds:read","subject":"s"}"#
        let session = try JSONDecoder().decode(SammySession.self, from: Data(old.utf8))
        #expect(session.replacesToken == nil)
        #expect(!session.addsToInbox)
    }
}
