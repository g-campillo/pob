import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct ProfileWindowsTests {
    /// An app with two temporary profiles, A first, so nothing touches the real folder. Each has the id it's listed under.
    func app() -> (AppController, a: Profile, b: Profile) {
        let a = Profile.temporary(id: Profile.initialID)
        let controller = AppController()
        let list = ProfileList(file: JSONFile(url: a.directory.appending(path: "profiles.json")))
        let b = Profile.temporary(id: list.add(name: "B").id)
        let profiles = [a.id: a, b.id: b]
        controller.profiles = list
        controller.makeProfile = { profiles[$0]! }
        controller.profile = a
        controller.appearance = AppearanceModel(store: SettingsStore(fileURL: a.directory.appending(path: "settings.json")), reduceTransparency: false)
        return (controller, a, b)
    }

    @Test func eachProfileGetsItsOwnWindowsBack() {
        let (app, a, b) = app()
        a.session.save(SessionSnapshot(windows: [window("https://a.example/", "https://a2.example/")]))
        b.session.save(SessionSnapshot(windows: [window("https://b.example/")]))
        app.restoreSession()
        #expect(app.windows.count == 2)
        #expect(app.windows.map { $0.tabs.profile === a } == [true, false])
        #expect(app.windows[1].tabs.list.records.map { $0.url?.host() } == ["b.example"])
    }
    @Test func parkedTabsComeBackIntoTheProfileAndSurviveASave() {
        let (app, _, b) = app()
        let parked = window("https://parked.example/")
        b.session.save(SessionSnapshot(windows: [window("https://b.example/")], parked: parked))
        app.restoreSession()
        #expect(b.parked == parked)
        app.saveAllSessions()
        #expect(b.session.load().parked == parked)
    }
    /// With no window left in their profile, nothing else would ever bring parked tabs back.
    @Test func aNewWindowInAProfileWithNoneOpenBringsItsParkedTabsBack() async {
        let (app, a, _) = app()
        app.openWindow(restoring: window("https://a.example/", "https://a2.example/"), in: a)
        let parkedFrame = NSRect(x: 100, y: 120, width: 900, height: 700)
        app.windows[0].window?.setFrame(parkedFrame, display: false)
        await app.switchProfile(of: app.windows[0], to: bID(app))
        app.windows[0].window?.close()
        #expect(app.windows.isEmpty && a.parked != nil)
        app.perform(.newWindow, keyWindow: nil)
        #expect(app.windows.count == 1 && app.windows[0].tabs.profile === a)
        #expect(app.windows[0].tabs.list.records.map { $0.url?.host() } == ["a.example", "a2.example"])
        #expect(app.windows[0].window?.frame != parkedFrame) // a new window's place
        #expect(a.parked == nil)
        let saved = a.session.load()
        #expect(saved.parked == nil && saved.windows.map(\.tabs.count) == [2])
    }
    @Test func aLaunchWithOnlyParkedTabsOpensThem() {
        let (app, a, _) = app()
        a.session.save(SessionSnapshot(windows: [], parked: window("https://parked.example/")))
        app.restoreSession()
        #expect(app.windows.count == 1 && app.windows[0].tabs.profile === a)
        #expect(app.windows[0].tabs.list.records.map { $0.url?.host() } == ["parked.example"])
        #expect(a.parked == nil && a.session.load().parked == nil)
    }
    /// While the profile has a window, its parked tabs wait for a switch back.
    @Test func aNewWindowBesideAnOpenOneLeavesTheParkedTabsParked() async {
        let (app, a, _) = app()
        app.openWindow(restoring: window("https://a.example/"), in: a)
        app.openWindow(restoring: window("https://a2.example/"), in: a)
        await app.switchProfile(of: app.windows[0], to: bID(app)) // the first parks, the second stays in A
        #expect(app.windows[0].tabs.profile === a)
        app.windows[0].perform(.newWindow)
        #expect(app.windows.count == 3 && app.windows[2].tabs.profile === a && app.windows[2].tabs.isEmpty)
        #expect(a.parked?.tabs.count == 1)
    }
    @Test func aWindowsChangesSaveOnlyItsProfile() async {
        let (app, a, b) = app()
        app.openWindow(restoring: window("https://a.example/"), in: a)
        app.windows[0].tabs.newTab(.url(URL(string: "about:blank")!), activate: true)
        #expect(await eventually { a.session.load().windows.first?.tabs.count == 2 })
        #expect(!FileManager.default.fileExists(atPath: b.directory.appending(path: "session.json").path()))
    }
    @Test func newWindowStaysInItsProfile() {
        let (app, _, b) = app()
        app.openWindow(restoring: nil, in: b)
        app.windows[0].perform(.newWindow)
        #expect(app.windows.count == 2)
        #expect(app.windows[1].tabs.profile === b)
    }
    @Test func aWindowWithNothingToSayOpensInTheFirstProfile() {
        let (app, a, _) = app()
        app.restoreSession() // no sessions anywhere
        #expect(app.windows.count == 1)
        #expect(app.windows[0].tabs.profile === a)
    }
    @Test func everyProfileWithAWindowCanShowADownloadNotice() {
        let (app, _, b) = app()
        app.openWindow(restoring: nil, in: b)
        #expect(b.downloads.onStart != nil)
        #expect(b.downloads.frontWindow != nil)
    }
    @Test func quittingSavesEveryProfile() {
        let (app, a, b) = app()
        app.openWindow(restoring: window("https://a.example/"), in: a)
        app.openWindow(restoring: window("https://b.example/"), in: b)
        app.saveAllSessions()
        #expect(a.session.load().windows.count == 1)
        #expect(b.session.load().windows.count == 1)
    }
    @Test func switchingParksTheTabsAndBringsThemBack() async {
        let (app, a, b) = app()
        app.openWindow(restoring: window("https://a.example/", "https://a2.example/"), in: a)
        await app.switchProfile(of: app.windows[0], to: bID(app))
        #expect(app.windows.count == 1)
        #expect(app.windows[0].tabs.profile === b)
        #expect(app.windows[0].tabs.isEmpty)
        #expect(a.parked?.tabs.count == 2)
        #expect(a.session.load().parked?.tabs.count == 2)
        await app.switchProfile(of: app.windows[0], to: Profile.initialID)
        #expect(app.windows[0].tabs.list.records.map { $0.url?.host() } == ["a.example", "a2.example"])
        #expect(a.parked == nil && b.parked == nil) // an empty window parks nothing
    }
    @Test func switchingKeepsTheWindowsPlace() async {
        let (app, a, _) = app()
        app.openWindow(restoring: nil, in: a)
        app.windows[0].window?.setFrame(NSRect(x: 100, y: 120, width: 900, height: 700), display: false)
        await app.switchProfile(of: app.windows[0], to: bID(app))
        #expect(app.windows[0].window?.frame == NSRect(x: 100, y: 120, width: 900, height: 700))
    }
    @Test func parkingTwiceKeepsEveryTab() async {
        let (app, a, _) = app()
        app.openWindow(restoring: window("https://1.example/"), in: a)
        app.openWindow(restoring: window("https://2.example/", "https://3.example/"), in: a)
        await app.switchProfile(of: app.windows[0], to: bID(app))
        await app.switchProfile(of: app.windows[0], to: bID(app)) // the second A window, now first in the list
        #expect(a.parked?.tabs.count == 3)
    }
    @Test func aWindowInACallAsksFirstAndCancelChangesNothing() async {
        let (app, a, _) = app()
        app.openWindow(restoring: window("https://call.example/"), in: a)
        app.windows[0].tabs.isCapturing = { _ in true }
        var asked = 0
        app.confirmSwitch = { _ in asked += 1; return false }
        await app.switchProfile(of: app.windows[0], to: bID(app))
        #expect(asked == 1)
        #expect(app.windows[0].tabs.profile === a && a.parked == nil)
    }
    /// The sheet waits on the user, and a window closed meanwhile has nothing left to switch.
    @Test func aWindowClosedDuringTheSheetIsntSwitched() async {
        let (app, a, _) = app()
        app.openWindow(restoring: window("https://call.example/"), in: a)
        app.windows[0].tabs.isCapturing = { _ in true }
        app.confirmSwitch = { controller in
            controller.window?.close()
            return true
        }
        await app.switchProfile(of: app.windows[0], to: bID(app))
        #expect(app.windows.isEmpty && a.parked == nil)
    }
    /// A switch into a profile that was deleted while the sheet was up would leave a window in a forgotten profile.
    @Test func aSwitchConfirmedDuringADeleteStaysPut() async throws {
        let (app, a, b) = app()
        app.openWindow(restoring: window("https://call.example/"), in: a)
        app.windows[0].tabs.isCapturing = { _ in true }
        let (gate, release) = AsyncStream<Void>.makeStream()
        var started = false
        app.removeDataStore = { _ in
            started = true
            for await _ in gate {} // until it's released
        }
        var deletion: Task<Void, any Error>?
        app.confirmSwitch = { [weak app] _ in
            deletion = Task { try await app?.deleteProfile(b.id) }
            _ = await eventually { started }
            return true
        }
        await app.switchProfile(of: app.windows[0], to: b.id)
        #expect(app.windows.count == 1 && app.windows[0].tabs.profile === a && a.parked == nil)
        release.finish()
        try await deletion?.value
        #expect(app.profiles?.all.map(\.id) == [Profile.initialID])
    }
    /// The sheet promises the call ends, which only holds if nothing keeps the old window's pages alive.
    @Test func aConfirmedSwitchReleasesTheOldWindowAndItsPages() async {
        let (app, a, _) = app()
        app.openWindow(restoring: window("https://call.example/", "https://other.example/"), in: a)
        app.windows[0].tabs.isCapturing = { _ in true }
        app.confirmSwitch = { _ in true }
        weak let old = app.windows[0]
        weak let webView = app.windows[0].tab?.webView
        #expect(webView != nil)
        await app.switchProfile(of: app.windows[0], to: bID(app))
        #expect(await eventually { old == nil && webView == nil })
    }
    @Test func theMenuListsEveryProfileAndChecksThisOne() {
        let (app, a, _) = app()
        app.openWindow(restoring: nil, in: a)
        let items = app.windows[0].profileMenu().items
        #expect(items.prefix(2).map(\.title) == ["Main", "B"])
        #expect(items[0].state == .on && items[1].state == .off)
        #expect(items.contains { $0.title == "New Private Window" })
    }
    @Test func renamingAProfileRelabelsItsWindows() {
        let (app, a, _) = app()
        app.openWindow(restoring: nil, in: a)
        app.profiles?.rename(Profile.initialID, to: "Home")
        #expect(app.windows[0].rail.profileButton.title == "Home")
    }

    @Test func aSwitchedWindowIsNamedAndItsPagesUseThatProfilesStore() async {
        let (app, a, _) = app()
        app.openWindow(restoring: window("https://a.example/"), in: a)
        await app.switchProfile(of: app.windows[0], to: bID(app))
        #expect(app.windows[0].rail.profileButton.title == "B")
        await app.switchProfile(of: app.windows[0], to: Profile.initialID)
        #expect(app.windows[0].rail.profileButton.title == "Main")
        #expect(app.windows[0].tab?.webView.configuration.websiteDataStore === a.dataStore)
    }
    @Test func aPrivateWindowOffersNoProfileAndNeverSwitches() async {
        let (app, a, _) = app()
        app.openWindow(restoring: nil, in: .makePrivate(from: a))
        #expect(app.windows[0].profileMenu().items.filter { !$0.isSeparatorItem }.map(\.title) == ["New Private Window", "Manage Profiles…"])
        await app.switchProfile(of: app.windows[0], to: bID(app))
        #expect(app.windows.count == 1 && app.windows[0].tabs.profile.isPrivate)
    }

    func bID(_ app: AppController) -> UUID { app.profiles!.all[1].id }

    func window(_ urls: String...) -> WindowSnapshot {
        WindowSnapshot(tabs: urls.map { TabRecord(url: URL(string: $0)) }, activeIndex: 0, frame: "")
    }
}
