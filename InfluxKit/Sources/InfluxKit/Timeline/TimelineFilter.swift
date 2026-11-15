import Foundation

/// Hides rows that match the reader's filters. It runs on the rows the
/// store reads, before the timeline lays anything out, so a hidden row never
/// takes space on screen and adding a filter never moves what is shown.
public struct TimelineFilter: Sendable {
    private let keywords: [String]
    private let expressions: [NSRegularExpression]

    /// A filter made of `filters`, skipping any that are switched off and
    /// any regular expression that doesn't compile, which hides nothing.
    public init(_ filters: [ContentFilter]) {
        var keywords: [String] = []
        var expressions: [NSRegularExpression] = []
        for filter in filters where filter.isEnabled {
            switch filter.match {
            case .keyword:
                let folded = Self.fold(filter.pattern.trimmingCharacters(in: .whitespacesAndNewlines))
                if !folded.isEmpty { keywords.append(folded) }
            case .regex:
                if let expression = Self.expression(filter.pattern) { expressions.append(expression) }
            }
        }
        self.keywords = keywords
        self.expressions = expressions
    }

    /// Whether the filter hides nothing.
    public var isEmpty: Bool { keywords.isEmpty && expressions.isEmpty }

    /// How long one regular expression may spend matching over one read of
    /// the timeline. A pattern such as `(a+)+$` can take exponential time
    /// on text that nearly matches; past this budget it stops hiding
    /// anything for the rest of the read, so a filter can't stall the
    /// timeline however it is written.
    public static let expressionBudget: Duration = .milliseconds(50)

    /// `rows` without the ones the filter hides, in the same order.
    public func apply(to rows: [TimelineRow]) -> [TimelineRow] {
        guard !isEmpty else { return rows }
        var budgets = Budgets(count: expressions.count)
        return rows.filter { !hides($0, budgets: &budgets) }
    }

    /// Whether `row` matches any keyword or expression. Keywords match
    /// whole words, ignoring case and accents, so "cat" hides "Cat!" but not
    /// "category"; a phrase matches as written, words in order. Expressions
    /// ignore case. Both look at the row's headline, text, link card title
    /// and quoted post, the words the reader sees.
    public func hides(_ row: TimelineRow) -> Bool {
        var budgets = Budgets(count: expressions.count)
        return hides(row, budgets: &budgets)
    }

    /// What each expression has left of `expressionBudget` in one read.
    private struct Budgets {
        var remaining: [Duration]

        init(count: Int) {
            remaining = Array(repeating: TimelineFilter.expressionBudget, count: count)
        }
    }

    private func hides(_ row: TimelineRow, budgets: inout Budgets) -> Bool {
        let texts = [row.title, row.body, row.linkCard?.title, row.quote?.body].compactMap { $0 }.filter { !$0.isEmpty }
        if !keywords.isEmpty {
            let folded = texts.map(Self.fold)
            if keywords.contains(where: { keyword in folded.contains { Self.contains(word: keyword, in: $0) } }) {
                return true
            }
        }
        for (index, expression) in expressions.enumerated() where budgets.remaining[index] > .zero {
            for text in texts where Self.matches(expression, text, budget: &budgets.remaining[index]) {
                return true
            }
        }
        return false
    }

    /// Whether `expression` matches `text`, giving up, as no match, once
    /// `budget` is spent. Progress reports arrive while a long match runs,
    /// so a runaway match is stopped partway through, not after.
    private static func matches(_ expression: NSRegularExpression, _ text: String, budget: inout Duration) -> Bool {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = start.advanced(by: budget)
        var found = false
        expression.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { result, _, stop in
            if result != nil {
                found = true
                stop.pointee = true
            } else if clock.now >= deadline {
                stop.pointee = true
            }
        }
        budget -= start.duration(to: clock.now)
        return found
    }

    /// The expression for `pattern`, matched ignoring case, or nil when it
    /// isn't a valid regular expression; the filter screen says so before
    /// saving one.
    public static func expression(_ pattern: String) -> NSRegularExpression? {
        guard !pattern.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Whether `word` appears in `text` with no letter or digit running
    /// straight on from either end. An end that is itself punctuation, as
    /// in "#swift", needs no boundary there.
    static func contains(word: String, in text: String) -> Bool {
        let first = word.unicodeScalars.first.map(isWordScalar) ?? false
        let last = word.unicodeScalars.last.map(isWordScalar) ?? false
        var searchStart = text.startIndex
        while let found = text.range(of: word, range: searchStart..<text.endIndex) {
            let before = found.lowerBound == text.startIndex ? nil : text.unicodeScalars[text.unicodeScalars.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text.unicodeScalars[found.upperBound]
            let startsClean = !first || before.map { !isWordScalar($0) } ?? true
            let endsClean = !last || after.map { !isWordScalar($0) } ?? true
            if startsClean, endsClean { return true }
            searchStart = text.index(after: found.lowerBound)
        }
        return false
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil || scalar == "_"
    }
}
