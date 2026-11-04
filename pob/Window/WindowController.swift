import AppKit
import WebKit

final class WindowController: NSWindowController, NSPopoverDelegate {
    let tab: Tab
    let rail = Rail()
    private(set) var usesFallbackBlur = false
    private(set) var railState = RailState()

    private let appearance: AppearanceModel
    private let contentView = NSView()
    private var blurGate = BlurGate()
    private var fallbackBlurView: NSVisualEffectView?
    private let edgeStrip = EdgeStrip()
    private var railLeading: NSLayoutConstraint?
    private var railCloseTask: Task<Void, Never>?
    private var openPopover: NSPopover?

    init(appearance: AppearanceModel, tab: Tab) {
        self.appearance = appearance
        self.tab = tab

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hasShadow = true
        window.minSize = NSSize(width: 480, height: 360)
        window.center()
        super.init(window: window)

        buildContent(in: window)
        connectRail()
        setWindowButtonsVisible(false)
        appearance.onChange = { [weak self] in self?.applyAppearance() }
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func applyAppearance() {
        guard let window else { return }
        let effective = appearance.effective
        tab.webView.alphaValue = effective.pageAlpha

        if !PrivateAPI.setWindowBlur(window, radius: blurGate.radiusToSend(effective.blurRadius)) {
            installFallbackBlur()
        }
        fallbackBlurView?.isHidden = effective.blurRadius == 0
        window.invalidateShadow()
    }

    func perform(_ id: CommandID) {
        switch id {
        case .back: tab.webView.goBack()
        case .forward: tab.webView.goForward()
        case .reload: tab.webView.reload()
        case .snapOpaque: appearance.toggleSnap()
        case .closeWindow: window?.performClose(nil)
        case .toggleRail:
            railState.toggleShortcut()
            if railState.visibility == .hidden {
                window?.makeFirstResponder(tab.webView)
            }
            applyRailState()
        case .focusAddress:
            railState.beginEditingAddress()
            applyRailState()
            rail.addressField.selectText(nil)
        case .toggleInspector:
            let webView = tab.webView
            let opened = PrivateAPI.isInspectorVisible(webView)
                ? PrivateAPI.closeInspector(webView)
                : PrivateAPI.showInspector(webView)
            reportInspector(available: opened)
        case .showConsole:
            reportInspector(available: PrivateAPI.showConsole(tab.webView))
        case .showPageSource:
            reportInspector(available: PrivateAPI.showPageSource(tab.webView))
        case .openInSafari:
            openInSafari()
        default: break
        }
    }

    func applyRailState() {
        let isVisible = railState.visibility != .hidden
        setWindowButtonsVisible(isVisible)
        tab.webView.obscuredContentInsets.left = railState.visibility == .pinned ? Rail.width + 2 * Rail.inset : 0

        if isVisible {
            rail.isHidden = false
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : 0.17
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            railLeading?.animator().constant = isVisible ? Rail.inset : -(Rail.width + Rail.inset)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.railState.visibility == .hidden else { return }
                self.rail.isHidden = true
            }
        }
    }

    func setWindowButtonsVisible(_ visible: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(button)?.isHidden = !visible
        }
    }

    private func buildContent(in window: NSWindow) {
        window.contentView = contentView

        let webView = tab.webView
        webView.frame = contentView.bounds
        webView.autoresizingMask = [.width, .height]
        contentView.addSubview(webView)

        let strip = TopDragStrip(frame: NSRect(
            x: 0,
            y: contentView.bounds.height - TopDragStrip.height,
            width: contentView.bounds.width,
            height: TopDragStrip.height
        ))
        strip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(strip)

        rail.translatesAutoresizingMaskIntoConstraints = false
        rail.isHidden = true
        contentView.addSubview(rail)
        let leading = rail.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor,
            constant: -(Rail.width + Rail.inset)
        )
        railLeading = leading
        NSLayoutConstraint.activate([
            leading,
            rail.widthAnchor.constraint(equalToConstant: Rail.width),
            rail.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Rail.inset),
            rail.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Rail.inset),
        ])

        edgeStrip.frame = NSRect(x: 0, y: 0, width: EdgeStrip.width, height: contentView.bounds.height)
        edgeStrip.autoresizingMask = [.height]
        contentView.addSubview(edgeStrip)
    }

    private func connectRail() {
        edgeStrip.onDwell = { [weak self] in
            guard let self else { return }
            railCloseTask?.cancel()
            railState.pointerDwelledAtEdge()
            applyRailState()
        }
        edgeStrip.onExit = { [weak self] in self?.scheduleRailClose() }
        rail.onPointerExit = { [weak self] in self?.scheduleRailClose() }
        rail.onNavigate = { [weak self] in self?.perform($0) }
        rail.onSettings = { [weak self] in self?.showAppearancePopover() }
        rail.onAddressFocus = { [weak self] in
            guard let self else { return }
            railState.beginEditingAddress()
            applyRailState()
        }
        rail.onAddressEndEditing = { [weak self] in
            guard let self else { return }
            railState.endEditingAddress(pointerInsideRail: isPointerOverRail)
            applyRailState()
        }
        rail.onSubmit = { [weak self] text in
            guard let self else { return }
            if let input = AddressInput.classify(text) {
                tab.load(input)
            }
            window?.makeFirstResponder(tab.webView)
        }
        rail.onCancel = { [weak self] in
            guard let self else { return }
            updateRailContents()
            window?.makeFirstResponder(tab.webView)
        }
        tab.onStateChange = { [weak self] in self?.updateRailContents() }
    }

    private func updateRailContents() {
        rail.update(url: tab.webView.url, canGoBack: tab.webView.canGoBack, canGoForward: tab.webView.canGoForward)
    }

    /// The rail closes shortly after the pointer leaves, unless it comes back or is still over the rail.
    private func scheduleRailClose() {
        railCloseTask?.cancel()
        railCloseTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, let self, !isPointerOverRail, openPopover == nil else { return }
            railState.pointerLeftRail()
            applyRailState()
        }
    }

    private func reportInspector(available: Bool) {
        guard !available else { return }
        let alert = NSAlert()
        alert.messageText = "Web Inspector isn't available in the window. Open this page in Safari's Develop menu instead."
        alert.present(in: window) { _ in }
    }

    private func openInSafari() {
        guard let url = tab.safariURL else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: "/Applications/Safari.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func showAppearancePopover() {
        showPopover(AppearancePopover(model: appearance), from: rail.settingsButton)
    }

    private func showPopover(_ content: NSViewController, from anchor: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = content
        popover.delegate = self
        openPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    func popoverDidClose(_ notification: Notification) {
        openPopover = nil
        scheduleRailClose()
    }

    private var isPointerOverRail: Bool {
        guard let window else { return false }
        let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return contentView.bounds.contains(point) && point.x <= rail.frame.maxX
    }

    private func installFallbackBlur() {
        guard fallbackBlurView == nil else { return }
        let blurView = NSVisualEffectView(frame: contentView.bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.blendingMode = .behindWindow
        blurView.material = .underWindowBackground
        blurView.state = .active
        contentView.addSubview(blurView, positioned: .below, relativeTo: tab.webView)
        fallbackBlurView = blurView
        usesFallbackBlur = true
    }
}
