import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One bookmark as Bookmarks to Sammy Inbox sends it: `POST
/// /api/v1/captures` on the account's server, and Sammy adds a plain task
/// to the Inbox. Sammy derives the task's id from `key`, so a retry,
/// another device or the same bookmark made again never makes a second
/// task. Nothing else is sent: no text body, no images, no account tokens,
/// and no link back, which Sammy builds from `key`.
///
/// Every field is fitted to Sammy's limits before anything is queued. The
/// limits count UTF-16 code units, as Sammy's validators do (Swift's
/// `utf16.count`, not `count`), and trimming cuts at a character boundary,
/// so an emoji is never split.
public struct SammyCapture: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case article
        case post
    }

    /// The bookmark's key: the item's `mergeKey`, the same on every device.
    public var key: String
    public var kind: Kind
    /// The task's title.
    public var title: String
    /// Where it came from: the feed's title, or `@handle on Mastodon`.
    public var from: String
    /// The web link, https only.
    public var url: String
    public var bookmarkedAt: Date

    /// Sammy's limits, in UTF-16 code units.
    public enum Limit {
        public static let key = 1024
        public static let title = 500
        public static let from = 120
        public static let url = 2048
        /// A title taken from a post's (or a title-less article's) first
        /// line is at most this many characters.
        public static let firstLine = 80
    }

    /// Why a bookmark can't go to Sammy at all. It is not queued, and the
    /// notice says so.
    public enum Refusal: Error, Sendable, Hashable {
        /// It has no web link, or one that isn't https.
        case notHTTPS
        /// Its web link is longer than Sammy takes, and can't be cut.
        case urlTooLong
        /// Its key is empty or longer than Sammy takes.
        case badKey
    }

    public init(key: String, kind: Kind, title: String, from: String, url: String, bookmarkedAt: Date) {
        self.key = key
        self.kind = kind
        self.title = title
        self.from = from
        self.url = url
        self.bookmarkedAt = bookmarkedAt
    }

    /// The capture for a bookmark, with each field fitted to the limits:
    /// `title` is an article's title; for a post, or an article that has
    /// only a body, its first non-empty line up to 80 characters; with no
    /// text at all, "Bookmark from <from>". `title` is then cut to 500 and
    /// `from` to 120. A link that isn't https, or a key or link too long to
    /// cut safely, is refused.
    public static func make(
        key: String, kind: Kind, title: String?, body: String, url: String?, from: String, bookmarkedAt: Date
    ) throws(Refusal) -> SammyCapture {
        guard (1...Limit.key).contains(key.utf16.count) else { throw .badKey }
        guard let url, isHTTPS(url) else { throw .notHTTPS }
        guard url.utf16.count <= Limit.url else { throw .urlTooLong }
        let from = trimmed(oneLine(from), toUTF16: Limit.from)
        var chosen = kind == .article ? oneLine(title ?? "") : ""
        if chosen.isEmpty { chosen = firstLine(of: title ?? "") ?? firstLine(of: body) ?? "" }
        if chosen.isEmpty { chosen = from.isEmpty ? "Bookmark" : "Bookmark from \(from)" }
        let title = trimmed(chosen, toUTF16: Limit.title)
        return SammyCapture(key: key, kind: kind, title: title, from: from, url: url, bookmarkedAt: bookmarkedAt)
    }

    /// Where a bookmark says it came from: `@handle on Mastodon` or
    /// `@handle on Bluesky` for a post from those services, else the feed's
    /// title (an RSS feed, or a Sammy feed).
    public static func from(sourceKind: Source.Kind?, sourceTitle: String, authorHandle: String) -> String {
        let handle = authorHandle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty else { return sourceTitle }
        switch sourceKind {
        case .mastodonHome, .mastodonList: return "\(handle) on Mastodon"
        case .blueskyFollowing, .blueskyFeed: return "\(handle) on Bluesky"
        default: return sourceTitle
        }
    }

    /// An absolute https URL with a host, as Sammy checks it.
    static func isHTTPS(_ text: String) -> Bool {
        guard let parts = URLComponents(string: text) else { return false }
        return parts.scheme?.lowercased() == "https" && !(parts.host ?? "").isEmpty
    }

    /// `text` on one line: line breaks and runs of white space become one
    /// space, and the ends are trimmed.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The first line of `text` with anything in it, up to `Limit.firstLine`
    /// characters: a longer one is cut at the last space in its final
    /// third, or at the limit, and ends with an ellipsis. Nil when every
    /// line is empty.
    static func firstLine(of text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).lazy.map({ oneLine(String($0)) }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        guard line.count > Limit.firstLine else { return line }
        var cut = line.prefix(Limit.firstLine - 1)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= (Limit.firstLine * 2) / 3 {
            cut = cut[..<space]
        }
        while let last = cut.last, last.isWhitespace || ",;:".contains(last) { cut = cut.dropLast() }
        return cut + "…"
    }

    /// `text` cut to at most `limit` UTF-16 code units, at a character
    /// boundary, with trailing white space dropped.
    static func trimmed(_ text: String, toUTF16 limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var end = text.startIndex
        var units = 0
        while end < text.endIndex, units + text[end].utf16.count <= limit {
            units += text[end].utf16.count
            end = text.index(after: end)
        }
        var kept = text[..<end]
        while let last = kept.last, last.isWhitespace { kept = kept.dropLast() }
        return String(kept)
    }

    // MARK: Sending

    /// `POST /api/v1/captures` on `issuer`, as JSON. The caller adds the
    /// bearer token.
    public func request(issuer: URL) -> URLRequest {
        var request = URLRequest(url: issuer.appending(path: "api/v1/captures"), cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body()
        return request
    }

    /// The JSON body, with `bookmarkedAt` as an ISO 8601 date and time.
    func body() -> Data {
        struct Body: Encodable {
            var key, kind, title, from, url, bookmarkedAt: String
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(Body(
            key: key, kind: kind.rawValue, title: title, from: from, url: url,
            bookmarkedAt: formatter.string(from: bookmarkedAt)
        ))) ?? Data()
    }
}

/// What sending one capture came to.
public enum SammyCaptureResult: Sendable, Hashable {
    /// Sammy has it (200), whether it made a task now or before.
    case accepted
    /// No answer: offline, or the request timed out. Try again later.
    case offline
    /// A 429 or a 5xx: try again later, not before `after` if the server
    /// said.
    case retry(after: Date?)
    /// 403: this session can't add to the Inbox (it lacks `inbox:add`).
    /// The capture waits for a session that can.
    case missingScope
    /// 401: the token was revoked. The capture waits for the account to
    /// be approved again.
    case signedOut
    /// Any other 4xx: Sammy will never take this capture.
    case refused(status: Int)

    /// What an HTTP answer to a capture means.
    public init(_ response: HTTPURLResponse, now: Date) {
        switch response.statusCode {
        case 200..<300:
            self = .accepted
        case 401:
            self = .signedOut
        case 403:
            self = .missingScope
        case 408, 425, 429, 500...599:
            self = .retry(after: ConnectorError.retryAfter(response, now: now))
        default:
            self = .refused(status: response.statusCode)
        }
    }
}

/// A Sammy account that captures can be sent through: `SammyAccount` in
/// the app, a stand-in in tests.
public protocol SammyInboxAccount: Sendable {
    /// Whether this device's session for the account holds `inbox:add`.
    /// Until it does (the upgraded session hasn't reached this device
    /// through iCloud Keychain yet), captures wait unsent.
    func mayAddToInbox() async -> Bool
    func sendCapture(_ capture: SammyCapture, now: Date) async -> SammyCaptureResult
    /// After `sendCapture` answered `.signedOut`, the token Sammy refused:
    /// the one that request carried, which may no longer be the stored one
    /// if another device's session arrived meanwhile. Nil when unknown.
    func refusedToken() async -> String?
}

extension SammyAccount: SammyInboxAccount {
    public func mayAddToInbox() async -> Bool {
        !isSignedOut && latestSession().addsToInbox
    }

    /// Sends `capture` with the account's token, refusing redirects, to its
    /// own server only (`send`), and reads the answer.
    public func sendCapture(_ capture: SammyCapture, now: Date) async -> SammyCaptureResult {
        let wasSignedOut = isSignedOut
        do {
            let (_, response) = try await send(capture.request(issuer: server))
            let result = SammyCaptureResult(response, now: now)
            // `send` answers with the session it last tried, so this is the
            // token Sammy refused.
            noteRefusal(result == .signedOut ? session.accessToken : nil)
            return result
        } catch ConnectorError.unauthorized {
            // Already signed out here: nothing was sent. Otherwise Sammy
            // refused the request, carrying the session `send` last tried.
            noteRefusal(wasSignedOut ? nil : session.accessToken)
            return .signedOut
        } catch ConnectorError.offline {
            return .offline
        } catch ConnectorError.rateLimited(let after) {
            return .retry(after: after)
        } catch {
            return .retry(after: nil)
        }
    }
}
