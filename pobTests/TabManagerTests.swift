import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct TabManagerTests {
    func manager() -> TabManager { TabManager(profile: .temporary(), keepsSpare: false) }

    @Test func tabsShareTheirProfilesDataStore() {
        let tabs = manager()
        let first = tabs.newTab(nil, activate: true)
        let second = tabs.newTab(nil, activate: false)
        #expect(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
    }
    @Test func closingTheActiveTabActivatesItsNeighbor() {
        let tabs = manager()
        let first = tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: true)
        tabs.close(tabs.list.activeID!)
        #expect(tabs.activeTab === first)
    }
    @Test func idleTabsStepDownAndSavedTabsLoseTheirWebView() {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: false)
        let idle = tabs.list.records[1].id
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        #expect(tabs.phase(of: idle) == .suspended)
        tabs.updatePhases(now: Date().addingTimeInterval(800), memoryPressure: true)
        #expect(tabs.phase(of: idle) == .saved)
        #expect(tabs.liveTab(idle) == nil)
    }
    @Test func activatingASavedTabRebuildsIt() {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        tabs.newTab(.url(URL(string: "about:blank")!), activate: false)
        let saved = tabs.list.records[1].id
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        tabs.updatePhases(now: Date().addingTimeInterval(800), memoryPressure: true)
        tabs.activate(saved)
        #expect(tabs.liveTab(saved) != nil)
        #expect(tabs.phase(of: saved) == .active)
    }
    @Test func aPageCantOpenWindowsOnItsOwn() async throws {
        let tabs = manager()
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) {
            tab.webView.loadHTMLString("<script>for (let i = 0; i < 5; i++) window.open('about:blank')</script>", baseURL: URL(string: "https://localhost/"))
        }
        #expect(tabs.list.records.count == 1)
    }
    @Test func theSpareTabIsUsedForTheNextTab() {
        let profile = Profile.temporary()
        profile.prepareSpareTab()
        let spare = profile.spareTab
        #expect(spare != nil)
        #expect(TabManager(profile: profile, keepsSpare: false).newTab(nil, activate: true) === spare)
        #expect(profile.spareTab == nil)
    }
    @Test func commandsMatchSpec() {
        let list = CommandList.standard { _ in }
        #expect(list.reservedCommand(key: "t", modifiers: .command)?.id == .openSwitcher)
        #expect(list.reservedCommand(key: "w", modifiers: .command)?.id == .closeTab)
        #expect(list.reservedCommand(key: "t", modifiers: [.shift, .command])?.id == .reopenTab)
        #expect(list.reservedCommand(key: "n", modifiers: .command)?.id == .newWindow)
        #expect(list.reservedCommand(key: "1", modifiers: .command)?.id == .selectTab1)
        #expect(list.reservedCommand(key: "9", modifiers: .command)?.id == .selectTab9)
        #expect(list.reservedCommand(key: "\t", modifiers: .control)?.id == .nextTab)
        #expect(list.reservedCommand(key: "\t", modifiers: [.control, .shift])?.id == .previousTab)
        #expect(list.command(.openSwitcherFromPage)?.isReserved == false)
    }

    func policy(of tab: Tab) -> WKPreferences.InactiveSchedulingPolicy {
        tab.webView.configuration.preferences.inactiveSchedulingPolicy
    }

    @Test func aNewTabRecordsWhereItsGoing() {
        let tabs = manager()
        let url = URL(string: "https://localhost/page")!
        tabs.newTab(.url(url), activate: true)
        #expect(tabs.list.active?.url == url)
    }
    @Test func onlySwitchingReportsAnActiveChange() throws {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        let first = try #require(tabs.list.activeID)
        tabs.newTab(nil, activate: true)
        var activeChanges = 0
        var changes = 0
        tabs.onActiveChange = { activeChanges += 1 }
        tabs.onChange = { changes += 1 }
        tabs.activate(first)
        #expect(activeChanges == 1)
        #expect(changes == 1)
        tabs.activate(first)
        tabs.newTab(nil, activate: false)
        #expect(activeChanges == 1)
    }
    @Test func everyTabReportsToTheManager() async {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        let background = tabs.newTab(nil, activate: false)
        var finished: [Tab] = []
        var changes = 0
        tabs.onLoadFinished = { finished.append($0) }
        tabs.onChange = { changes += 1 }
        await finishLoading(background) {
            background.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/"))
        }
        #expect(finished.count == 1)
        #expect(finished.first === background)
        #expect(changes > 0)
    }
    @Test func theSpareIsRebuiltOffTheCriticalPath() async {
        let profile = Profile.temporary()
        TabManager(profile: profile).newTab(nil, activate: true)
        #expect(profile.spareTab == nil)
        #expect(await eventually { profile.spareTab != nil })
    }

    @Test func backgroundTabsThrottleAndSuspendedTabsSuspend() {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        let background = tabs.newTab(nil, activate: false)
        #expect(policy(of: background) == .throttle)
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        #expect(policy(of: background) == .suspend)
    }
    @Test func aCapturingTabNeverStepsDown() throws {
        let tabs = manager()
        let call = tabs.newTab(nil, activate: true)
        let id = try #require(tabs.list.activeID)
        tabs.isCapturing = { $0 === call }
        tabs.newTab(nil, activate: true)
        #expect(policy(of: call) == .none)

        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: true)
        #expect(tabs.phase(of: id) == .background)
        #expect(policy(of: call) == .none)
    }
    @Test(arguments: [
        (0.0, TabPhase.background, WKPreferences.InactiveSchedulingPolicy.throttle),
        (700.0, TabPhase.suspended, WKPreferences.InactiveSchedulingPolicy.suspend),
    ])
    func theLifecycleResumesWhenCaptureEnds(idle: TimeInterval, phase: TabPhase, expected: WKPreferences.InactiveSchedulingPolicy) throws {
        let tabs = manager()
        let call = tabs.newTab(nil, activate: true)
        let id = try #require(tabs.list.activeID)
        tabs.isCapturing = { $0 === call }
        tabs.newTab(nil, activate: true)
        tabs.isCapturing = { _ in false }
        tabs.updatePhases(now: Date().addingTimeInterval(idle), memoryPressure: false)
        #expect(tabs.phase(of: id) == phase)
        #expect(policy(of: call) == expected)
    }

    @Test func popupsAreActiveTabsOnTheSuppliedConfiguration() throws {
        let tabs = manager()
        let opener = tabs.newTab(nil, activate: true)
        let configuration = opener.webView.configuration
        let popup = try #require(opener.onCreatePopup?(configuration))
        #expect(tabs.list.records.count == 2)
        #expect(tabs.activeTab?.webView === popup)
        #expect(popup.configuration.preferences === configuration.preferences)
        #expect(popup.configuration.websiteDataStore === configuration.websiteDataStore)
    }
    @Test func aPopupClosingItselfClosesItsTab() throws {
        let tabs = manager()
        let opener = tabs.newTab(nil, activate: true)
        let popup = try #require(opener.onCreatePopup?(opener.webView.configuration))
        try #require(tabs.activeTab).webViewDidClose(popup)
        #expect(tabs.list.records.count == 1)
        #expect(tabs.activeTab === opener)
    }
    /// WebKit gives a popup its opener's preferences object, so setting one tab's policy sets both.
    @Test func aPopupSteppingDownCantStepDownTheCallItCameFrom() throws {
        let tabs = manager()
        let call = tabs.newTab(nil, activate: true)
        _ = call.onCreatePopup?(call.webView.configuration)
        let popup = try #require(tabs.list.activeID)
        tabs.isCapturing = { $0 === call }
        tabs.newTab(nil, activate: true)

        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        #expect(tabs.phase(of: popup) == .suspended)
        #expect(policy(of: call) == .none)

        tabs.isCapturing = { _ in false }
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        #expect(policy(of: call) == .suspend)
    }

    /// `evaluateJavaScript` carries a user gesture, so this is a real popup with a real link to its opener.
    @Test func aRealPopupKeepsItsOpenerAndReturnsToItWhenItCloses() async throws {
        let tabs = manager()
        let opener = tabs.newTab(nil, activate: true)
        await finishLoading(opener) { opener.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        let neighbor = tabs.newTab(nil, activate: false)

        #expect(try await opener.webView.evaluateJavaScript("window.open('about:blank') !== null") as? Bool == true)
        #expect(tabs.list.records.count == 3)
        let popup = try #require(tabs.activeTab)
        #expect(popup !== opener)
        #expect(popup !== neighbor)
        #expect(tabs.liveTab(tabs.list.records[2].id) === neighbor)
        #expect(try await popup.webView.evaluateJavaScript("window.opener !== null") as? Bool == true)

        _ = try await popup.webView.evaluateJavaScript("window.close(); 1")
        #expect(await eventually { tabs.list.records.count == 2 })
        #expect(tabs.activeTab === opener)
    }
    /// Three tabs in a row: the opener, its popup, and a neighbor on the popup's right.
    func popupBetweenItsOpenerAndANeighbor(in tabs: TabManager) throws -> (opener: Tab, popup: Tab, neighbor: Tab) {
        let opener = tabs.newTab(nil, activate: true)
        let neighbor = tabs.newTab(nil, activate: false)
        _ = opener.onCreatePopup?(opener.webView.configuration)
        return (opener, try #require(tabs.activeTab), neighbor)
    }
    @Test func closingAPopupWithTheKeyboardStillGoesToItsNeighbor() throws {
        let tabs = manager()
        let (_, _, neighbor) = try popupBetweenItsOpenerAndANeighbor(in: tabs)
        tabs.close(try #require(tabs.list.activeID))
        #expect(tabs.activeTab === neighbor)
    }
    @Test func aPopupWhoseOpenerHasGoneClosesToItsNeighbor() throws {
        let tabs = manager()
        let (_, popup, neighbor) = try popupBetweenItsOpenerAndANeighbor(in: tabs)
        tabs.close(tabs.list.records[0].id)
        popup.webViewDidClose(popup.webView)
        #expect(tabs.activeTab === neighbor)
        #expect(tabs.list.records.count == 1)
    }
    @Test func aBackgroundPopupClosingLeavesTheActiveTabAlone() throws {
        let tabs = manager()
        let (_, popup, neighbor) = try popupBetweenItsOpenerAndANeighbor(in: tabs)
        tabs.activate(tabs.list.records[2].id)
        popup.webViewDidClose(popup.webView)
        #expect(tabs.activeTab === neighbor)
        #expect(tabs.list.records.count == 2)
    }

    /// A page with no window is in a background tab. A dialog from it would cover the active page with
    /// nothing to say which tab asked, so it gets the cancelled answer and nothing shows.
    func backgroundPage(in tabs: TabManager) async -> WKWebView {
        tabs.newTab(nil, activate: true)
        let tab = tabs.newTab(nil, activate: false)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        return tab.webView
    }
    @Test func aBackgroundPagesDialogsAreCancelledWithoutShowing() async throws {
        let tabs = manager()
        let page = await backgroundPage(in: tabs)
        #expect(page.window == nil)
        let modal = try await wentModal { () async throws in
            #expect(try await page.evaluateJavaScript("typeof alert('Hello')") as? String == "undefined")
            #expect(try await page.evaluateJavaScript("confirm('Leave?')") as? Bool == false)
            #expect(try await page.evaluateJavaScript("String(prompt('Session expired. Password?', 'guess'))") as? String == "null")
        }
        #expect(!modal)
    }
    @Test func javaScriptDialogsNameTheSite() async throws {
        let tab = await tabWith(html: "<p>x</p>") // https://localhost/
        var seen: [NSAlert] = []
        tab.alertSeam = { seen.append($0); return .alertFirstButtonReturn }
        _ = try await tab.webView.evaluateJavaScript("alert('A'); confirm('B'); prompt('C'); 1")
        #expect(seen.map(\.messageText) == Array(repeating: "localhost says", count: 3))
        #expect(seen.map(\.informativeText) == ["A", "B", "C"])
        let blank = Tab(profile: .temporary())
        await finishLoading(blank) { blank.webView.loadHTMLString("<p>x</p>", baseURL: nil) }
        seen = []
        blank.alertSeam = { seen.append($0); return .alertFirstButtonReturn }
        _ = try await blank.webView.evaluateJavaScript("alert('D'); 1")
        #expect(seen.first?.messageText == "This page says" && seen.first?.informativeText == "D")
    }
    @Test func bringingATabBackIsntAVisit() async throws {
        let server = LocalServer()
        server.routes = ["/": .body(Data("<title>Home</title>".utf8), headers: ["Content-Type": "text/html"])]
        try await server.start()
        defer { server.stop() }
        let profile = Profile.temporary()
        await profile.history.record(url: server.url("/"), title: "Home")
        let snapshot = WindowSnapshot(tabs: [TabRecord(url: server.url("/"))], activeIndex: 0, frame: "")
        let tabs = TabManager(profile: profile, keepsSpare: false, restoring: snapshot)
        let tab = try #require(tabs.activeTab)
        await finishLoading(tab) {}
        try await Task.sleep(for: .milliseconds(300))
        #expect(await profile.history.search("Home", limit: 5).first?.visitCount == 1)
        await finishLoading(tab) { tab.webView.reload() }
        #expect(await eventually { await profile.history.search("Home", limit: 5).first?.visitCount == 2 })
    }
    @Test func aRestoreCancelledByAClickDoesntSwallowTheNextVisit() async throws {
        let server = LocalServer()
        server.routes = [
            "/slow": .stall(sent: Data(), length: nil),
            "/next": .body(Data("<title>Next</title>".utf8), headers: ["Content-Type": "text/html"]),
        ]
        try await server.start()
        defer { server.stop() }
        let profile = Profile.temporary()
        let snapshot = WindowSnapshot(tabs: [TabRecord(url: server.url("/slow"))], activeIndex: 0, frame: "")
        let tabs = TabManager(profile: profile, keepsSpare: false, restoring: snapshot)
        let tab = try #require(tabs.activeTab)
        await finishLoading(tab) { tab.load(.url(server.url("/next"))) }
        #expect(await eventually { await profile.history.search("Next", limit: 5).first?.visitCount == 1 })
    }
    @Test func aRestoreThatFailsDoesntSwallowTheNextVisit() async throws {
        let server = LocalServer()
        server.routes = ["/": .body(Data("<title>Fine</title>".utf8), headers: ["Content-Type": "text/html"])]
        try await server.start()
        defer { server.stop() }
        let profile = Profile.temporary()
        let snapshot = WindowSnapshot(tabs: [TabRecord(url: URL(string: "http://localhost:1/"))], activeIndex: 0, frame: "")
        let tabs = TabManager(profile: profile, keepsSpare: false, restoring: snapshot)
        let tab = try #require(tabs.activeTab)
        await finishLoading(tab) {}
        #expect(tab.isShowingErrorPage)
        await finishLoading(tab) { tab.load(.url(server.url("/"))) }
        #expect(await eventually { await profile.history.search("Fine", limit: 5).first?.visitCount == 1 })
    }
    @Test func aCommandClickedDownloadLeavesNoBlankTab() async throws {
        let server = LocalServer()
        server.routes = [
            "/": .body(Data("<a href=/file.zip>x</a>".utf8), headers: ["Content-Type": "text/html"]),
            "/file.zip": .body(Data("zip".utf8), headers: ["Content-Type": "application/zip", "Content-Disposition": "attachment; filename=file.zip"]),
        ]
        try await server.start()
        defer { server.stop() }
        let tabs = manager()
        let tab = tabs.newTab(nil, activate: true)
        allowDownloads(tabs.profile.downloads)
        await finishLoading(tab) { tab.load(.url(server.url("/"))) }
        tab.webView(tab.webView, decidePolicyFor: FakeNavigationAction(url: server.url("/file.zip"), type: .linkActivated, modifiers: .command)) { _ in }
        #expect(tabs.list.records.count == 2)
        #expect(await eventually { tabs.list.records.count == 1 })
        #expect(tabs.activeTab === tab)
    }
    @Test func aBackgroundPageCantOpenAFilePanel() async throws {
        let tabs = manager()
        let page = await backgroundPage(in: tabs)
        let script = """
        return await new Promise(resolve => {
            const input = document.createElement('input');
            input.type = 'file';
            input.addEventListener('cancel', () => resolve('cancelled'));
            input.addEventListener('change', () => resolve('chosen'));
            setTimeout(() => resolve('no answer'), 3000);
            input.click();
        });
        """
        let modal = try await wentModal { () async throws in
            #expect(try await page.callAsyncJavaScript(script, contentWorld: .page) as? String == "cancelled")
        }
        #expect(!modal)
    }
    @Test func aPageWithNoWindowIsDeniedWithoutAPrompt() async {
        var decision: WKPermissionDecision?
        let modal = await wentModal {
            Permissions.ask(host: "example.com", type: .camera, in: nil) { decision = $0 }
        }
        #expect(!modal)
        #expect(decision == .deny)
    }

    @Test func commandClickingALinkOpensABackgroundTab() throws {
        let tabs = manager()
        let tab = tabs.newTab(nil, activate: true)
        let url = URL(string: "https://localhost/next")!
        var decision: WKNavigationActionPolicy?
        tab.webView(tab.webView, decidePolicyFor: FakeNavigationAction(url: url, type: .linkActivated, modifiers: .command)) { decision = $0 }
        #expect(decision == .cancel)
        #expect(tabs.list.records.count == 2)
        #expect(tabs.activeTab === tab)
        #expect(tabs.liveTab(tabs.list.records[1].id)?.webView.url == url)
    }
    /// The certificate question trusts `mainFrameURL`, and this link goes to another tab. A page can't fake the flag, so only a click gets here.
    @Test func commandClickingALinkLeavesThePageWhereItIs() {
        let tabs = manager()
        let tab = tabs.newTab(nil, activate: true)
        let page = URL(string: "https://page.example/")!
        tab.mainFrameURL = page
        let action = FakeNavigationAction(url: URL(string: "https://localhost/next")!, type: .linkActivated, modifiers: .command, target: FakeMainFrame())
        tab.webView(tab.webView, decidePolicyFor: action) { _ in }
        #expect(tab.mainFrameURL == page)
    }
    @Test(arguments: [
        (WKNavigationType.linkActivated, NSEvent.ModifierFlags(), false, WKNavigationActionPolicy.allow),
        (WKNavigationType.other, NSEvent.ModifierFlags.command, false, WKNavigationActionPolicy.allow),
        (WKNavigationType.linkActivated, NSEvent.ModifierFlags(), true, WKNavigationActionPolicy.download),
    ])
    func otherNavigationsStayInTheTab(type: WKNavigationType, modifiers: NSEvent.ModifierFlags, download: Bool, expected: WKNavigationActionPolicy) {
        let tabs = manager()
        let tab = tabs.newTab(nil, activate: true)
        let action = FakeNavigationAction(url: URL(string: "https://localhost/next")!, type: type, modifiers: modifiers, shouldDownload: download)
        var decision: WKNavigationActionPolicy?
        tab.webView(tab.webView, decidePolicyFor: action) { decision = $0 }
        #expect(decision == expected)
        #expect(tabs.list.records.count == 1)
    }
    @Test func commandClickingAPopupLinkOpensABackgroundTabInstead() {
        let tabs = manager()
        let tab = tabs.newTab(nil, activate: true)
        let action = FakeNavigationAction(url: URL(string: "https://localhost/next")!, type: .linkActivated, modifiers: .command)
        let popup = tab.webView(tab.webView, createWebViewWith: tab.webView.configuration, for: action, windowFeatures: keptWindowFeatures())
        #expect(popup == nil)
        #expect(tabs.list.records.count == 2)
        #expect(tabs.activeTab === tab)
    }

    @Test func aSavedTabKeepsItsPlaceAndComesBackWithItsHistory() async throws {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        let tab = tabs.newTab(nil, activate: false)
        let id = tabs.list.records[1].id
        let two = URL(string: "data:text/html,<title>Two</title>")!
        await finishLoading(tab) { tab.load(.url(URL(string: "data:text/html,<title>One</title>")!)) }
        await finishLoading(tab) { tab.load(.url(two)) }
        #expect(await eventually { tab.webView.title == "Two" })
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        tabs.updatePhases(now: Date().addingTimeInterval(800), memoryPressure: true)

        let record = try #require(tabs.list.records.first { $0.id == id })
        #expect(record.url == tab.webView.url)
        #expect(record.title == "Two")
        #expect(record.interactionState != nil)

        tabs.activate(id)
        let rebuilt = try #require(tabs.liveTab(id))
        #expect(rebuilt !== tab)
        #expect(rebuilt.webView.url == record.url)
        #expect(rebuilt.webView.canGoBack)
    }
    /// `loadHTMLString` stands in for a failed load: neither leaves a history entry, so the state restores to nothing.
    @Test func aTabWithNothingToRestoreGoesBackToItsAddress() async {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        let tab = tabs.newTab(nil, activate: false)
        let id = tabs.list.records[1].id
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/page")) }
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        tabs.updatePhases(now: Date().addingTimeInterval(800), memoryPressure: true)
        #expect(tabs.list.records[1].interactionState != nil)
        tabs.activate(id)
        #expect(tabs.activeTab?.webView.url?.absoluteString == "https://localhost/page")
    }
    @Test func closingIntoASavedNeighborRebuildsIt() throws {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        tabs.newTab(.url(URL(string: "about:blank")!), activate: false)
        let saved = tabs.list.records[1].id
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        tabs.updatePhases(now: Date().addingTimeInterval(800), memoryPressure: true)
        tabs.close(try #require(tabs.list.activeID))
        #expect(tabs.list.activeID == saved)
        #expect(tabs.activeTab != nil)
        #expect(tabs.phase(of: saved) == .active)
    }
    @Test func reopeningBringsBackTheClosedPage() async throws {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/page")) }
        let id = try #require(tabs.list.activeID)
        tabs.close(id)
        #expect(tabs.liveTab(id) == nil)
        tabs.reopenLast()
        #expect(tabs.list.activeID == id)
        #expect(tabs.activeTab != nil)
        #expect(tabs.phase(of: id) == .active)
        #expect(tabs.list.active?.url?.absoluteString == "https://localhost/page")
    }
}

/// `WKNavigationAction` can't be built by hand, and its `dealloc` crashes on an instance WebKit
/// didn't make, so every fake is kept for the life of the test process.
final class FakeNavigationAction: WKNavigationAction {
    private let url: URL
    private let type: WKNavigationType
    private let modifiers: NSEvent.ModifierFlags
    private let shouldDownload: Bool
    private let target: WKFrameInfo?

    init(url: URL, type: WKNavigationType, modifiers: NSEvent.ModifierFlags, shouldDownload: Bool = false, target: WKFrameInfo? = nil) {
        self.url = url
        self.type = type
        self.modifiers = modifiers
        self.shouldDownload = shouldDownload
        self.target = target
        super.init()
        _ = Unmanaged.passRetained(self)
    }

    override var request: URLRequest { URLRequest(url: url) }
    override var navigationType: WKNavigationType { type }
    override var modifierFlags: NSEvent.ModifierFlags { modifiers }
    override var shouldPerformDownload: Bool { shouldDownload }
    override var targetFrame: WKFrameInfo? { target }
}

/// Kept for the same reason as `FakeNavigationAction`.
final class FakeMainFrame: WKFrameInfo {
    override init() {
        super.init()
        _ = Unmanaged.passRetained(self)
    }
    override var isMainFrame: Bool { true }
}

/// Kept for the same reason as `FakeNavigationAction`.
func keptWindowFeatures() -> WKWindowFeatures {
    let features = WKWindowFeatures()
    _ = Unmanaged.passRetained(features)
    return features
}
