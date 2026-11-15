import Foundation
import Testing
import InfluxKit
@testable import Influx

/// What the timeline and the account screen say for Bookmarks to Sammy
/// Inbox, and the switch as the app sets it.
@MainActor
@Suite struct SammyInboxNoticeTests {
    @Test func aSentBookmarkSaysItWasAddedAndNothingIsSaidWhenTheSwitchIsOff() {
        #expect(SammyInbox.notice(for: .sent) == "Bookmarked · added to your Sammy Inbox")
        #expect(SammyInbox.notice(for: .off) == nil)
        #expect(SammyInbox.notice(for: .waiting(.offline)) == "Bookmarked · goes to your Sammy Inbox when you’re back online")
        #expect(SammyInbox.notice(for: .cannotSend(.notHTTPS))?.contains("can’t go to your Sammy Inbox") == true)
    }

    @Test func switchingOnSaysWhyItStayedOff() {
        #expect(SammyInbox.message(for: SammyConnectFlow.FlowError.differentAccount("x@example.com")).contains("different Sammy account"))
        #expect(SammyInbox.message(for: SammyConnectFlow.FlowError.missingScope(SammyOAuth.inboxScope)).contains("Adding to your Inbox wasn’t ticked"))
        #expect(SammyInbox.message(for: SammySignInError.missingScope(SammyOAuth.scope)).contains("Reading your feeds wasn’t ticked"))
    }

    @Test func anAccountsSwitchIsOffUntilSwitchedOnAndOffDropsWhatWaits() async throws {
        let store = try InfluxStore.inMemory()
        let accounts = Accounts(store: store, isSample: true, credentials: InMemoryCredentialStore())
        let inbox = SammyInbox(store: store, accounts: accounts, isSample: true)
        let account = Accounts.Account(id: "sub@example.com", service: .sammy, name: "Sammy (example.com)", sources: [], isSignedIn: true)
        #expect(try await store.isSammyInboxOn(account.id) == false)
        // No session here holds inbox:add, so switching on without the
        // reader's approval changes nothing.
        await inbox.set(true, for: account)
        #expect(try await store.isSammyInboxOn(account.id) == false)
        try await store.setSammyInbox(account.id, on: true)
        await inbox.set(false, for: account)
        #expect(try await store.isSammyInboxOn(account.id) == false)
    }

    @Test func cancelStopsConnectingAndLeavesTheSwitchOff() async throws {
        let store = try InfluxStore.inMemory()
        let accounts = Accounts(store: store, isSample: true, credentials: InMemoryCredentialStore())
        let inbox = SammyInbox(store: store, accounts: accounts, isSample: true)
        let account = Accounts.Account(id: "sub@example.com", service: .sammy, name: "Sammy (example.com)", sources: [], isSignedIn: true)
        let switching = Task { await inbox.set(true, for: account, approve: true) }
        for _ in 0..<200 where !inbox.connecting.contains(account.id) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(inbox.connecting.contains(account.id))
        inbox.cancelConnecting(account.id)
        await switching.value
        #expect(!inbox.connecting.contains(account.id))
        #expect(inbox.errors[account.id] == nil)
        #expect(try await store.isSammyInboxOn(account.id) == false)
    }

    @Test func aRefusedCaptureAsksForSignInEvenWithNoFeedSources() async throws {
        let store = try InfluxStore.inMemory()
        let credentials = InMemoryCredentialStore()
        let session = SammySession(issuer: URL(string: "https://example.com")!, revocationEndpoint: nil, accessToken: "refused",
                                   scope: SammyOAuth.inboxScopes, subject: "sub")
        try credentials.save(session, for: session.accountID)
        let accounts = Accounts(store: store, isSample: true, credentials: credentials)
        await accounts.load()
        let found = try #require(accounts.accounts.first { $0.id == session.accountID })
        #expect(found.sources.isEmpty)
        #expect(!found.needsSignIn([:]))
        // Sammy answered 401 to a bookmark.
        await accounts.markSammySignedOut(session.accountID, refusedToken: "refused")
        let refused = try #require(accounts.accounts.first { $0.id == session.accountID })
        #expect(refused.isSignedIn)
        #expect(refused.needsSignIn([:]))
        // It survives a relaunch: a new Accounts over the same store and
        // keychain still asks.
        let relaunched = Accounts(store: store, isSample: true, credentials: credentials)
        await relaunched.load()
        #expect(relaunched.accounts.first { $0.id == session.accountID }?.needsSignIn([:]) == true)
        // A different session stored since (signed in again, here or on
        // another device) ends it.
        var fresh = session
        fresh.accessToken = "approved-again"
        try credentials.save(fresh, for: session.accountID)
        await accounts.load()
        #expect(accounts.accounts.first { $0.id == session.accountID }?.needsSignIn([:]) == false)
        await relaunched.load()
        #expect(relaunched.accounts.first { $0.id == session.accountID }?.needsSignIn([:]) == false)
    }

    @Test func aSessionThatArrivedBeforeTheRefusalIsRecordedIsNotTakenForTheRefusedOne() async throws {
        let store = try InfluxStore.inMemory()
        let credentials = InMemoryCredentialStore()
        // Another device's new session is already stored by the time the
        // 401 for the old token is recorded.
        let arrived = SammySession(issuer: URL(string: "https://example.com")!, revocationEndpoint: nil, accessToken: "arrived",
                                   scope: SammyOAuth.inboxScopes, subject: "sub")
        try credentials.save(arrived, for: arrived.accountID)
        let accounts = Accounts(store: store, isSample: true, credentials: credentials)
        await accounts.markSammySignedOut(arrived.accountID, refusedToken: "refused-old")
        #expect(accounts.accounts.first { $0.id == arrived.accountID }?.needsSignIn([:]) == false)
    }

    @Test func signingInAgainWithoutTheInboxSwitchesItOffAndSaysWhy() async throws {
        let store = try InfluxStore.inMemory()
        let accounts = Accounts(store: store, isSample: true, credentials: InMemoryCredentialStore())
        let inbox = SammyInbox(store: store, accounts: accounts, isSample: true)
        let issuer = URL(string: "https://example.com")!
        let feedsOnly = SammySession(issuer: issuer, revocationEndpoint: nil, accessToken: "feeds-only", scope: SammyOAuth.scope, subject: "sub")
        let id = feedsOnly.accountID
        try await store.setSammyInbox(id, on: true)
        let capture = SammyCapture(key: "k", kind: .article, title: "t", from: "f", url: "https://example.com/a", bookmarkedAt: Date())
        try await store.queueCapture(capture, for: [id])
        #expect(try await store.waitingCaptures().count == 1)

        // Signed in again asking for both, the reader unticked the Inbox.
        await accounts.tookUpSammySessionSignedInAgain(feedsOnly, askedForInbox: true)
        #expect(try await store.isSammyInboxOn(id) == false)
        #expect(try await store.waitingCaptures().isEmpty)
        #expect(inbox.errors[id]?.contains("Adding to your Inbox wasn’t ticked") == true)
    }

    @Test func signingInAgainWithTheInboxKeepsItOn() async throws {
        let store = try InfluxStore.inMemory()
        let accounts = Accounts(store: store, isSample: true, credentials: InMemoryCredentialStore())
        let inbox = SammyInbox(store: store, accounts: accounts, isSample: true)
        let both = SammySession(issuer: URL(string: "https://example.com")!, revocationEndpoint: nil, accessToken: "both",
                                scope: SammyOAuth.inboxScopes, subject: "sub")
        try await store.setSammyInbox(both.accountID, on: true)
        await accounts.tookUpSammySessionSignedInAgain(both, askedForInbox: true)
        #expect(try await store.isSammyInboxOn(both.accountID))
        #expect(inbox.errors[both.accountID] == nil)
        // A sign-in that never asked for the Inbox leaves the switch alone.
        let feedsOnly = SammySession(issuer: both.issuer, revocationEndpoint: nil, accessToken: "f", scope: SammyOAuth.scope, subject: "sub")
        await accounts.tookUpSammySessionSignedInAgain(feedsOnly, askedForInbox: false)
        #expect(try await store.isSammyInboxOn(both.accountID))
    }

    @Test func aSessionThatHoldsInboxAddSwitchesOnWithoutAskingAgain() async throws {
        let store = try InfluxStore.inMemory()
        let credentials = InMemoryCredentialStore()
        let session = SammySession(issuer: URL(string: "https://example.com")!, revocationEndpoint: nil, accessToken: "t",
                                   scope: SammyOAuth.inboxScopes, subject: "sub")
        try credentials.save(session, for: session.accountID)
        let accounts = Accounts(store: store, isSample: true, credentials: credentials)
        let inbox = SammyInbox(store: store, accounts: accounts, isSample: true)
        let account = Accounts.Account(id: session.accountID, service: .sammy, name: "Sammy (example.com)", sources: [], isSignedIn: true)
        #expect(await inbox.addsToInbox(account.id))
        await inbox.set(true, for: account)
        #expect(try await store.isSammyInboxOn(account.id))
    }
}
