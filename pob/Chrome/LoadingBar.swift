import AppKit

/// The thin bar under the host while a page loads: a faint track that the accent color fills. A mark, never a target.
final class LoadingBar: NSView {
    static let height: CGFloat = 3

    /// How much of the track is filled.
    private(set) var fraction: Double = 0
    private let fill = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fill.wantsLayer = true
        addSubview(fill)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Animated, the fill slides there on the spring, so the page's jumps in progress read as one movement.
    func set(_ fraction: Double, animated: Bool, completion: (() -> Void)? = nil) {
        self.fraction = min(max(fraction, 0), 1)
        guard animated else {
            fill.frame = filledRect // set directly, which also stops a slide still running
            completion?()
            return
        }
        Motion.animate(Motion.spring, { fill.frame = filledRect }, completion: completion)
    }

    private var filledRect: NSRect { NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height) }

    override func layout() {
        super.layout()
        fill.frame = filledRect
    }

    override var wantsUpdateLayer: Bool { true }

    /// The colors resolve here, in the view's appearance, so they follow light and dark.
    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        layer?.cornerRadius = Self.height / 2
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.layer?.cornerRadius = Self.height / 2
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
