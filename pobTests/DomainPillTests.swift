import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct DomainPillTests {
    @Test func showsTheHostOnly() {
        #expect(DomainPill.displayHost(for: URL(string: "https://docs.example.com/a?b=1")) == "docs.example.com")
    }
    @Test func internationalHostsShowAsPunycodeSoLookalikesStandOut() {
        #expect(DomainPill.displayHost(for: URL(string: "https://xn--pple-43d.com/")) == "xn--pple-43d.com")
        #expect(DomainPill.displayHost(for: URL(string: "https://аpple.com/")) == "xn--pple-43d.com")   // Cyrillic а
        #expect(DomainPill.displayHost(for: URL(string: "https://bücher.example/a")) == "xn--bcher-kva.example")
    }
    @Test func pagesWithNoHostShowNothing() {
        #expect(DomainPill.displayHost(for: URL(string: "about:blank")) == nil)
        #expect(DomainPill.displayHost(for: URL(string: "file:///tmp/a.html")) == nil)
        #expect(DomainPill.displayHost(for: nil) == nil)
    }
    @Test func clickingCopiesTheFullAddress() {
        let pill = DomainPill(frame: .zero)
        let url = URL(string: "https://docs.example.com/a?b=1")!
        pill.show(url: url)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pill.copyURL(to: board)
        #expect(board.string(forType: .string) == url.absoluteString)
    }
    @Test func stayingOutOfTheWayWhileTheRailIsOpen() {
        let pill = DomainPill(frame: .zero)
        pill.isSuppressed = true
        pill.show(url: URL(string: "https://example.com"))
        #expect(pill.isHidden)
    }
    @Test func loadingLineFollowsProgressAndHidesWhenDone() {
        let line = LoadingLine(frame: NSRect(x: 0, y: 0, width: 100, height: 2))
        line.update(progress: 0.4, isLoading: true)
        #expect(line.fraction == 0.4)
        line.update(progress: 1, isLoading: false)
        #expect(line.fraction == 0)
    }

    @Test func aPageWithNoHostHidesTheOldHost() {
        let pill = DomainPill(frame: .zero)
        pill.show(url: URL(string: "https://example.com"))
        #expect(!pill.isHidden)
        pill.show(url: URL(string: "about:blank"))
        #expect(pill.isHidden)
    }
    @Test func openingTheRailHidesTheShownPillAtOnce() {
        let pill = DomainPill(frame: .zero)
        pill.show(url: URL(string: "https://example.com"))
        pill.isSuppressed = true
        #expect(pill.isHidden)
    }
    @Test func aNoticeLeavesThePageAddressAlone() {
        let pill = DomainPill(frame: .zero)
        pill.showNotice("a.zip")
        #expect(!pill.isHidden)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pill.copyURL(to: board)
        #expect(board.string(forType: .string) == nil)

        let url = URL(string: "https://example.com/x")!
        pill.show(url: url)
        pill.showNotice("a.zip")
        #expect(pill.currentURL == url)
    }
    private func event(_ type: NSEvent.EventType) -> NSEvent {
        switch type {
        case .leftMouseDown:
            NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        default:
            NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
        }
    }
    @Test func copiedFadesAfterItsTimeEvenWithThePointerInside() async {
        let pill = DomainPill(frame: .zero)
        pill.reducesMotion = { true } // the fade's completion needs an awake display
        pill.pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pill.copiedFor = .milliseconds(50)
        pill.show(url: URL(string: "https://example.com"))
        pill.mouseEntered(with: event(.mouseEntered))
        pill.mouseDown(with: event(.leftMouseDown))
        #expect(!pill.isHidden)
        #expect(await eventually { pill.isHidden })
    }
    @Test func hoverDoesNotStickAfterThePillIsHiddenUnderThePointer() async {
        let pill = DomainPill(frame: .zero)
        pill.reducesMotion = { true }
        pill.visibleFor = .milliseconds(50)
        pill.show(url: URL(string: "https://example.com"))
        pill.mouseEntered(with: event(.mouseEntered))
        pill.isSuppressed = true
        pill.isSuppressed = false
        pill.show(url: URL(string: "https://example.com"))
        #expect(await eventually { pill.isHidden })
    }
    @Test func theLoadingLineNeverTakesClicks() {
        let line = LoadingLine(frame: NSRect(x: 0, y: 0, width: 100, height: 2))
        line.update(progress: 0.5, isLoading: true)
        #expect(line.hitTest(NSPoint(x: 10, y: 1)) == nil)
    }
}

@Suite struct DomainPillWiringTests {
    func make(_ tabs: TabManager) -> WindowController {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        return WindowController(appearance: model, tabs: tabs)
    }

    @Test func onlyTheActiveTabsProgressReachesTheLine() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let background = tabs.newTab(nil, activate: true)
        let active = tabs.newTab(nil, activate: true)
        var seen: [Double] = []
        tabs.onActiveProgress = { progress, _ in seen.append(progress) }
        background.onProgress?(0.2, true)
        active.onProgress?(0.7, true)
        #expect(seen == [0.7])
    }
    @Test func aTabReportsItsLoadProgress() async {
        let tab = Tab(profile: .temporary())
        var sawLoading = false
        tab.onProgress = { _, isLoading in sawLoading = sawLoading || isLoading }
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(sawLoading)
    }
    @Test func aFinishedLoadInTheActiveTabShowsThePill() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        #expect(controller.pill.isHidden)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(!controller.pill.isHidden)
        #expect(controller.pill.currentURL?.host() == "localhost")
    }
    @Test func thePillStaysHiddenWhileTheRailShows() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        controller.revealRailImmediately()
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(controller.pill.isHidden)
    }
    @Test func theLineAndPillSitAboveThePageAndBelowTheRail() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let content = try #require(controller.window?.contentView)
        let order = content.subviews
        let page = try #require(order.firstIndex(of: tab.pageView))
        for view in [controller.pill, controller.loadingLine] as [NSView] {
            let index = try #require(order.firstIndex(of: view))
            #expect(page < index)
            #expect(try index < #require(order.firstIndex(of: controller.rail)))
            #expect(try index < #require(order.firstIndex(of: controller.switcher)))
        }
    }
}
