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

    private func text(of pill: DomainPill) -> String? {
        pill.subviewsDeep.compactMap { $0 as? NSTextField }.first?.stringValue
    }
    @Test func restingInTheCornerShowsTheHostUntilThePointerLeaves() async {
        let pill = DomainPill(frame: .zero)
        pill.reducesMotion = { true }
        pill.visibleFor = .milliseconds(20)
        pill.show(url: URL(string: "https://example.com"))
        #expect(await eventually { pill.isHidden })
        pill.isPointerInCorner = true
        #expect(!pill.isHidden)
        #expect(text(of: pill) == "example.com")
        pill.isPointerInCorner = false
        #expect(pill.isHidden)
    }
    @Test func theCornerHoldsThePillPastItsTime() async throws {
        let pill = DomainPill(frame: .zero)
        pill.reducesMotion = { true }
        pill.visibleFor = .milliseconds(20)
        pill.show(url: URL(string: "https://example.com"))
        pill.isPointerInCorner = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(!pill.isHidden)
        pill.isPointerInCorner = false
        #expect(pill.isHidden)
    }
    @Test func leavingTheCornerLeavesAShowStillOnItsClock() {
        let pill = DomainPill(frame: .zero)
        pill.show(url: URL(string: "https://example.com"))
        pill.isPointerInCorner = true
        pill.isPointerInCorner = false
        #expect(!pill.isHidden)
    }
    @Test func aNoticeInTheCornerGivesWayToTheHost() async {
        let pill = DomainPill(frame: .zero)
        pill.visibleFor = .milliseconds(20)
        pill.show(url: URL(string: "https://example.com"))
        pill.isPointerInCorner = true
        pill.showNotice("a.zip")
        #expect(text(of: pill) == "a.zip")
        #expect(await eventually { text(of: pill) == "example.com" })
        #expect(!pill.isHidden)
    }
    @Test func theCornerShowsNothingWhileTheRailIsOpenAndThePillComesBackAfter() {
        let pill = DomainPill(frame: .zero)
        pill.show(url: URL(string: "https://example.com"))
        pill.isSuppressed = true
        pill.isPointerInCorner = true
        #expect(pill.isHidden)
        pill.isSuppressed = false
        #expect(!pill.isHidden)
    }
    @Test func theCornerShowsNothingWithoutAPage() {
        let pill = DomainPill(frame: .zero)
        pill.isPointerInCorner = true
        #expect(pill.isHidden)
    }
    @Test func movingFromTheCornerOntoThePillKeepsIt() async {
        let pill = DomainPill(frame: .zero)
        pill.reducesMotion = { true }
        pill.visibleFor = .milliseconds(20)
        pill.show(url: URL(string: "https://example.com"))
        #expect(await eventually { pill.isHidden })
        pill.isPointerInCorner = true
        pill.mouseEntered(with: event(.mouseEntered))
        pill.isPointerInCorner = false
        #expect(!pill.isHidden)
        pill.mouseExited(with: event(.mouseExited))
        #expect(pill.isHidden)
    }
    @Test func dwellingInTheCornerBringsThePillUp() async {
        let pill = DomainPill(frame: .zero)
        pill.reducesMotion = { true }
        pill.visibleFor = .milliseconds(20)
        pill.show(url: URL(string: "https://example.com"))
        #expect(await eventually { pill.isHidden })
        pill.corner.mouseEntered(with: pointerEvent(.mouseEntered))
        #expect(await eventually { !pill.isHidden })
        pill.corner.mouseExited(with: pointerEvent(.mouseExited))
        #expect(pill.isHidden)
    }
    @Test func hoveringAPillCaughtFadingKeepsIt() async throws {
        let pill = DomainPill(frame: .zero)
        pill.reducesMotion = { false }
        pill.visibleFor = .milliseconds(20)
        pill.show(url: URL(string: "https://example.com"))
        #expect(await eventually { pill.isFadingOut })
        pill.mouseEntered(with: event(.mouseEntered))
        #expect(!pill.isFadingOut)
        #expect(pill.alphaValue == 1)
        try await Task.sleep(for: .milliseconds(400))
        #expect(!pill.isHidden)
    }
    @Test func theCornerNeverTakesClicks() {
        let pill = DomainPill(frame: .zero)
        pill.corner.frame = NSRect(origin: .zero, size: DomainPill.cornerSize)
        #expect(pill.corner.hitTest(NSPoint(x: 20, y: 5)) == nil)
    }

    /// A pill whose load has run past its delay, so it shows the host with the bar under it.
    private func pillShowingALoad(to url: URL, progress: Double = 0.3) async throws -> DomainPill {
        let pill = DomainPill(frame: .zero)
        pill.reducesMotion = { true }
        pill.progressDelay = .milliseconds(20)
        pill.update(url: url, progress: progress, isLoading: true)
        try #require(await eventually { pill.showsProgress })
        return pill
    }
    @Test func aQuickLoadNeverShowsTheBar() async throws {
        let pill = DomainPill(frame: .zero)
        pill.progressDelay = .milliseconds(200)
        let url = URL(string: "https://example.com")
        pill.update(url: url, progress: 0.3, isLoading: true)
        pill.update(url: url, progress: 1, isLoading: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(pill.isHidden)
        #expect(!pill.showsProgress)
        #expect(pill.bar.isHidden)
    }
    @Test func aSlowLoadShowsItsHostWithTheBar() async {
        let pill = DomainPill(frame: .zero)
        pill.progressDelay = .milliseconds(20)
        let url = URL(string: "https://docs.example.com/a")!
        pill.update(url: url, progress: 0.3, isLoading: true)
        #expect(pill.isHidden)
        #expect(await eventually { pill.showsProgress })
        #expect(!pill.isHidden)
        #expect(text(of: pill) == "docs.example.com")
        #expect(!pill.bar.isHidden)
        #expect(pill.bar.fraction == 0.3)
        #expect(pill.currentURL == url)
    }
    @Test func theBarFollowsTheLoadAndARedirectChangesTheHost() async throws {
        let url = URL(string: "https://docs.example.com/a")!
        let pill = try await pillShowingALoad(to: url)
        pill.update(url: url, progress: 0.7, isLoading: true)
        #expect(pill.bar.fraction == 0.7)
        let redirect = URL(string: "https://b.example/")!
        pill.update(url: redirect, progress: 0.8, isLoading: true)
        #expect(text(of: pill) == "b.example")
        #expect(pill.currentURL == redirect)
    }
    @Test func aLoadThatShowedSettlesIntoTheHost() async throws {
        let url = URL(string: "https://docs.example.com/a")!
        let pill = try await pillShowingALoad(to: url)
        pill.visibleFor = .milliseconds(50)
        pill.update(url: url, progress: 1, isLoading: false)
        #expect(!pill.showsProgress)
        #expect(pill.bar.isHidden) // Motion is off in tests, so the bar fills, fades and goes at once
        #expect(!pill.isHidden)
        #expect(text(of: pill) == "docs.example.com")
        #expect(await eventually { pill.isHidden })
    }
    @Test func aLoadThatEndsElsewhereSettlesOnWhereThePageIs() async throws {
        let pill = try await pillShowingALoad(to: URL(string: "https://b.example/")!)
        let landed = URL(string: "https://a.example/")!
        pill.update(url: landed, progress: 1, isLoading: false)
        #expect(text(of: pill) == "a.example")
        #expect(pill.currentURL == landed)
    }
    @Test func aLoadThatEndsElsewhereWhileAHostIsOnItsClockNamesWhereThePageIs() async throws {
        let pill = DomainPill(frame: .zero)
        pill.progressDelay = .milliseconds(20)
        pill.show(url: URL(string: "https://a.example/")) // the last page's host, still on its 2 s clock
        pill.update(url: URL(string: "https://b.example/"), progress: 0.3, isLoading: true)
        #expect(await eventually { pill.showsProgress })
        let landed = URL(string: "https://c.example/")!
        pill.update(url: landed, progress: 1, isLoading: false)
        #expect(pill.currentURL == landed)
        #expect(text(of: pill) == "c.example") // the pill names the address a click copies
    }
    @Test func aFailedLoadsErrorPageBringsNoBarBack() async throws {
        let url = URL(string: "https://docs.example.com/a")!
        let pill = try await pillShowingALoad(to: url)
        pill.update(url: url, progress: 1, isLoading: false)
        pill.update(url: url, progress: 0.1, isLoading: true)
        pill.update(url: url, progress: 1, isLoading: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!pill.showsProgress)
        #expect(pill.bar.isHidden)
        #expect(!pill.isHidden) // still on its 2 s clock
    }
    @Test func aNoticeDuringALoadGivesWayToTheHost() async throws {
        let pill = try await pillShowingALoad(to: URL(string: "https://docs.example.com/a")!)
        pill.visibleFor = .milliseconds(30)
        pill.showNotice("a.zip")
        #expect(text(of: pill) == "a.zip")
        #expect(!pill.bar.isHidden)
        #expect(await eventually { text(of: pill) == "docs.example.com" })
        #expect(!pill.isHidden)
    }
    @Test func theRailHidesALoadAndClosingItBringsItBack() async throws {
        let url = URL(string: "https://docs.example.com/a")!
        let pill = try await pillShowingALoad(to: url)
        pill.isSuppressed = true
        #expect(pill.isHidden)
        pill.update(url: url, progress: 0.6, isLoading: true)
        #expect(pill.isHidden)
        pill.isSuppressed = false
        #expect(!pill.isHidden)
        #expect(!pill.bar.isHidden)
        #expect(pill.bar.fraction == 0.6)
    }
    @Test func aLoadEndingBehindTheRailStaysHidden() async throws {
        let url = URL(string: "https://docs.example.com/a")!
        let pill = try await pillShowingALoad(to: url)
        pill.isSuppressed = true
        pill.update(url: url, progress: 1, isLoading: false)
        #expect(pill.isHidden)
        #expect(pill.bar.isHidden)
        pill.isSuppressed = false
        #expect(pill.isHidden)
    }
    @Test func anotherPageDropsTheLastPagesBar() async throws {
        let pill = try await pillShowingALoad(to: URL(string: "https://a.example/")!)
        pill.showPage(url: URL(string: "https://b.example/"), progress: 1, isLoading: false)
        #expect(!pill.showsProgress)
        #expect(pill.bar.isHidden)
        #expect(text(of: pill) == "b.example")
    }
    @Test func anotherPageStillLoadingShowsItsBarAfterTheDelay() async throws {
        let pill = try await pillShowingALoad(to: URL(string: "https://a.example/")!)
        pill.showPage(url: URL(string: "https://b.example/"), progress: 0.4, isLoading: true)
        #expect(!pill.showsProgress)
        #expect(pill.bar.isHidden)
        #expect(await eventually { pill.showsProgress })
        #expect(pill.bar.fraction == 0.4)
        #expect(!pill.bar.isHidden)
    }
    @Test func aLoadWithNoHostShowsNothing() async throws {
        let pill = DomainPill(frame: .zero)
        pill.progressDelay = .milliseconds(20)
        pill.update(url: URL(string: "about:blank"), progress: 0.5, isLoading: true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(pill.isHidden)
    }
    @Test func aLoadHoldsThePillWhenThePointerLeavesTheCorner() async throws {
        let pill = try await pillShowingALoad(to: URL(string: "https://docs.example.com/a")!)
        pill.isPointerInCorner = true
        pill.isPointerInCorner = false
        #expect(!pill.isHidden)
    }
    @Test func theBarsRowMakesThePillTallerUntilTheLoadSettles() async {
        let pill = DomainPill(frame: .zero)
        pill.progressDelay = .zero
        let url = URL(string: "https://example.com")!
        pill.show(url: url)
        let idle = pill.fittingSize.height
        pill.update(url: url, progress: 0.3, isLoading: true)
        #expect(await eventually { pill.showsProgress })
        #expect(pill.fittingSize.height > idle)
        pill.update(url: url, progress: 1, isLoading: false)
        #expect(pill.fittingSize.height == idle)
    }

    @Test func theBarStaysInRangeAndNeverTakesClicks() {
        let bar = LoadingBar(frame: NSRect(x: 0, y: 0, width: 100, height: 3))
        bar.set(1.4, animated: false)
        #expect(bar.fraction == 1)
        bar.set(-1, animated: false)
        #expect(bar.fraction == 0)
        #expect(bar.hitTest(NSPoint(x: 50, y: 1)) == nil)
    }
}

@Suite struct DomainPillWiringTests {
    func make(_ tabs: TabManager) -> WindowController {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        return WindowController(appearance: model, tabs: tabs)
    }

    @Test func onlyTheActiveTabsProgressIsReported() {
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
    @Test func thePillSitsAboveThePageAndBelowTheRail() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let content = try #require(controller.window?.contentView)
        let order = content.subviews
        let page = try #require(order.firstIndex(of: tab.pageView))
        let index = try #require(order.firstIndex(of: controller.pill))
        #expect(page < index)
        #expect(try index < #require(order.firstIndex(of: controller.rail)))
        #expect(try index < #require(order.firstIndex(of: controller.switcher)))
    }
    @Test func theCornerSitsAtTheBottomLeftAndReachesUnderThePillsEdgeOnly() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let window = try #require(controller.window)
        let corner = controller.pill.corner
        #expect(corner.superview === window.contentView)
        #expect(corner.frame == NSRect(origin: .zero, size: DomainPill.cornerSize))
        controller.pill.show(url: URL(string: "https://docs.example.com/"))
        window.layoutIfNeeded()
        let pill = controller.pill.frame
        #expect(corner.frame.maxY > pill.minY)
        #expect(corner.frame.maxY < pill.midY)
        #expect(corner.frame.minX < pill.minX)
        #expect(corner.frame.maxX > pill.minX)
    }
    @Test func theVeryCornerBringsUpThePillAndNotTheRail() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let content = try #require(controller.window?.contentView)
        let railStrip = try #require(content.subviews.compactMap { $0 as? EdgeStrip }.first { $0 !== controller.pill.corner })
        #expect(railStrip.frame.minY == DomainPill.cornerSize.height)
        #expect(!railStrip.frame.intersects(controller.pill.corner.frame))
    }
    @Test func pageLinksInTheCornerStillTakeClicks() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let content = try #require(controller.window?.contentView)
        #expect(controller.pill.isHidden)
        for point in [NSPoint(x: 4, y: 4), NSPoint(x: 100, y: 10), NSPoint(x: 30, y: 25)] {
            let hit = content.hitTest(content.convert(point, to: content.superview))
            #expect(hit?.isDescendant(of: tab.pageView) == true, "at \(point)")
        }
    }
    @Test func restingInTheCornerShowsTheActivePagesHostAndTheRailHidesIt() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        controller.pill.reducesMotion = { true }
        controller.pill.visibleFor = .milliseconds(20)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(await eventually { controller.pill.isHidden })
        controller.pill.corner.mouseEntered(with: pointerEvent(.mouseEntered))
        #expect(await eventually { !controller.pill.isHidden })
        #expect(controller.pill.currentURL?.host() == "localhost")
        controller.revealRailImmediately()
        #expect(controller.pill.isHidden)
    }
    @Test func aWindowWithNoPageShowsNothingInTheCorner() async throws {
        let controller = make(TabManager(profile: .temporary(), keepsSpare: false))
        controller.pill.corner.mouseEntered(with: pointerEvent(.mouseEntered))
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.pill.isHidden)
    }
    @Test func aPinnedRailHasThePillBesideIt() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        controller.perform(.toggleRail)
        #expect(!controller.pill.isSuppressed)
        controller.pill.show(url: URL(string: "https://example.com"))
        #expect(!controller.pill.isHidden)
        window.layoutIfNeeded()
        #expect(controller.pill.frame.minX == Rail.inset + Rail.width + 12)
        #expect(controller.pill.frame.minX > controller.rail.frame.maxX)
        let middle = NSPoint(x: controller.pill.frame.midX, y: controller.pill.frame.midY)
        #expect(content.hitTest(content.convert(middle, to: content.superview)) === controller.pill)
        controller.perform(.toggleRail)
        window.layoutIfNeeded()
        #expect(controller.pill.frame.minX == 12)
    }
    @Test func aHoverRailStillHidesThePillAndPinningItBringsItBack() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        controller.revealRailImmediately()
        #expect(controller.pill.isSuppressed)
        controller.pill.show(url: URL(string: "https://example.com"))
        #expect(controller.pill.isHidden)
        controller.perform(.toggleRail)
        #expect(!controller.pill.isSuppressed)
        controller.showNotice("a.zip")
        #expect(!controller.pill.isHidden)
    }
    @Test func pinningTurnsTheCornerOffAndLetsGoOfThePointer() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        controller.pill.corner.mouseEntered(with: pointerEvent(.mouseEntered))
        #expect(await eventually { controller.pill.isPointerInCorner })
        controller.perform(.toggleRail)
        #expect(controller.pill.corner.isHidden)
        #expect(!controller.pill.isPointerInCorner)
        controller.perform(.toggleRail)
        #expect(!controller.pill.corner.isHidden)
    }
    @Test func besideAPinnedRailInANarrowWindowThePillStopsShortOfTheBadge() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 480, height: 360))
        controller.perform(.toggleRail)
        controller.pill.show(url: URL(string: "https://a-rather-long-subdomain.of-an-example-host.example.co.uk/"))
        window.layoutIfNeeded()
        #expect(controller.pill.frame.minX == Rail.inset + Rail.width + 12)
        // It shortens to the room it has, not to its padding.
        #expect(controller.pill.frame.maxX == controller.privateBadge.frame.minX - 8)
    }
    @Test func aHostShownBeforeTheFirstLayoutShowsInFull() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 600))
        controller.pill.show(url: URL(string: "https://a-rather-long-subdomain.of-an-example-host.example.co.uk/"))
        window.layoutIfNeeded()
        let label = try #require(controller.pill.subviewsDeep.compactMap { $0 as? NSTextField }.first)
        #expect(label.frame.width >= label.intrinsicContentSize.width)
        #expect(!controller.pill.hasAmbiguousLayout) // with a tie in priorities, any width down to the padding would do
    }
    @Test func inANarrowWindowALongHostFillsThePillsShareOfTheWidth() throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 480, height: 360))
        controller.pill.show(url: URL(string: "https://a-rather-long-subdomain.of-an-example-host.example.co.uk/"))
        window.layoutIfNeeded()
        #expect(controller.pill.frame.width == 480 * 0.6)
    }

    /// A window over one tab whose page has loaded and settled, so no late report from that load lands mid-test.
    private func windowWithASettledPage() async -> (WindowController, Tab) {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(await eventually { !tab.webView.isLoading })
        controller.pill.progressDelay = .milliseconds(10)
        return (controller, tab)
    }
    /// Stands in for WebKit's progress reports with a load that runs past the pill's delay.
    private func startASlowLoad(in tab: Tab, of controller: WindowController) async throws {
        tab.onProgress?(0.5, true)
        try #require(await eventually { controller.pill.showsProgress })
    }
    @Test func aSlowLoadInTheActiveTabShowsTheBarThenTheHost() async {
        let (controller, tab) = await windowWithASettledPage()
        tab.onProgress?(0.5, true)
        #expect(await eventually { controller.pill.showsProgress })
        #expect(controller.pill.bar.fraction == 0.5)
        #expect(controller.pill.currentURL?.host() == "localhost")
        tab.onProgress?(1, false)
        #expect(!controller.pill.showsProgress)
        #expect(!controller.pill.isHidden)
    }
    @Test func aBackgroundTabsLoadLeavesThePillAlone() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let background = tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        controller.pill.progressDelay = .milliseconds(10)
        background.onProgress?(0.5, true)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!controller.pill.showsProgress)
    }
    @Test func switchingTabsDropsTheBar() async throws {
        let (controller, tab) = await windowWithASettledPage()
        try await startASlowLoad(in: tab, of: controller)
        controller.tabs.newTab(nil, activate: true)
        #expect(!controller.pill.showsProgress)
        #expect(controller.pill.bar.isHidden)
        #expect(controller.pill.isHidden) // the new tab has no address
    }
    @Test func aHoverRailHidesALoadAndPinningItBringsTheLoadBack() async throws {
        let (controller, tab) = await windowWithASettledPage()
        let window = try #require(controller.window)
        try await startASlowLoad(in: tab, of: controller)
        controller.revealRailImmediately()
        #expect(controller.pill.isHidden)
        controller.perform(.toggleRail)
        #expect(!controller.pill.isHidden)
        #expect(!controller.pill.bar.isHidden)
        window.layoutIfNeeded()
        #expect(controller.pill.frame.minX == Rail.inset + Rail.width + 12)
        controller.perform(.toggleRail)
        #expect(!controller.pill.isHidden)
        window.layoutIfNeeded()
        #expect(controller.pill.frame.minX == 12)
    }
    @Test func aLoadShowsBesideAPinnedRail() async {
        let (controller, tab) = await windowWithASettledPage()
        controller.perform(.toggleRail)
        tab.onProgress?(0.5, true)
        #expect(await eventually { controller.pill.showsProgress })
        #expect(!controller.pill.isHidden)
        #expect(!controller.pill.bar.isHidden)
    }
    @Test func aQuickLoadShowsTheHostWithoutABar() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = make(tabs)
        #expect(controller.pill.isHidden)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(!controller.pill.isHidden)
        #expect(controller.pill.currentURL?.host() == "localhost")
        #expect(controller.pill.bar.isHidden)
    }
}
