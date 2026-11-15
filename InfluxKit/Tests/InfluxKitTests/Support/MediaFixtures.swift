import Foundation
@testable import InfluxKit

/// The first bytes of image files, enough for `ImageSize` to read.
enum MediaFixtures {
    static func png(width: UInt32, height: UInt32) -> Data {
        join([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13], ascii("IHDR"), be32(width), be32(height), [8, 6, 0, 0, 0])
    }

    static func gif(width: UInt16, height: UInt16) -> Data {
        join(ascii("GIF89a"), le16(width), le16(height), [0xF7, 0, 0])
    }

    /// A baseline JPEG header, optionally with an EXIF orientation, after
    /// some other segment so the scan has to skip one.
    static func jpeg(width: UInt16, height: UInt16, orientation: UInt16? = nil) -> Data {
        // APP0 (JFIF), 16 bytes.
        let app0 = join([0xFF, 0xE0, 0x00, 0x10], ascii("JFIF"), [0, 1, 1, 0, 0, 1, 0, 1, 0, 0])
        var app1 = Data()
        if let orientation {
            // APP1: "Exif\0\0", a big-endian TIFF header, one IFD entry.
            let entry = join([0x01, 0x12, 0x00, 0x03, 0, 0, 0, 1], be16(orientation), [0, 0])
            let tiff = join(ascii("MM"), [0x00, 0x2A, 0, 0, 0, 8, 0, 1], [UInt8](entry), [0, 0, 0, 0])
            let payload = join(ascii("Exif"), [0, 0], [UInt8](tiff))
            app1 = join([0xFF, 0xE1], be16(UInt16(payload.count + 2)), [UInt8](payload))
        }
        // SOF0: length 17, precision 8, height, width, 3 components.
        let sof = join([0xFF, 0xC0, 0x00, 0x11, 0x08], be16(height), be16(width), [0x03, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
        return join([0xFF, 0xD8], [UInt8](app0), [UInt8](app1), [UInt8](sof))
    }

    static func webpLossy(width: UInt16, height: UInt16) -> Data {
        join(riff("VP8 "), [0, 0, 0, 0x9D, 0x01, 0x2A], le16(width), le16(height))
    }

    static func webpLossless(width: UInt32, height: UInt32) -> Data {
        let bits: UInt32 = (width - 1) | ((height - 1) << 14)
        return join(riff("VP8L"), [0x2F], le32(bits), [0, 0, 0, 0, 0])
    }

    static func webpExtended(width: UInt32, height: UInt32) -> Data {
        join(riff("VP8X"), [0, 0, 0, 0], le24(width - 1), le24(height - 1))
    }

    /// A RIFF WebP header up to the start of the named chunk's data.
    private static func riff(_ chunk: String) -> [UInt8] {
        [UInt8](join(ascii("RIFF"), [0, 0, 0, 0], ascii("WEBP"), ascii(chunk), [0, 0, 0, 0]))
    }

    private static func join(_ parts: [UInt8]...) -> Data {
        var data = Data()
        for part in parts { data.append(contentsOf: part) }
        return data
    }

    private static func ascii(_ text: String) -> [UInt8] { Array(text.utf8) }
    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func le24(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF)] }
    private static func le32(_ v: UInt32) -> [UInt8] { le24(v) + [UInt8(v >> 24)] }
}

extension MediaResolver {
    /// A resolver for tests: every host resolves to a public address
    /// unless `addresses` names it.
    static func testing(_ client: any HTTPClient, addresses: [String: [[UInt8]]] = [:], timeout: Duration = .seconds(5)) -> MediaResolver {
        MediaResolver(client: client, addresses: AddressLookup { addresses[$0] ?? [[93, 184, 216, 34]] }, timeout: timeout)
    }
}
