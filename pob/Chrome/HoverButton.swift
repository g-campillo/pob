import AppKit

/// A button that shows it can be clicked: a pointing hand over it, and for one with no border of its own, a fill behind it.
final class HoverButton: NSButton {
    private var hoverArea: NSTrackingArea?
    private var isHovered = false {
        didSet { showFill() }
    }

    override var isEnabled: Bool {
        didSet {
            window?.invalidateCursorRects(for: self)
            showFill()
        }
    }

    /// A cursor rect, because WebKit leaves the cursor alone while one is in force. Set any other way, the page
    /// under the rail takes the cursor back on the next move.
    override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {
            removeTrackingArea(hoverArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovered = false
    }

    /// A view taken away under the pointer gets no `mouseExited`.
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    func resetHover() {
        isHovered = false
    }

    private func showFill() {
        guard !isBordered else { return }
        wantsLayer = true
        layer?.cornerRadius = min(bounds.height / 4, 8)
        layer?.cornerCurve = .continuous
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = isHovered && isEnabled ? NSColor.quaternaryLabelColor.cgColor : nil
        }
    }
}
