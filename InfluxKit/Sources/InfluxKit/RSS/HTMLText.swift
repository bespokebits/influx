import Foundation

/// Plain text from the HTML feeds put in titles and summaries: tags
/// dropped, entities decoded, whitespace collapsed. Row layout draws plain
/// text; the reader view shows the real page.
enum HTMLText {
    /// `html` as one line of plain text, cut to at most `limit` characters
    /// at a word boundary, with an ellipsis when cut.
    static func plainText(_ html: String, limit: Int = .max) -> String {
        var text = ""
        text.reserveCapacity(min(html.utf8.count, 4096))
        var index = html.startIndex
        var skipping: String?
        while index < html.endIndex {
            let character = html[index]
            if character == "<", startsTag(html[html.index(after: index)...]),
               let close = html[index...].firstIndex(of: ">") {
                let tag = html[html.index(after: index)..<close]
                let name = tag.prefix { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "!" }.lowercased()
                if let open = skipping {
                    if name == "/" + open {
                        skipping = nil
                    }
                } else if name == "script" || name == "style" || name == "head" {
                    skipping = name
                } else if tag.hasPrefix("!--") {
                    // A comment may contain ">"; skip to its real end.
                    if let end = html.range(of: "-->", range: index..<html.endIndex) {
                        index = end.upperBound
                        text.append(" ")
                        continue
                    }
                } else if blockTags.contains(name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
                    text.append(" ")
                }
                index = html.index(after: close)
                continue
            }
            if skipping == nil {
                text.append(character)
            }
            index = html.index(after: index)
        }
        return truncate(collapse(decodeEntities(text)), limit: limit)
    }

    /// Plain text as HTML that `plainText(_:limit:)` turns back into the
    /// same text: a literal "&" or "<" would otherwise be read as markup.
    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
    }

    /// `html` decoded once more when a feed escaped its markup twice, as
    /// some do by putting already-escaped HTML inside CDATA
    /// ("&lt;i&gt;Show&lt;/i&gt;"); otherwise `html` as it is. The same
    /// characters are also how a feed writes a literal tag, so this decodes
    /// only text with no tags of its own and at least one escaped closing
    /// tag, which writing about a tag rarely has.
    static func unescapingDoubleEscapedMarkup(_ html: String) -> String {
        guard html.contains("&lt;/"), !hasTag(html), hasEscapedClosingTag(html) else { return html }
        return decodeEntities(html)
    }

    private static func hasTag(_ html: String) -> Bool {
        var rest = html[...]
        while let open = rest.firstIndex(of: "<") {
            rest = rest[rest.index(after: open)...]
            if startsTag(rest), rest.contains(">") { return true }
        }
        return false
    }

    /// Whether `html` holds "&lt;/name&gt;" for a tag name of letters and
    /// digits.
    private static func hasEscapedClosingTag(_ html: String) -> Bool {
        var rest = html[...]
        while let start = rest.range(of: "&lt;/") {
            rest = rest[start.upperBound...]
            let name = rest.prefix { $0.isASCII && ($0.isLetter || $0.isNumber) }
            if let first = name.first, first.isLetter, rest.dropFirst(name.count).hasPrefix("&gt;") { return true }
        }
        return false
    }

    /// Whether the text after a "<" is a tag rather than a bare "<".
    private static func startsTag(_ rest: Substring) -> Bool {
        guard let next = rest.first else { return false }
        return next.isLetter || next == "/" || next == "!"
    }

    /// Decodes character references: numeric ones and the named ones feeds
    /// actually use. Unknown names are left as they are.
    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }
        var result = ""
        result.reserveCapacity(string.utf8.count)
        var index = string.startIndex
        while index < string.endIndex {
            let character = string[index]
            guard character == "&",
                  let semicolon = string[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = string.index(after: index)
                continue
            }
            let name = string[string.index(after: index)..<semicolon]
            if let decoded = decode(name) {
                result.append(decoded)
                index = string.index(after: semicolon)
            } else {
                result.append(character)
                index = string.index(after: index)
            }
        }
        return result
    }

    private static func decode(_ name: Substring) -> String? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        if name.hasPrefix("#") {
            return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String($0) }
        }
        return named[String(name)]
    }

    static func collapse(_ string: String) -> String {
        string.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func truncate(_ string: String, limit: Int) -> String {
        guard string.count > limit else { return string }
        let cut = string.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return cut[..<end].trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…"
    }

    private static let blockTags: Set<String> = [
        "br", "p", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
        "pre", "tr", "td", "th", "table", "section", "article", "figure", "figcaption", "hr", "img",
    ]

    /// The named references in common use; the XML five come first.
    static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "hellip": "…", "mdash": "—", "ndash": "–", "minus": "−",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›",
        "bull": "•", "middot": "·", "dagger": "†", "Dagger": "‡", "prime": "′", "Prime": "″",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "para": "¶", "sect": "§",
        "times": "×", "divide": "÷", "plusmn": "±", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "cent": "¢", "pound": "£", "euro": "€", "yen": "¥",
        "iexcl": "¡", "iquest": "¿", "shy": "\u{AD}", "zwj": "\u{200D}", "zwnj": "\u{200C}",
        "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔",
        "agrave": "à", "aacute": "á", "acirc": "â", "atilde": "ã", "auml": "ä", "aring": "å", "aelig": "æ",
        "ccedil": "ç", "egrave": "è", "eacute": "é", "ecirc": "ê", "euml": "ë",
        "igrave": "ì", "iacute": "í", "icirc": "î", "iuml": "ï", "ntilde": "ñ",
        "ograve": "ò", "oacute": "ó", "ocirc": "ô", "otilde": "õ", "ouml": "ö", "oslash": "ø",
        "ugrave": "ù", "uacute": "ú", "ucirc": "û", "uuml": "ü", "yacute": "ý", "yuml": "ÿ", "szlig": "ß",
        "Agrave": "À", "Aacute": "Á", "Acirc": "Â", "Atilde": "Ã", "Auml": "Ä", "Aring": "Å", "AElig": "Æ",
        "Ccedil": "Ç", "Egrave": "È", "Eacute": "É", "Ecirc": "Ê", "Euml": "Ë",
        "Igrave": "Ì", "Iacute": "Í", "Icirc": "Î", "Iuml": "Ï", "Ntilde": "Ñ",
        "Ograve": "Ò", "Oacute": "Ó", "Ocirc": "Ô", "Otilde": "Õ", "Ouml": "Ö", "Oslash": "Ø",
        "Ugrave": "Ù", "Uacute": "Ú", "Ucirc": "Û", "Uuml": "Ü", "Yacute": "Ý",
    ]
}
