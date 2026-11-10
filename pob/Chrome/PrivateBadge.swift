import AppKit

/// Marks a private window for as long as it's open. The rail says so too, but the rail hides.
final class PrivateBadge: NSView {
    static let size: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        let icon = NSImageView(image: NSImage(systemSymbolName: "eye.slash", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .labelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let content = addGlass(cornerRadius: Self.size / 2)
        content.addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            icon.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Private window")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// A mark, never a target. Clicks go to the page under it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
