import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct SwitcherModelTests {
    let deployTab = TabRecord(url: URL(string: "https://docs.example.com/deploy"), title: "Deploy guide")
    let bookmark = Bookmark(id: UUID(), title: "Deployment checklist", url: URL(string: "https://example.com/check")!, folder: nil, isPinned: true)
    let visit = HistoryEntry(url: URL(string: "https://ops.example.com/deploy")!, title: "Deploy logs", visitCount: 2, lastVisit: .now)
    let commands = CommandList.standard { _ in }.all

    func rows(_ query: String) -> [SwitcherRow] {
        SwitcherModel.rows(query: query, tabs: [deployTab], bookmarks: [bookmark], history: [visit], commands: commands)
    }

    @Test func openTabsComeFirstThenBookmarksThenHistory() {
        #expect(Array(rows("dep").map(\.section).prefix(3)) == ["Tabs", "Bookmarks", "History"])
    }
    @Test func theFirstRowIsWhatReturnChooses() {
        #expect(rows("dep").first?.target == .tab(deployTab.id))
    }
    @Test func aFullAddressWithNoOpenTabGoesThere() {
        #expect(rows("apple.com").first?.target == .address(.url(URL(string: "https://apple.com")!)))
    }
    @Test func unmatchedTextEndsInASearchRow() {
        let result = SwitcherModel.rows(query: "zzzz nothing", tabs: [deployTab], bookmarks: [bookmark], history: [], commands: commands)
        #expect(result.count == 1)
        guard case .address(.search) = result[0].target else {
            Issue.record("expected a search row")
            return
        }
    }
    @Test func commandsMatchByTitle() {
        #expect(rows("web insp").contains { $0.target == .command(.toggleInspector) })
    }
    @Test func emptyQueriesListOpenTabs() {
        #expect(rows("").map(\.target) == [.tab(deployTab.id)])
    }
    @Test func aHistoryPageThatsAlsoBookmarkedShowsOnce() {
        let page = URL(string: "https://example.com/check")!
        let entry = HistoryEntry(url: page, title: "Deployment checklist", visitCount: 1, lastVisit: .now)
        let result = SwitcherModel.rows(query: "dep", tabs: [], bookmarks: [bookmark], history: [entry], commands: [])
        #expect(result.filter { $0.target == .url(page) }.count == 1)
    }
}

@Suite struct SwitcherLimitTests {
    let commands = CommandList.standard { _ in }.all

    func page(_ index: Int) -> URL { URL(string: "https://example.com/deploy/\(index)")! }
    func bookmark(_ url: URL) -> Bookmark { Bookmark(id: UUID(), title: "Deploy", url: url, folder: nil, isPinned: false) }
    func visit(_ url: URL) -> HistoryEntry { HistoryEntry(url: url, title: "Deploy", visitCount: 1, lastVisit: .now) }

    @Test func eachSectionStopsAtItsLimit() {
        let tabs = (0..<9).map { TabRecord(url: page($0), title: "Deploy") }
        let bookmarks = (10..<19).map { bookmark(page($0)) }
        let history = (20..<29).map { visit(page($0)) }
        let many = (0..<9).map { index in Command(id: .reload, title: "Deploy \(index)", key: "", modifiers: [], isReserved: false) {} }
        let sections = SwitcherModel.rows(query: "deploy", tabs: tabs, bookmarks: bookmarks, history: history, commands: many).map(\.section)
        #expect(sections.filter { $0 == "Tabs" }.count == 5)
        #expect(sections.filter { $0 == "Bookmarks" }.count == 3)
        #expect(sections.filter { $0 == "History" }.count == 5)
        #expect(sections.filter { $0 == "Commands" }.count == 3)
    }
    @Test func anEmptyQueryStopsAtTheTabLimitToo() {
        let tabs = (0..<9).map { TabRecord(url: page($0)) }
        #expect(SwitcherModel.rows(query: "", tabs: tabs, bookmarks: [], history: [], commands: commands).count == 5)
    }
    @Test func aURLGoesAfterTheTabsAndASearchGoesLast() {
        let tab = TabRecord(url: URL(string: "https://apple.com/mac"), title: "Mac")
        let mark = Bookmark(id: UUID(), title: "Apple", url: URL(string: "https://apple.com/store")!, folder: nil, isPinned: false)
        let address = SwitcherModel.rows(query: "apple.com", tabs: [tab], bookmarks: [mark], history: [], commands: [])
        #expect(address.map(\.section) == ["Tabs", "", "Bookmarks"])
        #expect(address[1].target == .address(.url(URL(string: "https://apple.com")!)))

        let search = SwitcherModel.rows(query: "apple", tabs: [tab], bookmarks: [mark], history: [], commands: [])
        #expect(search.map(\.section) == ["Tabs", "Bookmarks", ""])
        guard case .address(.search) = search[2].target else {
            Issue.record("expected the search row last")
            return
        }
    }
    @Test func surroundingSpacesDontChangeTheMatch() {
        let tab = TabRecord(url: nil, title: "Deploy guide")
        #expect(SwitcherModel.rows(query: "  dep ", tabs: [tab], bookmarks: [], history: [], commands: []).first?.target == .tab(tab.id))
        #expect(SwitcherModel.rows(query: "   ", tabs: [tab], bookmarks: [], history: [], commands: commands).map(\.target) == [.tab(tab.id)])
    }
    @Test func tabsMatchByURLAndUntitledTabsShowTheirHost() {
        let tab = TabRecord(url: URL(string: "https://docs.example.com/deploy"))
        let row = SwitcherModel.rows(query: "DEPLOY", tabs: [tab], bookmarks: [], history: [], commands: []).first
        #expect(row?.target == .tab(tab.id))
        #expect(row?.title == "docs.example.com")
        #expect(row?.subtitle == "https://docs.example.com/deploy")
    }
    @Test func aPageThatsOpenShowsOnlyAsItsTab() {
        let url = page(1)
        let tab = TabRecord(url: url, title: "Deploy")
        let result = SwitcherModel.rows(query: "dep", tabs: [tab], bookmarks: [bookmark(url)], history: [visit(url)], commands: [])
        #expect(result.filter { $0.target == .url(url) }.isEmpty)
        #expect(result.first?.target == .tab(tab.id))
    }
    /// A bookmark past the limit isn't on screen, so history is free to show that page.
    @Test func onlyPagesActuallyListedDropOutOfHistory() {
        let bookmarks = (0..<4).map { bookmark(page($0)) }
        let result = SwitcherModel.rows(query: "dep", tabs: [], bookmarks: bookmarks, history: [visit(page(3))], commands: [])
        #expect(result.filter { $0.section == "History" }.map(\.target) == [.url(page(3))])
    }
    @Test func historyWithNoTitleStillSaysWhatItIs() {
        let entry = HistoryEntry(url: page(1), title: "", visitCount: 1, lastVisit: .now)
        #expect(SwitcherModel.rows(query: "dep", tabs: [], bookmarks: [], history: [entry], commands: []).first?.title == page(1).absoluteString)
    }
}

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

        try press(escape, in: field)
        #expect(controller.switcher.isHidden)
        #expect(tabs.isEmpty)
        #expect(controller.window?.firstResponder === controller.window)

        controller.perform(.openSwitcher)
        #expect(hasKeyboard(field))
    }
    /// A hosted window is never shown, so AppKit delivers no clicks to it. This checks where a click lands and what it fires.
    @Test func clickingOutsideClosesItAndNeverReachesThePage() throws {
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
        try type("new", into: switcher.field) // five tabs, two commands and the search row
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

    // MARK: Choosing

    @Test func choosingATabRowActivatesIt() throws {
        let (controller, tabs) = make(tabs: 2)
        let field = controller.switcher.field
        let first = tabs.list.records[0].id
        controller.perform(.openSwitcher)
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
        #expect(controller.switcher.list.rows.first?.target == .command(.toggleRail))
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
        #expect(tabs.list.records.count == 1)
        #expect(controller.window?.firstResponder === controller.tab?.webView)
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

    // MARK: Address field

    func editAddress(_ text: String, in controller: WindowController) throws {
        controller.perform(.focusAddress)
        try type(text, into: controller.rail.addressField)
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
        try editAddress("marked", in: controller)
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
    @Test func withNoTabSubmittingTheAddressOpensOne() async throws {
        let (controller, tabs) = make(tabs: 0)
        let target = URL(string: "about:blank#typed")!
        try editAddress(target.absoluteString, in: controller)
        try press(enter, in: controller.rail.addressField)
        #expect(tabs.list.records.count == 1)
        #expect(await eventually { controller.tab?.webView.url == target })
    }
    @Test func withNoTabChoosingASuggestionOpensOne() async throws {
        let (controller, tabs) = make(tabs: 0)
        let target = URL(string: "data:text/html,marked")!
        tabs.profile.bookmarks.toggle(url: target, title: "Marked page")
        try editAddress("marked", in: controller)
        try press(down, in: controller.rail.addressField)
        try press(enter, in: controller.rail.addressField)
        #expect(tabs.list.records.count == 1)
        #expect(await eventually { controller.tab?.webView.url == target })
    }
    @Test func withNoTabEscLeavesTheWindowEmpty() throws {
        let (controller, tabs) = make(tabs: 0)
        try editAddress("half typed", in: controller)
        try press(escape, in: controller.rail.addressField)
        #expect(tabs.isEmpty)
        #expect(controller.rail.addressField.stringValue == "")
    }
}

@Suite struct SwitcherListTests {
    let rows = [
        SwitcherRow(target: .command(.back), title: "One", subtitle: "", section: "Tabs"),
        SwitcherRow(target: .command(.forward), title: "Two", subtitle: "", section: "Bookmarks"),
        SwitcherRow(target: .command(.reload), title: "Three", subtitle: "", section: "Bookmarks"),
    ]

    @Test func upAndDownSkipSectionHeadersAndStopAtTheEnds() {
        let list = SwitcherList(selectsFirstRow: true)
        list.show(rows)
        #expect(list.selection == rows[0])
        list.moveSelection(by: 1)
        #expect(list.selection == rows[1])
        list.moveSelection(by: 1)
        list.moveSelection(by: 1)
        #expect(list.selection == rows[2])
        list.moveSelection(by: -1)
        #expect(list.selection == rows[1])
        list.moveSelection(by: -1)
        list.moveSelection(by: -1)
        #expect(list.selection == rows[0])
    }
    @Test func aListWithNoDefaultStartsEmptyAndCanGoBackToEmpty() {
        let list = SwitcherList(selectsFirstRow: false)
        list.show(rows)
        #expect(list.selection == nil)
        list.moveSelection(by: -1)
        #expect(list.selection == nil)
        list.moveSelection(by: 1)
        #expect(list.selection == rows[0])
        list.moveSelection(by: -1)
        #expect(list.selection == nil)
    }
    @Test func aHeaderCantBeChosen() {
        let list = SwitcherList(selectsFirstRow: true)
        list.show(rows)
        var chosen: [SwitcherRow] = []
        list.onChoose = { chosen.append($0) }
        list.chooseRow(0)
        list.chooseRow(2)
        list.chooseRow(99)
        #expect(chosen.isEmpty)
        list.chooseRow(1)
        list.chooseRow(3)
        #expect(chosen == [rows[0], rows[1]])
    }
    @Test func noRowsMeansNothingToMoveThrough() {
        let list = SwitcherList(selectsFirstRow: true)
        list.show([])
        list.moveSelection(by: 1)
        #expect(list.selection == nil)
    }
    @Test func theSelectedRowShowsAFillAndOnlyThatRow() {
        let list = SwitcherList(selectsFirstRow: true)
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        list.show(rows)
        list.layoutSubtreeIfNeeded()
        func fills() -> Int { list.subviewsDeep.filter { $0 is ActiveFill && !$0.isHidden }.count }
        #expect(fills() == 1)
        list.moveSelection(by: 1)
        #expect(fills() == 1)
    }
    @Test func theListNeverTakesTheKeyboard() throws {
        let table = try #require(SwitcherList(selectsFirstRow: true).subviewsDeep.compactMap { $0 as? NSTableView }.first)
        #expect(!table.acceptsFirstResponder)
    }
    /// A hosted window gets no clicks, so `chooseRow` stands in for them above. This is the link from a real one.
    @Test func aClickOnTheTableComesToTheList() throws {
        let list = SwitcherList(selectsFirstRow: true)
        let table = try #require(list.subviewsDeep.compactMap { $0 as? NSTableView }.first)
        #expect(table.target === list)
        #expect(list.responds(to: table.action))
    }
}
