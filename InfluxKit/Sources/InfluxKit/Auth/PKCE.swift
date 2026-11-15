import Foundation

/// A proof key for one authorization request (RFC 7636), S256 only. A new
/// one is made for every sign-in and never reused.
public struct PKCE: Sendable, Hashable, Codable {
    /// Sent with the token request.
    public let verifier: String
    /// Sent with the authorization request: base64url(SHA-256(verifier)).
    public let challenge: String
    public var method: String { "S256" }

    public init(crypto: OAuthCrypto) {
        // 32 random bytes give a 43-character verifier, the shortest allowed.
        self.init(verifier: crypto.randomToken(bytes: 32), crypto: crypto)
    }

    init(verifier: String, crypto: OAuthCrypto) {
        self.verifier = verifier
        challenge = crypto.sha256(Data(verifier.utf8)).base64URLEncoded
    }
}
