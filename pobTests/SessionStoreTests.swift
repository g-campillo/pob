import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct SessionStoreTests {
    func file() -> JSONFile<SessionSnapshot> {
        JSONFile(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json"))
    }

    @Test func snapshotsRoundTrip() {
        let file = file()
        let record = TabRecord(url: URL(string: "https://example.com"), title: "E", interactionState: Data([1, 2, 3]))
        let snapshot = SessionSnapshot(windows: [WindowSnapshot(tabs: [record], activeIndex: 0, frame: "0 0 800 600")])
        SessionStore(file: file).save(snapshot)
        #expect(SessionStore(file: file).load() == snapshot)
    }
    @Test func corruptSessionsStartEmpty() throws {
        let file = file()
        try "{\"windows\":".write(to: file.url, atomically: true, encoding: .utf8)
        #expect(SessionStore(file: file).load().windows.isEmpty)
    }
    @Test func restoringBuildsOnlyTheActiveTab() {
        let records = (0..<50).map { TabRecord(url: URL(string: "https://example.com/\($0)")) }
        let snapshot = WindowSnapshot(tabs: records, activeIndex: 3, frame: "")
        let tabs = TabManager(profile: .temporary(), keepsSpare: false, restoring: snapshot)
        #expect(tabs.list.records.count == 50)
        #expect(tabs.list.activeID == records[3].id)
        #expect(tabs.liveTab(records[3].id) != nil)
        #expect(tabs.liveTab(records[0].id) == nil)
    }
    @Test func anOutOfRangeActiveIndexIsSafe() {
        let snapshot = WindowSnapshot(tabs: [TabRecord()], activeIndex: 9, frame: "")
        let tabs = TabManager(profile: .temporary(), keepsSpare: false, restoring: snapshot)
        #expect(tabs.list.activeID == snapshot.tabs[0].id)
    }
    @Test func aDamagedPageStateDoesntCrash() {
        let record = TabRecord(url: URL(string: "https://localhost/"), interactionState: Data([1, 2, 3]))
        let snapshot = WindowSnapshot(tabs: [record], activeIndex: 0, frame: "")
        #expect(TabManager(profile: .temporary(), keepsSpare: false, restoring: snapshot).activeTab != nil)
    }
    @Test func savingCapturesLiveTabState() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/page")) }
        #expect(tabs.snapshotRecords.first?.url?.absoluteString == "https://localhost/page")
    }

    // MARK: Restoring

    @Test func restoredTabsStartSavedAndKeepTheirRecords() {
        let saved = TabRecord(url: URL(string: "https://example.com/b"), title: "B", interactionState: Data([9]))
        let active = TabRecord(url: URL(string: "about:blank"))
        let tabs = TabManager(profile: .temporary(), keepsSpare: false, restoring: WindowSnapshot(tabs: [active, saved], activeIndex: 0, frame: ""))
        #expect(tabs.phase(of: active.id) == .active)
        #expect(tabs.phase(of: saved.id) == .saved)
        #expect(tabs.snapshotRecords[1] == saved)
    }
    /// A title arrives late, and the page's blank one mustn't replace the saved one in the meantime.
    @Test func aLivePageWithNoTitleYetKeepsTheSavedTitle() {
        let record = TabRecord(title: "Saved")
        let tabs = TabManager(profile: .temporary(), keepsSpare: false, restoring: WindowSnapshot(tabs: [record], activeIndex: 0, frame: ""))
        #expect(tabs.snapshotRecords[0].title == "Saved")
    }
    /// Saved straight after a launch, before the page is back, the place it left off has to survive.
    @Test func aRestoredPageKeepsItsHistoryAcrossTwoLaunches() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.load(.url(URL(string: "data:text/html,one")!)) }
        await finishLoading(tab) { tab.load(.url(URL(string: "data:text/html,two")!)) }
        await finishLoading(tab) { tab.webView.goBack() }

        let first = TabManager(profile: .temporary(), keepsSpare: false, restoring: WindowSnapshot(tabs: tabs.snapshotRecords, activeIndex: 0, frame: ""))
        let second = TabManager(profile: .temporary(), keepsSpare: false, restoring: WindowSnapshot(tabs: first.snapshotRecords, activeIndex: 0, frame: ""))
        let page = try #require(second.activeTab)
        #expect(await eventually { page.webView.canGoForward && !page.webView.isLoading })
        #expect(page.webView.url?.absoluteString == "data:text/html,one")
    }
    /// Once the page is back the saved state is out of date, even during the next load, and keeping it would send the tab back to where it started.
    @Test func aRestoredPageThatMovesOnSavesItsNewPlace() async throws {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.load(.url(URL(string: "data:text/html,one")!)) }

        let restored = TabManager(profile: .temporary(), keepsSpare: false, restoring: WindowSnapshot(tabs: tabs.snapshotRecords, activeIndex: 0, frame: ""))
        let page = try #require(restored.activeTab)
        await finishLoading(page) {}
        await finishLoading(page) { page.load(.url(URL(string: "data:text/html,two")!)) }
        page.load(.url(URL(string: "data:text/html,three")!))

        let next = TabManager(profile: .temporary(), keepsSpare: false, restoring: WindowSnapshot(tabs: restored.snapshotRecords, activeIndex: 0, frame: ""))
        let moved = try #require(next.activeTab)
        #expect(await eventually { moved.webView.url?.absoluteString == "data:text/html,three" && !moved.webView.isLoading })
        #expect(moved.webView.backForwardList.backList.map(\.url.absoluteString) == ["data:text/html,one", "data:text/html,two"])
    }

    // MARK: Saving soon

    let tabID = UUID()
    func snapshot(_ title: String) -> SessionSnapshot {
        SessionSnapshot(windows: [WindowSnapshot(tabs: [TabRecord(id: tabID, title: title)], activeIndex: 0, frame: "")])
    }
    let empty = SessionSnapshot(windows: [])

    /// Reading every page's state isn't free, so it waits until the debounce fires, and then happens once.
    @Test func severalChangesMakeOneWriteOfTheLatest() async {
        let file = file()
        let store = SessionStore(file: file)
        var builds = 0
        for index in 0..<5 {
            store.saveSoon {
                builds += 1
                return snapshot("\(index)")
            }
        }
        #expect(builds == 0)
        #expect(await eventually { builds == 1 })
        #expect(await eventually { file.load() != nil })
        #expect(file.load()?.windows[0].tabs[0].title == "4")
        try? await Task.sleep(for: .milliseconds(700))
        #expect(builds == 1)
    }
    /// A page that keeps changing its title can't hold the save off.
    @Test func aStreamOfChangesStillSaves() async {
        let file = file()
        let store = SessionStore(file: file)
        for _ in 0..<12 {
            store.saveSoon { snapshot("x") }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(file.load() != nil)
    }
    @Test func savingNowReplacesAWaitingSave() async {
        let file = file()
        let store = SessionStore(file: file)
        var built = false
        store.saveSoon {
            built = true
            return snapshot("stale")
        }
        store.save(snapshot("now"))
        #expect(file.load() == snapshot("now"))
        try? await Task.sleep(for: .milliseconds(700))
        #expect(!built)
        #expect(file.load() == snapshot("now"))
    }
    /// At quit nothing is left to fix a late write, so one already running has to finish first.
    @Test func aSaveNowLandsAfterAWriteInProgress() async {
        let file = file()
        defer { try? FileManager.default.removeItem(at: file.url) }
        let store = SessionStore(file: file)
        let large = SessionSnapshot(windows: [WindowSnapshot(tabs: [TabRecord(interactionState: Data(count: 8_000_000))], activeIndex: 0, frame: "")])
        var built = false
        store.saveSoon {
            built = true
            return large
        }
        #expect(await eventually { built })
        store.save(snapshot("quit"))
        #expect(file.load() == snapshot("quit"))
        try? await Task.sleep(for: .milliseconds(300))
        #expect(file.load() == snapshot("quit"))
    }

    // MARK: Empty sessions

    @Test func anEmptySnapshotCantReplaceASessionThatFailedToLoad() async throws {
        let file = file()
        let unreadable = "{\"windows\":"
        try unreadable.write(to: file.url, atomically: true, encoding: .utf8)
        let store = SessionStore(file: file)
        #expect(store.load().windows.isEmpty)

        store.save(empty)
        store.saveSoon { empty }
        try? await Task.sleep(for: .milliseconds(700))
        #expect(try String(contentsOf: file.url, encoding: .utf8) == unreadable)

        store.save(snapshot("first tab"))
        #expect(file.load() == snapshot("first tab"))
    }
    /// A quit can arrive before launch has read the session.
    @Test func aStoreThatHasntLoadedCantWriteEmpty() {
        let file = file()
        SessionStore(file: file).save(snapshot("x"))
        SessionStore(file: file).save(empty)
        #expect(file.load() == snapshot("x"))
    }
    @Test func theSessionEmptiesOnceItHasHadTabs() {
        let file = file()
        SessionStore(file: file).save(snapshot("x"))
        let restored = SessionStore(file: file)
        #expect(restored.load() == snapshot("x"))
        restored.save(empty)
        #expect(file.load() == empty)

        let fresh = SessionStore(file: file)
        fresh.save(snapshot("y"))
        fresh.save(empty)
        #expect(file.load() == empty)
    }

    // MARK: Unreadable sessions

    func copy(of file: JSONFile<SessionSnapshot>) -> URL { file.url.appendingPathExtension("unreadable") }
    func hasCopy(of file: JSONFile<SessionSnapshot>) -> Bool { FileManager.default.fileExists(atPath: copy(of: file).path()) }

    /// Decoding is all or nothing, so a typo costs the whole session unless the file is kept.
    @Test func anUnreadableSessionIsCopiedBeforeTheFirstTabReplacesIt() throws {
        let file = file()
        let unreadable = "{\"windows\":"
        try unreadable.write(to: file.url, atomically: true, encoding: .utf8)

        let store = SessionStore(file: file)
        #expect(store.load().windows.isEmpty)
        #expect(try String(contentsOf: copy(of: file), encoding: .utf8) == unreadable)

        store.save(snapshot("first tab"))
        #expect(file.load() == snapshot("first tab"))
        #expect(try String(contentsOf: copy(of: file), encoding: .utf8) == unreadable)
    }
    /// A later stage adding a required field reads as this, not as a typo.
    @Test func aSessionMissingAFieldIsCopiedToo() throws {
        let file = file()
        let older = "{\"windows\":[{\"tabs\":[],\"activeIndex\":0}]}"
        try older.write(to: file.url, atomically: true, encoding: .utf8)
        #expect(SessionStore(file: file).load().windows.isEmpty)
        #expect(try String(contentsOf: copy(of: file), encoding: .utf8) == older)
    }
    @Test func aNewCopyReplacesAnEarlierOne() throws {
        let file = file()
        try "earlier".write(to: copy(of: file), atomically: true, encoding: .utf8)
        try "later".write(to: file.url, atomically: true, encoding: .utf8)
        _ = SessionStore(file: file).load()
        #expect(try String(contentsOf: copy(of: file), encoding: .utf8) == "later")
    }
    @Test func aMissingSessionLeavesNoCopy() {
        let file = file()
        #expect(SessionStore(file: file).load().windows.isEmpty)
        #expect(!hasCopy(of: file))
    }
    @Test func aGoodSessionLeavesNoCopy() {
        let file = file()
        SessionStore(file: file).save(snapshot("x"))
        #expect(SessionStore(file: file).load() == snapshot("x"))
        #expect(!hasCopy(of: file))
    }
    /// With no copy, the file is the only place what it holds still exists.
    @Test func aSessionThatCantBeCopiedIsNeverReplaced() throws {
        let file = file()
        let unreadable = "{\"windows\":"
        try unreadable.write(to: file.url, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: copy(of: file).appending(path: "in the way"), withIntermediateDirectories: true)

        let store = SessionStore(file: file)
        #expect(store.load().windows.isEmpty)
        store.save(snapshot("first tab"))
        #expect(try String(contentsOf: file.url, encoding: .utf8) == unreadable)
    }

    // MARK: Holding saves during a restore

    /// An exception out of a restore never reaches its end, and AppKit swallows it during launch, so this is the state it leaves.
    @Test func nothingIsWrittenWhileARestoreRuns() {
        let file = file()
        SessionStore(file: file).save(snapshot("good"))
        let store = SessionStore(file: file)
        store.restore { session in
            #expect(session == snapshot("good"))
            store.save(snapshot("partial"))
            store.save(empty)
            #expect(file.load() == snapshot("good"))
        }
        store.save(snapshot("after"))
        #expect(file.load() == snapshot("after"))
    }

    @Test func aStage2SessionWithNoParkedTabsLoads() throws {
        let file = file()
        try Data(#"{"windows":[{"tabs":[],"activeIndex":0,"frame":"0 0 800 600 0 0 1440 900 "}]}"#.utf8).write(to: file.url)
        let loaded = SessionStore(file: file).load()
        #expect(loaded.windows.count == 1)
        #expect(loaded.parked == nil)
    }
    @Test func parkedTabsAloneAreWorthSaving() throws {
        let file = file()
        let parked = WindowSnapshot(tabs: [TabRecord(url: URL(string: "https://a.example/"))], activeIndex: 0, frame: "")
        SessionStore(file: file).save(SessionSnapshot(windows: [], parked: parked))
        #expect(try file.read()?.parked == parked)
    }
    @Test func appendingKeepsEveryTabAndTheNewerPlace() {
        let a = WindowSnapshot(tabs: [TabRecord(url: nil), TabRecord(url: nil)], activeIndex: 1, frame: "a")
        let b = WindowSnapshot(tabs: [TabRecord(url: nil)], activeIndex: 0, frame: "b")
        let both = a.appending(b)
        #expect(both.tabs.map(\.id) == a.tabs.map(\.id) + b.tabs.map(\.id))
        #expect(both.activeIndex == 2)
        #expect(both.frame == "b")
    }
}

private final class Reached {
    var value = false
}

/// `AppController` with a temporary profile. Its windows stay off screen, and tests set the key window themselves.
@Suite struct SessionWindowsTests {
    func makeApp(_ profile: Profile = .temporary()) -> AppController {
        let settings = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let app = AppController()
        app.profile = profile
        app.appearance = AppearanceModel(store: SettingsStore(fileURL: settings), reduceTransparency: false)
        return app
    }
    func sessionFile(of profile: Profile) -> JSONFile<SessionSnapshot> {
        JSONFile(url: profile.directory.appending(path: "session.json"))
    }
    func page(_ name: String) -> TabRecord {
        TabRecord(url: URL(string: "about:blank#\(name)"), title: name)
    }
    func window(_ tabs: TabRecord..., active: Int = 0, frame: String = "") -> WindowSnapshot {
        WindowSnapshot(tabs: tabs, activeIndex: active, frame: frame)
    }
    let quit = Notification(name: NSApplication.willTerminateNotification)

    // MARK: The snapshot

    @Test func aSnapshotCoversEveryWindow() {
        let app = makeApp()
        let first = [page("a"), page("b")]
        let second = [page("c")]
        app.openWindow(restoring: WindowSnapshot(tabs: first, activeIndex: 1, frame: ""))
        app.openWindow(restoring: WindowSnapshot(tabs: second, activeIndex: 0, frame: ""))

        let windows = app.sessionSnapshot.windows
        #expect(windows.map { $0.tabs.map(\.id) } == [first.map(\.id), second.map(\.id)])
        #expect(windows.map(\.activeIndex) == [1, 0])
    }
    @Test func aWindowWithNoTabsIsLeftOut() {
        let app = makeApp()
        app.openWindow(restoring: nil)
        #expect(app.windows.count == 1)
        #expect(app.sessionSnapshot.windows.isEmpty)

        let kept = page("kept")
        app.openWindow(restoring: window(kept))
        #expect(app.windows.count == 2)
        #expect(app.sessionSnapshot.windows.map { $0.tabs.map(\.id) } == [[kept.id]])
    }
    @Test func closingAWindowDropsItFromTheSnapshot() {
        let app = makeApp()
        let closing = page("closing")
        let kept = page("kept")
        app.openWindow(restoring: window(closing))
        app.openWindow(restoring: window(kept))

        app.windows[0].perform(.closeWindow)
        #expect(app.windows.count == 1)
        #expect(app.sessionSnapshot.windows.map { $0.tabs.map(\.id) } == [[kept.id]])
    }
    @Test func theFrameComesBackThroughTheSnapshot() throws {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        let original = try #require(app.windows[0].window)
        original.setFrame(NSRect(x: 120, y: 140, width: 900, height: 640), display: false)
        let saved = try #require(app.windows[0].snapshot)

        let next = makeApp()
        next.openWindow(restoring: saved)
        let restored = try #require(next.windows[0].window)
        #expect(restored.frame == original.frame)
        #expect(next.windows[0].tab?.pageView.frame.size == restored.contentView?.bounds.size)
    }
    @Test func aSnapshotWithNoFrameKeepsTheDefaultOne() throws {
        let app = makeApp()
        app.openWindow(restoring: nil)
        app.openWindow(restoring: window(page("a"), frame: ""))
        #expect(app.windows[1].window?.frame == app.windows[0].window?.frame)
    }
    /// `setFrame(from:)` throws on a NaN in any field, and the file can hold anything.
    @Test(arguments: [
        "nan nan 900 640 0 0 3440 1410 ", "100 NaN 900 640 0 0 3440 1410 ", "100 100 nan 640 0 0 3440 1410 ",
        "100 100 900 640 0 0 3440 -nan ", "nan nan nan nan", "inf 100 900 640 0 0 3440 1410 ",
    ])
    func aFrameThatIsntAllFiniteNumbersIsIgnored(frame: String) {
        let app = makeApp()
        let saved = page("saved")
        app.openWindow(restoring: nil)
        app.openWindow(restoring: window(saved, frame: frame))
        #expect(app.windows.count == 2)
        #expect(app.windows[1].tabs.list.records.map(\.id) == [saved.id])
        #expect(app.windows[1].window?.frame == app.windows[0].window?.frame)
    }

    // MARK: Launch

    @Test func launchOpensOneWindowPerSavedWindow() {
        let profile = Profile.temporary()
        let active = page("active")
        let snapshot = SessionSnapshot(windows: [window(page("a"), active, active: 1), window(page("b"))])
        profile.session.save(snapshot)

        let app = makeApp(profile)
        app.restoreSession()
        #expect(app.windows.count == 2)
        #expect(app.windows[0].tabs.list.activeID == active.id)
        #expect(app.windows.allSatisfy { $0.switcher.isHidden })
    }
    @Test func aBadFrameDoesntStopTheWindowsAfterIt() {
        let profile = Profile.temporary()
        let tabs = [page("first"), page("middle"), page("last")]
        profile.session.save(SessionSnapshot(windows: [window(tabs[0]), window(tabs[1], frame: "nan nan 900 640 0 0 3440 1410 "), window(tabs[2])]))

        let app = makeApp(profile)
        app.restoreSession()
        #expect(app.sessionSnapshot.windows.map { $0.tabs.map(\.id) } == tabs.map { [$0.id] })
    }
    /// A window taking its saved frame is a moment part way through a restore, with only some windows open.
    @Test func aSavePartWayThroughARestoreIsHeld() throws {
        let profile = Profile.temporary()
        let saved = SessionSnapshot(windows: [window(page("a"), frame: "300 300 900 640 0 0 3440 1410 "), window(page("b"))])
        profile.session.save(saved)
        let app = makeApp(profile)
        let reached = Reached()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated {
                reached.value = true
                profile.session.save(app.sessionSnapshot)
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        app.restoreSession()
        #expect(reached.value)
        #expect(app.windows.count == 2)
        #expect(sessionFile(of: profile).load() == saved)
    }
    /// The same window a first launch shows, and what a session that failed to load falls back to.
    @Test func launchWithNothingSavedOpensAnEmptyWindowWithTheSwitcher() {
        let app = makeApp()
        app.restoreSession()
        #expect(app.windows.count == 1)
        #expect(app.windows[0].tabs.isEmpty)
        #expect(!app.windows[0].switcher.isHidden)
    }
    @Test func aSessionThatFailsToLoadIsLeftAloneUntilTheFirstTab() async throws {
        let profile = Profile.temporary()
        let file = sessionFile(of: profile)
        let unreadable = "{\"windows\":"
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        try unreadable.write(to: file.url, atomically: true, encoding: .utf8)

        let app = makeApp(profile)
        app.restoreSession()
        let controller = app.windows[0]
        #expect(controller.tabs.isEmpty)
        #expect(!controller.switcher.isHidden)

        // These all report a change with no tabs in the list.
        for command in [CommandID.nextTab, .previousTab, .selectTab1, .reopenTab] {
            controller.perform(command)
        }
        try await Task.sleep(for: .milliseconds(700))
        #expect(try String(contentsOf: file.url, encoding: .utf8) == unreadable)
        let copy = file.url.appendingPathExtension("unreadable")
        #expect(try String(contentsOf: copy, encoding: .utf8) == unreadable)

        controller.tabs.newTab(nil, activate: true)
        #expect(await eventually { (try? file.read())?.windows.count == 1 })
        #expect(try String(contentsOf: copy, encoding: .utf8) == unreadable)
    }
    @Test func closingAnEmptyWindowLeavesAnUnreadSessionAlone() async throws {
        let profile = Profile.temporary()
        let file = sessionFile(of: profile)
        let unreadable = "{\"windows\":"
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        try unreadable.write(to: file.url, atomically: true, encoding: .utf8)

        let app = makeApp(profile)
        app.restoreSession()
        app.windows[0].perform(.closeWindow)
        #expect(app.windows.isEmpty)
        try await Task.sleep(for: .milliseconds(700))
        #expect(try String(contentsOf: file.url, encoding: .utf8) == unreadable)
    }

    // MARK: Saving

    @Test func aTabChangeReachesTheFile() async {
        let profile = Profile.temporary()
        let app = makeApp(profile)
        app.openWindow(restoring: nil)
        app.windows[0].tabs.newTab(.url(URL(string: "about:blank#new")!), activate: true)
        #expect(await eventually { sessionFile(of: profile).load()?.windows.first?.tabs.first?.url?.fragment() == "new" })
    }
    @Test func closingAWindowReachesTheFile() async throws {
        let profile = Profile.temporary()
        let kept = page("kept")
        profile.session.save(SessionSnapshot(windows: [window(page("closing")), window(kept)]))
        let app = makeApp(profile)
        app.restoreSession()

        app.windows[0].perform(.closeWindow)
        #expect(await eventually { sessionFile(of: profile).load()?.windows.map { $0.tabs.map(\.id) } == [[kept.id]] })
    }
    /// ⌘W leaves the empty window standing, so closing it takes a second press.
    @Test(arguments: [[CommandID.closeTab, .closeTab], [.closeWindow]])
    func closingTheLastWindowOnPurposeEmptiesTheSession(commands: [CommandID]) async {
        let profile = Profile.temporary()
        profile.session.save(SessionSnapshot(windows: [window(page("last"))]))
        let app = makeApp(profile)
        app.restoreSession()

        let controller = app.windows[0]
        commands.forEach(controller.perform)
        #expect(app.windows.isEmpty)
        #expect(await eventually { sessionFile(of: profile).load() == SessionSnapshot(windows: []) })
    }
    /// The window stays for ⇧⌘T, but with no tabs it leaves nothing to bring back after a quit.
    @Test func aWindowEmptiedByClosingItsLastTabIsOutOfTheSessionUntilTheTabReturns() async {
        let profile = Profile.temporary()
        let last = page("last")
        profile.session.save(SessionSnapshot(windows: [window(last)]))
        let app = makeApp(profile)
        app.restoreSession()

        let controller = app.windows[0]
        controller.perform(.closeTab)
        #expect(app.windows.count == 1)
        #expect(app.sessionSnapshot.windows.isEmpty)
        #expect(await eventually { sessionFile(of: profile).load() == SessionSnapshot(windows: []) })

        controller.perform(.reopenTab)
        #expect(await eventually { sessionFile(of: profile).load()?.windows.first?.tabs.map(\.id) == [last.id] })
    }

    // MARK: The test host

    /// A test run has no windows, so a save here would blank the session.
    @Test func quittingInTheTestHostSavesNothing() {
        let profile = Profile.temporary()
        let app = makeApp(profile)
        app.openWindow(restoring: window(page("a")))
        app.applicationWillTerminate(quit)
        #expect(!FileManager.default.fileExists(atPath: sessionFile(of: profile).url.path()))
    }
    @Test func theTestHostsOwnControllerHasNoProfileAndNoWindows() throws {
        let host = try #require(NSApp.delegate as? AppController)
        #expect(host.profile == nil)
        _ = host.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        #expect(host.windows.isEmpty)
    }

    // MARK: Commands

    @Test func commandsActOnTheKeyWindowOnly() {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        app.openWindow(restoring: window(page("b")))
        app.perform(.openSwitcher, keyWindow: app.windows[1].window)
        #expect(app.windows[0].switcher.isHidden)
        #expect(!app.windows[1].switcher.isHidden)
    }
    @Test func newWindowOpensAnEmptyWindowWithTheSwitcher() {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        app.perform(.newWindow, keyWindow: app.windows[0].window)
        #expect(app.windows.count == 2)
        #expect(app.windows[1].tabs.isEmpty)
        #expect(!app.windows[1].switcher.isHidden)
        #expect(app.windows[0].tabs.list.records.count == 1)
    }
    /// The row runs in the window, not through the menu, so it needs the same way up to `AppController`.
    @Test func theSwitchersNewWindowRowOpensAWindow() {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        let controller = app.windows[0]
        controller.perform(.openSwitcher)
        controller.switcher.onChoose?(SwitcherRow(target: .command(.newWindow), title: "New Window", subtitle: "", section: "Commands"))
        #expect(app.windows.count == 2)
        #expect(!app.windows[1].switcher.isHidden)
        #expect(controller.switcher.isHidden)
    }
    /// Landing exactly on the window behind, a new window would look as if nothing had happened.
    @Test func aNewWindowStepsAwayFromTheKeyWindow() throws {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        let key = try #require(app.windows[0].window)
        key.setFrame(NSRect(x: 300, y: 300, width: 900, height: 640), display: false)
        let keyFrame = key.frame

        app.perform(.newWindow, keyWindow: key)
        let opened = try #require(app.windows[1].window)
        #expect((1...60).contains(opened.frame.minX - keyFrame.minX))
        #expect((1...60).contains(keyFrame.maxY - opened.frame.maxY))
        #expect(key.frame == keyFrame)
    }
    @Test func theSwitchersNewWindowRowStepsAwayToo() throws {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        app.windows[0].switcher.onChoose?(SwitcherRow(target: .command(.newWindow), title: "New Window", subtitle: "", section: "Commands"))
        let opened = try #require(app.windows[1].window)
        #expect(opened.frame.origin != app.windows[0].window?.frame.origin)
    }
    /// A restored window keeps its saved frame, whatever is open.
    @Test func aRestoredWindowDoesntStepAway() throws {
        let app = makeApp()
        app.openWindow(restoring: window(page("a"), frame: "300 300 900 640 0 0 3440 1410 "))
        let saved = try #require(app.windows[0].snapshot)
        app.openWindow(restoring: saved)
        #expect(app.windows[1].window?.frame == app.windows[0].window?.frame)
    }
    @Test func aNewWindowWithNothingToStepFromStaysCentered() throws {
        let app = makeApp()
        app.perform(.newWindow, keyWindow: nil)
        let plain = WindowController(appearance: try #require(app.appearance), tabs: TabManager(profile: .temporary(), keepsSpare: false))
        #expect(app.windows[0].window?.frame == plain.window?.frame)
    }
    @Test(arguments: [CommandID.openSwitcher, .openSwitcherFromPage, .newWindow])
    func withNoWindowTheseOpenOne(command: CommandID) {
        let app = makeApp()
        app.perform(command, keyWindow: nil)
        #expect(app.windows.count == 1)
        #expect(!app.windows[0].switcher.isHidden)
    }
    @Test func withNoWindowOtherCommandsDoNothing() {
        let app = makeApp()
        for command in CommandID.allCases where ![.openSwitcher, .openSwitcherFromPage, .newWindow].contains(command) {
            app.perform(command, keyWindow: nil)
        }
        #expect(app.windows.isEmpty)
    }
    /// A sheet, a popover or a detached inspector is key, so nothing reaches the browser window or opens a new one.
    @Test func anotherKindOfKeyWindowKeepsItsKeys() {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        let controller = app.windows[0]
        let sheet = NSWindow()
        for command in CommandID.allCases {
            app.perform(command, keyWindow: sheet)
        }
        #expect(app.windows.count == 1)
        #expect(controller.switcher.isHidden)
        #expect(controller.tabs.list.records.count == 1)

        let noBrowserWindow = makeApp()
        noBrowserWindow.perform(.newWindow, keyWindow: sheet)
        #expect(noBrowserWindow.windows.isEmpty)
    }

    // MARK: Windows coming and going

    @Test func aClosedWindowIsReleasedWithItsPages() async {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        app.openWindow(restoring: window(page("b")))
        weak let closed = app.windows[0]
        weak let closedPage = app.windows[0].tab
        #expect(closed != nil)
        #expect(closedPage != nil)

        // What can hold a closure or start a task: the rail, a popover and a history search, all still up as it closes.
        app.windows[0].perform(.toggleRail)
        app.windows[0].perform(.signIn)
        app.windows[0].perform(.openSwitcher)
        app.windows[0].perform(.closeWindow)
        #expect(await eventually { closed == nil && closedPage == nil })
    }
    /// A closed window leaves its observers behind, and they have to do nothing.
    @Test func sharedChangesAfterAWindowClosesAreSafe() async throws {
        let profile = Profile.temporary()
        let app = makeApp(profile)
        app.openWindow(restoring: window(page("a")))
        app.openWindow(restoring: window(page("b")))
        weak let closed = app.windows[0]
        app.windows[0].perform(.closeWindow)
        #expect(await eventually { closed == nil })

        app.appearance?.toggleSnap()
        profile.bookmarks.toggle(url: URL(string: "https://example.com")!, title: "E")
        #expect(app.windows.count == 1)
    }
    @Test func idleTabsStepDownInEveryWindow() throws {
        let app = makeApp()
        app.openWindow(restoring: window(page("a")))
        app.openWindow(restoring: window(page("b")))
        let idle = app.windows.map { $0.tabs.newTab(nil, activate: false) }
        #expect(idle.count == 2)
        let ids = try app.windows.map { try #require($0.tabs.list.records.last?.id) }

        app.updateTabPhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        #expect(app.windows[0].tabs.phase(of: ids[0]) == .suspended)
        #expect(app.windows[1].tabs.phase(of: ids[1]) == .suspended)
    }
    /// The app stays open with no windows, and comes back through the Dock.
    @Test func theDockReopensAWindowOnlyWhenThereIsNone() {
        let app = makeApp()
        #expect(!app.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(app.windows.count == 1)
        #expect(!app.windows[0].switcher.isHidden)

        // A window that exists comes back through AppKit, so no second one opens.
        #expect(app.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        #expect(app.windows.count == 1)
    }
    /// A misspelled delegate method compiles and is never called.
    @Test func appKitFindsTheDelegateMethods() {
        let app = AppController()
        #expect(app.responds(to: #selector(NSApplicationDelegate.applicationWillTerminate(_:))))
        #expect(app.responds(to: #selector(NSApplicationDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:))))
        #expect(app.responds(to: #selector(NSApplicationDelegate.applicationShouldTerminateAfterLastWindowClosed(_:))))
    }
}
