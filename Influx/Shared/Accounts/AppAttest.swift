// App Attest for the signing service's callers (ADR 0033).
//
// DeviceCheck is linked into the app rather than loaded later like
// InfluxWebSignIn: on macOS 27.2 a SwiftUI app that links it loads one more
// image at launch, DeviceCheck itself, since everything it links is loaded
// already. Nothing here runs until the first Bluesky sign-in or refresh.
import DeviceCheck
import Foundation
import InfluxKit

/// `DCAppAttestService` as InfluxKit's `AppAttestService`.
struct DeviceAppAttest: AppAttestService {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await Self.mapped { try await DCAppAttestService.shared.generateKey() }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await Self.mapped { try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash) }
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await Self.mapped { try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash) }
    }

    /// A key this device no longer has (after a reinstall or a restore)
    /// becomes `AppAttestError.invalidKey`, so a new one is registered.
    private static func mapped<Value>(_ work: () async throws -> Value) async throws -> Value {
        do {
            return try await work()
        } catch let error as DCError where error.code == .invalidKey {
            throw AppAttestError.invalidKey
        }
    }
}

extension CallerAttestation {
    /// The app's one attestation, shared by every Bluesky client (both
    /// Worker hosts keep one key store), so all its requests take turns
    /// with one key. The key ID stays in this device's keychain, apart
    /// from sign-ins and never in iCloud: the key can't leave the device.
    static let app: CallerAttestation = {
        #if canImport(Security)
        let keys: any CredentialStore = KeychainCredentialStore(service: "dev.bespokebits.influx.app-attest")
        #else
        let keys: any CredentialStore = InMemoryCredentialStore()
        #endif
        #if os(iOS)
        let platform = Platform.ios
        #else
        let platform = Platform.mac
        #endif
        return CallerAttestation(
            service: DeviceAppAttest(), keys: keys, http: URLSession.shared, crypto: .system,
            platform: platform, appID: Bundle.main.bundleIdentifier ?? ""
        )
    }()
}
