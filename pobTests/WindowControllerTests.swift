import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct WindowControllerTests {
    func emptyTabs() -> TabManager { TabManager(profile: .temporary(), keepsSpare: false) }

    func make(_ tabs: TabManager) -> (WindowController, AppearanceModel) {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        return (WindowController(appearance: model, tabs: tabs), model)
    }

    func make() -> (WindowController, AppearanceModel) {
        let tabs = emptyTabs()
        tabs.newTab(nil, activate: true)
        return make(tabs)
    }

    @Test func windowIsClearAndChromeless() throws {
        let (controller, _) = make()
        let window = try #require(controller.window)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
    }
    @Test func windowButtonsStartHidden() throws {
        let (controller, _) = make()
        #expect(controller.window?.standardWindowButton(.closeButton)?.isHidden == true)
    }
    @Test func appearanceDrivesThePage() throws {
        let (controller, model) = make()
        let webView = try #require(controller.tab?.webView)
        #expect(abs(webView.alphaValue - 0.82) < 0.0001)
        model.toggleSnap()
        #expect(webView.alphaValue == 1)
    }
    @Test func privateBlurIsInUseOnThisMac() {
        #expect(!make().0.usesFallbackBlur)
    }
    @Test func snapCommandReachesTheModel() {
        let (controller, model) = make()
        controller.perform(.snapOpaque)
        #expect(model.isSnappedOpaque)
    }

    /// With nothing on screen and no page yet, a fully clear window can't be seen at all.
    @Test func blankWindowIsVisibleAndSnappingMakesItSolid() {
        let (controller, model) = make()
        #expect(controller.backdrop.alphaValue == 0.25)
        #expect(controller.backdrop.superview?.subviews.first === controller.backdrop)
        model.toggleSnap()
        #expect(controller.backdrop.alphaValue == 1)
    }

    @Test func theActivePageFillsTheWindowUnderTheTopStrip() throws {
        let tabs = emptyTabs()
        let first = tabs.newTab(nil, activate: true)
        let (controller, _) = make(tabs)
        let content = try #require(controller.window?.contentView)
        #expect(first.webView.frame.size == content.bounds.size)

        let second = tabs.newTab(nil, activate: true)
        #expect(first.pageView.superview == nil)
        #expect(second.pageView.superview === content)
        #expect(second.webView.frame.size == content.bounds.size)
        let strip = try #require(content.subviews.firstIndex { $0 is TopDragStrip })
        #expect(content.subviews[strip - 1] === second.pageView)
        #expect(controller.tab === second)
    }
    @Test func theIncomingPageTakesTheWindowsCurrentLook() {
        let tabs = emptyTabs()
        tabs.newTab(nil, activate: true)
        let (controller, _) = make(tabs)
        controller.perform(.toggleRail)
        let incoming = tabs.newTab(nil, activate: true)
        #expect(abs(incoming.webView.alphaValue - 0.82) < 0.0001)
        #expect(incoming.webView.obscuredContentInsets.left == 256)
        #expect(controller.tab === incoming)
    }
    @Test func aCapturingPageKeepsRunningBehindTheActivePage() throws {
        let tabs = emptyTabs()
        let call = tabs.newTab(nil, activate: true)
        let callID = try #require(tabs.list.activeID)
        let (controller, _) = make(tabs)
        let content = try #require(controller.window?.contentView)
        tabs.isCapturing = { $0 === call }

        let other = tabs.newTab(nil, activate: true)
        let otherID = try #require(tabs.list.activeID)
        #expect(call.pageView.superview === content)
        #expect(call.pageView.alphaValue == 0)
        #expect(!call.pageView.isHidden)
        #expect(try #require(content.subviews.firstIndex(of: call.pageView)) < #require(content.subviews.firstIndex(of: other.pageView)))

        tabs.activate(callID)
        #expect(call.pageView.alphaValue == 1)
        #expect(abs(call.webView.alphaValue - 0.82) < 0.0001)
        #expect(other.pageView.superview == nil)
        #expect(try #require(content.subviews.firstIndex { $0 is TopDragStrip }) - 1 == content.subviews.firstIndex(of: call.pageView))

        tabs.activate(otherID)
        tabs.isCapturing = { _ in false }
        tabs.updatePhases(now: .now, memoryPressure: false)
        #expect(call.pageView.superview == nil)
        #expect(controller.tab === other)
    }
    @Test func closingACapturingBackgroundTabTakesItOutOfTheWindow() throws {
        let tabs = emptyTabs()
        let call = tabs.newTab(nil, activate: true)
        let id = try #require(tabs.list.activeID)
        let (controller, _) = make(tabs)
        tabs.isCapturing = { $0 === call }
        let other = tabs.newTab(nil, activate: true)
        #expect(call.pageView.superview != nil)
        tabs.close(id)
        #expect(call.pageView.superview == nil)
        #expect(controller.tab === other)
    }
    /// WebKit docks the inspector beside the page. Left behind, it would show through the next translucent page.
    @Test func whateverWebKitDocksBesideThePageLeavesWithIt() throws {
        let tabs = emptyTabs()
        let first = tabs.newTab(nil, activate: true)
        let id = try #require(tabs.list.activeID)
        let (controller, _) = make(tabs)
        let docked = NSView()
        try #require(first.webView.superview).addSubview(docked)

        tabs.newTab(nil, activate: true)
        #expect(docked.window == nil)
        tabs.activate(id)
        #expect(docked.window === controller.window)
    }

    @Test func switchingTabsRefreshesTheRail() async throws {
        let tabs = emptyTabs()
        let first = tabs.newTab(nil, activate: true)
        let id = try #require(tabs.list.activeID)
        await finishLoading(first) { first.load(.url(URL(string: "data:text/html,one")!)) }
        await finishLoading(first) { first.load(.url(URL(string: "data:text/html,two")!)) }
        let (controller, _) = make(tabs)
        #expect(controller.rail.addressField.stringValue == "data:text/html,two")
        #expect(backButton(in: controller)?.isEnabled == true)

        tabs.newTab(nil, activate: true)
        #expect(controller.rail.addressField.stringValue == "")
        #expect(backButton(in: controller)?.isEnabled == false)

        tabs.activate(id)
        #expect(controller.rail.addressField.stringValue == "data:text/html,two")
        #expect(backButton(in: controller)?.isEnabled == true)
    }
    @Test func theActiveTabsNavigationReachesTheRail() async throws {
        let (controller, _) = make()
        let tab = try #require(controller.tab)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/page")) }
        #expect(controller.rail.addressField.stringValue == "https://localhost/page")
    }
    @Test func aBackgroundTabsNavigationLeavesTheRailAlone() async throws {
        let tabs = emptyTabs()
        let active = tabs.newTab(nil, activate: true)
        let background = tabs.newTab(nil, activate: false)
        await finishLoading(active) { active.load(.url(URL(string: "data:text/html,active")!)) }
        let (controller, _) = make(tabs)

        await finishLoading(background) { background.load(.url(URL(string: "data:text/html,one")!)) }
        await finishLoading(background) { background.load(.url(URL(string: "data:text/html,two")!)) }
        #expect(background.webView.canGoBack)
        #expect(controller.rail.addressField.stringValue == "data:text/html,active")
        #expect(backButton(in: controller)?.isEnabled == false)
    }

    /// Page code that reads its size while loading, like `matchMedia`, needs a real one even in a background tab.
    @Test func aPageOpenedInTheBackgroundLoadsAtThePagesSize() async throws {
        let tabs = emptyTabs()
        let active = tabs.newTab(nil, activate: true)
        let (controller, _) = make(tabs)
        active.onOpenLink?(URLRequest(url: URL(string: "data:text/html,page")!), false)
        let background = try #require(tabs.liveTab(tabs.list.records[1].id))
        #expect(background.pageView.frame == active.pageView.frame)
        #expect(background.webView.frame.size == active.webView.frame.size)
        #expect(await eventually {
            (try? await background.webView.evaluateJavaScript("innerWidth")) as? Int == 1200
        })
        #expect(try await background.webView.evaluateJavaScript("matchMedia('(max-width: 600px)').matches") as? Bool == false)
        #expect(controller.tab === active)
    }

    /// `.transient` only reacts to the user, and a popup closing can move the active tab with the popover still up.
    @Test func switchingTabsClosesAnOpenPopover() throws {
        let tabs = emptyTabs()
        tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: false)
        let (controller, _) = make(tabs)
        controller.perform(.signIn)
        #expect(controller.openPopover != nil)
        tabs.activateNext()
        #expect(controller.openPopover == nil)
    }
    /// The closing fade can outlast a quick switch. If its late `popoverDidClose` wiped out the next popover,
    /// that one would stay up untracked, and the next tab switch couldn't close it.
    @Test func aPopoverClosingLateDoesntForgetTheNextOne() throws {
        let (controller, _) = make()
        controller.perform(.signIn)
        let open = try #require(controller.openPopover)
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: NSPopover()))
        #expect(controller.openPopover === open)
        controller.popoverDidClose(Notification(name: NSPopover.didCloseNotification, object: open))
        #expect(controller.openPopover == nil)
    }
    @Test func theSignInPopoverFillsThePageItOpenedOn() async throws {
        let tabs = emptyTabs()
        let first = tabs.newTab(nil, activate: true)
        let second = tabs.newTab(nil, activate: false)
        let form = "<input id=u type=email><input id=p type=password>"
        await finishLoading(first) { first.webView.loadHTMLString(form, baseURL: URL(string: "https://one.localhost/")) }
        await finishLoading(second) { second.webView.loadHTMLString(form, baseURL: URL(string: "https://two.localhost/")) }
        let (controller, _) = make(tabs)
        controller.perform(.signIn)
        let popover = try #require(controller.openPopover?.contentViewController as? SignInPopover)

        tabs.activateNext()
        popover.usernameField.stringValue = "a@b.c"
        popover.passwordField.stringValue = "secret"
        let fill = try #require(popover.view.subviewsDeep.compactMap { $0 as? NSButton }.first { $0.title == "Fill" })
        fill.performClick(nil)

        let script = "document.getElementById('p').value"
        #expect(await eventually { (try? await first.webView.evaluateJavaScript(script)) as? String == "secret" })
        #expect(try await second.webView.evaluateJavaScript(script) as? String == "")
        #expect(controller.tab === second)
    }

    /// Otherwise Return would send the old tab's half-typed address to the new tab.
    @Test func switchingTabsMovesTheKeyboardToThePage() async throws {
        let tabs = emptyTabs()
        tabs.newTab(nil, activate: true)
        let other = tabs.newTab(nil, activate: false)
        await finishLoading(other) { other.load(.url(URL(string: "data:text/html,other")!)) }
        let (controller, _) = make(tabs)
        controller.perform(.focusAddress)
        controller.rail.addressField.stringValue = "half typed"

        tabs.activateNext()
        #expect(controller.window?.firstResponder === other.webView)
        #expect(controller.rail.addressField.stringValue == "data:text/html,other")
        #expect(!controller.railState.isEditingAddress)
    }

    @Test func tabCommandsDriveTheTabs() throws {
        let tabs = emptyTabs()
        let (controller, _) = make(tabs)
        for _ in 0..<10 { tabs.newTab(nil, activate: false) }
        let ids = tabs.list.records.map(\.id)
        let selectors: [CommandID] = [.selectTab1, .selectTab2, .selectTab3, .selectTab4, .selectTab5, .selectTab6, .selectTab7, .selectTab8]
        for (index, command) in selectors.enumerated() {
            controller.perform(command)
            #expect(tabs.list.activeID == ids[index], "\(command)")
        }
        controller.perform(.selectTab9)
        #expect(tabs.list.activeID == ids.last)

        controller.perform(.selectTab2)
        controller.perform(.nextTab)
        #expect(tabs.list.activeID == ids[2])
        controller.perform(.previousTab)
        #expect(tabs.list.activeID == ids[1])

        controller.perform(.closeTab)
        #expect(tabs.list.records.count == 9)
        controller.perform(.reopenTab)
        #expect(tabs.list.records.count == 10)
        #expect(tabs.list.activeID == ids[1])
    }
    @Test func newWindowAsksForOneAndLeavesThisWindowsTabsAlone() {
        let (controller, _) = make()
        var asked = 0
        controller.onNewWindow = { asked += 1 }
        controller.perform(.newWindow)
        #expect(asked == 1)
        #expect(controller.tabs.list.records.count == 1)
    }
    @Test func commandsAreSafeWithNoTabs() {
        let tabs = emptyTabs()
        let (controller, _) = make(tabs)
        controller.openURL = { _ in } // Screen Recording Settings would open the real System Settings
        for command in CommandID.allCases {
            controller.perform(command)
        }
        #expect(tabs.isEmpty)
        #expect(controller.tab == nil)
    }
    @Test func screenRecordingSettingsOpensItsPane() {
        let (controller, _) = make()
        var opened: [URL] = []
        controller.openURL = { opened.append($0) }
        controller.perform(.screenRecordingSettings)
        #expect(opened == [Permissions.screenRecordingSettingsURL])
    }
    @Test func resettingPermissionsForgetsThisSiteOnly() async throws {
        let (controller, _) = make()
        let tab = try #require(controller.tab)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        let store = tab.profile.siteSettings
        Permissions.remember(false, kinds: [.camera], host: "localhost", in: store)
        Permissions.remember(false, kinds: [.camera], host: "other.com", in: store)
        store["localhost"].allowsInvalidCertificate = true
        store["localhost"].zoom = 1.25
        await finishLoading(tab) { controller.perform(.resetSitePermissions) }
        #expect(Permissions.remembered([.camera], host: "localhost", in: store) == nil)
        #expect(store["localhost"].allowsInvalidCertificate == nil)
        #expect(store["localhost"].zoom == 1.25)
        #expect(Permissions.remembered([.camera], host: "other.com", in: store) == false)
    }
    func expectClose(of window: NSWindow, count: Int, during body: () -> Void) async {
        await confirmation(expectedCount: count) { closed in
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closed() }
            body()
            NotificationCenter.default.removeObserver(observer)
        }
    }
    /// The window owns what ⇧⌘T brings back, so it stays. With nothing left in it, the next ⌘W is what closes it.
    @Test func closingTheLastTabKeepsTheWindowWithTheSwitcherOpen() async throws {
        let (controller, _) = make()
        let window = try #require(controller.window)
        await expectClose(of: window, count: 0) { controller.perform(.closeTab) }
        #expect(controller.tabs.isEmpty)
        #expect(!controller.switcher.isHidden)
        #expect(window.firstResponder === controller.switcher.field.currentEditor())
        #expect(controller.switcher.list.rows.isEmpty)
    }
    @Test func theNextCloseTabClosesTheEmptyWindow() async throws {
        let (controller, _) = make()
        let window = try #require(controller.window)
        controller.perform(.closeTab)
        await expectClose(of: window, count: 1) { controller.perform(.closeTab) }
    }
    @Test func aPageClosingTheLastTabKeepsTheWindowWithTheSwitcherOpen() async throws {
        let (controller, _) = make()
        let window = try #require(controller.window)
        let tab = try #require(controller.tab)
        await expectClose(of: window, count: 0) { tab.webViewDidClose(tab.webView) }
        #expect(controller.tabs.isEmpty)
        #expect(!controller.switcher.isHidden)
    }
    @Test func aPageClosingTheLastTabBehindAnOpenSwitcherLeavesItUp() async throws {
        let (controller, _) = make()
        let window = try #require(controller.window)
        let tab = try #require(controller.tab)
        controller.perform(.openSwitcher)
        await expectClose(of: window, count: 0) { tab.webViewDidClose(tab.webView) }
        #expect(controller.tabs.isEmpty)
        #expect(!controller.switcher.isHidden)
        #expect(window.firstResponder === controller.switcher.field.currentEditor())
    }
    @Test func reopeningBringsTheLastTabBackAndClosesTheSwitcher() async throws {
        let (controller, _) = make()
        let tab = try #require(controller.tab)
        let address = URL(string: "https://localhost/last")!
        await finishLoading(tab) { tab.webView.loadSimulatedRequest(URLRequest(url: address), responseHTML: "<title>Last</title>") }
        let id = controller.tabs.list.activeID
        controller.perform(.closeTab)

        controller.perform(.reopenTab)
        #expect(controller.switcher.isHidden)
        #expect(controller.tabs.list.activeID == id)
        #expect(controller.tabs.list.active?.url == address)
        #expect(controller.tab?.pageView.superview === controller.window?.contentView)
        #expect(controller.window?.firstResponder === controller.tab?.webView)
    }
    /// A page with one history entry may close itself, so this goes through WebKit and not the delegate call alone.
    @Test func aPageThatClosedItselfComesBackToo() async throws {
        let (controller, _) = make()
        let tab = try #require(controller.tab)
        let address = URL(string: "https://localhost/closing")!
        await finishLoading(tab) { tab.webView.loadSimulatedRequest(URLRequest(url: address), responseHTML: "<title>Closing</title>") }
        _ = try await tab.webView.evaluateJavaScript("window.close(); 1")
        #expect(await eventually { controller.tabs.isEmpty })
        #expect(!controller.switcher.isHidden)

        controller.perform(.reopenTab)
        #expect(controller.switcher.isHidden)
        #expect(controller.tabs.list.active?.url == address)
        #expect(controller.window?.firstResponder === controller.tab?.webView)
    }
    @Test func closingAnotherTabLeavesTheWindowOpen() async throws {
        let tabs = emptyTabs()
        tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: true)
        let (controller, _) = make(tabs)
        let window = try #require(controller.window)
        await confirmation(expectedCount: 0) { closed in
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closed() }
            controller.perform(.closeTab)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Nothing about the tab or the bookmark changes when an icon lands, so this is what the rail's guards could lose.
    @Test func aPagesIconReachesItsRowAndItsPinnedBookmark() async throws {
        let (controller, _) = make()
        let tab = try #require(controller.tab)
        let address = URL(string: "https://localhost/icon")!
        let bookmarks = controller.tabs.profile.bookmarks
        bookmarks.toggle(url: address, title: "Icon")
        bookmarks.setPinned(true, id: try #require(bookmarks.all.first).id)
        let favicons = controller.tabs.profile.favicons
        #expect(favicons.image(forHost: "localhost") == nil)

        let page = "<title>Icon</title><link rel=\"icon\" href=\"data:image/png;base64,\(tinyPNG)\">"
        await finishLoading(tab) { tab.webView.loadSimulatedRequest(URLRequest(url: address), responseHTML: page) }
        #expect(await eventually { favicons.image(forHost: "localhost") != nil })

        let icon = try #require(favicons.image(forHost: "localhost"))
        let table = try #require(controller.rail.tabList.subviewsDeep.compactMap { $0 as? NSTableView }.first)
        #expect(await eventually {
            let row = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            return row?.subviews.contains { ($0 as? NSImageView)?.image === icon } == true
                && (controller.rail.pinned.subviews.first as? NSButton)?.image === icon
        })
    }

    private func backButton(in controller: WindowController) -> NSButton? {
        controller.rail.subviewsDeep.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Back" }
    }
}
