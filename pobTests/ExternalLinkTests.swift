import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

private nonisolated let join = "msteams://teams.example/l/join/1"

private final class Seen {
    var alerts: [NSAlert] = []
    var opened: [URL] = []
}

private final class SchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        task.didReceive(URLResponse(url: task.request.url!, mimeType: "text/html", expectedContentLength: 2, textEncodingName: "utf-8"))
        task.didReceive(Data("ok".utf8))
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Every tab here answers through the seams, so no test can open a real app.
@Suite(.timeLimit(.minutes(1))) struct ExternalLinkTests {
    let link = URL(string: join)!
    let address = URL(string: "https://page.example/meeting")!

    private func make(_ tab: Tab = Tab(profile: .temporary()), answer: NSApplication.ModalResponse = .alertFirstButtonReturn) -> (Tab, Seen) {
        let seen = Seen()
        tab.appToOpen = { _ in URL(filePath: "/Applications/Microsoft Teams.app") }
        tab.openInApp = { seen.opened.append($0) }
        tab.alertSeam = { seen.alerts.append($0); return answer }
        return (tab, seen)
    }
    func showPage(in tab: Tab, _ html: String = "") async {
        await finishLoading(tab) { tab.webView.loadSimulatedRequest(URLRequest(url: address), responseHTML: html) }
    }
    @discardableResult
    func decide(_ tab: Tab, _ url: URL, type: WKNavigationType = .linkActivated, modifiers: NSEvent.ModifierFlags = []) -> WKNavigationActionPolicy? {
        var decision: WKNavigationActionPolicy?
        tab.webView(tab.webView, decidePolicyFor: FakeNavigationAction(url: url, type: type, modifiers: modifiers)) { decision = $0 }
        return decision
    }

    // MARK: The question

    @Test func theSheetNamesTheAppAndThePage() async throws {
        let (tab, seen) = make()
        await showPage(in: tab)
        #expect(decide(tab, link) == .cancel)
        let alert = try #require(seen.alerts.first)
        #expect(alert.messageText == "Open this link in Microsoft Teams?")
        #expect(alert.informativeText.contains("page.example"))
        #expect(alert.buttons.map(\.title) == ["Open", "Cancel"])
    }
    @Test func openHandsTheLinkToTheApp() {
        let (tab, seen) = make()
        decide(tab, link)
        #expect(seen.opened == [link])
    }
    @Test func cancelOpensNothing() {
        let (tab, seen) = make(answer: .alertSecondButtonReturn)
        decide(tab, link)
        #expect(seen.alerts.count == 1)
        #expect(seen.opened.isEmpty)
    }
    @Test(arguments: [NSApplication.ModalResponse.alertFirstButtonReturn, .alertSecondButtonReturn])
    func nothingIsRemembered(answer: NSApplication.ModalResponse) {
        let (tab, seen) = make(answer: answer)
        let start = Date.now
        var seconds = 0.0
        tab.now = { start.addingTimeInterval(seconds) }
        decide(tab, link)
        seconds = 60 // well past the pause after a Cancel
        decide(tab, link)
        #expect(seen.alerts.count == 2)
    }
    @Test func withNoAppNothingHappens() {
        let (tab, seen) = make()
        tab.appToOpen = { _ in nil }
        #expect(decide(tab, link) == .cancel)
        #expect(seen.alerts.isEmpty)
        #expect(seen.opened.isEmpty)
    }
    /// A background tab has no window, so it can't ask, and a request it couldn't ask about mustn't block the next one.
    @Test func withNoWindowNothingShowsAndNothingOpens() async {
        let (tab, seen) = make()
        tab.alertSeam = nil
        var decision: WKNavigationActionPolicy?
        let modal = await wentModal { decision = decide(tab, link) }
        #expect(decision == .cancel)
        #expect(!modal)
        #expect(seen.opened.isEmpty)

        tab.alertSeam = { seen.alerts.append($0); return .alertSecondButtonReturn }
        decide(tab, link)
        #expect(seen.alerts.count == 1)
    }
    @Test func aPageCantStackSheets() {
        let (tab, _) = make()
        var asked = 0
        tab.alertSeam = { _ in
            asked += 1
            if asked == 1 { // the seam stands for the sheet being up, so these arrive while it is
                decide(tab, link)
                _ = tab.webView(tab.webView, createWebViewWith: tab.webView.configuration, for: FakeNavigationAction(url: link, type: .other, modifiers: []), windowFeatures: keptWindowFeatures())
            }
            return .alertFirstButtonReturn
        }
        decide(tab, link)
        #expect(asked == 1)
        decide(tab, link)
        #expect(asked == 2)
    }

    // MARK: After Cancel

    /// Reserved keys don't reach the window while a sheet is key, so a page that asked again at once could leave no way to press ⌘W.
    @Test func afterCancelTheTabDropsRequestsForThreeSeconds() {
        let (tab, seen) = make(answer: .alertSecondButtonReturn)
        let start = Date.now
        var seconds = 0.0
        tab.now = { start.addingTimeInterval(seconds) }
        decide(tab, link)
        #expect(seen.alerts.count == 1)

        seconds = 2.9
        #expect(decide(tab, link) == .cancel)
        #expect(tab.webView(tab.webView, createWebViewWith: tab.webView.configuration, for: FakeNavigationAction(url: link, type: .other, modifiers: []), windowFeatures: keptWindowFeatures()) == nil)
        #expect(seen.alerts.count == 1)

        seconds = 3
        decide(tab, link)
        #expect(seen.alerts.count == 2)
    }
    /// A looping page asks all through the pause, and that can't be what decides when it ends.
    @Test func requestsDroppedAfterCancelDontExtendThePause() {
        let (tab, seen) = make(answer: .alertSecondButtonReturn)
        let start = Date.now
        var seconds = 0.0
        tab.now = { start.addingTimeInterval(seconds) }
        decide(tab, link)
        for dropped in [1.0, 2.0, 2.9] {
            seconds = dropped
            decide(tab, link)
        }
        seconds = 3
        decide(tab, link)
        #expect(seen.alerts.count == 2)
    }
    @Test func openStartsNoPause() {
        let (tab, seen) = make()
        decide(tab, link)
        decide(tab, link)
        #expect(seen.alerts.count == 2)
    }
    @Test func aCancelInOneTabLeavesTheOthersAsking() {
        let (tab, _) = make(answer: .alertSecondButtonReturn)
        let (other, seen) = make()
        decide(tab, link)
        decide(other, link)
        #expect(seen.alerts.count == 1)
    }
    @Test func aPageThatNeverStopsAskingGetsOneSheet() async throws {
        let (tab, seen) = make(answer: .alertSecondButtonReturn)
        let frozen = Date.now // so a slow run can't outlast the pause
        tab.now = { frozen }
        await showPage(in: tab, "<script>setInterval(() => { location = '\(join)' }, 20)</script>")
        #expect(await eventually { !seen.alerts.isEmpty })
        try await Task.sleep(for: .milliseconds(500))
        #expect(seen.alerts.count == 1)
    }

    // MARK: Real WebKit

    @Test(arguments: [
        "document.querySelector('a').click()",
        "location = '\(join)'",
        "document.body.append(Object.assign(document.createElement('iframe'), {src: '\(join)'}))",
        "document.querySelector('form').submit()",
    ])
    func whateverStartsItThePageStaysAndTheAppOpens(script: String) async throws {
        let (tab, seen) = make()
        await showPage(in: tab, #"<a href="\#(join)">join</a><form action="\#(join)"></form>"#)
        _ = try await tab.webView.evaluateJavaScript("\(script); 1")
        #expect(await eventually { seen.opened.first?.scheme == "msteams" })
        #expect(seen.alerts.count == 1)
        #expect(tab.webView.url == address)
        #expect(!tab.isShowingErrorPage)
    }
    /// The certificate question trusts `mainFrameURL`, and this would otherwise name any host with no load at all.
    @Test func aLinkToAnotherAppLeavesThePageWhereItIs() async throws {
        let (tab, seen) = make()
        await showPage(in: tab)
        _ = try await tab.webView.evaluateJavaScript("location = 'msteams://accounts.example/'; 1")
        #expect(await eventually { !seen.opened.isEmpty })
        #expect(tab.mainFrameURL == address)
    }
    /// During a redirect `webView.url` holds the target, so a site could put any name it liked in the sheet.
    @Test func aRedirectCantClaimAnotherHost() async throws {
        let server = LocalServer()
        server.routes = [
            "/": .body(Data(#"<a href="/go">join</a>"#.utf8), headers: ["Content-Type": "text/html"]),
            "/go": .redirect(to: "msteams://accounts.example/x"),
        ]
        try await server.start()
        defer { server.stop() }
        let (tab, seen) = make()
        await finishLoading(tab) { tab.webView.load(URLRequest(url: server.url("/"))) }
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('a').click(); 1")
        #expect(await eventually { !seen.alerts.isEmpty })
        #expect(seen.alerts.first?.informativeText.contains("127.0.0.1") == true)
        #expect(seen.alerts.first?.informativeText.contains("accounts.example") == false)
        #expect(await eventually { tab.webView.url == server.url("/") })
        #expect(!tab.isShowingErrorPage)
    }

    // MARK: Tabs

    private func managedTab() -> (TabManager, Tab, Seen) {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let (tab, seen) = make(tabs.newTab(nil, activate: true))
        return (tabs, tab, seen)
    }
    @Test func aNewWindowLinkAsksAndOpensNoTab() async throws {
        let (tabs, tab, seen) = managedTab()
        await showPage(in: tab, #"<a target="_blank" href="\#(join)">join</a>"#)
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('a').click(); 1")
        #expect(await eventually { seen.opened == [link] })
        #expect(tabs.list.records.count == 1)
    }
    /// `window.open` skips the opener's policy call, so a popup would be left behind as a blank tab.
    @Test func windowOpenAsksAndLeavesNoBlankTab() async throws {
        let (tabs, tab, seen) = managedTab()
        await showPage(in: tab)
        #expect(try await tab.webView.evaluateJavaScript("window.open('\(join)') === null") as? Bool == true)
        #expect(await eventually { seen.opened == [link] })
        #expect(seen.alerts.count == 1)
        #expect(seen.alerts.first?.informativeText.contains("page.example") == true)
        #expect(tabs.list.records.count == 1)
    }
    /// A background tab couldn't show the sheet, so it would stay blank and the link would go nowhere.
    @Test func aCommandClickAsksHereAndOpensNoTab() {
        let (tabs, tab, seen) = managedTab()
        #expect(decide(tab, link, modifiers: .command) == .cancel)
        #expect(seen.opened == [link])
        #expect(tabs.list.records.count == 1)
    }

    // MARK: Left alone

    @Test(arguments: ["https://localhost/next", "http://localhost/next", "about:blank", "data:text/html,x", "blob:https://localhost/1", "file:///tmp/x.html", "javascript:void(0)"])
    func schemesWebKitHandlesAreLeftToIt(address: String) throws {
        let (tab, seen) = make()
        #expect(decide(tab, try #require(URL(string: address)), type: .other) == .allow)
        #expect(seen.alerts.isEmpty)
    }
    @Test func aSchemeWithItsOwnHandlerIsLeftToIt() async {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(SchemeHandler(), forURLScheme: "pobtest")
        let (tab, seen) = make(Tab(profile: .temporary(), configuration: configuration))
        tab.webView.load(URLRequest(url: URL(string: "pobtest://page/one")!))
        #expect(await eventually { !tab.webView.isLoading && tab.webView.url?.scheme == "pobtest" })
        #expect(seen.alerts.isEmpty)
    }
}
