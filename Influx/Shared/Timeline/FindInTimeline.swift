// Find in Timeline (ADR 0024): a search over the rows the timeline is
// showing, made ready and searched off the main thread. Typing replaces the
// timeline with a list of the rows that match; choosing one brings the
// timeline back at that row, with a way back to where the reader was.
import SwiftUI
import InfluxKit

/// A window's Find in Timeline. The shell keeps one per window, beside
/// `TimelineJumps`, which leads it to the timeline showing.
@MainActor
@Observable
final class TimelineFind {
    /// Whether the search field shows.
    var isPresented = false {
        didSet { if !isPresented, oldValue { clear() } }
    }
    /// What the reader typed. Each change searches again, cancelling the
    /// search before.
    var query = "" {
        didSet { if query != oldValue { search() } }
    }
    /// The matching rows, in timeline order.
    private(set) var results: [TimelineRow] = []
    /// The words the results matched, for marking them in the list.
    private(set) var words: [String] = []
    /// Whether `results` answers the current query, so "no matches" isn't
    /// shown while a search is still running.
    private(set) var isCurrent = true
    /// Goes up each time the field should take the keyboard.
    private(set) var focusRequest = 0

    @ObservationIgnored private let jumps: TimelineJumps
    /// The rows last made ready, and which timeline, and which version of
    /// its rows, they came from. Each timeline counts its own versions, so
    /// a version means nothing without its timeline.
    @ObservationIgnored private var prepared: (timeline: ObjectIdentifier, version: Int, rows: SearchableRows)?
    @ObservationIgnored private var searching: Task<Void, Never>?

    init(jumps: TimelineJumps) {
        self.jumps = jumps
    }

    /// Whether the results list stands in for the timeline.
    var showsResults: Bool { isPresented && !TimelineSearch(query).isEmpty }

    /// ⌘F, or the search button: shows the field and gives it the keyboard.
    func begin() {
        isPresented = true
        focusRequest += 1
    }

    /// Esc or Cancel: back to the timeline where it was.
    func cancel() {
        isPresented = false
    }

    /// A result chosen: the timeline comes back at that row.
    func choose(_ row: TimelineRow) {
        let key = row.mergeKey
        isPresented = false
        // After the list has gone, so the timeline is on screen to move.
        Task { [jumps] in
            jumps.timeline?.jump(toResult: key)
        }
    }

    private func clear() {
        searching?.cancel()
        searching = nil
        if !query.isEmpty { query = "" }
        results = []
        words = []
        isCurrent = true
    }

    private func search() {
        searching?.cancel()
        let search = TimelineSearch(query)
        guard !search.isEmpty, let timeline = jumps.timeline else {
            searching = nil
            results = []
            words = []
            isCurrent = true
            return
        }
        isCurrent = false
        let (rows, version) = timeline.searchRows
        let id = ObjectIdentifier(timeline)
        let ready = prepared.flatMap { $0.timeline == id && $0.version == version ? $0.rows : nil }
        searching = Task.detached(priority: .userInitiated) { [weak self] in
            let searchable = ready ?? SearchableRows(rows)
            guard let found = try? searchable.results(for: search) else { return }
            await self?.finish(found, words: search.words, rows: searchable, timeline: id, version: version)
        }
    }

    /// The timeline's rows changed, or another timeline took over: an open
    /// search runs again over the new rows.
    func rowsChanged() {
        if showsResults { search() }
    }

    private func finish(_ found: [TimelineRow], words: [String], rows: SearchableRows, timeline: ObjectIdentifier, version: Int) {
        prepared = (timeline, version, rows)
        // Superseded: a newer query, or newer rows, has its own search.
        guard TimelineSearch(query).words == words,
              let current = jumps.timeline, ObjectIdentifier(current) == timeline, current.searchRows.version == version
        else { return }
        results = found
        self.words = words
        isCurrent = true
    }
}

/// What stands in for the timeline while the reader types: the matching
/// rows, newest at the bottom like the timeline.
struct FindResults: View {
    let find: TimelineFind

    var body: some View {
        ZStack {
            Color(Broadsheet.paper)
            if find.results.isEmpty {
                if find.isCurrent {
                    ContentUnavailableView.search(text: find.query)
                        .accessibilityIdentifier("find-no-results")
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(find.results) { row in
                            Button { find.choose(row) } label: {
                                FindResultRow(row: row, words: find.words)
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("find-result")
                            Rectangle()
                                .fill(Color(Broadsheet.rule))
                                .frame(height: 1 / 2)
                        }
                    }
                }
                .defaultScrollAnchor(.bottom)
                .accessibilityIdentifier("find-results")
                // Under the newest match, where the list opens, so it's
                // always in view.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Text(find.results.count == 1 ? "1 match" : "\(find.results.count) matches")
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(Color(Broadsheet.ink2))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color(Broadsheet.paper))
                        .accessibilityIdentifier("find-count")
                }
            }
        }
        #if os(macOS)
        .onExitCommand { find.cancel() }
        #endif
    }
}

/// One match: the source dot, who and when, then the headline and the
/// text around the first match, with the matching words in bold.
struct FindResultRow: View {
    let row: TimelineRow
    let words: [String]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Color(Broadsheet.sourceColor(row.colorIndex)))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Self.marked(row.authorName.isEmpty ? row.sourceTitle : row.authorName, words))
                        .font(.system(.subheadline, design: .serif).weight(.semibold))
                        .lineLimit(1)
                    Text(Self.marked(row.sourceTitle, words))
                        .font(.system(.subheadline, design: .serif))
                        .foregroundStyle(Color(Broadsheet.ink2))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text((row.postedAt ?? row.publishedAt).formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                        .font(.system(.footnote, design: .serif))
                        .foregroundStyle(Color(Broadsheet.ink2))
                        .lineLimit(1)
                }
                if let title = row.title, !title.isEmpty {
                    Text(Self.marked(title, words))
                        .font(.system(.headline, design: .serif))
                        .lineLimit(2)
                }
                let text = Self.excerpt(of: row, words: words)
                if !text.isEmpty {
                    Text(Self.marked(text, words))
                        .font(.system(.body, design: .serif))
                        .lineLimit(3)
                }
            }
        }
        .foregroundStyle(Color(Broadsheet.ink))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The row's text on one line, starting a little before the first
    /// match when that is far in, else its link card title or quoted post.
    static func excerpt(of row: TimelineRow, words: [String]) -> String {
        excerpt(of: [row.body, row.linkCard?.title, row.quote?.body].compactMap { $0 }, words: words)
    }

    /// The first of `texts` with a match, or the first, as `excerpt(of:words:)`.
    static func excerpt(of texts: [String], words: [String]) -> String {
        let candidates = texts.filter { !$0.isEmpty }
        let text = (candidates.first { text in words.contains { firstMatch(of: $0, in: text) != nil } } ?? candidates.first ?? "")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard let match = words.compactMap({ firstMatch(of: $0, in: text) }).min(by: { $0.lowerBound < $1.lowerBound }),
              text.distance(from: text.startIndex, to: match.lowerBound) > 90
        else { return text }
        let start = text.index(match.lowerBound, offsetBy: -40)
        let wordStart = text[start...].firstIndex(of: " ").map { text.index(after: $0) } ?? start
        return "…" + text[wordStart...]
    }

    /// `text` with each of `words` in bold, matched as the search matches
    /// them, ignoring case and accents.
    static func marked(_ text: String, _ words: [String]) -> AttributedString {
        var marked = AttributedString(text)
        for word in words {
            var searchStart = text.startIndex
            while searchStart < text.endIndex, let found = firstMatch(of: word, in: text, from: searchStart) {
                if let range = Range<AttributedString.Index>(found, in: marked) {
                    marked[range].inlinePresentationIntent = .stronglyEmphasized
                }
                searchStart = found.upperBound
            }
        }
        return marked
    }

    /// The first place `word` appears in `text` as the search matches it:
    /// ignoring case and accents, and whole, so "cat" isn't found in
    /// "category". An end that is itself punctuation, as in "#swift", needs
    /// no boundary there.
    static func firstMatch(of word: String, in text: String, from start: String.Index? = nil) -> Range<String.Index>? {
        let first = word.unicodeScalars.first.map(isWordScalar) ?? false
        let last = word.unicodeScalars.last.map(isWordScalar) ?? false
        var searchStart = start ?? text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: searchStart..<text.endIndex) {
            let before = found.lowerBound == text.startIndex ? nil : text.unicodeScalars[text.unicodeScalars.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text.unicodeScalars[found.upperBound]
            let startsClean = !first || before.map { !isWordScalar($0) } ?? true
            let endsClean = !last || after.map { !isWordScalar($0) } ?? true
            if startsClean, endsClean { return found }
            searchStart = text.index(after: found.lowerBound)
        }
        return nil
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
    }
}

/// "Back to where you were", shown over the timeline after a Find result
/// until the reader scrolls on from it.
struct ReturnFromResultButton: View {
    let jumps: TimelineJumps

    var body: some View {
        if jumps.offersReturn {
            Button("Back to where you were", systemImage: "arrow.uturn.backward") {
                jumps.timeline?.returnFromResult()
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("find-back")
        }
    }
}
