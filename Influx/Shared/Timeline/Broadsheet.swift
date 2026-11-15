// The Broadsheet look: paper and ink, serif text, hairline rules, and a small
// coloured dot per source.
#if canImport(UIKit)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif
import InfluxKit

enum Broadsheet {
    static let paper = dynamic(light: (0.976, 0.965, 0.941), dark: (0.086, 0.082, 0.078))
    static let ink = dynamic(light: (0.102, 0.094, 0.086), dark: (0.918, 0.906, 0.882))
    static let ink2 = dynamic(light: (0.408, 0.396, 0.376), dark: (0.620, 0.608, 0.588))
    static let rule = dynamic(light: (0.835, 0.820, 0.792), dark: (0.231, 0.224, 0.216))
    static let wash = dynamic(light: (0.933, 0.922, 0.898), dark: (0.141, 0.137, 0.129))
    /// A liked heart and a boost the reader made.
    static let liked = dynamic(light: (0.784, 0.208, 0.247), dark: (0.941, 0.392, 0.416))
    static let boosted = dynamic(light: (0.180, 0.522, 0.337), dark: (0.384, 0.749, 0.537))
    /// Something went wrong, as the sync button's "!".
    /// A score badge's colour for each tone (green, amber, red, as the
    /// glyph in the text); ink2 for a tone this build doesn't know.
    static let favorable = dynamic(light: (0.196, 0.557, 0.243), dark: (0.400, 0.765, 0.420))
    static let mixed = dynamic(light: (0.722, 0.533, 0.039), dark: (0.910, 0.737, 0.231))
    static let unfavorable = dynamic(light: (0.776, 0.192, 0.165), dark: (0.941, 0.439, 0.404))

    static func badgeColor(_ tone: Item.Badge.Tone) -> PlatformColor {
        switch tone {
        case .favorable: favorable
        case .mixed: mixed
        case .unfavorable: unfavorable
        default: ink2
        }
    }

    static let alarm = dynamic(light: (0.702, 0.149, 0.118), dark: (0.941, 0.439, 0.404))

    /// Source-dot palette, indexed by `Source.colorIndex`.
    static let sourceColors: [PlatformColor] = [
        rgb(0.20, 0.47, 0.95), rgb(0.42, 0.33, 0.85), rgb(0.55, 0.36, 0.80), rgb(0.80, 0.33, 0.20),
        rgb(0.85, 0.15, 0.45), rgb(0.20, 0.60, 0.45), rgb(0.90, 0.50, 0.10),
    ]

    static func sourceColor(_ index: Int) -> PlatformColor {
        sourceColors[((index % sourceColors.count) + sourceColors.count) % sourceColors.count]
    }

    static func lineHeight(_ font: PlatformFont) -> CGFloat {
        #if canImport(UIKit)
        return ceil(font.lineHeight)
        #else
        return ceil(font.ascender - font.descender + font.leading)
        #endif
    }

    static func serif(_ size: CGFloat, weight: PlatformFont.Weight) -> PlatformFont {
        let base = PlatformFont.systemFont(ofSize: size, weight: weight)
        #if canImport(UIKit)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
        #else
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
        #endif
    }

    /// `font` in italic, at the same size; `font` itself when it has no
    /// italic.
    static func italic(_ font: PlatformFont) -> PlatformFont {
        #if canImport(UIKit)
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
        #else
        return NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) ?? font
        #endif
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> PlatformColor {
        PlatformColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> PlatformColor {
        let lightColor = rgb(light.0, light.1, light.2)
        let darkColor = rgb(dark.0, dark.1, dark.2)
        #if canImport(UIKit)
        return UIColor { $0.userInterfaceStyle == .dark ? darkColor : lightColor }
        #else
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        }
        #endif
    }
}

/// The Broadsheet type scale at one text size. Layout and drawing both read
/// it, so a row is drawn with exactly the fonts it was measured with.
/// Fonts are immutable, so it is safe to hand to layout and drawing off the
/// main thread.
struct Typography: @unchecked Sendable, Equatable {
    /// Text size relative to the default; 1 is the default size.
    let scale: CGFloat
    let meta: PlatformFont
    let body: PlatformFont
    let title: PlatformFont
    /// An article's excerpt, under its title.
    let excerpt: PlatformFont
    let linkTitle: PlatformFont
    /// A link card's description and a quoted post's text.
    let linkSummary: PlatformFont
    /// The line an unavailable quote shows: `linkSummary` in italic.
    let quoteUnavailable: PlatformFont
    /// The author picture's side at this text size.
    let avatarSide: CGFloat

    /// Point sizes at the default text size.
    struct Sizes: Sendable {
        var meta: CGFloat
        var body: CGFloat
        var title: CGFloat
        var excerpt: CGFloat
        var linkTitle: CGFloat
        var linkSummary: CGFloat
        /// The author picture's side.
        var avatar: CGFloat
    }

    /// The Mac's sizes, read at arm's length on a laptop or desktop.
    static let desktop = Sizes(meta: 12, body: 16, title: 20, excerpt: 16, linkTitle: 14, linkSummary: 13, avatar: 36)

    /// The iPhone's sizes. iOS sets its reading text at 17 pt (the body
    /// style at the default Large size), and a serif at the same size reads
    /// smaller than San Francisco, so post text sits a point above it.
    /// Headlines are only a point bigger than posts, so an article and a
    /// post weigh about the same in the timeline; the excerpt sits just
    /// under both.
    static let phone = Sizes(meta: 13, body: 18, title: 19, excerpt: 17, linkTitle: 16, linkSummary: 15, avatar: 40)

    #if os(iOS)
    static let platform = phone
    #else
    static let platform = desktop
    #endif

    init(scale: CGFloat = 1, sizes: Sizes = Typography.platform) {
        self.scale = scale
        meta = PlatformFont.systemFont(ofSize: (sizes.meta * scale).rounded(), weight: .medium)
        body = Broadsheet.serif((sizes.body * scale).rounded(), weight: .regular)
        title = Broadsheet.serif((sizes.title * scale).rounded(), weight: .semibold)
        excerpt = Broadsheet.serif((sizes.excerpt * scale).rounded(), weight: .regular)
        linkTitle = Broadsheet.serif((sizes.linkTitle * scale).rounded(), weight: .medium)
        linkSummary = Broadsheet.serif((sizes.linkSummary * scale).rounded(), weight: .regular)
        quoteUnavailable = Broadsheet.italic(linkSummary)
        avatarSide = min((sizes.avatar * scale).rounded(), 52)
    }

    #if canImport(UIKit)
    /// The type scale for the reader's text size setting.
    init(traits: UITraitCollection) {
        self.init(scale: UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: traits))
    }
    #endif

    static func == (lhs: Typography, rhs: Typography) -> Bool {
        lhs.scale == rhs.scale && lhs.body.pointSize == rhs.body.pointSize
    }
}

/// Everything besides a row's content that its geometry and bitmap depend
/// on. When any of it changes, every row is laid out and drawn again.
struct RowEnvironment: Sendable, Equatable {
    var width: CGFloat
    var scale: CGFloat
    var dark: Bool
    var typography: Typography
    /// The colour space rows are drawn in: the window's on the Mac, so Core
    /// Animation can show a row's bitmap as it is instead of keeping a
    /// colour-matched copy of each one.
    var colorSpace: String = CGColorSpace.sRGB as String
}
