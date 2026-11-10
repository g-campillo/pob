import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct FindAndZoomTests {
    @Test func zoomStepsThroughTheLevels() {
        #expect(ZoomLevels.larger(than: 1) == 1.1)
        #expect(ZoomLevels.smaller(than: 1) == 0.9)
    }
    @Test func zoomStopsAtTheEnds() {
        #expect(ZoomLevels.larger(than: 2) == 2)
        #expect(ZoomLevels.smaller(than: 0.5) == 0.5)
    }
    @Test func offStepValuesSnapToTheNextStep() {
        #expect(ZoomLevels.larger(than: 1.05) == 1.1)
        #expect(ZoomLevels.smaller(than: 1.05) == 1)
    }
    @Test func findReportsMatches() async {
        let tab = await tabWith(html: "<p>hello findme world</p>")
        #expect(await tab.find("findme", backwards: false))
        #expect(await tab.find("absent", backwards: false) == false)
    }
    @Test func commandsAreBound() {
        let list = CommandList.standard { _ in }
        #expect(list.command(.find)?.key == "f")
        #expect(list.command(.print)?.key == "p")
        #expect(list.command(.actualSize)?.key == "0")
        #expect(list.command(.zoomIn)?.key == "=")
        #expect(list.command(.zoomOut)?.key == "-")
        for id in [CommandID.find, .print, .zoomIn, .zoomOut, .actualSize] {
            #expect(list.command(id)?.isReserved == false, "\(id)")
        }
    }

    /// A text field's own background is a square box.
    @Test func theFindFieldSitsOnARoundedFill() {
        let bar = FindBar()
        #expect(!bar.field.drawsBackground)
        #expect(bar.subviewsDeep.contains { $0 is ActiveFill })
    }

    // MARK: Menu

    @Test func hiddenPlusItemSurvivesAndZoomsIn() throws {
        var received: [CommandID] = []
        let list = CommandList.standard { received.append($0) }
        let items = MainMenu.build(commands: list).items.compactMap(\.submenu).flatMap(\.items)
        let plus = try #require(items.first { $0.keyEquivalent == "+" })
        #expect(plus.isHidden)
        #expect(plus.allowsKeyEquivalentWhenHidden)
        #expect(plus.keyEquivalentModifierMask == .command)
        let target = try #require(plus.target as? NSObject)
        _ = target.perform(plus.action)
        #expect(received == [.zoomIn])
    }
    @Test func menusHoldTheNewCommands() {
        let menu = MainMenu.build(commands: CommandList.standard { _ in })
        let titles = { (name: String) in menu.item(withTitle: name)?.submenu?.items.map(\.title) ?? [] }
        #expect(titles("File").contains("Print…"))
        #expect(titles("Edit").contains("Find"))
        #expect(titles("View").contains("Zoom In"))
        #expect(titles("View").contains("Zoom Out"))
        #expect(titles("View").contains("Actual Size"))
    }

    // MARK: Zoom

    @Test func zoomCommandsChangeThePageAndSaveForTheHost() async {
        let tab = await tabWith(html: "<p>x</p>")
        tab.zoomIn()
        #expect(tab.webView.pageZoom == 1.1)
        #expect(tab.profile.siteSettings["localhost"].zoom == 1.1)
        tab.zoomOut()
        tab.zoomOut()
        #expect(tab.webView.pageZoom == 0.9)
        tab.actualSize()
        #expect(tab.webView.pageZoom == 1)
        #expect(tab.profile.siteSettings["localhost"].zoom == nil)
    }
    @Test func actualSizeLeavesNoEntryBehind() async {
        let tab = await tabWith(html: "<p>x</p>")
        tab.zoomIn()
        tab.actualSize()
        let saved = JSONFile<[String: SiteSetting]>(url: tab.profile.directory.appending(path: "sites.json")).load()
        #expect(saved?["localhost"] == nil)
    }
    @Test func savedZoomAppliesWhenAPageOnTheHostCommits() async {
        let profile = Profile.temporary()
        profile.siteSettings["localhost"].zoom = 1.5
        let tab = Tab(profile: profile)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        #expect(tab.webView.pageZoom == 1.5)
    }
    @Test func aHostWithNoSavedZoomShowsAtOneAfterAZoomedHost() async {
        let profile = Profile.temporary()
        profile.siteSettings["localhost"].zoom = 1.5
        let tab = Tab(profile: profile)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/")) }
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>y</p>", baseURL: URL(string: "https://other.test/")) }
        #expect(tab.webView.pageZoom == 1)
    }
    @Test func zoomOnAHostlessPageChangesItAndStoresNothing() async {
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: nil) }
        tab.zoomIn()
        #expect(tab.webView.pageZoom == 1.1)
        #expect(!FileManager.default.fileExists(atPath: tab.profile.directory.appending(path: "sites.json").path))
    }

    // MARK: Printing

    @Test func printOperationIsBuiltToThePageSize() async {
        let tab = await tabWith(html: "<p>x</p>")
        tab.webView.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        let operation = tab.printOperation()
        #expect(operation.view?.frame == tab.webView.bounds)
    }
    @Test func printHandsTheOperationToTheSeam() {
        let tab = Tab(profile: .temporary())
        var received = 0
        tab.printSeam = { _ in received += 1 }
        tab.printPage()
        #expect(received == 1)
    }

    // MARK: Find bar

    @Test func returnSearchesForward() {
        let bar = FindBar()
        var searches: [(String, Bool)] = []
        bar.onSearch = { searches.append(($0, $1)) }
        bar.field.stringValue = "abc"
        let handled = bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(handled)
        #expect(searches.count == 1 && searches[0].0 == "abc" && searches[0].1 == false)
    }
    @Test func escapeClosesTheBar() {
        let bar = FindBar()
        var closed = false
        bar.onClose = { closed = true }
        #expect(bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(closed)
    }
    @Test func notFoundShowsAndClearsWhenTheTextChanges() {
        let bar = FindBar()
        bar.showResult(found: false)
        #expect(!bar.notFoundLabel.isHidden)
        bar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: bar.field))
        #expect(bar.notFoundLabel.isHidden)
        bar.showResult(found: true)
        #expect(bar.notFoundLabel.isHidden)
    }
    @Test func theFieldTakesNoSubstitutions() {
        #expect(FindBar().field is LiteralTextField)
    }

    // MARK: Window

    func makeWindow() -> WindowController {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        return WindowController(appearance: model, tabs: tabs)
    }

    @Test func findOpensTheBarAndAHiddenBarCatchesNoClicks() throws {
        let controller = makeWindow()
        let window = try #require(controller.window)
        let bar = controller.findBar
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!bar.frame.isEmpty)
        let point = NSPoint(x: bar.frame.midX, y: bar.frame.midY) // in the superview, where hitTest looks
        #expect(bar.isHidden)
        #expect(bar.hitTest(point) == nil)
        controller.perform(.find)
        #expect(!bar.isHidden)
        #expect(bar.hitTest(point) != nil)
    }
    @Test func findAgainRefocusesTheBarAndSelectsItsText() throws {
        let controller = makeWindow()
        let window = try #require(controller.window)
        let bar = controller.findBar
        controller.perform(.find)
        bar.field.stringValue = "needle"
        #expect(window.makeFirstResponder(controller.tab?.webView))
        #expect(bar.field.currentEditor() == nil)
        controller.perform(.find)
        let editor = try #require(bar.field.currentEditor())
        #expect(window.firstResponder === editor)
        #expect(editor.selectedRange == NSRange(location: 0, length: 6))
    }
    @Test func returnOnEmptyTextSearchesNothing() {
        let bar = FindBar()
        var searched = false
        bar.onSearch = { _, _ in searched = true }
        #expect(bar.control(bar.field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        #expect(!searched)
    }
    @Test func escapeReturnsTheKeyboardToThePage() throws {
        let controller = makeWindow()
        controller.perform(.find)
        controller.findBar.onClose?()
        #expect(controller.findBar.isHidden)
        #expect(controller.window?.firstResponder === controller.tab?.webView)
    }
    @Test func switchingTabsAndOpeningTheSwitcherCloseTheBar() {
        let controller = makeWindow()
        controller.perform(.find)
        controller.tabs.newTab(nil, activate: true)
        #expect(controller.findBar.isHidden)
        controller.perform(.find)
        controller.perform(.openSwitcher)
        #expect(controller.findBar.isHidden)
        #expect(!controller.switcher.isHidden)
    }
    @Test func findThroughTheBarReportsNotFoundOnARealPage() async throws {
        let controller = makeWindow()
        let tab = try #require(controller.tab)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>hello findme</p>", baseURL: URL(string: "https://localhost/")) }
        controller.perform(.find)
        controller.findBar.field.stringValue = "absent"
        controller.findBar.onSearch?("absent", false)
        #expect(await eventually { !controller.findBar.notFoundLabel.isHidden })
        controller.findBar.onSearch?("findme", false)
        #expect(await eventually { controller.findBar.notFoundLabel.isHidden })
    }
    @Test func theNewCommandsAreSafeWithNoActiveTab() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        let controller = WindowController(appearance: model, tabs: tabs)
        for id in [CommandID.find, .print, .zoomIn, .zoomOut, .actualSize] {
            controller.perform(id)
        }
        #expect(controller.findBar.isHidden)
    }
    @Test func zoomAndPrintCommandsReachTheActiveTab() throws {
        let controller = makeWindow()
        let tab = try #require(controller.tab)
        var printed = 0
        tab.printSeam = { _ in printed += 1 }
        controller.perform(.zoomIn)
        #expect(tab.webView.pageZoom == 1.1)
        controller.perform(.zoomOut)
        controller.perform(.zoomOut)
        #expect(tab.webView.pageZoom == 0.9)
        controller.perform(.actualSize)
        #expect(tab.webView.pageZoom == 1)
        controller.perform(.print)
        #expect(printed == 1)
    }
}
