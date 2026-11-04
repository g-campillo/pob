import AppKit

/// A faint tint behind the page. Without it, a blank page leaves the window fully clear,
/// and macOS has nothing to blur, so the window can't be seen or clicked.
final class BackdropView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }
}
