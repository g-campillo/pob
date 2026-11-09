# pob Stage 3 ("Finish") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish pob v1: profiles, private windows, a Settings window, the per-site ad block switch where you can see it, a Load anyway button for blocked pages, bookmark import, a few Stage 2 fixes and a speed pass.

**Architecture:** `ProfileList` (`profiles.json`) names the profiles. `Profile.persistent(id:)` gives one shared `Profile` per id, and `AppController` opens, restores and saves windows per profile, each profile keeping its own `session.json`. Switching a window's profile parks its tabs in that profile's session and opens the other profile's parked tabs at the same frame. A private window gets a throwaway `Profile` whose data store is non-persistent and which shares its parent's bookmarks. Settings is one SwiftUI window over a small `@Observable` model. Ad block rules move to one shared `ContentBlocker`.

**Tech Stack:** Swift 6, AppKit, SwiftUI (Settings only), WebKit, SQLite3, Swift Testing, XcodeGen 2.46, Xcode 27.2, macOS 27, SafariConverterLib 4.3.1.

**Spec:** `docs/superpowers/specs/2026-11-04-pob-browser-design.md`. Stage 2's results, rulings and deferred minors are in `docs/stage-2-results.md`.

**Scope:** the spec's Stage 3 list, plus four small fixes from Stage 2's review (Task 9). The styling tweaks from Stage 1 are left out until the user lists them. Stage 3 is done when every requirement in the spec's section 2 is met or has an agreed fallback, which includes the Teams or Meet screen share still open from Stage 2 (Task 11).

## Decisions made in this plan

The user reviews these with the plan. Each is cheap to change before its task runs.

1. The starting profile is named **Main**. Its id and folder don't change, so its tabs, history, bookmarks and logins carry over.
2. **Switching profile happens in place**, as the spec says: the window's tabs are parked in the old profile and come back when you switch back. If the window has a tab in a call, pob asks first.
3. **Private windows:** each ⇧⌘N starts its own private session. ⌘N in a private window opens another window in the same session. A private window shows its parent's bookmarks, offers no history suggestions, and its downloads still go to `~/Downloads`. The rail's profile button reads Private and has no menu.
4. **Load anyway** loads the blocked page once in that tab, with rules off for that site until the tab moves to another site. It's not remembered. The switch is how you keep a site unblocked.
5. **The ad block switch** for the current site goes in the rail's settings popover, under the sliders. Settings lists the sites with blocking off so they can be turned back on.
6. **Bookmark import** is a command, in the Bookmarks menu and the switcher. Imported bookmarks aren't pinned, and URLs already saved are skipped.
7. **Search engines:** Google (default), DuckDuckGo and Bing.
8. **Settings** has General (search engine, default browser) and Profiles (add, rename, clear history, sites with blocking off, delete). The transparency and blur sliders stay in the rail popover only.
9. **Deleting a profile** asks first, and only works when none of its windows is open and it isn't the last profile.
10. **Ad block rules** move from the starting profile's folder to `Application Support/pob/rules`, shared by every profile. The first Stage 3 launch compiles them once from the bundled lists, as a fresh install does.
11. **Profile names** live in their own `profiles.json`, not in `settings.json` as the spec's data section sketches, so the appearance code and the profile code never overwrite each other's file.

## Global Constraints

Everything in Stage 2's constraints still applies:

- Deployment target macOS 27. Swift 6 language mode, Default Actor Isolation MainActor, Approachable Concurrency on.
- App Sandbox off. Hardened Runtime on. Sign with `Apple Development: GABRIEL CAMPILLO (ZV8JBS785H)`, team `UR28366SA6`. Never ad-hoc sign.
- AppKit for the browser. SwiftUI only for the Settings window.
- Only `pob/Private/PrivateAPI.swift` may use private APIs.
- Glass: `NSGlassEffectView` with `.regular` style, controls only, never on the page, never glass on glass. Rows and buttons inside glass use fills or plain styles.
- Keyboard actions never wait for an animation.
- WebKit completion handlers are `@MainActor`. Treat any "nearly matches" warning as a failure, and add each new delegate selector to `TabDelegateTests`.
- Fix every Swift warning before committing. Never pass `-skipPackagePluginValidation`.
- Each closure has one owner: `Tab`'s belong to `TabManager`, `TabManager`'s and `Rail`'s to `WindowController`, `WindowController`'s to `AppController`. Anything every window listens to uses `addObserver`.
- Use the `axiom:axiom-macos`, `axiom:axiom-design`, `axiom:axiom-swiftui` (Task 5 and 6), `axiom:axiom-testing` and `axiom:axiom-data` skills.
- History is kept for one year. Downloads go to `~/Downloads`. pob asks before every download.

New for this stage:

- **Branch:** work on `stage-3-finish`, made from `main` at `46c597c`.
- **Build folder:** use `build/s3`, never `build/dd`. The user daily-drives the Stage 2 build from `build/dd`, and replacing it mid-stage would swap their browser for unreviewed code.
- **The user's data:** tests never touch `~/Library/Application Support/pob`, `~/Downloads` or the default browser. `Profile.persistent(id:)` and `ContentBlocker.shared` point at the real folder, so tests reach profiles only through `AppController.makeProfile` and temporary profiles. Agents never `open`, `open -a` or `osascript` pob. Real-binary checks run the executable directly from `build/s3` with `CFFIXED_USER_HOME` set to a scratch folder.
- **Real WebKit:** a green suite once missed a crash on every HTTPS page. Any task that changes navigation, blocking or profiles proves its main path with a real web view in a test, not only with fakes.
- **Visual checks:** this session can't take screenshots, so steps marked **User check** are collected and run with the user in Task 11.
- End every commit message with:

```text
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TUZR76kvftwhB3xQVHu358
```

**Commands used throughout:**

- `TEST`: `xcodebuild test -project pob.xcodeproj -scheme pob -destination 'platform=macOS,arch=arm64' -derivedDataPath build/s3`
- `TEST <Suite>`: the same command plus `-only-testing:pobTests/<Suite>`
- `BUILD`: `xcodebuild build -project pob.xcodeproj -scheme pob -destination 'platform=macOS,arch=arm64' -derivedDataPath build/s3`

New files in `pob/` and `pobTests/` join the targets on their own, because both are synced folders. Run `xcodegen` only if `project.yml` changes, which no task needs.

Verified on this Mac with throwaway probes: a main-frame load stopped by a content rule fails with `WebKitErrorDomain` code 104, "The URL was blocked by a content blocker", with the blocked URL in `NSURLErrorFailingURLErrorKey`. `WKWebsiteDataStore.remove(forIdentifier:)` and `allDataStoreIdentifiers` exist and are async. `NSRunningApplication.current.launchDate` is nil for an executable started directly, so Task 10 reads the process start time from `sysctl` instead.

## Review Focus

Each of these has its test in the owning task.

1. **Upgrading from Stage 2.** A `settings.json` with no search engine keeps its transparency and blur. A `session.json` with no parked tabs restores. No `profiles.json` gives the one existing profile, with its tabs, history and bookmarks. Tasks 1 and 5.
2. **Switching profile during a call.** The call's tab would close with the window's other tabs. pob asks first, and Cancel changes nothing. Task 4.
3. **Private browsing on disk.** After a private window loads pages, nothing new exists under Application Support: no history row, no favicon, no session entry, no site setting. Its temporary folder goes when its last window closes. Task 3.
4. **Deleting a profile.** Never while one of its windows is open, never the last one, and a data store that won't go leaves the profile listed with its folder intact. Task 6.
5. **Real bookmark exports.** Chrome's and Safari's files, with entities in titles, nested folders, `javascript:` and `place:` links, empty titles and repeated URLs. Task 8.

---

### Task 1: Profiles on disk

**Files:**
- Create: `pob/Profile/ProfileList.swift`, `pobTests/ProfileListTests.swift`
- Modify: `pob/Profile/Profile.swift`, `pob/Profile/SessionStore.swift`, `pob/Services/ContentBlocker.swift`, `pobTests/FoundationTests.swift`, `pobTests/SessionStoreTests.swift`

**Interfaces:**
- Produces:

```swift
struct ProfileInfo: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
}

final class ProfileList {
    static var defaultFileURL: URL                // Application Support/pob/profiles.json
    init(file: JSONFile<[ProfileInfo]>)
    private(set) var all: [ProfileInfo]           // never empty
    func addObserver(_ observer: @escaping () -> Void)
    @discardableResult func add(name: String) -> ProfileInfo
    func rename(_ id: UUID, to name: String)
    func remove(_ id: UUID)
    func name(of id: UUID) -> String?
}

extension Profile {
    static let initialID: UUID                    // 6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11
    static func persistent(id: UUID) -> Profile   // one instance per id; initialID gives `initial`
    static func forget(id: UUID)                  // drops the cached instance, for Task 6
    var usesSharedRules: Bool { get }             // true for persistent profiles
    var parked: WindowSnapshot?                   // in memory, filled and saved by AppController (Task 2)
}

extension ContentBlocker {
    static let shared: ContentBlocker             // cache in Application Support/pob/rules
}

nonisolated struct SessionSnapshot: Codable, Equatable {
    var windows: [WindowSnapshot]
    var parked: WindowSnapshot? = nil             // a Stage 2 file has no key, and loads with nil
}

extension WindowSnapshot {
    /// `other`'s tabs after these, with `other`'s active tab and frame.
    func appending(_ other: WindowSnapshot) -> WindowSnapshot
}
```

- [ ] **Step 1: Write the failing tests**

```swift
// ProfileListTests.swift
@Suite struct ProfileListTests {
    func file() -> JSONFile<[ProfileInfo]> {
        JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "pob-\(UUID().uuidString)/profiles.json"))
    }

    @Test func aMissingFileGivesTheStartingProfile() {
        #expect(ProfileList(file: file()).all == [ProfileInfo(id: Profile.initialID, name: "Main")])
    }
    @Test func changesSurviveARelaunch() {
        let file = file()
        let list = ProfileList(file: file)
        let work = list.add(name: "Work")
        list.rename(Profile.initialID, to: "Home")
        #expect(ProfileList(file: file).all == [ProfileInfo(id: Profile.initialID, name: "Home"), work])
        list.remove(Profile.initialID)
        #expect(ProfileList(file: file).all == [work])
    }
    @Test func theLastProfileStays() {
        let list = ProfileList(file: file())
        list.remove(Profile.initialID)
        #expect(list.all.count == 1)
    }
    @Test func blankNamesAreIgnoredAndLongOnesCut() {
        let list = ProfileList(file: file())
        list.rename(Profile.initialID, to: "   ")
        #expect(list.name(of: Profile.initialID) == "Main")
        list.rename(Profile.initialID, to: String(repeating: "x", count: 60))
        #expect(list.name(of: Profile.initialID)?.count == 40)
        #expect(list.add(name: " ").name == "Profile 2") // a blank new name gets a numbered one
    }
    @Test func anUnreadableFileFallsBackAndIsKept() throws {
        let file = file()
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)
        #expect(ProfileList(file: file).all.map(\.id) == [Profile.initialID])
        #expect(FileManager.default.fileExists(atPath: file.url.appendingPathExtension("unreadable").path()))
    }
    @Test func observersHearEveryChange() {
        let list = ProfileList(file: file())
        var heard = 0
        list.addObserver { heard += 1 }
        let work = list.add(name: "Work")
        list.rename(work.id, to: "Job")
        list.remove(work.id)
        #expect(heard == 3)
    }
}

// FoundationTests.swift, added. Only paths and identity: no store of a persistent profile is touched.
@Test func persistentGivesOneProfilePerID() {
    let id = UUID()
    defer { Profile.forget(id: id) }
    #expect(Profile.persistent(id: id) === Profile.persistent(id: id))
    #expect(Profile.persistent(id: Profile.initialID) === Profile.initial)
    #expect(Profile.persistent(id: id).directory.path().hasSuffix("pob/profiles/\(id.uuidString)/"))
    #expect(Profile.persistent(id: id).usesSharedRules)
    #expect(!Profile.temporary().usesSharedRules) // tests keep their rules in their own folder
}
@Test func forgettingAProfileGivesAFreshOneNextTime() {
    let id = UUID()
    let first = Profile.persistent(id: id)
    Profile.forget(id: id)
    #expect(Profile.persistent(id: id) !== first)
    Profile.forget(id: id)
}

// SessionStoreTests.swift, added
@Test func aStage2SessionWithNoParkedTabsLoads() throws {
    let file = JSONFile<SessionSnapshot>(url: temporaryFile())
    try Data(#"{"windows":[{"tabs":[],"activeIndex":0,"frame":"0 0 800 600 0 0 1440 900 "}]}"#.utf8).write(to: file.url)
    let loaded = SessionStore(file: file).load()
    #expect(loaded.windows.count == 1)
    #expect(loaded.parked == nil)
}
@Test func parkedTabsAloneAreWorthSaving() throws {
    let file = JSONFile<SessionSnapshot>(url: temporaryFile())
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
```

Use whatever temporary-file helper `SessionStoreTests` already has in place of `temporaryFile()`, and the real `TabRecord` initializer.

- [ ] **Step 2: Run them to see them fail**

Run: `TEST ProfileListTests`, `TEST FoundationTests`, `TEST SessionStoreTests`
Expected: build failure, `ProfileList` and `parked` don't exist.

- [ ] **Step 3: Implement**

- `ProfileList`: `all` comes from `file.load()`, falling back to `[ProfileInfo(id: Profile.initialID, name: "Main")]` when that's nil or empty. Names are trimmed and cut to 40 characters. A blank new name becomes `"Profile \(all.count + 1)"`. Every change saves, logs a failed save like `BookmarkStore` does, then tells observers.
- `Profile.persistent(id:)` builds `Profile(id:directory:isPersistent: true, ...)` with the same favicon and downloads folders as `initial`, and caches it in a `private static var` keyed by id. `initial` keeps its `static let`, and `persistent(id: initialID)` returns it.
- `contentBlocker`'s lazy initializer returns `.shared` when `usesSharedRules`, else today's per-folder blocker. `ContentBlocker.shared` uses `URL.applicationSupportDirectory.appending(path: "pob/rules")` and `ContentBlocker.download`.
- `SessionStore`: a snapshot with `parked` counts as having tabs, both in `load()` and in `writeJob(for:)`.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass, including `ContentBlockerTests.hostedTestsNeverBuildTheRealProfilesBlocker` and `aTemporaryProfileKeepsItsRulesInItsOwnFolder`.

- [ ] **Step 5: Commit**

```bash
git add pob/Profile pob/Services/ContentBlocker.swift pobTests
git commit -m "feat: list profiles and share the ad block rules"
```

---

### Task 2: Windows in every profile

**Files:**
- Modify: `pob/App/AppController.swift`, `pob/Window/WindowController.swift`
- Create: `pobTests/ProfileWindowsTests.swift`
- Modify tests that call `sessionSnapshot` or `openWindow(restoring:)`: `pobTests/SessionStoreTests.swift`, `pobTests/DefaultBrowserTests.swift`

**Interfaces:**
- Consumes: Task 1's `ProfileList`, `Profile.persistent(id:)`, `Profile.parked`, `SessionSnapshot.parked`.
- Produces:

```swift
// AppController
var profiles: ProfileList?                         // set at launch; tests set their own
var makeProfile: (UUID) -> Profile = Profile.persistent(id:)   // tests return cached temporaries
var profile: Profile?                              // unchanged meaning: where a window opens when nothing says otherwise. The first listed profile.
func openWindow(restoring snapshot: WindowSnapshot?, in profile: Profile? = nil, cascadingFrom parent: NSWindow? = nil)
func sessionSnapshot(of profile: Profile) -> SessionSnapshot   // its windows, plus its parked tabs
func saveAllSessions()                             // synchronous, for quit
func restoreSession()                              // every listed profile's windows; parked tabs into `Profile.parked`
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ProfileWindowsTests {
    /// An app with two temporary profiles, A first, so nothing touches the real folder.
    func app() -> (AppController, a: Profile, b: Profile) {
        let a = Profile.temporary(), b = Profile.temporary()
        let controller = AppController()
        let list = ProfileList(file: JSONFile(url: a.directory.appending(path: "profiles.json")))
        let renamed = list.add(name: "B")
        let profiles = [Profile.initialID: a, renamed.id: b]
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
        #expect(app.windows[1].tabs.list.records.map(\.url?.host()) == ["b.example"])
    }
    @Test func parkedTabsComeBackIntoTheProfileAndSurviveASave() {
        let (app, _, b) = app()
        let parked = window("https://parked.example/")
        b.session.save(SessionSnapshot(windows: [], parked: parked))
        app.restoreSession()
        #expect(b.parked == parked)
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
```

- [ ] **Step 2: Run them to see them fail**

Run: `TEST ProfileWindowsTests`
Expected: build failure.

- [ ] **Step 3: Implement**

- At launch, past the test-host check: `profiles = ProfileList(file: JSONFile(url: ProfileList.defaultFileURL))`, `profile = makeProfile(profiles.all[0].id)`. Remove the old rules folder once: `try? FileManager.default.removeItem(at: Profile.initial.directory.appending(path: "rules"))`, with a comment that the rules moved to `pob/rules` in Stage 3.
- A private `prepare(_ profile: Profile)` runs once per profile instance, the first time a window opens in it: the downloads `onStart` and `frontWindow` hooks that today are set on `Profile.initial`, and the one-year history prune. Keep the prepared profiles in an array; Task 6 removes from it.
- `restoreSession()` walks `profiles.all` in order. For each, `session.restore { }` opens its windows in that profile and sets `profile.parked = snapshot.parked`. Pending links and the "no windows at all" fallback stay as they are, using `profile`.
- `openWindow(restoring:in:cascadingFrom:)` uses `in ?? profile`. `onTabsChanged` and `onClose` save only that window's profile. `onNewWindow` opens in that window's profile.
- `saveSessionSoon(_ profile:)` calls `profile.session.saveSoon { self.sessionSnapshot(of: profile) }`. `applicationWillTerminate` calls `saveAllSessions()`, which saves every prepared profile.
- `prepareFilterLists` and `refreshFilterLists` keep using `profile?.contentBlocker`, which is `.shared` in the app and the test's own blocker in tests.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass. Update the tests that used `sessionSnapshot` to `sessionSnapshot(of:)`.

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: open, restore and save windows in every profile"
```

---

### Task 3: Private windows

**Files:**
- Modify: `pob/Profile/Profile.swift`, `pob/App/Commands.swift`, `pob/App/MainMenu.swift`, `pob/App/AppController.swift`, `pob/Window/WindowController.swift`, `pob/Tab/TabManager.swift`, `pob/Chrome/Rail.swift`
- Create: `pobTests/PrivateWindowTests.swift`
- Modify: `pobTests/CommandsTests.swift`

**Interfaces:**
- Consumes: Task 2's `openWindow(restoring:in:cascadingFrom:)`.
- Produces:

```swift
extension Profile {
    static func makePrivate(from parent: Profile) -> Profile   // a private profile passed in uses its own parent
    let isPrivate: Bool
    let parent: Profile?          // the profile a private one was opened from; nil otherwise
}
enum CommandID { ...; case newPrivateWindow }   // "New Private Window", ⇧⌘N, reserved, File menu after New Window
// WindowController
var onNewPrivateWindow: (() -> Void)?
// Rail
let profileButton: NSButton
func update(profileName: String, isPrivate: Bool)
// WindowController
func showProfile(name: String)                 // passes the name and the profile's isPrivate to the rail
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct PrivateWindowTests {
    @Test func aPrivateProfileSharesBookmarksButNotCookies() {
        let parent = Profile.temporary()
        let hidden = Profile.makePrivate(from: parent)
        #expect(hidden.isPrivate && hidden.parent === parent)
        #expect(hidden.bookmarks === parent.bookmarks)
        #expect(hidden.dataStore !== parent.dataStore)
        #expect(!hidden.dataStore.isPersistent)
        #expect(Profile.makePrivate(from: hidden).parent === parent)
    }
    @Test func browsingPrivatelyLeavesNothingBehind() async throws {
        let server = try await LocalServer.page("<title>Secret</title><link rel=icon href=/i.png>") // use LocalServer's real route API
        let parent = Profile.temporary()
        let tabs = TabManager(profile: .makePrivate(from: parent), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.load(.url(server.url("/"))) }
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
        let profile = app.windows[0].tabs.profile
        try FileManager.default.createDirectory(at: profile.directory, withIntermediateDirectories: true)
        app.windows[0].window?.close()
        #expect(!FileManager.default.fileExists(atPath: profile.directory.path()))
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
}
// CommandsTests, added
@Test func newPrivateWindowIsReservedAndARepeatDoesNothing()  // ⇧⌘N, File menu, a key repeat is taken and dropped like ⌘N
```

Move `app()` into a shared test helper if two suites use it. `testAppearance()` is an `AppearanceModel` over a temporary settings file; reuse an existing helper if there is one.

- [ ] **Step 2: Run them to see them fail**

Run: `TEST PrivateWindowTests`
Expected: build failure.

- [ ] **Step 3: Implement**

- `makePrivate(from:)`: the parent is `parent.parent ?? parent`. A new id, a folder under the temporary directory named `pob-private-<id>`, `isPersistent: false`, `isPrivate: true`, the parent's downloads folder. After init, set `bookmarks = parent.bookmarks` and `favicons = parent.favicons`, and its content blocker is the parent's (`.shared` in the app, the test's own in tests).
- `TabManager` records no visit, updates no history title and fetches no favicon when `profile.isPrivate`.
- `WindowController.searchHistory` answers `[]` for a private profile. `onNewPrivateWindow` runs from `perform(.newPrivateWindow)`.
- `AppController`: `.newPrivateWindow` opens `makePrivate(from: key window's profile)`, cascading from it. With no window showing, it uses `profile`. `saveSessionSoon` and `saveAllSessions` skip private profiles, and `prepare` skips the history prune for them. When the last window of a private profile closes, remove its folder.
- `Rail`: `profileButton` sits at the left of the footer row, a plain borderless button with the profile's name and a `person.crop.circle` symbol, or `Private` with `eye.slash`, disabled. Its accessibility label is `"Profile: <name>"`. `AppController` sets the name through `WindowController` after opening a window, from `profiles.name(of:)`.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: add private windows"
```

**User check:** ⇧⌘N opens a window whose rail says Private. A site signed in to in the main window isn't signed in there. After closing it, the switcher in a normal window suggests nothing visited privately.

---

### Task 4: Switch a window's profile

**Files:**
- Modify: `pob/Chrome/Rail.swift`, `pob/Window/WindowController.swift`, `pob/App/AppController.swift`, `pob/Tab/TabManager.swift`
- Modify: `pobTests/ProfileWindowsTests.swift`

**Interfaces:**
- Consumes: Task 1's `WindowSnapshot.appending`, `Profile.parked`; Task 3's `Rail.profileButton`.
- Produces:

```swift
// TabManager
var isCapturingAny: Bool { get }             // any live tab, through the replaceable `isCapturing`
// WindowController
var profileChoices: () -> [ProfileInfo]       // set by AppController
var onSwitchProfile: ((UUID) -> Void)?
func profileMenu() -> NSMenu                  // what the rail's profile button pops up
// AppController
func switchProfile(of controller: WindowController, to id: UUID) async
var confirmSwitch: (WindowController) async -> Bool   // a sheet in the app; tests answer it
```

- [ ] **Step 1: Write the failing tests**

```swift
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
    #expect(app.windows[0].tabs.list.records.map(\.url?.host()) == ["a.example", "a2.example"])
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

func bID(_ app: AppController) -> UUID { app.profiles!.all[1].id }
```

- [ ] **Step 2: Run them to see them fail**

Run: `TEST ProfileWindowsTests`
Expected: build failure.

- [ ] **Step 3: Implement**

- `switchProfile`: do nothing for the same profile or a private window. If `controller.tabs.isCapturingAny`, await `confirmSwitch(controller)` and stop on false. The real `confirmSwitch` is an `NSAlert` sheet: "Switch profile and end the call in this window?", "Its tabs come back when you switch back.", buttons Switch and Cancel.
- Then, in this order: take `controller.snapshot`, and if it's not nil, set `old.parked = old.parked?.appending(snapshot) ?? snapshot`. Take `new.parked`, set it to nil, and replace its `frame` with the old window's `frameDescriptor` (or build an empty one with that frame). Open the new window with it, close the old window, and save both profiles.
- The rail's profile button pops up `profileMenu()` below itself: one item per profile, the window's own checked, each calling `onSwitchProfile`; a separator; New Private Window, showing ⇧⌘N.
- `AppController` relabels every window of a renamed profile through a `ProfileList` observer.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: switch a window's profile from the rail"
```

**User check:** make a second profile (Task 5 adds the button, so for now through `profiles.json` by hand, or run this check in Task 11). Switch, sign in somewhere, switch back: the first profile's tabs return and the sign-in doesn't carry over.

---

### Task 5: Settings window and search engine

**Files:**
- Create: `pob/Settings/SettingsModel.swift`, `pob/Settings/SettingsView.swift`, `pob/Settings/SettingsWindowController.swift`, `pobTests/SettingsTests.swift`
- Modify: `pob/Window/AppearanceSettings.swift`, `pob/Window/AppearanceModel.swift`, `pob/Tab/AddressInput.swift`, `pob/Chrome/SwitcherModel.swift`, `pob/Chrome/SwitcherView.swift`, `pob/Chrome/AppearancePopover.swift`, `pob/Window/WindowController.swift`, `pob/App/Commands.swift`, `pob/App/MainMenu.swift`, `pob/App/AppController.swift`

**Interfaces:**
- Consumes: Task 1's `ProfileList`; Task 4's `profileMenu()`.
- Produces:

```swift
enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case google, duckDuckGo, bing
    var name: String { get }                       // "Google", "DuckDuckGo", "Bing"
    func url(for query: String) -> URL             // query already percent-encoded by AddressInput
}
struct AppearanceSettings { ...; var searchEngine: SearchEngine? = nil }   // nil means Google
// AppearanceModel
var searchEngine: SearchEngine { get set }        // set saves settings.json
// AddressInput
static func classify(_ text: String, engine: SearchEngine = .google) -> AddressInput?
// SwitcherModel.rows gains `engine: SearchEngine = .google`
enum CommandID { ...; case openSettings }        // "Settings…", ⌘, (not reserved), pob menu, first item
@Observable final class SettingsModel {
    init(profiles: ProfileList, appearance: AppearanceModel)
    var profiles: [ProfileInfo] { get }
    var searchEngine: SearchEngine { get set }
    var selectedProfileID: UUID?
    func addProfile()
    func rename(_ id: UUID, to name: String)
    var makeDefaultBrowser: () -> Void
}
final class SettingsWindowController: NSWindowController   // one per app, kept by AppController
// AppController
private(set) var settingsWindow: SettingsWindowController?
func openSettings()                               // like browser windows, not shown on screen in a test run
// AppearancePopover
init(model: AppearanceModel, onOpenSettings: @escaping () -> Void = {})
```

- [ ] **Step 1: Write the failing tests**

```swift
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
    @Test func theAddressFieldAndSwitcherUseTheChosenEngine()  // a WindowController with .duckDuckGo: submitting "two words" in the rail loads a duckduckgo.com URL, and the switcher's search row targets duckduckgo.com
    @Test func addingAndRenamingShowInTheModel() {
        let list = ProfileList(file: JSONFile(url: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")))
        let model = SettingsModel(profiles: list, appearance: testAppearance())
        model.addProfile()
        #expect(model.profiles.map(\.name) == ["Main", "Profile 2"])
        model.rename(model.profiles[1].id, to: "Work")
        #expect(list.name(of: model.profiles[1].id) == "Work")
    }
    @Test func settingsOpensOnce() {
        let (app, _, _) = ProfileWindowsTests().app()
        app.perform(.openSettings, keyWindow: nil)
        let first = app.settingsWindow
        app.perform(.openSettings, keyWindow: nil)
        #expect(first != nil && app.settingsWindow === first)
    }
    @Test func commandsFromSettingsReachTheFrontBrowserWindow() {
        let (app, a, _) = ProfileWindowsTests().app()
        app.openWindow(restoring: nil, in: a)
        app.perform(.openSettings, keyWindow: nil)
        app.perform(.newWindow, keyWindow: app.settingsWindow?.window)
        #expect(app.windows.count == 2)
    }
    @Test func theCommandIsFirstInThePobMenu() {
        let menu = MainMenu.build(commands: .standard { _ in })
        let item = menu.item(withTitle: "pob")?.submenu?.items.first
        #expect(item?.title == "Settings…" && item?.keyEquivalent == ",")
    }
    @Test func theProfileMenuAndPopoverOpenSettings()  // profileMenu() has "Manage Profiles…" after a separator; the popover's Settings… button calls onOpenSettings
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `TEST SettingsTests`
Expected: build failure.

- [ ] **Step 3: Implement**

- `AppearanceSettings.clamped` carries `searchEngine` over, and `AppearancePopover.slidersChanged` changes only the two slider fields of `model.settings`, so neither drops the engine.
- `AddressInput.search` builds the URL with `engine.url(for: query)`. Callers in `WindowController`, `SwitcherModel` and `SwitcherView` pass `appearance.searchEngine`.
- `SettingsView` is a SwiftUI `Form` with `.formStyle(.grouped)`, about 480 pt wide. General: a `Picker` for the engine, and a "Make pob the Default Browser" button. Profiles: a `List` of profiles bound to `selectedProfileID`, each row a `TextField` for its name that renames on submit, and a "New Profile" button. Task 6 fills in the selected profile's details.
- `SettingsWindowController` hosts it in an `NSHostingController`, in a titled, closable window called Settings that isn't released when closed. `openSettings()` builds it once, then shows it and makes it key.
- `AppController.perform` treats the Settings window like no browser window being key: commands go to the front browser window, and `.openSettings` and `.makeDefaultBrowser` work with no window at all. `WindowController.perform(.openSettings)` calls `onOpenSettings`.
- `AppearancePopover` gets a "Settings…" push button under the sliders. `profileMenu()` gets "Manage Profiles…" after a separator, which opens Settings with that profile selected.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: add the Settings window and the search engine choice"
```

**User check:** ⌘, opens Settings, in light and dark. Choosing DuckDuckGo changes where ⌘T searches go. A new profile appears in the rail's profile menu.

---

### Task 6: Profile data in Settings

**Files:**
- Modify: `pob/Profile/HistoryStore.swift`, `pob/Profile/SiteSettings.swift`, `pob/Profile/Profile.swift`, `pob/Settings/SettingsModel.swift`, `pob/Settings/SettingsView.swift`, `pob/App/AppController.swift`
- Modify: `pobTests/HistoryStoreTests.swift`, `pobTests/SettingsTests.swift`

**Interfaces:**
- Consumes: Task 5's `SettingsModel`; Task 2's `makeProfile`.
- Produces:

```swift
// HistoryStore
func clear()
// SiteSettings
var hostsWithAdBlockerOff: [String] { get }       // sorted
// Profile
func dropSpareTab()
// AppController
var removeDataStore: (UUID) async throws -> Void = { try await WKWebsiteDataStore.remove(forIdentifier: $0) }
func canDeleteProfile(_ id: UUID) -> Bool         // more than one profile and no window open in it
func deleteProfile(_ id: UUID) async throws
// SettingsModel, through closures AppController sets, as with makeDefaultBrowser
func clearHistory(of id: UUID) async
func sitesWithBlockingOff(of id: UUID) -> [String]
func turnBlockingBackOn(_ host: String, in id: UUID)
func canDelete(_ id: UUID) -> Bool
func delete(_ id: UUID) async throws
```

- [ ] **Step 1: Write the failing tests**

```swift
// HistoryStoreTests, added
@Test func clearRemovesEverything() async {
    let store = HistoryStore(file: temporaryFile())
    await store.record(url: URL(string: "https://a.example/")!, title: "Alpha")
    await store.clear()
    #expect(await store.search("Alpha", limit: 10).isEmpty)
    await store.record(url: URL(string: "https://a.example/")!, title: "Alpha")
    #expect(await store.search("Alpha", limit: 10).first?.visitCount == 1)
}

// SettingsTests, added
@Test func sitesWithBlockingOffCanBeTurnedBackOn() {
    let profile = Profile.temporary()
    profile.siteSettings["b.example"].adBlockerOff = true
    profile.siteSettings["a.example"].adBlockerOff = true
    profile.siteSettings["z.example"].zoom = 1.5
    #expect(profile.siteSettings.hostsWithAdBlockerOff == ["a.example", "b.example"])
    // through SettingsModel.turnBlockingBackOn("a.example", in: id): only b.example is left, and z.example keeps its zoom
}
@Test func aProfileWithAWindowOpenOrTheLastOneCantBeDeleted() {
    let (app, a, _) = ProfileWindowsTests().app()
    app.openWindow(restoring: nil, in: a)
    #expect(!app.canDeleteProfile(Profile.initialID))
    #expect(app.canDeleteProfile(app.profiles!.all[1].id))
    app.profiles?.remove(app.profiles!.all[1].id)
    app.windows[0].window?.close()
    #expect(!app.canDeleteProfile(Profile.initialID)) // the only one
}
@Test func deletingRemovesTheFolderTheDataStoreAndTheEntry() async throws {
    let (app, _, b) = ProfileWindowsTests().app()
    let id = app.profiles!.all[1].id
    try FileManager.default.createDirectory(at: b.directory, withIntermediateDirectories: true)
    var removed: [UUID] = []
    app.removeDataStore = { removed.append($0) }
    try await app.deleteProfile(id)
    #expect(removed == [id])
    #expect(!FileManager.default.fileExists(atPath: b.directory.path()))
    #expect(app.profiles?.all.map(\.id) == [Profile.initialID])
}
@Test func aDataStoreThatWontGoKeepsTheProfile() async throws {
    let (app, _, b) = ProfileWindowsTests().app()
    let id = app.profiles!.all[1].id
    try FileManager.default.createDirectory(at: b.directory, withIntermediateDirectories: true)
    app.removeDataStore = { _ in throw CocoaError(.fileWriteNoPermission) }
    await #expect(throws: CocoaError.self) { try await app.deleteProfile(id) }
    #expect(FileManager.default.fileExists(atPath: b.directory.path()))
    #expect(app.profiles?.all.count == 2)
}
@Test func deletingTheFirstProfileMovesNewWindowsToTheNext() async throws {
    let (app, _, b) = ProfileWindowsTests().app()
    app.removeDataStore = { _ in }
    try await app.deleteProfile(Profile.initialID)
    #expect(app.profile === b)
}
@Test func deletingAProfileWithASpareTabDropsItFirst()  // b.prepareSpareTab(); the removeDataStore seam sees b.spareTab == nil when it runs
```

- [ ] **Step 2: Run them to see them fail**

Run: `TEST HistoryStoreTests`, `TEST SettingsTests`
Expected: build failure.

- [ ] **Step 3: Implement**

- `clear()` empties `visits` and `history_fts` in one transaction.
- `deleteProfile`: throw if `!canDeleteProfile`. Drop the spare tab, then `try await removeDataStore(id)`. Only after that succeeds: remove the folder, remove the id from `profiles`, call `Profile.forget(id:)`, drop it from the prepared profiles, and if it was `profile`, set `profile` to the first remaining one. Favicons are shared across profiles, so they stay.
- `SettingsView`, for the selected profile: a "Clear History…" button with a `.confirmationDialog` ("Clear all history for <name>?"), a "Sites with ad blocking off" list with a Turn On button per host and a "None" line when empty, and a destructive "Delete Profile…" button. The button is disabled with the caption "Close this profile's windows first" or "pob needs at least one profile", and confirms with "Delete <name>? Its tabs, history, bookmarks, logins and site data are removed." An error shows as an alert and leaves the profile listed.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: clear history, review blocked sites and delete profiles in Settings"
```

**User check:** clearing history empties the switcher's history rows for that profile only. Deleting a test profile removes it from the rail menu.

---

### Task 7: The ad block switch and Load anyway

**Files:**
- Modify: `pob/Tab/ErrorPage.swift`, `pob/Tab/Tab.swift`, `pob/Chrome/AppearancePopover.swift`, `pob/Window/WindowController.swift`
- Modify: `pobTests/ContentBlockerTests.swift`, `pobTests/AppearancePopoverTests.swift`

**Interfaces:**
- Consumes: the existing `.toggleSiteBlocking` command and `SiteSetting.adBlockerOff`; Task 5's `AppearancePopover.init`.
- Produces:

```swift
// ErrorPage
static let loadAnywayAddress = "pob:load-anyway"
static func blockedHTML(for url: URL) -> String   // title "pob blocked <host>", detail "It's on the ad blocker's lists.", one link "Load anyway"
// Tab
private(set) var isShowingBlockedPage: Bool
private(set) var unblockedHost: String?           // rules stay off for this host until the tab's page leaves it
// AppearancePopover
init(model: AppearanceModel, site: String? = nil, isBlocking: Bool = true, onToggleBlocking: @escaping () -> Void = {}, onOpenSettings: @escaping () -> Void = {})
var blockingCheckbox: NSButton? { get }          // "Block ads on <host>", nil when the page has no host
```

- [ ] **Step 1: Write the failing tests**

```swift
// ContentBlockerTests, added. `window(blockingWith:page:)` is the existing helper.
@Test func loadAnywayOpensABlockedPageOnce() async throws {
    let blocker = try blocker(bundled: listFolder("||blocked.example^"))
    await blocker.prepare()
    let (_, tab, scheme) = try window(blockingWith: blocker, page: "<title>Real</title>")
    await finishLoading(tab) { tab.load(.url(URL(string: "pobtest://blocked.example/")!)) }
    #expect(await eventually { tab.title == "pob blocked blocked.example" })
    #expect(tab.isShowingBlockedPage)
    await finishLoading(tab) { tab.webView.evaluateJavaScript("document.querySelector('a').click()", completionHandler: nil) }
    #expect(await eventually { tab.title == "Real" })
    #expect(scheme.requested == ["/"])
    #expect(tab.profile.siteSettings["blocked.example"] == SiteSetting()) // nothing remembered
}
@Test func loadAnywayEndsWhenTheTabLeavesTheSite() async throws {
    // after Load anyway on blocked.example, loading pobtest://other.example/ with `blockedAndAllowed` requests no blocked image,
    // and loading pobtest://blocked.example/ again shows the blocked page
}
@Test func aPageCantUseTheLinkItself() async throws {
    // an ordinary page with <a href="pob:load-anyway">: clicking it loads nothing, offers no app, and the rules still block its images
}
@Test func otherErrorsKeepTheirRetry() {
    #expect(ErrorPage.html(for: URL(string: "https://x.example/")!, error: URLError(.timedOut)).contains(">Retry<"))
    #expect(!ErrorPage.blockedHTML(for: URL(string: "https://x.example/")!).contains("Retry"))
}

// AppearancePopoverTests, added
@Test func thePopoverShowsTheSiteSwitch() {
    var toggled = 0
    let popover = AppearancePopover(model: testAppearance(), site: "x.example", isBlocking: true, onToggleBlocking: { toggled += 1 })
    popover.loadView()
    #expect(popover.blockingCheckbox?.title == "Block ads on x.example")
    #expect(popover.blockingCheckbox?.state == .on)
    popover.blockingCheckbox?.performClick(nil)
    #expect(toggled == 1)
    #expect(popover.blockingCheckbox?.state == .off)
}
@Test func aPageWithNoHostHasNoSwitch() {
    let popover = AppearancePopover(model: testAppearance())
    popover.loadView()
    #expect(popover.blockingCheckbox == nil)
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `TEST ContentBlockerTests`, `TEST AppearancePopoverTests`
Expected: build failure.

- [ ] **Step 3: Implement**

- `showErrorPage`: an `NSError` in `WebKitErrorDomain` with code 104 shows `blockedHTML` and sets `isShowingBlockedPage`. `didCommit` clears it on any other commit, as it does `isShowingErrorPage`.
- `decidePolicyFor navigationAction`: the first check, before the other-app check, is a request whose `absoluteString` is `ErrorPage.loadAnywayAddress`. Cancel it. Only when `isShowingBlockedPage` and `webView.url` has a host, set `unblockedHost` to that host and load `webView.url`.
- `applyBlocking(for:)`: rules come off when the host is `unblockedHost` or switched off. A main-frame load to any other host clears `unblockedHost` and puts the rules back.
- `WindowController.showAppearancePopover` passes the active tab's host, whether it's blocking, and `{ perform(.toggleSiteBlocking) }`. The checkbox is an `NSButton(checkboxWithTitle:)` under the sliders, and flips its own state after calling back.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: add Load anyway and the site switch in the rail popover"
```

**User check:** a link to a host on EasyList, such as `https://pagead2.googlesyndication.com/`, shows "pob blocked …" with Load anyway. The rail popover shows the switch on a normal site, and unticking it reloads the page with ads.

---

### Task 8: Bookmark import

**Files:**
- Create: `pob/Profile/BookmarkImport.swift`, `pobTests/BookmarkImportTests.swift`
- Modify: `pob/Profile/BookmarkStore.swift`, `pob/App/Commands.swift`, `pob/App/MainMenu.swift`, `pob/Window/WindowController.swift`, `pobTests/BookmarkStoreTests.swift`

**Interfaces:**
- Produces:

```swift
enum BookmarkImport {
    struct Item: Equatable {
        var title: String
        var url: URL
        var folder: String?       // nested folder names joined with " / "
    }
    static func parse(_ html: String) -> [Item]
}
// BookmarkStore
@discardableResult func importBookmarks(_ items: [BookmarkImport.Item]) -> Int   // added count; one save, one notify
enum CommandID { ...; case importBookmarks }     // "Import Bookmarks…", no shortcut, Bookmarks menu after Bookmark This Page
// WindowController
var chooseImportFile: (NSWindow?) async -> URL?  // an NSOpenPanel sheet for .html; tests answer it
```

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct BookmarkImportTests {
    static let chrome = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 ADD_DATE="1" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://example.com/" ADD_DATE="1" ICON="data:image/png;base64,AAAA">Example</A>
            <DT><H3 ADD_DATE="1">Work</H3>
            <DL><p>
                <DT><A HREF="https://rd.example/">R&amp;D &lt;team&gt;</A>
            </DL><p>
        </DL><p>
        <DT><A HREF="https://loose.example/">Loose</A>
    </DL><p>
    """
    static let safari = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <HTML><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8"><Title>Bookmarks</Title><H1>Bookmarks</H1>
    <DT><H3 FOLDED>Favorites</H3>
    <DL><p>
    <DT><A HREF="https://apple.com/">Apple</A>
    </DL><p>
    <DT><H3 id="com.apple.ReadingList">Reading List</H3>
    <DL><p>
    <DT><A HREF="http://later.example/read">Later &#39;s</A>
    </DL><p>
    </HTML>
    """

    @Test func readsAChromeExport() {
        #expect(BookmarkImport.parse(Self.chrome) == [
            .init(title: "Example", url: URL(string: "https://example.com/")!, folder: "Bookmarks bar"),
            .init(title: "R&D <team>", url: URL(string: "https://rd.example/")!, folder: "Bookmarks bar / Work"),
            .init(title: "Loose", url: URL(string: "https://loose.example/")!, folder: nil),
        ])
    }
    @Test func readsASafariExport() {
        #expect(BookmarkImport.parse(Self.safari).map(\.folder) == ["Favorites", "Reading List"])
        #expect(BookmarkImport.parse(Self.safari).last?.title == "Later 's")
    }
    @Test func skipsAddressesThatArentWebPages() {
        let html = ["javascript:alert(1)", "place:sort=8", "data:text/html,x", "file:///etc/hosts", "about:blank", "not a url"]
            .map { "<DT><A HREF=\"\($0)\">x</A>" }.joined(separator: "\n")
        #expect(BookmarkImport.parse(html).isEmpty)
    }
    @Test func anEmptyTitleBecomesTheHost() {
        #expect(BookmarkImport.parse(#"<DT><A HREF="https://x.example/a"><b></b></A>"#).first?.title == "x.example")
    }
    @Test func lowercaseTagsAndExtraAttributesWork() {
        #expect(BookmarkImport.parse(#"<dt><a add_date="1" href="https://y.example/" tags="t">Y</a>"#).first?.url == URL(string: "https://y.example/"))
    }
    @Test func aLargeExportReadsEveryBookmark() {
        let html = (0..<5_000).map { "<DT><A HREF=\"https://e\($0).example/\">E\($0)</A>" }.joined(separator: "\n")
        #expect(BookmarkImport.parse(html).count == 5_000)
    }
}

// BookmarkStoreTests, added
@Test func importSkipsWhatsThereAndSavesOnce() {
    let store = BookmarkStore(file: JSONFile(url: temporaryFile()))
    store.toggle(url: URL(string: "https://a.example/")!, title: "A")
    var heard = 0
    store.addObserver { heard += 1 }
    let b = BookmarkImport.Item(title: "B", url: URL(string: "https://b.example/")!, folder: "F")
    let added = store.importBookmarks([.init(title: "A again", url: URL(string: "https://a.example/")!, folder: nil), b, b])
    #expect(added == 1 && heard == 1)
    #expect(store.all.map(\.title) == ["A", "B"])
    #expect(store.all[1].folder == "F" && !store.all[1].isPinned)
}

// WindowControllerTests or BookmarkImportTests, added
@Test func theCommandImportsIntoThisWindowsProfile()  // chooseImportFile returns a temp file with `chrome`; perform(.importBookmarks); the profile has 3 bookmarks and the pill shows "Imported 3 bookmarks"
@Test func cancellingThePanelChangesNothing()          // chooseImportFile returns nil; no bookmarks, no notice
@Test func aFileWithNoBookmarksSaysSo()                 // a plain HTML page: the pill shows "No bookmarks found"; a file already imported shows "No new bookmarks"
```

- [ ] **Step 2: Run them to see them fail**

Run: `TEST BookmarkImportTests`, `TEST BookmarkStoreTests`
Expected: build failure.

- [ ] **Step 3: Implement**

`parse` walks the text once, matching four tokens case-insensitively, in order of appearance: `<h3 …>name</h3>`, `<dl…>`, `</dl>` and `<a …href="…"…>title</a>`. Keep a stack of folder names:

```text
h3 name   → pending = decoded name
<dl>      → push pending (nil when no h3 came before it); pending = nil
</dl>     → pop (if not empty)
<a>       → url = decoded href; keep it only when its scheme is http or https and it has a host
            title = the inner text with tags removed, entities decoded, whitespace collapsed; empty → url.host()
            folder = the non-nil names on the stack joined with " / ", nil when there are none
```

Decode `&amp; &lt; &gt; &quot; &#39;` and numeric `&#NNN;` / `&#xHH;`, decoding `&amp;` last. The command reads the chosen file only if it's under 50 MB, as UTF-8 with a Latin-1 fallback, and shows an `NSAlert` sheet if it can't be read. Imports go into `tabs.profile.bookmarks`, which in a private window is the parent's store.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: import bookmarks from Safari and Chrome"
```

**User check:** import a real export from Safari (File > Export > Bookmarks) and from Chrome (Bookmark manager > Export). The switcher then finds them by title.

---

### Task 9: Small fixes from Stage 2

These come from `docs/stage-2-results.md`: the final review's "JS dialogs carry no site name" ruling, Task 10's unencrypted password minor, the "every launch counts as a visit" minor, and the "⌘-clicked attachment leaves a blank background tab" minor.

**Files:**
- Modify: `pob/Tab/Tab.swift`, `pob/Tab/TabManager.swift`
- Modify: `pobTests/PageFailureTests.swift`, `pobTests/TabManagerTests.swift`, and whichever suite holds the JavaScript dialog tests

**Interfaces:**
- Produces no new names. `Tab.alertSeam` is how the tests read the dialogs.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func javaScriptDialogsNameTheSite() async {
    // alert, confirm and prompt from a page at https://localhost/: the alert's messageText is "localhost says"
    // and its informativeText is the page's message. A page with no host says "This page says".
}
@Test func signInOverPlainHTTPWarns() async {
    // a Basic challenge on http://127.0.0.1 (LocalServer): the sheet's informativeText contains "sent unencrypted".
    // Over https it doesn't.
}
@Test func bringingATabBackIsntAVisit() async throws {
    // record one visit to a LocalServer page, then a TabManager restoring a snapshot with that page active:
    // after its load finishes, history's visitCount for it is still 1. A Back or a reload in a live tab still counts as before.
}
@Test func aCommandClickedDownloadLeavesNoBlankTab() async throws {
    // a LocalServer link to /file.zip answered with Content-Disposition: attachment, ⌘-clicked through FakeNavigationAction:
    // the background tab closes once it becomes a download, the list is back to one tab, and the active tab didn't change
}
```

- [ ] **Step 2: Run them to see them fail**

Run: the suites above.
Expected: the four tests fail on their assertions.

- [ ] **Step 3: Implement**

- Dialogs: `messageText` is `"\(frame.securityOrigin.host) says"`, or `"This page says"` when the host is empty, and the page's text moves to `informativeText`. The prompt keeps its field.
- `askForPassword`: when `!space.receivesCredentialSecurely`, add "Your password will be sent unencrypted." to the informative text.
- `TabManager.rebuild` remembers the id, and that tab's next `onLoadFinished` skips `recordVisit` but still refreshes its favicon.
- A tab opened by `onOpenLink` is marked like a popup for `onBecameDownload` only. It must not change which tab ⌘W lands on, so keep it in its own set rather than in `openers`.

- [ ] **Step 4: Run the tests and the full suite**

Run: `TEST`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "fix: name the site in dialogs, warn on plain http sign-in, stop counting restores as visits"
```

---

### Task 10: Speed pass

**Files:**
- Create: `pob/App/Speed.swift`, `pobTests/SpeedTests.swift`
- Modify: `pob/App/AppController.swift`, `pob/Window/WindowController.swift`, `pob/Tab/TabManager.swift`, plus whatever a measured fix needs
- Create: `docs/stage-3-results.md` with a Speed section (Task 11 adds the rest)

**Interfaces:**
- Produces:

```swift
enum Speed {
    static let signposter: OSSignposter          // subsystem "pob", category "Speed"
    static func processStart() -> Date?          // sysctl KERN_PROC_PID, kp_proc.p_starttime
}
```

The spec's targets: ⌘T to typing under 50 ms, tab switch under 50 ms, cold launch to first paint of a locally cached page under 500 ms.

- [ ] **Step 1: Add the measurements**

- Signpost intervals: `Switcher` from `perform(.openSwitcher)` until the field is first responder and the window has laid out, ended in the next main-queue turn. `Tab switch` from `TabManager.activate` until `showActiveTab` returns.
- Launch: the first `didFinish` of a restored active tab logs once, through `Logger(subsystem: "pob", category: "Speed")`, `"Launch to first page: \(ms) ms"`, measured from `Speed.processStart()`.

- [ ] **Step 2: Write the speed tests**

`SpeedTests` runs only with `.enabled(if: ProcessInfo.processInfo.environment["POB_SPEED"] == "1")`, because timing on a busy machine would make the normal suite flaky. Each test does 30 runs after 3 warm-ups and prints the median and the slowest:

```swift
@Test func openingTheSwitcherIsQuick()     // WindowController in an offscreen window with 5 tabs; perform(.openSwitcher) until switcher.field is first responder; then closeSwitcher; median under 50 ms
@Test func switchingBetweenLiveTabsIsQuick()  // two loaded tabs, activate back and forth; median under 50 ms
@Test func returningToASavedTabIsQuick()   // a saved tab rebuilt on activate, measured to showActiveTab returning (not to its load); median under 50 ms
```

- [ ] **Step 3: Measure**

Run: `TEST_RUNNER_POB_SPEED=1 TEST SpeedTests`. xcodebuild strips the `TEST_RUNNER_` prefix and hands `POB_SPEED=1` to the test host. Then `BUILD`, make a scratch home with a `session.json` whose one tab is a local HTML file, and start `build/s3/Build/Products/Debug/pob.app/Contents/MacOS/pob` five times with `CFFIXED_USER_HOME` set to it, quitting each time with `kill -TERM`. Read the lines with `log show --last 5m --predicate 'subsystem == "pob" AND category == "Speed"'`.
Expected: three medians and five launch times recorded.

- [ ] **Step 4: Fix what misses**

For any target missed, profile with Axiom's `xcprof` (`record` with the Time Profiler, `analyze`) and fix the cause. Known candidates from Stage 2: every rail update probing `FaviconStore` on disk for hosts with no icon, which a negative cache fixes in one line, and the pinned bookmarks view rebuilding on each update. A fix that would take over about 50 lines, or that changes behavior, goes back to the controller for a ruling instead.

- [ ] **Step 5: Record and commit**

Write each number, before and after any fix, into the Speed section of `docs/stage-3-results.md`, with the machine and that launch was measured warm, not after a reboot.

```bash
git add pob pobTests docs/stage-3-results.md
git commit -m "perf: measure the speed targets"
```

**User check:** ⌘T and tab switching feel instant on the user's own tabs.

---

### Task 11: Run the Stage 3 checks

Run after the final whole-branch review and its fixes, so the user tests reviewed code.

- [ ] **Step 1: Hand over a build**

`BUILD`. Ask the user to quit their Stage 2 pob and start `build/s3/Build/Products/Debug/pob.app` on their real profile. Tell them the upgrade moves the ad block rules, which recompile once in the background, and adds `profiles.json`. Going back to the Stage 2 build still works: it ignores the new keys and recompiles its rules.

- [ ] **Step 2: Walk the checks with the user**

Every **User check** above, plus:

| Check | Pass means |
|---|---|
| Upgrade | Every Stage 2 tab, bookmark, history entry and the transparency settings are there, in a profile called Main |
| Profiles | A second profile keeps separate sign-ins, ⌘N stays in it, and a relaunch brings back both profiles' windows and parked tabs |
| Private | ⇧⌘N, separate sign-ins, nothing in history afterwards |
| Settings | ⌘, opens it, the search engine works, Clear History, Turn On for a blocked site, Delete Profile |
| Blocking | Load anyway, the popover switch |
| Import | Safari and Chrome exports |
| Dialogs | A page's `alert()` names its site |
| Speed | Feels instant; the numbers are in the results |
| Screen sharing | A Teams or Meet call sharing the screen while switching tabs, with camera and mic on and then off. Still open from Stage 2 |
| Work day | A full day in pob. Still open from Stage 2 |

- [ ] **Step 3: Write the results**

Fill in `docs/stage-3-results.md` the way `docs/stage-2-results.md` is laid out: the checks table, automated checks, what was found, decisions, rulings and deferred minors. Stage 3 is done when every row passes or has a fallback the user agrees to. If screen sharing fails, the spec's fallback is Open in Safari from the switcher, and the user decides whether that's acceptable.

- [ ] **Step 4: Commit**

```bash
git add docs/stage-3-results.md
git commit -m "docs: record Stage 3 results"
```

Then finish the branch with `superpowers:finishing-a-development-branch`.
