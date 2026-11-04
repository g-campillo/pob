# pob Stage 2 ("Daily driver") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Stage 1 window into a browser the user can switch to for a full work day: tabs, the full rail, switcher, domain pill, history, bookmarks, session restore, downloads, find, printing, permissions, ad blocking and default browser support.

**Architecture:** `TabManager` owns each window's `TabList` (pure, Codable records) and the live `Tab`s, so a tab can drop its web view and keep its place. `WindowController` shows whichever `Tab` is active under the same chrome. `Profile` becomes a class that owns its stores, so every window shares them: JSON files for small data, SQLite with FTS5 for history. `CommandList` stays the one list of actions, feeding the menu bar, reserved shortcuts and the switcher.

**Tech Stack:** Swift 6, AppKit, WebKit, SQLite3 (system), Swift Testing, XcodeGen 2.46, Xcode 27.2, macOS 27. Task 14 adds AdGuard's SafariConverterLib 4.3.1.

**Spec:** `docs/superpowers/specs/2026-11-04-pob-browser-design.md`

**Scope:** Stage 2 only, using the single starting profile. Profiles, private windows (⇧⌘N), bookmark import, Settings and the Settings control for the per-site ad blocker are Stage 3. The Web Inspector shortcuts in the spec's Stage 2 list already work from Stage 1, so they need no task. Results from Stage 1 are in `docs/stage-1-results.md`.

**Beyond the spec's Stage 2 list, on purpose:** two switcher commands, Reset Permissions for This Site (Task 13) and Toggle Ad Blocking for This Site (Task 14). Without them, a wrong Deny or a site broken by blocking has no fix in pob until Stage 3's Settings, and Stage 2 has to carry a full work day. Keep them even though the spec lists the ad blocker switch under Stage 3.

## Global Constraints

Everything in the Stage 1 plan's constraints still applies:

- Deployment target macOS 27. Swift 6 language mode, Default Actor Isolation MainActor, Approachable Concurrency on.
- App Sandbox off. Hardened Runtime on. Sign with `Apple Development: GABRIEL CAMPILLO (ZV8JBS785H)`, team `UR28366SA6`. Never ad-hoc sign.
- AppKit only in this stage. SwiftUI is for the Stage 3 Settings window.
- Only `pob/Private/PrivateAPI.swift` may use private APIs.
- Glass: `NSGlassEffectView` with `.regular` style, controls only, never on the page, never glass on glass. Rows inside glass use fills.
- Keyboard actions never wait for an animation.
- Use the `axiom:axiom-macos`, `axiom:axiom-design`, `axiom:axiom-testing` and `axiom:axiom-data` skills.
- Work on branch `stage-2-daily-driver`, not `main`.

New for this stage:

- **Delegate methods:** WebKit's completion handlers are `@MainActor`, and a wrong Swift signature compiles with only a "nearly matches" warning and is never called. Treat any such warning as a failure, and add each new delegate selector to `TabDelegateTests`.
- **Build output:** fix every Swift warning before committing.
- **Build plugins:** never pass `-skipPackagePluginValidation`.
- **Callbacks:** each closure has one owner. `Tab`'s closures belong to `TabManager`, and `TabManager`'s belong to `WindowController`. Anything every window listens to uses `addObserver`, as `AppearanceModel` does.
- **Visual checks:** this session can't take screenshots, so steps marked **User check** are collected and run with the user in Task 16.
- History is kept for one year. Google is the default search engine. Downloads go to `~/Downloads`.
- End every commit message with:

```text
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TUZR7A8dDo6iyiQViHVEda
```

**Commands used throughout:**

- `TEST`: `xcodebuild test -project pob.xcodeproj -scheme pob -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd`
- `TEST <Suite>`: the same command plus `-only-testing:pobTests/<Suite>`
- `RUN`: `xcodebuild build -project pob.xcodeproj -scheme pob -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd && open build/dd/Build/Products/Debug/pob.app`

Verified on this Mac with throwaway probes: all navigation and download delegate signatures named below, `interactionState` round trips as `Data` with history intact, `loadSimulatedRequest` keeps the failed URL, `find` reports matches, FTS5 prefix search works through `import SQLite3` and gives the counts in Task 5's test, and compiling a 46,000-rule list takes under a second. A compiled rule blocks a `pobtest://` image, `webView.url` reports punycode, `_displayCaptureState` exists, the geolocation delegate is public, and `WKDownload` quarantines finished files by itself, so Gatekeeper still checks them. SafariConverterLib itself isn't verified, because its build plugin needs the user's trust first.

## Review Focus

Each of these has its test in the owning task.

1. **Sharing a screen with camera and mic off.** WebKit's public capture states don't include screen sharing, so the tab could step down mid-call unless `isCapturing` checks it too. Task 3.
2. **Hand-edited or corrupt `session.json`.** pob must launch with an empty window, not crash or lose the app. Task 9.
3. **Download names.** A server can suggest `../../.zshrc` or a name that already exists. Nothing may land outside `~/Downloads` or overwrite a file. Task 11.
4. **History searches with symbols.** Typing `c++`, `"quoted`, `foo:bar` or `-x` must not throw an FTS5 syntax error or lose results. Task 5.
5. **Pages behind HTTP sign-in.** Staging servers and routers use Basic auth. Without a prompt they fail silently. Task 10.

---

### Task 1: Foundations

**Files:**
- Create: `pob/Profile/JSONFile.swift`, `pob/Profile/SiteSettings.swift`, `pobTests/TestSupport.swift`
- Modify: `pob/Profile/Profile.swift`, `pob/Window/AppearanceSettings.swift`, `pob/Window/AppearanceModel.swift`, `pob/Window/WindowController.swift`, every test using `Profile.initial`
- Test: `pobTests/FoundationTests.swift`

**Interfaces:**
- Produces:

```swift
final class Profile {
    let id: UUID
    let directory: URL        // Application Support/pob/profiles/<id>/
    let isPersistent: Bool
    let dataStore: WKWebsiteDataStore
    var siteSettings: SiteSettings { get }   // lazy, sites.json
    static let initial: Profile
    static func temporary() -> Profile       // temp directory, WKWebsiteDataStore.nonPersistent()
}
struct JSONFile<Value: Codable> {
    let url: URL
    func load() -> Value?                // nil when missing or unreadable
    func save(_ value: Value) throws     // creates folders, atomic write
}
struct SiteSetting: Codable, Equatable {
    var zoom: Double?
    var camera: Bool?
    var microphone: Bool?
    var location: Bool?
    var allowsInvalidCertificate: Bool?
}
final class SiteSettings {
    init(file: JSONFile<[String: SiteSetting]>)
    subscript(host: String) -> SiteSetting { get set }   // setter saves; a failed save logs and keeps the value
}
// AppearanceModel: onChange is replaced by
//   func addObserver(_ observer: @escaping () -> Void)
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import pob

@Suite struct FoundationTests {
    func tempFile() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json") }

    @Test func temporaryProfilesDontTouchRealData() {
        let profile = Profile.temporary()
        #expect(!profile.isPersistent)
        #expect(!profile.dataStore.isPersistent)
        #expect(profile.directory != Profile.initial.directory)
    }
    @Test func initialProfileKeepsItsStage1Identifier() {
        #expect(Profile.initial.id.uuidString == "6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11")
        #expect(Profile.initial.directory.path().hasSuffix("pob/profiles/6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11/"))
    }
    @Test func jsonFileRoundTripsAndCreatesFolders() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "a.json")
        let file = JSONFile<[String]>(url: url)
        #expect(file.load() == nil)
        try file.save(["x"])
        #expect(file.load() == ["x"])
    }
    @Test func jsonFileTreatsGarbageAsMissing() throws {
        let url = tempFile()
        try "not json".write(to: url, atomically: true, encoding: .utf8)
        #expect(JSONFile<[String]>(url: url).load() == nil)
    }
    @Test func siteSettingsPersistPerHost() {
        let file = JSONFile<[String: SiteSetting]>(url: tempFile())
        let settings = SiteSettings(file: file)
        settings["example.com"].zoom = 1.25
        #expect(SiteSettings(file: file)["example.com"].zoom == 1.25)
        #expect(SiteSettings(file: file)["other.com"] == SiteSetting())
    }
    @Test func everyObserverHearsAboutChanges() {
        let model = AppearanceModel(store: SettingsStore(fileURL: tempFile()), reduceTransparency: false)
        var calls = 0
        model.addObserver { calls += 1 }
        model.addObserver { calls += 1 }
        model.toggleSnap()
        #expect(calls == 2)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST FoundationTests`
Expected: build FAILS with `type 'Profile' has no member 'temporary'`

- [ ] **Step 3: Implement the types above**

- `Profile` is a class so every window shares one set of stores. Each later task adds its store here as a `lazy var`.
- `SettingsStore` keeps its API and uses `JSONFile<AppearanceSettings>` inside.
- Replace `Profile.initial` with `Profile.temporary()` in every test, so tests stop touching the user's data store. Update `AppearanceTests` to use `addObserver`.
- `addObserver` closures are never removed: `// shortcut: a closed window leaves a no-op closure behind, add removal if that ever matters`.
- `TestSupport.swift` provides `func finishLoading(_ tab: Tab, _ start: () -> Void) async`, `func tabWith(html: String) async -> Tab` and `func eventually(_ condition: () async -> Bool) async -> Bool`, which polls for up to a second. The existing per-suite copies go away. `finishLoading` calls any earlier `onLoadFinished` and puts it back, so it doesn't unhook `TabManager`.
- In `WindowController.openInSafari`, find Safari with `NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Safari")`.

- [ ] **Step 4: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`, with no Swift warnings

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: add profile storage, JSON files and site settings"
```

---

### Task 2: Tab list and lifecycle rules

**Files:**
- Create: `pob/Tab/TabList.swift`, `pob/Tab/TabLifecycle.swift`
- Test: `pobTests/TabListTests.swift`

**Interfaces:**
- Produces:

```swift
struct TabRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var url: URL?
    var title: String
    var interactionState: Data?
    init(id: UUID = UUID(), url: URL? = nil, title: String = "", interactionState: Data? = nil)
}
struct TabList: Equatable {
    private(set) var records: [TabRecord]
    private(set) var activeID: UUID?
    private(set) var recentlyClosed: [TabRecord]     // newest last, at most 20
    var active: TabRecord? { get }
    init(records: [TabRecord] = [], activeID: UUID? = nil)
    mutating func add(_ record: TabRecord, activate: Bool)   // inserted after the active tab
    mutating func close(_ id: UUID)
    mutating func activate(_ id: UUID)
    mutating func activate(index: Int)     // 0 to 7 by position, 8 means last, out of range does nothing
    mutating func activateNext()           // wraps
    mutating func activatePrevious()       // wraps
    mutating func move(from: Int, to: Int)
    mutating func reopenLast() -> TabRecord?
    mutating func update(_ id: UUID, _ change: (inout TabRecord) -> Void)
}
enum TabPhase: Equatable { case active, background, suspended, saved }
enum TabLifecycle {
    static let idleLimit: TimeInterval   // 600
    static func nextPhase(current: TabPhase, isActive: Bool, isCapturing: Bool, idleSeconds: TimeInterval, memoryPressure: Bool) -> TabPhase
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import pob

@Suite struct TabListTests {
    func list(_ count: Int) -> (TabList, [UUID]) {
        var list = TabList()
        let records = (0..<count).map { _ in TabRecord() }
        records.forEach { list.add($0, activate: true) }
        list.activate(records[0].id)
        return (list, list.records.map(\.id))
    }

    @Test func newTabsLandRightAfterTheActiveTab() {
        var (list, ids) = list(3)
        let added = TabRecord()
        list.add(added, activate: false)
        #expect(list.records.map(\.id) == [ids[0], added.id, ids[1], ids[2]])
        #expect(list.activeID == ids[0])
    }
    @Test func closingTheActiveTabSelectsTheOneToItsRight() {
        var (list, ids) = list(3)
        list.close(ids[0])
        #expect(list.activeID == ids[1])
    }
    @Test func closingTheLastPositionSelectsTheOneToItsLeft() {
        var (list, ids) = list(3)
        list.activate(ids[2])
        list.close(ids[2])
        #expect(list.activeID == ids[1])
    }
    @Test func closingTheOnlyTabLeavesNothingActive() {
        var (list, ids) = list(1)
        list.close(ids[0])
        #expect(list.records.isEmpty)
        #expect(list.activeID == nil)
    }
    @Test func reopeningRestoresTheNewestClosedTab() {
        var (list, ids) = list(3)
        list.close(ids[1])
        list.close(ids[2])
        let reopened = list.reopenLast()
        #expect(reopened?.id == ids[2])
        #expect(list.activeID == ids[2])
        #expect(list.recentlyClosed.map(\.id) == [ids[1]])
    }
    @Test func recentlyClosedKeepsTwenty() {
        var list = TabList()
        for _ in 0..<25 {
            let record = TabRecord()
            list.add(record, activate: true)
            list.close(record.id)
        }
        #expect(list.recentlyClosed.count == 20)
    }
    @Test func numberShortcutsPickByPositionAndNineMeansLast() {
        var (list, ids) = list(3)
        list.activate(index: 1)
        #expect(list.activeID == ids[1])
        list.activate(index: 8)
        #expect(list.activeID == ids[2])
        list.activate(index: 5)
        #expect(list.activeID == ids[2])
    }
    @Test func nextAndPreviousWrap() {
        var (list, ids) = list(2)
        list.activatePrevious()
        #expect(list.activeID == ids[1])
        list.activateNext()
        #expect(list.activeID == ids[0])
    }
    @Test func movingKeepsTheActiveTab() {
        var (list, ids) = list(3)
        list.move(from: 0, to: 2)
        #expect(list.records.map(\.id) == [ids[1], ids[2], ids[0]])
        #expect(list.activeID == ids[0])
    }
    @Test func lifecycleStepsDownAsTabsGoIdle() {
        func next(_ current: TabPhase, active: Bool = false, capturing: Bool = false, idle: TimeInterval = 0, pressure: Bool = false) -> TabPhase {
            TabLifecycle.nextPhase(current: current, isActive: active, isCapturing: capturing, idleSeconds: idle, memoryPressure: pressure)
        }
        #expect(next(.background, active: true) == .active)
        #expect(next(.active) == .background)
        #expect(next(.background, idle: 599) == .background)
        #expect(next(.background, idle: 600) == .suspended)
        #expect(next(.suspended, pressure: true) == .saved)
        #expect(next(.background, pressure: true) == .background)
        #expect(next(.suspended, capturing: true, idle: 9000, pressure: true) == .background)
        #expect(next(.saved) == .saved)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST TabListTests`
Expected: build FAILS with `cannot find 'TabList' in scope`

- [ ] **Step 3: Implement the types above**

Memory pressure saves only suspended tabs, as the spec's lifecycle table says. A capturing tab always stays at `.background`, because it must keep running.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST TabListTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob/Tab pobTests/TabListTests.swift
git commit -m "feat: add tab list and lifecycle rules"
```

---

### Task 3: Tab manager and switching tabs

**Files:**
- Create: `pob/Tab/TabManager.swift`
- Modify: `pob/Tab/Tab.swift`, `pob/Profile/Profile.swift`, `pob/Private/PrivateAPI.swift`, `pob/Window/WindowController.swift`, `pob/App/Commands.swift`, `pob/App/MainMenu.swift`, `pob/App/AppController.swift`
- Delete: `pob/Tab/PopupWindow.swift`
- Test: `pobTests/TabManagerTests.swift`

**Interfaces:**
- Consumes: `TabList`, `TabLifecycle`, `Profile`, `AddressInput`
- Produces:

```swift
// Tab gains:
//   let profile: Profile
//   init(profile: Profile, configuration: WKWebViewConfiguration? = nil)
//   var onOpenLink: ((URLRequest, _ activate: Bool) -> Void)?
//   var onCreatePopup: ((WKWebViewConfiguration) -> WKWebView?)?
//   var onCloseRequested: (() -> Void)?
//   var isCapturing: Bool { get }     // camera, mic or screen capture in use; muted counts
// Tab.popupPolicy and PopupPolicy go away.
// Profile gains:
//   private(set) var spareTab: Tab?
//   func prepareSpareTab()            // builds one when none is waiting
//   func takeSpareTab() -> Tab        // the spare, otherwise a new Tab
// PrivateAPI gains: static func isCapturingDisplay(_ webView: WKWebView) -> Bool
final class TabManager {
    init(profile: Profile, keepsSpare: Bool = true)
    let profile: Profile
    private(set) var list: TabList
    var onChange: (() -> Void)?
    var onActiveChange: (() -> Void)?
    var onLoadFinished: ((Tab) -> Void)?
    var isEmpty: Bool { get }
    var activeTab: Tab? { get }
    func phase(of id: UUID) -> TabPhase
    func liveTab(_ id: UUID) -> Tab?
    @discardableResult func newTab(_ input: AddressInput?, activate: Bool) -> Tab
    func close(_ id: UUID)
    func reopenLast()
    func activate(_ id: UUID)
    func activate(index: Int)
    func activateNext()
    func activatePrevious()
    func move(from: Int, to: Int)
    func updatePhases(now: Date, memoryPressure: Bool)
}
// CommandID gains: openSwitcher (⌘T, reserved), openSwitcherFromPage (⌘K), newWindow (⌘N, reserved),
//   reopenTab (⇧⌘T, reserved), closeTab (⌘W, reserved), nextTab (⌃Tab, reserved), previousTab (⌃⇧Tab, reserved),
//   selectTab1 to selectTab9 (⌘1 to ⌘9, reserved).
// closeWindow moves to ⇧⌘W. Task 7 builds the switcher; until then openSwitcher opens a blank tab and focuses the address field.
// WindowController: init(appearance:tabs:), var tab: Tab? { tabs.activeTab }, let tabs: TabManager
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct TabManagerTests {
    func manager() -> TabManager { TabManager(profile: .temporary(), keepsSpare: false) }

    @Test func tabsShareTheirProfilesDataStore() {
        let tabs = manager()
        let first = tabs.newTab(nil, activate: true)
        let second = tabs.newTab(nil, activate: false)
        #expect(first.webView.configuration.websiteDataStore === second.webView.configuration.websiteDataStore)
    }
    @Test func closingTheActiveTabActivatesItsNeighbor() {
        let tabs = manager()
        let first = tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: true)
        tabs.close(tabs.list.activeID!)
        #expect(tabs.activeTab === first)
    }
    @Test func idleTabsStepDownAndSavedTabsLoseTheirWebView() {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: false)
        let idle = tabs.list.records[1].id
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        #expect(tabs.phase(of: idle) == .suspended)
        tabs.updatePhases(now: Date().addingTimeInterval(800), memoryPressure: true)
        #expect(tabs.phase(of: idle) == .saved)
        #expect(tabs.liveTab(idle) == nil)
    }
    @Test func activatingASavedTabRebuildsIt() {
        let tabs = manager()
        tabs.newTab(nil, activate: true)
        tabs.newTab(.url(URL(string: "about:blank")!), activate: false)
        let saved = tabs.list.records[1].id
        tabs.updatePhases(now: Date().addingTimeInterval(700), memoryPressure: false)
        tabs.updatePhases(now: Date().addingTimeInterval(800), memoryPressure: true)
        tabs.activate(saved)
        #expect(tabs.liveTab(saved) != nil)
        #expect(tabs.phase(of: saved) == .active)
    }
    @Test func aPageCantOpenWindowsOnItsOwn() async throws {
        let tabs = manager()
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) {
            tab.webView.loadHTMLString("<script>for (let i = 0; i < 5; i++) window.open('about:blank')</script>", baseURL: URL(string: "https://localhost/"))
        }
        #expect(tabs.list.records.count == 1)
    }
    @Test func theSpareTabIsUsedForTheNextTab() {
        let profile = Profile.temporary()
        profile.prepareSpareTab()
        let spare = profile.spareTab
        #expect(spare != nil)
        #expect(TabManager(profile: profile, keepsSpare: false).newTab(nil, activate: true) === spare)
        #expect(profile.spareTab == nil)
    }
    @Test func commandsMatchSpec() {
        let list = CommandList.standard { _ in }
        #expect(list.reservedCommand(key: "t", modifiers: .command)?.id == .openSwitcher)
        #expect(list.reservedCommand(key: "w", modifiers: .command)?.id == .closeTab)
        #expect(list.reservedCommand(key: "t", modifiers: [.shift, .command])?.id == .reopenTab)
        #expect(list.reservedCommand(key: "n", modifiers: .command)?.id == .newWindow)
        #expect(list.reservedCommand(key: "1", modifiers: .command)?.id == .selectTab1)
        #expect(list.reservedCommand(key: "9", modifiers: .command)?.id == .selectTab9)
        #expect(list.reservedCommand(key: "\t", modifiers: .control)?.id == .nextTab)
        #expect(list.reservedCommand(key: "\t", modifiers: [.control, .shift])?.id == .previousTab)
        #expect(list.command(.openSwitcherFromPage)?.isReserved == false)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST TabManagerTests`
Expected: build FAILS with `cannot find 'TabManager' in scope`

- [ ] **Step 3: Implement `TabManager` and the `Tab` changes**

- `Tab` sets `preferences.javaScriptCanOpenWindowsAutomatically = false` so scripts need a user gesture. A supplied configuration is used unchanged.
- `createWebViewWith`: with `.command` in `modifierFlags`, call `onOpenLink(request, false)` and return nil. Otherwise return `onCreatePopup?(configuration)`. `TabManager` wraps that configuration in a new `Tab(profile:configuration:)`, so `window.opener` survives, and adds it as an active tab. `webViewDidClose` calls `onCloseRequested`, which closes that tab.
- `decidePolicyFor navigationAction`: a link with `.command` in `modifierFlags` cancels and calls `onOpenLink(request, false)`. Otherwise allow, and use `.download` when `shouldPerformDownload` is true.
- `TabManager` sets every closure on a `Tab` when it adds one, and forwards finished loads through `onLoadFinished`. It keeps `[UUID: Tab]`, `[UUID: TabPhase]` and last-active dates. Background tabs set `webView.configuration.preferences.inactiveSchedulingPolicy` to `.throttle`, and `.suspended` sets `.suspend`.
- `isCapturing` checks `cameraCaptureState`, `microphoneCaptureState` and `PrivateAPI.isCapturingDisplay`, which reads `_displayCaptureState` after a `responds(to:)` check. Add that selector to `missingSelectors`.
- Saved tabs store `webView.interactionState as? Data` in their record and drop the `Tab`. Rebuilding sets `interactionState` when it exists, otherwise loads the record's URL.
- Spare: one per profile, as the spec says. `newTab` calls `profile.takeSpareTab()`. When `keepsSpare` is true it then calls `profile.prepareSpareTab()` from a `Task`, which keeps that off the critical path.
- `AppController` owns one 60 s timer and one `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)`. They call `updatePhases(now: .now, memoryPressure:)` with false and true.

- [ ] **Step 4: Wire it into `WindowController`, commands and the menu**

- `WindowController` swaps the active web view into the stack below the top strip whenever `tabs.onActiveChange` fires. A tab where `isCapturing` is true stays in the view hierarchy behind the active one with `alphaValue = 0`, not `isHidden`, so it keeps running and doesn't show through a translucent page. All others are removed.
- Copy the current `alphaValue` and `obscuredContentInsets` to the incoming web view.
- `perform` covers the new commands. Closing the last tab closes the window. `newWindow` does nothing until Task 9.
- The reserved-key monitor maps key code 48 to `"\t"`, because Shift changes Tab's character. It only acts while a browser window is key, so sheets and a detached inspector keep their own keys.
- Add a File menu: New Tab, New Window, Reopen Closed Tab, Close Tab, Close Window.
- Update every test that builds a `WindowController` for `init(appearance:tabs:)`, and `CommandsTests` for the new reserved set. Remove `windowToClose` and its test, because popups are tabs now, and the `popupPolicy` test in `TabTests`.

- [ ] **Step 5: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add -A pob pobTests
git commit -m "feat: add tabs, popups as tabs and idle tab lifecycle"
```

---

### Task 4: Tabs in the rail

**Files:**
- Create: `pob/Chrome/TabListView.swift`
- Modify: `pob/Chrome/Rail.swift`, `pob/Window/WindowController.swift`, `pob/Tab/Tab.swift`
- Test: `pobTests/TabListViewTests.swift`

**Interfaces:**
- Consumes: `TabRecord`, `TabManager`
- Produces:

```swift
final class TabListView: NSView {
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onMove: ((Int, Int) -> Void)?
    var onNewTab: (() -> Void)?
    func update(records: [TabRecord], activeID: UUID?)
    var rowCount: Int { get }
    func selectRow(_ index: Int)     // same path as a click
    static func displayTitle(for record: TabRecord) -> String
}
// Rail gains: let tabList: TabListView
// Tab gains: var title: String { get } (observed), and onStateChange fires for title changes.
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Testing
@testable import pob

@Suite struct TabListViewTests {
    @Test func showsOneRowPerTab() {
        let view = TabListView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        view.update(records: [TabRecord(title: "One"), TabRecord(title: "Two")], activeID: nil)
        #expect(view.rowCount == 2)
    }
    @Test func clickingARowReportsItsTab() {
        let view = TabListView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
        let records = [TabRecord(title: "One"), TabRecord(title: "Two")]
        view.update(records: records, activeID: records[0].id)
        var selected: UUID?
        view.onSelect = { selected = $0 }
        view.selectRow(1)
        #expect(selected == records[1].id)
    }
    @Test func untitledTabsFallBackToTheirHost() {
        #expect(TabListView.displayTitle(for: TabRecord(url: URL(string: "https://example.com/a"))) == "example.com")
        #expect(TabListView.displayTitle(for: TabRecord()) == "New Tab")
    }
    @Test func theRailListsTheWindowsTabs() {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        tabs.newTab(nil, activate: true)
        tabs.newTab(nil, activate: true)
        let model = AppearanceModel(store: SettingsStore(fileURL: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)), reduceTransparency: false)
        let controller = WindowController(appearance: model, tabs: tabs)
        #expect(controller.rail.tabList.rowCount == 2)
    }
    @Test func recordsFollowTheirTabs() async {
        let tabs = TabManager(profile: .temporary(), keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.webView.loadHTMLString("<title>Hello</title>", baseURL: URL(string: "https://localhost/")) }
        #expect(tabs.list.active?.title == "Hello")
        #expect(tabs.list.active?.url?.host() == "localhost")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST TabListViewTests`
Expected: build FAILS with `cannot find 'TabListView' in scope`

- [ ] **Step 3: Implement `TabListView`**

- An `NSTableView` in a clear `NSScrollView`, so long lists scroll. `style = .plain`, no header, no background, `selectionHighlightStyle = .none`.
- Rows draw a translucent fill for the active tab (`NSColor.quaternaryLabelColor`). The fill view overrides the read-only `cornerConfiguration` to return `.uniformCorners(radius: .containerConcentric(6))`.
- Each row: a favicon slot (colored letter tile for now), the title, and a close button shown on hover.
- Drag to reorder with `tableView(_:pasteboardWriterForRow:)` and `acceptDrop`.
- A New Tab row sits below the table. `Rail` places this view between the address field and the footer. The profile switcher waits for Stage 3.

- [ ] **Step 4: Wire it up and run the whole suite**

`TabManager` copies each tab's `url` and `title` into its record from `onStateChange`, then calls `onChange`. `WindowController` refreshes the list from `tabs.onChange`, and routes `onSelect`, `onClose`, `onMove` and `onNewTab` to `TabManager`.

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob pobTests/TabListViewTests.swift
git commit -m "feat: show tabs in the rail"
```

**User check for Task 16:** rail tab rows look right on glass, hover shows close, dragging reorders.

---

### Task 5: History

**Files:**
- Create: `pob/Profile/HistoryStore.swift`
- Modify: `pob/Profile/Profile.swift`, `pob/Tab/TabManager.swift`, `pob/App/AppController.swift`
- Test: `pobTests/HistoryStoreTests.swift`

**Interfaces:**
- Produces:

```swift
struct HistoryEntry: Equatable, Sendable { let url: URL; let title: String; let visitCount: Int; let lastVisit: Date }
actor HistoryStore {
    init(file: URL)                  // opens or creates; a failure leaves it inert
    func record(url: URL, title: String, at date: Date = .now)
    func search(_ query: String, limit: Int) -> [HistoryEntry]   // frecency order
    func prune(before date: Date)
}
// Profile gains: var history: HistoryStore { get }   // lazy, history.sqlite
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import pob

@Suite struct HistoryStoreTests {
    func store() -> HistoryStore {
        HistoryStore(file: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite"))
    }
    let deploy = URL(string: "https://ops.example.com/deploy")!

    @Test func findsPagesByTitlePrefix() async {
        let history = store()
        await history.record(url: deploy, title: "Deploy logs")
        #expect(await history.search("dep", limit: 5).map(\.url) == [deploy])
    }
    @Test func findsPagesByAddress() async {
        let history = store()
        await history.record(url: deploy, title: "Logs")
        #expect(await history.search("ops.exam", limit: 5).map(\.url) == [deploy])
    }
    @Test func repeatVisitsCountAndUpdateTheTitle() async {
        let history = store()
        await history.record(url: deploy, title: "Old")
        await history.record(url: deploy, title: "New")
        let entry = await history.search("new", limit: 5).first
        #expect(entry?.visitCount == 2)
        #expect(await history.search("old", limit: 5).isEmpty)
    }
    @Test func busierPagesRankFirst() async {
        let history = store()
        let quiet = URL(string: "https://example.com/deploy-quiet")!
        await history.record(url: quiet, title: "Deploy quiet")
        for _ in 0..<3 { await history.record(url: deploy, title: "Deploy busy") }
        #expect(await history.search("deploy", limit: 5).map(\.url) == [deploy, quiet])
    }
    @Test(arguments: [("c++", 1), ("\"quoted", 1), ("foo:bar", 1), ("-x", 1), ("a AND", 1), ("(", 0), ("*", 0), ("'", 0)])
    func symbolsInSearchesAreSafe(query: String, matches: Int) async {
        let history = store()
        await history.record(url: URL(string: "https://example.com/c++")!, title: "c++ \"quoted foo:bar -x a AND notes")
        #expect(await history.search(query, limit: 5).count == matches)
    }
    @Test func oldVisitsArePruned() async {
        let history = store()
        await history.record(url: deploy, title: "Deploy", at: .distantPast)
        await history.prune(before: Date().addingTimeInterval(-365 * 86_400))
        #expect(await history.search("deploy", limit: 5).isEmpty)
    }
    @Test func anUnopenableFileDoesntCrash() async {
        let history = HistoryStore(file: URL(fileURLWithPath: "/nonexistent/folder/h.sqlite"))
        await history.record(url: deploy, title: "x")
        #expect(await history.search("x", limit: 5).isEmpty)
    }
    @Test func finishedPagesLandInHistory() async {
        let profile = Profile.temporary()
        let tabs = TabManager(profile: profile, keepsSpare: false)
        let tab = tabs.newTab(nil, activate: true)
        await finishLoading(tab) { tab.webView.loadHTMLString("<title>Deploy</title>", baseURL: URL(string: "https://localhost/deploy")) }
        let found = await eventually { await profile.history.search("deploy", limit: 5).count == 1 }
        #expect(found)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST HistoryStoreTests`
Expected: build FAILS with `cannot find 'HistoryStore' in scope`

- [ ] **Step 3: Implement `HistoryStore`**

- `import SQLite3`. Create the parent folder first. Bind strings with `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`.
- Tables: `visits(url TEXT PRIMARY KEY, title TEXT, visit_count INTEGER, last_visit REAL)`, and a `history_fts` FTS5 table on `url, title` keyed to `visits.rowid`, kept in step inside one transaction. Set `PRAGMA user_version = 1`.
- Queries: split the text on whitespace, wrap each token in double quotes with embedded quotes doubled, add `*`, and join with spaces. A query with no usable token returns nothing.
- Order: `visit_count * 1.0 / (1 + days since last_visit)` descending.
- Any SQLite failure logs with `NSLog` and returns an empty result. History must never block navigation.
- `TabManager` records `didFinish` main-frame loads for `http` and `https` through `profile.history`. `AppController` prunes entries older than a year at launch.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST HistoryStoreTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob pobTests/HistoryStoreTests.swift
git commit -m "feat: add searchable history"
```

---

### Task 6: Bookmarks and favicons

**Files:**
- Create: `pob/Profile/BookmarkStore.swift`, `pob/Profile/FaviconStore.swift`
- Modify: `pob/Profile/Profile.swift`, `pob/Tab/TabManager.swift`, `pob/Chrome/Rail.swift`, `pob/Chrome/TabListView.swift`, `pob/App/Commands.swift`, `pob/App/MainMenu.swift`, `pob/Window/WindowController.swift`
- Test: `pobTests/BookmarkStoreTests.swift`

**Interfaces:**
- Produces:

```swift
struct Bookmark: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var url: URL
    var folder: String?
    var isPinned: Bool
}
final class BookmarkStore {
    init(file: JSONFile<[Bookmark]>)
    private(set) var all: [Bookmark]
    var pinned: [Bookmark] { get }
    func addObserver(_ observer: @escaping () -> Void)
    func contains(_ url: URL) -> Bool
    func toggle(url: URL, title: String)       // adds it pinned, or removes it
    func setPinned(_ isPinned: Bool, id: UUID)
}
final class FaviconStore {
    init(directory: URL)
    func image(forHost host: String) -> NSImage?
    func update(host: String, from page: WKWebView) async
    static func letter(for host: String) -> String
    static func letterTile(for host: String, size: CGFloat) -> NSImage
}
// Profile gains: var bookmarks: BookmarkStore { get } (bookmarks.json), var favicons: FaviconStore { get }
// CommandID gains bookmarkPage (⌘D).
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct BookmarkStoreTests {
    func file() -> JSONFile<[Bookmark]> {
        JSONFile(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json"))
    }
    let page = URL(string: "https://example.com/a")!

    @Test func togglingAddsThenRemoves() {
        let store = BookmarkStore(file: file())
        store.toggle(url: page, title: "A")
        #expect(store.contains(page))
        #expect(store.pinned.map(\.title) == ["A"])
        store.toggle(url: page, title: "A")
        #expect(!store.contains(page))
    }
    @Test func unpinningKeepsTheBookmark() {
        let store = BookmarkStore(file: file())
        store.toggle(url: page, title: "A")
        store.setPinned(false, id: store.all[0].id)
        #expect(store.pinned.isEmpty)
        #expect(store.contains(page))
    }
    @Test func bookmarksSurviveARelaunch() {
        let file = file()
        BookmarkStore(file: file).toggle(url: page, title: "A")
        #expect(BookmarkStore(file: file).contains(page))
    }
    @Test func corruptFilesStartEmpty() throws {
        let file = file()
        try "nope".write(to: file.url, atomically: true, encoding: .utf8)
        #expect(BookmarkStore(file: file).all.isEmpty)
    }
    @Test func letterTilesUseTheHostsFirstLetter() {
        #expect(FaviconStore.letter(for: "www.example.com") == "E")
        #expect(FaviconStore.letter(for: "") == "?")
    }
    @Test func commandIsBound() {
        let command = CommandList.standard { _ in }.command(.bookmarkPage)
        #expect(command?.key == "d")
        #expect(command?.isReserved == false)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST BookmarkStoreTests`
Expected: build FAILS with `cannot find 'BookmarkStore' in scope`

- [ ] **Step 3: Implement the stores**

- `FaviconStore.update` runs JavaScript for `document.querySelector('link[rel~="icon"]')?.href`, falling back to `/favicon.ico`, fetches with `URLSession`, and caches a PNG named by host. It ignores failures, leaving the letter tile.
- `TabManager` calls `update` after each main-frame load.
- `favicons/` sits in `Application Support/pob/`, next to `profiles/`. A temporary profile keeps its own inside its directory.
- A new bookmark starts pinned, so ⌘D visibly does something. Stage 3's import adds unpinned ones.

- [ ] **Step 4: Show them in the rail**

Pinned bookmarks appear as icons between the address field and the tabs, wrapping onto new rows. A click opens the bookmark in the current tab, and the context menu offers Unpin and Remove. `WindowController` listens through `profile.bookmarks.addObserver`. Tab rows now use real favicons.

- [ ] **Step 5: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add pob pobTests/BookmarkStoreTests.swift
git commit -m "feat: add bookmarks and favicons"
```

---

### Task 7: Switcher

**Files:**
- Create: `pob/Chrome/SwitcherModel.swift`, `pob/Chrome/SwitcherView.swift`
- Modify: `pob/Window/WindowController.swift`, `pob/Chrome/Rail.swift`
- Test: `pobTests/SwitcherModelTests.swift`

**Interfaces:**
- Consumes: `TabRecord`, `Bookmark`, `HistoryEntry`, `Command`, `AddressInput`
- Produces:

```swift
struct SwitcherRow: Equatable {
    enum Target: Equatable { case tab(UUID), url(URL), command(CommandID), address(AddressInput) }
    let target: Target
    let title: String
    let subtitle: String
    let section: String    // "Tabs", "Bookmarks", "History", "Commands" or ""
}
enum SwitcherModel {
    static func rows(query: String, tabs: [TabRecord], bookmarks: [Bookmark], history: [HistoryEntry], commands: [Command]) -> [SwitcherRow]
}
final class SwitcherView: NSView {
    var onChoose: ((SwitcherRow) -> Void)?
    var onCancel: (() -> Void)?
    var onQueryChange: ((String) -> Void)?
    func show(rows: [SwitcherRow])
    func focus()
}
```

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST SwitcherModelTests`
Expected: build FAILS with `cannot find 'SwitcherModel' in scope`

- [ ] **Step 3: Implement `SwitcherModel`**

Matching is a case-insensitive contains on title and URL for tabs, bookmarks and commands. History arrives already filtered by `HistoryStore.search`. An empty query shows only tabs. Row order: tabs, then the address row if the input classifies as a URL, then bookmarks, history and commands, and finally the address row for a search. Show at most 5 tabs, 3 bookmarks, 5 history entries and 3 commands.

- [ ] **Step 4: Implement `SwitcherView` and wire it up**

- An overlay in the window: a dimming view at 22% black, and one `NSGlassEffectView` about 56% of the window's width, with a search field and an `NSTableView` of rows with section headers.
- Up and down move the selection through `control(_:textView:doCommandBy:)`. Return chooses. Esc or clicking outside cancels.
- `WindowController` queries `profile.history` as you type. It shows tabs and commands at once and adds history when it returns, dropping a result whose query no longer matches the field.
- `.tab` activates. `.url` and `.address` open a new tab. `.command` performs it. Nothing is created until Return.
- `openSwitcher` and `openSwitcherFromPage` show it, replacing Task 3's blank tab.
- A window with no tabs opens the switcher, and the `about:blank` launch tab goes away.
- The address field uses the same `SwitcherModel` while you type: suggestions replace the tab list in the rail until editing ends, and they navigate the current tab.

- [ ] **Step 5: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add pob pobTests/SwitcherModelTests.swift
git commit -m "feat: add the switcher and address suggestions"
```

**User check for Task 16:** ⌘T appears instantly, typing feels immediate, and Return does what you'd expect.

---

### Task 8: Domain pill and loading line

**Files:**
- Create: `pob/Chrome/DomainPill.swift`, `pob/Chrome/LoadingLine.swift`
- Modify: `pob/Window/WindowController.swift`, `pob/Tab/Tab.swift`, `pob/Tab/TabManager.swift`
- Test: `pobTests/DomainPillTests.swift`

**Interfaces:**
- Produces:

```swift
final class DomainPill: NSView {
    static let visibleDuration: Duration    // 2 seconds
    static func displayHost(for url: URL?) -> String?   // nil for about: pages and URLs with no host
    var isSuppressed: Bool                  // true while the rail is open
    private(set) var currentURL: URL?
    func show(url: URL?)
    func showNotice(_ text: String)
    func copyURL(to pasteboard: NSPasteboard)
}
final class LoadingLine: NSView {
    func update(progress: Double, isLoading: Bool)
    var fraction: Double { get }   // 0 when hidden
}
// Tab gains: var onProgress: ((Double, Bool) -> Void)? from estimatedProgress and isLoading.
// TabManager gains: var onActiveProgress: ((Double, Bool) -> Void)?, forwarding the active tab's.
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct DomainPillTests {
    @Test func showsTheHostOnly() {
        #expect(DomainPill.displayHost(for: URL(string: "https://docs.example.com/a?b=1")) == "docs.example.com")
    }
    @Test func internationalHostsShowAsPunycodeSoLookalikesStandOut() {
        #expect(DomainPill.displayHost(for: URL(string: "https://xn--pple-43d.com/")) == "xn--pple-43d.com")
        #expect(DomainPill.displayHost(for: URL(string: "https://аpple.com/")) == "xn--pple-43d.com")   // Cyrillic а
        #expect(DomainPill.displayHost(for: URL(string: "https://bücher.example/a")) == "xn--bcher-kva.example")
    }
    @Test func pagesWithNoHostShowNothing() {
        #expect(DomainPill.displayHost(for: URL(string: "about:blank")) == nil)
        #expect(DomainPill.displayHost(for: URL(string: "file:///tmp/a.html")) == nil)
        #expect(DomainPill.displayHost(for: nil) == nil)
    }
    @Test func clickingCopiesTheFullAddress() {
        let pill = DomainPill(frame: .zero)
        let url = URL(string: "https://docs.example.com/a?b=1")!
        pill.show(url: url)
        let board = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
        pill.copyURL(to: board)
        #expect(board.string(forType: .string) == url.absoluteString)
    }
    @Test func stayingOutOfTheWayWhileTheRailIsOpen() {
        let pill = DomainPill(frame: .zero)
        pill.isSuppressed = true
        pill.show(url: URL(string: "https://example.com"))
        #expect(pill.isHidden)
    }
    @Test func loadingLineFollowsProgressAndHidesWhenDone() {
        let line = LoadingLine(frame: NSRect(x: 0, y: 0, width: 100, height: 2))
        line.update(progress: 0.4, isLoading: true)
        #expect(line.fraction == 0.4)
        line.update(progress: 1, isLoading: false)
        #expect(line.fraction == 0)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST DomainPillTests`
Expected: build FAILS with `cannot find 'DomainPill' in scope`

- [ ] **Step 3: Implement both views**

- `DomainPill`: a glass capsule at the bottom left, inset 12 pt. `effectIsInteractive = true`, because the pill is a control. Fades out after `visibleDuration`. Hovering holds it. Clicking copies the full URL and shows `Copied` for 1 second. `displayHost` uses `URLComponents(url:resolvingAgainstBaseURL:)?.encodedHost` and treats an empty host as nil, because `URL.host()` percent-encodes a raw international host.
- `LoadingLine`: a thin accent-colored bar along the top edge of the window. It isn't glass.

- [ ] **Step 4: Wire them up**

- `tabs.onLoadFinished` calls `pill.show(url:)` when that tab is active. Switching tabs does too.
- `isSuppressed` is true whenever `railState.visibility != .hidden`.
- `Tab` uses `webView.observe(\.estimatedProgress)` and `\.isLoading`. `tabs.onActiveProgress` updates the line.

- [ ] **Step 5: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add pob pobTests/DomainPillTests.swift
git commit -m "feat: add the domain pill and loading line"
```

**User check for Task 16:** the pill appears at the bottom left after a page loads, click copies the URL, and the line shows while loading.

---

### Task 9: Session restore and windows

**Files:**
- Create: `pob/Profile/SessionStore.swift`
- Modify: `pob/App/AppController.swift`, `pob/Profile/Profile.swift`, `pob/Tab/TabManager.swift`, `pob/Window/WindowController.swift`
- Test: `pobTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: `JSONFile`, `TabRecord`, `TabList`
- Produces:

```swift
struct WindowSnapshot: Codable, Equatable { var tabs: [TabRecord]; var activeIndex: Int; var frame: String }
struct SessionSnapshot: Codable, Equatable { var windows: [WindowSnapshot] }
final class SessionStore {
    init(file: JSONFile<SessionSnapshot>)
    func load() -> SessionSnapshot       // empty when missing or corrupt
    func save(_ snapshot: SessionSnapshot)                 // now
    func saveSoon(_ snapshot: @escaping () -> SessionSnapshot)   // debounced 0.5 s
}
// Profile gains: var session: SessionStore { get }   // lazy, session.json
// TabManager gains: init(profile:keepsSpare:restoring: WindowSnapshot?), var snapshotRecords: [TabRecord] { get }
//   Restored tabs start .saved, and only the active one builds a web view.
// WindowController gains: var onTabsChanged: (() -> Void)?, var onClose: (() -> Void)?
// AppController gains: var windows: [WindowController], func openWindow(restoring: WindowSnapshot?)
```

- [ ] **Step 1: Write the failing tests**

```swift
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
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST SessionStoreTests`
Expected: build FAILS with `cannot find 'SessionStore' in scope`

- [ ] **Step 3: Implement `SessionStore` and restoring**

`snapshotRecords` reads URL, title and `interactionState` from live tabs, and uses the stored values for saved ones.

- [ ] **Step 4: Update `AppController`**

- Launch: load the session, open one window per `WindowSnapshot`, or an empty window showing the switcher if there are none.
- `WindowController` calls `onTabsChanged` from `tabs.onChange`. Save with `saveSoon` on every `onTabsChanged`, and with `save` in `applicationWillTerminate`. Use `window.frameDescriptor` and `setFrame(from:)` for `frame`.
- Closing a window drops it from `windows` and from the session through `onClose`. Quitting doesn't close windows first, so a quit restores all of them.
- Commands target the key window's controller. With no browser window open, ⌘T, ⌘K and ⌘N open one, and other commands do nothing.
- `newWindow` calls `openWindow(restoring: nil)`.
- `applicationShouldTerminateAfterLastWindowClosed` becomes false, and `applicationShouldHandleReopen` opens a window when none are visible.
- The timer and memory source from Task 3 now loop over `windows`.

- [ ] **Step 5: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add pob pobTests/SessionStoreTests.swift
git commit -m "feat: restore tabs and windows"
```

---

### Task 10: When pages fail

**Files:**
- Create: `pob/Tab/ErrorPage.swift`, `pob/Tab/SignInChallenge.swift`
- Modify: `pob/Tab/Tab.swift`
- Test: `pobTests/PageFailureTests.swift`, `pobTests/TabDelegateTests.swift`

**Interfaces:**
- Consumes: `profile.siteSettings`
- Produces:

```swift
enum ErrorPage {
    static func html(for url: URL, error: Error) -> String
    static func crashHTML(for url: URL?) -> String
    static func shouldShow(_ error: Error) -> Bool    // false for cancelled loads and download handoffs
}
enum ChallengeAction: Equatable { case trust, askForPassword, askAboutCertificate, useDefault }
enum SignInChallenge {
    static func action(method: String, hostIsAllowed: Bool, trustIsValid: Bool) -> ChallengeAction
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import pob

@Suite struct PageFailureTests {
    let page = URL(string: "https://example.com/a")!

    @Test func errorPagesNameTheFailure() {
        let error = URLError(.notConnectedToInternet)
        #expect(ErrorPage.html(for: page, error: error).contains("example.com"))
    }
    @Test func errorTextCantInjectMarkup() {
        let error = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "<script>alert(1)</script>"])
        let html = ErrorPage.html(for: page, error: error)
        #expect(!html.contains("<script>alert"))
        #expect(html.contains("&lt;script&gt;alert"))
    }
    @Test func cancelledLoadsShowNothing() {
        #expect(!ErrorPage.shouldShow(URLError(.cancelled)))
        #expect(!ErrorPage.shouldShow(NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(ErrorPage.shouldShow(URLError(.timedOut)))
    }
    @Test func challengesGetTheRightResponse() {
        let cases: [(String, Bool, Bool, ChallengeAction)] = [
            (NSURLAuthenticationMethodHTTPBasic, false, true, .askForPassword),
            (NSURLAuthenticationMethodHTTPDigest, false, true, .askForPassword),
            (NSURLAuthenticationMethodServerTrust, false, true, .useDefault),
            (NSURLAuthenticationMethodServerTrust, false, false, .askAboutCertificate),
            (NSURLAuthenticationMethodServerTrust, true, false, .trust),
            (NSURLAuthenticationMethodClientCertificate, false, true, .useDefault),
        ]
        for (method, allowed, valid, expected) in cases {
            #expect(SignInChallenge.action(method: method, hostIsAllowed: allowed, trustIsValid: valid) == expected)
        }
    }
}
```

Add these selectors to `TabDelegateTests`: `webView:didFailProvisionalNavigation:withError:`, `webView:didFailNavigation:withError:`, `webViewWebContentProcessDidTerminate:`, `webView:didReceiveAuthenticationChallenge:completionHandler:`.

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST PageFailureTests`
Expected: build FAILS with `cannot find 'ErrorPage' in scope`

- [ ] **Step 3: Implement the failure handling**

- `didFailProvisionalNavigation` and `didFail`: when `shouldShow`, call `webView.loadSimulatedRequest(URLRequest(url: failedURL), responseHTML:)`, using `NSURLErrorFailingURLErrorKey` for the URL. The page has a Retry link to the same address. Escape every interpolated value.
- `webViewWebContentProcessDidTerminate`: reload once. If it crashes again within 10 seconds, show `crashHTML`.
- `didReceive challenge`: evaluate with `SecTrustEvaluateWithError`, then follow `SignInChallenge.action`.
  - `.askForPassword`: an `NSAlert` sheet with username and password fields, naming the host and realm. Cancel uses `.cancelAuthenticationChallenge`.
  - `.askAboutCertificate`: an `NSAlert` with Go Back and Allow This Site. Allowing stores `allowsInvalidCertificate` for that host.
  - `.trust`: `.useCredential` with `URLCredential(trust:)`.

- [ ] **Step 4: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`, with no "nearly matches" warnings

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: handle failed pages, crashes and HTTP sign-in"
```

---

### Task 11: Downloads

**Files:**
- Create: `pob/Services/Downloads.swift`, `pob/Chrome/DownloadsPopover.swift`
- Modify: `pob/Profile/Profile.swift`, `pob/Tab/Tab.swift`, `pob/Chrome/Rail.swift`, `pob/Window/WindowController.swift`, `pob/App/AppController.swift`
- Test: `pobTests/DownloadsTests.swift`, `pobTests/TabDelegateTests.swift`

**Interfaces:**
- Produces:

```swift
enum DownloadState: Equatable { case running, finished, failed }
struct DownloadItem: Identifiable, Equatable {
    let id: UUID
    let filename: String
    let destination: URL
    var state: DownloadState
    var progress: Double
}
final class Downloads: NSObject, WKDownloadDelegate {
    init(directory: URL)      // ~/Downloads by default
    private(set) var items: [DownloadItem]
    var onChange: (() -> Void)?        // owned by the open popover
    var onStart: ((String) -> Void)?   // owned by AppController
    func track(_ download: WKDownload)
    func retry(_ id: UUID, in webView: WKWebView)
    static func safeDestination(directory: URL, suggestedFilename: String) -> URL
}
// Profile gains: var downloads: Downloads { get }   // ~/Downloads; a temporary profile uses its own folder
// WindowController gains: func showNotice(_ text: String)
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import pob

@Suite struct DownloadsTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func plainNamesAreKept() throws {
        let folder = try directory()
        #expect(Downloads.safeDestination(directory: folder, suggestedFilename: "report.pdf").lastPathComponent == "report.pdf")
    }
    @Test func existingFilesArentOverwritten() throws {
        let folder = try directory()
        try Data().write(to: folder.appending(path: "report.pdf"))
        #expect(Downloads.safeDestination(directory: folder, suggestedFilename: "report.pdf").lastPathComponent == "report 2.pdf")
    }
    @Test(arguments: ["../../.zshrc", "/etc/passwd", "a/b/c.txt", "..\\..\\x.txt"])
    func namesCantEscapeTheFolder(name: String) throws {
        let folder = try directory()
        let result = Downloads.safeDestination(directory: folder, suggestedFilename: name)
        #expect(result.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
    }
    @Test(arguments: ["", ".", "..", "/"])
    func emptyNamesGetADefault(name: String) throws {
        let folder = try directory()
        #expect(Downloads.safeDestination(directory: folder, suggestedFilename: name).lastPathComponent == "download")
    }
}
```

Add these selectors to `TabDelegateTests`: `webView:decidePolicyForNavigationResponse:decisionHandler:`, `webView:navigationAction:didBecomeDownload:`, `webView:navigationResponse:didBecomeDownload:`. Add a test that `Downloads` responds to `download:decideDestinationUsingResponse:suggestedFilename:completionHandler:`, `downloadDidFinish:` and `download:didFailWithError:resumeData:`.

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST DownloadsTests`
Expected: build FAILS with `cannot find 'Downloads' in scope`

- [ ] **Step 3: Implement `Downloads`**

- `safeDestination`: replace backslashes with slashes, take the last path component, and fall back to `download` for empty, `.` and `..`. If the file exists, insert ` 2`, ` 3` and so on before the extension.
- `Tab`: `decidePolicyFor navigationResponse` returns `.download` when `canShowMIMEType` is false. Both `didBecome` methods hand the download to `Downloads`.
- Progress comes from `download.progress`. `AppController` sets `onStart` to call `showNotice` on the key window's controller, which passes it to the pill.
- `retry` calls `webView.startDownload(using: originalRequest)`.

- [ ] **Step 4: Add the popover**

The rail's download button opens a transient `NSPopover` listing items with progress, Reveal in Finder (`NSWorkspace.shared.activateFileViewerSelecting`) and Retry for failed ones.

- [ ] **Step 5: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add pob pobTests
git commit -m "feat: add downloads"
```

---

### Task 12: Find, printing and zoom

**Files:**
- Create: `pob/Chrome/FindBar.swift`, `pob/Tab/ZoomLevels.swift`
- Modify: `pob/App/Commands.swift`, `pob/App/MainMenu.swift`, `pob/Window/WindowController.swift`, `pob/Tab/Tab.swift`
- Test: `pobTests/FindAndZoomTests.swift`

**Interfaces:**
- Consumes: `profile.siteSettings`
- Produces:

```swift
enum ZoomLevels {
    static let steps: [Double]    // 0.5, 0.75, 0.9, 1, 1.1, 1.25, 1.5, 2
    static func larger(than zoom: Double) -> Double
    static func smaller(than zoom: Double) -> Double
}
final class FindBar: NSView {
    var onSearch: ((String, _ backwards: Bool) -> Void)?
    var onClose: (() -> Void)?
    func focus()
    func showResult(found: Bool)
}
// CommandID gains: find (⌘F), print (⌘P), zoomIn (⌘+), zoomOut (⌘-), actualSize (⌘0).
// zoomIn uses key "=", so it works without Shift. MainMenu adds a hidden "+" item with
//   allowsKeyEquivalentWhenHidden, so ⌘+ works too.
// Tab gains: func find(_ text: String, backwards: Bool) async -> Bool
//            func setZoom(_ zoom: Double) (saves per host), and saved zoom applies on didCommit.
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
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
        #expect(list.command(.find)?.isReserved == false)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST FindAndZoomTests`
Expected: build FAILS with `cannot find 'ZoomLevels' in scope`

- [ ] **Step 3: Implement**

- `Tab.find` uses `webView.find(_:configuration:)` with `WKFindConfiguration`, `wraps = true`, and `backwards` as given.
- `FindBar`: a small glass field at the top right. Return finds the next match, ⇧Return the previous one, and Esc closes and returns focus to the page. It shows `Not found` in the bar.
- Print: `webView.printOperation(with: .shared)`, set `operation.view?.frame = webView.bounds`, and run it with `runModal(for:delegate:didRun:contextInfo:)`.
- Zoom: `webView.pageZoom`, stored in `SiteSettings` by host.

- [ ] **Step 4: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob pobTests
git commit -m "feat: add find, printing and per-site zoom"
```

---

### Task 13: Remembered permissions

**Files:**
- Modify: `pob/Services/Permissions.swift`, `pob/Tab/Tab.swift`, `pob/App/Commands.swift`, `pob/Window/WindowController.swift`, `Config/Info.plist`, `Config/pob.entitlements`
- Test: `pobTests/PermissionsTests.swift`, `pobTests/TabDelegateTests.swift`

**Interfaces:**
- Consumes: `profile.siteSettings`
- Produces:

```swift
enum PermissionKind { case camera, microphone, location }
extension Permissions {
    static func kinds(for type: WKMediaCaptureType) -> [PermissionKind]
    static func remembered(_ kinds: [PermissionKind], host: String, in settings: SiteSettings) -> Bool?   // nil until every kind is answered
    static func remember(_ allowed: Bool, kinds: [PermissionKind], host: String, in settings: SiteSettings)
    static func settingsURL(for kind: PermissionKind) -> URL
    static let screenRecordingSettingsURL: URL
    static func forget(host: String, in settings: SiteSettings)   // clears its answers and certificate exception, keeps zoom
}
// CommandID gains, with no shortcuts: screenRecordingSettings ("Screen Recording Settings"),
//   resetSitePermissions ("Reset Permissions for This Site").
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct PermissionsTests {
    func settings() -> SiteSettings {
        SiteSettings(file: JSONFile(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")))
    }

    @Test func nothingIsRememberedAtFirst() {
        #expect(Permissions.remembered([.camera], host: "a.com", in: settings()) == nil)
    }
    @Test func answersAreRememberedPerSite() {
        let store = settings()
        Permissions.remember(true, kinds: [.camera], host: "a.com", in: store)
        #expect(Permissions.remembered([.camera], host: "a.com", in: store) == true)
        #expect(Permissions.remembered([.camera], host: "b.com", in: store) == nil)
    }
    @Test func aCallNeedsBothAnswers() {
        let store = settings()
        Permissions.remember(true, kinds: [.camera], host: "a.com", in: store)
        #expect(Permissions.remembered(Permissions.kinds(for: .cameraAndMicrophone), host: "a.com", in: store) == nil)
    }
    @Test func aDenialWins() {
        let store = settings()
        Permissions.remember(true, kinds: [.camera], host: "a.com", in: store)
        Permissions.remember(false, kinds: [.microphone], host: "a.com", in: store)
        #expect(Permissions.remembered([.camera, .microphone], host: "a.com", in: store) == false)
    }
    @Test func settingsLinksPointAtTheRightPane() {
        #expect(Permissions.settingsURL(for: .camera).absoluteString.hasSuffix("Privacy_Camera"))
        #expect(Permissions.settingsURL(for: .microphone).absoluteString.hasSuffix("Privacy_Microphone"))
        #expect(Permissions.settingsURL(for: .location).absoluteString.hasSuffix("Privacy_LocationServices"))
    }
    @Test func resettingASiteForgetsItsAnswersButKeepsZoom() {
        let store = settings()
        Permissions.remember(false, kinds: [.camera, .microphone], host: "a.com", in: store)
        store["a.com"].allowsInvalidCertificate = true
        store["a.com"].zoom = 1.25
        Permissions.forget(host: "a.com", in: store)
        #expect(Permissions.remembered([.camera], host: "a.com", in: store) == nil)
        #expect(store["a.com"].allowsInvalidCertificate == nil)
        #expect(store["a.com"].zoom == 1.25)
    }
    @Test func screenRecordingHasARouteToSettings() {
        #expect(Permissions.screenRecordingSettingsURL.absoluteString.hasSuffix("Privacy_ScreenCapture"))
        #expect(CommandList.standard { _ in }.command(.screenRecordingSettings)?.title == "Screen Recording Settings")
    }
}
```

Add `webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:` to `TabDelegateTests`.

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST PermissionsTests`
Expected: build FAILS with `type 'Permissions' has no member 'remembered'`

- [ ] **Step 3: Implement**

- Media requests check `remembered` in `profile.siteSettings` first. If there's no answer, they ask, then remember.
- Before prompting for a site, check `AVCaptureDevice.authorizationStatus(for:)`, or `CLLocationManager().authorizationStatus` for location. On `.denied`, deny and show an `NSAlert` explaining macOS has it turned off, with a button that opens `settingsURL`.
- Add `webView(_:requestGeolocationPermissionFor:initiatedByFrame:decisionHandler:)`, with the same flow.
- WebKit gives pob no signal when macOS refuses screen capture, so the spec's explanation for that case becomes the `screenRecordingSettings` command, which opens the pane from the switcher.
- `resetSitePermissions` calls `forget` for the active tab's host and reloads, so the site asks again.
- Add `NSLocationUsageDescription` (`Sites can ask for your location.`) to `Info.plist`, and `com.apple.security.personal-information.location` to the entitlements.

- [ ] **Step 4: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob pobTests Config
git commit -m "feat: remember site permissions"
```

---

### Task 14: Ad blocking

**Decision needed first:** the user picks how filter lists get converted. This task is written for the spec's choice, AdGuard's SafariConverterLib. Its `GenerateVersion` build plugin needs Xcode's trust, so after Step 1 the user opens `pob.xcodeproj` once and chooses **Trust & Enable**. Don't bypass this. If the build still reports the plugin isn't enabled, stop and ask. No other task depends on this one.

**Files:**
- Create: `pob/Services/ContentBlocker.swift`, `pob/Lists/easylist.txt`, `pob/Lists/easyprivacy.txt`
- Modify: `project.yml`, `pob/Profile/Profile.swift`, `pob/Profile/SiteSettings.swift`, `pob/Tab/Tab.swift`, `pob/App/AppController.swift`, `pob/App/Commands.swift`, `pob/Window/WindowController.swift`
- Test: `pobTests/ContentBlockerTests.swift`

**Interfaces:**
- Produces:

```swift
struct FilterList: Equatable { let name: String; let remote: URL }
final class ContentBlocker {
    static let lists: [FilterList]   // easylist and easyprivacy from easylist.to
    init(cacheDirectory: URL, bundledDirectory: URL, fetch: @escaping (URL) async throws -> String)
    private(set) var ruleLists: [WKContentRuleList]
    func attach(_ controller: WKUserContentController)   // held weakly; gets the rules now and after every update
    func apply(to controller: WKUserContentController)   // adds the current rules once
    func prepare() async                  // compiled rules, else bundled lists
    func refreshIfStale(now: Date) async  // weekly
    nonisolated static func convert(_ text: String) -> String   // WebKit JSON
}
// Profile gains: var contentBlocker: ContentBlocker { get set }   // lazy, settable for tests
// SiteSetting gains: var adBlockerOff: Bool?
// CommandID gains toggleSiteBlocking ("Toggle Ad Blocking for This Site", no shortcut).
```

- [ ] **Step 1: Add the package and bundled lists**

In `project.yml` add under `packages`:

```yaml
packages:
  ContentBlockerConverter:
    url: https://github.com/AdguardTeam/SafariConverterLib
    exactVersion: 4.3.1
```

Add `- package: ContentBlockerConverter` with `product: ContentBlockerConverter` to the `pob` target's `dependencies`. Download `https://easylist.to/easylist/easylist.txt` and `https://easylist.to/easylist/easyprivacy.txt` into `pob/Lists/`. Run `xcodegen generate`, and ask the user to trust the plugin.

- [ ] **Step 2: Write the failing tests**

```swift
import Foundation
import Testing
import WebKit
@testable import pob

final class CountingScheme: NSObject, WKURLSchemeHandler {
    private(set) var requested: [String] = []
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        requested.append(task.request.url?.lastPathComponent ?? "")
        task.didFailWithError(URLError(.cancelled))
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@Suite struct ContentBlockerTests {
    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func blocker(
        bundled: URL? = nil,
        fetch: @escaping (URL) async throws -> String = { _ in throw URLError(.notConnectedToInternet) }
    ) throws -> ContentBlocker {
        let resources = try bundled ?? #require(Bundle(for: Tab.self).resourceURL)
        return ContentBlocker(cacheDirectory: try folder(), bundledDirectory: resources, fetch: fetch)
    }
    func listFolder(_ rule: String) throws -> URL {
        let bundled = try folder()
        try rule.write(to: bundled.appending(path: "easylist.txt"), atomically: true, encoding: .utf8)
        return bundled
    }

    @Test func convertsANetworkRule() {
        #expect(ContentBlocker.convert("||ads.example^").contains("ads"))
    }
    @Test func bundledListsCompile() async throws {
        let blocker = try blocker()
        await blocker.prepare()
        #expect(blocker.ruleLists.count == 2)
    }
    @Test func aListThatFailsIsSkipped() async throws {
        let blocker = try blocker(bundled: listFolder("||ads.example^"))   // no easyprivacy.txt
        await blocker.prepare()
        #expect(blocker.ruleLists.count == 1)
    }
    @Test func aFailedRefreshKeepsTheLastGoodRules() async throws {
        let blocker = try blocker()
        await blocker.prepare()
        await blocker.refreshIfStale(now: .now.addingTimeInterval(8 * 86_400))
        #expect(blocker.ruleLists.count == 2)
    }
    @Test func aFreshCacheSkipsTheNetwork() async throws {
        var fetched = 0
        let blocker = try blocker(fetch: { _ in fetched += 1; return "||ads.example^" })
        await blocker.prepare()
        await blocker.refreshIfStale(now: .now)
        #expect(fetched == 0)
    }
    @Test func listedRequestsNeverLeaveEvenForTabsBuiltBeforeTheRules() async throws {
        let blocker = try blocker(bundled: listFolder("/blocked.png"))
        let scheme = CountingScheme()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "pobtest")
        blocker.attach(configuration.userContentController)
        await blocker.prepare()

        let tab = Tab(profile: .temporary(), configuration: configuration)
        await finishLoading(tab) {
            tab.webView.loadHTMLString("<img src='pobtest://x/blocked.png'><img src='pobtest://x/allowed.png'>", baseURL: URL(string: "pobtest://x/"))
        }
        #expect(scheme.requested.contains("allowed.png"))
        #expect(!scheme.requested.contains("blocked.png"))
    }
    @Test func aSiteSwitchedOffLoadsEverything() async throws {
        let profile = Profile.temporary()
        profile.contentBlocker = try blocker(bundled: listFolder("/blocked.png"))
        await profile.contentBlocker.prepare()
        profile.siteSettings["x"].adBlockerOff = true

        let scheme = CountingScheme()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(scheme, forURLScheme: "pobtest")
        let tab = Tab(profile: profile, configuration: configuration)
        await finishLoading(tab) {
            tab.webView.loadHTMLString("<img src='pobtest://x/blocked.png'>", baseURL: URL(string: "pobtest://x/"))
        }
        #expect(scheme.requested.contains("blocked.png"))
    }
}
```

A hand-written `url-filter` rule was probed and does block this `pobtest://` image. If the last test fails, check the JSON that `convert` produced first.

- [ ] **Step 3: Run them to verify they fail**

Run: `TEST ContentBlockerTests`
Expected: build FAILS with `cannot find 'ContentBlocker' in scope`

- [ ] **Step 4: Implement `ContentBlocker`**

- `init` creates `cacheDirectory` and opens `WKContentRuleListStore(url:)` there. If that fails, log it and keep no rules.
- `convert` calls `ContentBlockerConverter().convertArray(rules:safariVersion:advancedBlocking:)` with `SafariVersion.autodetect()` and `advancedBlocking: false`, and returns `safariRulesJSON`. Run it off the main actor.
- `prepare`: look up `contentRuleList(forIdentifier:)` for each list, and compile from the bundled text when it's missing. A list that can't be read or compiled is skipped and logged. Record the date when bundled text compiles, so the weekly clock starts then.
- `refreshIfStale`: when the last refresh is over 7 days old, fetch, convert and compile each list. Any failure keeps the existing rule list and logs. Store the date in `cacheDirectory`.
- `attach` keeps controllers in `NSHashTable.weakObjects()`, which also covers the spare tab and popups.
- `Tab.init` calls `profile.contentBlocker.attach(webView.configuration.userContentController)`. Each tab keeps its own controller, as the spec requires for Stage 3's per-site switch.
- In `decidePolicyFor navigationAction`, before calling the decision handler for a main-frame load, `Tab` reads `adBlockerOff` for the target host. True calls `removeAllContentRuleLists()`, otherwise `profile.contentBlocker.apply(to:)`.
- `toggleSiteBlocking` flips `adBlockerOff` for the active tab's host and reloads.
- `// shortcut: a weekly refresh can re-add rules to an open page on a switched-off site until its next load`.
- `Profile.contentBlocker` uses `directory.appending(path: "rules")` and `Bundle.main.resourceURL`.
- `AppController` starts `prepare()` at launch without blocking the window, then `refreshIfStale`.
- `// shortcut: one compiled list per filter list, assumes each stays under WebKit's 150,000 rules, split if compiling ever fails on size`. EasyList is about 78,000 lines today.

Record the conversion time and rule counts in the task's commit message, since they're unverified.

- [ ] **Step 5: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add project.yml pob pobTests
git commit -m "feat: add built-in ad blocking"
```

---

### Task 15: Default browser

**Files:**
- Modify: `Config/Info.plist`, `pob/Tab/Tab.swift`, `pob/App/AppController.swift`, `pob/App/Commands.swift`, `pob/App/MainMenu.swift`
- Test: `pobTests/DefaultBrowserTests.swift`

**Interfaces:**
- Produces:

```swift
// CommandID gains makeDefaultBrowser (no shortcut, in the pob menu).
enum IncomingLink {
    static func address(for url: URL) -> AddressInput?   // http, https and file only
}
// AppController gains application(_:open:), and links wait in a queue until a window exists.
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
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
    }
    @Test func localFilesLoad() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".html")
        try "<title>Local</title>".write(to: file, atomically: true, encoding: .utf8)
        let tab = Tab(profile: .temporary())
        await finishLoading(tab) { tab.load(.url(file)) }
        #expect(tab.webView.title == "Local")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST DefaultBrowserTests`
Expected: build FAILS with `cannot find 'IncomingLink' in scope`

- [ ] **Step 3: Implement**

- `Info.plist`: `CFBundleURLTypes` for `http` and `https`, and `CFBundleDocumentTypes` for `public.html`, both with the Viewer role.
- `application(_:open:)` opens each link as a new active tab in the front window, or opens a window first. Links arriving before launch finishes wait in a queue.
- `Tab.load` uses `loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())` for `file:` URLs, so WebKit gets read access.
- `makeDefaultBrowser` calls `NSWorkspace.shared.setDefaultApplication(at:toOpenURLsWithScheme:)` for `http` and `https`. macOS asks the user to confirm.

- [ ] **Step 4: Run the whole suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add Config pob pobTests
git commit -m "feat: support being the default browser"
```

---

### Task 16: Run the Stage 2 checks

Done together with the user.

**Files:**
- Create: `docs/stage-2-results.md`

- [ ] **Step 1: Run the full suite and audit the glass**

Run: `TEST`. Then run the `axiom:liquid-glass-auditor` agent against `pob/`.
Expected: `** TEST SUCCEEDED **`, with no glass on content, no glass on glass and no clear glass.

- [ ] **Step 2: Run the user checks**

Run `RUN` and go through these with the user:

| Check | Pass means |
|---|---|
| Tabs | ⌘T, ⌘W, ⇧⌘T, ⌘1 to ⌘9 and ⌃Tab behave. Rail rows look right, hover shows close, and dragging reorders |
| Windows | ⌘N opens a second window with its own tabs, and quitting restores both |
| Switcher | ⌘T appears instantly, and tabs, bookmarks, history and commands all search |
| Domain pill | Appears at the bottom left after a load, and a click copies the URL |
| Sign-in | Google sign-in popups work as tabs |
| Session | Quitting and relaunching restores tabs and your place |
| Downloads | A file lands in `~/Downloads` and shows in the popover |
| Find, print, zoom | All work, and zoom sticks per site |
| Permissions | A second visit doesn't ask again, and Reset Permissions for This Site makes it ask again |
| Ad blocking | Ads are gone on a normal news site, nothing important breaks, and Toggle Ad Blocking for This Site brings them back after a reload |
| Default browser | A link from another app opens in pob |
| Failures | A bad address shows the error page, `https://expired.badssl.com` asks about the certificate, and `https://httpbin.org/basic-auth/a/b` asks for a password |
| Speed | ⌘T and tab switching feel instant |
| Work day | The user can spend a full work day in pob |
| Screen sharing | Teams or Meet shares a screen and keeps going while switching tabs, including with camera and mic off. The user runs this on demand |

- [ ] **Step 3: Write `docs/stage-2-results.md`**

One row per check with the result and evidence, then any decisions.

- [ ] **Step 4: Commit**

```bash
git add docs/stage-2-results.md
git commit -m "docs: record Stage 2 results"
```
