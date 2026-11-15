// Stands in for the services on sample runs, so likes, boosts, bookmarks
// and threads work on the seeded timeline in previews and UI tests without
// a network or an account.
import Foundation
import InfluxKit

struct SampleConnector: Connector {
    /// Refuse every action as a signed-out account's would.
    var refuses = false

    func handles(_ source: Source) -> Bool { true }

    func fetch(_ request: FetchRequest, from source: Source) async throws -> FetchedPage {
        throw ConnectorError.unsupported
    }

    var supportedActions: Set<ConnectorAction> { Set(ConnectorAction.allCases) }

    func perform(_ action: ConnectorAction, on item: ItemReference) async throws -> Item.Viewer {
        try await Task.sleep(for: .milliseconds(150))
        if refuses { throw ConnectorError.unauthorized }
        return (item.viewer ?? Item.Viewer()).applying(action)
    }

    func offersThread(of item: ItemReference) -> Bool { true }

    /// The post with one post above it and a few replies, made up, with
    /// posts missing at both edges, a quote and a quote of a post that is
    /// unavailable.
    func thread(of reference: ItemReference) async throws -> PostThread {
        try await Task.sleep(for: .milliseconds(300))
        func post(_ id: String, _ author: String, _ body: String) -> Item {
            Item(sourceID: reference.sourceID, remoteID: id, kind: .post, mergeKey: "sample:\(id)",
                 authorName: author, authorHandle: "@\(author.lowercased().replacingOccurrences(of: " ", with: "."))",
                 body: body, publishedAt: Date(), fetchedAt: Date(), viewer: Item.Viewer())
        }
        let id = reference.remoteID
        var focus = post(id, "Ana Ruiz", "The post you opened.")
        focus.viewer = reference.viewer ?? Item.Viewer()
        focus.url = "https://example.com/sample/\(id)"
        var parent = post("\(id)-parent", "Sam Okafor", "What started the conversation.")
        parent.quote = Item.Quote(mergeKey: "sample:quoted", url: "https://example.org/@trust/2001", authorName: "Riverside Trust",
                                  authorHandle: "@trust@example.org", body: "The boardwalk works finish this week.")
        var later = post("\(id)-r2", "Lena Fischer", "Another reply.")
        later.quote = .unavailable(url: "https://example.net/@notices/1134028")
        return PostThread(
            ancestors: [parent],
            post: focus,
            replies: [
                .init(item: post("\(id)-r1", "Grace Liu", "A reply."), depth: 1),
                .init(item: post("\(id)-r1a", "Omar Haddad", "A reply to the reply."), depth: 2),
                .init(item: later, depth: 1),
            ],
            gaps: [.init(position: .ancestors, reason: .deleted), .init(position: .replies, reason: .notCollected)]
        )
    }
}
