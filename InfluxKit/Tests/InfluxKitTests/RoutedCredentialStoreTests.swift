import Foundation
import Testing
@testable import InfluxKit

/// An app that shares another app's sign-ins keeps some to itself (ADR
/// 0042): the accounts whose sessions two apps can't both spend.
@Suite struct RoutedCredentials {
    private let shared = InMemoryCredentialStore()
    private let own = InMemoryCredentialStore()
    private let mastodon = "@ana@example.social"
    private let bluesky = "did:plc:example"

    private var store: RoutedCredentialStore {
        RoutedCredentialStore(shared: shared, own: own, isShared: { !$0.hasPrefix("did:") })
    }

    @Test func eachAccountIsKeptInItsOwnStore() throws {
        try store.setData(Data("m".utf8), for: mastodon)
        try store.setData(Data("b".utf8), for: bluesky)
        #expect(try shared.accounts() == [mastodon])
        #expect(try own.accounts() == [bluesky])
        #expect(try store.data(for: mastodon) == Data("m".utf8))
        #expect(try store.data(for: bluesky) == Data("b".utf8))
    }

    /// The shared store is the other app's too, so it also holds that app's
    /// own session for the same account. This app never reads or lists it.
    @Test func theOtherAppsOwnSessionIsNeverReadOrListed() throws {
        try shared.setData(Data("theirs".utf8), for: bluesky)
        try shared.setData(Data("m".utf8), for: mastodon)
        #expect(try store.data(for: bluesky) == nil)
        #expect(try store.accounts() == [mastodon])
        try store.setData(Data("ours".utf8), for: bluesky)
        #expect(try shared.data(for: bluesky) == Data("theirs".utf8))
        #expect(try store.accounts().sorted() == [mastodon, bluesky].sorted())
    }

    @Test func signingOutLeavesTheOtherAppsSessionAlone() throws {
        try shared.setData(Data("theirs".utf8), for: bluesky)
        try store.setData(Data("ours".utf8), for: bluesky)
        try store.setData(Data("m".utf8), for: mastodon)
        try store.deleteData(for: bluesky)
        try store.deleteData(for: mastodon)
        #expect(try own.accounts().isEmpty)
        #expect(try shared.accounts() == [bluesky])
        #expect(try shared.data(for: bluesky) == Data("theirs".utf8))
    }
}
