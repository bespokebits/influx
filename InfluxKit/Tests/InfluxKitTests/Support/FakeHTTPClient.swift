import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import InfluxKit

/// Answers requests with canned responses, for connector tests, and keeps
/// every request it was sent.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var headers: [String: String] = [:]
        var body: Data = Data()

        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        init(status: Int = 200, headers: [String: String] = [:], text: String) {
            self.init(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) throws -> Response
    private var _requests: [URLRequest] = []
    private var _addresses: [[UInt8]] = []

    /// The address each pinned request was sent to, oldest first.
    var addresses: [[UInt8]] {
        lock.withLock { _addresses }
    }

    /// Every request sent so far, oldest first.
    var requests: [URLRequest] {
        lock.withLock { _requests }
    }

    init(_ handler: @escaping @Sendable (URLRequest) throws -> Response) {
        self.handler = handler
    }

    /// Answers each URL from `routes`, and anything else with a 404.
    convenience init(routes: [String: Response]) {
        self.init { request in
            routes[request.url?.absoluteString ?? ""] ?? Response(status: 404)
        }
    }

    func respond(_ handler: @escaping @Sendable (URLRequest) throws -> Response) {
        lock.withLock { self.handler = handler }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let handler = lock.withLock {
            _requests.append(request)
            return self.handler
        }
        let response = try handler(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (response.body, http)
    }

    /// Fakes never follow redirects, so this only notes the address and
    /// cuts the body short.
    func send(_ request: URLRequest, upTo limit: Int, at address: [UInt8]) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _addresses.append(address) }
        let (data, response) = try await send(request)
        return (data.prefix(limit), response)
    }

    /// Follows redirects the way URLSession does for subscriptions,
    /// upgrading http hops to https and noting a permanent move.
    func sendNotingMove(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse, movedTo: URL?) {
        var current = request
        var movedTo: URL?
        var stillPermanent = true
        for _ in 0..<10 {
            let (data, response) = try await send(current)
            guard (300..<400).contains(response.statusCode), response.statusCode != 304,
                  let location = response.value(forHTTPHeaderField: "Location"),
                  var next = URL(string: location, relativeTo: current.url)?.absoluteURL else {
                return (data, response, movedTo)
            }
            next = HTTPRedirects.upgraded(next) ?? next
            if stillPermanent, HTTPRedirects.isPermanent(response.statusCode) {
                movedTo = next
            } else {
                stillPermanent = false
            }
            current.url = next
        }
        throw ConnectorError.badResponse("too many redirects")
    }

    /// Follows the redirects `allowed` accepts with the request's headers,
    /// as URLSession does, and returns the first it refuses.
    func send(_ request: URLRequest, followingRedirectsOnlyTo allowed: @escaping @Sendable (URL) -> Bool) async throws -> (Data, HTTPURLResponse) {
        var current = request
        for _ in 0..<10 {
            let (data, response) = try await send(current)
            guard (300..<400).contains(response.statusCode), response.statusCode != 304,
                  let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: current.url)?.absoluteURL, allowed(next) else {
                return (data, response)
            }
            current.url = next
        }
        throw ConnectorError.badResponse("too many redirects")
    }

    /// Sends once and, as URLSession does with its redirects refused, turns
    /// a 3xx answer other than 304 into `.badResponse`.
    func sendRefusingRedirects(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await send(request)
        try HTTPRedirects.refuse(response)
        return (data, response)
    }
}
