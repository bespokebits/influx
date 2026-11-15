import SwiftUI

/// The Timeline menu: Refresh (⇧⌘R), and the jumps for an oldest-first
/// timeline. Jump to Newest (⌘↓) goes to the bottom. On iOS the same commands
/// show in the hardware keyboard's shortcut list.
struct TimelineCommands: Commands {
    let app: AppModel
    /// The timeline in the focused window.
    @FocusedValue(\.timelineJumps) private var jumps
    /// Find in Timeline in the focused window.
    @FocusedValue(\.timelineFind) private var find

    var body: some Commands {
        #if os(macOS)
        // ⌘F is Find in Timeline. The standard Find items would take it
        // first, and there is no other text to find in.
        CommandGroup(replacing: .textEditing) {}
        #endif
        CommandMenu("Timeline") {
            Button("Refresh") { Task { await app.refreshNow() } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Find in Timeline…") { find?.begin() }
                .keyboardShortcut("f")
                .disabled(find == nil)
            Divider()
            Button("Jump to Newest") { jumps?.timeline?.jumpToNewest() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(jumps == nil)
            Button("Jump to Marker") { jumps?.timeline?.jumpToMarker() }
                .keyboardShortcut("j")
                .disabled(jumps == nil)
            Button("Jump Back") { jumps?.timeline?.jumpBack() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(jumps?.canJumpBack != true)
        }
    }
}

/// A window's way to its timeline for the Timeline menu. The shell keeps
/// one per window; the timeline showing in it attaches itself, and a new
/// one takes over when the view changes.
@MainActor
@Observable
final class TimelineJumps {
    @ObservationIgnored private(set) weak var timeline: TimelineController?
    private(set) var canJumpBack = false
    /// Whether "Back to where you were" shows, after a Find result.
    private(set) var offersReturn = false
    /// Goes up whenever the attached timeline's rows change, or another
    /// timeline attaches, so an open Find searches again.
    private(set) var rowsChanged = 0

    func attach(_ timeline: TimelineController) {
        self.timeline = timeline
        canJumpBack = timeline.canJumpBack
        offersReturn = timeline.offersReturn
        timeline.onCanJumpBackChange = { [weak self, weak timeline] can in
            guard let self, self.timeline === timeline else { return }
            self.canJumpBack = can
        }
        timeline.onOffersReturnChange = { [weak self, weak timeline] offers in
            guard let self, self.timeline === timeline else { return }
            self.offersReturn = offers
        }
        timeline.model.onReplace = { [weak self, weak timeline] in
            guard let self, self.timeline === timeline else { return }
            self.rowsChanged += 1
        }
        rowsChanged += 1
    }

    /// The old timeline may go after the new one has attached.
    func detach(_ timeline: TimelineController) {
        guard self.timeline === timeline else { return }
        self.timeline = nil
        canJumpBack = false
        offersReturn = false
        rowsChanged += 1
    }
}

extension FocusedValues {
    @Entry var timelineJumps: TimelineJumps?
    @Entry var timelineFind: TimelineFind?
}
