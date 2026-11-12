import AppKit
import Foundation
import Testing
@testable import pob

func pillButton(_ label: String, in pill: NavigationPill) -> NSButton? {
    pill.subviewsDeep.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == label }
}

@Suite struct NavigationPillTests {
    @Test func itStartsWithNowhereToGo() throws {
        let pill = NavigationPill()
        let back = try #require(pillButton("Back", in: pill))
        let forward = try #require(pillButton("Forward", in: pill))
        #expect(!back.isEnabled)
        #expect(!forward.isEnabled)
    }

    @Test func itFollowsWhatThePageCanDo() throws {
        let pill = NavigationPill()
        let back = try #require(pillButton("Back", in: pill))
        let forward = try #require(pillButton("Forward", in: pill))
        pill.update(canGoBack: true, canGoForward: false)
        #expect(back.isEnabled)
        #expect(!forward.isEnabled)
        pill.update(canGoBack: false, canGoForward: true)
        #expect(!back.isEnabled)
        #expect(forward.isEnabled)
    }

    @Test func itsButtonsSendBackAndForward() throws {
        let pill = NavigationPill()
        pill.update(canGoBack: true, canGoForward: true)
        var sent: [CommandID] = []
        pill.onNavigate = { sent.append($0) }
        try #require(pillButton("Back", in: pill)).performClick(nil)
        try #require(pillButton("Forward", in: pill)).performClick(nil)
        #expect(sent == [.back, .forward])
    }

    @Test func itsACapsuleOfRegularGlass() throws {
        let glass = try #require(NavigationPill().subviewsDeep.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .regular)
        #expect(glass.cornerRadius == NavigationPill.height / 2)
    }

    @Test func itsCurveRunsAlongsideTheWindowsCorner() {
        #expect(NavigationPill.inset + NavigationPill.height / 2 == Rail.cornerRadius + Rail.inset)
    }

    @Test func itsJustBigEnoughForTwoButtons() {
        #expect(NavigationPill().fittingSize == NSSize(width: 56, height: 28))
    }

    @Test func bothButtonsShowTheyCanBeClicked() {
        let buttons = NavigationPill().subviewsDeep.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        #expect(buttons.allSatisfy { $0 is HoverButton })
        #expect(buttons.map { $0.accessibilityLabel() } == ["Back", "Forward"])
    }
}

@Suite struct NavigationPillWindowTests {
    func controller(_ tabs: TabManager) -> WindowController {
        WindowController(appearance: testAppearance(), tabs: tabs)
    }

    func controller() -> WindowController {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        return controller(tabs)
    }

    /// A tab that has been to two pages, so it can go back but not forward.
    func tabsWithHistory() async -> (TabManager, Tab) {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let first = tabs.newTab(nil, activate: true)
        await finishLoading(first) { first.load(.url(URL(string: "data:text/html,one")!)) }
        await finishLoading(first) { first.load(.url(URL(string: "data:text/html,two")!)) }
        return (tabs, first)
    }

    /// The window's own strip along its left edge. Another, wider `EdgeStrip` can sit along the bottom.
    func railStrip(in content: NSView) -> EdgeStrip? {
        content.subviews.compactMap { $0 as? EdgeStrip }.first { $0.frame.width == EdgeStrip.width }
    }

    @Test func thePillSitsWhereTheWindowButtonsDo() throws {
        let controller = controller()
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        window.layoutIfNeeded()
        let pill = controller.navigationPill
        #expect(pill.superview === content)
        #expect(pill.frame.minX == NavigationPill.inset)
        #expect(content.bounds.maxY - pill.frame.maxY == NavigationPill.inset)
        let pillRect = pill.convert(pill.bounds, to: nil)

        controller.perform(.toggleRail)
        window.layoutIfNeeded()
        let close = try #require(window.standardWindowButton(.closeButton))
        let closeRect = close.convert(close.bounds, to: nil)
        #expect(pillRect.contains(NSPoint(x: closeRect.midX, y: closeRect.midY)))
        #expect(abs(pillRect.midY - closeRect.midY) <= 1)
    }

    @Test func thePillIsAboveTheTopStripAndBelowTheRail() throws {
        let controller = controller()
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let pill = try #require(content.subviews.firstIndex { $0 === controller.navigationPill })
        let strip = try #require(content.subviews.firstIndex { $0 is TopDragStrip })
        let rail = try #require(content.subviews.firstIndex { $0 === controller.rail })
        let switcher = try #require(content.subviews.firstIndex { $0 === controller.switcher })
        #expect(pill > strip)
        #expect(pill < rail)
        #expect(pill < switcher)

        window.layoutIfNeeded()
        let back = try #require(pillButton("Back", in: controller.navigationPill))
        let center = back.convert(NSPoint(x: back.bounds.midX, y: back.bounds.midY), to: nil)
        let point = try #require(content.superview?.convert(center, from: nil))
        #expect(content.hitTest(point) === back)
    }

    @Test func theRailAndThePillTakeTurns() {
        let controller = controller()
        #expect(!controller.navigationPill.isHidden)
        controller.perform(.toggleRail)
        #expect(controller.navigationPill.isHidden)
        controller.perform(.toggleRail)
        #expect(!controller.navigationPill.isHidden)
        controller.revealRailImmediately()
        #expect(controller.navigationPill.isHidden)
    }

    @Test func typingAnAddressPutsTheRailInThePillsPlace() {
        let controller = controller()
        controller.perform(.focusAddress)
        #expect(controller.navigationPill.isHidden)
    }

    @Test func hoveringAtTheEdgePutsTheRailInThePillsPlace() throws {
        let controller = controller()
        let content = try #require(controller.window?.contentView)
        let strip = try #require(railStrip(in: content))
        strip.onDwell?()
        #expect(controller.railState.visibility == .hover)
        #expect(controller.navigationPill.isHidden)
    }

    @Test func aWindowWithNoPageHasNoPill() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let controller = controller(tabs)
        #expect(controller.navigationPill.isHidden)
        tabs.newTab(nil, activate: true)
        #expect(!controller.navigationPill.isHidden)
        controller.perform(.closeTab)
        #expect(tabs.isEmpty)
        #expect(controller.navigationPill.isHidden)
    }

    @Test func thePillFollowsTheActiveTab() async throws {
        let (tabs, _) = await tabsWithHistory()
        let firstID = try #require(tabs.list.activeID)
        let controller = controller(tabs)
        let back = try #require(pillButton("Back", in: controller.navigationPill))
        let forward = try #require(pillButton("Forward", in: controller.navigationPill))
        #expect(back.isEnabled)
        #expect(!forward.isEnabled)

        tabs.newTab(nil, activate: true)
        #expect(!back.isEnabled)
        #expect(!forward.isEnabled)

        tabs.activate(firstID)
        #expect(back.isEnabled)
    }

    @Test func thePillsButtonsMoveThroughTheActiveTabsHistory() async throws {
        let (tabs, first) = await tabsWithHistory()
        let controller = controller(tabs)
        let back = try #require(pillButton("Back", in: controller.navigationPill))
        let forward = try #require(pillButton("Forward", in: controller.navigationPill))

        back.performClick(nil)
        #expect(await eventually { first.webView.url?.absoluteString == "data:text/html,one" })
        #expect(await eventually { forward.isEnabled }) // the page's own history change reaches the pill, not just a tab switch

        forward.performClick(nil)
        #expect(await eventually { first.webView.url?.absoluteString == "data:text/html,two" })
    }

    @Test func theRailSlidingInFadesThePillAway() async {
        let controller = controller()
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            #expect(!controller.navigationPill.isHidden) // still fading
        }
        #expect(await eventually { controller.navigationPill.isHidden })
    }

    /// The fade out cut short by the fade in reports its end at once, and mustn't hide the pill that came back.
    @Test func theRailComingStraightBackLeavesThePillUp() async throws {
        let controller = controller()
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            controller.perform(.toggleRail)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!controller.navigationPill.isHidden)
        #expect(controller.navigationPill.alphaValue == 1)
    }
}
