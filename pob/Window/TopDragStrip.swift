import AppKit

/// The window has no visible title bar, so this strip along the top edge moves it. It's as tall as a title bar and lies
/// over the page, so only a press that moves is a drag. One that doesn't is the page's click.
final class TopDragStrip: NSView {
    static let height: CGFloat = 32
    /// How far the pointer moves before a press is a drag.
    static let slop: CGFloat = 3

    /// Replaceable because a real window drag runs its own event loop.
    var startDrag: (NSEvent) -> Void = { $0.window?.performDrag(with: $0) }

    static func takes(_ type: NSEvent.EventType?) -> Bool { type == .leftMouseDown }

    /// Scrolling, right clicks and hovering go to the page underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.takes(NSApp.currentEvent?.type) ? super.hitTest(point) : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { return click(event, next) }
            let start = event.locationInWindow, now = next.locationInWindow
            if hypot(now.x - start.x, now.y - start.y) > Self.slop { return startDrag(event) }
        }
    }

    /// Hands the press and release to whatever is under the strip, as the window would have.
    private func click(_ down: NSEvent, _ up: NSEvent) {
        isHidden = true
        defer { isHidden = false }
        guard let window, let content = window.contentView,
              let under = content.hitTest(content.superview?.convert(down.locationInWindow, from: nil) ?? down.locationInWindow)
        else { return }
        if under.acceptsFirstResponder { window.makeFirstResponder(under) }
        under.mouseDown(with: down)
        under.mouseUp(with: up)
    }
}
