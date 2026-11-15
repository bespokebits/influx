// A timeline row on macOS. It shows the row's finished bitmap and
// draws nothing itself.
import AppKit

final class TimelineItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("TimelineItem")

    override func loadView() {
        view = RowView()
    }

    func show(_ image: CGImage?, label: String, actions: @escaping () -> [NSAccessibilityCustomAction] = { [] }) {
        (view as? RowView)?.image = image
        (view as? RowView)?.actions = actions
        view.setAccessibilityLabel(label)
    }
}

private final class RowView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }
    /// The row's VoiceOver actions, built only when asked for.
    var actions: () -> [NSAccessibilityCustomAction] = { [] }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        actions()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        layer?.backgroundColor = Broadsheet.paper.cgColor
    }
}
