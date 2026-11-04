# pob Stage 1 ("Prove it") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build one real pob window with a web view, transparency, blur, the slider popover and a glass rail, then run the spec's seven Stage 1 checks.

**Architecture:** A native AppKit app. `WindowController` owns a non-opaque window that stacks one `Tab`'s `WKWebView` under a floating glass `Rail`. Pure logic (settings, address parsing, rail state, commands) stays separate from views so it can be unit tested. Only `PrivateAPI.swift` touches private APIs.

**Tech Stack:** Swift 6, AppKit, WebKit, Swift Testing, XcodeGen 2.46, Xcode 27.2, macOS 27.

**Spec:** `docs/superpowers/specs/2026-11-04-pob-browser-design.md`

**Scope:** Stage 1 only. The spec gives each stage its own plan, and Stage 1's results shape Stage 2, so that plan gets written after Task 12.

## Global Constraints

- Deployment target macOS 27. Swift 6 language mode, Default Actor Isolation MainActor, Approachable Concurrency on.
- App Sandbox off. Hardened Runtime on, with camera and audio input entitlements.
- Sign with `Apple Development: GABRIEL CAMPILLO (ZV8JBS785H)`, team `UR28366SA6`. Never ad-hoc sign.
- Bundle ID `com.gcampillo.pob`.
- AppKit only in this stage.
- Only `pob/Private/PrivateAPI.swift` may use private APIs.
- No new dependencies.
- Glass: `NSGlassEffectView` with `.regular` style, controls only, never on the page, never glass on glass.
- Transparency 0 to 80%, default 18%. Blur 0 to 40, default 16.
- Rail 240 pt wide, inset 8 pt. Left trigger strip 8 pt, 60 ms dwell, 140 ms close delay. Top drag strip 6 pt.
- Keyboard actions never wait for an animation.
- Judge glass and transparency only from `screencapture -x`. It captures the main display and needs an unlocked screen.
- Use the `axiom:axiom-macos`, `axiom:axiom-design` and `axiom:axiom-testing` skills for AppKit, glass and test work.
- Work on branch `stage-1-prove-it`, not `main`.
- End every commit message with:

```text
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01TUZR7A8dDo6iyiQViHVEda
```

**Commands used throughout:**

- `TEST`: `xcodebuild test -project pob.xcodeproj -scheme pob -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd`
- `TEST <Suite>`: the same command plus `-only-testing:pobTests/<Suite>`
- `RUN`: `xcodebuild build -project pob.xcodeproj -scheme pob -destination 'platform=macOS,arch=arm64' -derivedDataPath build/dd && open build/dd/Build/Products/Debug/pob.app`

`project.yml`, the project setup, `TEST`, `-only-testing`, every public API name below, the blur call, the private selectors and the login fill approach were all verified on this Mac in a throwaway project.

## Review Focus

Each of these has its test in the owning task.

1. **Copy, paste, select all and undo.** A hand-built menu bar doesn't get these for free, and without them ⌘V fails in the address field and in pages. Task 6.
2. **Typing an address while the rail is on hover.** The rail must stay open if the pointer wanders off, or typing is lost. Task 8.
3. **Clicking page elements at the left edge.** The trigger strip must never swallow clicks meant for the page. Task 8.
4. **Dragging blur to 0 and back.** iTerm2 reports that setting blur from above 0 to exactly 0 can break it until relaunch. Task 3.
5. **A corrupt or hand-edited `settings.json`.** pob must launch with safe values, not crash. Task 2.

---

### Task 1: Project and app entry point

**Files:**
- Create: `project.yml`, `README.md`, `Config/Info.plist`, `Config/pob.entitlements`, `pob/App/AppController.swift`
- Modify: `.gitignore`
- Test: `pobTests/AppControllerTests.swift`

**Interfaces:**
- Produces: `AppController` (the `@main` `NSApplicationDelegate`, with `static func main()` setting itself as delegate and calling `run()`), and `AppController.isRunningTests: Bool`.

- [ ] **Step 1: Create the project files**

`project.yml`:

```yaml
name: pob
options:
  bundleIdPrefix: com.gcampillo
  deploymentTarget:
    macOS: "27.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor
    SWIFT_APPROACHABLE_CONCURRENCY: YES
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "Apple Development: GABRIEL CAMPILLO (ZV8JBS785H)"
    DEVELOPMENT_TEAM: UR28366SA6
targets:
  pob:
    type: application
    platform: macOS
    sources:
      - path: pob
        type: syncedFolder
    settings:
      base:
        ENABLE_HARDENED_RUNTIME: YES
        INFOPLIST_FILE: Config/Info.plist
        CODE_SIGN_ENTITLEMENTS: Config/pob.entitlements
        PRODUCT_BUNDLE_IDENTIFIER: com.gcampillo.pob
  pobTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: pobTests
        type: syncedFolder
    dependencies:
      - target: pob
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
schemes:
  pob:
    build:
      targets:
        pob: all
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - pobTests
```

`Config/Info.plist`: `CFBundleExecutable` `$(EXECUTABLE_NAME)`, `CFBundleIdentifier` `$(PRODUCT_BUNDLE_IDENTIFIER)`, `CFBundleName` `pob`, `CFBundlePackageType` `APPL`, `CFBundleShortVersionString` `0.1`, `CFBundleVersion` `1`, `NSPrincipalClass` `NSApplication`, `NSCameraUsageDescription` `Sites can use your camera for calls.`, `NSMicrophoneUsageDescription` `Sites can use your microphone for calls.`

`Config/pob.entitlements`: `com.apple.security.device.camera` and `com.apple.security.device.audio-input`, both true.

Add `*.xcodeproj/` to `.gitignore`. `README.md` says to run `xcodegen generate`, then gives the `TEST` and `RUN` commands. Synced folders pick up new files, so regenerate only when `project.yml` changes.

- [ ] **Step 2: Write the failing test**

```swift
import Testing
@testable import pob

@Suite struct AppControllerTests {
    @Test func hostedTestsSkipWindowSetup() {
        #expect(AppController.isRunningTests)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `xcodegen generate`, then `TEST AppControllerTests`
Expected: build FAILS with `cannot find 'AppController' in scope`

- [ ] **Step 4: Implement `AppController` in `pob/App/AppController.swift`**

`isRunningTests` is true when the environment contains `XCTestConfigurationFilePath`. `applicationDidFinishLaunching` returns early when it's true.

- [ ] **Step 5: Run the test to verify it passes**

Run: `TEST AppControllerTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add .gitignore project.yml README.md Config pob pobTests
git commit -m "feat: add project and app entry point"
```

---

### Task 2: Appearance settings

**Files:**
- Create: `pob/Window/AppearanceSettings.swift`, `pob/Window/AppearanceModel.swift`
- Test: `pobTests/AppearanceTests.swift`

**Interfaces:**
- Produces:

```swift
struct AppearanceSettings: Codable, Equatable {
    var transparency: Double            // 0...0.8
    var blur: Int                       // 0...40
    static let standard: AppearanceSettings   // 0.18, 16
    var clamped: AppearanceSettings { get }
}
struct EffectiveAppearance: Equatable { let pageAlpha: Double; let blurRadius: Int }
struct SettingsStore {
    static var defaultFileURL: URL      // ~/Library/Application Support/pob/settings.json
    init(fileURL: URL)
    func load() -> AppearanceSettings   // never throws; bad input gives .standard
    func save(_ settings: AppearanceSettings) throws   // atomic write
}
final class AppearanceModel {
    init(store: SettingsStore, reduceTransparency: Bool)
    var settings: AppearanceSettings { get set }   // applies clamped, calls onChange
    var reduceTransparency: Bool { get set }       // calls onChange
    private(set) var isSnappedOpaque: Bool
    var effective: EffectiveAppearance { get }
    var onChange: (() -> Void)?
    func toggleSnap()
    func persist() throws
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import pob

@Suite struct AppearanceTests {
    func tempFile() -> URL { FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json") }

    @Test func defaultsMatchSpec() {
        #expect(AppearanceSettings.standard == AppearanceSettings(transparency: 0.18, blur: 16))
    }
    @Test func clampsToRange() {
        #expect(AppearanceSettings(transparency: 2, blur: 99).clamped == AppearanceSettings(transparency: 0.8, blur: 40))
        #expect(AppearanceSettings(transparency: -1, blur: -5).clamped == AppearanceSettings(transparency: 0, blur: 0))
    }
    @Test func missingFileGivesDefaults() {
        #expect(SettingsStore(fileURL: tempFile()).load() == .standard)
    }
    @Test(arguments: ["not json", "{}", "{\"transparency\":\"high\",\"blur\":16}", ""])
    func corruptFileGivesDefaults(contents: String) throws {
        let url = tempFile()
        try contents.write(to: url, atomically: true, encoding: .utf8)
        #expect(SettingsStore(fileURL: url).load() == .standard)
    }
    @Test func outOfRangeFileIsClamped() throws {
        let url = tempFile()
        try "{\"transparency\":5,\"blur\":500}".write(to: url, atomically: true, encoding: .utf8)
        #expect(SettingsStore(fileURL: url).load() == AppearanceSettings(transparency: 0.8, blur: 40))
    }
    @Test func saveCreatesFoldersAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "settings.json")
        let store = SettingsStore(fileURL: url)
        try store.save(AppearanceSettings(transparency: 0.4, blur: 20))
        #expect(store.load() == AppearanceSettings(transparency: 0.4, blur: 20))
    }
    @Test func effectiveUsesSettings() {
        let model = AppearanceModel(store: SettingsStore(fileURL: tempFile()), reduceTransparency: false)
        #expect(abs(model.effective.pageAlpha - 0.82) < 0.0001)
        #expect(model.effective.blurRadius == 16)
    }
    @Test func snapGoesOpaqueAndRestores() {
        let model = AppearanceModel(store: SettingsStore(fileURL: tempFile()), reduceTransparency: false)
        model.toggleSnap()
        #expect(model.effective == EffectiveAppearance(pageAlpha: 1, blurRadius: 0))
        model.toggleSnap()
        #expect(model.effective.blurRadius == 16)
    }
    @Test func reduceTransparencyForcesOpaqueWhileRunning() {
        let model = AppearanceModel(store: SettingsStore(fileURL: tempFile()), reduceTransparency: false)
        var changes = 0
        model.onChange = { changes += 1 }
        model.reduceTransparency = true
        #expect(model.effective == EffectiveAppearance(pageAlpha: 1, blurRadius: 0))
        model.reduceTransparency = false
        #expect(model.effective.blurRadius == 16)
        #expect(changes == 2)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST AppearanceTests`
Expected: build FAILS with `cannot find 'AppearanceSettings' in scope`

- [ ] **Step 3: Implement the types above**

`load()` decodes with `JSONDecoder`, returns `.clamped`, and falls back to `.standard` on any error. `save` creates parent folders and writes with `.atomic`. `AppearanceModel.init` loads from the store.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST AppearanceTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob/Window pobTests/AppearanceTests.swift
git commit -m "feat: add appearance settings and model"
```

---

### Task 3: Private API wrapper

**Files:**
- Create: `pob/Private/PrivateAPI.swift`
- Test: `pobTests/PrivateAPITests.swift`

**Interfaces:**
- Produces:

```swift
enum PrivateAPI {
    static func setWindowBlur(_ window: NSWindow, radius: Int) -> Bool
    static func makeBackgroundClear(_ webView: WKWebView)
    static func enableDeveloperExtras(_ configuration: WKWebViewConfiguration)
    static func showInspector(_ webView: WKWebView) -> Bool    // show, then attach
    static func closeInspector(_ webView: WKWebView) -> Bool
    static func isInspectorVisible(_ webView: WKWebView) -> Bool
    static func showConsole(_ webView: WKWebView) -> Bool
    static func showPageSource(_ webView: WKWebView) -> Bool   // false when _mainFrame is nil
    static func missingSelectors(on webView: WKWebView) -> [String]
}
struct BlurGate { mutating func radiusToSend(_ requested: Int) -> Int }
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Testing
import WebKit
@testable import pob

@Suite struct PrivateAPITests {
    @Test func blurWorksOnARealWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        #expect(PrivateAPI.setWindowBlur(window, radius: 10))
    }
    @Test func inspectorAPIsStillExist() {
        let configuration = WKWebViewConfiguration()
        PrivateAPI.enableDeveloperExtras(configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        #expect(PrivateAPI.missingSelectors(on: webView).isEmpty)
    }
    @Test func blurNeverReturnsToZeroOnceUsed() {
        var gate = BlurGate()
        #expect(gate.radiusToSend(0) == 0)
        #expect(gate.radiusToSend(16) == 16)
        #expect(gate.radiusToSend(0) == 1)
        #expect(gate.radiusToSend(8) == 8)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST PrivateAPITests`
Expected: build FAILS with `cannot find 'PrivateAPI' in scope`

- [ ] **Step 3: Implement `PrivateAPI`**

- Blur: `dlsym` with `RTLD_DEFAULT` (`UnsafeMutableRawPointer(bitPattern: -2)`) for `CGSDefaultConnectionForThread` as `@convention(c) () -> Int32` and `CGSSetWindowBackgroundBlurRadius` as `@convention(c) (Int32, Int, Int32) -> Int32`. Pass `window.windowNumber`. Return true when both resolve and the result is 0.
- Background: `webView.setValue(false, forKey: "drawsBackground")`.
- Developer extras: `configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")`.
- Inspector: `webView.value(forKey: "_inspector") as? NSObject`. Selectors are `show`, `close`, `attach`, `showConsole`, `isVisible` and `showMainResourceForFrame:`, passing `webView.perform(NSSelectorFromString("_mainFrame"))`. Read `isVisible` with `value(forKey:)`.
- `missingSelectors` checks `_inspector` and `_mainFrame` on the web view, and the six inspector selectors above.
- `BlurGate` remembers the first non-zero request, then sends at least 1.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST PrivateAPITests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob/Private pobTests/PrivateAPITests.swift
git commit -m "feat: add private API wrapper for blur and Web Inspector"
```

---

### Task 4: Address input

**Files:**
- Create: `pob/Tab/AddressInput.swift`
- Test: `pobTests/AddressInputTests.swift`

**Interfaces:**
- Produces:

```swift
enum AddressInput: Equatable {
    case url(URL)
    case search(URL)
    static func classify(_ text: String) -> AddressInput?   // nil for empty or whitespace
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import pob

@Suite struct AddressInputTests {
    @Test(arguments: [
        ("example.com", "https://example.com"),
        ("  example.com  ", "https://example.com"),
        ("EXAMPLE.com/Path", "https://EXAMPLE.com/Path"),
        ("https://example.com/a?b=1", "https://example.com/a?b=1"),
        ("http://example.com", "http://example.com"),
        ("localhost", "http://localhost"),
        ("localhost:3000", "http://localhost:3000"),
        ("127.0.0.1:8080/health", "http://127.0.0.1:8080/health"),
        ("192.168.1.10", "http://192.168.1.10"),
        ("[::1]:3000", "http://[::1]:3000"),
        ("my-server.local", "http://my-server.local"),
        ("file:///tmp/a.html", "file:///tmp/a.html"),
        ("about:blank", "about:blank"),
    ])
    func recognizesAddresses(input: String, expected: String) {
        #expect(AddressInput.classify(input) == .url(URL(string: expected)!))
    }

    @Test(arguments: [
        ("hello world", "https://www.google.com/search?q=hello%20world"),
        ("swift", "https://www.google.com/search?q=swift"),
        ("foo.bar baz", "https://www.google.com/search?q=foo.bar%20baz"),
        ("a&b=c", "https://www.google.com/search?q=a%26b%3Dc"),
        ("javascript:alert(1)", "https://www.google.com/search?q=javascript%3Aalert(1)"),
    ])
    func treatsEverythingElseAsSearch(input: String, expected: String) {
        #expect(AddressInput.classify(input) == .search(URL(string: expected)!))
    }

    @Test(arguments: ["", "   ", "\n"])
    func emptyInputIsNothing(input: String) {
        #expect(AddressInput.classify(input) == nil)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST AddressInputTests`
Expected: build FAILS with `cannot find 'AddressInput' in scope`

- [ ] **Step 3: Implement `classify`**

Check in this order after trimming: empty gives nil. Anything with a space is a search. `http`, `https`, `file` and `about` schemes pass through as URLs, and every other scheme is a search. `localhost`, IPv4, bracketed IPv6 and `.local` hosts get `http://`. A dotted host with a letter-only last label gets `https://`. Anything else is a search. Encode queries so `&`, `=` and `:` are percent-encoded.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST AddressInputTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob/Tab/AddressInput.swift pobTests/AddressInputTests.swift
git commit -m "feat: classify address field input"
```

---

### Task 5: Tab and web view

**Files:**
- Create: `pob/Tab/Tab.swift`, `pob/Tab/UserAgent.swift`, `pob/Tab/PopupWindow.swift`, `pob/Profile/Profile.swift`, `pob/Services/Permissions.swift`
- Test: `pobTests/TabTests.swift`

**Interfaces:**
- Consumes: `AddressInput`, `PrivateAPI.makeBackgroundClear`, `PrivateAPI.enableDeveloperExtras`
- Produces:

```swift
enum UserAgent {
    static let fallback: String   // "Version/27.0 Safari/605.1.15"
    static func applicationName(safariInfoPlist: URL = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")) -> String
}
struct Profile {
    let id: UUID
    static let initial: Profile   // id 6F0B5C2E-2F4B-4C6E-9B52-1F6B0A5D7C11
    var dataStore: WKWebsiteDataStore { get }   // WKWebsiteDataStore(forIdentifier: id)
}
enum PopupPolicy { case sameTab, popupWindow }
final class Tab: NSObject, WKNavigationDelegate, WKUIDelegate {
    init(profile: Profile)
    let webView: WKWebView
    var onLoadFinished: (() -> Void)?
    var onStateChange: (() -> Void)?   // URL, canGoBack or canGoForward changed
    func load(_ input: AddressInput)
    static func popupPolicy(for navigationType: WKNavigationType) -> PopupPolicy
}
enum Permissions {
    static func promptText(host: String, type: WKMediaCaptureType) -> String
    static func ask(host: String, type: WKMediaCaptureType, in window: NSWindow?, decision: @escaping (WKPermissionDecision) -> Void)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct TabTests {
    func tabWith(html: String) async -> Tab {
        let tab = Tab(profile: .initial)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { tab.onLoadFinished = nil; continuation.resume() }
            tab.webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        }
        return tab
    }

    @Test func userAgentUsesInstalledSafariVersion() throws {
        let plist = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".plist")
        try (["CFBundleShortVersionString": "27.1"] as NSDictionary).write(to: plist)
        #expect(UserAgent.applicationName(safariInfoPlist: plist) == "Version/27.1 Safari/605.1.15")
    }
    @Test func missingSafariFallsBack() {
        let plist = URL(fileURLWithPath: "/nonexistent.plist")
        #expect(UserAgent.applicationName(safariInfoPlist: plist) == UserAgent.fallback)
    }
    @Test func pagesSeeSafari() async throws {
        let tab = await tabWith(html: "<p>x</p>")
        let agent = try await tab.webView.evaluateJavaScript("navigator.userAgent") as? String
        #expect(agent?.contains("Version/") == true && agent?.contains("Safari/") == true)
    }
    @Test func h264AndAACAreSupported() async throws {
        let tab = await tabWith(html: "<p>x</p>")
        let result = try await tab.webView.evaluateJavaScript("document.createElement('video').canPlayType('video/mp4; codecs=\"avc1.42E01E, mp4a.40.2\"')") as? String
        #expect(result == "probably")
    }
    @Test func screenCaptureIsExposed() async throws {
        let tab = await tabWith(html: "<p>x</p>")
        let result = try await tab.webView.evaluateJavaScript("typeof navigator.mediaDevices?.getDisplayMedia") as? String
        #expect(result == "function")
    }
    @Test func linksStayInTheTabAndScriptsGetPopups() {
        #expect(Tab.popupPolicy(for: .linkActivated) == .sameTab)
        #expect(Tab.popupPolicy(for: .other) == .popupWindow)
    }
    @Test func promptNamesTheSiteAndDevice() {
        #expect(Permissions.promptText(host: "meet.example.com", type: .camera) == "Allow meet.example.com to use your camera?")
        #expect(Permissions.promptText(host: "meet.example.com", type: .microphone) == "Allow meet.example.com to use your microphone?")
        #expect(Permissions.promptText(host: "meet.example.com", type: .cameraAndMicrophone) == "Allow meet.example.com to use your camera and microphone?")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST TabTests`
Expected: build FAILS with `cannot find 'Tab' in scope`

- [ ] **Step 3: Implement the types above**

- `Tab.init` builds the configuration: `websiteDataStore` from the profile, `applicationNameForUserAgent` from `UserAgent`, `preferences.isElementFullscreenEnabled = true`, and `PrivateAPI.enableDeveloperExtras`.
- The web view sets `isInspectable`, `allowsBackForwardNavigationGestures` and `allowsMagnification` to true, `underPageBackgroundColor` to `.clear`, and calls `PrivateAPI.makeBackgroundClear`.
- Observe `url`, `canGoBack` and `canGoForward` with KVO for `onStateChange`.
- `createWebViewWith`: when `popupPolicy` is `.sameTab`, load the request in this web view and return nil. Otherwise return `PopupWindow.open(configuration:)`'s web view, built from the supplied configuration so sign-in popups keep `window.opener`.
- `PopupWindow`: a plain opaque `NSWindowController`, retained until closed, which closes on `webViewDidClose`.
- `requestMediaCapturePermissionFor` calls `Permissions.ask`. Don't add a display capture delegate.
- JavaScript alert, confirm and prompt use `NSAlert` sheets. `runOpenPanelWith` uses `NSOpenPanel`.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST TabTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob/Tab pob/Profile pob/Services pobTests/TabTests.swift
git commit -m "feat: add tab, popups, permissions and Safari user agent"
```

---

### Task 6: Commands and menu bar

**Files:**
- Create: `pob/App/Commands.swift`, `pob/App/MainMenu.swift`
- Test: `pobTests/CommandsTests.swift`

**Interfaces:**
- Produces:

```swift
enum CommandID: String, CaseIterable {
    case toggleRail, focusAddress, reload, back, forward, snapOpaque
    case toggleInspector, showConsole, showPageSource, openInSafari, signIn, closeWindow
}
struct Command {
    let id: CommandID
    let title: String
    let key: String                        // empty when there's no shortcut
    let modifiers: NSEvent.ModifierFlags
    let isReserved: Bool                   // taken before the page sees it
    let perform: () -> Void
}
struct CommandList {
    let all: [Command]
    static func standard(perform: @escaping (CommandID) -> Void) -> CommandList
    func command(_ id: CommandID) -> Command?
    func reservedCommand(key: String, modifiers: NSEvent.ModifierFlags) -> Command?
}
enum MainMenu { static func build(commands: CommandList) -> NSMenu }
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Testing
@testable import pob

@Suite struct CommandsTests {
    let list = CommandList.standard { _ in }

    @Test func shortcutsMatchSpec() {
        let expected: [(CommandID, String, NSEvent.ModifierFlags)] = [
            (.toggleRail, "b", .command),
            (.focusAddress, "l", .command),
            (.reload, "r", .command),
            (.back, "[", .command),
            (.forward, "]", .command),
            (.closeWindow, "w", .command),
            (.snapOpaque, "o", [.option, .command]),
            (.toggleInspector, "i", [.option, .command]),
            (.showConsole, "c", [.option, .command]),
            (.showPageSource, "u", [.option, .command]),
        ]
        for (id, key, modifiers) in expected {
            #expect(list.command(id)?.key == key, "\(id)")
            #expect(list.command(id)?.modifiers == modifiers, "\(id)")
        }
    }
    @Test func shortcutsAreUnique() {
        let bound = list.all.filter { !$0.key.isEmpty }.map { "\($0.key)-\($0.modifiers.rawValue)" }
        #expect(Set(bound).count == bound.count)
    }
    @Test func onlyAlwaysReachShortcutsAreReserved() {
        #expect(Set(list.all.filter(\.isReserved).map(\.id)) == [.focusAddress, .closeWindow])
    }
    @Test func reservedLookupIgnoresPageFirstShortcuts() {
        #expect(list.reservedCommand(key: "l", modifiers: .command)?.id == .focusAddress)
        #expect(list.reservedCommand(key: "b", modifiers: .command) == nil)
    }
    @Test func everyCommandReachesTheHandler() {
        var received: [CommandID] = []
        let recording = CommandList.standard { received.append($0) }
        recording.all.forEach { $0.perform() }
        #expect(Set(received) == Set(CommandID.allCases))
    }
    @Test func menuKeepsStandardEditing() {
        let menu = MainMenu.build(commands: list)
        let items = menu.items.compactMap(\.submenu).flatMap(\.items)
        for (action, key) in [("cut:", "x"), ("copy:", "c"), ("paste:", "v"), ("selectAll:", "a"), ("undo:", "z")] {
            #expect(items.contains { $0.action == Selector(action) && $0.keyEquivalent == key }, "missing \(action)")
        }
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST CommandsTests`
Expected: build FAILS with `cannot find 'CommandList' in scope`

- [ ] **Step 3: Implement the types above**

Menus: pob (Quit ⌘Q), Edit (undo, redo, cut, copy, paste, select all, targeting the first responder), View (`toggleRail`, `snapOpaque`), Go (`back`, `forward`, `reload`, `focusAddress`), Develop (`toggleInspector`, `showConsole`, `showPageSource`, `openInSafari`, `signIn`) and Window (minimize, zoom, `closeWindow`). `openInSafari` and `signIn` have no shortcut. Command titles: Show or Hide Rail, Open Location, Reload, Back, Forward, Snap to Opaque, Web Inspector, Console, Page Source, Open in Safari, Sign In with AutoFill, Close Window.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST CommandsTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob/App pobTests/CommandsTests.swift
git commit -m "feat: add command list and menu bar"
```

---

### Task 7: The transparent window

**Files:**
- Create: `pob/Window/WindowController.swift`, `pob/Window/TopDragStrip.swift`
- Modify: `pob/App/AppController.swift`
- Test: `pobTests/WindowControllerTests.swift`

**Interfaces:**
- Consumes: `AppearanceModel`, `Tab`, `PrivateAPI.setWindowBlur`, `BlurGate`, `CommandList`, `MainMenu`
- Produces:

```swift
final class WindowController: NSWindowController {
    init(appearance: AppearanceModel, tab: Tab)
    let tab: Tab
    func applyAppearance()
    func perform(_ id: CommandID)        // later tasks add cases
    var usesFallbackBlur: Bool { get }
    func setWindowButtonsVisible(_ visible: Bool)
}
final class TopDragStrip: NSView { static let height: CGFloat }   // 6
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct WindowControllerTests {
    func make() -> (WindowController, AppearanceModel) {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        return (WindowController(appearance: model, tab: Tab(profile: .initial)), model)
    }

    @Test func windowIsClearAndChromeless() throws {
        let (controller, _) = make()
        let window = try #require(controller.window)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
    }
    @Test func windowButtonsStartHidden() throws {
        let (controller, _) = make()
        #expect(controller.window?.standardWindowButton(.closeButton)?.isHidden == true)
    }
    @Test func appearanceDrivesThePage() {
        let (controller, model) = make()
        #expect(abs(controller.tab.webView.alphaValue - 0.82) < 0.0001)
        model.toggleSnap()
        #expect(controller.tab.webView.alphaValue == 1)
    }
    @Test func privateBlurIsInUseOnThisMac() {
        #expect(!make().0.usesFallbackBlur)
    }
    @Test func snapCommandReachesTheModel() {
        let (controller, model) = make()
        controller.perform(.snapOpaque)
        #expect(model.isSnappedOpaque)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST WindowControllerTests`
Expected: build FAILS with `cannot find 'WindowController' in scope`

- [ ] **Step 3: Implement `WindowController` and `TopDragStrip`**

- Window: `[.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]`, `isOpaque = false`, `backgroundColor = .clear`, `titlebarAppearsTransparent = true`, `titleVisibility = .hidden`, `hasShadow = true`, 1200 by 800, minimum 480 by 360.
- Content view stack, bottom to top: optional fallback blur view, web view filling the window, `TopDragStrip` pinned to the top edge.
- `applyAppearance` sets `tab.webView.alphaValue`, sends the radius through `BlurGate` to `PrivateAPI.setWindowBlur`, and calls `invalidateShadow()`. When the blur call fails, it adds a behind-window `NSVisualEffectView` with `.underWindowBackground` material and sets `usesFallbackBlur`.
- Set `appearance.onChange` to `applyAppearance`.
- `perform` handles `back`, `forward`, `reload`, `snapOpaque` and `closeWindow`.
- `TopDragStrip.mouseDown` calls `window?.performDrag(with:)`.

In `AppController.applicationDidFinishLaunching`, after the test guard:

- Create `AppearanceModel` with the default file and `NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency`.
- Observe `NSWorkspace.accessibilityDisplayOptionsDidChangeNotification` on `NSWorkspace.shared.notificationCenter` and update `reduceTransparency`.
- Create the window with `Tab(profile: .initial)` and load `about:blank`.
- Build `NSApp.mainMenu`.
- Add an `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` monitor that runs `reservedCommand(key:modifiers:)` and swallows the event when it matches. Compare `charactersIgnoringModifiers` and `modifierFlags.intersection(.deviceIndependentFlagsMask)`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `TEST WindowControllerTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Check it for real**

Run: `RUN`, with a busy wallpaper behind the window. Then run `screencapture -x` and read the image.
Expected: no toolbar or window buttons, the desktop blurred through a blank window, rounded corners with no square plates, and a shadow. Dragging the top edge moves the window.

- [ ] **Step 6: Commit**

```bash
git add pob pobTests/WindowControllerTests.swift
git commit -m "feat: add transparent window with adjustable blur"
```

---

### Task 8: The hidden rail

**Files:**
- Create: `pob/Window/RailState.swift`, `pob/Window/EdgeStrip.swift`, `pob/Chrome/Rail.swift`
- Modify: `pob/Window/WindowController.swift`
- Test: `pobTests/RailTests.swift`

**Interfaces:**
- Consumes: `Tab`, `AddressInput`, `WindowController.setWindowButtonsVisible`
- Produces:

```swift
enum RailVisibility { case hidden, hover, pinned }
struct RailState: Equatable {
    private(set) var visibility: RailVisibility = .hidden
    private(set) var isEditingAddress = false
    mutating func pointerDwelledAtEdge()
    mutating func pointerLeftRail()
    mutating func toggleShortcut()
    mutating func beginEditingAddress()
    mutating func endEditingAddress(pointerInsideRail: Bool)
}
final class EdgeStrip: NSView { static let width: CGFloat }   // 8
final class Rail: NSView {
    static let width: CGFloat   // 240
    static let inset: CGFloat   // 8
    var onSubmit: ((String) -> Void)?
    var onSettings: (() -> Void)?
    let addressField: NSTextField
    func update(url: URL?, canGoBack: Bool, canGoForward: Bool)
}
// WindowController gains:
//   private(set) var railState: RailState
//   let rail: Rail
//   func applyRailState()
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct RailTests {
    @Test func edgeOpensAndLeavingCloses() {
        var state = RailState()
        state.pointerDwelledAtEdge()
        #expect(state.visibility == .hover)
        state.pointerLeftRail()
        #expect(state.visibility == .hidden)
    }
    @Test func shortcutPinsAndHides() {
        var state = RailState()
        state.toggleShortcut()
        #expect(state.visibility == .pinned)
        state.pointerLeftRail()
        #expect(state.visibility == .pinned)
        state.toggleShortcut()
        #expect(state.visibility == .hidden)
    }
    @Test func shortcutPinsARailOpenOnHover() {
        var state = RailState()
        state.pointerDwelledAtEdge()
        state.toggleShortcut()
        #expect(state.visibility == .pinned)
    }
    @Test func typingKeepsTheRailOpen() {
        var state = RailState()
        state.beginEditingAddress()
        #expect(state.visibility == .hover)
        state.pointerLeftRail()
        #expect(state.visibility == .hover)
        state.endEditingAddress(pointerInsideRail: false)
        #expect(state.visibility == .hidden)
    }
    @Test func finishingWithThePointerInsideKeepsItOpen() {
        var state = RailState()
        state.beginEditingAddress()
        state.endEditingAddress(pointerInsideRail: true)
        #expect(state.visibility == .hover)
    }
    @Test func edgeStripNeverTakesClicks() {
        let strip = EdgeStrip(frame: NSRect(x: 0, y: 0, width: 8, height: 400))
        #expect(strip.hitTest(NSPoint(x: 4, y: 200)) == nil)
    }
    @Test func railIsRegularGlass() throws {
        let glass = try #require(Rail(frame: .zero).subviewsDeep.compactMap { $0 as? NSGlassEffectView }.first)
        #expect(glass.style == .regular)
    }
    @Test func pinningMovesThePageOverAndHoverDoesNot() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let model = AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false)
        let controller = WindowController(appearance: model, tab: Tab(profile: .initial))
        controller.perform(.toggleRail)
        #expect(controller.tab.webView.obscuredContentInsets.left == 256)
        #expect(controller.window?.standardWindowButton(.closeButton)?.isHidden == false)
        controller.perform(.toggleRail)
        #expect(controller.tab.webView.obscuredContentInsets.left == 0)
    }
}

extension NSView {
    var subviewsDeep: [NSView] { subviews + subviews.flatMap(\.subviewsDeep) }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST RailTests`
Expected: build FAILS with `cannot find 'RailState' in scope`

- [ ] **Step 3: Implement `RailState`, `EdgeStrip` and `Rail`**

- `EdgeStrip` overrides `hitTest` to return nil and uses an `NSTrackingArea` with `.mouseEnteredAndExited`, `.activeAlways` and `.inVisibleRect`. Its `onDwell` closure fires after 60 ms inside.
- `Rail` hosts one `NSGlassEffectView` (`.regular`) inside an `NSGlassEffectContainerView`. Its content view is a vertical stack: a top row leaving room for the window buttons, then back, forward and reload as plain borderless image buttons (`chevron.left`, `chevron.right`, `arrow.clockwise`), the address `NSTextField` on a translucent fill, a flexible spacer, and a `gearshape` button.
- Use `cornerConfiguration` for concentric corners on rows near the panel's corners, and `effectIsInteractive` on the glass only if it holds controls directly.
- Pin the glass view's `contentView` with explicit constraints.
- No glass inside the rail.

- [ ] **Step 4: Wire it into `WindowController`**

- Add the rail above the web view and the strip above that. Add a tracking area on the rail. Leaving it starts a 140 ms timer that calls `pointerLeftRail()`, and re-entering cancels the timer.
- `applyRailState` slides the rail on or off screen with a 0.17 s `NSAnimationContext` and sets `isHidden` when it's off, so hidden glass costs nothing. It shows window buttons when the rail is visible, and sets `obscuredContentInsets.left` to 256 when pinned and 0 otherwise.
- `perform` handles `.toggleRail` and `.focusAddress`. `.focusAddress` calls `beginEditingAddress()`, makes the field first responder and selects its text.
- Return classifies the text with `AddressInput` and loads it. Return and Esc both call `endEditingAddress`.
- `tab.onStateChange` calls `rail.update`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `TEST RailTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 6: Check it for real**

Run: `RUN`, load a real site, then `screencapture -x` in each state.
Expected: the rail appears at the left edge without a stutter and closes after moving away. ⌘B holds it open and pages reflow. If they don't reflow, follow the spec's fallback and shrink the web view's frame. A link within 8 pt of the left edge still clicks. ⌘L, typing and moving the pointer away keeps the rail open.

- [ ] **Step 7: Commit**

```bash
git add pob pobTests/RailTests.swift
git commit -m "feat: add hidden glass rail with edge trigger and pinning"
```

---

### Task 9: Slider popover

**Files:**
- Create: `pob/Chrome/AppearancePopover.swift`
- Modify: `pob/Window/WindowController.swift`
- Test: `pobTests/AppearancePopoverTests.swift`

**Interfaces:**
- Consumes: `AppearanceModel`, `Rail.onSettings`
- Produces:

```swift
final class AppearancePopover: NSViewController {
    init(model: AppearanceModel)
    let transparencySlider: NSSlider   // 0...80
    let blurSlider: NSSlider           // 0...40
    func slidersChanged()              // applies live
    func slidersFinished()             // persists
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Foundation
import Testing
@testable import pob

@Suite struct AppearancePopoverTests {
    @Test func slidersStartAtCurrentValuesAndHaveSpecRanges() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let popover = AppearancePopover(model: AppearanceModel(store: SettingsStore(fileURL: url), reduceTransparency: false))
        popover.loadView()
        #expect(popover.transparencySlider.doubleValue == 18)
        #expect(popover.transparencySlider.maxValue == 80)
        #expect(popover.blurSlider.doubleValue == 16)
        #expect(popover.blurSlider.maxValue == 40)
    }
    @Test func movingSlidersAppliesLiveAndFinishingSaves() {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".json")
        let store = SettingsStore(fileURL: url)
        let model = AppearanceModel(store: store, reduceTransparency: false)
        let popover = AppearancePopover(model: model)
        popover.loadView()
        popover.transparencySlider.doubleValue = 40
        popover.blurSlider.doubleValue = 30
        popover.slidersChanged()
        #expect(model.settings == AppearanceSettings(transparency: 0.4, blur: 30))
        #expect(store.load() == .standard)
        popover.slidersFinished()
        #expect(store.load() == AppearanceSettings(transparency: 0.4, blur: 30))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST AppearancePopoverTests`
Expected: build FAILS with `cannot find 'AppearancePopover' in scope`

- [ ] **Step 3: Implement `AppearancePopover`**

Two labeled continuous `NSSlider`s with value labels, shown in a transient `NSPopover` from the rail's settings button. The popover is a system component, so don't add glass to it. The slider action calls `slidersChanged()`, and calls `slidersFinished()` when `NSApp.currentEvent?.type == .leftMouseUp`. While the popover is open, the rail stays visible.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST AppearancePopoverTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Check it for real**

Run: `RUN`, open the popover over a real page and drag both sliders, including blur to 0 and back.
Expected: the window updates live with no lag, blur returns after 0, ⌥⌘O snaps to opaque and back, and values survive a relaunch.

- [ ] **Step 6: Commit**

```bash
git add pob pobTests/AppearancePopoverTests.swift
git commit -m "feat: add transparency and blur popover"
```

---

### Task 10: Dev tools and Open in Safari

**Files:**
- Modify: `pob/Window/WindowController.swift`, `pob/Tab/Tab.swift`
- Test: `pobTests/DevToolsTests.swift`

**Interfaces:**
- Consumes: `PrivateAPI` inspector functions
- Produces: `Tab.safariURL: URL?`, which is nil for `about:` pages and when no page is loaded. `perform` gains `.toggleInspector`, `.showConsole`, `.showPageSource` and `.openInSafari`.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import pob

@Suite struct DevToolsTests {
    @Test func blankPagesDontOpenInSafari() async {
        let tab = Tab(profile: .initial)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { tab.onLoadFinished = nil; continuation.resume() }
            tab.load(.url(URL(string: "about:blank")!))
        }
        #expect(tab.safariURL == nil)
    }
    @Test func realPagesOpenInSafari() async {
        let tab = Tab(profile: .initial)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { tab.onLoadFinished = nil; continuation.resume() }
            tab.webView.loadHTMLString("<p>x</p>", baseURL: URL(string: "https://localhost/page"))
        }
        #expect(tab.safariURL?.absoluteString == "https://localhost/page")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST DevToolsTests`
Expected: build FAILS with `value of type 'Tab' has no member 'safariURL'`

- [ ] **Step 3: Implement**

- `.toggleInspector` shows or closes based on `isInspectorVisible`.
- `.showConsole` and `.showPageSource` call their `PrivateAPI` functions.
- When any of those returns false, show an `NSAlert` with the text `Web Inspector isn't available in the window. Open this page in Safari's Develop menu instead.`
- `.openInSafari` opens `safariURL` with `NSWorkspace.shared.open(_:withApplicationAt:configuration:)` and `/Applications/Safari.app`.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST DevToolsTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Check it for real**

Run: `RUN`, load a real site, then try ⌥⌘I, ⌥⌘C and ⌥⌘U.
Expected: the inspector docks inside the window, Console and Network work, and page source opens in Sources. Open in Safari opens the current page.

- [ ] **Step 6: Commit**

```bash
git add pob pobTests/DevToolsTests.swift
git commit -m "feat: add Web Inspector commands and Open in Safari"
```

---

### Task 11: Sign-in popover

This is the AutoFill test from the spec: native fields that macOS may fill from Apple Passwords, passed into the page.

**Files:**
- Create: `pob/Chrome/SignInPopover.swift`, `pob/Tab/LoginFiller.swift`
- Modify: `pob/Window/WindowController.swift`
- Test: `pobTests/LoginFillerTests.swift`

**Interfaces:**
- Consumes: `Tab`
- Produces:

```swift
enum LoginFiller {
    static func fill(_ webView: WKWebView, username: String, password: String) async throws -> Bool
}
final class SignInPopover: NSViewController {
    init(host: String, onFill: @escaping (String, String) -> Void)
    let usernameField: NSTextField       // contentType .username
    let passwordField: NSSecureTextField // contentType .password
}
```

- [ ] **Step 1: Write the failing tests**

```swift
import AppKit
import Foundation
import Testing
import WebKit
@testable import pob

@Suite struct LoginFillerTests {
    func tabWith(html: String) async -> Tab {
        let tab = Tab(profile: .initial)
        await withCheckedContinuation { continuation in
            tab.onLoadFinished = { tab.onLoadFinished = nil; continuation.resume() }
            tab.webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
        }
        return tab
    }

    @Test func fillsPasswordsWithSpecialCharacters() async throws {
        let tab = await tabWith(html: "<form><input id=u type=email><input id=p type=password></form>")
        let password = "q\"'\\<>é"
        #expect(try await LoginFiller.fill(tab.webView, username: "a@b.c", password: password))
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('u').value") as? String == "a@b.c")
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('p').value") as? String == password)
    }
    @Test func firesInputEventsSoWebAppsNotice() async throws {
        let tab = await tabWith(html: "<input id=u type=text><input id=p type=password><script>window.n=0;p.addEventListener('input',()=>window.n++)</script>")
        _ = try await LoginFiller.fill(tab.webView, username: "a", password: "b")
        #expect(try await tab.webView.evaluateJavaScript("window.n") as? Int == 1)
    }
    @Test func reportsWhenThereIsNoLoginForm() async throws {
        let tab = await tabWith(html: "<p>nothing here</p>")
        #expect(try await LoginFiller.fill(tab.webView, username: "a", password: "b") == false)
    }
    @Test func fieldsUseAutoFillContentTypes() {
        let popover = SignInPopover(host: "example.com") { _, _ in }
        popover.loadView()
        #expect(popover.usernameField.contentType == .username)
        #expect(popover.passwordField.contentType == .password)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `TEST LoginFillerTests`
Expected: build FAILS with `cannot find 'LoginFiller' in scope`

- [ ] **Step 3: Implement**

- `LoginFiller.fill` runs `webView.callAsyncJavaScript(_:arguments:in:contentWorld:)` with `["user": username, "pass": password]` as arguments, so values never get pasted into script text. Use a `WKContentWorld(configuration:)` with `autofillScriptingEnabled = true`.
- The script finds the first `input[type=password]` and returns false when there's none. It finds the last text or email input before it in document order, sets both values, dispatches bubbling `input` and `change` events, and returns true.
- `SignInPopover` shows `Sign in to <host>`, the two fields and a Fill button, in a transient `NSPopover` from the rail. `.signIn` in `perform` opens it, keeping the rail open.
- Clear both fields after filling. Don't store or log the values.

- [ ] **Step 4: Run them to verify they pass**

Run: `TEST LoginFillerTests`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add pob pobTests/LoginFillerTests.swift
git commit -m "feat: add sign-in popover for the AutoFill test"
```

---

### Task 12: Run the Stage 1 checks

Several checks need the user's real accounts, so this task is done together with them.

**Files:**
- Create: `docs/stage-1-results.md`

**Interfaces:**
- Consumes: the finished app
- Produces: a pass or fail with evidence for each check, and the decision each failure triggers.

- [ ] **Step 1: Run the full suite**

Run: `TEST`
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Audit the glass**

Follow `skills/axiom-design/skills/liquid-glass-auditor.md` from the Axiom plugin against `pob/`.
Expected: no glass on content, no glass on glass, and no clear glass. Fix any findings.

- [ ] **Step 3: Check transparency visually**

With a busy wallpaper, use `screencapture -x` at 0% and blur 0, the default, and 80% with blur 40, plus with Reduce Transparency, Increase Contrast and Reduce Motion each on.
Expected: it matches the approved mockups, with no artifacts or square corners, and glass stays legible. Tune the default blur radius to match the mockup, then update `AppearanceSettings.standard` and its test. Under Reduce Transparency the window goes opaque immediately.

- [ ] **Step 4: Run the user-driven checks**

Run `RUN` and go through these with the user. Record the result, macOS build and notes for each:

| Check | Pass means | If it fails |
|---|---|---|
| Screen sharing in Teams | Remote viewers see the shared screen or window | Try the private capture delegate. If that fails, Open in Safari covers calls and the user decides whether that's acceptable |
| Screen sharing in Meet | Same | Same |
| Google sign-in | Sign-in completes with the Safari user agent | Investigate before Stage 2 |
| H.264 and AAC video | MP4 plays with sound | Investigate, because this is an expected pass |
| Apple Passwords through native AutoFill | macOS offers saved logins in the sign-in popover | Stay on the menu bar and ask the user about the import |
| Docked Web Inspector | Opens in the window with Console and Network working | Use Safari's Develop menu |
| Glass, transparency and blur together | Step 3 passed | Fall back to the fixed public blur, then reassess with the user |

- [ ] **Step 5: Write `docs/stage-1-results.md`**

One row per check with the result and evidence, then any decisions. If WebKit fails screen sharing and Open in Safari isn't acceptable, stop: the engine decision goes back to the user before Stage 2.

- [ ] **Step 6: Commit**

```bash
git add docs/stage-1-results.md
git commit -m "docs: record Stage 1 results"
```
