import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The sync status panel, from the sync button: whether this device is up
/// to date with iCloud, when it last synced, what's waiting to go up, and
/// what went wrong lately, in the reader's words.
struct SyncStatusView: View {
    let sync: Sync
    /// True for a moment after the diagnostics were copied.
    @State private var copied = false

    var body: some View {
        let status = sync.status
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SlipsMarkView(phase: status.phase.mark)
                    .frame(width: 28, height: 28)
                Text(headline(status.phase))
                    .font(.system(.title3, design: .serif, weight: .semibold))
                    .foregroundStyle(Color.paint(Broadsheet.ink))
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 6) {
                if let last = status.lastSynced {
                    // Relative, so it keeps itself current while open.
                    Text("Last synced \(Text(last, style: .relative)) ago")
                } else {
                    Text("Hasn't reached iCloud yet")
                }
                Text(waiting(status.waiting))
                Text("Since Influx opened: \(count(status.sent, "change")) sent, \(status.received) received")
            }
            .font(.callout)
            .foregroundStyle(Color.paint(Broadsheet.ink2))

            if !status.problems.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent problems")
                        .font(.caption.weight(.semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.paint(Broadsheet.ink2))
                    ForEach(status.problems, id: \.message) { problem in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(problem.at, style: .time)
                                .monospacedDigit()
                                .foregroundStyle(Color.paint(Broadsheet.ink2))
                            Text(problem.message)
                                .foregroundStyle(Color.paint(Broadsheet.ink))
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
            }

            Button("Sync Now") { sync.tapped() }
                .disabled(status.phase == .syncing || status.phase == .starting)
                .accessibilityIdentifier("sync-now")

            // What sync did over the last two days, to paste to whoever is
            // finding out why a device opened where it did. Most readers
            // never need it, so it is a quiet line under a rule and Sync
            // Now stays the panel's one button
            // (docs/design/2026-11-sync-diagnostics).
            Divider()
            Button {
                Task {
                    Pasteboard.copy(await sync.diagnostics())
                    copied = true
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy Diagnostics", systemImage: "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(Color.paint(Broadsheet.ink2))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("copy-sync-diagnostics")
        }
        .padding(18)
        .frame(width: 300, alignment: .leading)
        .accessibilityIdentifier("sync-status")
    }

    private func headline(_ phase: SyncStatus.Phase) -> String {
        switch phase {
        case .starting: "Starting iCloud sync"
        case .syncing: "Syncing"
        case .synced: "Up to date"
        case .failed(let reason): reason
        }
    }

    private func waiting(_ count: Int?) -> String {
        switch count {
        case nil: "Checking for changes to send"
        case 0: "Nothing waiting to send"
        case let count?: "\(self.count(count, "change")) waiting to send"
        }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}

/// The system clipboard, the same call on both platforms.
enum Pasteboard {
    @MainActor
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}
