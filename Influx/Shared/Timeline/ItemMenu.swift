// The item menu: what a right-click on the Mac, a long press on iOS and
// the Item menu offer on a row. Opening the original is the same open a
// tap on an article makes, so an article opened from here is marked read
// too.
import Foundation
import SwiftUI
import InfluxKit

enum ItemAction: CaseIterable {
    case openOriginal, openThread, openAuthor, bookmark, copyLink, copyText, share

    var title: String {
        switch self {
        case .openOriginal: "Open Original"
        case .openThread: "Open Thread"
        case .openAuthor: "Open Author"
        case .bookmark: "Bookmark"
        case .copyLink: "Copy Link"
        case .copyText: "Copy Text"
        case .share: "Share…"
        }
    }

    var symbol: String {
        switch self {
        case .openOriginal: "safari"
        case .openThread: "bubble.left.and.bubble.right"
        case .openAuthor: "person.crop.circle"
        case .bookmark: "bookmark"
        case .copyLink: "link"
        case .copyText: "doc.on.doc"
        case .share: "square.and.arrow.up"
        }
    }

    /// What a row's menu calls the action: Bookmark turns into Remove
    /// Bookmark on a bookmarked row.
    func title(for row: TimelineRow) -> String {
        self == .bookmark && row.viewer?.bookmarked == true ? "Remove Bookmark" : title
    }

    func symbol(for row: TimelineRow) -> String {
        self == .bookmark && row.viewer?.bookmarked == true ? "bookmark.slash" : symbol
    }

    /// What `row` offers, in menu order. Articles have no thread or author
    /// page, nor do posts from a service without threads; a row without a web address can't be opened, copied or shared
    /// as a link; only a row with a bookmark icon can be bookmarked.
    static func available(for row: TimelineRow) -> [ItemAction] {
        allCases.filter { $0.applies(to: row) }
    }

    func applies(to row: TimelineRow) -> Bool {
        switch self {
        case .openOriginal, .copyLink, .share: ItemMenu.originalURL(row) != nil
        case .openThread: row.hasThread
        case .openAuthor: RowText.profileURL(row) != nil
        case .bookmark: RowAction.available(for: row).contains(.bookmark)
        case .copyText: !ItemMenu.text(of: row).isEmpty
        }
    }

    /// Menus show the opens, then the bookmark, then copying and sharing,
    /// with separators between.
    var group: Int {
        switch self {
        case .openOriginal, .openThread, .openAuthor: 0
        case .bookmark: 1
        case .copyLink, .copyText, .share: 2
        }
    }

    /// `actions` in their menu groups, leaving out empty ones.
    static func grouped(_ actions: [ItemAction]) -> [[ItemAction]] {
        (0...2).map { group in actions.filter { $0.group == group } }.filter { !$0.isEmpty }
    }
}

enum ItemMenu {
    /// The post on its service's site, or the article's page.
    static func originalURL(_ row: TimelineRow) -> URL? {
        guard let string = row.url, let url = URL(string: string),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    /// Opening the original as a tap would: an article's also marks it read.
    static func original(of row: TimelineRow) -> RowHit? {
        originalURL(row).map { row.kind == .article ? .article(row, $0) : .link($0) }
    }

    /// The row's words: an article's title and summary, or a post's text.
    static func text(of row: TimelineRow) -> String {
        [row.title, row.body]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// What the reader is told when the Item menu's command doesn't apply
    /// to the row it acts on.
    static func unavailable(_ action: ItemAction) -> String {
        switch action {
        case .openOriginal, .copyLink, .share: "This item has no link."
        case .openThread: "This item has no thread to open."
        case .openAuthor: "This item has no author page."
        case .bookmark: "This item can't be bookmarked."
        case .copyText: "This item has no text."
        }
    }
}

/// What the Item menu acts on: the timeline in the focused window.
@MainActor
protocol ItemMenuTarget: AnyObject {
    /// Acts on the row the reader last clicked or pressed while it is on
    /// screen, or else the row at the top of the screen.
    func performOnCurrentRow(_ action: ItemAction)
    /// Does what a link back to an item asked: opens the row as a tap
    /// would, goes to a row, or shows a notice. Once on screen, if it
    /// isn't yet.
    func take(_ request: TimelineItems.Request)
}

/// A window's way to its timeline for the Item menu, kept by the shell
/// like `TimelineJumps`; the timeline showing attaches itself.
@MainActor
@Observable
final class TimelineItems {
    @ObservationIgnored private(set) weak var target: (any ItemMenuTarget)?
    private(set) var isAttached = false
    /// A request waiting for a timeline: none is attached yet (a launch
    /// by a link), or the one asked for is still to come.
    @ObservationIgnored private(set) var waiting: Request?

    /// What a link back to an item asks of the timeline.
    enum Request: Equatable {
        case open(TimelineRow)
        /// Goes to the row with this merge key, with a brief highlight,
        /// once the timeline has it on screen.
        case reveal(String)
        case notice(String)
    }

    func attach(_ target: any ItemMenuTarget) {
        self.target = target
        isAttached = true
        if let waiting {
            self.waiting = nil
            target.take(waiting)
        }
    }

    /// Hands `request` to the timeline showing, or to the next one to
    /// attach when there is none or `forNextTimeline`, as when the shell
    /// is switching views and the one showing is about to go.
    func send(_ request: Request, forNextTimeline: Bool = false) {
        if !forNextTimeline, let target {
            target.take(request)
        } else {
            waiting = request
        }
    }

    /// The old timeline may go after the new one has attached.
    func detach(_ target: any ItemMenuTarget) {
        guard self.target === target else { return }
        self.target = nil
        isAttached = false
    }
}

extension FocusedValues {
    @Entry var timelineItems: TimelineItems?
}

/// The Item menu: Open Original (⌘O), Bookmark (⌘K) and the rest of the
/// row menu, for the current row. Bookmark removes the bookmark from a
/// bookmarked row, as the row's icon does. On iOS it shows in the hardware
/// keyboard's shortcut list.
struct ItemCommands: Commands {
    @FocusedValue(\.timelineItems) private var items

    var body: some Commands {
        CommandMenu("Item") {
            item(.openOriginal).keyboardShortcut("o")
            item(.openThread)
            item(.openAuthor)
            Divider()
            item(.bookmark).keyboardShortcut("k")
            Divider()
            item(.copyLink)
            item(.copyText)
            item(.share)
        }
    }

    private func item(_ action: ItemAction) -> some View {
        Button(action.title) { items?.target?.performOnCurrentRow(action) }
            .disabled(items?.isAttached != true)
    }
}
