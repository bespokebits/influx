import Foundation

/// `work`'s result, or nil once `limit` has passed or the caller is
/// cancelled; `work` is cancelled then. Returns at once even if `work` is
/// slow to notice.
func withDeadline<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async -> T?) async -> T? {
    let first = FirstResult<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            guard first.waiting(continuation) else { return }
            let worker = Task {
                first.offer(await work())
            }
            first.holding(worker)
            Task {
                try? await Task.sleep(for: limit)
                // Claim nil first, so the worker's answer to being
                // cancelled can't win.
                first.offer(nil)
                worker.cancel()
            }
        }
    } onCancel: {
        first.cancel()
    }
}

/// Hands the first value offered to a waiting continuation and drops the
/// rest. Cancelling offers nil and cancels the work.
private final class FirstResult<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var worker: Task<Void, Never>?
    private var isCancelled = false

    /// False, having resumed with nil, when the caller was already
    /// cancelled; don't start the work then.
    func waiting(_ continuation: CheckedContinuation<Value?, Never>) -> Bool {
        let cancelled = lock.withLock {
            if !isCancelled { self.continuation = continuation }
            return isCancelled
        }
        if cancelled { continuation.resume(returning: nil) }
        return !cancelled
    }

    func holding(_ worker: Task<Void, Never>) {
        let cancelled = lock.withLock {
            self.worker = worker
            return isCancelled
        }
        if cancelled { worker.cancel() }
    }

    func cancel() {
        let worker = lock.withLock {
            isCancelled = true
            return self.worker
        }
        offer(nil)
        worker?.cancel()
    }

    func offer(_ value: Value?) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(returning: value)
    }
}

extension Duration {
    var seconds: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
