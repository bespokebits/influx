import Foundation

/// Opens a sign-in page in the system's web authentication sheet and
/// returns the URL the service sent the browser back to. Mastodon comes back
/// on the app's URL scheme; Bluesky, a confidential web client, on a
/// universal link.
///
/// The sheet lives in the embedded InfluxWebSignIn framework, loaded on the
/// first sign-in: linking AuthenticationServices into the app loads about a
/// thousand system libraries at every launch.
@MainActor
enum WebSignIn {
    enum Callback {
        /// `dev.bespokebits.influx:/…`
        case customScheme(String)
        /// A universal link, e.g. `https://influx.bespokebits.dev/oauth/callback`.
        /// Needs the Associated Domains entitlement for the host.
        case https(host: String, path: String)

        /// The app's own scheme, which Mastodon's redirect uses.
        static let influx = Callback.customScheme("dev.bespokebits.influx")

        /// The scheme of a sign-in's redirect address, so the sheet waits
        /// for whatever scheme that sign-in's service sends the browser back
        /// on. Sammy's redirect moves to the app's scheme only once its
        /// server accepts the new one.
        static func scheme(of redirect: String) -> Callback {
            .customScheme(URLComponents(string: redirect)?.scheme ?? "dev.bespokebits.influx")
        }
    }

    struct Cancelled: Error {}
    /// The system couldn't show the sheet, e.g. no window to present from,
    /// ended it before the page could appear, or the framework that shows
    /// it couldn't be loaded.
    struct CouldNotStart: Error {}

    /// Throws `Cancelled` when the reader closes the sheet or the calling
    /// task is cancelled, and `CouldNotStart` when the sheet never opens.
    static func open(_ url: URL, callback: Callback) async throws -> URL {
        guard let start = loadStart() else { throw CouldNotStart() }
        let (scheme, host, path): (NSString?, NSString?, NSString?) = switch callback {
        case .customScheme(let scheme): (scheme as NSString, nil, nil)
        case .https(let host, let path): (nil, host as NSString, path as NSString)
        }
        let running = Running()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard running.begin(continuation) else { return }
                let handle = start(url as NSURL, scheme, host, path) { url, outcome, error in
                    switch outcome {
                    case 0 where url != nil: running.finish(.success(url! as URL))
                    case 2: running.finish(.failure(CouldNotStart()))
                    case 3: running.finish(.failure(error ?? Cancelled()))
                    default: running.finish(.failure(Cancelled()))
                    }
                }
                if let handle { running.hold(handle) }
            }
        } onCancel: {
            running.cancel()
        }
    }

    /// `influx_web_sign_in_start` in InfluxWebSignIn.swift.
    private typealias Start = @convention(c) (
        NSURL, NSString?, NSString?, NSString?,
        @escaping @Sendable @convention(block) (NSURL?, Int, NSError?) -> Void
    ) -> NSObject?

    private static var loaded: Start?

    private static func loadStart() -> Start? {
        if let loaded { return loaded }
        guard let symbol = EmbeddedFramework.symbol("influx_web_sign_in_start", in: "InfluxWebSignIn") else { return nil }
        loaded = unsafeBitCast(symbol, to: Start.self)
        return loaded
    }

    /// One sign-in's continuation and sheet. The browser's completion and
    /// task cancellation can race, so whichever comes first resumes the
    /// continuation and the other does nothing. Cancelling the sheet doesn't
    /// call its completion, so cancelling resumes here too.
    private final class Running: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, any Error>?
        private var handle: NSObject?
        private var isCancelled = false

        /// False, having resumed with `Cancelled`, when the task was
        /// cancelled before the sign-in began; don't open the sheet then.
        func begin(_ continuation: CheckedContinuation<URL, any Error>) -> Bool {
            let cancelled = lock.withLock {
                if !isCancelled { self.continuation = continuation }
                return isCancelled
            }
            if cancelled { continuation.resume(throwing: Cancelled()) }
            return !cancelled
        }

        /// Keeps the sheet's handle until the sign-in ends, or cancels it
        /// at once if the task was cancelled first.
        func hold(_ handle: NSObject) {
            let cancelled = lock.withLock {
                if !isCancelled, continuation != nil { self.handle = handle }
                return isCancelled
            }
            if cancelled { dismiss(handle) }
        }

        func finish(_ result: Result<URL, any Error>) {
            let continuation = lock.withLock {
                defer { self.continuation = nil; handle = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
        }

        func cancel() {
            let handle = lock.withLock {
                isCancelled = true
                return self.handle
            }
            if let handle { dismiss(handle) }
            finish(.failure(Cancelled()))
        }

        private func dismiss(_ handle: NSObject) {
            // InfluxWebSignInHandle.cancel(), which dismisses the sheet.
            _ = handle.perform(NSSelectorFromString("cancel"))
        }
    }
}
