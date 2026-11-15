// What the timeline does when the reader acts on a row: sends a like, boost
// or bookmark through the row's connector, or flips Influx's own bookmark,
// and finds what a thread view needs. The platform view controllers turn taps into these calls and show
// the result.
import Foundation
import os
import InfluxKit

@MainActor
final class RowInteractions {
    private let app: AppModel
    private static let log = Logger(subsystem: "dev.bespokebits.influx", category: "Actions")

    init(app: AppModel) {
        self.app = app
    }

    /// Flips `toggle` on the row's post. The row shows the change at once;
    /// returns what to tell the reader if the service refused it, in which
    /// case the row has gone back. A row that keeps its own bookmark (an
    /// article, a rich feed's post) has no service to send it to: Influx
    /// keeps it, and syncs it, and it is the row's only action.
    ///
    /// A bookmark made here, and only here (or in a thread), also goes to
    /// the Inbox of each Sammy account with Bookmarks to Sammy Inbox on;
    /// what came of that is the notice then. Sync applies bookmarks from
    /// other devices without coming through here, so they never send.
    func toggle(_ toggle: Item.Viewer.Toggle, on row: TimelineRow) async -> String? {
        if row.keepsOwnBookmark {
            guard toggle == .bookmark else { return nil }
            do {
                let isBookmarked = try await app.store.toggleOwnBookmark(mergeKey: row.mergeKey)
                if row.kind == .article { return await app.sammyInbox.article(row, isBookmarked: isBookmarked) }
                guard let item = try await app.store.item(id: row.id) else { return nil }
                return await ownPostBookmark(of: item, isBookmarked: isBookmarked)
            } catch {
                Self.log.error("own \(toggle.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return "Couldn't \(Self.verb(toggle, row.viewer))."
            }
        }
        guard let item = try? await app.store.item(id: row.id) else { return nil }
        return await self.toggle(toggle, on: item)
    }

    /// As above, for any post, stored or in a thread; on success `done`
    /// gets the post's new state. A rich feed's post in a thread has only
    /// Influx's own bookmark, which needs no signed-in account.
    func toggle(_ toggle: Item.Viewer.Toggle, on item: Item, done: (Item.Viewer) -> Void = { _ in }) async -> String? {
        if (try? await app.store.keepsOwnBookmark(item)) == true {
            guard toggle == .bookmark else { return nil }
            do {
                let isBookmarked = try await app.store.toggleOwnBookmark(mergeKey: item.mergeKey)
                done(Item.Viewer(bookmarked: isBookmarked))
                return await ownPostBookmark(of: item, isBookmarked: isBookmarked)
            } catch {
                Self.log.error("own \(toggle.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                return "Couldn't \(Self.verb(toggle, item.viewer))."
            }
        }
        guard let connector = app.connector(forSource: item.sourceID) else {
            return "Couldn't \(Self.verb(toggle, item.viewer)): this account isn't signed in here. Use Sign in again at the top."
        }
        do {
            guard let viewer = try await app.postActions.toggle(toggle, on: item, with: connector) else { return nil }
            done(viewer)
            guard toggle == .bookmark else { return nil }
            return await app.sammyInbox.post(item, isBookmarked: viewer.bookmarked)
        } catch {
            // Says why the service refused, which the notice doesn't.
            Self.log.error("\(toggle.rawValue, privacy: .public) on \(item.sourceID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return Self.message(for: error, verb: Self.verb(toggle, item.viewer))
        }
    }

    /// The Sammy Inbox side of a rich post's own bookmark, sent as any
    /// post's is. Removing it while another copy of the post (one from
    /// Mastodon or Bluesky, ADR 0014) is still bookmarked on its service
    /// leaves the post in Bookmarks, so its waiting Inbox capture stays.
    private func ownPostBookmark(of item: Item, isBookmarked: Bool) async -> String? {
        if !isBookmarked, (try? await app.store.isBookmarked(mergeKey: item.mergeKey, kind: .post)) == true { return nil }
        return await app.sammyInbox.post(item, isBookmarked: isBookmarked)
    }

    /// `item`'s own bookmark, when Influx keeps it and the store holds the
    /// post (`InfluxStore.ownBookmark(of:)`); nil for a post whose state
    /// is its service's, or one only seen in a thread.
    func ownBookmark(of item: Item) async -> Item.Viewer? {
        try? await app.store.ownBookmark(of: item)
    }

    /// What a thread view opens with: the row's stored post (for a rich
    /// post, its copy that names the thread), and the connector to fetch
    /// the rest through. Nil when the post has gone or its account isn't
    /// signed in here.
    func thread(for row: TimelineRow) async -> (post: Item, connector: any Connector)? {
        guard let item = try? await app.store.item(id: row.threadItemID ?? row.id),
              let connector = app.connector(forSource: item.sourceID) else { return nil }
        return (item, connector)
    }

    func markRead(_ row: TimelineRow) {
        let store = app.store
        Task { try? await store.setArticle(mergeKey: row.mergeKey, read: true) }
    }

    var actions: PostActions { app.postActions }

    func connector(forSource sourceID: String) -> (any Connector)? {
        app.connector(forSource: sourceID)
    }

    private static func verb(_ toggle: Item.Viewer.Toggle, _ viewer: Item.Viewer?) -> String {
        let on = viewer?.isOn(toggle) ?? false
        return switch toggle {
        case .like: on ? "unlike it" : "like it"
        case .boost: on ? "undo the boost" : "boost it"
        case .bookmark: on ? "remove the bookmark" : "bookmark it"
        }
    }

    /// A short line for a failed action, shown briefly over the timeline.
    static func message(for error: any Error, verb: String) -> String {
        switch error {
        case ConnectorError.offline: "Couldn't \(verb): no connection."
        case ConnectorError.unauthorized: "Couldn't \(verb): this account is signed out. Use Sign in again at the top."
        case ConnectorError.rateLimited: "Couldn't \(verb): the server is busy. Try again soon."
        case ConnectorError.notFound: "Couldn't \(verb): the post is gone."
        default: "Couldn't \(verb)."
        }
    }
}
