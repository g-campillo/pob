import AppKit

/// Watches a stretch of the window's left edge for the pointer, which brings the rail out. It never takes clicks, so links there still work.
final class EdgeStrip: NSView {
    static let width: CGFloat = 8
    private static let dwell: Duration = .milliseconds(60)

    var onDwell: (() -> Void)?
    var onExit: (() -> Void)?

    private var dwellTask: Task<Void, Never>?
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            self?.onDwell?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        dwellTask?.cancel()
        onExit?()
    }

    /// A strip hidden under the pointer gets no `mouseExited`, so hiding it counts as the pointer leaving.
    override func viewDidHide() {
        super.viewDidHide()
        dwellTask?.cancel()
        onExit?()
    }
}
