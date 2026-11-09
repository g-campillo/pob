import AppKit
import UniformTypeIdentifiers
import WebKit

final class WindowController: NSWindowController, NSPopoverDelegate, NSWindowDelegate {
    let tabs: TabManager
    var tab: Tab? { tabs.activeTab }
    let rail = Rail()
    let switcher = SwitcherView()
    let backdrop = BackdropView()
    let pill = DomainPill()
    let findBar = FindBar()
    let loadingLine = LoadingLine()
    private(set) var usesFallbackBlur = false
    private(set) var railState = RailState()
    /// Replaceable because tests need history to answer late.
    var searchHistory: (String) async -> [HistoryEntry]
    var onTabsChanged: (() -> Void)?
    var onClose: (() -> Void)?
    /// `AppController` owns the windows, and the switcher's New Window row starts here.
    var onNewWindow: (() -> Void)?
    var onNewPrivateWindow: (() -> Void)?
    var onMakeDefaultBrowser: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var profileChoices: () -> [ProfileInfo] = { [] }
    var onSwitchProfile: ((UUID) -> Void)?

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
    private var historySearch: Task<Void, Never>?
    private var shownHistory: [HistoryEntry] = []
    private lazy var commands = CommandList.standard { [weak self] in self?.perform($0) }

    init(appearance: AppearanceModel, tabs: TabManager) {
        self.appearance = appearance
        self.tabs = tabs
        searchHistory = { [profile = tabs.profile] query in
            guard !profile.isPrivate else { return [] } // a private window offers no history, not even its parent's
            return await profile.history.search(query, limit: SwitcherModel.historySearchLimit)
        }

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
        window.delegate = self

        buildContent(in: window)
        connectRail()
        connectTabs()
        connectSwitcher()
        connectFindBar()
        setWindowButtonsVisible(false)
        appearance.addObserver { [weak self] in self?.applyAppearance() }
        tabs.profile.bookmarks.addObserver { [weak self] in self?.updateRailContents() }
        if tabs.profile.isPrivate { // it isn't in the profile list, so nothing else names it
            showProfile(name: "Private")
        }
        showActiveTab()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// nil for a window with no tabs, which leaves nothing to bring back.
    var snapshot: WindowSnapshot? {
        guard let window, !tabs.isEmpty else { return nil }
        let records = tabs.snapshotRecords
        return WindowSnapshot(
            tabs: records,
            activeIndex: records.firstIndex { $0.id == tabs.list.activeID } ?? 0,
            frame: window.frameDescriptor
        )
    }

    func showProfile(name: String) {
        rail.update(profileName: name, isPrivate: tabs.profile.isPrivate)
    }

    /// What the rail's profile button pops up. A private window has no other profile to go to, but can manage its parent.
    func profileMenu() -> NSMenu {
        let menu = NSMenu()
        if !tabs.profile.isPrivate {
            for info in profileChoices() {
                let item = NSMenuItem(title: info.name, action: #selector(profileChosen(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = info.id
                item.state = info.id == tabs.profile.id ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        if let command = commands.command(.newPrivateWindow) {
            menu.addItem(MainMenu.menuItem(for: command))
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage Profiles…", action: #selector(manageProfiles), keyEquivalent: "")
        manage.target = self
        menu.addItem(manage)
        return menu
    }

    @objc private func manageProfiles() {
        onOpenSettings?()
    }

    @objc private func profileChosen(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID {
            onSwitchProfile?(id)
        }
    }

    private func showProfileMenu() {
        let button = rail.profileButton
        profileMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: button.isFlipped ? button.bounds.maxY : 0), in: button)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

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

    /// Replaceable so a test can't open System Settings.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Replaceable because tests can't show a sheet. Nil means cancelled.
    var chooseImportFile: @MainActor (NSWindow?) async -> URL? = { window in
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a bookmarks file exported from Safari or Chrome"
        guard let window else { return panel.runModal() == .OK ? panel.url : nil }
        return await panel.beginSheetModal(for: window) == .OK ? panel.url : nil
    }
    /// The import in progress, for tests to wait on.
    private(set) var importTask: Task<Void, Never>?

    private func importBookmarks() {
        guard importTask == nil else { return }
        importTask = Task { [weak self] in
            defer { self?.importTask = nil }
            guard let self, let file = await chooseImportFile(window) else { return }
            guard let text = Self.readImportFile(file) else {
                let alert = NSAlert()
                alert.messageText = "Couldn't read that file"
                alert.informativeText = "Choose a bookmarks file under 50 MB exported from Safari or Chrome."
                if let window { await alert.beginSheetModal(for: window) } else { alert.runModal() }
                return
            }
            let items = BookmarkImport.parse(text)
            let added = tabs.profile.bookmarks.importBookmarks(items)
            showNotice(items.isEmpty ? "No bookmarks found" : added == 0 ? "No new bookmarks" : "Imported \(added) bookmark\(added == 1 ? "" : "s")")
        }
    }

    private static func readImportFile(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 50_000_000,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    func perform(_ id: CommandID) {
        if !switcher.isHidden, id != .openSwitcher, id != .openSwitcherFromPage {
            // Commands act on the window, and several of them move the keyboard, so the panel can't stay up over them.
            closeSwitcher()
            // ⌘T says New Tab, so ⌘T then ⌘W means "never mind", not "close the page behind it". With no page, it closes the window.
            if id == .closeTab, !tabs.isEmpty { return }
        }
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
            hideFindBar()
            openSwitcher()
        case .find:
            guard tab != nil else { return }
            findBar.isHidden = false
            findBar.focus()
        case .print: tab?.printPage()
        case .zoomIn: tab?.zoomIn()
        case .zoomOut: tab?.zoomOut()
        case .actualSize: tab?.actualSize()
        case .newWindow: onNewWindow?()
        case .newPrivateWindow: onNewPrivateWindow?()
        case .makeDefaultBrowser: onMakeDefaultBrowser?() // the switcher and the address bar reach it from here
        case .openSettings: onOpenSettings?()
        case .screenRecordingSettings: openURL(Permissions.screenRecordingSettingsURL)
        case .resetSitePermissions:
            guard let tab, let host = tab.webView.url?.host() else { return }
            Permissions.forget(host: host, in: tab.profile.siteSettings)
            tab.webView.reload()
        case .toggleSiteBlocking:
            guard let tab, let host = tab.webView.url?.host() else { return }
            let settings = tab.profile.siteSettings
            settings[host].adBlockerOff = settings[host].adBlockerOff == true ? nil : true // on is the default, so it leaves no entry
            tab.webView.reload()
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
        case .importBookmarks: importBookmarks()
        case .bookmarkPage:
            guard let webView = tab?.webView, let url = webView.url, url.scheme != "about" else { return }
            tabs.profile.bookmarks.toggle(url: url, title: webView.title?.isEmpty == false ? webView.title! : url.host() ?? url.absoluteString)
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
        switcher.pageInset = isVisible ? Rail.footprint : 0
        pill.isSuppressed = isVisible

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

        loadingLine.frame = NSRect(
            x: 0,
            y: contentView.bounds.height - LoadingLine.height,
            width: contentView.bounds.width,
            height: LoadingLine.height
        )
        loadingLine.autoresizingMask = [.width, .minYMargin]
        contentView.addSubview(loadingLine)

        pill.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            pill.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            pill.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.6),
        ])

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

        findBar.translatesAutoresizingMaskIntoConstraints = false
        findBar.isHidden = true
        contentView.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: TopDragStrip.height + 10),
            findBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            findBar.widthAnchor.constraint(equalToConstant: FindBar.width),
            findBar.heightAnchor.constraint(equalToConstant: FindBar.height),
        ])

        switcher.frame = contentView.bounds
        switcher.autoresizingMask = [.width, .height]
        switcher.isHidden = true
        contentView.addSubview(switcher)
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
        rail.onDownloads = { [weak self] in self?.showDownloadsPopover() }
        rail.onProfile = { [weak self] in self?.showProfileMenu() }
        rail.onAddressFocus = { [weak self] in
            guard let self else { return }
            railState.beginEditingAddress()
            applyRailState()
        }
        rail.onAddressChange = { [weak self] text in
            self?.suggest(text) { rows in
                // Blank text matches every open tab, and the tab list already shows those.
                self?.rail.showSuggestions(AddressInput.classify(text) == nil ? [] : rows)
            }
        }
        rail.onAddressEndEditing = { [weak self] in
            guard let self else { return }
            historySearch?.cancel()
            rail.showSuggestions([])
            railState.endEditingAddress(pointerInsideRail: isPointerOverRail)
            applyRailState()
        }
        rail.onSubmit = { [weak self] text in
            guard let self else { return }
            if let input = AddressInput.classify(text, engine: appearance.searchEngine) {
                navigate(input)
            }
            leaveAddressField()
        }
        rail.onCancel = { [weak self] in self?.leaveAddressField() }
        rail.suggestions.onChoose = { [weak self] in self?.chooseSuggestion($0) }
    }

    /// The rail leaves a field being edited alone, so the address can only come back once the keyboard has moved.
    private func leaveAddressField() {
        window?.makeFirstResponder(tab?.webView)
        updateRailContents()
    }

    /// Loads in the current tab, or in a new one when the window has none.
    private func navigate(_ input: AddressInput) {
        if let tab {
            tab.load(input)
        } else {
            tabs.newTab(input, activate: true)
        }
    }

    private func chooseSuggestion(_ row: SwitcherRow) {
        leaveAddressField()
        switch row.target {
        case .tab(let id):
            if let url = tabs.list.records.first(where: { $0.id == id })?.url {
                navigate(.url(url))
            }
        case .url(let url): navigate(.url(url))
        case .address(let input): navigate(input)
        case .command(let id): commands.command(id)?.perform()
        }
    }

    /// A bookmark opens in the current tab, or in a new one when the window has none.
    func openBookmark(_ bookmark: Bookmark) {
        navigate(.url(bookmark.url))
    }

    private func connectSwitcher() {
        switcher.onChoose = { [weak self] in self?.chooseInSwitcher($0) }
        switcher.onCancel = { [weak self] in self?.closeSwitcher() }
        switcher.onQueryChange = { [weak self] in self?.searchInSwitcher($0) }
    }

    private func connectFindBar() {
        findBar.onSearch = { [weak self] text, backwards in
            guard let tab = self?.tab else { return }
            Task { [weak self] in
                let found = await tab.find(text, backwards: backwards)
                if tab === self?.tab { self?.findBar.showResult(found: found) }
            }
        }
        findBar.onClose = { [weak self] in
            self?.hideFindBar()
            self?.window?.makeFirstResponder(self?.tab?.webView)
        }
    }

    private func hideFindBar() {
        findBar.isHidden = true
        findBar.showResult(found: true)
    }

    private func openSwitcher() {
        guard switcher.isHidden else {
            switcher.focus()
            return
        }
        switcher.open()
        searchInSwitcher("")
    }

    /// A link from outside opens as the active tab, and the switcher a fresh window opens with has no business over it.
    func openLink(_ input: AddressInput) {
        if !switcher.isHidden { closeSwitcher() }
        tabs.newTab(input, activate: true)
    }

    private func closeSwitcher() {
        window?.makeFirstResponder(tab?.webView)
        switcher.isHidden = true
    }

    private func chooseInSwitcher(_ row: SwitcherRow) {
        closeSwitcher()
        switch row.target {
        case .tab(let id): tabs.activate(id)
        case .url(let url): tabs.newTab(.url(url), activate: true)
        case .address(let input): tabs.newTab(input, activate: true)
        case .command(let id): commands.command(id)?.perform()
        }
    }

    private func searchInSwitcher(_ query: String) {
        suggest(query) { [weak self] in self?.switcher.show(rows: $0) }
    }

    /// Everything but history shows at once. History the last answer found stays while it still matches, so the list
    /// holds still between keys, until the next answer replaces it. Each search cancels the one before, so a late
    /// answer for old text is dropped.
    private func suggest(_ query: String, show: @escaping ([SwitcherRow]) -> Void) {
        historySearch?.cancel()
        shownHistory = SwitcherModel.stillMatching(shownHistory, query: query)
        show(rows(for: query, history: shownHistory))
        historySearch = Task { [weak self, searchHistory] in
            let history = await searchHistory(query)
            guard !Task.isCancelled, let self, history != shownHistory else { return }
            shownHistory = history
            show(rows(for: query, history: history))
        }
    }

    private func rows(for query: String, history: [HistoryEntry]) -> [SwitcherRow] {
        SwitcherModel.rows(query: query, tabs: tabs.list.records, bookmarks: tabs.profile.bookmarks.all, history: history, commands: commands.all, engine: appearance.searchEngine)
    }

    private func connectTabs() {
        let bookmarks = tabs.profile.bookmarks
        rail.pinned.onOpen = { [weak self] in self?.openBookmark($0) }
        rail.pinned.onUnpin = { bookmarks.setPinned(false, id: $0) }
        rail.pinned.onRemove = { bookmarks.remove(id: $0) }
        rail.tabList.favicons = tabs.profile.favicons
        rail.tabList.onSelect = { [weak self] in self?.tabs.activate($0) }
        rail.tabList.onClose = { [weak self] in self?.tabs.close($0) }
        rail.tabList.onMove = { [weak self] in self?.tabs.move(from: $0, to: $1) }
        rail.tabList.onNewTab = { [weak self] in self?.perform(.openSwitcher) }
        tabs.onChange = { [weak self] in
            self?.updateRailContents()
            self?.onTabsChanged?()
        }
        tabs.onLoadFinished = { [weak self] finished in
            guard let self, finished === tab else { return }
            pill.show(url: finished.webView.url)
        }
        tabs.onActiveProgress = { [weak self] in self?.loadingLine.update(progress: $0, isLoading: $1) }
        tabs.onActiveChange = { [weak self] in
            guard let self else { return }
            showActiveTab()
            if tabs.isEmpty { // the window owns what ⇧⌘T brings back, so it stays, and the next ⌘W closes it
                perform(.openSwitcher)
            }
        }
    }

    /// Puts the active page under the top strip. `TabManager` detaches the tabs it steps down, so the page
    /// being replaced is only still here if it's capturing. Clear, not hidden, because hidden pages stop running.
    private func showActiveTab() {
        openPopover?.close()
        openPopover = nil
        hideFindBar()
        shownPage?.alphaValue = 0
        shownPage = tab?.pageView
        if let tab {
            tab.pageView.alphaValue = 1
            tab.pageView.frame = contentView.bounds
            contentView.addSubview(tab.pageView, positioned: .below, relativeTo: topStrip)
            if switcher.isHidden { // a page coming forward behind the panel mustn't catch what's being typed
                window?.makeFirstResponder(tab.webView)
            }
        }
        applyPageStyle()
        updateRailContents()
        pill.show(url: tab?.webView.url)
        loadingLine.update(progress: tab?.webView.estimatedProgress ?? 0, isLoading: tab?.webView.isLoading ?? false)
    }

    private func applyPageStyle() {
        guard let webView = tab?.webView else { return }
        webView.alphaValue = appearance.effective.pageAlpha
        webView.obscuredContentInsets.left = railState.visibility == .pinned ? Rail.footprint : 0
    }

    private func updateRailContents() {
        let webView = tab?.webView
        rail.update(url: webView?.url, canGoBack: webView?.canGoBack ?? false, canGoForward: webView?.canGoForward ?? false)
        rail.update(pinned: tabs.profile.bookmarks.pinned, favicons: tabs.profile.favicons)
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
        let host = tab?.webView.url?.host()
        let popover = AppearancePopover(
            model: appearance,
            site: host,
            isBlocking: host.map { tab?.profile.siteSettings[$0].adBlockerOff != true } ?? true,
            onToggleBlocking: { [weak self] in self?.perform(.toggleSiteBlocking) },
            onOpenSettings: { [weak self] in
                self?.openPopover?.close()
                self?.onOpenSettings?()
            }
        )
        showPopover(popover, from: rail.settingsButton)
    }

    private func showDownloadsPopover() {
        let downloads = tabs.profile.downloads
        let popover = DownloadsPopover(downloads: downloads) { [weak self] id in
            guard let webView = self?.tab?.webView else { return } // no page to start it from
            downloads.retry(id, in: webView)
        }
        showPopover(popover, from: rail.downloadsButton)
    }

    /// A download's name, in the pill.
    func showNotice(_ text: String) {
        pill.showNotice(text)
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
