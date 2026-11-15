// The attributed strings a row draws. Layout measures exactly these strings
// and the row draws exactly these strings, so measured and drawn heights
// cannot disagree.
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import InfluxKit

enum RowText {
    /// The whole header on one line: "Name  @handle · time". A row uses it
    /// when it fits; otherwise the handle drops to its own line below
    /// (`headerName`, `handle`), so the name and time are never cut.
    static func header(_ row: TimelineRow, _ type: Typography) -> NSAttributedString {
        let text = headerName(row, type, withHandle: true)
        text.append(time(row, type))
        return text
    }

    /// The name, followed by the handle when it shares the name's line.
    static func headerName(_ row: TimelineRow, _ type: Typography, withHandle: Bool) -> NSMutableAttributedString {
        let text = NSMutableAttributedString(string: row.authorName, attributes: attributes(type.meta, Broadsheet.ink, singleLine: true))
        if withHandle, !row.authorHandle.isEmpty {
            text.append(NSAttributedString(string: "  \(row.authorHandle)", attributes: attributes(type.meta, Broadsheet.ink2, singleLine: true)))
        }
        return text
    }

    /// The header shows when the row's item was posted, or boosted for a
    /// boost, whose context line carries the original time. A row that
    /// arrived late can sit below its own time's place (ADR 0041), but
    /// still shows its own time.
    static func time(_ row: TimelineRow, _ type: Typography) -> NSAttributedString {
        let time = shownDate(row).formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return NSAttributedString(string: " · \(time)", attributes: attributes(type.meta, Broadsheet.ink2, singleLine: true))
    }

    /// The time a row shows: its item's own, or where it sits for a row
    /// read before that was stored.
    static func shownDate(_ row: TimelineRow) -> Date {
        row.postedAt ?? row.sortDate
    }

    /// The handle on a line of its own, for when it doesn't fit beside the
    /// name. It may wrap, breaking after a dot or before the server's "@"
    /// rather than mid-word; nil when the row has no handle.
    static func handle(_ row: TimelineRow, _ type: Typography) -> NSAttributedString? {
        guard !row.authorHandle.isEmpty else { return nil }
        return NSAttributedString(string: breakable(row.authorHandle), attributes: attributes(type.meta, Broadsheet.ink2))
    }

    /// `handle` with zero-width spaces where a line may break: after each
    /// dot and before every "@" but the first.
    static func breakable(_ handle: String) -> String {
        var result = ""
        for (index, character) in handle.enumerated() {
            if character == "@", index > 0 { result.append("\u{200B}") }
            result.append(character)
            if character == "." { result.append("\u{200B}") }
        }
        return result
    }

    /// "Boosted by …" or "Replying to …", or nil when the row has neither.
    /// It wraps rather than cut off the time a boosted post was written.
    static func context(_ row: TimelineRow, _ type: Typography) -> NSAttributedString? {
        guard let line = contextLine(row) else { return nil }
        return NSAttributedString(string: line, attributes: attributes(type.meta, Broadsheet.ink2))
    }

    static func contextLine(_ row: TimelineRow) -> String? {
        if row.boostedBy.isEmpty {
            return row.replyToHandle.map { "Replying to \($0)" }
        }
        let boosters = switch row.boostedBy.count {
        case 1:
            "Boosted by \(row.boostedBy[0])"
        case 2:
            "Boosted by \(row.boostedBy[0]) and \(row.boostedBy[1])"
        default:
            "Boosted by \(row.boostedBy[0]) and \(row.boostedBy.count - 1) others"
        }
        guard let posted = postedTime(row) else { return boosters }
        return "\(boosters) · posted \(posted)"
    }

    /// When a boosted post was first written, if that's not when its row
    /// sits; nil when the two are within a minute.
    static func postedTime(_ row: TimelineRow) -> String? {
        guard !row.boostedBy.isEmpty, abs(shownDate(row).timeIntervalSince(row.publishedAt)) >= 60 else { return nil }
        return row.publishedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// What VoiceOver reads for a row, since its text is only in a bitmap.
    static func accessibilityLabel(_ row: TimelineRow) -> String {
        var parts = [row.authorName]
        if let context = contextLine(row) { parts.append(context) }
        if let badge = row.badge { parts.append(badge.spoken) }
        if let title = row.title { parts.append(title) }
        parts.append(row.body)
        if let card = row.linkCard { parts.append("Link: \(card.title), \(card.site)") }
        if let quote = row.quote, quote.isUnavailable {
            parts.append(quoteUnavailableLabel(quote))
        } else if let quote = row.quote {
            let body = quote.body.trimmingCharacters(in: .whitespacesAndNewlines)
            parts.append(body.isEmpty ? "Quoting \(quote.authorName)" : "Quoting \(quote.authorName): \(body)")
            if let image = quote.image { parts.append(mediaLabel(image)) }
        }
        parts += row.media.map(mediaLabel)
        parts.append(shownDate(row).formatted(date: .abbreviated, time: .shortened))
        if let viewer = row.viewer {
            let state = [viewer.liked ? "Liked" : nil, viewer.boosted ? "Boosted" : nil, viewer.bookmarked ? "Bookmarked" : nil].compactMap { $0 }
            if !state.isEmpty { parts.append(state.joined(separator: ", ")) }
        }
        return parts.joined(separator: ". ")
    }

    /// "Image: <alt text>", or just the kind when there is none.
    static func mediaLabel(_ item: Item.Media) -> String {
        let kind = switch item.kind {
        case .image: "Image"
        case .gif: "GIF"
        case .video: "Video"
        }
        return item.altText.map { "\(kind): \($0)" } ?? kind
    }

    /// The badge's text, set on its tone's colour (`RowRenderer`).
    static func badge(_ row: TimelineRow, _ type: Typography) -> NSAttributedString? {
        guard let badge = row.badge else { return nil }
        let font = PlatformFont.systemFont(ofSize: type.meta.pointSize, weight: .semibold)
        return NSAttributedString(string: badge.text, attributes: attributes(font, Broadsheet.paper, singleLine: true))
    }

    static func title(_ row: TimelineRow, _ type: Typography) -> NSAttributedString? {
        row.title.map { NSAttributedString(string: $0, attributes: attributes(type.title, Broadsheet.ink)) }
    }

    /// The body, with its links underlined. Underlines don't change the
    /// text's height, so a row measures the same with or without links.
    /// An article's body is its excerpt, set a little smaller than a post.
    static func body(_ row: TimelineRow, _ type: Typography) -> NSAttributedString {
        body(row.body, links: row.links, font: row.kind == .article ? type.excerpt : type.body)
    }

    static func body(_ text: String, links: [Item.Link], font: PlatformFont) -> NSAttributedString {
        let string = NSMutableAttributedString(string: text, attributes: attributes(font, Broadsheet.ink, lineSpacing: (font.pointSize * 0.2).rounded()))
        for link in links {
            guard let range = range(of: link, in: string) else { continue }
            string.addAttributes([
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .underlineColor: Broadsheet.ink2,
            ], range: range)
        }
        return string
    }

    /// `link`'s run of `string`, if it fits inside it.
    static func range(of link: Item.Link, in string: NSAttributedString) -> NSRange? {
        guard link.start >= 0, link.length > 0, link.start + link.length <= string.length else { return nil }
        return NSRange(location: link.start, length: link.length)
    }

    /// The link under `point` in a body laid out at `width`, with `point`
    /// measured from the body's top left. Laid out again here, at tap time,
    /// with the same string and width as the row was measured with.
    static func link(at point: CGPoint, in row: TimelineRow, width: CGFloat, _ type: Typography) -> URL? {
        guard !row.links.isEmpty else { return nil }
        let string = body(row, type)
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        // A finger is wider than a glyph: try a little either side too.
        for dx in [0, -8, 8] as [CGFloat] {
            let probe = CGPoint(x: point.x + dx, y: point.y)
            let glyph = layout.glyphIndex(for: probe, in: container)
            let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            guard bounds.insetBy(dx: -8, dy: -4).contains(probe) else { continue }
            let index = layout.characterIndexForGlyph(at: glyph)
            for link in row.links {
                if let range = range(of: link, in: string), NSLocationInRange(index, range) {
                    return URL(string: link.url)
                }
            }
        }
        return nil
    }

    /// Where the author's profile lives on the web: `@user@host` is a
    /// Mastodon account, `@handle` a Bluesky one when the post is on
    /// bsky.app. Nil for anything else, such as an article's site.
    static func profileURL(_ row: TimelineRow) -> URL? {
        guard row.kind == .post, row.authorHandle.hasPrefix("@") else { return nil }
        let parts = row.authorHandle.dropFirst().split(separator: "@")
        if parts.count == 2 {
            return URL(string: "https://\(parts[1])/@\(parts[0])")
        }
        if parts.count == 1, row.url?.hasPrefix("https://bsky.app/") == true {
            return URL(string: "https://bsky.app/profile/\(parts[0])")
        }
        return nil
    }

    /// The symbol an action's icon shows, and whether it is switched on.
    static func symbol(_ action: RowAction, _ viewer: Item.Viewer) -> (name: String, on: Bool) {
        switch action {
        case .thread: ("bubble.left", false)
        case .boost: ("arrow.2.squarepath", viewer.boosted)
        case .like: (viewer.liked ? "heart.fill" : "heart", viewer.liked)
        case .bookmark: (viewer.bookmarked ? "bookmark.fill" : "bookmark", viewer.bookmarked)
        }
    }

    /// What VoiceOver calls an action: what it does now.
    static func actionName(_ action: RowAction, _ viewer: Item.Viewer) -> String {
        switch action {
        case .thread: "Open thread"
        case .boost: viewer.boosted ? "Undo boost" : "Boost"
        case .like: viewer.liked ? "Unlike" : "Like"
        case .bookmark: viewer.bookmarked ? "Remove bookmark" : "Bookmark"
        }
    }

    static func linkSite(_ card: Item.LinkCard, _ type: Typography) -> NSAttributedString {
        NSAttributedString(string: card.site.uppercased(), attributes: attributes(type.meta, Broadsheet.ink2, singleLine: true))
    }

    static func linkTitle(_ card: Item.LinkCard, _ type: Typography) -> NSAttributedString {
        NSAttributedString(string: card.title, attributes: attributes(type.linkTitle, Broadsheet.ink))
    }

    /// The card's description, or nil when it has none or only repeats
    /// the title.
    static func linkSummary(_ card: Item.LinkCard, _ type: Typography) -> NSAttributedString? {
        guard let summary = card.summary, summary != card.title else { return nil }
        return NSAttributedString(string: summary, attributes: attributes(type.linkSummary, Broadsheet.ink2))
    }

    /// "Name  @handle" on a quoted post's card.
    static func quoteHeader(_ quote: Item.Quote, _ type: Typography) -> NSAttributedString {
        let text = NSMutableAttributedString(string: quote.authorName, attributes: attributes(type.meta, Broadsheet.ink, singleLine: true))
        text.append(NSAttributedString(string: "  \(quote.authorHandle)", attributes: attributes(type.meta, Broadsheet.ink2, singleLine: true)))
        return text
    }

    static func quoteBody(_ quote: Item.Quote, _ type: Typography) -> NSAttributedString? {
        let body = quote.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return NSAttributedString(string: body, attributes: attributes(type.linkSummary, Broadsheet.ink))
    }

    /// What an unavailable quote's card says, on one line cut short.
    static let quoteUnavailableText = "Quoted post unavailable"

    static func quoteUnavailable(_ type: Typography) -> NSAttributedString {
        NSAttributedString(string: quoteUnavailableText, attributes: attributes(type.quoteUnavailable, Broadsheet.ink2, singleLine: true))
    }

    /// What VoiceOver reads for an unavailable quote: what it says, and
    /// where the post was when that is known.
    static func quoteUnavailableLabel(_ quote: Item.Quote) -> String {
        guard let site = site(of: quote) else { return quoteUnavailableText }
        return "\(quoteUnavailableText), \(site)"
    }

    /// The host a quote's address names, without its `www.`.
    static func site(of quote: Item.Quote) -> String? {
        guard var host = quote.url.flatMap({ URL(string: $0)?.host() }), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    /// Where the quoted post lives, as its host (the other network's host
    /// for a bridged post), or nil without a web address.
    static func quoteSite(_ quote: Item.Quote, _ type: Typography) -> NSAttributedString? {
        guard let host = site(of: quote) else { return nil }
        return NSAttributedString(string: host, attributes: attributes(type.meta, Broadsheet.ink2, singleLine: true))
    }

    /// The letter a missing avatar shows: the name's first letter or digit.
    static func monogram(_ row: TimelineRow) -> String {
        let name = row.kind == .article ? row.sourceTitle : row.authorName
        return name.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "•"
    }

    private static func attributes(_ font: PlatformFont, _ color: PlatformColor, singleLine: Bool = false, lineSpacing: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = singleLine ? .byTruncatingTail : .byWordWrapping
        paragraph.lineSpacing = lineSpacing
        return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }
}
