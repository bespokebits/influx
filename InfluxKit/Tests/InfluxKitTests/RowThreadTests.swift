import Foundation
import Testing
@testable import InfluxKit

/// A row says whether its post's thread can be opened, which its source's
/// service decides, and on a rich feed the post itself.
@Suite struct RowThreads {
    private func row(kind: Item.Kind, from source: Source.Kind, actionRef: String? = nil) async throws -> TimelineRow {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: [Source(id: "s", kind: source, accountID: "a", title: "S", colorIndex: 0)])
        try await store.insert([Item(sourceID: "s", remoteID: "1", kind: kind, mergeKey: "https://example.com/1",
                                     authorName: "Ana", authorHandle: "@ana", body: "Hello", url: "https://example.com/1",
                                     publishedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                     fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), actionRef: actionRef)])
        return try #require(try await store.rows().first)
    }

    @Test(arguments: [Source.Kind.mastodonHome, .mastodonList, .blueskyFollowing, .blueskyFeed])
    func socialPostsHaveThreads(_ source: Source.Kind) async throws {
        let row = try await row(kind: .post, from: source)
        #expect(row.hasThread && !row.isRich)
    }

    @Test func richPostsHaveOneOnlyWhereTheyNameIt() async throws {
        let plain = try await row(kind: .post, from: .sammyFeed)
        #expect(!plain.hasThread && plain.isRich)
        #expect(try await row(kind: .post, from: .sammyFeed, actionRef: "thread:contract-thread-1").hasThread)
        // Only a thread reference names one.
        #expect(try await !row(kind: .post, from: .sammyFeed, actionRef: "contract-thread-1").hasThread)
        #expect(try await !row(kind: .article, from: .sammyFeed, actionRef: "thread:contract-thread-1").hasThread)
    }

    /// One post in two feeds, where only the copy stored second names its
    /// thread: the row stays shown from the first, and opens the thread
    /// from the second.
    @Test func aRichPostsThreadComesFromWhicheverCopyNamesIt() async throws {
        let store = try InfluxStore.inMemory()
        try await store.save(sources: ["a", "b"].map { Source(id: $0, kind: .sammyFeed, accountID: "x", title: $0, colorIndex: 0) })
        func copy(_ source: String, _ actionRef: String?) -> Item {
            Item(sourceID: source, remoteID: "1", kind: .post, mergeKey: "https://example.com/1", authorName: "Ana",
                 authorHandle: "example.com", body: "Hello", url: "https://example.com/1",
                 publishedAt: Date(timeIntervalSince1970: 1_800_000_000), fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
                 actionRef: actionRef)
        }
        try await store.insert([copy("a", nil)])
        try await store.insert([copy("b", "thread:contract-thread-1")])
        let row = try #require(try await store.rows().first)
        #expect(try await store.item(id: row.id)?.sourceID == "a")
        #expect(row.hasThread)
        let threaded = try #require(row.threadItemID)
        #expect(try await store.item(id: threaded)?.sourceID == "b")
        // Out of scope, the other copy names nothing.
        #expect(try await store.rows(in: .sources(["a"])).first?.hasThread == false)
    }

    @Test(arguments: Source.Kind.allCases)
    func articlesHaveNone(_ source: Source.Kind) async throws {
        #expect(try await !row(kind: .article, from: source).hasThread)
    }
}
