import Foundation

/// Turns the HTML Mastodon sends for a status into the plain text a row
/// shows. Mastodon's HTML is a small, sanitized subset: paragraphs, line
/// breaks, links, and spans. Links to long URLs carry `invisible` spans for
/// the parts hidden from display and an `ellipsis` span for the part shown
/// shortened, so those become `…`, as on the web.
enum MastodonHTML {
    static func text(_ html: String) -> String {
        textAndLinks(html).text
    }

    /// The plain text, and where each link sits in it: web links, mentions
    /// and hashtags, each with the address its anchor goes to.
    static func textAndLinks(_ html: String) -> (text: String, links: [Item.Link]) {
        var output = ""
        var links: [Item.Link] = []
        // Where the open anchor's text starts, in UTF-16, and where it goes.
        var anchor: (start: Int, href: String)?
        // Each open span: whether it hides its text, or ends in an ellipsis.
        var spans: [(hidden: Bool, ellipsis: Bool)] = []
        var hidden: Bool { spans.contains { $0.hidden } }
        var index = html.startIndex

        func newlines(_ count: Int) {
            guard !output.isEmpty else { return }
            let have = output.reversed().prefix { $0 == "\n" }.count
            if have < count {
                output += String(repeating: "\n", count: count - have)
            }
        }

        while index < html.endIndex {
            if html[index] == "<", let close = html[index...].firstIndex(of: ">") {
                let tag = html[html.index(after: index)..<close]
                index = html.index(after: close)
                let isClosing = tag.hasPrefix("/")
                let name = tag.drop { $0 == "/" }.prefix { $0.isLetter || $0.isNumber }.lowercased()
                switch (name, isClosing) {
                case ("br", _):
                    if !hidden { output += "\n" }
                case ("p", false), ("blockquote", false), ("li", false):
                    newlines(2)
                case ("p", true), ("blockquote", true), ("li", true):
                    newlines(2)
                case ("span", false):
                    let classes = attribute("class", in: tag)?.split(separator: " ") ?? []
                    spans.append((classes.contains("invisible"), classes.contains("ellipsis")))
                case ("span", true):
                    if let span = spans.popLast(), span.ellipsis, !hidden {
                        output += "…"
                    }
                case ("a", false):
                    if let href = attribute("href", in: tag).map({ text(String($0)) }),
                       href.hasPrefix("https://") || href.hasPrefix("http://") {
                        anchor = (output.utf16.count, href)
                    }
                case ("a", true):
                    if let open = anchor, output.utf16.count > open.start {
                        links.append(Item.Link(start: open.start, length: output.utf16.count - open.start, url: open.href))
                    }
                    anchor = nil
                default:
                    break
                }
            } else if html[index] == "&", let end = html[index...].prefix(12).firstIndex(of: ";"),
                      let decoded = entity(html[html.index(after: index)..<end]) {
                if !hidden { output += decoded }
                index = html.index(after: end)
            } else {
                if !hidden { output.append(html[index]) }
                index = html.index(after: index)
            }
        }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Trimming moves the text back by what it took off the front.
        let lead = output.utf16.count - output.drop { $0.isWhitespace || $0.isNewline }.utf16.count
        let length = trimmed.utf16.count
        let placed = links.compactMap { link -> Item.Link? in
            let start = max(0, link.start - lead)
            let end = min(length, link.start + link.length - lead)
            return end > start ? Item.Link(start: start, length: end - start, url: link.url) : nil
        }
        return (trimmed, placed)
    }

    /// The links a status's text makes to the web, in order: not mentions,
    /// hashtags or the quote of another post.
    static func links(_ html: String) -> [String] {
        var links: [String] = []
        var index = html.startIndex
        while let open = html[index...].range(of: "<a ", options: .caseInsensitive) {
            guard let close = html[open.upperBound...].firstIndex(of: ">") else { break }
            let tag = html[open.lowerBound..<close]
            index = close
            let classes = attribute("class", in: tag)?.split(separator: " ") ?? []
            let rel = attribute("rel", in: tag)?.split(separator: " ") ?? []
            guard !classes.contains(where: { ["mention", "hashtag", "u-url", "quote-inline"].contains($0) }),
                  !rel.contains("tag"),
                  let href = attribute("href", in: tag).map({ text(String($0)) }),
                  href.hasPrefix("https://") || href.hasPrefix("http://") else { continue }
            if !links.contains(href) { links.append(href) }
        }
        return links
    }

    private static func attribute(_ name: String, in tag: Substring) -> Substring? {
        guard let range = tag.range(of: "\(name)=\"") else { return nil }
        let rest = tag[range.upperBound...]
        return rest.prefix { $0 != "\"" }
    }

    private static func entity(_ name: Substring) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{A0}"
        default:
            let number: UInt32?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                number = UInt32(name.dropFirst(2), radix: 16)
            } else if name.hasPrefix("#") {
                number = UInt32(name.dropFirst())
            } else {
                number = nil
            }
            return number.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}
