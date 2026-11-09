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
        b.session.save(SessionSnapshot(windows: [], parked: parked))
        app.restoreSession()
        #expect(b.parked == parked)
        app.openWindow(restoring: nil, in: b) // so the save below really writes b
        app.saveAllSessions()
        #expect(b.session.load().parked == parked)
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

    func window(_ urls: String...) -> WindowSnapshot {
        WindowSnapshot(tabs: urls.map { TabRecord(url: URL(string: $0)) }, activeIndex: 0, frame: "")
    }
}
