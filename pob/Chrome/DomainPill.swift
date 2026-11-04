import AppKit

/// A small glass pill at the bottom left. It names the page's host for a moment after a load, and clicking it copies the address.
final class DomainPill: NSView {
    static let visibleDuration: Duration = .seconds(2)
    private static let copiedDuration: Duration = .seconds(1)
    private static let fadeDuration: TimeInterval = 0.2

    /// Punycode, so lookalike hosts stand out. `URL.host()` would percent-encode a raw international host instead.
    static func displayHost(for url: URL?) -> String? {
        guard let url, let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost, !host.isEmpty else { return nil }
        return host
    }

    /// True while the rail is open, so the pill stays out of its way.
    var isSuppressed = false {
        didSet {
            if isSuppressed { hide(animated: false) }
        }
    }
    /// The page's address. A notice never changes it.
    private(set) var currentURL: URL?

    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?
    private var fadeGeneration = 0
    private var isHovered = false
    private var trackingArea: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = 13
        glass.effectIsInteractive = true // the pill is a control
        let content = NSView()
        glass.contentView = content
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy address")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows the host of a freshly loaded page, or hides the pill when the page has none.
    func show(url: URL?) {
        currentURL = url
        guard let host = Self.displayHost(for: url) else { return hide(animated: false) }
        present(host, for: Self.visibleDuration)
    }

    /// Shows text for the same time, such as a download's filename. The page's address stays as it was.
    func showNotice(_ text: String) {
        present(text, for: Self.visibleDuration)
    }

    func copyURL(to pasteboard: NSPasteboard) {
        guard let currentURL else { return }
        pasteboard.clearContents()
        pasteboard.setString(currentURL.absoluteString, forType: .string)
    }

    // MARK: Showing and hiding

    private func present(_ text: String, for duration: Duration) {
        guard !isSuppressed else { return hide(animated: false) }
        fadeGeneration += 1
        label.stringValue = text
        alphaValue = 1
        isHidden = false
        scheduleHide(after: duration)
    }

    /// Hovering holds the pill, so the clock only runs while the pointer is outside it.
    private func scheduleHide(after duration: Duration) {
        hideTask?.cancel()
        guard !isHovered else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
    }

    private func hide(animated: Bool) {
        hideTask?.cancel()
        fadeGeneration += 1
        let generation = fadeGeneration
        guard animated, !isHidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new show in the meantime owns the pill.
                guard let self, self.fadeGeneration == generation else { return }
                self.isHidden = true
            }
        }
    }

    // MARK: Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard currentURL != nil else { return }
        copyURL(to: .general)
        present("Copied", for: Self.copiedDuration)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        hideTask?.cancel()
        if !isHidden, alphaValue < 1 { // caught mid-fade
            fadeGeneration += 1
            alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        if !isHidden {
            scheduleHide(after: Self.visibleDuration)
        }
    }
}
