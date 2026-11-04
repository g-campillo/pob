import AppKit
import WebKit

final class WindowController: NSWindowController, NSPopoverDelegate {
    let tabs: TabManager
    var tab: Tab? { tabs.activeTab }
    let rail = Rail()
    let backdrop = BackdropView()
    private(set) var usesFallbackBlur = false
    private(set) var railState = RailState()

    private let appearance: AppearanceModel
    private let contentView = NSView()
    private let topStrip = TopDragStrip()
    private weak var shownPage: NSView?
    private var blurGate = BlurGate()
    private var fallbackBlurView: NSVisualEffectView?
    private let edgeStrip = EdgeStrip()
    private var railLeading: NSLayoutConstraint?
    private var railCloseTask: Task<Void, Never>?
    private(set) var openPopover: NSPopover?

    init(appearance: AppearanceModel, tabs: TabManager) {
        self.appearance = appearance
        self.tabs = tabs

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
        connectTabs()
        setWindowButtonsVisible(false)
        appearance.addObserver { [weak self] in self?.applyAppearance() }
        showActiveTab()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func applyAppearance() {
        guard let window else { return }
        let effective = appearance.effective
        applyPageStyle()
        backdrop.alphaValue = effective.pageAlpha < 1 ? 0.25 : 1

        if !PrivateAPI.setWindowBlur(window, radius: blurGate.radiusToSend(effective.blurRadius)) {
            installFallbackBlur()
        }
        fallbackBlurView?.isHidden = effective.blurRadius == 0
        window.invalidateShadow()
    }

    func perform(_ id: CommandID) {
        switch id {
        case .back: tab?.webView.goBack()
        case .forward: tab?.webView.goForward()
        case .reload: tab?.webView.reload()
        case .snapOpaque: appearance.toggleSnap()
        case .closeWindow: window?.performClose(nil)
        case .closeTab:
            if let active = tabs.list.activeID {
                tabs.close(active)
            } else {
                window?.performClose(nil)
            }
        case .reopenTab: tabs.reopenLast()
        case .nextTab: tabs.activateNext()
        case .previousTab: tabs.activatePrevious()
        case .selectTab1: tabs.activate(index: 0)
        case .selectTab2: tabs.activate(index: 1)
        case .selectTab3: tabs.activate(index: 2)
        case .selectTab4: tabs.activate(index: 3)
        case .selectTab5: tabs.activate(index: 4)
        case .selectTab6: tabs.activate(index: 5)
        case .selectTab7: tabs.activate(index: 6)
        case .selectTab8: tabs.activate(index: 7)
        case .selectTab9: tabs.activate(index: 8)
        case .openSwitcher, .openSwitcherFromPage:
            // shortcut: a blank tab stands in for the switcher, replace this when the switcher exists
            tabs.newTab(nil, activate: true)
            perform(.focusAddress)
        case .newWindow:
            break // shortcut: there's one window for now, open another here when AppController manages several
        case .toggleRail:
            railState.toggleShortcut()
            if railState.visibility == .hidden {
                window?.makeFirstResponder(tab?.webView)
            }
            applyRailState()
        case .focusAddress:
            railState.beginEditingAddress()
            applyRailState()
            rail.addressField.selectText(nil)
        case .toggleInspector:
            guard let webView = tab?.webView else { return }
            let opened = PrivateAPI.isInspectorVisible(webView)
                ? PrivateAPI.closeInspector(webView)
                : PrivateAPI.showInspector(webView)
            reportInspector(available: opened)
        case .showConsole:
            guard let webView = tab?.webView else { return }
            reportInspector(available: PrivateAPI.showConsole(webView))
        case .showPageSource:
            guard let webView = tab?.webView else { return }
            reportInspector(available: PrivateAPI.showPageSource(webView))
        case .openInSafari:
            openInSafari()
        case .signIn:
            showSignInPopover()
        }
    }

    /// Popovers anchor to the rail, so it has to be in place before one opens.
    func revealRailImmediately() {
        railState.pointerDwelledAtEdge()
        applyRailState(animated: false)
        contentView.layoutSubtreeIfNeeded()
    }

    func applyRailState(animated: Bool = true) {
        let isVisible = railState.visibility != .hidden
        setWindowButtonsVisible(isVisible)
        applyPageStyle()

        if isVisible {
            rail.isHidden = false
        }
        let leading = isVisible ? Rail.inset : -(Rail.width + Rail.inset)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            railLeading?.constant = leading
            rail.isHidden = !isVisible
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.17
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            railLeading?.animator().constant = leading
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

        backdrop.wantsLayer = true
        backdrop.frame = contentView.bounds
        backdrop.autoresizingMask = [.width, .height]
        contentView.addSubview(backdrop)

        topStrip.frame = NSRect(
            x: 0,
            y: contentView.bounds.height - TopDragStrip.height,
            width: contentView.bounds.width,
            height: TopDragStrip.height
        )
        topStrip.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(topStrip)

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
                tab?.load(input)
            }
            window?.makeFirstResponder(tab?.webView)
        }
        rail.onCancel = { [weak self] in
            guard let self else { return }
            updateRailContents()
            window?.makeFirstResponder(tab?.webView)
        }
    }

    private func connectTabs() {
        rail.tabList.onSelect = { [weak self] in self?.tabs.activate($0) }
        rail.tabList.onClose = { [weak self] in self?.tabs.close($0) }
        rail.tabList.onMove = { [weak self] in self?.tabs.move(from: $0, to: $1) }
        rail.tabList.onNewTab = { [weak self] in self?.perform(.openSwitcher) }
        tabs.onChange = { [weak self] in self?.updateRailContents() }
        tabs.onActiveChange = { [weak self] in
            guard let self else { return }
            showActiveTab()
            if tabs.isEmpty {
                window?.performClose(nil)
            }
        }
    }

    /// Puts the active page under the top strip. `TabManager` detaches the tabs it steps down, so the page
    /// being replaced is only still here if it's capturing. Clear, not hidden, because hidden pages stop running.
    private func showActiveTab() {
        openPopover?.close()
        openPopover = nil
        shownPage?.alphaValue = 0
        shownPage = tab?.pageView
        if let tab {
            tab.pageView.alphaValue = 1
            tab.pageView.frame = contentView.bounds
            contentView.addSubview(tab.pageView, positioned: .below, relativeTo: topStrip)
            window?.makeFirstResponder(tab.webView)
        }
        applyPageStyle()
        updateRailContents()
    }

    private func applyPageStyle() {
        guard let webView = tab?.webView else { return }
        webView.alphaValue = appearance.effective.pageAlpha
        webView.obscuredContentInsets.left = railState.visibility == .pinned ? Rail.width + 2 * Rail.inset : 0
    }

    private func updateRailContents() {
        let webView = tab?.webView
        rail.update(url: webView?.url, canGoBack: webView?.canGoBack ?? false, canGoForward: webView?.canGoForward ?? false)
        rail.tabList.update(records: tabs.list.records, activeID: tabs.list.activeID)
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
        guard let url = tab?.safariURL else { return }
        guard let safari = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari") else { return }
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: safari,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func showAppearancePopover() {
        showPopover(AppearancePopover(model: appearance), from: rail.settingsButton)
    }

    private func showSignInPopover() {
        guard let webView = tab?.webView else { return }
        revealRailImmediately()
        let host = webView.url?.host() ?? "this site"
        let popover = SignInPopover(host: host) { [weak self] username, password in
            self?.fillLogin(webView, username: username, password: password)
        }
        showPopover(popover, from: rail.addressField)
    }

    private func fillLogin(_ webView: WKWebView, username: String, password: String) {
        openPopover?.close()
        Task { [weak self] in
            guard let self else { return }
            let filled = (try? await LoginFiller.fill(webView, username: username, password: password)) ?? false
            if !filled {
                let alert = NSAlert()
                alert.messageText = "No sign-in form was found on this page."
                alert.present(in: window) { _ in }
            }
        }
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
        if notification.object as? NSPopover === openPopover {
            openPopover = nil
        }
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
        contentView.addSubview(blurView, positioned: .above, relativeTo: backdrop)
        fallbackBlurView = blurView
        usesFallbackBlur = true
    }
}
