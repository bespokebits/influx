import Foundation

/// How a rich feed names a post the reader already holds from another
/// connector (ADR 0014, 0031): its alias is
/// `urn:uuid:` + lower-case UUIDv5(`namespace`, the exact UTF-8 bytes of
/// the post's native identity). Nothing is trimmed, folded, normalized or
/// percent-coded, so two keys are the same only when their bytes are.
enum LegacyPostIdentity {
    /// The frozen namespace: UUIDv5 of the URL namespace and
    /// `https://example.com/rich-feed/legacy-post-identity/v1`.
    static let namespace: [UInt8] = uuidBytes("dbbccf96-b845-55a8-b336-67a2996b053c")!
    /// RFC 9562's URL namespace, which `namespace` derives from.
    static let urlNamespace: [UInt8] = uuidBytes("6ba7b811-9dad-11d1-80b4-00c04fd430c8")!

    /// The alias of a native post identity, or nil for an empty one.
    static func alias(of identity: String) -> String? {
        alias(bytes: Array(identity.utf8))
    }

    /// The alias of a native identity given as UTF-16 code units, or nil
    /// when they are empty or not valid UTF-16 (a lone surrogate), which
    /// have no exact UTF-8 bytes. Nothing is repaired.
    static func alias(utf16 units: [UInt16]) -> String? {
        guard let identity = String(validating: units, as: UTF16.self) else { return nil }
        return alias(of: identity)
    }

    static func alias(bytes: [UInt8]) -> String? {
        guard !bytes.isEmpty else { return nil }
        return "urn:uuid:" + uuidV5(namespace: namespace, name: bytes)
    }

    /// RFC 9562 UUIDv5 of `name` in `namespace`, lower-case.
    static func uuidV5(namespace: [UInt8], name: [UInt8]) -> String {
        var bytes = Array(SHA1.hash(namespace + name).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return groups.joined(separator: "-")
    }

    /// The 16 bytes of a UUID written `8-4-4-4-12`.
    static func uuidBytes(_ text: String) -> [UInt8]? {
        let hex = Array(text.utf8.filter { $0 != UInt8(ascii: "-") })
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(decoding: hex[index..<index + 2], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        return bytes
    }
}

/// SHA-1 (FIPS 180-4), for UUIDv5 only: the derivation is fixed by the
/// rich feed contract, and it is no security boundary. InfluxKit builds on
/// Linux, which has no CryptoKit, and a package for one hash would need an
/// ADR of its own.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: (UInt32, UInt32, UInt32, UInt32, UInt32) = (0x6745_2301, 0xEFCD_AB89, 0x98BA_DCFE, 0x1032_5476, 0xC3D2_E1F0)
        var padded = message
        padded.append(0x80)
        while padded.count % 64 != 56 { padded.append(0) }
        let bits = UInt64(message.count) &* 8
        for shift in stride(from: 56, through: 0, by: -8) { padded.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift))) }

        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: padded.count, by: 64) {
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(padded[b]) << 24 | UInt32(padded[b + 1]) << 16 | UInt32(padded[b + 2]) << 8 | UInt32(padded[b + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, b, c, d, e) = h
            for i in 0..<80 {
                let f: UInt32, k: UInt32
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A82_7999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9_EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62_C1D6)
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotl(b, 30), a, t)
            }
            h = (h.0 &+ a, h.1 &+ b, h.2 &+ c, h.3 &+ d, h.4 &+ e)
        }
        return [h.0, h.1, h.2, h.3, h.4].flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (24 - 8 * UInt32($0))) } }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }
}
