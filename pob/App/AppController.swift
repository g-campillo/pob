import AppKit

@main
final class AppController: NSObject, NSApplicationDelegate {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private var appearance: AppearanceModel?
    private var windowController: WindowController?
    private var commands: CommandList?
    private var keyMonitor: Any?
    private var displayOptionsObserver: NSObjectProtocol?
    private var phaseTimer: Timer?
    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    /// A sheet or a detached inspector in front keeps its keys.
    private var isBrowserWindowKey: Bool {
        NSApp.keyWindow === windowController?.window
    }

    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        let appearance = AppearanceModel(
            store: SettingsStore(fileURL: SettingsStore.defaultFileURL),
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        )
        self.appearance = appearance
        observeDisplayOptions(appearance)

        let tabs = TabManager(profile: .initial)
        tabs.newTab(.url(URL(string: "about:blank")!), activate: true)
        let windowController = WindowController(appearance: appearance, tabs: tabs)
        self.windowController = windowController

        let commands = CommandList.standard { [weak self] id in
            guard let self, isBrowserWindowKey else { return }
            self.windowController?.perform(id)
        }
        self.commands = commands
        let menu = MainMenu.build(commands: commands)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.item(withTitle: "Window")?.submenu
        installReservedShortcuts()
        watchTabPhases()

        windowController.showWindow(nil)
        NSApp.activate()
        windowController.perform(.focusAddress)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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
            guard let self, isBrowserWindowKey, let command = commands?.reservedCommand(for: event) else { return event }
            command.perform()
            return nil
        }
    }

    /// Both handlers run on the main thread: the timer on the run loop it was scheduled from, the source on `.main`.
    private func watchTabPhases() {
        phaseTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateTabPhases(memoryPressure: false) }
        }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.updateTabPhases(memoryPressure: true) }
        }
        source.activate()
        memoryPressureSource = source
    }

    private func updateTabPhases(memoryPressure: Bool) {
        windowController?.tabs.updatePhases(now: .now, memoryPressure: memoryPressure)
    }
}
