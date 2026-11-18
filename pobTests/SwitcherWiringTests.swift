import AppKit
import Foundation
import Testing
@testable import pob

/// History that answers only when told to, so a test can make an answer arrive late.
private final class HeldHistory {
    private var waiting: [String: CheckedContinuation<[HistoryEntry], Never>] = [:]

    func search(_ query: String) async -> [HistoryEntry] {
        guard !query.isEmpty else { return [] }
        return await withCheckedContinuation { waiting[query] = $0 }
    }
    func isWaiting(for query: String) -> Bool { waiting[query] != nil }
    func answer(_ query: String, with entries: [HistoryEntry] = []) {
        waiting.removeValue(forKey: query)?.resume(returning: entries)
    }
}

@Suite struct SwitcherWiringTests {
    let found = HistoryEntry(url: URL(string: "https://found.localhost/")!, title: "Found", visitCount: 1, lastVisit: .now)

    func make(tabs count: Int = 1) -> (controller: WindowController, tabs: TabManager) {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        for _ in 0..<count { tabs.newTab(nil, activate: true) }
        return (controller(for: tabs), tabs)
    }
    func controller(for tabs: TabManager) -> WindowController {
        let settings = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        return WindowController(appearance: AppearanceModel(store: SettingsStore(fileURL: settings), reduceTransparency: false), tabs: tabs)
    }

    /// Goes through the field editor, the way the keyboard does, so a field that lost focus fails here.
    func type(_ text: String, into field: NSTextField) throws {
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }
    func press(_ key: Selector, in field: NSTextField) throws {
        try #require(field.currentEditor() as? NSTextView).doCommand(by: key)
    }
    func hasKeyboard(_ field: NSTextField) -> Bool {
        field.currentEditor() != nil && field.window?.firstResponder === field.currentEditor()
    }
    let down = #selector(NSResponder.moveDown(_:))
    let up = #selector(NSResponder.moveUp(_:))
    let enter = #selector(NSResponder.insertNewline(_:))
    let escape = #selector(NSResponder.cancelOperation(_:))


    // MARK: Opening and closing

    @Test(arguments: [CommandID.openSwitcher, .openSwitcherFromPage])
    func openingCreatesNothingAndPutsTheKeyboardInTheField(command: CommandID) throws {
        let (controller, tabs) = make()
        controller.perform(command)
        #expect(!controller.switcher.isHidden)
        #expect(hasKeyboard(controller.switcher.field))
        #expect(tabs.list.records.count == 1)
        #expect(controller.switcher.list.rows.map(\.target) == tabs.list.records.map { .tab($0.id) })
    }
    @Test func theRailsNewTabRowOpensTheSwitcher() {
        let (controller, tabs) = make()
        controller.rail.tabList.onNewTab?()
        #expect(!controller.switcher.isHidden)
        #expect(tabs.list.records.count == 1)
    }
    @Test func eachOpenStartsEmptyWithTheOpenTabs() throws {
        let (controller, tabs) = make()
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        try type("zzzz", into: field)
        try press(escape, in: field)

        controller.perform(.openSwitcher)
        #expect(field.stringValue == "")
        #expect(controller.switcher.list.rows.map(\.target) == tabs.list.records.map { .tab($0.id) })
    }
    @Test func openingAgainLeavesItOpenAndFocused() throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        try type("half typed", into: field)

        controller.perform(.openSwitcher)
        #expect(!controller.switcher.isHidden)
        #expect(hasKeyboard(field))
        #expect(field.stringValue == "half typed")
        #expect(try #require(field.currentEditor() as? NSTextView).selectedRange().length == 0)
    }
    @Test func escClosesWithoutCreatingAnythingAndReturnsToThePage() throws {
        let (controller, tabs) = make()
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        try type("about:blank#nothing", into: field)
        try press(escape, in: field)
        #expect(controller.switcher.isHidden)
        #expect(tabs.list.records.count == 1)
        #expect(controller.window?.firstResponder === controller.tab?.webView)
    }
    @Test func anEmptyWindowShowsTheSwitcherAndStaysReadyForTheNextOne() throws {
        let (controller, tabs) = make(tabs: 0)
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        #expect(!controller.switcher.isHidden)
        #expect(controller.switcher.list.rows.isEmpty)
        try press(enter, in: field)
        #expect(tabs.isEmpty)
        #expect(!controller.switcher.isHidden)
    }

    // MARK: Smooth animations, where a closed panel is still on screen for a moment

    @Test func reopeningWhileThePanelFadesOutKeepsItOpen() async throws {
        let (controller, _) = make()
        withMotion(.smooth) {
            controller.perform(.openSwitcher)
            controller.switcher.onCancel?()
            #expect(!controller.switcher.isOpen)
            #expect(!controller.switcher.isHidden) // still fading
            controller.perform(.openSwitcher)
            #expect(controller.switcher.isOpen)
            #expect(hasKeyboard(controller.switcher.field))
        }
        try await Task.sleep(for: .milliseconds(400)) // the fade that was cut short has reported its end by now
        #expect(!controller.switcher.isHidden)
    }
    @Test func aPanelFadingOutLetsClicksThroughAndThenGoes() async throws {
        let (controller, _) = make()
        let content = try #require(controller.window?.contentView)
        withMotion(.smooth) {
            controller.perform(.openSwitcher)
            controller.switcher.onCancel?()
            #expect(content.hitTest(NSPoint(x: 20, y: 20))?.isDescendant(of: controller.switcher) != true)
            #expect(controller.window?.firstResponder === controller.tab?.webView)
        }
        #expect(await eventually { controller.switcher.isHidden })
    }

    // MARK: A window with no pages

    /// The panel is all an empty window has. Esc used to take it away and leave a blank window.
    @Test func escInAnEmptyWindowLeavesTheSwitcherUp() throws {
        let (controller, tabs) = make(tabs: 0)
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        try press(escape, in: field)
        #expect(!controller.switcher.isHidden)
        #expect(hasKeyboard(field))
        #expect(tabs.isEmpty)
    }
    @Test func aCommandInAnEmptyWindowLeavesTheSwitcherUp() {
        let (controller, _) = make(tabs: 0)
        controller.perform(.openSwitcher)
        controller.perform(.toggleRail)
        #expect(!controller.switcher.isHidden)
        #expect(hasKeyboard(controller.switcher.field))
    }
    @Test func aCommandRowInAnEmptyWindowLeavesTheSwitcherUp() throws {
        let (controller, _) = make(tabs: 0)
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        try type("hide rail", into: field)
        try press(down, in: field)
        #expect(controller.switcher.list.selection?.target == .command(.toggleRail))
        try press(enter, in: field)
        #expect(controller.railState.visibility == .pinned)
        #expect(!controller.switcher.isHidden)
    }
    /// The switcher's field is the address field of a window with no page.
    @Test func focusingTheAddressInAnEmptyWindowGoesToTheSwitcher() {
        let (controller, _) = make(tabs: 0)
        controller.perform(.focusAddress)
        #expect(!controller.switcher.isHidden)
        #expect(hasKeyboard(controller.switcher.field))
        #expect(controller.railState.visibility == .hidden)
    }
    /// There's no page to dim, and a click beside the panel has to reach the rail.
    @Test func anEmptyWindowHasNoDimmingToCatchClicks() throws {
        let (controller, tabs) = make(tabs: 0)
        let content = try #require(controller.window?.contentView)
        let dimming = try #require(controller.switcher.subviews.first)
        controller.perform(.openSwitcher)
        controller.switcher.layoutSubtreeIfNeeded()
        #expect(dimming.isHidden)
        #expect(content.hitTest(NSPoint(x: 20, y: 20))?.isDescendant(of: controller.switcher) != true)

        tabs.newTab(nil, activate: true)
        controller.perform(.openSwitcher)
        #expect(!dimming.isHidden)
    }
    @Test func closingAnEmptyWindowDoesntBringTheSwitcherBack() async throws {
        let (controller, _) = make(tabs: 0)
        let window = try #require(controller.window)
        controller.perform(.openSwitcher)
        await confirmation { closed in
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closed() }
            controller.perform(.closeTab)
            NotificationCenter.default.removeObserver(observer)
        }
        #expect(controller.switcher.isHidden)
    }
    /// A hosted window is never shown, so AppKit delivers no clicks to it. This checks where a click lands and what it fires.
    @Test func aClickOutsideLandsOnTheDimmingAndClosesIt() throws {
        let (controller, tabs) = make()
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        controller.perform(.openSwitcher)
        controller.switcher.layoutSubtreeIfNeeded()
        let hit = try #require(content.hitTest(NSPoint(x: 20, y: 20)))
        #expect(hit === controller.switcher.subviews.first)

        let recognizer = try #require(hit.gestureRecognizers.first as? NSClickGestureRecognizer)
        NSApp.sendAction(try #require(recognizer.action), to: recognizer.target, from: recognizer)
        #expect(controller.switcher.isHidden)
        #expect(tabs.list.records.count == 1)
        #expect(window.firstResponder === controller.tab?.webView)
    }
    /// AppKit gathers recognizers from the hit view and its superviews, and the dimming view is neither for a click on the panel.
    @Test func aClickOnThePanelMissesTheDimming() throws {
        let (controller, _) = make()
        let content = try #require(controller.window?.contentView)
        controller.perform(.openSwitcher)
        controller.switcher.layoutSubtreeIfNeeded()
        let glass = try #require(controller.switcher.subviewsDeep.first { $0 is NSGlassEffectView })
        let hit = try #require(content.hitTest(glass.convert(NSPoint(x: glass.bounds.midX, y: glass.bounds.midY), to: content)))
        #expect(hit.isDescendant(of: glass))
    }
    @Test func thePanelIsTallEnoughForItsRows() throws {
        let (controller, _) = make(tabs: 3)
        controller.perform(.openSwitcher)
        controller.switcher.layoutSubtreeIfNeeded()
        #expect(controller.switcher.list.contentHeight > 0)
        #expect(controller.switcher.list.frame.height == controller.switcher.list.contentHeight)
    }
    @Test func theFieldStaysPutAsResultsChange() throws {
        let (controller, _) = make(tabs: 3)
        let switcher = controller.switcher
        controller.perform(.openSwitcher)
        switcher.layoutSubtreeIfNeeded()
        let tall = switcher.field.convert(switcher.field.bounds, to: switcher)
        try type("zzzz nothing", into: switcher.field)
        switcher.layoutSubtreeIfNeeded()
        #expect(switcher.field.convert(switcher.field.bounds, to: switcher) == tall)
    }
    @Test func longResultsScrollInsideThePanelEvenInAShortWindow() throws {
        let (controller, _) = make(tabs: 5)
        let window = try #require(controller.window)
        window.setFrame(NSRect(origin: window.frame.origin, size: window.minSize), display: false)
        let switcher = controller.switcher
        #expect(switcher.bounds.height == window.minSize.height)
        controller.perform(.openSwitcher)
        try type("new", into: switcher.field) // five tabs, three commands and the search row
        switcher.layoutSubtreeIfNeeded()
        let glass = try #require(switcher.subviewsDeep.first { $0 is NSGlassEffectView })
        let panel = glass.convert(glass.bounds, to: switcher)
        #expect(switcher.bounds.insetBy(dx: 0, dy: 16).contains(panel))
        #expect(switcher.list.frame.height > 0)
        #expect(switcher.list.frame.height < switcher.list.contentHeight)
        #expect(window.frame.size == window.minSize)
    }
    @Test func theDimmingIsPlainAndThePanelIsOneRegularGlass() throws {
        let (controller, _) = make()
        controller.perform(.openSwitcher)
        controller.switcher.layoutSubtreeIfNeeded()
        let dimming = try #require(controller.switcher.subviews.first)
        #expect(Swift.type(of: dimming) == NSView.self)
        #expect(dimming.frame == controller.switcher.bounds)
        #expect(abs((dimming.layer?.backgroundColor?.alpha ?? 0) - 0.22) < 0.001)

        let glass = controller.switcher.subviewsDeep.compactMap { $0 as? NSGlassEffectView }
        #expect(glass.count == 1)
        #expect(glass.first?.style == .regular)
        #expect(abs((glass.first?.frame.width ?? 0) / controller.switcher.bounds.width - 0.56) < 0.01)
    }
    @Test func theOverlaySitsAboveEverythingElseInTheWindow() throws {
        let (controller, tabs) = make()
        let content = try #require(controller.window?.contentView)
        tabs.newTab(nil, activate: true)
        #expect(content.subviews.last === controller.switcher)
    }

    func panelFrame(in controller: WindowController) throws -> NSRect {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let glass = try #require(controller.switcher.subviewsDeep.first { $0 is NSGlassEffectView })
        return glass.convert(glass.bounds, to: controller.switcher)
    }
    func setWidth(_ width: CGFloat, of controller: WindowController) throws {
        let window = try #require(controller.window)
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: width, height: 800)), display: false)
        #expect(controller.switcher.bounds.width == width)
    }
    func pinRail(in controller: WindowController) {
        controller.perform(.toggleRail)
        controller.applyRailState(animated: false)
    }

    /// Glass never sits on glass, so while the rail shows, the panel centers on the page beside it and sizes from that.
    @Test func thePanelClearsAPinnedRailAt1024Points() throws {
        let (controller, _) = make()
        try setWidth(1024, of: controller)
        pinRail(in: controller)
        controller.perform(.openSwitcher)
        let panel = try panelFrame(in: controller)
        #expect(controller.rail.frame.maxX == 248)
        #expect(panel.minX >= controller.rail.frame.maxX)
        #expect(abs(panel.midX - (256 + 1024) / 2) < 1)
        #expect(abs(panel.width - 0.56 * (1024 - 256)) < 1)
    }
    @Test(arguments: [CGFloat(480), 700, 1000, 1126, 1127, 1600])
    func thePanelClearsThePinnedRailAtEveryWidth(width: CGFloat) throws {
        let (controller, _) = make()
        try setWidth(width, of: controller)
        pinRail(in: controller)
        controller.perform(.openSwitcher)
        #expect(try panelFrame(in: controller).minX >= controller.rail.frame.maxX)
    }
    @Test func thePanelMovesAsideWhenTheRailAppearsWhileItsOpen() throws {
        let (controller, _) = make()
        try setWidth(1024, of: controller)
        controller.perform(.openSwitcher)
        #expect(abs(try panelFrame(in: controller).midX - 512) < 1)

        controller.revealRailImmediately()
        #expect(try panelFrame(in: controller).minX >= controller.rail.frame.maxX)
        #expect(hasKeyboard(controller.switcher.field))
    }
    @Test func thePanelCentersOnTheWindowAgainOnceTheRailHides() throws {
        let (controller, _) = make()
        try setWidth(1024, of: controller)
        pinRail(in: controller)
        controller.perform(.toggleRail)
        controller.perform(.openSwitcher)
        let panel = try panelFrame(in: controller)
        #expect(abs(panel.midX - 512) < 1)
        #expect(abs(panel.width - 0.56 * 1024) < 1)
    }

    // MARK: Return on an empty field

    /// ⌘T then Return shouldn't jump tabs. "The first row is what Return chooses" is for matches.
    @Test func returnOnAnEmptyFieldClosesAndChangesNothing() throws {
        let (controller, tabs) = make(tabs: 2)
        let active = tabs.list.activeID
        controller.perform(.openSwitcher)
        try press(enter, in: controller.switcher.field)
        #expect(controller.switcher.isHidden)
        #expect(tabs.list.activeID == active)
        #expect(tabs.list.records.count == 2)
        #expect(controller.window?.firstResponder === controller.tab?.webView)
    }
    @Test func onlySpacesCountAsAnEmptyField() throws {
        let (controller, tabs) = make(tabs: 2)
        let field = controller.switcher.field
        let active = tabs.list.activeID
        controller.perform(.openSwitcher)
        try type("   ", into: field)
        try press(enter, in: field)
        #expect(controller.switcher.isHidden)
        #expect(tabs.list.activeID == active)
    }
    /// A marked row that Return ignores would be a lie, so nothing's marked until the arrows move.
    @Test func anEmptyFieldMarksNoRowUntilTheArrowsDo() throws {
        let (controller, tabs) = make(tabs: 2)
        let field = controller.switcher.field
        let list = controller.switcher.list
        controller.perform(.openSwitcher)
        #expect(list.selection == nil)
        try press(down, in: field)
        #expect(list.selection?.target == .tab(tabs.list.records[0].id))
        try press(up, in: field)
        #expect(list.selection == nil)
    }
    @Test func emptyingTheFieldGoesBackToNoRow() throws {
        let (controller, tabs) = make(tabs: 2)
        let field = controller.switcher.field
        let active = tabs.list.activeID
        controller.perform(.openSwitcher)
        try type("new", into: field)
        #expect(controller.switcher.list.selection != nil)
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(controller.switcher.list.selection == nil)
        try press(enter, in: field)
        #expect(controller.switcher.isHidden)
        #expect(tabs.list.activeID == active)
    }

    // MARK: Choosing

    @Test func choosingATabRowActivatesIt() throws {
        let (controller, tabs) = make(tabs: 2)
        let field = controller.switcher.field
        let first = tabs.list.records[0].id
        controller.perform(.openSwitcher)
        try press(down, in: field)
        try press(enter, in: field)
        #expect(tabs.list.activeID == first)
        #expect(tabs.list.records.count == 2)
        #expect(controller.switcher.isHidden)
        #expect(controller.window?.firstResponder === controller.tab?.webView)
    }
    /// Tab would otherwise send the keyboard to something behind the panel.
    @Test func tabMovesThroughTheRowsAndKeepsTheKeyboard() throws {
        let (controller, tabs) = make(tabs: 3)
        let field = controller.switcher.field
        let rows = tabs.list.records.map { SwitcherRow.Target.tab($0.id) }
        controller.perform(.openSwitcher)
        try press(#selector(NSResponder.insertTab(_:)), in: field)
        try press(#selector(NSResponder.insertTab(_:)), in: field)
        #expect(controller.switcher.list.selection?.target == rows[1])
        try press(#selector(NSResponder.insertBacktab(_:)), in: field)
        #expect(controller.switcher.list.selection?.target == rows[0])
        #expect(hasKeyboard(field))
    }
    @Test func theArrowsPickWhichTabReturnChooses() throws {
        let (controller, tabs) = make(tabs: 3)
        let field = controller.switcher.field
        tabs.activate(tabs.list.records[0].id)
        controller.perform(.openSwitcher)
        try press(down, in: field)
        try press(down, in: field)
        try press(down, in: field)
        try press(up, in: field)
        try press(enter, in: field)
        #expect(tabs.list.activeID == tabs.list.records[1].id)
    }
    @Test func anAddressRowOpensANewActiveTab() async throws {
        let (controller, tabs) = make()
        let field = controller.switcher.field
        let before = tabs.list.activeID
        let target = URL(string: "about:blank#opened")!
        controller.perform(.openSwitcher)
        try type(target.absoluteString, into: field)
        #expect(controller.switcher.list.rows.first?.target == .address(.url(target)))
        try press(enter, in: field)

        #expect(tabs.list.records.count == 2)
        #expect(tabs.list.activeID != before)
        #expect(controller.switcher.isHidden)
        #expect(await eventually { controller.tab?.webView.url == target })
        #expect(controller.window?.firstResponder === controller.tab?.webView)
    }
    @Test func aBookmarkRowOpensANewActiveTab() async throws {
        let (controller, tabs) = make()
        let field = controller.switcher.field
        let target = URL(string: "data:text/html,marked")!
        tabs.profile.bookmarks.toggle(url: target, title: "Marked page")
        controller.perform(.openSwitcher)
        try type("marked", into: field)
        try press(enter, in: field)
        #expect(tabs.list.records.count == 2)
        #expect(await eventually { controller.tab?.webView.url == target })
    }
    @Test func aCommandRowPerformsItOnThisWindow() throws {
        let (controller, tabs) = make()
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        try type("hide rail", into: field)
        try press(down, in: field) // the search row comes first
        #expect(controller.switcher.list.selection?.target == .command(.toggleRail))
        try press(enter, in: field)
        #expect(controller.railState.visibility == .pinned)
        #expect(controller.switcher.isHidden)
        #expect(tabs.list.records.count == 1)
    }
    @Test func aCommandThatOpensTheSwitcherLeavesItOpen() throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        try type("open switcher", into: field)
        try press(down, in: field)
        try press(enter, in: field)
        #expect(!controller.switcher.isHidden)
        #expect(field.stringValue == "")
        #expect(hasKeyboard(field))
    }
    @Test func aRowForATabThatClosedDoesNothing() throws {
        let (controller, tabs) = make(tabs: 2)
        let field = controller.switcher.field
        let first = tabs.list.records[0].id
        let active = tabs.list.activeID
        controller.perform(.openSwitcher)
        try press(down, in: field)
        tabs.close(first)
        try press(enter, in: field)
        #expect(tabs.list.activeID == active)
        #expect(controller.switcher.isHidden)
    }

    // MARK: Staying out of the way

    /// Otherwise the next key typed would land on the page behind the panel.
    @Test func aPageComingForwardBehindTheSwitcherLeavesTheKeyboardInIt() throws {
        let (controller, tabs) = make(tabs: 2)
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        tabs.activateNext()
        #expect(!controller.switcher.isHidden)
        #expect(hasKeyboard(field))
    }
    @Test func openingWhileEditingTheAddressEndsThatEdit() throws {
        let (controller, tabs) = make()
        try editAddress("reload", in: controller)
        controller.perform(.openSwitcher)
        #expect(hasKeyboard(controller.switcher.field))
        #expect(!controller.railState.isEditingAddress)
        #expect(controller.rail.suggestions.isHidden)
        #expect(!controller.rail.tabList.isHidden)
        #expect(controller.switcher.list.rows.map(\.target) == tabs.list.records.map { .tab($0.id) })
    }
    @Test func theSwitcherClosesBeforeACommandActsOnTheWindow() throws {
        let (controller, tabs) = make(tabs: 2)
        controller.perform(.openSwitcher)
        controller.perform(.focusAddress)
        #expect(controller.switcher.isHidden)
        #expect(hasKeyboard(controller.rail.addressField))

        controller.perform(.openSwitcher)
        controller.perform(.nextTab)
        #expect(controller.switcher.isHidden)
        #expect(controller.window?.firstResponder === controller.tab?.webView)

        controller.perform(.openSwitcher)
        controller.perform(.closeTab)
        #expect(controller.switcher.isHidden)
        #expect(tabs.list.records.count == 2)
        #expect(controller.window?.firstResponder === controller.tab?.webView)

        controller.perform(.closeTab)
        #expect(tabs.list.records.count == 1)
    }
    /// ⌘T is labelled New Tab, so ⌘T then ⌘W means "never mind". It mustn't take the page behind, or the app with the last tab.
    @Test func closeTabWithTheSwitcherOpenClosesOnlyTheSwitcher() async throws {
        let (controller, tabs) = make()
        let window = try #require(controller.window)
        controller.perform(.openSwitcher)
        await confirmation(expectedCount: 0) { closed in
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closed() }
            controller.perform(.closeTab)
            NotificationCenter.default.removeObserver(observer)
        }
        #expect(controller.switcher.isHidden)
        #expect(tabs.list.records.count == 1)
        #expect(window.firstResponder === controller.tab?.webView)
    }
    @Test func closeWindowWithTheSwitcherOpenStillClosesTheWindow() async throws {
        let (controller, _) = make()
        let window = try #require(controller.window)
        controller.perform(.openSwitcher)
        await confirmation { closed in
            let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: nil) { _ in closed() }
            controller.perform(.closeWindow)
            NotificationCenter.default.removeObserver(observer)
        }
    }
    @Test func choosingTheCloseTabRowStillClosesTheTab() throws {
        let (controller, tabs) = make(tabs: 2)
        let field = controller.switcher.field
        controller.perform(.openSwitcher)
        try type("close tab", into: field)
        try press(down, in: field)
        #expect(controller.switcher.list.selection?.target == .command(.closeTab))
        try press(enter, in: field)
        #expect(tabs.list.records.count == 1)
    }
    /// The row is caught before it runs, because a real search would reach the internet.
    @Test(arguments: ["zoom", "back", "print", "close", "bookmark"])
    func returnOnAWordFromACommandTitleSearches(word: String) throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        var chosen: SwitcherRow?
        controller.switcher.onChoose = { chosen = $0 }
        controller.perform(.openSwitcher)
        try type(word, into: field)
        try press(enter, in: field)
        guard case .address(.search) = chosen?.target else {
            Issue.record("expected the search row, got \(String(describing: chosen))")
            return
        }
    }

    // MARK: History

    @Test func tabsAndCommandsShowWithoutWaitingForHistory() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.load(.url(URL(string: "data:text/html,reload")!)) }
        let controller = controller(for: tabs)
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("reload", into: controller.switcher.field)

        let sections = controller.switcher.list.rows.map(\.section)
        #expect(sections.contains("Tabs"))
        #expect(sections.contains("Commands"))
        #expect(await eventually { held.isWaiting(for: "reload") })
        held.answer("reload")
    }
    @Test func historyJoinsTheRowsWhenItAnswers() async throws {
        let (controller, tabs) = make()
        await tabs.profile.history.record(url: found.url, title: found.title)
        controller.perform(.openSwitcher)
        try type("found", into: controller.switcher.field)
        #expect(await eventually {
            controller.switcher.list.rows.contains { $0.target == .url(found.url) }
        })
    }
    /// Pages listed above drop out of History, so asking for only as many as it shows would leave it short.
    @Test func historyStillFillsItsSectionWhenItsTopPagesAreBookmarked() async throws {
        let (controller, tabs) = make()
        let history = tabs.profile.history
        for index in 0..<8 {
            let url = URL(string: "https://found.localhost/\(index)")!
            await history.record(url: url, title: "Found \(index)")
            if index < 3 {
                await history.record(url: url, title: "Found \(index)")
                tabs.profile.bookmarks.toggle(url: url, title: "Found \(index)")
            }
        }
        controller.perform(.openSwitcher)
        try type("found", into: controller.switcher.field)
        #expect(await eventually {
            controller.switcher.list.rows.filter { $0.section == "History" }.count == 5
        })
    }
    @Test func aLateAnswerForAnOldQueryIsDropped() async throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("fo", into: field)
        #expect(await eventually { held.isWaiting(for: "fo") })
        try type("und", into: field)
        #expect(await eventually { held.isWaiting(for: "found") })

        held.answer("fo", with: [found])
        try await Task.sleep(for: .milliseconds(50))
        #expect(!controller.switcher.list.rows.contains { $0.target == .url(found.url) })
        held.answer("found")
    }
    @Test func aLateAnswerDoesntComeBackAfterClosing() async throws {
        let (controller, tabs) = make()
        let field = controller.switcher.field
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("found", into: field)
        #expect(await eventually { held.isWaiting(for: "found") })
        try press(escape, in: field)
        controller.perform(.openSwitcher)

        held.answer("found", with: [found])
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.switcher.list.rows.map(\.target) == tabs.list.records.map { .tab($0.id) })
    }
    /// Otherwise every key empties History until the store answers, and the panel's edge jumps up and back.
    @Test func historyThatStillMatchesStaysWhileTheNextAnswerIsOnItsWay() async throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("fou", into: field) // matches no command, so only history can change the height
        #expect(await eventually { held.isWaiting(for: "fou") })
        held.answer("fou", with: [found])
        #expect(await eventually { controller.switcher.list.rows.contains { $0.target == .url(found.url) } })
        let height = controller.switcher.list.contentHeight

        try type("n", into: field)
        #expect(controller.switcher.list.rows.contains { $0.target == .url(found.url) })
        #expect(controller.switcher.list.contentHeight == height)
        #expect(await eventually { held.isWaiting(for: "foun") })
        held.answer("foun", with: [found])
    }
    @Test func historyAlsoStaysWhenOnlyItsURLStillMatches() async throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        let page = HistoryEntry(url: URL(string: "https://zebra.localhost/")!, title: "Stripes", visitCount: 1, lastVisit: .now)
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("zeb", into: field)
        #expect(await eventually { held.isWaiting(for: "zeb") })
        held.answer("zeb", with: [page])
        #expect(await eventually { controller.switcher.list.rows.contains { $0.target == .url(page.url) } })

        try type("RA", into: field)
        #expect(controller.switcher.list.rows.contains { $0.target == .url(page.url) })
        #expect(await eventually { held.isWaiting(for: "zebRA") })
        held.answer("zebRA", with: [page])
    }
    /// A row that doesn't match what's typed must never be there to choose, even before the store answers.
    @Test func historyThatStopsMatchingGoesAtOnce() async throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("fo", into: field)
        #expect(await eventually { held.isWaiting(for: "fo") })
        held.answer("fo", with: [found])
        #expect(await eventually { controller.switcher.list.rows.contains { $0.target == .url(found.url) } })

        try type("x", into: field)
        #expect(!controller.switcher.list.rows.contains { $0.target == .url(found.url) })
        #expect(await eventually { held.isWaiting(for: "fox") })
        held.answer("fox")
    }
    /// The store matches word prefixes, so it can disagree with the contains that kept a row. It has the last word.
    @Test func theNextAnswerReplacesWhatWasKept() async throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("fo", into: field)
        #expect(await eventually { held.isWaiting(for: "fo") })
        held.answer("fo", with: [found])
        #expect(await eventually { controller.switcher.list.rows.contains { $0.target == .url(found.url) } })

        try type("u", into: field)
        #expect(controller.switcher.list.rows.contains { $0.target == .url(found.url) })
        #expect(await eventually { held.isWaiting(for: "fou") })
        held.answer("fou")
        #expect(await eventually { !controller.switcher.list.rows.contains { $0.target == .url(found.url) } })
    }
    @Test func keptHistoryDoesntReachTheNextSearch() async throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("fo", into: field)
        #expect(await eventually { held.isWaiting(for: "fo") })
        held.answer("fo", with: [found])
        #expect(await eventually { controller.switcher.list.rows.contains { $0.target == .url(found.url) } })
        try press(escape, in: field)

        controller.perform(.openSwitcher)
        try type("fo", into: field)
        #expect(!controller.switcher.list.rows.contains { $0.target == .url(found.url) })
        #expect(await eventually { held.isWaiting(for: "fo") })
        held.answer("fo")
    }
    /// The user arrowed to a row, so history arriving mustn't move them off it.
    @Test func aPickedRowSurvivesHistoryArriving() async throws {
        let (controller, tabs) = make()
        let field = controller.switcher.field
        let mark = URL(string: "data:text/html,mark")!
        tabs.profile.bookmarks.toggle(url: URL(string: "data:text/html,other")!, title: "Found one")
        tabs.profile.bookmarks.toggle(url: mark, title: "Found two")
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("found", into: field)
        try press(down, in: field)
        #expect(controller.switcher.list.selection?.target == .url(mark))
        #expect(await eventually { held.isWaiting(for: "found") })

        held.answer("found", with: [found])
        #expect(await eventually { controller.switcher.list.rows.contains { $0.target == .url(found.url) } })
        #expect(controller.switcher.list.selection?.target == .url(mark))
    }
    /// With no pick, Return still means the top row, whatever arrives above the one that was top a moment ago.
    @Test func withNoPickTheTopRowStaysSelectedAsHistoryArrives() async throws {
        let (controller, _) = make()
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        controller.perform(.openSwitcher)
        try type("found", into: controller.switcher.field)
        #expect(await eventually { held.isWaiting(for: "found") })

        held.answer("found", with: [found])
        #expect(await eventually { controller.switcher.list.rows.first?.target == .url(found.url) })
        #expect(controller.switcher.list.selection?.target == .url(found.url))
    }
    @Test func typingAfterArrowingStartsAgainFromTheTop() throws {
        let (controller, tabs) = make()
        let field = controller.switcher.field
        tabs.profile.bookmarks.toggle(url: URL(string: "data:text/html,one")!, title: "Found one")
        tabs.profile.bookmarks.toggle(url: URL(string: "data:text/html,two")!, title: "Found two")
        controller.perform(.openSwitcher)
        try type("found", into: field)
        try press(down, in: field)
        try type(" ", into: field)
        #expect(controller.switcher.list.selection == controller.switcher.list.rows.first)
    }

    // MARK: Text substitutions

    /// These follow each user's system settings, so tests start from on rather than trust the defaults.
    func turnSubstitutionsOn(in controller: WindowController) throws {
        let editor = try #require(controller.window?.fieldEditor(true, for: nil) as? NSTextView)
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isAutomaticTextReplacementEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        editor.isAutomaticDashSubstitutionEnabled = true
    }
    func expectLiteral(_ field: NSTextField) throws {
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(!editor.isAutomaticSpellingCorrectionEnabled)
        #expect(!editor.isAutomaticTextReplacementEnabled)
        #expect(!editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isAutomaticDashSubstitutionEnabled)
    }
    @Test func theSwitcherFieldKeepsTextAsTyped() throws {
        let (controller, _) = make()
        let field = controller.switcher.field
        try turnSubstitutionsOn(in: controller)
        controller.perform(.openSwitcher)
        try expectLiteral(field)
        try type("--", into: field)
        try expectLiteral(field)
        #expect(field.stringValue == "--")
    }
    @Test func theAddressFieldKeepsTextAsTyped() throws {
        let (controller, _) = make()
        let field = controller.rail.addressField
        try turnSubstitutionsOn(in: controller)
        controller.perform(.focusAddress)
        try expectLiteral(field)
        try type("--", into: field)
        try expectLiteral(field)
        #expect(field.stringValue == "--")
    }

    // MARK: Address field

    func editAddress(_ text: String, in controller: WindowController) throws {
        controller.perform(.focusAddress)
        try type(text, into: controller.rail.addressField)
    }

    /// One click selects the whole address, so typing replaces it.
    @Test func aClickInTheAddressFieldSelectsTheWholeAddress() throws {
        let (controller, _) = make()
        controller.revealRailImmediately()
        let window = try #require(controller.window)
        let field = controller.rail.addressField
        field.stringValue = "https://localhost/page"
        window.contentView?.layoutSubtreeIfNeeded()
        let point = field.convert(NSPoint(x: 20, y: field.bounds.midY), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        window.postEvent(mouse(.leftMouseUp), atStart: false)
        field.mouseDown(with: mouse(.leftMouseDown))
        let editor = try #require(field.currentEditor() as? NSTextView)
        #expect(editor.selectedRange() == NSRange(location: 0, length: field.stringValue.utf16.count))
        try type("example.com", into: field)
        #expect(field.stringValue == "example.com")
    }
    @Test func typingInTheAddressFieldReplacesTheTabListWithSuggestions() throws {
        let (controller, _) = make()
        try editAddress("reload", in: controller)
        #expect(controller.rail.suggestions.rows.contains { $0.target == .command(.reload) })
        #expect(!controller.rail.suggestions.isHidden)
        #expect(controller.rail.tabList.isHidden)
        #expect(controller.rail.suggestions.selection == nil)
    }
    @Test func focusAloneKeepsTheTabList() {
        let (controller, _) = make()
        controller.perform(.focusAddress)
        #expect(controller.rail.suggestions.isHidden)
        #expect(!controller.rail.tabList.isHidden)
    }
    @Test func emptyingTheFieldBringsTheTabListBack() throws {
        let (controller, _) = make()
        try editAddress("reload", in: controller)
        let editor = try #require(controller.rail.addressField.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        #expect(controller.rail.suggestions.isHidden)
        #expect(!controller.rail.tabList.isHidden)
    }
    /// With animations on, a list hidden at once and then faded back in mustn't be taken for one that's already showing.
    @Test func emptyingTheFieldAgainStillBringsTheTabListBack() async throws {
        let (controller, _) = make()
        let rail = controller.rail
        try withMotion(.smooth) {
            controller.perform(.focusAddress)
            for _ in 0..<2 {
                try type("reload", into: rail.addressField)
                #expect(!rail.suggestions.isHidden)
                #expect(rail.tabList.isHidden)
                let editor = try #require(rail.addressField.currentEditor() as? NSTextView)
                editor.selectAll(nil)
                editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                #expect(!rail.tabList.isHidden)
                #expect(rail.suggestions.isHidden)
            }
        }
        #expect(await eventually { rail.tabList.alphaValue == 1 })
    }
    @Test func returnWithSuggestionsShowingStillLoadsTheTypedText() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let current = tabs.newTab(nil, activate: true)
        let other = tabs.newTab(nil, activate: false)
        await finishLoading(other) { other.load(.url(URL(string: "data:text/html,about:typed")!)) }
        let controller = controller(for: tabs)
        try editAddress("about:typed", in: controller)
        #expect(controller.rail.suggestions.rows.first?.section == "Tabs")

        try press(enter, in: controller.rail.addressField)
        #expect(await eventually { current.webView.url == URL(string: "about:typed") })
        #expect(tabs.list.records.count == 2)
        #expect(controller.tab === current)
    }
    @Test func choosingASuggestionNavigatesTheCurrentTab() async throws {
        let (controller, tabs) = make()
        let current = try #require(controller.tab)
        let target = URL(string: "data:text/html,marked")!
        tabs.profile.bookmarks.toggle(url: target, title: "Marked page")
        try clickAddress(typing: "marked", in: controller)
        try press(down, in: controller.rail.addressField)
        try press(enter, in: controller.rail.addressField)

        #expect(await eventually { current.webView.url == target })
        #expect(tabs.list.records.count == 1)
        #expect(controller.tab === current)
        #expect(controller.window?.firstResponder === current.webView)
    }
    @Test func clickingASuggestionNavigatesTheCurrentTab() async throws {
        let (controller, tabs) = make()
        let current = try #require(controller.tab)
        let target = URL(string: "data:text/html,marked")!
        tabs.profile.bookmarks.toggle(url: target, title: "Marked page")
        try editAddress("marked", in: controller)
        let index = try #require(controller.rail.suggestions.rows.firstIndex { $0.target == .url(target) })
        controller.rail.suggestions.chooseRow(index + 1) // the Bookmarks header comes first
        #expect(await eventually { current.webView.url == target })
        #expect(tabs.list.records.count == 1)
    }
    @Test func aTabSuggestionBringsThatPageHereWithoutSwitching() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let current = tabs.newTab(nil, activate: true)
        let other = tabs.newTab(nil, activate: false)
        let target = URL(string: "data:text/html,elsewhere")!
        await finishLoading(other) { other.load(.url(target)) }
        let controller = controller(for: tabs)
        try editAddress("elsewhere", in: controller)
        try press(down, in: controller.rail.addressField)
        #expect(controller.rail.suggestions.selection?.section == "Tabs")
        try press(enter, in: controller.rail.addressField)

        #expect(await eventually { current.webView.url == target })
        #expect(controller.tab === current)
        #expect(tabs.list.records.count == 2)
    }
    @Test func aCommandSuggestionPerforms() throws {
        let (controller, _) = make()
        try editAddress("hide rail", in: controller)
        try press(down, in: controller.rail.addressField) // the search row comes first
        try press(down, in: controller.rail.addressField)
        try press(enter, in: controller.rail.addressField)
        #expect(controller.railState.visibility == .pinned)
        #expect(controller.rail.addressField.currentEditor() == nil)
    }
    @Test func upFromTheFirstSuggestionGoesBackToTheTypedText() async throws {
        let (controller, tabs) = make()
        let current = try #require(controller.tab)
        let typed = URL(string: "about:typed")!
        tabs.profile.bookmarks.toggle(url: URL(string: "data:text/html,other")!, title: "about:typed notes")
        try editAddress("about:typed", in: controller)
        try press(down, in: controller.rail.addressField)
        try press(up, in: controller.rail.addressField)
        #expect(controller.rail.suggestions.selection == nil)
        try press(enter, in: controller.rail.addressField)
        #expect(await eventually { current.webView.url == typed })
    }
    @Test func theArrowsMoveTheCaretWhenThereAreNoSuggestions() throws {
        let (controller, _) = make()
        controller.perform(.focusAddress)
        let editor = try #require(controller.rail.addressField.currentEditor() as? NSTextView)
        #expect(!controller.rail.control(controller.rail.addressField, textView: editor, doCommandBy: down))
        #expect(!controller.rail.control(controller.rail.addressField, textView: editor, doCommandBy: up))
    }
    @Test func escRestoresTheAddressAndBringsTheTabListBack() async throws {
        let (controller, _) = make()
        let current = try #require(controller.tab)
        await finishLoading(current) { current.load(.url(URL(string: "data:text/html,page")!)) }
        try editAddress("half typed", in: controller)
        try press(escape, in: controller.rail.addressField)

        #expect(controller.rail.addressField.stringValue == "data:text/html,page")
        #expect(controller.window?.firstResponder === current.webView)
        #expect(controller.rail.suggestions.isHidden)
        #expect(!controller.rail.tabList.isHidden)
        #expect(!controller.railState.isEditingAddress)
    }
    @Test func suggestionsGoAwayHoweverEditingEnds() throws {
        let (controller, _) = make()
        try editAddress("reload", in: controller)
        controller.window?.makeFirstResponder(controller.tab?.webView)
        #expect(controller.rail.suggestions.isHidden)
        #expect(!controller.rail.tabList.isHidden)
    }
    @Test func aLateAnswerDoesntBringSuggestionsBackAfterEditingEnds() async throws {
        let (controller, _) = make()
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        try editAddress("found", in: controller)
        #expect(await eventually { held.isWaiting(for: "found") })
        try press(escape, in: controller.rail.addressField)

        held.answer("found", with: [found])
        try await Task.sleep(for: .milliseconds(50))
        #expect(controller.rail.suggestions.isHidden)
        #expect(!controller.rail.tabList.isHidden)
    }
    @Test func historyReachesTheSuggestionsToo() async throws {
        let (controller, _) = make()
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        try editAddress("found", in: controller)
        #expect(await eventually { held.isWaiting(for: "found") })
        held.answer("found", with: [found])
        #expect(await eventually { controller.rail.suggestions.rows.contains { $0.target == .url(found.url) } })
    }
    @Test func suggestionsKeepHistoryThatStillMatchesBetweenKeys() async throws {
        let (controller, _) = make()
        let field = controller.rail.addressField
        let held = HeldHistory()
        controller.searchHistory = { await held.search($0) }
        try editAddress("fo", in: controller)
        #expect(await eventually { held.isWaiting(for: "fo") })
        held.answer("fo", with: [found])
        #expect(await eventually { controller.rail.suggestions.rows.contains { $0.target == .url(found.url) } })

        try type("u", into: field)
        #expect(controller.rail.suggestions.rows.contains { $0.target == .url(found.url) })
        #expect(await eventually { held.isWaiting(for: "fou") })
        held.answer("fou", with: [found])
    }
    @Test func arrowingToAnAddressSuggestionLoadsItInTheCurrentTab() async throws {
        let (controller, tabs) = make()
        let current = try #require(controller.tab)
        let field = controller.rail.addressField
        let target = URL(string: "about:typed")!
        try editAddress("about:typed", in: controller)
        try press(down, in: field)
        #expect(controller.rail.suggestions.selection?.target == .address(.url(target)))
        try press(enter, in: field)
        #expect(await eventually { current.webView.url == target })
        #expect(tabs.list.records.count == 1)
        #expect(controller.tab === current)
    }
    @Test func typingAfterArrowingClearsTheRailsPick() throws {
        let (controller, tabs) = make()
        let field = controller.rail.addressField
        tabs.profile.bookmarks.toggle(url: URL(string: "data:text/html,marked")!, title: "Marked page")
        try editAddress("mark", in: controller)
        try press(down, in: field)
        #expect(controller.rail.suggestions.selection != nil)
        try type("ed", into: field)
        #expect(controller.rail.suggestions.rows.contains { $0.section == "Bookmarks" })
        #expect(controller.rail.suggestions.selection == nil)
    }
    /// ⌘L goes to the switcher in a window with no page, so the rail's own field is reached with a click.
    /// That window always has the switcher up, so these start with it up.
    func clickAddress(typing text: String, in controller: WindowController) throws {
        controller.perform(.openSwitcher)
        controller.window?.makeFirstResponder(controller.rail.addressField)
        try type(text, into: controller.rail.addressField)
    }
    @Test func withNoTabSubmittingTheAddressOpensOne() async throws {
        let (controller, tabs) = make(tabs: 0)
        let target = URL(string: "about:blank#typed")!
        try clickAddress(typing: target.absoluteString, in: controller)
        try press(enter, in: controller.rail.addressField)
        #expect(tabs.list.records.count == 1)
        #expect(controller.switcher.isHidden) // the page has the window now
        #expect(await eventually { controller.tab?.webView.url == target })
    }
    @Test func withNoTabChoosingASuggestionOpensOne() async throws {
        let (controller, tabs) = make(tabs: 0)
        let target = URL(string: "data:text/html,marked")!
        tabs.profile.bookmarks.toggle(url: target, title: "Marked page")
        try clickAddress(typing: "marked", in: controller)
        try press(down, in: controller.rail.addressField)
        try press(enter, in: controller.rail.addressField)
        #expect(tabs.list.records.count == 1)
        #expect(await eventually { controller.tab?.webView.url == target })
    }
    @Test func withNoTabEscLeavesTheWindowEmpty() throws {
        let (controller, tabs) = make(tabs: 0)
        try clickAddress(typing: "half typed", in: controller)
        try press(escape, in: controller.rail.addressField)
        #expect(tabs.isEmpty)
        #expect(controller.rail.addressField.stringValue == "")
        #expect(!controller.switcher.isHidden)
        #expect(hasKeyboard(controller.switcher.field))
    }
}
