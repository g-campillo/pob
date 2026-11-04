import AppKit

/// A thin accent-colored bar along the top edge of the window. It is a status mark, never a target.
final class LoadingLine: NSView {
    static let height: CGFloat = 2

    /// How much of the width is filled, or 0 when nothing is loading.
    private(set) var fraction: Double = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        layerContentsRedrawPolicy = .duringViewResize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(progress: Double, isLoading: Bool) {
        fraction = isLoading ? min(max(progress, 0), 1) : 0
        isHidden = !isLoading
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height).fill()
    }
}
