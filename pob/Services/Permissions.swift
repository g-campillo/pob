import AVFoundation
import AppKit
import CoreLocation
import WebKit

enum PermissionKind { case camera, microphone, location }

enum Permissions {
    static func promptText(host: String, type: WKMediaCaptureType) -> String {
        "Allow \(host) to use your \(deviceName(for: type))?"
    }

    static func promptText(host: String, kinds: [PermissionKind]) -> String {
        "Allow \(host) to use your \(kinds.map(name).joined(separator: " and "))?"
    }

    /// Shows an alert and reports its answer when the alert is finished.
    typealias Presenter = (NSAlert, @escaping @MainActor (NSApplication.ModalResponse) -> Void) -> Void

    /// Reports nil when the question went unanswered (no window), so a refusal that wasn't the user's isn't remembered.
    static func ask(text: String, present: Presenter, answer: @escaping @MainActor (Bool?) -> Void) {
        let alert = NSAlert()
        alert.messageText = text
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Don't Allow")
        present(alert) { response in
            switch response {
            case .alertFirstButtonReturn: answer(true)
            case .alertSecondButtonReturn: answer(false)
            default: answer(nil)
            }
        }
    }

    static func ask(
        host: String,
        type: WKMediaCaptureType,
        in window: NSWindow?,
        decision: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        ask(text: promptText(host: host, type: type), present: { $0.present(in: window, completion: $1) }) {
            decision($0 == true ? .grant : .deny)
        }
    }

    /// The whole flow: a remembered answer, then macOS's own switch, then the question.
    static func resolve(
        kinds: [PermissionKind],
        host: String,
        text: String,
        settings: SiteSettings,
        macOSAllows: (PermissionKind) -> Bool,
        present: @escaping Presenter,
        openSettings: @escaping @MainActor (URL) -> Void,
        decision: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        let known = remembered(kinds, host: host, in: settings)
        if known == false { return decision(.deny) }
        // The site never got a user's answer here, so nothing is stored.
        if let blocked = kinds.first(where: { !macOSAllows($0) }) {
            explainMacOSDenial(blocked, present: present, openSettings: openSettings)
            return decision(.deny)
        }
        if known == true { return decision(.grant) }
        ask(text: text, present: present) { answer in
            guard let answer else { return decision(.deny) }
            remember(answer, kinds: kinds, host: host, in: settings)
            decision(answer ? .grant : .deny)
        }
    }

    private static func explainMacOSDenial(_ kind: PermissionKind, present: Presenter, openSettings: @escaping @MainActor (URL) -> Void) {
        let alert = NSAlert()
        alert.messageText = "macOS has the \(name(kind)) turned off for pob"
        alert.informativeText = "Turn it on in System Settings, then try again."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            if response == .alertFirstButtonReturn { openSettings(settingsURL(for: kind)) }
        }
    }

    /// False when macOS has the device off for pob. Undetermined counts as allowed, because WebKit raises macOS's own prompt then.
    static func macOSAllows(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .camera: ![.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone: ![.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio))
        case .location: CLLocationManager.locationServicesEnabled() && ![.denied, .restricted].contains(CLLocationManager().authorizationStatus)
        }
    }

    static func kinds(for type: WKMediaCaptureType) -> [PermissionKind] {
        switch type {
        case .camera: [.camera]
        case .microphone: [.microphone]
        case .cameraAndMicrophone: [.camera, .microphone]
        @unknown default: [.camera, .microphone]
        }
    }

    /// nil until every kind is answered. One denial among them settles it.
    static func remembered(_ kinds: [PermissionKind], host: String, in settings: SiteSettings) -> Bool? {
        let answers = kinds.map { kind -> Bool? in
            let site = settings[host]
            switch kind {
            case .camera: return site.camera
            case .microphone: return site.microphone
            case .location: return site.location
            }
        }
        if answers.contains(where: { $0 == nil }) { return nil }
        return !answers.contains(false)
    }

    static func remember(_ allowed: Bool, kinds: [PermissionKind], host: String, in settings: SiteSettings) {
        var site = settings[host]
        for kind in kinds {
            switch kind {
            case .camera: site.camera = allowed
            case .microphone: site.microphone = allowed
            case .location: site.location = allowed
            }
        }
        settings[host] = site
    }

    /// Clears only what this file remembers, so zoom and anything added later stay.
    static func forget(host: String, in settings: SiteSettings) {
        var site = settings[host]
        site.camera = nil
        site.microphone = nil
        site.location = nil
        site.allowsInvalidCertificate = nil
        settings[host] = site
    }

    static func settingsURL(for kind: PermissionKind) -> URL {
        switch kind {
        case .camera: privacyPane("Privacy_Camera")
        case .microphone: privacyPane("Privacy_Microphone")
        case .location: privacyPane("Privacy_LocationServices")
        }
    }

    static let screenRecordingSettingsURL = privacyPane("Privacy_ScreenCapture")

    private static func privacyPane(_ anchor: String) -> URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    private static func name(_ kind: PermissionKind) -> String {
        switch kind {
        case .camera: "camera"
        case .microphone: "microphone"
        case .location: "location"
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
