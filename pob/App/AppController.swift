import AppKit

@main
final class AppController: NSObject, NSApplicationDelegate {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private(set) var windows: [WindowController] = []
    /// The list, `profile` and `appearance` are set at launch, past the test-host check, so a test run can't reach the
    /// real profiles. Tests set their own.
    var profiles: ProfileList?
    /// Where a window opens when nothing says otherwise: the first listed profile.
    var profile: Profile?
    var appearance: AppearanceModel?
    /// Replaceable so a test gets temporary profiles and never the real folder.
    var makeProfile: (UUID) -> Profile = { Profile.persistent(id: $0) }
    /// Replaceable so a test can't change the Mac's default browser.
    var requestDefault: (String) async throws -> Void = {
        try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: $0)
    }
    /// Links that arrive before the session is back wait here, so a restored window isn't replaced.
    private var pendingLinks: [AddressInput] = []
    private var hasRestored = false
    /// Every profile that has had a window, in the order they first did.
    private var preparedProfiles: [Profile] = []
    private var commands: CommandList?
    private var keyMonitor: Any?
    private var displayOptionsObserver: NSObjectProtocol?
    private var phaseTimer: Timer?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    /// A sheet, a popover or a detached inspector in front keeps its keys.
    private var isBrowserWindowKey: Bool {
        controller(of: NSApp.keyWindow) != nil
    }

    /// The window that shows the pill notice. A download's answer runs while its sheet is still the key window.
    func noticeController(keyWindow: NSWindow?) -> WindowController? {
        controller(of: keyWindow?.sheetParent ?? keyWindow)
    }

    private var isShowingAWindow: Bool {
        windows.contains { $0.window?.isVisible == true }
    }

    /// Reads every live page's state, so it's built when a save happens and not on every change.
    func sessionSnapshot(of profile: Profile) -> SessionSnapshot {
        SessionSnapshot(windows: windows.filter { $0.tabs.profile === profile }.compactMap(\.snapshot), parked: profile.parked)
    }

    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        // Stage 3 moved the rules to pob/rules, shared by every profile.
        try? FileManager.default.removeItem(at: Profile.initial.directory.appending(path: "rules"))
        let profiles = ProfileList(file: JSONFile(url: ProfileList.defaultFileURL))
        self.profiles = profiles
        profile = makeProfile(profiles.all[0].id)
        prepareFilterLists()

        let appearance = AppearanceModel(
            store: SettingsStore(fileURL: SettingsStore.defaultFileURL),
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        self.appearance = appearance
        observeDisplayOptions(appearance)

        let commands = CommandList.standard { [weak self] in self?.perform($0, keyWindow: NSApp.keyWindow) }
        self.commands = commands
        let menu = MainMenu.build(commands: commands)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.item(withTitle: "Window")?.submenu
        installReservedShortcuts()
        watchTabPhases()
        restoreSession()
    }

    /// A test run has no windows, so saving here would blank the real session.
    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        saveAllSessions()
    }

    /// Returns with every session on disk, so it's safe to call at quit. A private window is never saved.
    func saveAllSessions() {
        for profile in preparedProfiles where !profile.isPrivate {
            profile.session.save(sessionSnapshot(of: profile))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// AppKit brings back a minimized window when this returns true, so only having none at all needs a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if windows.isEmpty {
            openWindow(restoring: nil)
        }
        return true
    }

    /// Opens every profile's saved windows, or one empty window when there are none, as after a session that failed to load.
    func restoreSession() {
        for info in profiles?.all ?? [] {
            let profile = makeProfile(info.id)
            profile.session.restore { session in
                profile.parked = session.parked
                for window in session.windows {
                    openWindow(restoring: window, in: profile)
                }
            }
        }
        if windows.isEmpty, pendingLinks.isEmpty {
            openWindow(restoring: nil)
        }
        hasRestored = true
        let links = pendingLinks
        pendingLinks = []
        open(links, keyWindow: nil)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls.compactMap(IncomingLink.address(for:)), keyWindow: NSApp.keyWindow)
    }

    func open(_ urls: [URL], keyWindow: NSWindow?) {
        open(urls.compactMap(IncomingLink.address(for:)), keyWindow: keyWindow)
    }

    /// The key browser window, else the front one, else the last opened (hosted windows aren't ordered), else a new one.
    private func open(_ links: [AddressInput], keyWindow: NSWindow?) {
        guard !links.isEmpty else { return }
        guard hasRestored else {
            pendingLinks += links
            return
        }
        if windows.isEmpty { openWindow(restoring: nil) }
        let target = controller(of: keyWindow) ?? NSApp.orderedWindows.lazy.compactMap(controller(of:)).first ?? windows.last
        guard let target else { return }
        links.forEach(target.openLink)
        if !Self.isRunningTests {
            target.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    /// macOS asks the user to confirm each scheme itself, and this works with no window open.
    func makeDefaultBrowser(keyWindow: NSWindow?) async {
        do {
            for scheme in ["http", "https"] {
                try await requestDefault(scheme)
            }
        } catch {
            let alert = NSAlert(error: error)
            if let keyWindow {
                await alert.beginSheetModal(for: keyWindow)
            } else {
                alert.runModal()
            }
        }
    }

    /// A window opened from another steps away from it. Exactly on top, it would look as if nothing had happened.
    func openWindow(restoring snapshot: WindowSnapshot?, in profile: Profile? = nil, cascadingFrom parent: NSWindow? = nil) {
        guard let profile = profile ?? self.profile, let appearance else { return }
        prepare(profile)
        let controller = WindowController(appearance: appearance, tabs: TabManager(profile: profile, restoring: snapshot))
        if let snapshot, snapshot.hasFiniteFrame {
            controller.window?.setFrame(from: snapshot.frame)
        }
        if let parent, let window = controller.window {
            let stepped = window.cascadeTopLeft(from: NSPoint(x: parent.frame.minX, y: parent.frame.maxY))
            window.cascadeTopLeft(from: stepped)
        }
        controller.onTabsChanged = { [weak self] in self?.saveSessionSoon(profile) }
        controller.onNewWindow = { [weak self, weak controller] in
            self?.openWindow(restoring: nil, in: profile, cascadingFrom: controller?.window)
        }
        controller.onNewPrivateWindow = { [weak self, weak controller] in
            self?.openWindow(restoring: nil, in: .makePrivate(from: profile), cascadingFrom: controller?.window)
        }
        controller.onMakeDefaultBrowser = { [weak self, weak controller] in
            guard let self else { return }
            Task { await self.makeDefaultBrowser(keyWindow: controller?.window) }
        }
        controller.onClose = { [weak self, weak controller] in
            guard let self else { return }
            windows.removeAll { $0 === controller }
            saveSessionSoon(profile)
            if profile.isPrivate, !windows.contains(where: { $0.tabs.profile === profile }) {
                try? FileManager.default.removeItem(at: profile.directory)
                preparedProfiles.removeAll { $0 === profile }
                profile.dropSpareTab() // with its cookies, which are in memory only
            }
        }
        if let name = profiles?.name(of: profile.id) {
            controller.showProfile(name: name)
        }
        windows.append(controller)

        if !Self.isRunningTests { // hosted windows stay off screen
            controller.showWindow(nil)
            NSApp.activate()
        }
        if controller.tabs.isEmpty {
            controller.perform(.openSwitcher)
        }
        Task { profile.prepareSpareTab() } // no launch tab asked for one, and the first Return shouldn't wait
    }

    /// Commands act on the key window. Anything else that's key keeps its keys, so "no window" means nothing is key
    /// and no browser window is showing. A minimized one doesn't count, or ⌘N would do nothing.
    func perform(_ id: CommandID, keyWindow: NSWindow?) {
        if id == .makeDefaultBrowser {
            Task { await makeDefaultBrowser(keyWindow: keyWindow) }
        } else if let controller = controller(of: keyWindow) {
            controller.perform(id)
        } else if keyWindow == nil, !isShowingAWindow, [.openSwitcher, .openSwitcherFromPage, .newWindow, .newPrivateWindow].contains(id) {
            openWindow(restoring: nil, in: id == .newPrivateWindow ? profile.map(Profile.makePrivate(from:)) : nil)
        }
    }

    private func controller(of window: NSWindow?) -> WindowController? {
        windows.first { $0.window === window }
    }

    /// Holds `self` until the save runs, because a snapshot taken after it was gone would be empty.
    private func saveSessionSoon(_ profile: Profile) {
        guard !profile.isPrivate else { return }
        profile.session.saveSoon { self.sessionSnapshot(of: profile) }
    }

    /// Once per profile, with its first window.
    private func prepare(_ profile: Profile) {
        guard !preparedProfiles.contains(where: { $0 === profile }) else { return }
        preparedProfiles.append(profile)
        // Every window shares the profile's downloads, so only the key window shows the notice.
        profile.downloads.onStart = { [weak self] name in
            self?.noticeController(keyWindow: NSApp.keyWindow)?.showNotice(name)
        }
        // A background tab or a closed popup has no window of its own to ask in.
        profile.downloads.frontWindow = { [weak self] in
            guard let self else { return nil }
            return (controller(of: NSApp.keyWindow) ?? NSApp.orderedWindows.lazy.compactMap(controller(of:)).first)?.window
        }
        if !profile.isPrivate { // it keeps no history
            Task { await profile.history.prune(before: Date().addingTimeInterval(-365 * 86_400)) }
        }
    }

    private func observeDisplayOptions(_ appearance: AppearanceModel) {
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak appearance] _ in
            MainActor.assumeIsolated {
                appearance?.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            }
        }
    }

    /// Reserved shortcuts run here, before WebKit offers the key to the page.
    private func installReservedShortcuts() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, isBrowserWindowKey, commands?.performReserved(event) == true else { return event }
            return nil
        }
    }

    /// Both handlers run on the main thread: the timer on the run loop it was scheduled from, the source on `.main`.
    private func watchTabPhases() {
        phaseTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateTabPhases(now: .now, memoryPressure: false)
                self?.refreshFilterLists(now: .now)
            }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.updateTabPhases(now: .now, memoryPressure: true) }
        }
        source.activate()
        memoryPressureSource = source
    }

    /// Nothing waits for this. Pages load without rules until it lands.
    func prepareFilterLists() {
        guard let blocker = profile?.contentBlocker else { return }
        Task(priority: .utility) {
            await blocker.prepare()
            await blocker.refreshIfStale(now: .now)
        }
    }

    /// pob can stay open for weeks, so launch alone isn't enough.
    func refreshFilterLists(now: Date) {
        guard let blocker = profile?.contentBlocker else { return }
        Task(priority: .utility) { await blocker.refreshIfStale(now: now) }
    }

    func updateTabPhases(now: Date, memoryPressure: Bool) {
        for controller in windows {
            controller.tabs.updatePhases(now: now, memoryPressure: memoryPressure)
        }
    }
}
