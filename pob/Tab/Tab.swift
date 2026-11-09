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
    /// The error page is the one for a page the rules blocked, so its Load anyway link works.
    private(set) var isShowingBlockedPage = false
    /// Load anyway let this host through. The rules stay off for it until the tab's page leaves it, and nothing is remembered.
    private(set) var unblockedHost: String?

    private var observations: [NSKeyValueObservation] = []
    private var errorNavigation: WKNavigation?
    private var blockedNavigation: WKNavigation?
    /// Tests answer the alerts through this, because a sheet needs a window on screen.
    var alertSeam: ((NSAlert) -> NSApplication.ModalResponse)?
    /// Replaceable so tests don't depend on this Mac's camera, microphone and location settings.
    var deviceAccess: (PermissionKind) -> Bool = { Permissions.macOSAllows($0) }
    /// Replaceable so a test can't open System Settings.
    var openSettings: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Replaceable so a test can't open a real app.
    var openInApp: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Replaceable so tests don't depend on what's installed on this Mac.
    var appToOpen: (URL) -> URL? = { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    /// The main-frame address last going ahead, which is what a no-window refusal has to retry and what a certificate question has to be about.
    var mainFrameURL: URL?
    /// Set when a certificate question was refused only because the tab had no window. The manager loads it on activation.
    var retryURL: URL?
    /// The network layer retries a refused connection, so a refusal holds until the next page or the load's end.
    private var refusedHosts: Set<String> = []
    /// Back-forward items that hold an error page, which WebKit restores from its cache as if they were real pages.
    private var errorItems: [WKBackForwardListItem?] = []
    private var arrivedByHistory = false
    private var isOfferingToOpen = false
    /// When the user last said no. Reserved keys like ⌘W don't reach a window behind a sheet, so a page asking again at once could trap them.
    private var offerCancelledAt = Date.distantPast
    private static let offerPause: TimeInterval = 3
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
        profile.contentBlocker.attach(webView.configuration.userContentController)
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
        case .url(let url) where url.isFileURL:
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
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
        if navigationAction.request.url?.absoluteString == ErrorPage.loadAnywayAddress {
            // Before the other-app check, which would offer it to an app. Any page can link here, so only the blocked page's own link counts.
            decisionHandler(.cancel)
            if isShowingBlockedPage, let url = webView.url, let host = url.host() {
                unblockedHost = host
                webView.load(URLRequest(url: url))
            }
        } else if let link = linkForAnotherApp(navigationAction) {
            decisionHandler(.cancel)
            offerToOpen(link)
        } else if navigationAction.navigationType == .linkActivated, navigationAction.modifierFlags.contains(.command) {
            onOpenLink?(navigationAction.request, false)
            decisionHandler(.cancel)
        } else if isShowingErrorPage, navigationAction.navigationType == .linkActivated, navigationAction.request.url == webView.url {
            // Retry to the page's own address plus a fragment would only scroll.
            decisionHandler(.cancel)
            webView.reload()
        } else if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
        } else {
            if navigationAction.targetFrame?.isMainFrame == true {
                mainFrameURL = navigationAction.request.url
                applyBlocking(for: navigationAction.request.url)
            }
            decisionHandler(.allow)
        }
    }

    /// Before the load goes ahead, so the page's first request already follows it. A restored page comes through here too.
    private func applyBlocking(for url: URL?) {
        let controller = webView.configuration.userContentController
        let host = url?.host()
        if let host, profile.siteSettings[host].adBlockerOff == true {
            if host == unblockedHost { unblockedHost = nil } // the site's switch takes over, so switching it back on blocks the page again
            profile.contentBlocker.detach(controller)
        } else if let host, host == unblockedHost {
            profile.contentBlocker.detach(controller)
        } else {
            profile.contentBlocker.attach(controller)
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
        let isDownload = isAttachment || !navigationResponse.canShowMIMEType
        // Only now does it show it's no page, so the one that stays goes back to its own site's rules.
        if isDownload, navigationResponse.isForMainFrame { applyBlocking(for: webView.backForwardList.currentItem?.url) }
        decisionHandler(isDownload ? .download : .allow)
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
        isShowingBlockedPage = navigation != nil && navigation === blockedNavigation
        // Here and not in the policy call, because a link that turns out to be a download leaves the page where it is.
        if webView.url?.host() != unblockedHost { unblockedHost = nil }
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
        let error = error as NSError
        guard ErrorPage.shouldShow(error), let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL else { return }
        if error.domain == "WebKitErrorDomain", error.code == 104 { // a content rule blocked the page itself
            show(ErrorPage.blockedHTML(for: url), at: url)
            blockedNavigation = errorNavigation // the flag goes up when this commits, so the page being replaced can't use the link
        } else {
            show(ErrorPage.html(for: url, error: error), at: url)
        }
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
            // WebKit asks about everything a page loads, and Allow lasts, so a page can't raise this about another host.
            // `load` preconnects, which can beat the policy call that names the page, but then the load itself asks again.
            guard space.host == mainFrameURL?.host() else {
                completion(.cancelAuthenticationChallenge, nil)
                return
            }
            if refusedHosts.contains(space.host) {
                completion(.cancelAuthenticationChallenge, nil)
            } else if alertSeam == nil, webView.window == nil {
                // A background tab can't show the question, so it asks again when the tab is activated, and remembers nothing.
                retryURL = mainFrameURL
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

    /// The address, if it's one for another app. WebKit fails those with an error that's hidden, so the link would do nothing.
    private func linkForAnotherApp(_ action: WKNavigationAction) -> URL? {
        guard let url = action.request.url, let scheme = url.scheme, !WKWebView.handlesURLScheme(scheme),
              webView.configuration.urlSchemeHandler(forURLScheme: scheme) == nil else { return nil }
        return url
    }

    /// A page can do this with no click, so it always asks. One sheet at a time, and what arrives while it's up, or just after a Cancel, is dropped.
    private func offerToOpen(_ link: URL) {
        guard !isOfferingToOpen, now().timeIntervalSince(offerCancelledAt) >= Self.offerPause, let app = appToOpen(link) else { return }
        isOfferingToOpen = true
        let alert = NSAlert()
        alert.messageText = "Open this link in \(app.deletingPathExtension().lastPathComponent)?"
        // The committed page, because during a redirect `webView.url` holds the target, and the sender picks that.
        alert.informativeText = webView.backForwardList.currentItem?.url.host().map { "This link comes from \($0)." } ?? ""
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        present(alert) { [weak self] response in
            guard let self else { return }
            isOfferingToOpen = false
            if response == .alertFirstButtonReturn {
                openInApp(link)
            } else if response == .alertSecondButtonReturn { // no window answers `.cancel`, and nobody said no
                offerCancelledAt = now()
            }
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
        // `window.open` skips the policy call above, and a popup would be left behind as a blank tab.
        if let link = linkForAnotherApp(navigationAction) {
            offerToOpen(link)
            return nil
        }
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
        decide(kinds: Permissions.kinds(for: type), originHost: origin.host, decision: decisionHandler)
    }

    func webView(
        _ webView: WKWebView,
        requestGeolocationPermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decide(kinds: [.location], originHost: origin.host, decision: decisionHandler)
    }

    /// Answers are kept under the page's own host, so Reset works for the page in view and an embedded frame can't reuse a grant.
    func decide(kinds: [PermissionKind], originHost: String, decision: @escaping @MainActor (WKPermissionDecision) -> Void) {
        let host = webView.url?.host() ?? originHost
        Permissions.resolve(
            kinds: kinds, host: host, text: Permissions.promptText(host: host, kinds: kinds), settings: profile.siteSettings,
            macOSAllows: deviceAccess,
            present: { [self] alert, completion in present(alert, completion: completion) },
            openSettings: openSettings, decision: decision)
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
