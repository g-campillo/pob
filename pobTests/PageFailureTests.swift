import Foundation
import Testing
@testable import pob

@Suite struct PageFailureTests {
    let page = URL(string: "https://example.com/a")!

    @Test func errorPagesNameTheFailure() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Boom & bust"])
        let html = ErrorPage.html(for: page, error: error)
        #expect(html.contains("<title>Can't open example.com</title>"))
        #expect(html.contains("<p>Boom &amp; bust</p>"))
    }
    @Test func errorTextCantInjectMarkup() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "<script>alert(1)</script>"])
        let html = ErrorPage.html(for: page, error: error)
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;script&gt;alert"))
    }
    @Test func theNamedAddressIsEscapedToo() {
        let html = ErrorPage.html(for: URL(string: "file:///tmp/a&b")!, error: URLError(.fileDoesNotExist))
        #expect(html.contains("a&amp;b"))
        #expect(!html.contains("a&b"))
    }
    @Test func retryLinksAreEscapedAndLimitedToWebAndFileAddresses() {
        let error = URLError(.timedOut)
        let tricky = URL(string: "https://example.com/a?x=1&y='z'")!
        let html = ErrorPage.html(for: tricky, error: error)
        #expect(html.contains("href=\"https://example.com/a?x=1&amp;y=&#39;z&#39;\""))
        #expect(ErrorPage.html(for: URL(string: "file:///tmp/a.html")!, error: error).contains("Retry"))
        #expect(!ErrorPage.html(for: URL(string: "javascript:alert(1)")!, error: error).contains("<a "))
        #expect(!ErrorPage.crashHTML(for: nil).contains("<a "))
        #expect(ErrorPage.crashHTML(for: page).contains("Reload"))
    }
    @Test func cancelledLoadsShowNothing() {
        #expect(!ErrorPage.shouldShow(URLError(.cancelled)))
        #expect(!ErrorPage.shouldShow(NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(!ErrorPage.shouldShow(NSError(domain: "WebKitErrorDomain", code: 204)))
        #expect(!ErrorPage.shouldShow(URLError(.unsupportedURL)))
        #expect(ErrorPage.shouldShow(URLError(.timedOut)))
    }
    @Test func challengesGetTheRightResponse() {
        let cases: [(String, Bool, Bool, ChallengeAction)] = [
            (NSURLAuthenticationMethodHTTPBasic, false, true, .askForPassword),
            (NSURLAuthenticationMethodHTTPDigest, false, true, .askForPassword),
            (NSURLAuthenticationMethodServerTrust, false, true, .useDefault),
            (NSURLAuthenticationMethodServerTrust, false, false, .askAboutCertificate),
            (NSURLAuthenticationMethodServerTrust, true, false, .trust),
            (NSURLAuthenticationMethodClientCertificate, false, true, .useDefault),
        ]
        for (method, allowed, valid, expected) in cases {
            #expect(SignInChallenge.action(method: method, hostIsAllowed: allowed, trustIsValid: valid) == expected)
        }
    }
    @Test func aSecondCrashWithinTenSecondsGivesUp() {
        var recovery = CrashRecovery()
        let start = Date(timeIntervalSince1970: 1000)
        let first = recovery.shouldReload(at: start)
        let second = recovery.shouldReload(at: start.addingTimeInterval(9))
        let third = recovery.shouldReload(at: start.addingTimeInterval(11))
        #expect(first && !second && third)
    }
    @Test(.timeLimit(.minutes(1))) func aCrashReloadsOnceThenShowsTheCrashPage() async {
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.webView.load(URLRequest(url: URL(string: "about:blank")!)) }
        var clock = Date(timeIntervalSince1970: 1000)
        tab.now = { clock }
        await finishLoading(tab) { tab.webViewWebContentProcessDidTerminate(tab.webView) }
        #expect(!tab.isShowingErrorPage)
        clock += 3
        await finishLoading(tab) { tab.webViewWebContentProcessDidTerminate(tab.webView) }
        #expect(tab.isShowingErrorPage)
        clock += 11
        await finishLoading(tab) { tab.webViewWebContentProcessDidTerminate(tab.webView) }
        #expect(!tab.isShowingErrorPage)
    }
    @Test(.timeLimit(.minutes(1))) func aFailureReportedAfterCommitShowsTheErrorPageToo() async {
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.webView.load(URLRequest(url: URL(string: "about:blank")!)) }
        let error = URLError(.networkConnectionLost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "http://localhost:1/")!])
        await finishLoading(tab) { tab.webView(tab.webView, didFail: nil, withError: error) }
        #expect(tab.isShowingErrorPage)
    }
    @Test func theAppAllowsPlainHTTPInWebContent() throws {
        let ats = try #require(Bundle(for: Tab.self).infoDictionary?["NSAppTransportSecurity"] as? [String: Any])
        #expect(ats["NSAllowsArbitraryLoadsInWebContent"] as? Bool == true)
    }

    // MARK: Real failed loads

    private func failedLoad(_ tabs: TabManager, _ address: String = "http://localhost:1/") async -> Tab {
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.load(.url(URL(string: address)!)) }
        return tab
    }

    @Test(.timeLimit(.minutes(1))) func aLoadThatFailsShowsTheErrorPageAndLeavesNoHistory() async throws {
        let profile = Profile.temporary()
        var asked = false
        let tabs = TabManager(profile: profile, keepsSpare: false)
        tabs.updateFavicon = { _, _, _ in asked = true }
        let tab = await failedLoad(tabs)
        #expect(tab.isShowingErrorPage)
        let text = try? await tab.webView.evaluateJavaScript("document.body.innerText") as? String
        #expect(text?.contains("localhost") == true)
        try? await Task.sleep(for: .milliseconds(200))
        let found = await profile.history.search("localhost", limit: 5)
        #expect(found.isEmpty)
        #expect(!asked)
        // The address and the page's place both stay, so a restore brings back the real page and its history.
        #expect(tabs.snapshotRecords[0].url?.host() == "localhost")
        #expect(tabs.snapshotRecords[0].interactionState != nil)
    }
    @Test(.timeLimit(.minutes(1))) func theErrorFlagClearsOnTheNextRealPage() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = await failedLoad(tabs)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(!tab.isShowingErrorPage)
    }
    @Test(.timeLimit(.minutes(1))) func aFailedRevisitKeepsTheSavedTitle() async {
        let profile = Profile.temporary()
        let address = URL(string: "http://localhost:1/")!
        await profile.history.record(url: address, title: "Saved")
        let tabs = TabManager(profile: profile, keepsSpare: false)
        _ = await failedLoad(tabs)
        try? await Task.sleep(for: .milliseconds(300))
        let found = await profile.history.search("localhost", limit: 5)
        #expect(found.map(\.title) == ["Saved"] && found.first?.visitCount == 1)
    }
    @Test(.timeLimit(.minutes(1))) func goingBackToAnErrorPageStillKeepsItOutOfHistory() async {
        let profile = Profile.temporary()
        let tabs = TabManager(profile: profile, keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.webView.load(URLRequest(url: URL(string: "about:blank")!)) }
        await finishLoading(tab) { tab.load(.url(URL(string: "http://localhost:1/")!)) }
        await finishLoading(tab) { tab.webView.goBack() }
        #expect(!tab.isShowingErrorPage)
        tab.webView.goForward()
        #expect(await eventually { tab.isShowingErrorPage })
        try? await Task.sleep(for: .milliseconds(500))
        let found = await profile.history.search("localhost", limit: 5)
        #expect(found.isEmpty)
    }
    @Test(.timeLimit(.minutes(1))) func retryWorksWhenTheAddressHasAFragment() async {
        let tab = Tab(profile: .temporary())
        let address = URL(string: "http://localhost:1/#part")!
        let error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: address])
        await finishLoading(tab) { tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: error) }
        #expect(tab.webView.url == address)
        // A link to the page's own address plus a fragment only scrolls, so it has to become a reload.
        await finishLoading(tab) {
            tab.webView.evaluateJavaScript("document.querySelector('a').click()", completionHandler: nil)
        }
        #expect(tab.isShowingErrorPage)
    }
    @Test(.timeLimit(.minutes(1))) func goingBackToAPageThatRetryFixedLoadsItFromCache() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "pob-retry-\(UUID().uuidString).html")
        defer { try? FileManager.default.removeItem(at: file) }
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.webView.load(URLRequest(url: URL(string: "about:blank")!)) }
        let error = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: file])
        await finishLoading(tab) { tab.webView(tab.webView, didFailProvisionalNavigation: nil, withError: error) }
        #expect(tab.isShowingErrorPage)
        try "<p>fixed</p>".write(to: file, atomically: true, encoding: .utf8)
        await finishLoading(tab) { tab.webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent()) }
        #expect(!tab.isShowingErrorPage)
        await finishLoading(tab) { tab.webView.load(URLRequest(url: URL(string: "about:blank")!)) }
        await finishLoading(tab) { tab.webView.goBack() }
        try? await Task.sleep(for: .milliseconds(300))
        #expect(!tab.isShowingErrorPage)
    }
}
