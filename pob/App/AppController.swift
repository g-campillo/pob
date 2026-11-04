import AppKit

@main
final class AppController: NSObject, NSApplicationDelegate {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static func main() {
        let application = NSApplication.shared
        let controller = AppController()
        application.delegate = controller
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
    }
}
