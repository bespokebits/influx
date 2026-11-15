import AppKit

/// Whether the reader can see the Mac app, for how often its sources are
/// fetched (ADR 0036): one of its windows is on screen, and not hidden,
/// minimised or wholly covered by other windows. Each window's occlusion
/// state says so. Being the active app doesn't count on its own, since
/// its windows may all be minimised, and being in the background doesn't
/// stop a window beside the one in front from being read.
///
/// It looks again whenever AppKit says something that can change it, and
/// says only when it did change.
@MainActor
final class ScreenPresence {
    private let center: NotificationCenter
    private let isOnScreen: () -> Bool
    private let changed: (Bool) -> Void
    private var observers: [any NSObjectProtocol] = []
    private var last: Bool?

    /// The notifications after which the answer can differ.
    static let changes: [Notification.Name] = [
        NSWindow.didChangeOcclusionStateNotification,
        NSWindow.didMiniaturizeNotification,
        NSWindow.didDeminiaturizeNotification,
        NSWindow.willCloseNotification,
        NSApplication.didHideNotification,
        NSApplication.didUnhideNotification,
        NSApplication.didBecomeActiveNotification,
        NSApplication.didResignActiveNotification,
    ]

    init(center: NotificationCenter = .default,
         isOnScreen: @escaping () -> Bool = { ScreenPresence.anyWindowVisible() },
         changed: @escaping (Bool) -> Void) {
        self.center = center
        self.isOnScreen = isOnScreen
        self.changed = changed
    }

    /// Whether any of the app's windows can be seen. Panels (a find bar, a
    /// colour picker) don't count without a window behind them.
    static func anyWindowVisible() -> Bool {
        NSApplication.shared.windows.contains { window in
            window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible) && !(window is NSPanel)
        }
    }

    /// Starts watching, and says what it is now. Calling it again does nothing.
    func start() {
        guard observers.isEmpty else { return }
        for name in Self.changes {
            // Delivered where posted, which for all of these is the main thread.
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.lookAgain() }
            })
        }
        check()
    }

    /// Looks now and again on the next turn: a window that is closing is
    /// still visible while it says so.
    private func lookAgain() {
        check()
        Task { @MainActor [weak self] in self?.check() }
    }

    private func check() {
        let now = isOnScreen()
        guard now != last else { return }
        last = now
        changed(now)
    }

    isolated deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}
