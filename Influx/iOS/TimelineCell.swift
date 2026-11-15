// A timeline cell. It shows the row's finished bitmap and draws nothing
// itself.
import UIKit

final class TimelineCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Broadsheet.paper
        contentView.layer.contentsGravity = .resize
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Builds the VoiceOver text when it's read, not when the cell is shown.
    private var label: (() -> String)?
    /// The same for the row's actions.
    private var actions: (() -> [UIAccessibilityCustomAction])?

    override var accessibilityLabel: String? {
        get { label?() }
        set {}
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { actions?() }
        set {}
    }

    func show(_ image: CGImage?, scale: CGFloat, label: @escaping () -> String,
              actions: @escaping () -> [UIAccessibilityCustomAction] = { [] }) {
        self.label = label
        self.actions = actions
        contentView.layer.contentsScale = scale
        contentView.layer.contents = image
    }

    // Heights are final before display; never let the cell resize itself.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }
}
