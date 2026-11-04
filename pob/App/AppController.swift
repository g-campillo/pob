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

        let tab = Tab(profile: .initial)
        let windowController = WindowController(appearance: appearance, tab: tab)
        self.windowController = windowController
        tab.load(.url(URL(string: "about:blank")!))

        let commands = CommandList.standard { [weak self] in self?.windowController?.perform($0) }
        self.commands = commands
        let menu = MainMenu.build(commands: commands)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.item(withTitle: "Window")?.submenu
        installReservedShortcuts()

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
            let modifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard let key = event.charactersIgnoringModifiers?.lowercased(),
                  let command = self?.commands?.reservedCommand(key: key, modifiers: modifiers)
            else { return event }
            command.perform()
            return nil
        }
    }
}
