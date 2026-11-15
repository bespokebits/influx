// The link back to an item (`ItemLink`), as another app opens it: Sammy's
// "Open in Influx" on a task made from a bookmark. A bookmark opens
// Bookmarks scrolled to it, briefly highlighted; an item whose bookmark was
// removed opens as a tap on its row would; anything else falls back to
// Bookmarks.
import Foundation
import os
import InfluxKit

@MainActor
enum ItemLinkRoute {
    /// What the reader is told when neither the item nor its bookmark is
    /// on this device. The web link is in the Sammy task's notes.
    static let goneNotice = "That bookmark is no longer in Influx."

    /// The scheme this build registers (`CFBundleURLTypes`, from
    /// `INFLUX_BUNDLE_IDENTIFIER` in project.yml): `dev.bespokebits.influx`
    /// for the App Store build, and each other build's own bundle ID, so a
    /// dev build never takes the real app's links.
    static var scheme: String { Bundle.main.bundleIdentifier ?? ItemLink.scheme }

    private static let log = Logger(subsystem: "dev.bespokebits.influx", category: "ItemLink")

    /// Opens `url` if it is a link back to an item, and says whether it
    /// was. Anything else on the scheme (the sign-in callbacks, which the
    /// sign-in sheet takes itself) is left alone.
    @discardableResult
    static func open(_ url: URL, store: InfluxStore, views: Views, items: TimelineItems, scheme: String = scheme) async -> Bool {
        guard let link = ItemLink(url, scheme: scheme) else { return false }
        let target = (try? await store.target(of: link)) ?? .gone
        log.info("item link: \(target.name, privacy: .public)")
        switch target {
        case .bookmark(let row):
            // Bookmarks opens a new timeline, which goes to the row once
            // it has shown its rows.
            let switching = views.selectedID != SavedView.bookmarksID
            views.selectedID = SavedView.bookmarksID
            items.send(.reveal(row.mergeKey), forNextTimeline: switching)
        case .row(let row):
            items.send(.open(row))
        case .bookmarked:
            views.selectedID = SavedView.bookmarksID
        case .gone:
            // Bookmarks opens a new timeline, which shows the notice.
            let switching = views.selectedID != SavedView.bookmarksID
            views.selectedID = SavedView.bookmarksID
            items.send(.notice(goneNotice), forNextTimeline: switching)
        }
        return true
    }
}

private extension ItemLinkTarget {
    /// What the log says the link led to, without the item.
    var name: String {
        switch self {
        case .bookmark: "a bookmark"
        case .row: "an item no longer bookmarked"
        case .bookmarked: "a bookmark not stored here"
        case .gone: "nothing"
        }
    }
}
