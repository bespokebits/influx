// Every row's geometry, computed off the main thread before the row is
// displayed and never changed while it can be seen.
import CoreGraphics
import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import InfluxKit

struct RowGeometry: Sendable, Equatable {
    var width: CGFloat
    var height: CGFloat
    /// The author's picture (an article's feed icon), left of everything else.
    var avatar: CGRect
    var dot: CGRect
    /// The name, with the handle after it when the whole header fits on
    /// one line.
    var header: CGRect
    /// " · time", straight after the name; never cut.
    var time: CGRect
    /// The handle on its own line(s) under the name, when the header
    /// didn't fit on one line.
    var handle: CGRect?
    var context: CGRect?
    /// The first booster's picture, at the start of the context line.
    var boosterAvatar: CGRect?
    /// The score capsule on its own line above the title, for a row with
    /// a badge.
    var badge: CGRect? = nil
    var title: CGRect?
    var body: CGRect
    /// The whole link card.
    var link: CGRect?
    /// The link card's image: across its top on a large card, or a square
    /// at its right edge on a small one.
    var linkImage: CGRect?
    /// The card's site, title and description lines.
    var linkSite: CGRect?
    var linkTitle: CGRect?
    var linkSummary: CGRect?
    /// One frame per media tile, in the order of `row.media`.
    var media: [CGRect]
    /// The quoted post's card: its picture across the top, its "name
    /// @handle" line, its text and the site it lives on. An unavailable
    /// quote's card has only its one italic line, in `quoteHeader`, and
    /// the site, when its address is known.
    var quote: CGRect?
    var quoteImage: CGRect?
    var quoteHeader: CGRect?
    var quoteBody: CGRect?
    var quoteSite: CGRect?
    /// The light-action icons along the bottom of a row, one per
    /// `RowAction.available(for:)`, in order; empty when no action applies.
    var actions: [CGRect] = []
}

/// The icons along the bottom of a post: open its thread (where its
/// service has threads), then the three post actions. A row that keeps
/// its own bookmark (an article, a rich feed's post) has only the
/// bookmark.
enum RowAction: Int, CaseIterable, Sendable {
    case thread, boost, like, bookmark

    /// The icons `row` shows, in order.
    static func available(for row: TimelineRow) -> [RowAction] {
        guard row.viewer != nil else { return [] }
        if row.keepsOwnBookmark { return [.bookmark] }
        return row.hasThread ? allCases : allCases.filter { $0 != .thread }
    }

    var toggle: Item.Viewer.Toggle? {
        switch self {
        case .thread: nil
        case .boost: .boost
        case .like: .like
        case .bookmark: .bookmark
        }
    }
}

enum RowLayout {
    static let inset: CGFloat = 20
    static let top: CGFloat = 16
    static let bottom: CGFloat = 16
    static let gap: CGFloat = 6
    static let dotSize: CGFloat = 7
    static let linkPadding: CGFloat = 10
    /// Space between the avatar and the text column.
    static let avatarGap: CGFloat = 12
    /// Images, link cards and quotes are never wider than this, so a wide
    /// Mac window shows a picture at a comfortable reading size rather
    /// than one that fills the column. A phone's column is narrower anyway.
    static let mediaMaxWidth: CGFloat = 560
    /// A link card's image goes across the top of the card when it is at
    /// least this much wider than tall; squarer images stay a thumbnail.
    static let largeCardAspect: CGFloat = 1.2
    /// A large card's image is never narrower than this.
    static let largeCardMinWidth: CGFloat = 200
    static let linkTitleLines: CGFloat = 2
    static let linkSummaryLines: CGFloat = 3
    static let quoteBodyLines: CGFloat = 6
    /// A handle on its own line, and a context line, wrap to at most this.
    static let metaLines: CGFloat = 2

    static func avatarSide(_ type: Typography) -> CGFloat {
        type.avatarSide
    }

    static func geometries(for rows: [TimelineRow], in environment: RowEnvironment) -> [RowGeometry] {
        rows.map { geometry(for: $0, in: environment) }
    }

    static func geometry(for row: TimelineRow, in environment: RowEnvironment) -> RowGeometry {
        let width = environment.width
        let type = environment.typography
        let side = avatarSide(type)
        let avatar = CGRect(x: inset, y: top, width: side, height: side)
        let left = inset + side + avatarGap
        let textWidth = max(width - left - inset, 1)
        let boxWidth = min(textWidth, mediaMaxWidth)
        let metaHeight = Broadsheet.lineHeight(type.meta)
        var y = top

        let dot = CGRect(x: left, y: y + (metaHeight - dotSize) / 2, width: dotSize, height: dotSize)
        let headerX = left + dotSize + 8
        let headerWidth = max(left + textWidth - headerX, 1)
        let timeWidth = singleLineWidth(RowText.time(row, type))
        let whole = singleLineWidth(RowText.headerName(row, type, withHandle: true))
        let fits = whole + timeWidth <= headerWidth
        // When it doesn't all fit, the name keeps the line with the time
        // and the handle moves down; a name too long for even that is cut,
        // never the time.
        let nameWidth = fits ? whole : min(singleLineWidth(RowText.headerName(row, type, withHandle: false)),
                                           max(headerWidth - timeWidth, 1))
        let header = CGRect(x: headerX, y: y, width: nameWidth, height: metaHeight)
        let time = CGRect(x: header.maxX, y: y, width: min(timeWidth, headerWidth), height: metaHeight)
        y += metaHeight

        var handle: CGRect?
        if !fits, let text = RowText.handle(row, type) {
            y += 2
            let height = lines(text, width: headerWidth, font: type.meta, max: metaLines)
            handle = CGRect(x: headerX, y: y, width: headerWidth, height: height)
            y += height
        }
        y += gap

        var context: CGRect?
        var boosterAvatar: CGRect?
        if let text = RowText.context(row, type) {
            var x = left
            if !row.boostedBy.isEmpty, row.boosterAvatar != nil {
                boosterAvatar = CGRect(x: left, y: y, width: metaHeight, height: metaHeight)
                x += metaHeight + 5
            }
            let height = lines(text, width: left + textWidth - x, font: type.meta, max: metaLines)
            context = CGRect(x: x, y: y, width: left + textWidth - x, height: height)
            y += height + gap
        }

        var badge: CGRect?
        if let text = RowText.badge(row, type) {
            let height = (Broadsheet.lineHeight(type.meta) + 2 * badgePadding.height).rounded(.up)
            badge = CGRect(x: left, y: y, width: min(singleLineWidth(text) + 2 * badgePadding.width, textWidth), height: height)
            y += height + gap
        }

        var title: CGRect?
        if let text = RowText.title(row, type) {
            let height = measure(text, width: textWidth)
            title = CGRect(x: left, y: y, width: textWidth, height: height)
            y += height + gap
        }

        let bodyHeight = measure(RowText.body(row, type), width: textWidth)
        let body = CGRect(x: left, y: y, width: textWidth, height: bodyHeight)
        y += bodyHeight

        var link: CGRect?, linkImage: CGRect?, linkSite: CGRect?, linkTitle: CGRect?, linkSummary: CGRect?
        if let card = row.linkCard {
            y += gap + 4
            let padding = linkPadding
            let cardTop = y
            if let image = card.image, CGFloat(image.aspect) >= largeCardAspect, boxWidth >= largeCardMinWidth {
                // A large card: the picture across the top, the words below.
                let imageHeight = (boxWidth / CGFloat(image.aspect)).rounded()
                linkImage = CGRect(x: left, y: y, width: boxWidth, height: imageHeight)
                y += imageHeight + padding
                let inner = boxWidth - padding * 2
                linkSite = CGRect(x: left + padding, y: y, width: inner, height: metaHeight)
                y += metaHeight + 2
                let titleHeight = lines(RowText.linkTitle(card, type), width: inner, font: type.linkTitle, max: linkTitleLines)
                linkTitle = CGRect(x: left + padding, y: y, width: inner, height: titleHeight)
                y += titleHeight
                if let summary = RowText.linkSummary(card, type) {
                    y += 2
                    let summaryHeight = lines(summary, width: inner, font: type.linkSummary, max: linkSummaryLines)
                    linkSummary = CGRect(x: left + padding, y: y, width: inner, height: summaryHeight)
                    y += summaryHeight
                }
                y += padding
            } else {
                // A small card: site and title, with a square thumbnail
                // only when there is room left for the text.
                let height = (padding * 2 + metaHeight + 2 + Broadsheet.lineHeight(type.linkTitle) * linkTitleLines).rounded(.up)
                var inner = boxWidth - padding * 2
                if card.image != nil, boxWidth >= height * 3 {
                    linkImage = CGRect(x: left + boxWidth - height, y: y, width: height, height: height)
                    inner -= height
                }
                linkSite = CGRect(x: left + padding, y: y + padding, width: inner, height: metaHeight)
                linkTitle = CGRect(x: left + padding, y: y + padding + metaHeight + 2, width: inner,
                                   height: height - padding * 2 - metaHeight - 2)
                y += height
            }
            let cardHeight = (y - cardTop).rounded(.up)
            link = CGRect(x: left, y: cardTop, width: boxWidth, height: cardHeight)
            y = cardTop + cardHeight
        }

        var media: [CGRect] = []
        if !row.media.isEmpty {
            y += gap + 4
            let top = y
            // An article's picture was sized from its file, so a small one
            // can be kept small.
            let keepSmall = row.kind == .article
            media = MediaGrid.frames(for: row.media, width: boxWidth, keepingSmallImagesSmall: keepSmall).map { $0.offsetBy(dx: left, dy: top) }
            y += MediaGrid.height(for: row.media, width: boxWidth, keepingSmallImagesSmall: keepSmall)
        }

        var quote: CGRect?, quoteImage: CGRect?, quoteHeader: CGRect?, quoteBody: CGRect?, quoteSite: CGRect?
        if let quoted = row.quote {
            y += gap + 4
            let padding = linkPadding
            let inner = boxWidth - padding * 2
            let cardTop = y
            if quoted.isUnavailable {
                // A fixed height, set by the text size alone: one line at
                // the quote's text size and the site's meta line, each cut
                // short, never wrapped.
                y += padding
                let line = Broadsheet.lineHeight(type.quoteUnavailable)
                quoteHeader = CGRect(x: left + padding, y: y, width: inner, height: line)
                y += line
            } else {
                // The picture keeps its shape, like a single image in a post.
                if let image = quoted.image, let frame = MediaGrid.frames(for: [image], width: boxWidth).first {
                    quoteImage = frame.offsetBy(dx: left, dy: y)
                    y += frame.height
                }
                y += padding
                quoteHeader = CGRect(x: left + padding, y: y, width: inner, height: metaHeight)
                y += metaHeight
                if let text = RowText.quoteBody(quoted, type) {
                    y += 4
                    let height = lines(text, width: inner, font: type.linkSummary, max: quoteBodyLines)
                    quoteBody = CGRect(x: left + padding, y: y, width: inner, height: height)
                    y += height
                }
            }
            if RowText.quoteSite(quoted, type) != nil {
                y += 2
                quoteSite = CGRect(x: left + padding, y: y, width: inner, height: metaHeight)
                y += metaHeight
            }
            y += padding
            quote = CGRect(x: left, y: cardTop, width: boxWidth, height: y - cardTop)
        }

        var actions: [CGRect] = []
        let available = RowAction.available(for: row)
        if !available.isEmpty {
            let side = actionIconSide(type)
            y += actionGap
            // Spread over the text column, as far apart as fits, up to a
            // comfortable thumb's reach.
            let step = min(actionSpacing * type.scale, (textWidth - side) / CGFloat(RowAction.allCases.count - 1))
            actions = available.indices.map { index in
                CGRect(x: left + CGFloat(index) * step, y: y, width: side, height: side)
            }
            y += side - actionBottomTrim
        }

        // A short post is never shorter than its avatar.
        y = max(y, avatar.maxY)
        y += bottom
        return RowGeometry(width: width, height: ceil(y), avatar: avatar, dot: dot, header: header, time: time,
                           handle: handle, context: context,
                           boosterAvatar: boosterAvatar, badge: badge, title: title, body: body, link: link, linkImage: linkImage,
                           linkSite: linkSite, linkTitle: linkTitle, linkSummary: linkSummary, media: media,
                           quote: quote, quoteImage: quoteImage, quoteHeader: quoteHeader, quoteBody: quoteBody,
                           quoteSite: quoteSite, actions: actions)
    }

    /// The height of `text` at `width`, cut to at most `max` lines of
    /// `font`; it is drawn truncated to the same frame.
    static func lines(_ text: NSAttributedString, width: CGFloat, font: PlatformFont, max count: CGFloat) -> CGFloat {
        min(measure(text, width: width), ceil(Broadsheet.lineHeight(font) * count) + 1)
    }

    /// Room around a badge's text inside its capsule.
    static let badgePadding = CGSize(width: 8, height: 2)

    static let actionGap: CGFloat = 10
    static let actionSpacing: CGFloat = 64
    /// The icons' own whitespace stands in for part of the bottom margin.
    static let actionBottomTrim: CGFloat = 4

    static func actionIconSide(_ type: Typography) -> CGFloat {
        (18 * type.scale).rounded()
    }

    /// The smallest tap target, around an icon or a line of text.
    static let minimumTarget: CGFloat = 44

    /// `frame` grown to at least the minimum tap target, about its centre.
    static func target(around frame: CGRect) -> CGRect {
        frame.insetBy(dx: min(0, (frame.width - minimumTarget) / 2), dy: min(0, (frame.height - minimumTarget) / 2))
    }

    /// How wide `text` is set on one line, unwrapped.
    static func singleLineWidth(_ text: NSAttributedString) -> CGFloat {
        let bounds = text.boundingRect(with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(bounds.width) + 1
    }

    static func measure(_ text: NSAttributedString, width: CGFloat) -> CGFloat {
        let bounds = text.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(bounds.height) + 1
    }
}
