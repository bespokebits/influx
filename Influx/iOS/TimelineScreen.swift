import SwiftUI

/// Hosts the UIKit timeline in the SwiftUI shell.
struct TimelineScreen: UIViewControllerRepresentable {
    let app: AppModel
    /// The saved view to show. A different view is a different timeline:
    /// the shell gives each its own identity, so switching makes a new one.
    let viewID: String
    /// The window's way to this timeline for the Timeline menu.
    let jumps: TimelineJumps
    /// The window's way to this timeline for the Item menu.
    let items: TimelineItems

    func makeUIViewController(context: Context) -> TimelineViewController {
        TimelineViewController(app: app, viewID: viewID, jumps: jumps, items: items)
    }

    func updateUIViewController(_ controller: TimelineViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: TimelineViewController, coordinator: ()) {
        controller.tearDown()
    }
}
