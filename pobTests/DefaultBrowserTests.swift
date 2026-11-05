import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct DefaultBrowserTests {
    @Test(arguments: ["https://example.com", "http://example.com", "file:///tmp/a.html"])
    func webAndFileLinksOpen(link: String) {
        let url = URL(string: link)!
        #expect(IncomingLink.address(for: url) == .url(url))
    }
    @Test(arguments: ["javascript:alert(1)", "mailto:a@b.c", "ftp://example.com"])
    func otherLinksAreIgnored(link: String) {
        #expect(IncomingLink.address(for: URL(string: link)!) == nil)
    }
    @Test func theAppDeclaresItCanOpenWebLinks() throws {
        let info = try #require(Bundle(for: Tab.self).infoDictionary)
        let types = try #require(info["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        #expect(Set(schemes).isSuperset(of: ["http", "https"]))
        #expect(types.allSatisfy { $0["CFBundleTypeRole"] as? String == "Viewer" })
    }
    @Test func theAppDeclaresItCanOpenHTMLFiles() throws {
        let info = try #require(Bundle(for: Tab.self).infoDictionary)
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        #expect(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }.contains("public.html"))
    }
    @Test func localFilesLoad() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".html")
        try "<title>Local</title>".write(to: file, atomically: true, encoding: .utf8)
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.load(.url(file)) }
        #expect(await eventually { tab.webView.title == "Local" }) // the title can land just after the finish
    }
    /// A saved tab on a local file has to come back with its content, not just its address.
    @Test func aSavedLocalFileComesBack() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".html")
        try "<title>Local</title>".write(to: file, atomically: true, encoding: .utf8)
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let tab = tabs.newTab(.url(file), activate: false)
        let id = tabs.list.records[1].id
        #expect(await eventually { tab.webView.title == "Local" })
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        tabs.updatePhases(now: Date().addingTimeInterval(800), memoryPressure: true)
        #expect(tabs.liveTab(id) == nil)

        tabs.activate(id)
        let rebuilt = try #require(tabs.liveTab(id))
        #expect(await eventually { rebuilt.webView.title == "Local" })
    }
}

/// `AppController` with a temporary profile, windows off screen and the key window passed in.
@Suite struct IncomingLinkTests {
    let first = URL(string: "https://example.com/first")!
    let second = URL(string: "https://example.com/second")!

    func makeApp(_ profile: Profile = .temporary()) -> AppController {
        let settings = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let app = AppController()
        app.profile = profile
        app.appearance = AppearanceModel(store: SettingsStore(fileURL: settings), reduceTransparency: false)
        return app
    }
    func urls(of window: WindowController) -> [URL?] { window.tabs.list.records.map(\.url) }
    func activeURL(of window: WindowController) -> URL? { window.tabs.list.active?.url }
    func saved(_ profile: Profile, _ name: String) {
        let record = TabRecord(url: URL(string: "about:blank#\(name)"), title: name)
        profile.session.save(SessionSnapshot(windows: [WindowSnapshot(tabs: [record], activeIndex: 0, frame: "")]))
    }

    @Test func aLinkOpensAsTheActiveTabOfTheFrontWindow() {
        let app = makeApp()
        app.restoreSession()
        app.application(NSApp, open: [first])
        #expect(app.windows.count == 1)
        #expect(urls(of: app.windows[0]) == [first])
        #expect(activeURL(of: app.windows[0]) == first)
    }
    @Test func severalLinksEachGetATabAndTheLastIsActive() {
        let app = makeApp()
        app.restoreSession()
        app.application(NSApp, open: [first, URL(string: "mailto:a@b.c")!, second])
        #expect(urls(of: app.windows[0]) == [first, second])
        #expect(activeURL(of: app.windows[0]) == second)
    }
    @Test func linksOfOtherKindsOpenNothing() {
        let app = makeApp()
        app.restoreSession()
        app.application(NSApp, open: [URL(string: "ftp://example.com")!])
        #expect(app.windows[0].tabs.isEmpty)
    }
    @Test func theKeyBrowserWindowIsTheOneThatGetsIt() {
        let app = makeApp()
        app.restoreSession()
        app.openWindow(restoring: nil)
        app.open([first], keyWindow: app.windows[0].window)
        #expect(urls(of: app.windows[0]) == [first])
        #expect(app.windows[1].tabs.isEmpty)
    }
    @Test func aKeySheetDoesNotMeanNoWindow() {
        let app = makeApp()
        app.restoreSession()
        app.open([first], keyWindow: NSWindow())
        #expect(app.windows.count == 1)
        #expect(urls(of: app.windows[0]) == [first])
    }
    @Test func theSwitcherClosesFirst() {
        let app = makeApp()
        app.restoreSession()
        #expect(!app.windows[0].switcher.isHidden)
        app.open([first], keyWindow: app.windows[0].window)
        #expect(app.windows[0].switcher.isHidden)
    }
    @Test func withNoWindowALinkOpensOne() {
        let app = makeApp()
        app.restoreSession()
        app.windows[0].perform(.closeWindow)
        #expect(app.windows.isEmpty)
        app.application(NSApp, open: [first])
        #expect(app.windows.count == 1)
        #expect(urls(of: app.windows[0]) == [first])
        #expect(app.windows[0].switcher.isHidden)
    }

    // MARK: Before launch finishes

    @Test func aLinkWaitsForTheRestoredSessionAndEndsActive() {
        let profile = Profile.temporary()
        saved(profile, "kept")
        let app = makeApp(profile)
        app.application(NSApp, open: [first])
        #expect(app.windows.isEmpty)

        app.restoreSession()
        #expect(app.windows.count == 1)
        #expect(urls(of: app.windows[0]).map { $0?.absoluteString } == ["about:blank#kept", first.absoluteString])
        #expect(activeURL(of: app.windows[0]) == first)
    }
    @Test func launchingForALinkLeavesNoEmptyWindowBesideIt() {
        let app = makeApp()
        app.application(NSApp, open: [first])
        app.restoreSession()
        #expect(app.windows.count == 1)
        #expect(urls(of: app.windows[0]) == [first])
        #expect(app.windows[0].switcher.isHidden)
    }

    // MARK: Make default

    @Test func makingDefaultAsksForBothSchemesWithNoWindow() async {
        let app = makeApp()
        var asked: [String] = []
        app.requestDefault = { asked.append($0) }
        await app.makeDefaultBrowser(keyWindow: nil)
        #expect(asked == ["http", "https"])
    }
    @Test func aFailureShowsAnAlert() async {
        struct Refused: Error {}
        let app = makeApp()
        app.requestDefault = { _ in throw Refused() }
        let alerted = await wentModal { await app.makeDefaultBrowser(keyWindow: nil) }
        #expect(alerted)
    }
    @Test func theSwitcherRowRunsIt() async {
        let app = makeApp()
        var asked: [String] = []
        app.requestDefault = { asked.append($0) }
        app.restoreSession()
        let row = SwitcherRow(target: .command(.makeDefaultBrowser), title: "Make pob the Default Browser", subtitle: "", section: "Commands")
        app.windows[0].switcher.onChoose?(row)
        #expect(await eventually { asked == ["http", "https"] })
    }
    @Test func theCommandReachesItWithNoWindow() async {
        let app = makeApp()
        var asked: [String] = []
        app.requestDefault = { asked.append($0) }
        app.perform(.makeDefaultBrowser, keyWindow: nil)
        #expect(await eventually { asked == ["http", "https"] })
    }
}
