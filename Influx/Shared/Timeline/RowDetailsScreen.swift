// Row Details, from the row menu: everything this device knows about why a
// row sits where it does (influx-dev#285, ADR 0043). Its copies with their
// publish and fetch times, the rule that placed it and the line that held
// it, the positions iCloud moved it to, and the sync journal's lines that
// name it. It is text the reader can copy into a report, as Copy
// Diagnostics is; nothing leaves the device unless they do.
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif
import InfluxKit

struct RowDetailsScreen: View {
    let store: InfluxStore
    let row: TimelineRow
    var close: () -> Void
    @State private var text: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text ?? "Loading…")
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityIdentifier("row-details-text")
            }
            .navigationTitle("Row Details")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                        .accessibilityIdentifier("row-details-done")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(copied ? "Copied" : "Copy") { copy() }
                        .disabled(text == nil)
                        .accessibilityIdentifier("row-details-copy")
                }
            }
        }
        .task { text = await Self.details(of: row, in: store) }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 480, idealHeight: 640)
        #endif
    }

    private func copy() {
        guard let text else { return }
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
    }

    /// The details as text: the build, the row as the timeline shows it,
    /// its history, and the journal lines that name it.
    nonisolated static func details(of row: TimelineRow, in store: InfluxStore, now: Date = Date()) async -> String {
        var lines = ["Influx \(BuildInfo.versionLine), \(platform), copied \(now.ISO8601Format())", ""]
        lines += shown(row)
        lines.append("")
        do {
            lines.append(try await store.rowHistory(mergeKey: row.mergeKey, shownItemID: row.id).text)
        } catch {
            lines.append("History: couldn't be read (\(error))")
        }
        let journal = (try? await store.syncJournal(since: now.addingTimeInterval(-7 * 86_400), limit: 20_000)) ?? []
        let naming = journal.filter { names($0.message, row.mergeKey) }
        lines += ["", "Sync journal lines naming this row, last 7 days (\(naming.count))"] + naming.map(\.line)
        return lines.joined(separator: "\n")
    }

    /// Whether a journal line names `key` as a whole: one key can begin
    /// another (`…/posts/1` and `…/posts/10`), so the key must stand
    /// between spaces or punctuation, not run on into a longer one.
    nonisolated static func names(_ message: String, _ key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let bounds: Set<Character> = [" ", ",", ";", "(", ")", "[", "]", "\""]
        var from = message.startIndex
        while let range = message.range(of: key, range: from..<message.endIndex) {
            let before = range.lowerBound == message.startIndex ? nil : message[message.index(before: range.lowerBound)]
            let after = range.upperBound == message.endIndex ? nil : message[range.upperBound]
            if (before.map(bounds.contains) ?? true) && (after.map(bounds.contains) ?? true) { return true }
            from = message.index(after: range.lowerBound)
        }
        return false
    }

    /// The row as the timeline shows it: the times the header draws from.
    nonisolated static func shown(_ row: TimelineRow) -> [String] {
        func stamp(_ date: Date?) -> String {
            date.map { Date.ISO8601FormatStyle(includingFractionalSeconds: true).format($0) } ?? "none"
        }
        return [
            "Shown from \(row.sourceTitle) (\(row.sourceID)), item \(row.id)",
            "Header time \(stamp(RowText.shownDate(row)))",
            "Published \(stamp(row.publishedAt)); posted \(stamp(row.postedAt)); boosted \(stamp(row.boostedAt))",
            "First fetched here \(stamp(row.fetchedAt)); arrow shows \(stamp(RowText.receivedDate(row)))",
            "Sits at \(stamp(row.sortDate))",
            "Read \(row.isRead ? "yes" : "no")",
        ]
    }

    private nonisolated static var platform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }
}
