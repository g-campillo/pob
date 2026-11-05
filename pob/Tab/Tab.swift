import AppKit
import WebKit

final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    let profile: Profile
    let webView: WKWebView
    /// WebKit docks the inspector beside the page, so the two share this view to leave the window together.
    let pageView = NSView()
    var title: String { webView.title ?? "" }
    var onLoadFinished: (() -> Void)?
    var onStateChange: (() -> Void)?
    var onProgress: ((Double, Bool) -> Void)?
    var onOpenLink: ((URLRequest, _ activate: Bool) -> Void)?
    var onCreatePopup: ((WKWebViewConfiguration) -> WKWebView?)?
    var onCloseRequested: (() -> Void)?
    /// A navigation in this tab turned into a download.
    var onBecameDownload: (() -> Void)?

    /// True from the moment an error or crash page loads until the next real page commits, so history and favicons skip it.
    private(set) var isShowingErrorPage = false

    private var observations: [NSKeyValueObservation] = []
    private var errorNavigation: WKNavigation?
    /// Tests answer the alerts through this, because a sheet needs a window on screen.
    var alertSeam: ((NSAlert) -> NSApplication.ModalResponse)?
    /// The main-frame address last asked for, which is what a no-window refusal has to retry.
    var mainFrameURL: URL?
    /// Set when a certificate question was refused only because the tab had no window. The manager loads it on activation.
    var retryURL: URL?
    /// The network layer retries a refused connection, so a refusal holds until the next page or the load's end.
    private var refusedHosts: Set<String> = []
    /// Back-forward items that hold an error page, which WebKit restores from its cache as if they were real pages.
    private var errorItems: [WKBackForwardListItem?] = []
    private var arrivedByHistory = false
    /// Replaceable so a test can make the evaluation refuse to start. The block runs on the main queue.
    var evaluateTrust: (SecTrust, @escaping @Sendable (Bool) -> Void) -> OSStatus = { trust, done in
        SecTrustEvaluateAsyncWithError(trust, .main) { _, valid, _ in done(valid) }
    }
    private var crashRecovery = CrashRecovery()
    /// Replaceable because tests can't wait ten seconds.
    var now: () -> Date = { .now }

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

    /// Whether the text was found. Wraps around the page.
    func find(_ text: String, backwards: Bool) async -> Bool {
        let configuration = WKFindConfiguration()
        configuration.wraps = true
        configuration.backwards = backwards
        return (try? await webView.find(text, configuration: configuration).matchFound) ?? false
    }

    // MARK: Zoom and printing

    /// The zoom is kept per host. Pages with no host (`about:` and the like) change but remember nothing.
    func setZoom(_ zoom: Double) {
        webView.pageZoom = zoom
        guard let host = webView.url?.host() else { return }
        let saved = zoom == 1 ? nil : zoom // 1 is the default, so it clears the entry
        if profile.siteSettings[host].zoom != saved { profile.siteSettings[host].zoom = saved }
    }

    func zoomIn() { setZoom(ZoomLevels.larger(than: webView.pageZoom)) }
    func zoomOut() { setZoom(ZoomLevels.smaller(than: webView.pageZoom)) }
    func actualSize() { setZoom(1) }

    /// Replaceable because the print sheet needs a window on screen.
    var printSeam: ((NSPrintOperation) -> Void)?

    func printOperation() -> NSPrintOperation {
        let operation = webView.printOperation(with: .shared)
        operation.view?.frame = webView.bounds
        return operation
    }

    func printPage() {
        let operation = printOperation()
        if let printSeam {
            printSeam(operation)
        } else if let window = webView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        }
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
            webView.observe(\.title) { [weak self] _, _ in self?.stateChanged() },
            webView.observe(\.canGoBack) { [weak self] _, _ in self?.stateChanged() },
            webView.observe(\.canGoForward) { [weak self] _, _ in self?.stateChanged() },
            webView.observe(\.estimatedProgress) { [weak self] _, _ in self?.progressChanged() },
            webView.observe(\.isLoading) { [weak self] _, _ in self?.progressChanged() },
        ]
    }

    // WebKit reports these properties on the main thread.
    private nonisolated func stateChanged() {
        MainActor.assumeIsolated { onStateChange?() }
    }

    private nonisolated func progressChanged() {
        MainActor.assumeIsolated { onProgress?(webView.estimatedProgress, webView.isLoading) }
    }

    // MARK: WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        arrivedByHistory = navigationAction.navigationType == .backForward
        if navigationAction.targetFrame?.isMainFrame == true { mainFrameURL = navigationAction.request.url }
        if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command) {
            onOpenLink?(navigationAction.request, false)
            decisionHandler(.cancel)
        } else if isShowingErrorPage, navigationAction.navigationType == .linkActivated, navigationAction.request.url == webView.url {
            // Retry to the page's own address plus a fragment would only scroll.
            decisionHandler(.cancel)
            webView.reload()
        } else {
            decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        // Like Safari, an attachment downloads even when WebKit could show it.
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let isAttachment = disposition?.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") == true
        decisionHandler(isAttachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        profile.downloads.track(download)
        onBecameDownload?()
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        profile.downloads.track(download)
        onBecameDownload?()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Only the blank page shows the desktop. Pages with no background of their own get a normal one.
        PrivateAPI.setDrawsBackground(webView, webView.url?.scheme != "about")
        webView.pageZoom = webView.url?.host().flatMap { profile.siteSettings[$0].zoom } ?? 1
        let item = webView.backForwardList.currentItem
        if navigation != nil, navigation === errorNavigation {
            errorItems.append(item)
            isShowingErrorPage = true
        } else if arrivedByHistory, errorItems.contains(where: { $0 === item }) {
            isShowingErrorPage = true
            webView.reload()
        } else {
            errorItems.removeAll { $0 === item } // the entry holds a real page now
            isShowingErrorPage = false
        }
        if retryURL != webView.url { retryURL = nil } // the tab moved on. A 401 body commits at the same address, so it keeps its retry
        refusedHosts = []
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refusedHosts = []
        showErrorPage(for: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showErrorPage(for: error)
    }

    private func showErrorPage(for error: Error) {
        guard ErrorPage.shouldShow(error),
              let url = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return }
        show(ErrorPage.html(for: url, error: error), at: url)
    }

    private func show(_ html: String, at url: URL?) {
        if let url {
            errorNavigation = webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        } else {
            errorNavigation = webView.loadHTMLString(html, baseURL: nil)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if crashRecovery.shouldReload(at: now()) {
            webView.reload()
        } else {
            show(ErrorPage.crashHTML(for: webView.url), at: webView.url)
        }
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = space.serverTrust else {
            answer(challenge, trustIsValid: true, completionHandler)
            return
        }
        // The header requires the call to come from the queue it answers on. The evaluation itself runs in trustd.
        let status = evaluateTrust(trust) { valid in
            MainActor.assumeIsolated { self.answer(challenge, trustIsValid: valid, completionHandler) }
        }
        if status != errSecSuccess { answer(challenge, trustIsValid: false, completionHandler) }
    }

    /// Calls `completion` exactly once on every path.
    private func answer(
        _ challenge: URLAuthenticationChallenge,
        trustIsValid: Bool,
        _ completion: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let allowed = profile.siteSettings[space.host].allowsInvalidCertificate == true
        switch SignInChallenge.action(method: space.authenticationMethod, hostIsAllowed: allowed, trustIsValid: trustIsValid) {
        case .useDefault:
            completion(.performDefaultHandling, nil)
        case .trust:
            if let trust = space.serverTrust {
                completion(.useCredential, URLCredential(trust: trust))
            } else {
                completion(.performDefaultHandling, nil)
            }
        case .askForPassword:
            askForPassword(challenge, completion)
        case .askAboutCertificate:
            if refusedHosts.contains(space.host) {
                completion(.cancelAuthenticationChallenge, nil)
            } else if alertSeam == nil, webView.window == nil {
                // A background tab can't show the question, so it asks again when the tab is activated, and remembers nothing.
                if mainFrameURL?.host() == space.host { retryURL = mainFrameURL }
                completion(.cancelAuthenticationChallenge, nil)
            } else {
                askAboutCertificate(challenge, completion)
            }
        }
    }

    private func present(_ alert: NSAlert, completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let alertSeam {
            completion(alertSeam(alert))
        } else {
            alert.present(in: webView.window, completion: completion)
        }
    }

    private func askForPassword(
        _ challenge: URLAuthenticationChallenge,
        _ completion: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        // A background tab can't show the sheet, so it asks again when activated.
        if alertSeam == nil, webView.window == nil, mainFrameURL?.host() == space.host { retryURL = mainFrameURL }
        let user = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 22))
        user.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        password.placeholderString = "Password"
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 50))
        fields.addSubview(user)
        fields.addSubview(password)

        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        // The realm is the server's own text, so it's quoted and cut short.
        let realm = space.realm.map { "The site says: \"\($0.prefix(100))\"" } ?? ""
        let retry = challenge.previousFailureCount > 0 ? "That didn't work. Try again.\n" : ""
        alert.informativeText = retry + realm
        alert.accessoryView = fields
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            if response == .alertFirstButtonReturn {
                completion(.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession))
            } else {
                completion(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    private func askAboutCertificate(
        _ challenge: URLAuthenticationChallenge,
        _ completion: @escaping @MainActor (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The certificate for \(space.host) isn't valid"
        alert.informativeText = "pob can't confirm this is the real site. Allow it only if you trust it, for example on a local development server."
        alert.addButton(withTitle: "Go Back")
        alert.addButton(withTitle: "Allow This Site")
        present(alert) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, let trust = space.serverTrust else {
                self?.refusedHosts.insert(space.host)
                completion(.cancelAuthenticationChallenge, nil)
                return
            }
            profile.siteSettings[space.host].allowsInvalidCertificate = true
            completion(.useCredential, URLCredential(trust: trust))
        }
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
        guard let window = webView.window else {
            completionHandler(nil)
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}
