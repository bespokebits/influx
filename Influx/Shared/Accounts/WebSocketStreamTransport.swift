import Foundation
import InfluxKit

/// A Mastodon stream's connection over `URLSessionWebSocketTask`
/// (ADR 0037). The token goes in the `Authorization` header of the
/// handshake, which follows no redirect, so it reaches only the address
/// the instance named. A ping every 30 seconds notices a connection that
/// died quietly.
struct WebSocketStreamTransport: MastodonStreamTransport {
    static let pingInterval: Duration = .seconds(30)

    func open(_ url: URL, bearer: String) -> AsyncThrowingStream<MastodonStreamFrame, any Error> {
        AsyncThrowingStream { continuation in
            let connection = Connection(continuation)
            var request = URLRequest(url: url)
            request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            let session = URLSession(configuration: .ephemeral, delegate: connection, delegateQueue: nil)
            let task = session.webSocketTask(with: request)
            connection.task = task
            continuation.onTermination = { _ in
                connection.stop()
                task.cancel(with: .goingAway, reason: nil)
                session.invalidateAndCancel()
            }
            task.resume()
            connection.receive()
        }
    }

    /// One connection's delegate. Its state is touched from the session's
    /// delegate queue and the receive callbacks, so it is locked.
    private final class Connection: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<MastodonStreamFrame, any Error>.Continuation
        private let lock = NSLock()
        private var pinging: Task<Void, Never>?
        private var finished = false
        var task: URLSessionWebSocketTask?

        init(_ continuation: AsyncThrowingStream<MastodonStreamFrame, any Error>.Continuation) {
            self.continuation = continuation
        }

        func receive() {
            task?.receive { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(.string(let text)):
                    continuation.yield(.message(text))
                    receive()
                case .success:
                    receive()
                case .failure:
                    finish(failure(of: task?.response))
                }
            }
        }

        func stop() {
            lock.withLock {
                finished = true
                pinging?.cancel()
            }
        }

        private func finish(_ failure: MastodonStreamFailure) {
            let first = lock.withLock {
                defer { finished = true }
                pinging?.cancel()
                return !finished
            }
            if first { continuation.finish(throwing: failure) }
        }

        /// What a failed handshake's status says: a refused token, no
        /// stream for this client, or a dropped connection.
        private func failure(of response: URLResponse?) -> MastodonStreamFailure {
            switch (response as? HTTPURLResponse)?.statusCode {
            case 401?: .unauthorized
            case 403?, 404?, 410?: .unavailable
            default: .dropped
            }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            continuation.yield(.opened)
            let ping = Task { [weak self, weak webSocketTask] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: WebSocketStreamTransport.pingInterval)
                    guard !Task.isCancelled, let webSocketTask else { return }
                    webSocketTask.sendPing { error in
                        if error != nil { self?.finish(.dropped) }
                    }
                }
            }
            lock.withLock { pinging = ping }
        }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            finish(.dropped)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            finish(failure(of: task.response))
        }

        /// The token is in the request's header, so no redirect is followed.
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
