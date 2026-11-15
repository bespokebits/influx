import AppKit

/// Comings back to the Mac app that wait for the synced place behind the
/// "Syncing in Progress" screen (influx-dev #109). The Mac keeps syncing in
/// the background, but not while it sleeps, and a place another device sent
/// meanwhile may not be in yet. Scrolling first would be the last move, win
/// everywhere, and lose the reader's place (#106).
///
/// - Switching back to Influx after `SyncingGate.away` or longer. A quick
///   switch back still syncs, without the screen.
/// - Waking the Mac or its display, or unlocking it, with Influx in front:
///   nothing else tells the app the reader is back. The network may take
///   a moment to return, so the screen waits for it, up to its limit.
/// - Reopening the window, from the Dock or the Window menu.
///
/// It also says when the reader leaves: switching to another app, or the
/// Mac going to sleep. The app then saves and sends the reading place at
/// once, so a device opened next finds it (influx-dev #125). Quitting
/// isn't watched: the app can't finish a send while it quits.
///
/// AppKit's notifications, not the scene phase, which doesn't change for
/// a wake, and changes for windows rather than the app.
@MainActor
final class SyncReturns {
    /// Says the app came back after `away`; `true` waits for the network.
    private let cameBack: (_ away: Duration, _ waitingForNetwork: Bool) -> Void
    /// Says the reader left the app, or the Mac is going to sleep.
    private let wentAway: () -> Void
    private let appCenter: NotificationCenter
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: NotificationCenter
    private let isActive: () -> Bool
    private let now: () -> ContinuousClock.Instant
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    /// When Influx stopped being the active app, while it isn't.
    private var resignedAt: ContinuousClock.Instant?
    private var windowsOpened = 0

    /// Longer than any wait for coming back, so the screen shows.
    static let always: Duration = .seconds(365 * 86_400)
    /// Posted by the system when the screen is unlocked.
    static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    init(appCenter: NotificationCenter = .default,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributedCenter: NotificationCenter = DistributedNotificationCenter.default(),
         isActive: @escaping () -> Bool = { NSApplication.shared.isActive },
         now: @escaping () -> ContinuousClock.Instant = { .now },
         wentAway: @escaping () -> Void = {},
         cameBack: @escaping (_ away: Duration, _ waitingForNetwork: Bool) -> Void) {
        self.appCenter = appCenter
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        self.isActive = isActive
        self.now = now
        self.wentAway = wentAway
        self.cameBack = cameBack
    }

    /// Starts watching. Calling it again does nothing.
    func start() {
        guard observers.isEmpty else { return }
        watch(appCenter, NSApplication.didResignActiveNotification) { $0.resigned() }
        watch(appCenter, NSApplication.didBecomeActiveNotification) { $0.becameActive() }
        watch(workspaceCenter, NSWorkspace.willSleepNotification) { $0.wentAway() }
        watch(workspaceCenter, NSWorkspace.didWakeNotification) { $0.woke() }
        watch(workspaceCenter, NSWorkspace.screensDidWakeNotification) { $0.woke() }
        watch(distributedCenter, Self.screenUnlocked) { $0.woke() }
    }

    /// A timeline window appeared. The first is launch's own, which the
    /// screen already covers; any later one opens from the place this Mac
    /// last knew, so it waits for the synced one too.
    func windowOpened() {
        windowsOpened += 1
        guard windowsOpened > 1 else { return }
        cameBack(Self.always, false)
    }

    private func resigned() {
        resignedAt = now()
        wentAway()
    }

    private func becameActive() {
        let away = resignedAt.map { now() - $0 } ?? .zero
        resignedAt = nil
        cameBack(away, false)
    }

    private func woke() {
        // In the background, switching back to Influx will say.
        guard isActive() else { return }
        cameBack(Self.always, true)
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name,
                       _ handle: @escaping @MainActor (SyncReturns) -> Void) {
        // Delivered where posted, which for all of these is the main thread.
        let observer = center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handle(self)
            }
        }
        observers.append((center, observer))
    }

    isolated deinit {
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
