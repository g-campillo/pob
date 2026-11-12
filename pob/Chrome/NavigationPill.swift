import AppKit

/// Back and forward at the top left, where the window buttons sit while the rail is open. The rail has its own pair,
/// so the window only shows this one while the rail is away.
final class NavigationPill: NSView {
    /// From the window's top and left edges. Half the height on top of this makes the window's corner, so the two curves run side by side.
    static let inset: CGFloat = 12
    static let height: CGFloat = 28
    private static let buttonSize: CGFloat = 24

    var onNavigate: ((CommandID) -> Void)?

    private lazy var backButton = button("chevron.left", label: "Back", action: #selector(backPressed))
    private lazy var forwardButton = button("chevron.right", label: "Forward", action: #selector(forwardPressed))

    override init(frame: NSRect) {
        super.init(frame: frame)
        let content = addGlass(cornerRadius: Self.height / 2)
        content.addSubview(backButton)
        content.addSubview(forwardButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            backButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            forwardButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
            backButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            forwardButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        update(canGoBack: false, canGoForward: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(canGoBack: Bool, canGoForward: Bool) {
        backButton.isEnabled = canGoBack
        forwardButton.isEnabled = canGoForward
    }

    private func button(_ symbol: String, label: String, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage()
        let button = HoverButton(image: image, target: self, action: action)
        button.isBordered = false
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.buttonSize).isActive = true
        button.heightAnchor.constraint(equalToConstant: Self.buttonSize).isActive = true
        return button
    }

    @objc private func backPressed() { onNavigate?(.back) }
    @objc private func forwardPressed() { onNavigate?(.forward) }
}
