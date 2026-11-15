import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Reads the subscription lists other readers export: every `outline` with
/// an `xmlUrl`, however deeply folders nest them.
public enum OPML {
    public struct Outline: Sendable, Hashable {
        public var feedURL: String
        public var title: String?
        public var siteURL: String?
    }

    public enum Failure: Error, Equatable {
        case notOPML
    }

    /// The feeds in `data`, in document order, each once.
    public static func parse(_ data: Data) throws -> [Outline] {
        let parser = XMLParser(data: data)
        let delegate = Delegate()
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.isOPML else {
            throw Failure.notOPML
        }
        var seen = Set<String>()
        return delegate.outlines.filter { seen.insert($0.feedURL).inserted }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var isOPML = false
        var outlines: [Outline] = []
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            depth += 1
            if depth == 1 {
                isOPML = name.lowercased() == "opml"
                if !isOPML { parser.abortParsing() }
                return
            }
            guard name == "outline" else { return }
            // Attribute names are case-sensitive in XML, but exporters
            // disagree on "xmlUrl" versus "xmlURL".
            let lowered = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            guard let url = lowered["xmlurl"]?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else { return }
            let title = [lowered["title"], lowered["text"]]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            outlines.append(Outline(feedURL: url, title: title, siteURL: lowered["htmlurl"]))
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            depth -= 1
        }
    }
}
