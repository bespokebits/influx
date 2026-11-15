import Foundation

/// What a reader types for a server they sign in to, as that server's
/// origin. Mastodon instances and Sammy servers are both found this way.
public enum ServerAddress {
    /// The https origin `input` names: `feeds.example.com`,
    /// `https://Feeds.Example.com/` and `https://feeds.example.com/any/path`
    /// all give `https://feeds.example.com`. The host must be a dotted name;
    /// a port other than 443 is kept; a path, query or fragment is dropped.
    /// Anything but https, and an address with user info in it, is nil.
    public static func origin(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") {
            text = "https://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host?.lowercased(),
              !host.isEmpty, host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".")
        else { return nil }
        guard components.scheme?.lowercased() == "https", components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        components.host = host
        if components.port == 443 { components.port = nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Whether `url` is on `origin`: https, the same host and the same port.
    public static func isSameOrigin(_ url: URL, _ origin: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", origin.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(), host == origin.host()?.lowercased()
        else { return false }
        return (url.port ?? 443) == (origin.port ?? 443)
    }
}
