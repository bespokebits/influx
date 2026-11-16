// Makes Influx Preview's app icons from Influx's (ADR 0042): the same
// drawing with the paper turned amber, so the two apps are told apart at a
// glance. Run from the repository root after the Influx icons change:
//
//   swift scripts/preview-icon.swift
//
// It writes the AppIconPreview sets beside the AppIcon sets. Each pixel is
// read as a blend of the paper with one of the drawing's other colours, and
// the paper's share is repainted, so edges stay smooth. A pixel that is no
// such blend (the Mac icon's shadow) is left as it is.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

typealias RGB = SIMD3<Double>

func rgb(_ hex: UInt32) -> RGB {
    RGB(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
}

func length(_ v: RGB) -> Double { (v * v).sum().squareRoot() }

/// `from` (the paper) becomes `to`; `others` are the colours it meets.
/// `fromRow` leaves the rows above it alone, counted from the top.
struct Recolour {
    var from: RGB
    var to: RGB
    var others: [RGB]
    var fromRow = 0

    func apply(_ p: RGB) -> RGB {
        var best: (residual: Double, share: Double, other: RGB)?
        for other in others {
            let axis = other - from
            let share = min(1, max(0, ((p - from) * axis).sum() / (axis * axis).sum()))
            let residual = length(p - (from + axis * share))
            if best == nil || residual < best!.residual { best = (residual, share, other) }
        }
        guard let best, best.residual < 14 else { return p }
        return to + (best.other - to) * best.share
    }
}

func recoloured(_ source: URL, _ recolour: Recolour, size: Int? = nil) -> CGImage {
    let image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(source as CFURL, nil)!, 0, nil)!
    let width = image.width, height = image.height
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: space, bitmapInfo: info)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let pixels = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
    for i in stride(from: recolour.fromRow * width * 4, to: width * height * 4, by: 4) {
        let alpha = Double(pixels[i + 3]) / 255
        guard alpha > 0 else { continue }
        let straight = RGB(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])) / alpha
        let painted = recolour.apply(straight) * alpha
        for c in 0..<3 { pixels[i + c] = UInt8(min(255, max(0, painted[c].rounded()))) }
    }
    let full = context.makeImage()!
    guard let size, size != width else { return full }
    let small = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4, space: space, bitmapInfo: info)!
    small.interpolationQuality = .high
    small.draw(full, in: CGRect(x: 0, y: 0, width: size, height: size))
    return small.makeImage()!
}

func write(_ image: CGImage, to url: URL, opaque: Bool) {
    var image = image
    if opaque {
        // The iPhone icons carry no alpha channel, and App Store Connect refuses one.
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let flat = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        flat.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        image = flat.makeImage()!
    }
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "could not write \(url.path)")
}

let amber = rgb(0xF4C542)
let slips = [rgb(0x7B61FF), rgb(0x2B8CFF), rgb(0xEE7F2E)]
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default

// iPhone: paper behind an ink tray; in the dark icon, a paper tray on ink.
// The system colours the tinted icon, which is all greys, so there the
// tray alone is greyed, by its rows: its white can't be told from a slip's.
let ios = root.appending(path: "Influx/iOS/Assets.xcassets")
let iosOut = ios.appending(path: "AppIconPreview.appiconset")
try fm.createDirectory(at: iosOut, withIntermediateDirectories: true)
try? fm.removeItem(at: iosOut.appending(path: "Contents.json"))
try fm.copyItem(at: ios.appending(path: "AppIcon.appiconset/Contents.json"), to: iosOut.appending(path: "Contents.json"))
let iosIcons: [(String, Recolour)] = [
    ("AppIcon.png", Recolour(from: rgb(0xF7F4ED), to: amber, others: slips + [rgb(0x1D1B17)])),
    ("AppIcon-dark.png", Recolour(from: rgb(0xEEEAE2), to: amber, others: [rgb(0x1A1916)])),
    ("AppIcon-tinted.png", Recolour(from: rgb(0xFFFFFF), to: rgb(0x8C8C8C), others: [rgb(0x000000)], fromRow: 560)),
]
for (name, recolour) in iosIcons {
    write(recoloured(ios.appending(path: "AppIcon.appiconset/\(name)"), recolour), to: iosOut.appending(path: name), opaque: true)
}

// Mac: every size from the largest, repainted and then scaled.
let mac = root.appending(path: "Influx/macOS/Assets.xcassets")
let macOut = mac.appending(path: "AppIconPreview.appiconset")
try fm.createDirectory(at: macOut, withIntermediateDirectories: true)
try? fm.removeItem(at: macOut.appending(path: "Contents.json"))
try fm.copyItem(at: mac.appending(path: "AppIcon.appiconset/Contents.json"), to: macOut.appending(path: "Contents.json"))
let macPaper = Recolour(from: rgb(0xF7F4ED), to: amber, others: slips + [rgb(0x1C1C16)])
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let image = recoloured(mac.appending(path: "AppIcon.appiconset/AppIcon-1024.png"), macPaper, size: size)
    write(image, to: macOut.appending(path: "AppIcon-\(size).png"), opaque: false)
}
print("wrote \(iosOut.path) and \(macOut.path)")
