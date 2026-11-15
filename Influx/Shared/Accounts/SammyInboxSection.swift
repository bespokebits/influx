import Combine
import SwiftUI
import InfluxKit

/// Bookmarks to Sammy Inbox on a Sammy account's screen: the switch, off
/// by default and the same on every device, what it has sent today and
/// what waits, and what was given up on. Switching it on with a session
/// that can't add to the Inbox yet asks first, then connects again for
/// `inbox:add` (`SammyInbox.set`).
struct SammyInboxSection: View {
    let account: Accounts.Account
    let inbox: SammyInbox
    /// The account needs signing in again, so nothing can be sent.
    var needsSignIn = false
    @State private var summary = SammyInboxSummary()
    /// Whether this device's session holds `inbox:add`.
    @State private var addsHere: Bool?
    @State private var asksApproval = false
    /// The start of the day "Sent today" counts from.
    @State private var today = Calendar.current.startOfDay(for: Date())

    static let footer = "When you bookmark an article or post in Influx, Sammy adds it to your Inbox with a link back here. Removing the bookmark later leaves the task."
    #if os(macOS)
    static let approvalMessage = "Sammy has to approve this first. Influx opens Sammy’s page in your browser with a code, the same way as when you connected. Your feeds stay as they are."
    #else
    static let approvalMessage = "Sammy has to approve this first. Influx opens Sammy’s page with a code, the same way as when you connected. Your feeds stay as they are."
    #endif

    var body: some View {
        Section {
            Toggle("Bookmarks to Sammy Inbox", isOn: Binding(get: { isConnecting || summary.isOn }, set: switched))
                // A setting, so a switch on the Mac too, where a list's
                // toggles are otherwise checkboxes.
                .toggleStyle(.switch)
                .disabled(isConnecting)
                .accessibilityIdentifier("sammy-inbox-switch")
            if isConnecting {
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(inbox.steps[account.id].map(AddSammySheet.message(for:)) ?? Accounts.SignInStep.contactingServer.message)
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 8)
                    // Always a way out, even when the sign-in page never
                    // appears: the switch stays off, as closing it does.
                    Button("Cancel") { inbox.cancelConnecting(account.id) }
                        .accessibilityIdentifier("sammy-inbox-cancel")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            } else if let error = inbox.errors[account.id] {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("sammy-inbox-error")
            }
            if summary.isOn {
                LabeledContent("Sent today", value: "\(summary.sent)")
                if summary.waiting > 0 {
                    // The count stays beside the title when the reason
                    // under it wraps.
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Waiting to send")
                            Text(waitingReason)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        Text("\(summary.waiting)")
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if summary.expired > 0 {
                note(count: summary.expired, "They didn’t reach Sammy within 7 days, so Influx stopped trying.")
            }
            if summary.refused > 0 {
                note(count: summary.refused, "Sammy didn’t accept them, so Influx won’t try again.")
            }
            #if os(macOS)
            // A Mac list draws a section footer on one line, which would
            // cut this off, so it is the section's last row there.
            Text(Self.footer)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            #endif
        } header: {
            Text("Sammy Inbox")
        } footer: {
            #if !os(macOS)
            Text(Self.footer)
            #endif
        }
        // "Sent today" counts from today's midnight: a new day starts the
        // observation again from the new midnight.
        .task(id: [account.id, String(today.timeIntervalSinceReferenceDate)]) {
            await inbox.watchSummary(account.id, since: today) { self.summary = $0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: DispatchQueue.main)) { _ in
            today = Calendar.current.startOfDay(for: Date())
        }
        .task(id: [summary.isOn, isConnecting]) {
            addsHere = await inbox.addsToInbox(account.id)
        }
        .alert("Let Influx add to your Inbox?", isPresented: $asksApproval) {
            Button("Cancel", role: .cancel) {}
            Button("Continue") {
                Task { await inbox.set(true, for: account, approve: true) }
            }
            .accessibilityIdentifier("sammy-inbox-continue")
        } message: {
            Text(Self.approvalMessage)
        }
    }

    private var isConnecting: Bool { inbox.connecting.contains(account.id) }

    /// Why bookmarks wait, as far as this device can tell.
    private var waitingReason: String {
        if needsSignIn { return "Sign in to Sammy again above to send them." }
        if addsHere == false { return "Waiting for Sammy’s approval to reach this \(SammyInbox.device). They go as soon as it does." }
        return "No connection, or Sammy is busy. Influx keeps trying."
    }

    private func note(count: Int, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(count == 1 ? "1 bookmark wasn’t sent" : "\(count) bookmarks weren’t sent")
                .foregroundStyle(SignInAlert.red)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func switched(_ on: Bool) {
        guard on else {
            Task { await inbox.set(false, for: account) }
            return
        }
        Task {
            if await inbox.addsToInbox(account.id) {
                await inbox.set(true, for: account)
            } else {
                asksApproval = true
            }
        }
    }
}
