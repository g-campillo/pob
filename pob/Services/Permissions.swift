import AppKit
import WebKit

enum Permissions {
    static func promptText(host: String, type: WKMediaCaptureType) -> String {
        "Allow \(host) to use your \(deviceName(for: type))?"
    }

    static func ask(
        host: String,
        type: WKMediaCaptureType,
        in window: NSWindow?,
        decision: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = promptText(host: host, type: type)
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        alert.present(in: window) { response in
            decision(response == .alertFirstButtonReturn ? .grant : .deny)
        }
    }

    private static func deviceName(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: "camera"
        case .microphone: "microphone"
        case .cameraAndMicrophone: "camera and microphone"
        @unknown default: "camera and microphone"
        }
    }
}

extension NSAlert {
    /// Shows a sheet. A page with no window is in a background tab, and a dialog from it would
    /// cover the active page with nothing to say which tab asked, so it's cancelled unseen.
    func present(in window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(.cancel)
        }
    }
}
