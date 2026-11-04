import AppKit

/// The window has no visible title bar, so this thin strip along the top edge moves it.
final class TopDragStrip: NSView {
    static let height: CGFloat = 6

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}
