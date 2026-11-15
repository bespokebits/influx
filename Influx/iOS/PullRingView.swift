import SwiftUI
import UIKit

/// The mark below the newest row while the reader pulls to refresh: the
/// Full Circle ring (`RingMark.pullFrame`), drawn with two shape layers so
/// that a scroll event sets one stroke end and changes no SwiftUI state
/// and no layout. Once the reader lets go, `refreshView` (the refresh as
/// the sync button draws it) takes over.
final class PullRingView: UIView {
    private let track = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let refreshView: UIView
    /// Whether the pull has gone far enough to refresh.
    private var armed = false
    private var pull: CGFloat = 0

    init(size: CGFloat, refreshView: UIView) {
        self.refreshView = refreshView
        super.init(frame: CGRect(x: 0, y: 0, width: size, height: size))
        isUserInteractionEnabled = false
        let scale = size / 24
        let path = UIBezierPath(arcCenter: CGPoint(x: RingMark.center.x * scale, y: RingMark.center.y * scale),
                                radius: RingMark.radius * scale, startAngle: -.pi / 2, endAngle: 3 * .pi / 2,
                                clockwise: true).cgPath
        for shape in [track, ring] {
            shape.frame = bounds
            shape.path = path
            shape.fillColor = nil
            shape.lineWidth = RingMark.stroke * scale
            shape.lineCap = .round
            shape.strokeEnd = 0
            shape.opacity = 0
            layer.addSublayer(shape)
        }
        track.strokeEnd = 1
        refreshView.frame = bounds
        refreshView.isHidden = true
        addSubview(refreshView)
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PullRingView, _) in view.applyColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// How far the reader has pulled, 0 to 1, where 1 refreshes on
    /// letting go.
    func setPull(_ pull: CGFloat) {
        guard pull != self.pull else { return }
        self.pull = pull
        let wasArmed = armed
        armed = pull >= 1
        let frame = RingMark.pullFrame(pull, armedFor: armed ? 0 : nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.opacity = Float(frame.trackOpacity)
        ring.opacity = Float(frame.ringOpacity)
        ring.strokeEnd = frame.ringDrawn
        if armed != wasArmed { applyColors() }
        CATransaction.commit()
        if armed, !wasArmed, !UIAccessibility.isReduceMotionEnabled { thump() }
    }

    /// Whether the refresh shows, in place of the pull.
    var showsRefresh = false {
        didSet {
            guard showsRefresh != oldValue else { return }
            refreshView.isHidden = !showsRefresh
            track.isHidden = showsRefresh
            ring.isHidden = showsRefresh
            if !showsRefresh { setPull(0) }
        }
    }

    /// The thump when the pull goes far enough: up to 1.18 and back, as
    /// `RingMark` draws it.
    private func thump() {
        let samples = 12
        let values = (0...samples).map { i -> CGFloat in
            RingMark.pullFrame(1, armedFor: RingMark.armLength * Double(i) / Double(samples)).ringScale.width
        }
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = values
        animation.duration = RingMark.armLength
        ring.add(animation, forKey: "thump")
    }

    private func applyColors() {
        let traits = traitCollection
        track.strokeColor = Broadsheet.rule.resolvedColor(with: traits).cgColor
        ring.strokeColor = (armed ? Broadsheet.ink : Broadsheet.ink2).resolvedColor(with: traits).cgColor
    }
}
