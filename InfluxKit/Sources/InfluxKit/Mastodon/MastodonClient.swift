import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One account's view of its instance: the timelines and lists Influx reads.
public struct MastodonClient: Sendable {
    /// Mastodon's largest page for timelines.
    public static let pageSize = 40

    public let instance: URL
    private let accessToken: String
    private let http: any HTTPClient

    public init(instance: URL, accessToken: String, http: any HTTPClient = URLSession.shared) {
        self.instance = instance
        self.accessToken = accessToken
        self.http = http
    }

    /// Which page of a timeline to fetch. Mastodon status IDs sort in time
    /// order, so each is relative to a status already seen.
    public enum Page: Sendable, Hashable {
        /// The newest statuses.
        case newest
        /// The statuses immediately after this ID, oldest of them first in
        /// time: what catching up from a stored status needs (`min_id`).
        case after(String)
        /// The statuses before this ID (`max_id`).
        case before(String)
    }

    public struct TimelinePage: Sendable, Hashable {
        /// Newest first, as the API returns them.
        public var statuses: [Mastodon.Status]
        /// Where the next newer page starts, if the instance offered one.
        public var newer: Page?
        /// Where the next older page starts; nil at the end of the timeline.
        public var older: Page?
        public var rateLimit: RateLimit?
    }

    /// The instance's budget for this account, from its `X-RateLimit-*`
    /// headers.
    public struct RateLimit: Sendable, Hashable {
        public var limit: Int
        public var remaining: Int
        public var resetsAt: Date?
    }

    // MARK: Requests

    public func verifyCredentials() async throws(ConnectorError) -> Mastodon.Account {
        try await get("/api/v1/accounts/verify_credentials").decoded()
    }

    public func homeTimeline(_ page: Page = .newest) async throws(ConnectorError) -> TimelinePage {
        try await timeline("/api/v1/timelines/home", page)
    }

    public func lists() async throws(ConnectorError) -> [Mastodon.List] {
        try await get("/api/v1/lists").decoded()
    }

    public func listTimeline(listID: String, _ page: Page = .newest) async throws(ConnectorError) -> TimelinePage {
        try await timeline("/api/v1/timelines/list/\(Self.pathSegment(listID))", page)
    }

    /// The account's bookmarks, most recently bookmarked first. Pages by
    /// the bookmarks' own IDs, from the `Link` header, not status IDs.
    public func bookmarks(_ page: Page = .newest) async throws(ConnectorError) -> TimelinePage {
        try await timeline("/api/v1/bookmarks", page)
    }

    public func status(_ id: String) async throws(ConnectorError) -> Mastodon.Status {
        try await get("/api/v1/statuses/\(Self.pathSegment(id))").decoded()
    }

    public func context(_ id: String) async throws(ConnectorError) -> Mastodon.Context {
        try await get("/api/v1/statuses/\(Self.pathSegment(id))/context").decoded()
    }

    /// Favourites, boosts or bookmarks a status, or undoes it, and returns
    /// the status as the instance now has it (a boost returns the new
    /// boost, with the status inside).
    public func act(_ action: ConnectorAction, onStatus id: String) async throws(ConnectorError) -> Mastodon.Status {
        let verb = switch action {
        case .like: "favourite"
        case .unlike: "unfavourite"
        case .boost: "reblog"
        case .unboost: "unreblog"
        case .bookmark: "bookmark"
        case .unbookmark: "unbookmark"
        }
        return try await send("/api/v1/statuses/\(Self.pathSegment(id))/\(verb)", method: "POST").decoded()
    }

    /// Where the instance's streaming API is, for the home stream
    /// (`MastodonStreaming.userStreamURL`), or nil when it has none to
    /// offer this client: no streaming URL, or any refusal but a 401,
    /// which throws `.unauthorized`. No answer throws `.offline`.
    public func userStreamURL() async throws(ConnectorError) -> URL? {
        var request = URLRequest(url: instance.appending(path: "/api/v2/instance"))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.sendRefusingRedirects(request)
        } catch {
            throw .offline
        }
        switch response.statusCode {
        case 200: return MastodonStreaming.userStreamURL(instanceInfo: data, instance: instance)
        case 401: throw .unauthorized
        default: return nil
        }
    }

    /// Opens the account's `user` stream at `url` through `transport`,
    /// with the token in the `Authorization` header, never in the URL.
    public func openUserStream(at url: URL, with transport: any MastodonStreamTransport) -> AsyncThrowingStream<MastodonStreamFrame, any Error> {
        transport.open(url, bearer: accessToken)
    }

    private func timeline(_ path: String, _ page: Page) async throws(ConnectorError) -> TimelinePage {
        var query = [URLQueryItem(name: "limit", value: String(Self.pageSize))]
        switch page {
        case .newest: break
        case .after(let id): query.append(URLQueryItem(name: "min_id", value: id))
        case .before(let id): query.append(URLQueryItem(name: "max_id", value: id))
        }
        let response = try await get(path, query: query)
        let statuses: [Mastodon.Status] = try response.decoded()
        let links = Self.links(response.http.value(forHTTPHeaderField: "Link"))
        return TimelinePage(
            statuses: statuses,
            newer: links["prev"]?["min_id"].map(Page.after),
            // An empty page is the end, whatever the header says.
            older: statuses.isEmpty ? nil : links["next"]?["max_id"].map(Page.before),
            rateLimit: Self.rateLimit(response.http)
        )
    }

    // MARK: Transport

    struct Response {
        var data: Data
        var http: HTTPURLResponse

        func decoded<T: Decodable>() throws(ConnectorError) -> T {
            do {
                return try Mastodon.decoder().decode(T.self, from: data)
            } catch {
                throw .badResponse("undecodable \(T.self): \(error)")
            }
        }
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws(ConnectorError) -> Response {
        try await send(path, query: query)
    }

    private func send(_ path: String, method: String = "GET", query: [URLQueryItem] = []) async throws(ConnectorError) -> Response {
        var components = URLComponents(url: instance.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // The token reads and writes the account, so it goes to the instance
        // and nowhere else: a client that follows redirects would carry the
        // header to wherever the instance, or anything between, pointed it.
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await http.sendRefusingRedirects(request)
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw .offline
        }
        // Mastodon dates its rate-limit reset in its own header rather than
        // `Retry-After`.
        if response.statusCode == 429, let reset = Self.rateLimit(response)?.resetsAt {
            throw .rateLimited(retryAfter: reset)
        }
        do {
            try ConnectorError.check(response, now: Date())
        } catch let error as ConnectorError {
            throw error
        } catch {
            throw .badResponse(String(describing: error))
        }
        return Response(data: data, http: response)
    }

    // MARK: Headers

    static func rateLimit(_ http: HTTPURLResponse) -> RateLimit? {
        guard let limit = http.value(forHTTPHeaderField: "X-RateLimit-Limit").flatMap({ Int($0) }),
              let remaining = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap({ Int($0) })
        else { return nil }
        let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap { text in
            (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                ?? (try? Date(text, strategy: Date.ISO8601FormatStyle()))
        }
        return RateLimit(limit: limit, remaining: remaining, resetsAt: reset)
    }

    /// Reads a `Link` header into each relation's query items, e.g.
    /// `["next": ["max_id": "109"]]`.
    static func links(_ header: String?) -> [String: [String: String]] {
        guard let header else { return [:] }
        var result: [String: [String: String]] = [:]
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let target = pieces.first, target.hasPrefix("<"), target.hasSuffix(">"),
                  let url = URLComponents(string: String(target.dropFirst().dropLast())),
                  let rel = pieces.dropFirst().first(where: { $0.hasPrefix("rel=") })
            else { continue }
            let name = rel.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            var query: [String: String] = [:]
            for item in url.queryItems ?? [] {
                query[item.name] = item.value
            }
            result[name] = query
        }
        return result
    }

    private static func pathSegment(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }
}
