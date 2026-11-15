import Foundation
import Testing
@testable import InfluxKit

@Suite struct SharedAuth {
    @Test func pkceChallengeIsTheHashedVerifier() {
        let crypto = OAuthCrypto.fake()
        let pkce = PKCE(crypto: crypto)
        // 32 random bytes make a 43-character verifier, the shortest allowed.
        #expect(pkce.verifier.count == 43)
        #expect(pkce.challenge == crypto.sha256(Data(pkce.verifier.utf8)).base64URLEncoded)
        #expect(pkce.method == "S256")
        #expect(PKCE(crypto: crypto).verifier != pkce.verifier)
    }

    #if canImport(CryptoKit)
    @Test func pkceMatchesRFC7636() {
        // RFC 7636, appendix B.
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", crypto: .system)
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    #endif

    @Test func credentialStoreKeepsOneValuePerAccount() throws {
        struct Secret: Codable, Equatable { var token: String }
        let store = InMemoryCredentialStore()
        try store.save(Secret(token: "a"), for: "@me@example.social")
        try store.save(Secret(token: "b"), for: "did:plc:me")
        try store.save(Secret(token: "c"), for: "@me@example.social")
        #expect(try store.load(Secret.self, for: "@me@example.social") == Secret(token: "c"))
        #expect(try store.load(Secret.self, for: "did:plc:me") == Secret(token: "b"))
        try store.delete(for: "@me@example.social")
        #expect(try store.load(Secret.self, for: "@me@example.social") == nil)
        #expect(try store.load(Secret.self, for: "did:plc:me") == Secret(token: "b"))
    }
}
