import SwiftUI
import Testing
import InfluxKit
@testable import Influx

// SwiftUI views are main-actor isolated, so the smoke test runs there too.
@MainActor
@Test func rootViewBuilds() {
    _ = RootView(app: .sample(count: 20)).body
}

@Test func versionLineShowsTheCommitWhenThereIsOne() {
    let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"]
    #expect(BuildInfo.versionLine(info: info) == "0.1.0 (1)")
    #expect(BuildInfo.versionLine(info: info.merging(["InfluxCommit": ""]) { $1 }) == "0.1.0 (1)")
    #expect(BuildInfo.versionLine(info: info.merging(["InfluxCommit": "5e8404a"]) { $1 }) == "0.1.0 (1) · 5e8404a")
}

/// Refresh on a sample run adds newer sample rows rather than going to the
/// network, so UI tests can pull to refresh.
@MainActor
@Test func refreshOnASampleRunAddsNewerRows() async throws {
    let app = AppModel.sample(count: 20)
    // The sample goes in as one insert. Its boosts merge into their posts'
    // rows, so it makes fewer than 20 rows; a newer batch has no boosts.
    var seeded = 0
    for _ in 0..<500 where seeded == 0 {
        seeded = try await app.store.rows().count
        if seeded == 0 { try await Task.sleep(for: .milliseconds(10)) }
    }
    try #require(seeded > 0)
    await app.refreshNow()
    #expect(try await app.store.rows().count == seeded + 20)
}

@Test func aBuildTheSigningServiceRefusesSaysToUpdate() {
    let message = signInMessage(for: BlueskyError.appNotAccepted)
    #expect(message.hasPrefix("This version of Influx can't sign in to Bluesky. Update the app"))
    #expect(signInAgainMessage(for: BlueskyError.appNotAccepted, account: Accounts.Account(
        id: "did:plc:ana", service: .bluesky, name: "@ana.example.com", sources: [], isSignedIn: true
    )) == message)
}

@Test func mastodonSignInSaysSoWhenTheServerDoesNotAnswer() {
    #expect(signInMessage(for: MastodonSignInError.timedOut).contains("didn't answer"))
}

@Test func sammySignInSaysWhatWentWrongInPlainWords() {
    #expect(signInMessage(for: SammySignInError.notASammyServer("no feeds:read scope")).contains("doesn't look like a Sammy server"))
    #expect(signInMessage(for: SammySignInError.notAnAddress).contains("doesn't look like a Sammy server"))
    #expect(signInMessage(for: SammySignInError.timedOut).contains("didn't answer"))
    #expect(signInMessage(for: SammySignInError.callback(.denied("access_denied"))) == "The server didn't allow the sign-in.")
    #expect(signInMessage(for: SammySignInError.callback(.stateMismatch)) == "The sign-in didn't finish. Try again.")
    #expect(signInMessage(for: SammySignInError.callback(.issuerMismatch)) == "The sign-in didn't finish. Try again.")
    #expect(signInMessage(for: SammySignInError.callback(.missingCode)) == "The sign-in didn't finish. Try again.")
    #expect(signInMessage(for: SammySignInError.failed(.offline)).contains("Couldn't reach"))
    #expect(signInMessage(for: SammySignInError.failed(.rateLimited(retryAfter: nil))).contains("busy"))
    // What a refused code exchange (`invalid_grant`) becomes.
    #expect(signInMessage(for: SammySignInError.failed(.unauthorized)) == "That server didn't accept the sign-in. Try again.")
    #expect(signInMessage(for: SammySignInError.failed(.notFound)).contains("didn't accept the sign-in ("))
    #expect(signInMessage(for: SammySignInError.couldNotStore("x")).contains("couldn't save the sign-in"))
}

private func sammyFeed(_ feedID: String, account: String = "1@sammy.example") -> Source {
    Source(
        id: SammyFeedConnector.sourceID(accountID: account, feedID: feedID), kind: .sammyFeed, accountID: account,
        title: feedID, url: "https://sammy.example/feeds/\(feedID).json", colorIndex: 0
    )
}

@MainActor
@Test func switchingAFeedOffAndOnAgainLeavesItOn() async throws {
    let store = try InfluxStore.inMemory()
    let a = sammyFeed("a"), b = sammyFeed("b")
    try await store.save(sources: [a, b])
    let accounts = Accounts(store: store, isSample: true)
    // Switching off is held up once it has started, as a load or a refresh
    // can hold it, until switching on has been asked for. Unless that waits
    // for it, switching on lands first and switching off undoes it.
    let (held, release) = AsyncStream<Void>.makeStream()
    accounts.listChangeStarting = { _, added in
        guard !added else { return }
        for await _ in held { break }
    }
    let off = Task { await accounts.setList(a, added: false) }
    let on = Task { await accounts.setList(a, added: true) }
    try await Task.sleep(for: .milliseconds(100))
    release.yield()
    await off.value
    await on.value
    #expect(Set(try await store.sources().map(\.id)) == [a.id, b.id])
}

@MainActor
@Test func aSammyAccountsLastFeedCanBeSwitchedOff() async throws {
    let store = try InfluxStore.inMemory()
    let a = sammyFeed("a")
    try await store.save(sources: [a])
    let accounts = Accounts(store: store, isSample: true)
    await accounts.setList(a, added: false)
    #expect(try await store.sources().isEmpty)
}

@MainActor
@Test func sammyFeedsGroupIntoTheirAccountsAndSigningOutRemovesOnlyThatOnesFeeds() async throws {
    let store = try InfluxStore.inMemory()
    let a = sammyFeed("a"), b = sammyFeed("b"), other = sammyFeed("c", account: "2@sammy.example")
    try await store.save(sources: [a, b, other])
    let accounts = Accounts(store: store, isSample: true)
    await accounts.load()
    #expect(accounts.accounts.map(\.id) == ["1@sammy.example", "2@sammy.example"])
    #expect(accounts.accounts.allSatisfy { $0.service == .sammy })
    #expect(accounts.accounts.map { Set($0.sources.map(\.id)) } == [[a.id, b.id], [other.id]])
    let first = try #require(accounts.accounts.first)
    await accounts.signOut(first)
    #expect(try await store.sources().map(\.id) == [other.id])
    #expect(accounts.accounts.map(\.id) == ["2@sammy.example"])
}

@MainActor
@Test func signingOutRemovesAFeedSwitchedOnSinceTheAccountWasRead() async throws {
    let store = try InfluxStore.inMemory()
    let a = sammyFeed("a"), c = sammyFeed("c")
    try await store.save(sources: [a])
    let accounts = Accounts(store: store, isSample: true)
    await accounts.load()
    // The account as a screen opened before the feed was switched on holds it.
    let shown = try #require(accounts.accounts.first)
    await accounts.setList(c, added: true)
    await accounts.signOut(shown)
    #expect(try await store.sources().isEmpty)
    #expect(accounts.accounts.isEmpty)
}

@MainActor
@Test func aFeedSwitchedOnWhileSigningOutIsNotLeftBehind() async throws {
    let store = try InfluxStore.inMemory()
    let a = sammyFeed("a"), c = sammyFeed("c")
    try await store.save(sources: [a])
    let accounts = Accounts(store: store, isSample: true)
    await accounts.load()
    let account = try #require(accounts.accounts.first)
    // Switching on is held up once it has started, until sign-out has been
    // asked for. Unless sign-out waits for it, it saves its feed after
    // sign-out has removed the account's feeds.
    let (held, release) = AsyncStream<Void>.makeStream()
    accounts.listChangeStarting = { _, added in
        guard added else { return }
        for await _ in held { break }
    }
    let on = Task { await accounts.setList(c, added: true) }
    try await Task.sleep(for: .milliseconds(100))
    let out = Task { await accounts.signOut(account) }
    try await Task.sleep(for: .milliseconds(100))
    release.yield()
    await on.value
    await out.value
    #expect(try await store.sources().isEmpty)
    #expect(accounts.accounts.isEmpty)
}

/// A Sammy session for `1@sammy.example` as the keychain holds it. It has
/// no revocation endpoint, so signing out sends nothing.
private func storeSammySession(in credentials: some CredentialStore) throws {
    let session: [String: Any] = [
        "issuer": "https://sammy.example", "subject": "1", "clientID": "influx",
        "accessToken": "sao_access-1", "scope": "feeds:read",
    ]
    try credentials.setData(JSONSerialization.data(withJSONObject: session), for: "1@sammy.example")
}

@MainActor
@Test func aSammyAccountWithNoFeedsIsListedFromItsCredentialsAndCanBeSignedOutOf() async throws {
    let store = try InfluxStore.inMemory()
    let credentials = InMemoryCredentialStore()
    try storeSammySession(in: credentials)
    // Other services' credentials aren't Sammy accounts.
    try credentials.setData(Data("{}".utf8), for: "@sam@mastodon.example")
    try credentials.setData(Data("{}".utf8), for: "did:plc:example")
    let accounts = Accounts(store: store, isSample: true, credentials: credentials)
    await accounts.load()
    #expect(accounts.accounts.map(\.id) == ["1@sammy.example"])
    let account = try #require(accounts.accounts.first)
    #expect(account.service == .sammy)
    #expect(account.name == "Sammy (sammy.example)")
    #expect(account.isSignedIn)
    #expect(account.sources.isEmpty)
    await accounts.signOut(account)
    #expect(try credentials.data(for: "1@sammy.example") == nil)
    #expect(accounts.accounts.isEmpty)
}

@MainActor
@Test func switchingOffAnAccountsLastSammyFeedOffersToDisconnect() {
    let a = sammyFeed("a"), b = sammyFeed("b"), other = sammyFeed("c", account: "2@sammy.example")
    #expect(Accounts.offersDisconnect(removing: a, added: [a, other]))
    #expect(!Accounts.offersDisconnect(removing: a, added: [a, b]))
}

@MainActor
@Test func sammyFeedRowsSayWhichAreOn() {
    let a = sammyFeed("a"), b = sammyFeed("b"), gone = sammyFeed("gone")
    // A feed gained later shows switched off; one the server no longer
    // lists stays, once, so it can still be switched off.
    let rows = AccountScreen.feedRows(listed: [a, b, a], added: [a, gone], shown: [], keepsUnlisted: true)
    #expect(rows.map(\.source.id) == [a.id, b.id, gone.id])
    #expect(rows.map(\.isAdded) == [true, false, true])
    // A feed switched off while the list loaded stays off.
    let toggled = AccountScreen.feedRows(listed: [a, b], added: [a, gone], shown: [(a, false), (gone, true)], keepsUnlisted: true)
    #expect(toggled.map(\.isAdded) == [false, false, true])
    #expect(AccountScreen.feedRows(listed: [a], added: [a, gone], shown: [], keepsUnlisted: false).map(\.source.id) == [a.id])
}

@MainActor
@Test func signInSheetsSayWhatTheyAreWaitingOn() {
    #expect(Accounts.SignInStep.contactingServer.message == "Contacting the server…")
    #expect(Accounts.SignInStep.inBrowser.message.contains("browser window"))
}

@MainActor
@Test func sammyFeedsAreNamedInTheViewsPicker() {
    let source = Source(id: "sammy:1@sammy.example:a", kind: .sammyFeed, accountID: "1@sammy.example", title: "Picks", colorIndex: 0)
    #expect(source.kindName == "Sammy feed")
    #expect(Accounts.Account.Service.sammy.name == "Sammy")
}
