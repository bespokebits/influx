import Foundation

/// Finds rows in a timeline the reader has already loaded: Find in
/// Timeline. It looks at the words a keyword filter looks at (headline,
/// text, link card title and quoted post) and also the author's name and
/// handle and the source's name. Words match whole, ignoring case and
/// accents, the same way `TimelineFilter` keywords do, and a row must hold
/// every word of the query, in any order and in any of those places.
///
/// It searches only the rows it is given, which are the current view's rows
/// with its filters already applied, so a post a filter hides is never
/// found. Nothing is indexed: a search is a scan, cheap enough for the few
/// thousand rows the store keeps (ADR 0024).
public struct TimelineSearch: Sendable, Hashable {
    /// The query's words, folded for matching, in the order typed.
    public let words: [String]

    /// A search for the words in `query`. Spaces separate words; punctuation at
    /// either end, such as a comma, full stop or ellipsis, is dropped, but a leading
    /// `#` or `@` is kept, so "@ana" finds the handle and "#swift" the tag.
    public init(_ query: String) {
        var words: [String] = []
        for piece in query.split(whereSeparator: { $0.isWhitespace }) {
            let trimmed = piece.trimmingCharacters(in: Self.droppedPunctuation)
            let folded = TimelineFilter.fold(trimmed)
            if !folded.isEmpty, !words.contains(folded) { words.append(folded) }
        }
        self.words = words
    }

    /// Whether the query has no words, so it finds nothing.
    public var isEmpty: Bool { words.isEmpty }

    /// Whether `row` holds every word of the query. An empty query matches
    /// nothing.
    public func matches(_ row: TimelineRow) -> Bool {
        guard !isEmpty else { return false }
        let texts = Self.texts(of: row).map(TimelineFilter.fold)
        return words.allSatisfy { word in texts.contains { TimelineFilter.contains(word: word, in: $0) } }
    }

    /// The rows of `rows` that match, in the same order. Searching the
    /// same rows again as the reader types is quicker through
    /// `SearchableRows`, which folds each row's words once.
    public func results(in rows: [TimelineRow]) throws -> [TimelineRow] {
        try SearchableRows(rows).results(for: self)
    }

    /// The words of a row that a search looks at.
    static func texts(of row: TimelineRow) -> [String] {
        [row.title, row.body, row.linkCard?.title, row.quote?.body, row.authorName, row.authorHandle, row.sourceTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    /// Punctuation dropped from either end of a query word, in any
    /// script: an ellipsis or a full-width comma as well as a full stop.
    /// `#` and `@` aren't in it, since they start tags and handles.
    private static let droppedPunctuation = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "#@"))
}

/// A view's rows made ready to search: each row's words are folded once,
/// when the rows are read, so each keystroke only looks for its words.
/// Build it off the main thread; it is the slow half.
public struct SearchableRows: Sendable {
    public let rows: [TimelineRow]
    /// Each row's searched words, folded, one per line. A line break is no
    /// letter or digit, so a word can't run from one field into the next.
    private let folded: [String]

    public init(_ rows: [TimelineRow]) {
        self.rows = rows
        folded = rows.map { TimelineFilter.fold(TimelineSearch.texts(of: $0).joined(separator: "\n")) }
    }

    /// The rows that hold every word of `search`, in timeline order. It
    /// checks for cancellation as it goes, so a search the next keystroke
    /// replaces stops early, and throws `CancellationError` when it does.
    public func results(for search: TimelineSearch) throws -> [TimelineRow] {
        guard !search.isEmpty else { return [] }
        var found: [TimelineRow] = []
        for index in rows.indices {
            if index % 256 == 0 { try Task.checkCancellation() }
            let text = folded[index]
            if search.words.allSatisfy({ TimelineFilter.contains(word: $0, in: text) }) {
                found.append(rows[index])
            }
        }
        return found
    }
}
