import AppKit

/// A small glass pill at the bottom left. It names the page's host for a moment after a load and while the pointer rests in the window's bottom-left corner, and clicking it copies the address. A load that takes a while shows with a bar under the host.
final class DomainPill: NSView {
    static let visibleDuration: Duration = .seconds(2)
    /// The band along the window's bottom edge, from its left corner, where resting the pointer brings the pill up.
    /// It reaches a little way under the pill, so the pointer moves onto the pill without leaving both, and no further,
    /// so a link under the pill still takes a click.
    static let cornerSize = NSSize(width: 200, height: 18)
    /// A load has to run this long before the pill shows it, so a quick one never flashes a bar.
    static let progressDelay: Duration = .milliseconds(500)
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
    /// The address the pill names: the page's, or the one a showing load is going to. A notice never changes it.
    private(set) var currentURL: URL?
    /// A fade out is running. Its completion hides the pill only if nothing showed it again first.
    private(set) var isFadingOut = false
    /// A load has run past `progressDelay` and is still going, so the bar shows under the host.
    private(set) var showsProgress = false
    /// The page's progress, under the host while a load shows.
    let bar = LoadingBar()

    /// Replaceable so tests needn't wait out the real times.
    var visibleFor = DomainPill.visibleDuration
    var copiedFor: Duration = .seconds(1)
    var progressDelay = DomainPill.progressDelay
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
    /// The active page's load while it runs: where it's going and how far it has got.
    private var load: (url: URL?, progress: Double)?
    private var progressTask: Task<Void, Never>?
    /// The label sits on the pill's bottom edge until a load opens the bar's row under it.
    private lazy var labelAtBottom = label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5)
    private lazy var barRow = [
        bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 80), // a short host still gets a bar that reads as progress
    ]

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
        // Just above the glass's hugging (250). A tie lets the pill settle anywhere down to its padding, with no text showing.
        // Still below the window's hold on its size (500), so a long host truncates instead of widening the window.
        label.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bar)

        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            labelAtBottom,
            bar.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 3),
            bar.heightAnchor.constraint(equalToConstant: LoadingBar.height),
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

    /// Follows the active page's load. One still running after `progressDelay` brings the pill up with the bar under the
    /// host it's going to, and once it ends the pill shows that host for `visibleFor`, like any finished load.
    func update(url: URL?, progress: Double, isLoading: Bool) {
        guard isLoading else { return endLoad(at: url) }
        let starting = load == nil
        load = (url, progress)
        if showsProgress {
            showLoad()
        } else if starting {
            progressTask?.cancel()
            progressTask = Task { [weak self, progressDelay] in
                try? await Task.sleep(for: progressDelay)
                guard !Task.isCancelled else { return }
                self?.showLoad()
            }
        }
    }

    /// Another page came forward, as on a tab switch: its host for a moment, and its own load from the start,
    /// without the bar of the page before.
    func showPage(url: URL?, progress: Double, isLoading: Bool) {
        progressTask?.cancel()
        load = nil
        showsProgress = false
        collapseBar()
        show(url: url)
        update(url: url, progress: progress, isLoading: isLoading)
    }

    func copyURL(to pasteboard: NSPasteboard) {
        guard let currentURL else { return }
        pasteboard.clearContents()
        pasteboard.setString(currentURL.absoluteString, forType: .string)
    }

    // MARK: Showing and hiding

    /// A load showing, or the pointer in the corner, keeps the pill up past any clock.
    private var isHeld: Bool { showsProgress || isPointerInCorner }

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

    /// Puts the running load in the pill. A notice keeps the label until its time is up.
    private func showLoad() {
        guard let load else { return }
        currentURL = load.url
        if showsProgress {
            bar.set(load.progress, animated: true)
        } else {
            showsProgress = true // first, so a fade or slide of the last load that this cuts short leaves the bar alone
            bar.set(load.progress, animated: false)
            showBar()
        }
        reveal()
    }

    /// However the load ended, one that showed settles into the page's host for `visibleFor`. Its bar fills, fades and
    /// takes its row with it.
    private func endLoad(at url: URL?) {
        progressTask?.cancel()
        load = nil
        guard showsProgress else { return }
        showsProgress = false
        currentURL = url
        bar.set(1, animated: true) { [weak self] in self?.fadeBar() }
        if isOnClock { // a notice keeps the rest of its time. A host on its clock changes to where the page landed
            reveal()
        } else {
            present(nil, for: visibleFor)
        }
    }

    /// Opens the bar's row under the host and fades the bar in.
    private func showBar() {
        labelAtBottom.isActive = false
        NSLayoutConstraint.activate(barRow)
        bar.isHidden = false
        bar.alphaValue = 0 // set directly, which also stops a fade out still running
        Motion.animate(Motion.fadeIn) { bar.alphaValue = 1 }
    }

    /// The bar fades once it's full, and its row goes once it's gone.
    private func fadeBar() {
        guard !showsProgress, !bar.isHidden else { return } // the next load took it, or the row has already gone
        Motion.animate(Motion.fadeOut) { bar.alphaValue = 0 } completion: { [weak self] in self?.collapseBar() }
    }

    /// Takes the bar's row away, so the pill is back to the host's height. A load that has the bar keeps it.
    private func collapseBar() {
        guard !showsProgress else { return }
        bar.isHidden = true
        bar.alphaValue = 1
        NSLayoutConstraint.deactivate(barRow)
        labelAtBottom.isActive = true
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
            collapseBar()
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
                self.collapseBar()
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
