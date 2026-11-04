import AppKit
import WebKit

enum PopupPolicy {
    case sameTab
    case popupWindow
}

final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let webView: WKWebView
    var onLoadFinished: (() -> Void)?
    var onStateChange: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []

    init(profile: Profile) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.dataStore
        configuration.applicationNameForUserAgent = UserAgent.applicationName()
        configuration.preferences.isElementFullscreenEnabled = true
        PrivateAPI.enableDeveloperExtras(configuration)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .clear
        PrivateAPI.makeBackgroundClear(webView)

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeState()
    }

    func load(_ input: AddressInput) {
        switch input {
        case .url(let url), .search(let url):
            webView.load(URLRequest(url: url))
        }
    }

    static func popupPolicy(for navigationType: WKNavigationType) -> PopupPolicy {
        navigationType == .linkActivated ? .sameTab : .popupWindow
    }

    private func observeState() {
        observations = [
            webView.observe(\.url) { [weak self] _, _ in self?.stateChanged() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.stateChanged() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.stateChanged() },
        ]
    }

    // WebKit reports these properties on the main thread.
    private nonisolated func stateChanged() {
        MainActor.assumeIsolated { onStateChange?() }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onLoadFinished?()
    }

    // MARK: WKUIDelegate

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        switch Self.popupPolicy(for: navigationAction.navigationType) {
        case .sameTab:
            webView.load(navigationAction.request)
            return nil
        case .popupWindow:
            return PopupWindow.open(configuration: configuration, features: windowFeatures, uiDelegate: self)
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        PopupWindow.close(showing: webView)
    }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        Permissions.ask(host: origin.host, type: type, in: webView.window, decision: decisionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.present(in: webView.window) { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.present(in: webView.window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor (String?) -> Void
    ) {
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        let alert = NSAlert()
        alert.messageText = prompt
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.present(in: webView.window) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if let window = webView.window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
