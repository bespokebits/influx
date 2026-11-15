import Foundation
import Testing
@testable import InfluxKit

// What the thread view says where a thread has gaps (#234): one note per
// edge, each reason once, in a fixed order, and a way to the whole thread.
@Suite struct ThreadMissingNoteTests {
    private static func post(_ id: String, url: String? = "https://www.example.com/posts/1") -> Item {
        Item(sourceID: "feed", remoteID: id, kind: .post, mergeKey: "https://example.com/posts/\(id)",
             authorName: "Iris Calder", authorHandle: "@iris@example.com", body: "A post", url: url,
             publishedAt: Date(timeIntervalSince1970: 1_794_200_000), fetchedAt: Date(timeIntervalSince1970: 1_794_200_000))
    }

    private static func thread(_ gaps: [PostThread.Gap], url: String? = "https://www.example.com/posts/1") -> PostThread {
        PostThread(ancestors: [post("a")], post: post("f", url: url), replies: [], gaps: gaps)
    }

    @Test func aThreadWithNoGapsHasNoNote() {
        let thread = Self.thread([])
        #expect(thread.missingNote(at: .ancestors) == nil)
        #expect(thread.missingNote(at: .replies) == nil)
    }

    @Test func eachEdgeHasItsOwnNote() throws {
        let thread = Self.thread([.init(position: .replies, reason: .notCollected), .init(position: .ancestors, reason: .deleted)])
        let earlier = try #require(thread.missingNote(at: .ancestors))
        #expect(earlier.heading == "Earlier posts missing")
        #expect(earlier.sentences == ["Some earlier posts were deleted by their authors."])
        let later = try #require(thread.missingNote(at: .replies))
        #expect(later.heading == "Later posts missing")
        #expect(later.sentences == ["The thread goes on past what was collected."])
    }

    @Test func reasonsComeInAFixedOrderWhateverTheServiceSent() throws {
        let thread = Self.thread([
            .init(position: .ancestors, reason: .other), .init(position: .ancestors, reason: .notCollected),
            .init(position: .ancestors, reason: .unavailable), .init(position: .ancestors, reason: .deleted),
        ])
        let note = try #require(thread.missingNote(at: .ancestors))
        #expect(note.reasons == [.deleted, .unavailable, .notCollected, .other])
        #expect(note.sentences == [
            "Some earlier posts were deleted by their authors.",
            "Some earlier posts are private, blocked or unreachable.",
            "The conversation starts further back than was collected.",
            "Some earlier posts are missing.",
        ])
    }

    @Test func everySentenceSaysSomeAndNeverACount() {
        for position in [PostThread.Gap.Position.ancestors, .replies] {
            for reason in PostThread.Gap.Reason.allCases {
                let sentence = PostThread.MissingNote(position: position, reasons: [reason]).sentences[0]
                #expect(!sentence.contains { $0.isNumber }, "\(sentence)")
                #expect(sentence.hasSuffix("."))
            }
        }
        #expect(PostThread.MissingNote(position: .replies, reasons: [.deleted, .unavailable, .other]).sentences == [
            "Some later posts were deleted by their authors.",
            "Some later posts are private, blocked or unreachable.",
            "Some later posts are missing.",
        ])
    }

    @Test func theWholeThreadIsThePostsOwnPage() throws {
        let whole = try #require(Self.thread([]).wholeThread)
        #expect(whole.url.absoluteString == "https://www.example.com/posts/1")
        #expect(whole.site == "example.com")
        #expect(Self.thread([], url: nil).wholeThread == nil)
        #expect(Self.thread([], url: "at://did:plc:x/app.bsky.feed.post/1").wholeThread == nil)
        #expect(Self.thread([], url: "javascript:alert(1)").wholeThread == nil)
    }
}
