import AppKit

/// A small glass pill at the bottom left. It names the page's host for a moment after a load and while the pointer rests in the window's bottom-left corner, and clicking it copies the address.
final class DomainPill: NSView {
    static let visibleDuration: Duration = .seconds(2)
    /// The band along the window's bottom edge, from its left corner, where resting the pointer brings the pill up.
    /// It reaches a little way under the pill, so the pointer moves onto the pill without leaving both, and no further,
    /// so a link under the pill still takes a click.
    static let cornerSize = NSSize(width: 200, height: 18)
    private static let fadeDuration: TimeInterval = 0.2

    /// Punycode, so lookalike hosts stand out. `URL.host()` would percent-encode a raw international host instead.
    static func displayHost(for url: URL?) -> String? {
        guard let url, let host = URLComponents(url: url, resolvingAgainstBaseURL: false)?.encodedHost, !host.isEmpty else { return nil }
        return host
    }

    /// True while a rail opened by hovering covers the corner, so the pill stays out of its way. A pinned rail leaves it be.
    var isSuppressed = false {
        didSet {
            if isSuppressed {
                hide(animated: false)
            } else if oldValue, isHeld { // the pointer still in the corner gets the pill back
                reveal()
            }
        }
    }
    /// The pointer is resting in the corner, and the pill stays up until it leaves.
    var isPointerInCorner = false {
        didSet {
            guard isPointerInCorner != oldValue else { return }
            if isPointerInCorner { reveal() } else { hideIfFree() }
        }
    }
    /// Watches the corner for the pointer. The window places it, and it never takes clicks.
    let corner = EdgeStrip()
    /// The page's address. A notice never changes it.
    private(set) var currentURL: URL?
    /// A fade out is running. Its completion hides the pill only if nothing showed it again first.
    private(set) var isFadingOut = false

    /// Replaceable so tests needn't wait out the real times.
    var visibleFor = DomainPill.visibleDuration
    var copiedFor: Duration = .seconds(1)
    var pasteboard = NSPasteboard.general

    private let label = NSTextField(labelWithString: "")
    private var hideTask: Task<Void, Never>?
    private var fadeGeneration = 0
    private var isHovered = false
    /// A notice or Copied, shown over the host until its time is up.
    private var message: String?
    /// Text is up for a set time, on a clock that hovering pauses.
    private var isOnClock = false
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
        corner.onDwell = { [weak self] in self?.isPointerInCorner = true }
        corner.onExit = { [weak self] in self?.isPointerInCorner = false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Shows the host of a freshly loaded page, or hides the pill when the page has none.
    func show(url: URL?) {
        currentURL = url
        guard Self.displayHost(for: url) != nil else { return hide(animated: false) }
        present(nil, for: visibleFor)
    }

    /// Shows text for the same time, such as a download's filename. The page's address stays as it was.
    func showNotice(_ text: String) {
        present(text, for: visibleFor)
    }

    func copyURL(to pasteboard: NSPasteboard) {
        guard let currentURL else { return }
        pasteboard.clearContents()
        pasteboard.setString(currentURL.absoluteString, forType: .string)
    }

    // MARK: Showing and hiding

    /// Something besides a clock keeps the pill up.
    private var isHeld: Bool { isPointerInCorner }

    /// Shows a notice, or the host when there's none, for `duration`.
    private func present(_ message: String?, for duration: Duration, holdsOnHover: Bool = true) {
        self.message = message
        reveal()
        guard !isHidden else { return } // the rail is open, or there's nothing to say
        isOnClock = true
        scheduleHide(after: duration, holdsOnHover: holdsOnHover)
    }

    /// Brings the pill up with the notice, or else the host. With nothing to say, or with the rail open, it hides instead.
    private func reveal() {
        guard !isSuppressed, let text = message ?? Self.displayHost(for: currentURL) else { return hide(animated: false) }
        if label.stringValue != text { // only a change, so a repeat doesn't lay the pill out again
            label.stringValue = text
        }
        guard isHidden || isFadingOut else { return } // already up, and a fade in still running carries on
        fadeGeneration += 1 // a fade out still running no longer owns the pill
        isFadingOut = false
        let fadesIn = isHidden && !reducesMotion()
        alphaValue = fadesIn ? 0 : 1
        isHidden = false
        if fadesIn {
            Motion.animate(Motion.fadeIn) { alphaValue = 1 }
        }
    }

    /// Hovering holds the pill, so the clock only runs while the pointer is outside it.
    private func scheduleHide(after duration: Duration, holdsOnHover: Bool = true) {
        hideTask?.cancel()
        guard !(isHovered && holdsOnHover) else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.clockRanOut()
        }
    }

    /// A notice gives way to the host while something else holds the pill. Otherwise the pill goes.
    private func clockRanOut() {
        isOnClock = false
        message = nil
        if isHeld { reveal() } else { hide(animated: true) }
    }

    /// Hides the pill once nothing keeps it up: no clock, no pointer on it, and nothing else holding it.
    private func hideIfFree() {
        guard !isOnClock, !isHovered, !isHeld else { return }
        hide(animated: true)
    }

    /// Replaceable because the fade's completion never fires while the display is asleep, so tests take the instant path.
    var reducesMotion: () -> Bool = { !Motion.isOn }

    private func hide(animated: Bool) {
        hideTask?.cancel()
        isOnClock = false
        message = nil
        fadeGeneration += 1
        let generation = fadeGeneration
        guard animated, !isHidden, !reducesMotion() else {
            isFadingOut = false
            isHidden = true
            isHovered = false // a hidden view gets no mouseExited
            return
        }
        isFadingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A new show in the meantime owns the pill.
                guard let self, self.fadeGeneration == generation else { return }
                self.isFadingOut = false
                self.isHidden = true
                self.isHovered = false
            }
        }
    }

    // MARK: Pointer

    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func mouseDown(with event: NSEvent) {
        guard currentURL != nil else { return }
        copyURL(to: pasteboard)
        // The pointer is inside by definition, so this one fades regardless of hover.
        present("Copied", for: copiedFor, holdsOnHover: false)
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
        if isFadingOut { // caught mid-fade. It goes back on its clock, which waits for the pointer to leave
            fadeGeneration += 1
            isFadingOut = false
            isOnClock = true
            alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        guard !isHidden else { return }
        if isOnClock {
            scheduleHide(after: visibleFor)
        } else {
            hideIfFree()
        }
    }
}
