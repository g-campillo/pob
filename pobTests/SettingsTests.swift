import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct SettingsTests {
    @Test func aStage2SettingsFileKeepsItsLook() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        try Data(#"{"transparency":0.3,"blur":10}"#.utf8).write(to: url)
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        #expect(model.settings.transparency == 0.3 && model.settings.blur == 10)
        #expect(model.searchEngine == .google)
    }
    @Test func theEngineIsSavedAndASliderKeepsIt() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        model.searchEngine = .duckDuckGo
        let popover = AppearancePopover(model: model)
        popover.loadView()
        popover.transparencySlider.doubleValue = 40
        popover.slidersChanged()
        popover.slidersFinished()
        #expect(AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false).searchEngine == .duckDuckGo)
    }
    @Test(arguments: [
        (SearchEngine.google, "https://www.google.com/search?q=two%20words"),
        (.duckDuckGo, "https://duckduckgo.com/?q=two%20words"),
        (.bing, "https://www.bing.com/search?q=two%20words"),
    ])
    func eachEngineSearches(engine: SearchEngine, expected: String) {
        #expect(AddressInput.classify("two words", engine: engine) == .search(URL(string: expected)!))
    }
    /// The page is stopped as soon as it has the address, so the search never reaches the internet.
    @Test func theAddressFieldAndSwitcherUseTheChosenEngine() async {
        let appearance = testAppearance()
        appearance.searchEngine = .duckDuckGo
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: appearance, tabs: tabs)
        let expected = URL(string: "https://duckduckgo.com/?q=two%20words")!

        controller.rail.onSubmit?("two words")
        #expect(tab.webView.url == expected)
        tab.webView.stopLoading()

        controller.perform(.openSwitcher)
        controller.switcher.onQueryChange?("two words")
        let row = controller.switcher.list.rows.first { $0.target == .address(.search(expected)) }
        #expect(row?.subtitle == "Search DuckDuckGo")
    }
    @Test func addingAndRenamingShowInTheModel() {
        let list = ProfileList(file: JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")))
        let model = SettingsModel(profiles: list, appearance: testAppearance())
        model.addProfile()
        #expect(model.profiles.map(\.name) == ["Main", "Profile 2"])
        model.rename(model.profiles[1].id, to: "Work")
        #expect(list.name(of: model.profiles[1].id) == "Work")
    }
    @Test func theModelsEngineIsTheAppearances() {
        let list = ProfileList(file: JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")))
        let appearance = testAppearance()
        let model = SettingsModel(profiles: list, appearance: appearance)
        #expect(model.searchEngine == .google)
        model.searchEngine = .bing
        #expect(appearance.searchEngine == .bing)
    }
    @Test func settingsOpensOnce() {
        let (app, _, _) = ProfileWindowsTests().app()
        app.perform(.openSettings, keyWindow: nil)
        let first = app.settingsWindow
        app.perform(.openSettings, keyWindow: nil)
        #expect(first != nil && app.settingsWindow === first)
    }
    /// A hosted view has no size until it's on screen, so the window is given one, or it centers as a sliver.
    @Test func theWindowIsSizedToItsContent() throws {
        let (app, _, _) = ProfileWindowsTests().app()
        app.openSettings()
        let window = try #require(app.settingsWindow?.window)
        #expect(window.contentLayoutRect.width == 480 && window.contentLayoutRect.height > 300)
        #expect(window.title == "Settings" && window.styleMask == [.titled, .closable] && !window.isReleasedWhenClosed)
    }
    /// Hosted windows are never visible, so ⌘N alone would pass by opening a window as if none were showing. ⌘T can only
    /// pass by reaching the window that's there.
    @Test func commandsFromSettingsReachTheFrontBrowserWindow() {
        let (app, a, _) = ProfileWindowsTests().app()
        app.openWindow(restoring: ProfileWindowsTests().window("https://a.example/"), in: a) // a tab, so no switcher yet
        app.perform(.openSettings, keyWindow: nil)
        app.perform(.openSwitcher, keyWindow: app.settingsWindow?.window)
        #expect(app.windows.count == 1 && !app.windows[0].switcher.isHidden)
        app.perform(.newWindow, keyWindow: app.settingsWindow?.window)
        #expect(app.windows.count == 2)
    }
    /// ⌘W in Settings means Settings, not a page behind it.
    @Test func closingFromSettingsClosesSettings() {
        let (app, a, _) = ProfileWindowsTests().app()
        app.openWindow(restoring: ProfileWindowsTests().window("https://a.example/"), in: a)
        app.perform(.openSettings, keyWindow: nil)
        app.perform(.closeTab, keyWindow: app.settingsWindow?.window)
        app.perform(.closeWindow, keyWindow: app.settingsWindow?.window)
        #expect(app.windows.count == 1 && app.windows[0].tabs.list.records.count == 1)
    }
    @Test func settingsMakesPobTheDefaultBrowser() async {
        let (app, _, _) = ProfileWindowsTests().app()
        var asked: [String] = []
        app.requestDefault = { asked.append($0) }
        app.openSettings()
        app.settingsWindow?.model.makeDefaultBrowser()
        #expect(await eventually { asked == ["http", "https"] })
    }
    @Test func theCommandIsFirstInThePobMenu() {
        let menu = MainMenu.build(commands: .standard { _ in })
        let item = menu.item(withTitle: "pob")?.submenu?.items.first
        #expect(item?.title == "Settings…" && item?.keyEquivalent == ",")
    }
    @Test func theProfileMenuAndPopoverOpenSettings() throws {
        let (app, _, b) = ProfileWindowsTests().app()
        app.openWindow(restoring: nil, in: b)
        let menu = app.windows[0].profileMenu()
        let index = try #require(menu.items.firstIndex { $0.title == "Manage Profiles…" })
        #expect(menu.items[index - 1].isSeparatorItem)
        menu.performActionForItem(at: index)
        #expect(app.settingsWindow?.model.selectedProfileID == b.id)

        var opened = false
        let popover = AppearancePopover(model: testAppearance()) { opened = true }
        popover.loadView()
        let button = try #require(popover.view.subviewsDeep.compactMap { $0 as? NSButton }.first { $0.title == "Settings…" })
        button.performClick(nil)
        #expect(opened)
    }
    @Test func aPrivateWindowManagesItsParentProfile() throws {
        let (app, _, b) = ProfileWindowsTests().app()
        app.openWindow(restoring: nil, in: .makePrivate(from: b))
        let menu = app.windows[0].profileMenu()
        menu.performActionForItem(at: try #require(menu.items.firstIndex { $0.title == "Manage Profiles…" }))
        #expect(app.settingsWindow?.model.selectedProfileID == b.id)
    }
}
