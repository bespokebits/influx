import SwiftUI
import InfluxKit

/// Over the timeline while any feed has kept failing for more than a day
///: names it, and opens Sources when tapped. It stays until
/// the feed fetches again or is removed.
struct FailingFeedsNotice: View {
    let feeds: Feeds
    let open: () -> Void

    var body: some View {
        let failing = feeds.failing
        if !failing.isEmpty {
            Button(action: open) {
                Label(Self.text(failing, states: feeds.states), systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .lineLimit(1)
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("failing-feeds-notice")
        }
    }

    /// "“Six Colors” not updating since Oct 27", or for several, how many
    /// and since when the first stopped.
    nonisolated static func text(_ failing: [Source], states: [String: SourceFetchState]) -> String {
        let since = failing.first.flatMap { states[$0.id]?.problemSince }
            .map { " since \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
        if failing.count == 1, let feed = failing.first {
            return "“\(feed.title)” not updating\(since)"
        }
        return "\(failing.count) feeds not updating\(since)"
    }
}
