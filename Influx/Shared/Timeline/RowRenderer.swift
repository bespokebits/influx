// Draws a whole row (dot, text, link card, media, rule) into one bitmap,
// off the main thread. Cells only swap the finished image into a
// layer, so scrolling never draws text on the main thread. Images that
// haven't loaded yet are drawn as paper and listed in `missing`, and the
// row is drawn again once they land.
import CoreGraphics
import InfluxKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A finished row bitmap. CGImage is immutable, so it is safe to hand across
/// threads.
struct RowImage: @unchecked Sendable {
    let key: String
    let image: CGImage
    /// Media drawn as paper because it wasn't loaded yet.
    let missing: [MediaRequest]
}

enum RowRenderer {
    static func render(_ row: TimelineRow, geometry: RowGeometry, in environment: RowEnvironment,
                       media: MediaImages = .shared) -> RowImage? {
        let scale = environment.scale
        let pixelWidth = Int((geometry.width * scale).rounded(.up))
        let pixelHeight = Int((geometry.height * scale).rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        func makeContext(in name: CFString) -> CGContext? {
            CGColorSpace(name: name).flatMap {
                CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: $0,
                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            }
        }
        // A window's space that 8-bit RGB can't draw in falls back to sRGB.
        guard let context = makeContext(in: environment.colorSpace as CFString) ?? makeContext(in: CGColorSpace.sRGB)
        else { return nil }
        // Top-left origin in points, like the views it replaces.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)

        var missing: [MediaRequest] = []
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        UITraitCollection(userInterfaceStyle: environment.dark ? .dark : .light).performAsCurrent {
            draw(row, geometry: geometry, type: environment.typography, scale: scale, media: media, missing: &missing, in: context)
        }
        UIGraphicsPopContext()
        #else
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        NSAppearance(named: environment.dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            draw(row, geometry: geometry, type: environment.typography, scale: scale, media: media, missing: &missing, in: context)
        }
        NSGraphicsContext.current = previous
        #endif

        return context.makeImage().map { RowImage(key: row.mergeKey, image: $0, missing: missing) }
    }

    private static func draw(_ row: TimelineRow, geometry: RowGeometry, type: Typography, scale: CGFloat,
                             media: MediaImages, missing: inout [MediaRequest], in context: CGContext) {
        let hairline = 1 / scale
        // Fill colours resolve inside the appearance block the caller set up.
        func fill(_ rect: CGRect, _ color: PlatformColor, oval: Bool = false) {
            context.setFillColor(color.cgColor)
            if oval { context.fillEllipse(in: rect) } else { context.fill(rect) }
        }

        let sourceColor = Broadsheet.sourceColor(row.colorIndex)

        fill(CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height), Broadsheet.paper)
        fill(geometry.dot, sourceColor, oval: true)
        text(RowText.headerName(row, type, withHandle: geometry.handle == nil), in: geometry.header)
        text(RowText.time(row, type), in: geometry.time)
        if let frame = geometry.handle { text(RowText.handle(row, type), in: frame) }
        if let frame = geometry.context { text(RowText.context(row, type), in: frame) }
        if let frame = geometry.badge, let badge = row.badge {
            // A capsule in the tone's colour, the score centred in it.
            context.setFillColor(Broadsheet.badgeColor(badge.tone).cgColor)
            context.addPath(CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil))
            context.fillPath()
            text(RowText.badge(row, type), in: frame.insetBy(dx: RowLayout.badgePadding.width, dy: RowLayout.badgePadding.height))
        }
        if let frame = geometry.title { text(RowText.title(row, type), in: frame) }
        text(RowText.body(row, type), in: geometry.body)

        /// Draws `item`'s image, or its still for a gif or video, filling
        /// `frame`; paper until it has loaded, including while a failed
        /// load waits to be tried again.
        func picture(_ item: Item.Media, in frame: CGRect) {
            fill(frame, Broadsheet.wash)
            guard let url = item.kind == .image ? item.url : item.previewURL else { return }
            let request = MediaRequest(url: url, pixels: MediaGrid.decodeSize(pixelWidth: item.width, pixelHeight: item.height,
                                                                              filling: frame.size, scale: scale))
            if let image = media.image(for: request) {
                draw(image, filling: frame, in: context)
            } else {
                missing.append(request)
            }
        }

        /// Draws a profile picture in a circle filling `frame`: wash while
        /// it loads, and the row's monogram on its source colour when there
        /// is none or its last load failed.
        func avatar(_ url: String?, in frame: CGRect, monogram: String?) {
            if let url {
                // Avatars are near enough square; their size isn't stored.
                let pixels = (Int((frame.width * scale).rounded(.up)) + 63) / 64 * 64
                let request = MediaRequest(url: url, pixels: pixels, avatar: true)
                if let image = media.image(for: request) {
                    context.saveGState()
                    context.addEllipse(in: frame)
                    context.clip()
                    fill(frame, Broadsheet.wash)
                    draw(image, filling: frame, in: context)
                    context.restoreGState()
                    return
                }
                missing.append(request)
                if !media.hasFailed(request) {
                    fill(frame, Broadsheet.wash, oval: true)
                    return
                }
            }
            fill(frame, sourceColor.withAlphaComponent(0.85), oval: true)
            guard let monogram else { return }
            let font = PlatformFont.systemFont(ofSize: (frame.height * 0.45).rounded(), weight: .semibold)
            let letter = NSAttributedString(string: monogram, attributes: [.font: font, .foregroundColor: PlatformColor.white])
            let size = letter.size()
            letter.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }

        avatar(row.authorAvatar, in: geometry.avatar, monogram: RowText.monogram(row))
        if let frame = geometry.boosterAvatar {
            avatar(row.boosterAvatar, in: frame, monogram: nil)
        }

        if let link = row.linkCard, let frame = geometry.link {
            fill(frame, Broadsheet.wash)
            if let image = link.image, let imageFrame = geometry.linkImage {
                picture(image, in: imageFrame)
            }
            if let site = geometry.linkSite { text(RowText.linkSite(link, type), in: site) }
            if let title = geometry.linkTitle { text(RowText.linkTitle(link, type), in: title) }
            if let summary = geometry.linkSummary { text(RowText.linkSummary(link, type), in: summary) }
        }

        for (index, (item, frame)) in zip(row.media, geometry.media).enumerated() {
            picture(item, in: frame)
            switch item.kind {
            case .image: break
            case .video:
                if VideoPlayback.canPlay(item) { playBadge(in: frame, context: context) }
            case .gif:
                if VideoPlayback.canPlay(item) { playBadge(in: frame, context: context) }
                label("GIF", font: type.meta, in: frame, context: context)
            }
            let hidden = row.media.count - geometry.media.count
            if hidden > 0, index == geometry.media.count - 1 {
                fill(frame, PlatformColor.black.withAlphaComponent(0.45))
                let more = NSAttributedString(string: "+\(hidden)", attributes: [.font: type.title, .foregroundColor: PlatformColor.white])
                let size = more.size()
                more.draw(at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
            }
        }

        if let quote = row.quote, let frame = geometry.quote {
            // A hairline box, like the rules between rows.
            context.setStrokeColor(Broadsheet.rule.cgColor)
            context.setLineWidth(hairline)
            context.stroke(frame.insetBy(dx: hairline / 2, dy: hairline / 2))
            if let image = quote.image, let imageFrame = geometry.quoteImage { picture(image, in: imageFrame) }
            if let header = geometry.quoteHeader {
                text(quote.isUnavailable ? RowText.quoteUnavailable(type) : RowText.quoteHeader(quote, type), in: header)
            }
            if let body = geometry.quoteBody { text(RowText.quoteBody(quote, type), in: body) }
            if let site = geometry.quoteSite { text(RowText.quoteSite(quote, type), in: site) }
        }

        if let viewer = row.viewer {
            for (action, frame) in zip(RowAction.available(for: row), geometry.actions) {
                let (name, on) = RowText.symbol(action, viewer)
                let color = switch action {
                case .like where on: Broadsheet.liked
                case .boost where on: Broadsheet.boosted
                case _ where on: Broadsheet.ink
                default: Broadsheet.ink2
                }
                symbol(name, color: color, in: frame, scale: scale, context: context)
            }
        }

        fill(CGRect(x: RowLayout.inset, y: geometry.height - hairline,
                    width: geometry.width - RowLayout.inset * 2, height: hairline), Broadsheet.rule)
    }

    /// Draws an SF Symbol in `color`, fitted to `frame` and centred. The
    /// colour is resolved for the appearance the caller set up. The symbol
    /// comes from `SymbolImages`, so CoreUI never draws it here.
    private static func symbol(_ name: String, color: PlatformColor, in frame: CGRect, scale: CGFloat, context: CGContext) {
        guard let symbol = SymbolImages.shared.image(name, color: color.cgColor, pointSize: frame.height * 0.82, scale: scale)
        else { return }
        let target = fitted(symbol.size, in: frame)
        context.saveGState()
        // The context is flipped to a top-left origin; images draw bottom-up.
        context.translateBy(x: 0, y: target.minY + target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(symbol.image, in: target)
        context.restoreGState()
    }

    /// `size` scaled to fit inside `frame`, centred.
    private static func fitted(_ size: CGSize, in frame: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return frame }
        let fit = min(frame.width / size.width, frame.height / size.height, 1)
        let width = size.width * fit, height = size.height * fit
        return CGRect(x: frame.midX - width / 2, y: frame.midY - height / 2, width: width, height: height)
    }

    /// Draws `image` scaled to cover `frame`, cropped to it and centred.
    private static func draw(_ image: CGImage, filling frame: CGRect, in context: CGContext) {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return }
        let fit = max(frame.width / width, frame.height / height)
        let target = CGRect(x: frame.midX - width * fit / 2, y: frame.midY - height * fit / 2,
                            width: width * fit, height: height * fit)
        context.saveGState()
        context.clip(to: frame)
        // The context is flipped to a top-left origin; images draw bottom-up.
        context.translateBy(x: 0, y: target.minY + target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        context.draw(image, in: target)
        context.restoreGState()
    }

    /// A play button in the middle of a video's still.
    private static func playBadge(in frame: CGRect, context: CGContext) {
        let side = min(44, frame.width * 0.4, frame.height * 0.4)
        let circle = CGRect(x: frame.midX - side / 2, y: frame.midY - side / 2, width: side, height: side)
        context.setFillColor(PlatformColor.black.withAlphaComponent(0.5).cgColor)
        context.fillEllipse(in: circle)
        let arm = side * 0.2
        context.setFillColor(PlatformColor.white.cgColor)
        context.move(to: CGPoint(x: circle.midX - arm * 0.8, y: circle.midY - arm))
        context.addLine(to: CGPoint(x: circle.midX + arm * 1.1, y: circle.midY))
        context.addLine(to: CGPoint(x: circle.midX - arm * 0.8, y: circle.midY + arm))
        context.closePath()
        context.fillPath()
    }

    /// A small tag in the bottom-left corner of a tile.
    private static func label(_ string: String, font: PlatformFont, in frame: CGRect, context: CGContext) {
        let tag = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: PlatformColor.white])
        let size = tag.size()
        let box = CGRect(x: frame.minX + 6, y: frame.maxY - 6 - size.height - 2, width: size.width + 8, height: size.height + 2)
        guard box.maxX < frame.maxX, box.minY > frame.minY else { return }
        context.setFillColor(PlatformColor.black.withAlphaComponent(0.5).cgColor)
        context.fill(box)
        tag.draw(at: CGPoint(x: box.minX + 4, y: box.minY + 1))
    }

    private static func text(_ string: NSAttributedString?, in frame: CGRect) {
        string?.draw(with: frame, options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine], context: nil)
    }
}

/// SF Symbols as bitmaps, drawn once per name, size, colour and scale and
/// kept. Rows render on several background queues at once, and CoreUI's
/// vector glyphs aren't safe to draw concurrently (a rare crash in
/// `CUINamedVectorGlyph`), so every first drawing happens under one lock and
/// rows only ever draw the finished `CGImage`. There are a few dozen keys
/// in practice (each action on and off, light and dark, per type size).
final class SymbolImages: @unchecked Sendable {
    static let shared = SymbolImages()

    struct Symbol: @unchecked Sendable {
        let image: CGImage
        /// In points.
        let size: CGSize
    }

    private struct Key: Hashable {
        let name: String
        let color: [CGFloat]
        let colorSpace: String
        let pointSize: CGFloat
        let scale: CGFloat
    }

    private let lock = NSLock()
    private var images: [Key: Symbol] = [:]
    /// More than this many keys means something is varying that shouldn't;
    /// start again rather than grow.
    private let limit = 512

    func image(_ name: String, color: CGColor, pointSize: CGFloat, scale: CGFloat) -> Symbol? {
        let key = Key(name: name, color: color.components ?? [], colorSpace: (color.colorSpace?.name as String?) ?? "",
                      pointSize: (pointSize * scale).rounded() / scale, scale: scale)
        return lock.withLock {
            if let found = images[key] { return found }
            guard let made = Self.rasterize(name, color: color, pointSize: key.pointSize, scale: scale) else { return nil }
            if images.count >= limit { images.removeAll() }
            images[key] = made
            return made
        }
    }

    private static func rasterize(_ name: String, color: CGColor, pointSize: CGFloat, scale: CGFloat) -> Symbol? {
        #if canImport(UIKit)
        let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        guard let image = UIImage(systemName: name, withConfiguration: configuration)?
            .withTintColor(UIColor(cgColor: color), renderingMode: .alwaysOriginal)
        else { return nil }
        let size = image.size
        #else
        guard let resolved = NSColor(cgColor: color) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [resolved]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        else { return nil }
        let size = image.size
        #endif
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Top-left origin in points, as the rows draw.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let bounds = CGRect(origin: .zero, size: size)
        #if canImport(UIKit)
        UIGraphicsPushContext(context)
        image.draw(in: bounds)
        UIGraphicsPopContext()
        #else
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.current = previous
        #endif
        return context.makeImage().map { Symbol(image: $0, size: size) }
    }
}
