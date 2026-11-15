import Foundation
import Testing
@testable import InfluxKit

private let t0 = Date(timeIntervalSince1970: 1_793_000_000)

private func row(
    _ key: String = "k", body: String, title: String? = nil, card: String? = nil, quote: String? = nil,
    author: String = "Ana Ruiz", handle: String = "@ana@example.social", source: String = "Mastodon"
) -> TimelineRow {
    TimelineRow(
        id: 1, kind: title == nil ? .post : .article, mergeKey: key, sourceID: "s", sourceTitle: source, colorIndex: 0,
        authorName: author, authorHandle: handle, title: title, body: body, url: nil,
        publishedAt: t0, sortDate: t0, boostedBy: [], replyToHandle: nil,
        linkCard: card.map { Item.LinkCard(url: "https://example.com", site: "example.com", title: $0) }, media: [],
        quote: quote.map { Item.Quote(mergeKey: "q", url: nil, authorName: "Bo", authorHandle: "@bo", body: $0) },
        isRead: false, viewer: nil, links: []
    )
}

private func finds(_ query: String, in row: TimelineRow) -> Bool {
    TimelineSearch(query).matches(row)
}

@Suite struct FindInTimeline {
    @Test func wholeWordsIgnoringCaseAndAccents() {
        #expect(finds("cat", in: row(body: "My CAT! is asleep")))
        #expect(finds("cafe", in: row(body: "Off to the Café")))
        #expect(finds("CAFÉ", in: row(body: "off to the cafe")))
        #expect(!finds("cat", in: row(body: "A category of things")))
        #expect(!finds("cat", in: row(body: "bobcats")))
    }

    @Test func everyWordMustBeThereInAnyOrderAndAnyPlace() {
        let post = row(body: "The dog barked", title: "A cat story")
        #expect(finds("cat dog", in: post))
        #expect(finds("dog cat", in: post))
        #expect(!finds("cat mouse", in: post))
        #expect(finds("  cat   dog  ", in: post))
    }

    @Test func looksAtTheWordsAFilterLooksAt() {
        #expect(finds("eclipse", in: row(body: "x", title: "Eclipse tonight")))
        #expect(finds("eclipse", in: row(body: "x", card: "Watching the eclipse")))
        #expect(finds("eclipse", in: row(body: "x", quote: "Did you see the eclipse?")))
    }

    @Test func alsoLooksAtTheAuthorAndTheSource() {
        #expect(finds("ruiz", in: row(body: "x")))
        #expect(finds("@ana", in: row(body: "x")))
        #expect(finds("ana", in: row(body: "x", author: "Someone", handle: "@ana@example.social")))
        #expect(finds("verge", in: row(body: "x", source: "The Verge")))
        #expect(finds("ana verge", in: row(body: "x", source: "The Verge")))
        #expect(!finds("bo", in: row(body: "x")), "The quoted post's author isn't searched, only its text")
    }

    @Test func trailingPunctuationIsDroppedButTagsAndHandlesKeepTheirMark() {
        #expect(finds("asleep.", in: row(body: "My cat is asleep")))
        #expect(finds("\"asleep\"", in: row(body: "My cat is asleep")))
        #expect(finds("cat…", in: row(body: "My cat is asleep")))
        #expect(finds("cat，", in: row(body: "My cat is asleep")))
        #expect(finds("«cat»", in: row(body: "My cat is asleep")))
        #expect(finds("#swift", in: row(body: "Loving #swift today")))
        #expect(!finds("#swift", in: row(body: "Loving swift today")))
        #expect(!finds("#swift", in: row(body: "Loving #SwiftUI today")))
    }

    @Test func anEmptyQueryFindsNothing() throws {
        #expect(TimelineSearch("").isEmpty)
        #expect(TimelineSearch("   ").isEmpty)
        #expect(TimelineSearch("!?").isEmpty)
        #expect(!finds("", in: row(body: "anything")))
        #expect(try TimelineSearch(" ").results(in: [row(body: "anything")]).isEmpty)
    }

    @Test func repeatedWordsCountOnce() {
        #expect(TimelineSearch("cat Cat CÁT").words == ["cat"])
    }

    @Test func resultsKeepTheTimelineOrder() throws {
        let rows = [row("a", body: "cat one"), row("b", body: "dog"), row("c", body: "cat two"), row("d", body: "Cat three")]
        #expect(try TimelineSearch("cat").results(in: rows).map(\.mergeKey) == ["a", "c", "d"])
    }

    @Test func aCancelledSearchStops() async {
        let rows = (0..<1_000).map { row("k\($0)", body: "cat \($0)") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SearchableRows(rows).results(for: TimelineSearch("cat"))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func searchesOnlyTheRowsTheViewShows() async throws {
        let store = try InfluxStore.inMemory()
        let rss = Source(id: "rss:https://example.com/feed", kind: .rss, title: "Example", url: "https://example.com/feed", colorIndex: 3)
        let mastodon = Source(id: "mastodon:@me@example.social:home", kind: .mastodonHome, accountID: "@me@example.social", title: "Mastodon", colorIndex: 1)
        try await store.save(sources: [rss, mastodon])
        func post(_ id: String, _ source: Source, _ body: String, at offset: TimeInterval) -> Item {
            Item(
                sourceID: source.id, remoteID: id, kind: .post, mergeKey: "post:\(id)",
                authorName: "Ana Ruiz", authorHandle: "@ana", body: body,
                publishedAt: t0.addingTimeInterval(offset), fetchedAt: t0.addingTimeInterval(offset)
            )
        }
        try await store.insert([post("1", mastodon, "Eclipse tonight", at: 0), post("2", rss, "Eclipse photos", at: 1), post("3", mastodon, "Eclipse spoiler", at: 2)])
        try await store.save(filter: ContentFilter(id: "f", pattern: "spoiler", match: .keyword))
        var view = SavedView(id: "v", name: "Feeds", sourceIDs: [rss.id], sortIndex: 0)
        try await store.save(view: view)

        let search = TimelineSearch("eclipse")
        #expect(try search.results(in: try await store.rows(inView: SavedView.allID)).map(\.body) == ["Eclipse tonight", "Eclipse photos"])
        #expect(try search.results(in: try await store.rows(inView: "v")).map(\.body) == ["Eclipse photos"])
        view.sourceIDs.append(mastodon.id)
        try await store.save(view: view)
        #expect(try search.results(in: try await store.rows(inView: "v")).map(\.body) == ["Eclipse tonight", "Eclipse photos"])
    }

    @Test func searchingTwoThousandRowsIsFast() async throws {
        let store = try InfluxStore.inMemory()
        try await SeedFeed.load(into: store, count: 2_000)
        let rows = try await store.rows(inView: SavedView.allID)
        #expect(rows.count > 1_500)
        let clock = ContinuousClock()
        var searchable: SearchableRows?
        let prepared = clock.measure { searchable = SearchableRows(rows) }
        // Once each time the view's rows change, off the main thread.
        #expect(prepared < .milliseconds(150), "Preparing took \(prepared)")
        // A word that is rare, so nearly every row is read in full, then
        // two common ones.
        for query in ["zyzzyva", "the apple", "swift"] {
            let elapsed = try clock.measure { _ = try searchable?.results(for: TimelineSearch(query)) }
            // One keystroke's search, also off the main thread.
            #expect(elapsed < .milliseconds(50), "\(query) took \(elapsed)")
        }
    }
}
