import Foundation

/// Finds the feeds a web page points to, for adding a subscription from a
/// site's address instead of its feed's.
enum FeedDiscovery {
    /// The feeds `html` advertises with `<link rel="alternate">`, resolved
    /// against `pageURL`, RSS, Atom and JSON Feed only, in page order.
    static func feeds(inPage html: String, at pageURL: URL) -> [URL] {
        // Only the head can hold them, and pages can be large.
        let head = html.range(of: "</head", options: .caseInsensitive).map { html[..<$0.lowerBound] } ?? html[...]
        var base = pageURL
        var found: [URL] = []
        for tag in tags(named: ["link", "base"], in: head) {
            let attributes = attributes(of: tag.body)
            if tag.name == "base", let href = attributes["href"], let url = URL(string: href, relativeTo: pageURL) {
                base = url.absoluteURL
                continue
            }
            let rel = Set((attributes["rel"] ?? "").lowercased().split(separator: " ").map(String.init))
            let type = (attributes["type"] ?? "").lowercased()
            guard rel.contains("alternate"), feedTypes.contains(type),
                  let href = attributes["href"].map(HTMLText.decodeEntities),
                  let url = URL(string: href.trimmingCharacters(in: .whitespaces), relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https",
                  !found.contains(url) else { continue }
            found.append(url)
        }
        return found
    }

    /// Where sites without a `<link>` usually keep their feed, tried in
    /// this order.
    static func guesses(for pageURL: URL) -> [URL] {
        ["/feed", "/rss", "/feed.xml", "/rss.xml", "/atom.xml", "/index.xml", "/feed/", "/feed.json"]
            .compactMap { URL(string: $0, relativeTo: pageURL)?.absoluteURL }
    }

    /// Not plain `application/json`, which pages also use for other
    /// alternates, such as a post's own API record.
    private static let feedTypes: Set<String> = ["application/rss+xml", "application/atom+xml", "application/rdf+xml", "application/xml", "text/xml", "application/feed+json"]

    static func tags(named names: Set<String>, in html: Substring) -> [(name: String, body: Substring)] {
        var result: [(String, Substring)] = []
        var index = html.startIndex
        while let open = html[index...].firstIndex(of: "<") {
            guard let close = html[open...].firstIndex(of: ">") else { break }
            let inner = html[html.index(after: open)..<close]
            let name = inner.prefix { $0.isLetter }.lowercased()
            if names.contains(name) {
                result.append((name, inner.dropFirst(name.count)))
            }
            index = html.index(after: close)
        }
        return result
    }

    /// `name="value"`, `name='value'` and `name=value` pairs; names
    /// lowercased.
    static func attributes(of body: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = body.startIndex
        func skipSpaces() {
            while index < body.endIndex, body[index].isWhitespace || body[index] == "/" { index = body.index(after: index) }
        }
        while true {
            skipSpaces()
            guard index < body.endIndex else { break }
            let nameStart = index
            while index < body.endIndex, !body[index].isWhitespace, body[index] != "=", body[index] != "/" {
                index = body.index(after: index)
            }
            let name = body[nameStart..<index].lowercased()
            skipSpaces()
            guard index < body.endIndex, body[index] == "=" else {
                if !name.isEmpty { result[name] = result[name] ?? "" }
                if index == nameStart { index = body.index(after: index) }
                continue
            }
            index = body.index(after: index)
            while index < body.endIndex, body[index].isWhitespace { index = body.index(after: index) }
            guard index < body.endIndex else { break }
            let value: Substring
            if body[index] == "\"" || body[index] == "'" {
                let quote = body[index]
                let start = body.index(after: index)
                let end = body[start...].firstIndex(of: quote) ?? body.endIndex
                value = body[start..<end]
                index = end < body.endIndex ? body.index(after: end) : end
            } else {
                let start = index
                while index < body.endIndex, !body[index].isWhitespace { index = body.index(after: index) }
                value = body[start..<index]
            }
            if result[name] == nil { result[name] = String(value) }
        }
        return result
    }
}
