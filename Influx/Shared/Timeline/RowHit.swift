// What a tap on a timeline row reaches. A row is one bitmap, so
// its parts are found from its geometry: the same frames it was drawn in.
import CoreGraphics
import Foundation
import InfluxKit

enum RowHit {
    /// One of the icons along the bottom of a post.
    case action(RowAction, TimelineRow)
    /// The "Replying to" chip, or the rest of a post: its thread, where
    /// its service has threads.
    case thread(TimelineRow)
    /// A video or gif tile the system player can play.
    case video(Item.Media)
    case image(Item.Media)
    /// A link in the text, the link card, or the author.
    case link(URL)
    /// Anywhere on an article: its page, which also marks it read.
    case article(TimelineRow, URL)

    /// `point` is measured from the row's top left. The icons come first,
    /// since their tap targets reach a little past the icons themselves.
    static func at(_ point: CGPoint, in row: TimelineRow, geometry: RowGeometry, typography: Typography) -> RowHit? {
        for (action, frame) in zip(RowAction.available(for: row), geometry.actions) where RowLayout.target(around: frame).contains(point) {
            return .action(action, row)
        }
        for (media, frame) in zip(row.media, geometry.media) where frame.contains(point) {
            if VideoPlayback.canPlay(media) { return .video(media) }
            if media.kind == .image { return .image(media) }
        }
        if let frame = geometry.link, frame.contains(point), let url = row.linkCard.flatMap({ URL(string: $0.url) }) {
            // An article's card opens the article, which marks it read.
            return row.kind == .article ? .article(row, url) : .link(url)
        }
        if let frame = geometry.quote, frame.contains(point), let url = row.quote?.url.flatMap({ URL(string: $0) }) {
            return .link(url)
        }
        if geometry.body.contains(point),
           let url = RowText.link(at: CGPoint(x: point.x - geometry.body.minX, y: point.y - geometry.body.minY),
                                  in: row, width: geometry.body.width, typography) {
            return .link(url)
        }
        // The context line is a "Replying to" chip only when it says so.
        // Without a thread, the chip has nothing to open.
        if let frame = geometry.context, row.boostedBy.isEmpty, row.replyToHandle != nil, frame.insetBy(dx: 0, dy: -6).contains(point) {
            return row.hasThread ? .thread(row) : nil
        }
        if geometry.header.insetBy(dx: 0, dy: -6).contains(point) || geometry.avatar.contains(point)
            || geometry.handle?.insetBy(dx: 0, dy: -6).contains(point) == true,
           let profile = RowText.profileURL(row) {
            return .link(profile)
        }
        return opening(row)
    }

    /// What a tap on the rest of `row`, away from its links and icons,
    /// opens; also what a link back to the item opens (`ItemLink`).
    static func opening(_ row: TimelineRow) -> RowHit? {
        switch row.kind {
        case .post:
            // Without a thread, the post's own page has the rest of it. A
            // rich post always opens its original; its thread, where it
            // has one, is in the item menu.
            return row.hasThread && !row.isRich ? .thread(row) : originalLink(row)
        case .article:
            return row.url.flatMap { URL(string: $0) }.map { .article(row, $0) }
        }
    }

    private static func originalLink(_ row: TimelineRow) -> RowHit? {
        ItemMenu.originalURL(row).map { .link($0) }
    }

    /// The row's actions as VoiceOver lists them.
    static func accessibilityActions(for row: TimelineRow) -> [(name: String, hit: RowHit)] {
        var actions: [(name: String, hit: RowHit)] = []
        let icons = RowAction.available(for: row)
        if let viewer = row.viewer {
            actions += icons.map { (RowText.actionName($0, viewer), .action($0, row)) }
        }
        if row.hasThread, !icons.contains(.thread) {
            // A rich post's icons are only its bookmark, but it may have a
            // thread.
            actions.append(("Open thread", .thread(row)))
        }
        if let card = row.linkCard, let url = URL(string: card.url) {
            actions.append(("Open link: \(card.title)", row.kind == .article ? .article(row, url) : .link(url)))
        }
        if let quote = row.quote, let url = quote.url.flatMap({ URL(string: $0) }) {
            actions.append((quote.isUnavailable ? "Open quoted post's address" : "Open quoted post by \(quote.authorName)", .link(url)))
        }
        for link in row.links {
            guard let url = URL(string: link.url), let range = Range(NSRange(location: link.start, length: link.length), in: row.body) else { continue }
            actions.append(("Open \(row.body[range])", .link(url)))
        }
        if let video = row.media.first(where: VideoPlayback.canPlay) {
            actions.append((video.kind == .gif ? "Play GIF" : "Play video", .video(video)))
        }
        let images = row.media.filter { $0.kind == .image }
        for (index, image) in images.enumerated() {
            actions.append((images.count == 1 ? "Open image" : "Open image \(index + 1)", .image(image)))
        }
        if let profile = RowText.profileURL(row) {
            actions.append(("Open \(row.authorName)'s profile", .link(profile)))
        }
        if row.kind == .article, let url = row.url.flatMap({ URL(string: $0) }) {
            actions.append(("Open article", .article(row, url)))
        } else if let original = ItemMenu.original(of: row) {
            actions.append(("Open original", original))
        }
        return actions
    }
}
