import Foundation
import Testing
import InfluxKit
@testable import Influx

// The alert for accounts that need signing in again.
private let since = Date(timeIntervalSince1970: 1_793_070_660) // 27 Oct 2026 03:11 UTC

private func account(signedIn: Bool = true, sources: [Source]) -> Accounts.Account {
    Accounts.Account(id: "did:plc:ana", service: .bluesky, name: "@ana.bsky.social", sources: sources, isSignedIn: signedIn)
}

private let following = Source(id: "bluesky:did:plc:ana:following", kind: .blueskyFollowing, accountID: "did:plc:ana", title: "Following", colorIndex: 0)
private let feed = Source(id: "bluesky:did:plc:ana:feed", kind: .blueskyFeed, accountID: "did:plc:ana", title: "Feed", colorIndex: 0)

private func state(_ source: Source, _ problem: SourceProblem?, since date: Date? = nil) -> SourceFetchState {
    var state = SourceFetchState(sourceID: source.id)
    state.problem = problem
    state.problemSince = date
    return state
}

@Test func anAccountNeedsSigningInWhenASourceIsSignedOutOrItHasNoSignInHere() {
    let fine = [following.id: state(following, nil), feed.id: state(feed, .offline)]
    #expect(!account(sources: [following, feed]).needsSignIn(fine))
    #expect(account(signedIn: false, sources: [following]).needsSignIn([:]))
    let refused = [following.id: state(following, nil), feed.id: state(feed, .signedOut, since: since)]
    #expect(account(sources: [following, feed]).needsSignIn(refused))
    #expect(account(sources: [following, feed]).signedOutSince(refused) == since)
}

@Test func anAccountWithNoSignInHereMissedPostsSinceItLastFetched() {
    var fetched = state(following, nil)
    fetched.lastSuccessAt = since
    #expect(account(signedIn: false, sources: [following]).signedOutSince([following.id: fetched]) == since)
    // A refusal says it better when there is one.
    let refusedLater = since.addingTimeInterval(600)
    var refused = state(following, .signedOut, since: refusedLater)
    refused.lastSuccessAt = since
    #expect(account(signedIn: false, sources: [following]).signedOutSince([following.id: refused]) == refusedLater)
    #expect(account(sources: [following]).signedOutSince([following.id: fetched]) == nil)
}

@Test func accountNamesAreRememberedForAccountsWithNoSignInHere() throws {
    let defaults = try #require(UserDefaults(suiteName: "AccountNamesTests-\(UUID().uuidString)"))
    let names = AccountNames(defaults: defaults)
    #expect(names.all().isEmpty)
    names.remember(["did:plc:ana": "@ana.bsky.social"])
    names.remember(["42@sammy.example": "ana on sammy.example"])
    names.remember(["did:plc:ana": "@ana.example"])
    #expect(names.all() == ["did:plc:ana": "@ana.example", "42@sammy.example": "ana on sammy.example"])
}

@Test func theAlertNamesTheAccountAndWhenItsPostsStopped() {
    #expect(SignInAlert.headline(service: "Bluesky", name: "@ana.bsky.social", signedOut: true) == "Bluesky @ana.bsky.social is signed out.")
    #expect(SignInAlert.headline(service: "Bluesky", name: "@ana.bsky.social", signedOut: false) == "Bluesky @ana.bsky.social isn't signed in on this device.")
    #expect(SignInAlert.detail(since: nil) == "Its posts aren't coming in.")
    #expect(SignInAlert.detail(since: since).hasPrefix("You've missed its posts since "))
}

@Test func signingInAsAnotherAccountSaysWhichToUse() {
    let message = signInAgainMessage(for: SignInAgainError.differentAccount("@bob.bsky.social"), account: account(sources: [following]))
    #expect(message == "That's @bob.bsky.social. Sign in as @ana.bsky.social to fix this account.")
}

@Test func mastodonAndSammySignInsSyncAndBlueskysDoNot() {
    #expect(Accounts.isMastodonID("@ana@mastodon.social"))
    #expect(!Accounts.isMastodonID("did:plc:ana"))
    #expect(!Accounts.isMastodonID("42@sammy.example"))
    #expect(Accounts.syncsCredentials("@ana@mastodon.social"))
    #expect(Accounts.syncsCredentials("AbCdEf@sammy.example"))
    #expect(!Accounts.syncsCredentials("did:plc:ana"))
    #expect(!Accounts.syncsCredentials("did:web:ana.example"))
}

@MainActor
@Test func aRefusedActionPointsAtSignInAgain() {
    let message = RowInteractions.message(for: ConnectorError.unauthorized, verb: "remove the bookmark")
    #expect(message.contains("signed out"))
    #expect(message.contains("Sign in again"))
}

@MainActor
@Test func rootViewBuildsWithSignedOutSampleAccounts() {
    UserDefaults.standard.register(defaults: ["InfluxSampleSignedOut": true])
    defer { UserDefaults.standard.register(defaults: ["InfluxSampleSignedOut": false]) }
    _ = RootView(app: .sample(count: 20)).body
}

#if os(macOS)
import AppKit

/// The Mac's refused-action notice draws inside the timeline, in front of
/// the rows, and stays long enough to read.
@MainActor
@Test func theMacActionNoticeShowsInFrontOfTheTimeline() async throws {
    let controller = TimelineViewController(app: .sample(count: 20), viewID: "all", jumps: TimelineJumps(), items: TimelineItems())
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.makeKeyAndOrderFront(nil)
    defer {
        controller.tearDown()
        window.close()
    }
    controller.showNotice("Couldn't remove the bookmark: this account is signed out. Use Sign in again at the top.")
    controller.view.layoutSubtreeIfNeeded()
    let notice = controller.notice
    #expect(!notice.isHidden)
    #expect(notice.alphaValue == 1)
    #expect(notice.frame.height >= 20)
    #expect(controller.view.bounds.contains(notice.frame))
    // In front of the scroll view, so no row covers it.
    let siblings = try #require(notice.superview?.subviews)
    let scroll = try #require(siblings.firstIndex { $0 is NSScrollView })
    #expect(try #require(siblings.firstIndex { $0 === notice }) > scroll)
    try await Task.sleep(for: .seconds(4.5))
    #expect(!notice.isHidden)
}
#endif
