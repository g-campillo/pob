import AppKit
import WebKit

final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let profile: Profile
    let webView: WKWebView
    /// WebKit docks the inspector beside the page, so the two share this view to leave the window together.
    let pageView = NSView()
    var onLoadFinished: (() -> Void)?
    var onStateChange: (() -> Void)?
    var onOpenLink: ((URLRequest, _ activate: Bool) -> Void)?
    var onCreatePopup: ((WKWebViewConfiguration) -> WKWebView?)?
    var onCloseRequested: (() -> Void)?

    private var observations: [NSKeyValueObservation] = []

    /// A popup passes the configuration WebKit gave it, which keeps its link to the opener.
    init(profile: Profile, configuration: WKWebViewConfiguration? = nil) {
        self.profile = profile
        webView = WKWebView(frame: .zero, configuration: configuration ?? Self.standardConfiguration(for: profile))
        webView.isInspectable = true
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.underPageBackgroundColor = .clear
        webView.autoresizingMask = [.width, .height]
        PrivateAPI.setDrawsBackground(webView, false)
        pageView.autoresizingMask = [.width, .height]
        pageView.addSubview(webView)

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeState()
    }

    private static func standardConfiguration(for profile: Profile) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.dataStore
        configuration.applicationNameForUserAgent = UserAgent.applicationName()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        PrivateAPI.enableDeveloperExtras(configuration)
        return configuration
    }

    /// Muted capture counts, because the call is still going.
    var isCapturing: Bool {
        webView.cameraCaptureState != .none
            || webView.microphoneCaptureState != .none
            || PrivateAPI.isCapturingDisplay(webView)
    }

    /// The page to hand to Safari, or nil when there's nothing worth opening.
    var safariURL: URL? {
        guard let url = webView.url, url.scheme != "about" else { return nil }
        return url
    }

    func load(_ input: AddressInput) {
        switch input {
        case .url(let url), .search(let url):
            webView.load(URLRequest(url: url))
        }
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

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command) {
            onOpenLink?(navigationAction.request, false)
            decisionHandler(.cancel)
        } else {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Only the blank page shows the desktop. Pages with no background of their own get a normal one.
        PrivateAPI.setDrawsBackground(webView, webView.url?.scheme != "about")
    }

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
        if navigationAction.modifierFlags.contains(.command) {
            onOpenLink?(navigationAction.request, false)
            return nil
        }
        return onCreatePopup?(configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        onCloseRequested?()
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
