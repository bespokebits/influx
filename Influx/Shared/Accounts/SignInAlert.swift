import SwiftUI
import InfluxKit
import UserNotifications
#if os(macOS)
import AppKit
#endif

/// The red bar over the timeline while any account needs signing in again:
/// signed out by its service, or not signed in on this device. It names
/// each account, says since when its posts have been missed, and signs it
/// in again in place. It can't be dismissed; it goes when the account is
/// signed in again or removed.
struct SignInAlert: View {
    let accounts: Accounts
    let states: [String: SourceFetchState]

    var body: some View {
        let needing = accounts.accounts.filter { $0.needsSignIn(states) }
        if !needing.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(needing) { account in
                    SignInAlertLine(account: account, accounts: accounts, since: account.signedOutSince(states))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(Self.red.ignoresSafeArea(edges: .top))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("sign-in-alert")
        }
    }

    /// The one solid block of colour in the design, so it can't be missed.
    static let red = Color(red: 0.72, green: 0.07, blue: 0.09)

    /// "Bluesky @ana.bsky.social is signed out."
    nonisolated static func headline(service: String, name: String, signedOut: Bool) -> String {
        signedOut ? "\(service) \(name) is signed out." : "\(service) \(name) isn't signed in on this device."
    }

    /// "You've missed its posts since Mon 27 Oct."
    nonisolated static func detail(since: Date?) -> String {
        guard let since else { return "Its posts aren't coming in." }
        return "You've missed its posts since \(since.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))."
    }
}

/// One account in the alert, with its Sign in again button.
private struct SignInAlertLine: View {
    let account: Accounts.Account
    let accounts: Accounts
    let since: Date?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SignInAlert.headline(service: account.service.name, name: account.name, signedOut: account.isSignedIn))
                    .font(.headline)
                Text(SignInAlert.detail(since: since))
                    .font(.subheadline)
                if let error = accounts.signInAgainErrors[account.id] {
                    Text(error)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("sign-in-again-error")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if accounts.signingInAgain.contains(account.id) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
            } else {
                SignInAgainButton(account: account, accounts: accounts, onRed: true)
            }
        }
    }
}

/// Signs the account in again in place: on the alert, the account's row
/// and its screen.
struct SignInAgainButton: View {
    let account: Accounts.Account
    let accounts: Accounts
    var onRed = false

    var body: some View {
        Button {
            Task { await accounts.signInAgain(account) }
        } label: {
            Text("Sign in again")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(onRed ? SignInAlert.red : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(onRed ? Color.white : SignInAlert.red, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(accounts.signingInAgain.contains(account.id))
        .accessibilityIdentifier("sign-in-again")
    }
}

/// Outside the window: a system notification the first time an account
/// needs signing in again, and a badge (the Dock's "!", the app icon's
/// count) for as long as any does.
@MainActor
enum SignInNotices {
    private static let notifiedKey = "InfluxSignInNotified"
    private static var lastCount: Int?

    /// Call whenever the accounts or their states change.
    static func update(accounts: [Accounts.Account], states: [String: SourceFetchState]) {
        let needing = accounts.filter { $0.needsSignIn(states) }
        #if os(macOS)
        NSApplication.shared.dockTile.badgeLabel = needing.isEmpty ? nil : "!"
        #endif
        // Sample runs (previews, UI tests) never ask for notifications.
        guard !AppSettings.seedTimeline, !AppSettings.perfStore else { return }
        var notified = Set(UserDefaults.standard.stringArray(forKey: notifiedKey) ?? [])
        // An account notified about is forgotten only once it is seen
        // signed in, with the states read, so a launch that reads the
        // accounts before their states doesn't notify again.
        if !states.isEmpty {
            for account in accounts where !account.needsSignIn(states) {
                notified.remove(account.id)
            }
        }
        let fresh = needing.filter { !notified.contains($0.id) }
        notified.formUnion(fresh.map(\.id))
        UserDefaults.standard.set(Array(notified).sorted(), forKey: notifiedKey)
        let count = needing.count
        let center = UNUserNotificationCenter.current()
        let messages = fresh.map { account in
            (id: account.id, body: SignInAlert.headline(service: account.service.name, name: account.name, signedOut: account.isSignedIn))
        }
        // States change at every fetch; only a new count or account needs
        // the notification centre.
        guard !messages.isEmpty || count != lastCount else { return }
        lastCount = count
        Task {
            if messages.isEmpty {
                // Never asks: only an alert worth sending does that.
                guard await center.notificationSettings().authorizationStatus == .authorized else { return }
            } else {
                guard (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) == true else { return }
            }
            #if os(iOS)
            try? await center.setBadgeCount(count)
            #endif
            for message in messages {
                let content = UNMutableNotificationContent()
                content.title = "Influx needs you to sign in again"
                content.body = message.body + " Open Influx and choose Sign in again."
                content.sound = .default
                try? await center.add(UNNotificationRequest(identifier: "sign-in:\(message.id)", content: content, trigger: nil))
            }
            if count == 0 {
                center.removeDeliveredNotifications(withIdentifiers: accounts.map { "sign-in:\($0.id)" })
            }
        }
    }
}
