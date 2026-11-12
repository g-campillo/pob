import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct RailTests {
    @Test func edgeOpensAndLeavingCloses() {
        var state = RailState()
        state.pointerDwelledAtEdge()
        #expect(state.visibility == .hover)
        state.pointerLeftRail()
        #expect(state.visibility == .hidden)
    }
    @Test func shortcutPinsAndHides() {
        var state = RailState()
        state.toggleShortcut()
        #expect(state.visibility == .pinned)
        state.pointerLeftRail()
        #expect(state.visibility == .pinned)
        state.toggleShortcut()
        #expect(state.visibility == .hidden)
    }
    @Test func shortcutPinsARailOpenOnHover() {
        var state = RailState()
        state.pointerDwelledAtEdge()
        state.toggleShortcut()
        #expect(state.visibility == .pinned)
    }
    @Test func typingKeepsTheRailOpen() {
        var state = RailState()
        state.beginEditingAddress()
        #expect(state.visibility == .hover)
        state.pointerLeftRail()
        #expect(state.visibility == .hover)
        state.endEditingAddress(pointerInsideRail: false)
        #expect(state.visibility == .hidden)
    }
    @Test func finishingWithThePointerInsideKeepsItOpen() {
        var state = RailState()
        state.beginEditingAddress()
        state.endEditingAddress(pointerInsideRail: true)
        #expect(state.visibility == .hover)
    }
    @Test func edgeStripNeverTakesClicks() {
        let strip = EdgeStrip(frame: NSRect(x: 0, y: 0, width: 8, height: 400))
        #expect(strip.hitTest(NSPoint(x: 4, y: 200)) == nil)
    }
    @Test func railIsRegularGlass() throws {
        let glass = try #require(Rail(frame: .zero).subviewsDeep.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .regular)
    }
    /// The lists above it come and go, and the bottom row mustn't ride up when neither is showing.
    @Test func theBottomRowStaysAtTheBottomWhateverTheListsShow() {
        let rail = Rail(frame: NSRect(x: 0, y: 0, width: Rail.width, height: 600))
        func frame(of view: NSView) -> NSRect {
            rail.layoutSubtreeIfNeeded()
            return rail.convert(view.bounds, from: view)
        }
        let settings = frame(of: rail.settingsButton)
        #expect(settings.minY < 20) // the stack's 10 pt margin, not somewhere up the rail
        #expect(frame(of: rail.tabList).minY - settings.maxY <= 12) // the tab list still fills the space down to it

        rail.showSuggestions([SwitcherRow(target: .command(.reload), title: "Reload", subtitle: "", section: "")])
        #expect(frame(of: rail.settingsButton) == settings) // one short row of suggestions

        rail.showSuggestions([])
        rail.tabList.isHidden = true
        #expect(frame(of: rail.settingsButton) == settings) // neither list
    }
    @Test func pinningMovesThePageOverAndHoverDoesNot() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: model, tabs: tabs)
        controller.perform(.toggleRail)
        #expect(controller.tab?.webView.obscuredContentInsets.left == 256)
        #expect(controller.window?.standardWindowButton(.closeButton)?.isHidden == false)
        controller.perform(.toggleRail)
        #expect(controller.tab?.webView.obscuredContentInsets.left == 0)
    }

    @Test func revealingImmediatelyPutsTheRailInPlaceForPopovers() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        let controller = WindowController(appearance: model, tabs: TabManager(profile: .temporary(), keepsSpare: false))
        controller.revealRailImmediately()
        #expect(controller.rail.isHidden == false)
        #expect(controller.rail.frame.minX == Rail.inset)
    }

    // MARK: Smooth animations, where the rail is still on screen while it slides out

    private func pinned() -> WindowController {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        controller.perform(.toggleRail)
        return controller
    }
    @Test func theRailStaysUpWhileItSlidesOutAndThenHides() async {
        let controller = pinned()
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            #expect(!controller.rail.isHidden)
            controller.applyRailState() // nothing changed, and the slide mustn't be cut short
            #expect(!controller.rail.isHidden)
        }
        #expect(await eventually { controller.rail.isHidden })
        #expect(controller.rail.frame.minX == -(Rail.width + Rail.inset))
    }
    @Test func showingTheRailAgainMidSlideKeepsIt() async throws {
        let controller = pinned()
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            controller.perform(.toggleRail)
        }
        try await Task.sleep(for: .milliseconds(700)) // both slides have ended by now
        #expect(!controller.rail.isHidden)
        #expect(controller.rail.frame.minX == Rail.inset)
        #expect(controller.window?.standardWindowButton(.closeButton)?.alphaValue == 1)
    }
    @Test func hidingTheRailMidSlideInStillHidesIt() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            #expect(!controller.rail.isHidden)
            controller.perform(.toggleRail)
            #expect(!controller.rail.isHidden)
        }
        #expect(await eventually { controller.rail.isHidden })
        #expect(controller.rail.frame.minX == -(Rail.width + Rail.inset)) // it slid back out before it went
    }
    /// A popover anchors to the rail, so this can't wait for a slide.
    @Test func revealingImmediatelyStopsASlideOut() async throws {
        let controller = pinned()
        withMotion(.smooth) {
            controller.perform(.toggleRail)
            controller.revealRailImmediately()
            #expect(controller.rail.frame.minX == Rail.inset)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(!controller.rail.isHidden)
        #expect(controller.rail.frame.minX == Rail.inset)
    }

    // MARK: Bookmarks

    /// A window on a profile with this many bookmarks in no folder, and one tab.
    private func window(bookmarks count: Int) -> WindowController {
        let profile = Profile.temporary()
        for index in 0..<count {
            profile.bookmarks.add(title: "Site \(index)", url: URL(string: "https://site\(index).example/")!, folder: nil)
        }
        let tabs = TabManager(profile: profile, keepsSpare: false)
        tabs.newTab(nil, activate: true)
        return WindowController(appearance: testAppearance(), tabs: tabs)
    }
    /// The pinned rail at this height, with its Bookmarks section open.
    private func openSection(in controller: WindowController, height: CGFloat) throws -> NSScrollView {
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 800, height: height))
        controller.perform(.toggleRail)
        controller.rail.bookmarks.setExpanded(true, animated: false)
        window.layoutIfNeeded()
        return try #require(controller.rail.bookmarks.subviewsDeep.compactMap { $0 as? NSScrollView }.first)
    }
    private func settingsButtonInRail(of controller: WindowController) -> NSRect {
        controller.rail.convert(controller.rail.settingsButton.bounds, from: controller.rail.settingsButton)
    }

    @Test func theBookmarksSectionStartsClosedInANewWindow() throws {
        let controller = window(bookmarks: 1)
        let bookmark = try #require(controller.tabs.profile.bookmarks.all.first)
        #expect(!controller.rail.bookmarks.isExpanded)
        #expect(controller.rail.bookmarks.rows == [.bookmark(bookmark, inFolder: false)])
    }
    @Test func manyBookmarksInAShortWindowLeaveTheTabsAndTheBottomRowAlone() throws {
        let controller = window(bookmarks: 30)
        let scroll = try openSection(in: controller, height: 360)
        #expect(scroll.frame.height > 0)
        #expect(scroll.frame.height <= 0.4 * 360 + 0.5)
        #expect(controller.rail.tabList.frame.height >= 34) // the New Tab row still fits
        #expect(settingsButtonInRail(of: controller).minY < 20)
    }
    @Test func inATallWindowTheListStopsAtSevenRows() throws {
        let controller = window(bookmarks: 30)
        let scroll = try openSection(in: controller, height: 1000)
        #expect(abs(scroll.frame.height - BookmarksSection.maxListHeight) <= 0.5)
        #expect(settingsButtonInRail(of: controller).minY < 20)
    }
}

extension NSView {
    var subviewsDeep: [NSView] { subviews + subviews.flatMap(\.subviewsDeep) }
}
