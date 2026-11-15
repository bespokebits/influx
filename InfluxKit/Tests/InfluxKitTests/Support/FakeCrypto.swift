import Foundation
@testable import InfluxKit

/// A DPoP key that "signs" by naming itself, so Linux tests can check proofs
/// without CryptoKit.
struct FakeDPoPKey: DPoPKey {
    var name = "key"
    var publicJWK: JWK { JWK(x: "x-\(name)", y: "y-\(name)") }
    var rawRepresentation: Data { Data(name.utf8) }

    func sign(_ message: Data) throws -> Data {
        Data("signed-by-\(name)".utf8)
    }
}

extension OAuthCrypto {
    /// Deterministic stand-ins: the "hash" is a readable prefix plus the
    /// input, and random bytes count up so each token differs.
    static func fake() -> OAuthCrypto {
        let counter = Counter()
        return OAuthCrypto(
            sha256: { Data("sha256:".utf8) + $0 },
            randomBytes: { count in Data(repeating: counter.next(), count: count) },
            newKey: { FakeDPoPKey() },
            restoreKey: { FakeDPoPKey(name: String(decoding: $0, as: UTF8.self)) }
        )
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt8 = 0

    func next() -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        value &+= 1
        return value
    }
}

/// Decodes the parts of a compact JWT.
func decodeJWT<Header: Decodable, Claims: Decodable>(_ jwt: String, _ types: (Header.Type, Claims.Type)) throws -> (Header, Claims, signature: Data) {
    let parts = jwt.split(separator: ".").map(String.init)
    func bytes(_ part: String) -> Data {
        var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)!
    }
    return (
        try JSONDecoder().decode(Header.self, from: bytes(parts[0])),
        try JSONDecoder().decode(Claims.self, from: bytes(parts[1])),
        bytes(parts[2])
    )
}
