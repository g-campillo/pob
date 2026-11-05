import AppKit

@main
final class AppController: NSObject, NSApplicationDelegate {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private(set) var windows: [WindowController] = []
    /// Both are set at launch, past the test-host check, so a test run can't reach the real profile. Tests set their own.
    var profile: Profile?
    var appearance: AppearanceModel?
    private var commands: CommandList?
    private var keyMonitor: Any?
    private var displayOptionsObserver: NSObjectProtocol?
    private var phaseTimer: Timer?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    /// A sheet, a popover or a detached inspector in front keeps its keys.
    private var isBrowserWindowKey: Bool {
        controller(of: NSApp.keyWindow) != nil
    }

    private var isShowingAWindow: Bool {
        windows.contains { $0.window?.isVisible == true }
    }

    /// Reads every live page's state, so it's built when a save happens and not on every change.
    var sessionSnapshot: SessionSnapshot {
        SessionSnapshot(windows: windows.compactMap(\.snapshot))
    }

    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        profile = .initial
        // Every window shares the profile's downloads, so only the key window shows the notice.
        Profile.initial.downloads.onStart = { [weak self] name in
            self?.controller(of: NSApp.keyWindow)?.showNotice(name)
        }
        Task { await Profile.initial.history.prune(before: Date().addingTimeInterval(-365 * 86_400)) }

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
        profile?.session.save(sessionSnapshot)
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

    /// Opens the saved windows, or one empty window when there are none, as after a session that failed to load.
    func restoreSession() {
        profile?.session.restore { session in
            for window in session.windows {
                openWindow(restoring: window)
            }
            if windows.isEmpty {
                openWindow(restoring: nil)
            }
        }
    }

    /// A window opened from another steps away from it. Exactly on top, it would look as if nothing had happened.
    func openWindow(restoring snapshot: WindowSnapshot?, cascadingFrom parent: NSWindow? = nil) {
        guard let profile, let appearance else { return }
        let controller = WindowController(appearance: appearance, tabs: TabManager(profile: profile, restoring: snapshot))
        if let snapshot, snapshot.hasFiniteFrame {
            controller.window?.setFrame(from: snapshot.frame)
        }
        if let parent, let window = controller.window {
            let stepped = window.cascadeTopLeft(from: NSPoint(x: parent.frame.minX, y: parent.frame.maxY))
            window.cascadeTopLeft(from: stepped)
        }
        controller.onTabsChanged = { [weak self] in self?.saveSessionSoon() }
        controller.onNewWindow = { [weak self, weak controller] in self?.openWindow(restoring: nil, cascadingFrom: controller?.window) }
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
            self?.saveSessionSoon()
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
        if let controller = controller(of: keyWindow) {
            controller.perform(id)
        } else if keyWindow == nil, !isShowingAWindow, [.openSwitcher, .openSwitcherFromPage, .newWindow].contains(id) {
            openWindow(restoring: nil)
        }
    }

    private func controller(of window: NSWindow?) -> WindowController? {
        windows.first { $0.window === window }
    }

    /// Holds `self` until the save runs, because a snapshot taken after it was gone would be empty.
    private func saveSessionSoon() {
        profile?.session.saveSoon { self.sessionSnapshot }
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
            MainActor.assumeIsolated { self?.updateTabPhases(now: .now, memoryPressure: false) }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.updateTabPhases(now: .now, memoryPressure: true) }
        }
        source.activate()
        memoryPressureSource = source
    }

    func updateTabPhases(now: Date, memoryPressure: Bool) {
        for controller in windows {
            controller.tabs.updatePhases(now: now, memoryPressure: memoryPressure)
        }
    }
}
