import AppKit
import SwiftUI

enum MotionStyle: String, Codable, CaseIterable, Identifiable {
    case smooth, snappy

    var id: Self { self }

    var name: String {
        switch self {
        case .smooth: "Smooth"
        case .snappy: "Snappy"
        }
    }
}

/// Every animation in pob runs through here, so Snappy and Reduce Motion turn them all off in one place.
/// The numbers are the ones Rex uses for its panes.
enum Motion {
    /// `AppController` points this at the saved setting.
    static var style: () -> MotionStyle = { .smooth }
    /// Replaceable because an animation's completion never fires in a window that isn't on screen, as in a test run.
    static var reducesMotion: () -> Bool = {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || AppController.isRunningTests
    }

    static var isOn: Bool { style() == .smooth && !reducesMotion() }

    /// Critically damped, so it never bounces. It settles in about 0.4 s.
    static let spring = Animation.interpolatingSpring(mass: 1, stiffness: 1000, damping: 63.246)
    static let fadeIn = Animation.timingCurve(0.5, 0.5, 0.75, 1, duration: 0.173)
    /// Leaving is quicker than arriving.
    static let fadeOut = Animation.timingCurve(0.5, 0.5, 0.75, 1, duration: 0.146)
    /// How small a view is when it starts growing into place.
    static let startScale: CGFloat = 0.87

    /// Animates changes made straight to a view's frame or alpha. A constraint change doesn't animate.
    /// The view gets there a frame at a time, so it reads back its old value until then. An animation cut short by
    /// another, or by a plain set, calls its completion at once.
    static func animate(_ animation: Animation = spring, _ changes: () -> Void, completion: (() -> Void)? = nil) {
        guard isOn else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.animate(animation, changes: changes, completion: completion)
    }
}

private var shownKey: UInt8 = 0

extension NSView {
    /// What `setShown` was last asked for. `isHidden` only catches up once a fade out ends, and the alpha lags too,
    /// because an animation moves it a frame at a time. A view hidden with a plain `isHidden = true` counts as hidden,
    /// or the next show would be taken for one already done and leave it hidden.
    private var isMeantToShow: Bool {
        get { (objc_getAssociatedObject(self, &shownKey) as? Bool ?? true) && !isHidden }
        set { objc_setAssociatedObject(self, &shownKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    /// Shows or hides the view the way Rex's panes come and go: in from 87% on the spring with a quick fade, out faster.
    func setShown(_ shown: Bool, scales: Bool = true) {
        let wasMeantToShow = isMeantToShow
        isMeantToShow = shown
        guard Motion.isOn else {
            alphaValue = 1 // set directly, which also stops a fade still running
            isHidden = !shown
            return
        }
        guard shown != wasMeantToShow else { return }
        if shown {
            if isHidden { // caught mid-fade, it carries on from where it is
                alphaValue = 0
                isHidden = false
            }
            Motion.animate(Motion.fadeIn) { alphaValue = 1 }
            if scales { grow() }
        } else {
            Motion.animate(Motion.fadeOut) { alphaValue = 0 } completion: { [weak self] in
                // A fade cut short by a show reports its end too, at once, and the view is the show's to keep.
                guard let self, !isMeantToShow else { return }
                isHidden = true
                alphaValue = 1
            }
            if scales { shrink() }
        }
    }

    func grow() {
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = 1000
        spring.damping = 63.246
        spring.duration = spring.settlingDuration
        scale(from: Motion.startScale, to: 1, with: spring)
    }

    func shrink() {
        let linear = CABasicAnimation(keyPath: "transform")
        linear.duration = 0.149
        scale(from: 1, to: Motion.startScale, with: linear)
    }

    /// Only what's on screen scales. The view's own frame never changes.
    private func scale(from: CGFloat, to: CGFloat, with animation: CABasicAnimation) {
        guard Motion.isOn, let layer else { return }
        // AppKit anchors a view's layer at its corner, so the move keeps the middle where it is.
        func about(_ scale: CGFloat) -> CATransform3D {
            CATransform3DConcat(
                CATransform3DMakeScale(scale, scale, 1),
                CATransform3DMakeTranslation(bounds.midX * (1 - scale), bounds.midY * (1 - scale), 0)
            )
        }
        animation.fromValue = about(from)
        animation.toValue = about(to)
        layer.add(animation, forKey: "pob.scale")
    }
}
