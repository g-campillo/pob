import AppKit
import SwiftUI

/// The app's one Settings window. Closing it only hides it, so it comes back as it was.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let content = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: content)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(content.view.fittingSize) // the hosted view has no size of its own until it's on screen
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Ends any edit, so a name being typed is kept.
    func windowWillClose(_ notification: Notification) {
        window?.makeFirstResponder(nil)
    }
}
