import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Whether an address is on the public internet. Lookups are started by
/// whatever links a post contains, so they must never reach the reader's
/// own device or network.
enum PublicAddress {
    /// A host name that could be public: dotted, plain ASCII, ending in an
    /// alphabetic top-level label, and not a reserved local name. IP
    /// literals in any spelling fail this, since their last label is
    /// numeric or they contain a colon.
    static func isPublicName(_ host: String) -> Bool {
        let name = (host.hasSuffix(".") ? String(host.dropLast()) : host).lowercased()
        guard name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }) else { return false }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let top = labels.last, top.first?.isLetter == true else { return false }
        return !localNames.contains { name == $0 || name.hasSuffix("." + $0) }
    }

    private static let localNames = ["localhost", "local", "localdomain", "internal", "intranet", "lan", "home.arpa", "test", "invalid"]

    /// Whether a resolved IPv4 (4 bytes) or IPv6 (16 bytes) address is
    /// public: not loopback, private, link-local, shared, multicast or
    /// otherwise reserved.
    static func isPublic(_ address: [UInt8]) -> Bool {
        switch address.count {
        case 4:
            return isPublicV4(address)
        case 16:
            let a = address
            // IPv4-mapped (::ffff:0:0/96) and NAT64 (64:ff9b::/96) carry an IPv4 address.
            if a[0..<10].allSatisfy({ $0 == 0 }), a[10] == 0xFF, a[11] == 0xFF {
                return isPublicV4(Array(a[12...]))
            }
            if a[0..<12].elementsEqual([0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) {
                return isPublicV4(Array(a[12...]))
            }
            if a[0..<15].allSatisfy({ $0 == 0 }) { return false }       // :: and ::1
            if a[0] & 0xFE == 0xFC { return false }                       // fc00::/7 unique local
            if a[0] == 0xFE, a[1] & 0x80 == 0x80 { return false }         // fe80::/10 link-local, fec0::/10 site-local
            if a[0] == 0xFF { return false }                              // multicast
            if a[0..<4].elementsEqual([0x20, 0x01, 0x0D, 0xB8]) { return false } // documentation
            return true
        default:
            return false
        }
    }

    private static func isPublicV4(_ a: [UInt8]) -> Bool {
        switch (a[0], a[1]) {
        case (0, _), (10, _), (127, _): false
        case (100, 64...127): false          // carrier-grade NAT
        case (169, 254): false               // link-local
        case (172, 16...31): false
        case (192, 168): false
        case (192, 0) where a[2] == 0 || a[2] == 2: false
        case (198, 18...19): false           // benchmarking
        case (198, 51) where a[2] == 100: false
        case (203, 0) where a[2] == 113: false
        case (224..., _): false              // multicast and reserved
        default: true
        }
    }

    /// The bytes of an IPv4 or IPv6 address written as text, with or
    /// without brackets or a zone.
    static func parse(_ text: String) -> [UInt8]? {
        var address = text
        if address.hasPrefix("["), address.hasSuffix("]") {
            address = String(address.dropFirst().dropLast())
        }
        if let zone = address.firstIndex(of: "%") {
            address = String(address[..<zone])
        }
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }

    /// The addresses `host` resolves to, or nil when it doesn't resolve.
    /// Blocks while it waits for DNS.
    static func addresses(of host: String) -> [[UInt8]]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }
        var found: [[UInt8]] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let info = node {
            if let address = info.pointee.ai_addr {
                switch info.pointee.ai_family {
                case AF_INET:
                    address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        found.append(withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) })
                    }
                case AF_INET6:
                    address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        found.append(withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) })
                    }
                default:
                    break
                }
            }
            node = info.pointee.ai_next
        }
        return found
    }
}

/// Resolves host names for `MediaResolver`, so tests can answer without DNS.
struct AddressLookup: Sendable {
    var resolve: @Sendable (String) async -> [[UInt8]]?

    /// The system resolver, off the calling thread.
    static let system = AddressLookup { host in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: PublicAddress.addresses(of: host))
            }
        }
    }
}
