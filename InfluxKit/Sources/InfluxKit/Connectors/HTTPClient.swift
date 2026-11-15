import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one way connectors reach the network, so tests can answer with
/// recorded responses instead.
public protocol HTTPClient: Sendable {
    /// Sends `request` and returns the body and response whatever the
    /// status; a request that gets no answer throws `ConnectorError.offline`.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)

    /// Like `send`, for lookups of links other people posted: connects to
    /// exactly `address`, which the caller has checked is public, while
    /// still verifying the certificate for the URL's host; stops reading the
    /// body after `limit` bytes; and never follows a redirect (the 3xx
    /// response is returned, so the caller can check where it leads).
    func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse)

    /// Like `send`, for subscriptions that should follow a feed that moves:
    /// `movedTo` is where the redirects that began the chain lead, when
    /// every one of them was permanent (301 or 308), and nil otherwise.
    func sendNotingMove(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse, movedTo: URL?)

    /// Like `send`, for requests that carry a credential: follows a
    /// redirect only to a URL `allowed` accepts, and otherwise returns the
    /// 3xx response, so the credential never reaches another server. Every
    /// client implements this itself, since one that falls back on `send`
    /// would carry the credential wherever `send` follows.
    func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse)

    /// Like `send`, for requests that carry a token and should never be
    /// redirected anywhere (every Sammy request): no redirect is followed,
    /// so the request goes to exactly one URL, and a 3xx answer other than
    /// 304 throws `ConnectorError.badResponse`. URLSession would otherwise
    /// replay the `Authorization` header to wherever a redirect leads
    /// before the caller sees the answer.
    func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension HTTPClient {
    public func sendNotingMove(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse, movedTo: URL?) {
        let (data, response) = try await send(request)
        return (data, response, nil)
    }

    /// Fails closed: a client that doesn't say how it refuses redirects
    /// isn't trusted with a request that must not be redirected.
    public func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw ConnectorError.badResponse("this client can't refuse redirects")
    }
}

extension URLSession: HTTPClient {
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await self.data(for: request)
        } catch is URLError {
            throw ConnectorError.offline
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.badResponse("not an HTTP response")
        }
        return (data, http)
    }

    #if canImport(FoundationNetworking)
    /// Fails, as pinned requests do: this URLSession follows redirects with
    /// no per-request check, and Influx only runs on Apple platforms, where
    /// the one below checks each. InfluxKit is only tested here.
    public func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        throw ConnectorError.badResponse("checked redirects need URLSession's task delegate")
    }

    /// FoundationNetworking has no per-task delegate, so the request goes
    /// through a session of its own, made from this one's configuration
    /// (its protocol classes included), whose delegate refuses every
    /// redirect.
    public func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let refusing = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { refusing.finishTasksAndInvalidate() }
        let (data, response): (Data, URLResponse) = try await withCheckedThrowingContinuation { continuation in
            refusing.dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error is URLError ? ConnectorError.offline : error)
                } else if let response {
                    continuation.resume(returning: (data ?? Data(), response))
                } else {
                    continuation.resume(throwing: ConnectorError.offline)
                }
            }.resume()
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.badResponse("not an HTTP response")
        }
        try HTTPRedirects.refuse(http)
        return (data, http)
    }
    #else
    /// Follows redirects as `send` does, but turns a redirect to http into
    /// https, since Influx allows no cleartext loads, and notes the permanent
    /// ones.
    public func sendNotingMove(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse, movedTo: URL?) {
        let moves = MoveTracker()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await self.data(for: request, delegate: moves)
        } catch is URLError {
            throw ConnectorError.offline
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.badResponse("not an HTTP response")
        }
        return (data, http, moves.movedTo)
    }

    public func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await self.data(for: request, delegate: RedirectFilter(allowed: allowed))
        } catch is URLError {
            throw ConnectorError.offline
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.badResponse("not an HTTP response")
        }
        return (data, http)
    }

    public func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await self.data(for: request, delegate: RedirectFilter(allowed: { _ in false }))
        } catch is URLError {
            throw ConnectorError.offline
        }
        guard let http = response as? HTTPURLResponse else {
            throw ConnectorError.badResponse("not an HTTP response")
        }
        try HTTPRedirects.refuse(http)
        return (data, http)
    }
    #endif

    /// URLSession resolves names itself, so this makes its own connection
    /// (`PinnedRequest`) where Network.framework is available, and fails
    /// elsewhere: Influx only runs on Apple platforms, and InfluxKit is only
    /// tested on others.
    public func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
        #if canImport(Network)
        try await PinnedRequest.send(request, to: address, upTo: limit)
        #else
        throw ConnectorError.badResponse("pinned requests need Network.framework")
        #endif
    }
}

#if !canImport(FoundationNetworking)
/// Upgrades redirects to https and remembers where the permanent ones at
/// the start of a chain lead.
private final class MoveTracker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var stillPermanent = true
    private var permanentTarget: URL?

    var movedTo: URL? {
        lock.withLock { permanentTarget }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var next = request
        if let url = request.url, let upgraded = HTTPRedirects.upgraded(url) {
            next.url = upgraded
        }
        lock.withLock {
            if stillPermanent, HTTPRedirects.isPermanent(response.statusCode) {
                permanentTarget = next.url
            } else {
                stillPermanent = false
            }
        }
        return next
    }
}

/// Follows only the redirects its check accepts; refusing one hands the
/// 3xx response back as the answer.
private final class RedirectFilter: NSObject, URLSessionTaskDelegate, Sendable {
    private let allowed: @Sendable (URL) -> Bool

    init(allowed: @escaping @Sendable (URL) -> Bool) {
        self.allowed = allowed
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let url = request.url, allowed(url) else { return nil }
        return request
    }
}
#endif

#if canImport(FoundationNetworking)
/// Refuses every redirect, so the 3xx response is the answer.
private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif

/// Rules shared by every client that follows redirects.
enum HTTPRedirects {
    /// Throws for a redirect that `sendRefusingRedirects` was handed back
    /// instead of following: any 3xx but 304, which is an answer.
    static func refuse(_ response: HTTPURLResponse) throws {
        if (300..<400).contains(response.statusCode), response.statusCode != 304 {
            throw ConnectorError.badResponse("refused a redirect (HTTP \(response.statusCode))")
        }
    }

    static func isPermanent(_ status: Int) -> Bool {
        status == 301 || status == 308
    }

    /// The https form of an http URL, or nil for any other.
    static func upgraded(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url
    }
}
