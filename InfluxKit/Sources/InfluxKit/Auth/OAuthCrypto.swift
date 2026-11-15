import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The cryptography OAuth needs: hashing, random bytes and DPoP signing
/// keys. The app uses `OAuthCrypto.system`, backed by CryptoKit. InfluxKit also
/// builds on Linux, which has no CryptoKit, so the rest of the OAuth code
/// takes this as a parameter and Linux tests pass a fake.
public struct OAuthCrypto: Sendable {
    public var sha256: @Sendable (Data) -> Data
    public var randomBytes: @Sendable (Int) -> Data
    /// A new P-256 key for DPoP.
    public var newKey: @Sendable () -> any DPoPKey
    /// A key restored from its `rawRepresentation`.
    public var restoreKey: @Sendable (Data) throws -> any DPoPKey

    public init(
        sha256: @escaping @Sendable (Data) -> Data,
        randomBytes: @escaping @Sendable (Int) -> Data,
        newKey: @escaping @Sendable () -> any DPoPKey,
        restoreKey: @escaping @Sendable (Data) throws -> any DPoPKey
    ) {
        self.sha256 = sha256
        self.randomBytes = randomBytes
        self.newKey = newKey
        self.restoreKey = restoreKey
    }

    /// `count` random bytes, base64url-encoded: for PKCE verifiers, state
    /// and DPoP proof IDs.
    func randomToken(bytes count: Int = 32) -> String {
        randomBytes(count).base64URLEncoded
    }
}

/// A private key that signs DPoP proofs (RFC 9449) with ES256.
public protocol DPoPKey: Sendable {
    /// The public half as a JWK, for the proof's header.
    var publicJWK: JWK { get }
    /// The private key's bytes, kept in the keychain with the tokens it is
    /// bound to.
    var rawRepresentation: Data { get }
    /// An ES256 signature of `message`: r and s, 32 bytes each.
    func sign(_ message: Data) throws -> Data
}

/// A public P-256 key in JSON Web Key form.
public struct JWK: Codable, Sendable, Hashable {
    public var kty = "EC"
    public var crv = "P-256"
    public var x: String
    public var y: String

    public init(x: String, y: String) {
        self.x = x
        self.y = y
    }
}

#if canImport(CryptoKit)
extension OAuthCrypto {
    public static let system = OAuthCrypto(
        sha256: { Data(SHA256.hash(data: $0)) },
        randomBytes: { count in
            var generator = SystemRandomNumberGenerator()
            return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        },
        newKey: { P256DPoPKey(signing: P256.Signing.PrivateKey()) },
        restoreKey: { try P256DPoPKey(signing: P256.Signing.PrivateKey(rawRepresentation: $0)) }
    )
}

struct P256DPoPKey: DPoPKey {
    let signing: P256.Signing.PrivateKey

    var publicJWK: JWK {
        // The x9.63 form is 0x04, then x and y, 32 bytes each.
        let point = signing.publicKey.x963Representation
        return JWK(x: point[1..<33].base64URLEncoded, y: point[33..<65].base64URLEncoded)
    }

    var rawRepresentation: Data { signing.rawRepresentation }

    func sign(_ message: Data) throws -> Data {
        try signing.signature(for: message).rawRepresentation
    }
}
#endif

extension DataProtocol {
    /// Base64url without padding (RFC 7515 appendix C).
    var base64URLEncoded: String {
        Data(self).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
