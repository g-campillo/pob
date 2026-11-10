import AppKit
import Foundation
import Testing
@testable import pob

@Suite(.timeLimit(.minutes(1))) struct PrivateWindowTests {
    @Test func aPrivateProfileSharesBookmarksButNotCookies() {
        let parent = Profile.temporary()
        let hidden = Profile.makePrivate(from: parent)
        #expect(hidden.isPrivate && hidden.parent === parent)
        #expect(hidden.bookmarks === parent.bookmarks)
        #expect(hidden.dataStore !== parent.dataStore)
        #expect(!hidden.dataStore.isPersistent)
        #expect(Profile.makePrivate(from: hidden).parent === parent)
    }
    /// The rail names a private window, but the rail hides. The badge doesn't.
    @Test func aPrivateWindowKeepsItsBadgeWhateverTheRailDoes() {
        let tabs = TabManager(profile: .makePrivate(from: .temporary()), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        let controller = WindowController(appearance: testAppearance(), tabs: tabs)
        #expect(!controller.privateBadge.isHidden)
        #expect(controller.privateBadge.superview === controller.window?.contentView)
        controller.perform(.toggleRail)
        controller.perform(.toggleRail)
        controller.perform(.openSwitcher)
        #expect(!controller.privateBadge.isHidden)
        #expect(controller.privateBadge.accessibilityLabel() == "Private window")
    }
    @Test func anOrdinaryWindowHasNoBadge() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        #expect(WindowController(appearance: testAppearance(), tabs: tabs).privateBadge.isHidden)
    }
    @Test func theBadgeNeverTakesClicks() {
        let badge = PrivateBadge(frame: NSRect(x: 0, y: 0, width: 26, height: 26))
        #expect(badge.hitTest(NSPoint(x: 13, y: 13)) == nil)
    }
    /// A real page through real WebKit, because history and icons are written from WebKit's callbacks.
    @Test func browsingPrivatelyLeavesNothingBehind() async throws {
        let server = LocalServer()
        server.routes = [
            "/": .body(Data("<title>Secret</title><link rel=icon href=/i.png>".utf8), headers: ["Content-Type": "text/html"]),
            "/i.png": .body(Data(base64Encoded: tinyPNG)!, headers: ["Content-Type": "image/png"]),
        ]
        try await server.start()
        defer { server.stop() }
        let parent = Profile.temporary()
        let tabs = TabManager(profile: .makePrivate(from: parent), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.load(.url(server.url("/"))) }
        #expect(await eventually { tab.title == "Secret" }) // the title can land just after the load ends
        try await Task.sleep(for: .milliseconds(300)) // history and favicon writes are async
        #expect(await parent.history.search("Secret", limit: 10).isEmpty)
        #expect(await tabs.profile.history.search("Secret", limit: 10).isEmpty)
        #expect(parent.favicons.image(forHost: "127.0.0.1") == nil)
    }
    @Test func privateWindowsAreNeverInASession() {
        let (app, a, _) = ProfileWindowsTests().app()
        app.openWindow(restoring: ProfileWindowsTests().window("https://a.example/"), in: a)
        app.windows[0].perform(.newPrivateWindow)
        #expect(app.windows.count == 2)
        #expect(app.windows[1].tabs.profile.isPrivate)
        app.windows[1].tabs.newTab(.url(URL(string: "about:blank")!), activate: true)
        #expect(app.sessionSnapshot(of: a).windows.count == 1) // only A's own window
    }
    @Test func newWindowInAPrivateWindowSharesItsSession() {
        let (app, a, _) = ProfileWindowsTests().app()
        app.openWindow(restoring: nil, in: .makePrivate(from: a))
        app.windows[0].perform(.newWindow)
        #expect(app.windows[1].tabs.profile === app.windows[0].tabs.profile)
        app.windows[0].perform(.newPrivateWindow)
        #expect(app.windows[2].tabs.profile !== app.windows[0].tabs.profile)
        #expect(app.windows[2].tabs.profile.parent === a)
    }
    @Test func closingTheLastPrivateWindowRemovesItsFolder() async throws {
        let (app, a, _) = ProfileWindowsTests().app()
        app.openWindow(restoring: nil, in: .makePrivate(from: a))
        app.windows[0].perform(.newWindow)
        let profile = app.windows[0].tabs.profile
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        app.windows[0].window?.close()
        #expect(FileManager.default.fileExists(atPath: profile.directory.path())) // its other window still uses it
        app.windows[0].window?.close()
        #expect(!FileManager.default.fileExists(atPath: profile.directory.path()))
    }
    /// ⌘Q sends no window a close, so a private window can't rely on its folder being removed.
    @Test func privateSiteSettingsStayInMemory() {
        let hidden = Profile.makePrivate(from: .temporary())
        hidden.siteSettings["x.example"].zoom = 1.5
        #expect(hidden.siteSettings["x.example"].zoom == 1.5)
        #expect(!FileManager.default.fileExists(atPath: hidden.directory.appending(path: "sites.json").path()))
        #expect(!FileManager.default.fileExists(atPath: hidden.directory.path()))
    }
    /// Its cookies live in memory, so they go when it does.
    @Test func aClosedPrivateProfileIsReleased() async {
        let (app, a, _) = ProfileWindowsTests().app()
        app.openWindow(restoring: nil, in: .makePrivate(from: a))
        weak let profile = app.windows[0].tabs.profile
        #expect(await eventually { profile?.spareTab != nil }) // the spare web view holds its profile
        app.windows[0].window?.close()
        #expect(await eventually { profile == nil })
    }
    @Test func withNoWindowTheShortcutOpensAPrivateOne() {
        let (app, _, _) = ProfileWindowsTests().app()
        app.perform(.newPrivateWindow, keyWindow: nil)
        #expect(app.windows.first?.tabs.profile.isPrivate == true)
    }
    @Test func thePrivateSwitcherSuggestsNoHistory() async {
        let parent = Profile.temporary()
        await parent.history.record(url: URL(string: "https://seen.example/")!, title: "Seen")
        let controller = WindowController(appearance: testAppearance(), tabs: TabManager(profile: .makePrivate(from: parent), keepsSpare: false))
        #expect(await controller.searchHistory("seen").isEmpty)
    }
    @Test func theRailSaysPrivate() {
        let controller = WindowController(appearance: testAppearance(), tabs: TabManager(profile: .makePrivate(from: .temporary()), keepsSpare: false))
        #expect(controller.rail.profileButton.title == "Private")
        #expect(!controller.rail.profileButton.isEnabled)
    }
    @Test func theRailNamesTheWindowsProfile() {
        let (app, _, b) = ProfileWindowsTests().app()
        app.openWindow(restoring: nil, in: b)
        #expect(app.windows[0].rail.profileButton.title == "B")
        #expect(app.windows[0].rail.profileButton.accessibilityLabel() == "Profile: B")
        #expect(app.windows[0].rail.profileButton.isEnabled)
    }
}
