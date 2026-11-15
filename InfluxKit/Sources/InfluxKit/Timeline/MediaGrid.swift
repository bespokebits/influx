import Foundation

/// Where a row's images and videos sit, from their pixel sizes alone, so the
/// row's height is final before it is drawn.
public enum MediaGrid {
    /// Space between the tiles of a grid.
    public static let gap: CGFloat = 2
    /// The most tiles shown; later media is counted on the last tile.
    public static let maxTiles = 4
    /// A single image is never taller than this times its width.
    public static let tallest: CGFloat = 1.25
    /// Two or more tiles share a 16:9 box.
    public static let gridAspect: CGFloat = 16.0 / 9.0

    /// The frame of each tile within a box `width` wide whose top is at zero,
    /// in the order of `media`, at most `maxTiles` of them.
    /// - One: the image's own shape, no taller than `tallest` times the width.
    ///   With `keepingSmallImagesSmall`, an image is also no wider in points
    ///   than it is in pixels, at the left of the box, so a small one isn't
    ///   blown up. Only for media whose size is the file's own (articles):
    ///   services can store a bare ratio (Bluesky) or a preview's size
    ///   (Mastodon) as the size.
    /// - Two: side by side. Three: one on the left, two stacked on the right.
    /// - Four or more: a two-by-two grid.
    public static func frames(for media: [Item.Media], width: CGFloat, keepingSmallImagesSmall: Bool = false) -> [CGRect] {
        guard width > 0 else { return [] }
        switch media.count {
        case 0:
            return []
        case 1:
            let shown = keepingSmallImagesSmall && media[0].kind == .image ? min(width, CGFloat(media[0].width)) : width
            let height = min((shown / CGFloat(media[0].aspect)).rounded(), (shown * tallest).rounded())
            return [CGRect(x: 0, y: 0, width: shown, height: max(height, 1))]
        default:
            let height = (width / gridAspect).rounded()
            let half = ((width - gap) / 2).rounded(.down)
            let right = width - half - gap
            let upper = ((height - gap) / 2).rounded(.down)
            let lower = height - upper - gap
            switch media.count {
            case 2:
                return [CGRect(x: 0, y: 0, width: half, height: height),
                        CGRect(x: half + gap, y: 0, width: right, height: height)]
            case 3:
                return [CGRect(x: 0, y: 0, width: half, height: height),
                        CGRect(x: half + gap, y: 0, width: right, height: upper),
                        CGRect(x: half + gap, y: upper + gap, width: right, height: lower)]
            default:
                return [CGRect(x: 0, y: 0, width: half, height: upper),
                        CGRect(x: half + gap, y: 0, width: right, height: upper),
                        CGRect(x: 0, y: upper + gap, width: half, height: lower),
                        CGRect(x: half + gap, y: upper + gap, width: right, height: lower)]
            }
        }
    }

    /// The height of the box `frames(for:width:)` fills.
    public static func height(for media: [Item.Media], width: CGFloat, keepingSmallImagesSmall: Bool = false) -> CGFloat {
        frames(for: media, width: width, keepingSmallImagesSmall: keepingSmallImagesSmall).map(\.maxY).max() ?? 0
    }

    /// The longest side, in pixels, to decode an image of `pixelWidth` by
    /// `pixelHeight` at so that it fills `frame` (in points, at `scale`)
    /// with no upscaling, rounded up to a multiple of 64 so nearby sizes
    /// share one decoded image. Never more than the image's own longest side,
    /// and never more than `maxPixels` decoded pixels, so an extreme shape
    /// (a 1000 by 100,000 strip filling a tile) can't ask for a huge bitmap;
    /// such an image is drawn softer instead.
    public static func decodeSize(pixelWidth: Int, pixelHeight: Int, filling frame: CGSize, scale: CGFloat,
                                  maxPixels: Int = maxDecodedPixels) -> Int {
        let longest = max(pixelWidth, pixelHeight)
        let cap = largestDecode(pixelWidth: pixelWidth, pixelHeight: pixelHeight, maxPixels: maxPixels)
        guard frame.width > 0, frame.height > 0, scale > 0 else { return cap }
        let fill = max(frame.width * scale / CGFloat(pixelWidth), frame.height * scale / CGFloat(pixelHeight))
        let wanted = Int((CGFloat(longest) * fill).rounded(.up))
        let bucketed = (wanted + 63) / 64 * 64
        return min(max(bucketed, 64), cap)
    }

    /// The longest side an image of this shape may decode at: its own
    /// longest side, or less if that would exceed `maxPixels`.
    public static func largestDecode(pixelWidth: Int, pixelHeight: Int, maxPixels: Int = maxDecodedPixels) -> Int {
        let longest = max(pixelWidth, pixelHeight)
        let shortest = min(pixelWidth, pixelHeight)
        guard shortest > 0 else { return 1 }
        // The longest side at which the decoded area is `maxPixels`.
        let budget = Int((Double(maxPixels) * Double(longest) / Double(shortest)).squareRoot().rounded(.down))
        return max(1, min(longest, budget))
    }

    /// About 16 MB as a 4-byte-per-pixel bitmap; a full-width tile on an
    /// iPhone 15 Pro Max at 3x needs about 2.4 million.
    public static let maxDecodedPixels = 4_194_304
}
