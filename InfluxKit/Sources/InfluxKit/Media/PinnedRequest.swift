#if canImport(Network)
import Foundation
import Network

/// A GET over its own connection to an address already checked to be
/// public, so the request can't go wherever the name resolves by the time
/// URLSession connects. TLS still names the URL's host, for SNI and for
/// verifying its certificate. HTTP/1.1, one request per connection.
enum PinnedRequest {
    static func send(_ request: URLRequest, to address: [UInt8], upTo limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              let ip = endpointHost(address) else { throw ConnectorError.badResponse("not a pinnable request") }
        let port = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? 443)) ?? .https

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(request.timeoutInterval.rounded(.up))
        let connection = NWConnection(host: ip, port: port, using: NWParameters(tls: tls, tcp: tcp))
        let queue = DispatchQueue(label: "dev.bespokebits.influx.pinned-request")

        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await ready(connection, on: queue)
            try await write(head(for: request, url: url, host: host), to: connection)
            var reader = HTTPResponseReader(limit: limit)
            while !reader.isDone {
                let (data, complete) = try await receive(from: connection)
                if let data { try reader.feed(data) }
                if complete { try reader.finish() }
            }
            guard let status = reader.status,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: reader.headers) else {
                throw ConnectorError.badResponse("no HTTP response")
            }
            return (reader.body, response)
        } onCancel: {
            connection.cancel()
        }
    }

    private static func endpointHost(_ address: [UInt8]) -> NWEndpoint.Host? {
        switch address.count {
        case 4: IPv4Address(Data(address)).map { .ipv4($0) }
        case 16: IPv6Address(Data(address)).map { .ipv6($0) }
        default: nil
        }
    }

    /// The request line and headers; the body of a GET is empty.
    private static func head(for request: URLRequest, url: URL, host: String) -> Data {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = components?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let query = components?.percentEncodedQuery { target += "?" + query }
        var lines = ["GET \(target) HTTP/1.1", "Host: \(url.port.map { "\(host):\($0)" } ?? host)",
                     "Accept-Encoding: identity", "Connection: close"]
        for (field, value) in request.allHTTPHeaderFields ?? [:]
        where !["host", "accept-encoding", "connection"].contains(field.lowercased()) {
            lines.append("\(field): \(value)")
        }
        // Header values come from InfluxKit, but never let one end the head early.
        let text = lines.map { $0.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "") }
            .joined(separator: "\r\n") + "\r\n\r\n"
        return Data(text.utf8)
    }

    private static func ready(_ connection: NWConnection, on queue: DispatchQueue) async throws {
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { continuation.resume() }
                case .failed, .waiting, .cancelled:
                    // Waiting means no route right now; a lookup doesn't wait.
                    once.run { continuation.resume(throwing: ConnectorError.offline) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func write(_ data: Data, to connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil {
                    continuation.resume(throwing: ConnectorError.offline)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receive(from connection: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if error != nil {
                    continuation.resume(throwing: ConnectorError.offline)
                } else {
                    continuation.resume(returning: (data, complete))
                }
            }
        }
    }
}

/// Runs a block the first time only, for callbacks that can fire again.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { block() }
    }
}
#endif
