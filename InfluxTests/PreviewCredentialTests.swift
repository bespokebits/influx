import Foundation
import Testing
import InfluxKit
@testable import Influx

/// Influx Preview shares Influx's keychain group, and keeps to itself what
/// two apps can't share (ADR 0042).
@MainActor @Suite struct PreviewCredentials {
    @Test func anAppWithNoServiceOfItsOwnKeepsEverySignInTogether() {
        #expect(Accounts.keychain(ownService: nil) is KeychainCredentialStore)
    }

    @Test func blueskySignInsGoToTheAppsOwnServiceAndTheRestStayShared() throws {
        let store = try #require(Accounts.keychain(ownService: "example.preview.credentials") as? RoutedCredentialStore)
        #expect((store.own as? KeychainCredentialStore)?.service == "example.preview.credentials")
        // Never in iCloud Keychain: the session is this app's on this device.
        #expect((store.own as? KeychainCredentialStore)?.synchronizes == false)
        #expect((store.shared as? KeychainCredentialStore)?.service == KeychainCredentialStore().service)
        #expect(!store.isShared("did:plc:example"))
        #expect(store.isShared("@ana@example.social"))
        #expect(store.isShared("subject@example.com"))
    }

    /// A key works only in the app that made it, so each app looks for its
    /// key ID under its own name. Influx's is what it has always been.
    @Test func eachAppKeepsItsAttestationKeyUnderItsOwnName() {
        #expect(CallerAttestation.keyService(bundleID: "dev.bespokebits.influx") == "dev.bespokebits.influx.app-attest")
        #expect(CallerAttestation.keyService(bundleID: "dev.bespokebits.influx.preview") == "dev.bespokebits.influx.preview.app-attest")
        #expect(CallerAttestation.keyService(bundleID: nil) == "dev.bespokebits.influx.app-attest")
    }
}

/// Influx and Influx Preview send field performance reports; the builds
/// that never ship through TestFlight don't (ADR 0034, 0042).
@MainActor @Test func onlyTheAppsThatShipThroughTestFlightReportPerformance() {
    #expect(FieldPerformance.reports(bundleID: "dev.bespokebits.influx"))
    #expect(FieldPerformance.reports(bundleID: "dev.bespokebits.influx.preview"))
    for other in ["dev.bespokebits.influx.dev", "dev.bespokebits.influx.uitest", "dev.bespokebits.influx.perf", nil] {
        #expect(!FieldPerformance.reports(bundleID: other))
    }
}
