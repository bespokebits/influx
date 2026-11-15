import Foundation

/// An image's pixel size, read from the first bytes of its file without
/// decoding it: enough to size a row before the image itself arrives.
enum ImageSize {
    /// How many leading bytes to fetch. JPEG puts its size after its
    /// metadata, which is usually well under this.
    static let prefixLength = 64 * 1024

    /// The displayed width and height for PNG, GIF, JPEG and WebP, or nil
    /// for anything else or a prefix cut off too early. A JPEG whose EXIF
    /// rotates it a quarter turn reports its sides swapped, as it is shown.
    static func parse(_ data: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](data.prefix(prefixLength))
        let size: (Int, Int)?
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            size = png(bytes)
        } else if bytes.starts(with: Array("GIF8".utf8)) {
            size = gif(bytes)
        } else if bytes.starts(with: [0xFF, 0xD8]) {
            size = jpeg(bytes)
        } else if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)), Array(bytes[8..<12]) == Array("WEBP".utf8) {
            size = webp(bytes)
        } else {
            size = nil
        }
        guard let (width, height) = size, width > 0, height > 0 else { return nil }
        return (width, height)
    }

    private static func png(_ b: [UInt8]) -> (Int, Int)? {
        // Signature, then the IHDR chunk: length, "IHDR", width, height.
        guard b.count >= 24, Array(b[12..<16]) == Array("IHDR".utf8) else { return nil }
        return (Int(be32(b, 16)), Int(be32(b, 20)))
    }

    private static func gif(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count >= 10 else { return nil }
        return (Int(le16(b, 6)), Int(le16(b, 8)))
    }

    private static func jpeg(_ b: [UInt8]) -> (Int, Int)? {
        var i = 2
        var rotated = false
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            let marker = b[i + 1]
            if marker == 0xFF {
                i += 1
                continue
            }
            // Markers without a length.
            if marker == 0x01 || (0xD0...0xD7).contains(marker) {
                i += 2
                continue
            }
            let length = Int(be16(b, i + 2))
            guard length >= 2 else { return nil }
            let segment = i + 4
            if marker == 0xE1, segment + length - 2 <= b.count {
                rotated = exifRotatesQuarterTurn(Array(b[segment..<(segment + length - 2)])) ?? rotated
            }
            // Start of frame: every SOFn except DHT (C4), JPG (C8) and DAC (CC).
            if (0xC0...0xCF).contains(marker), ![0xC4, 0xC8, 0xCC].contains(marker) {
                guard segment + 5 <= b.count else { return nil }
                let height = Int(be16(b, segment + 1))
                let width = Int(be16(b, segment + 3))
                return rotated ? (height, width) : (width, height)
            }
            i = segment + length - 2
        }
        return nil
    }

    /// Whether an EXIF block's orientation is one of the four (5 to 8) that
    /// turn the image on its side; nil when it says nothing.
    private static func exifRotatesQuarterTurn(_ e: [UInt8]) -> Bool? {
        guard e.count >= 14, e.starts(with: Array("Exif".utf8) + [0, 0]) else { return nil }
        let tiff = 6
        let little: Bool
        switch (e[tiff], e[tiff + 1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return nil
        }
        func u16(_ at: Int) -> Int? { at + 2 <= e.count ? Int(little ? le16(e, at) : be16(e, at)) : nil }
        func u32(_ at: Int) -> Int? { at + 4 <= e.count ? Int(little ? le32(e, at) : be32(e, at)) : nil }
        guard let ifd = u32(tiff + 4), let count = u16(tiff + ifd) else { return nil }
        for entry in 0..<count {
            let at = tiff + ifd + 2 + entry * 12
            guard let tag = u16(at) else { return nil }
            if tag == 0x0112, let value = u16(at + 8) {
                return (5...8).contains(value)
            }
        }
        return nil
    }

    private static func webp(_ b: [UInt8]) -> (Int, Int)? {
        guard b.count >= 30 else { return nil }
        switch String(decoding: b[12..<16], as: UTF8.self) {
        case "VP8 ":
            // Lossy: a key frame's start code, then 14-bit width and height.
            guard b[23] == 0x9D, b[24] == 0x01, b[25] == 0x2A else { return nil }
            return (Int(le16(b, 26) & 0x3FFF), Int(le16(b, 28) & 0x3FFF))
        case "VP8L":
            // Lossless: a signature byte, then width - 1 and height - 1 in 14 bits each.
            guard b[20] == 0x2F else { return nil }
            let bits = le32(b, 21)
            return (Int(bits & 0x3FFF) + 1, Int((bits >> 14) & 0x3FFF) + 1)
        case "VP8X":
            // Extended: 24-bit canvas width - 1 and height - 1.
            return (Int(le24(b, 24)) + 1, Int(le24(b, 27)) + 1)
        default:
            return nil
        }
    }

    private static func be16(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i]) << 8 | UInt32(b[i + 1]) }
    private static func le16(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i + 1]) << 8 | UInt32(b[i]) }
    private static func le24(_ b: [UInt8], _ i: Int) -> UInt32 { UInt32(b[i + 2]) << 16 | le16(b, i) }
    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 { be16(b, i) << 16 | be16(b, i + 2) }
    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 { le16(b, i + 2) << 16 | le16(b, i) }
}
