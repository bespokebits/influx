import Foundation
import InfluxKit

/// An event stream's connection over a `URLSession` data task (ADR 0038):
/// the response, then the body's bytes as they arrive. The request goes
/// as it is, with its token in its header, and follows no redirect, so
/// the token reaches only the address it was built for. A connection that
/// sends nothing for the request's timeout ends, so one that died quietly
/// is noticed.
struct EventStreamSessionTransport: EventStreamTransport {
    /// Longer than the server keeps any stream open (an hour).
    static let longestConnection: TimeInterval = 2 * 60 * 60

    func open(_ request: URLRequest) -> AsyncThrowingStream<EventStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = Self.longestConnection
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpShouldSetCookies = false
            let session = URLSession(configuration: configuration, delegate: Connection(continuation), delegateQueue: nil)
            let task = session.dataTask(with: request)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    /// One connection's delegate, called on the session's delegate queue.
    private final class Connection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<EventStreamChunk, any Error>.Continuation

        init(_ continuation: AsyncThrowingStream<EventStreamChunk, any Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse else {
                continuation.finish(throwing: URLError(.badServerResponse))
                return completionHandler(.cancel)
            }
            continuation.yield(.response(response))
            // A refusal's body isn't read: its status says it all.
            completionHandler(response.statusCode == 200 ? .allow : .cancel)
            if response.statusCode != 200 { continuation.finish() }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.bytes(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }

        /// The token is in the request's header, so no redirect is followed.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
