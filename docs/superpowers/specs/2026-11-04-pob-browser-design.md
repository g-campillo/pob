# pob: design spec

**Date:** 2026-11-04
**Status:** Design approved in brainstorming, written spec awaiting review

## 1. Goal

pob is a personal macOS browser for one person's daily work. Existing browsers feel bloated, so pob does less and stays out of the way: a page fills the window, the browser's controls appear only when needed, and everything responds immediately.

Success means the user can make pob their default browser and do a normal work day in it, including dev work and Teams or Meet calls with screen sharing, without missing anything they rely on.

## 2. Requirements

### Stated by the user

- Minimal and distraction-free, straightforward to use.
- Fast and responsive. The user moves quickly and works from the keyboard.
- Easy to add features to later.
- Extensive Liquid Glass wherever Apple's design allows it.
- Adjustable window transparency, plus adjustable blur.
- Dev tools: page source, network requests and console.
- Ad blocking.
- Bookmarks and multiple profiles.
- Screen sharing in Teams and Google Meet, used every so often.
- Works with Apple Passwords, which the user relies on today.
- Rare engine updates are acceptable.
- No specific Chrome extensions are needed.

### Assumptions, not stated by the user

- macOS 27 and later only, because this is for the user's own Mac.
- The bundle ID is `com.gcampillo.pob` and the app is called pob.
- Google is the default search engine, changeable in Settings.
- Downloads go to `~/Downloads`.
- History is kept for one year and can be cleared in Settings.
- A window belongs to one profile.

## 3. Decisions and why

| Decision | Reason | Ruled out |
|---|---|---|
| WebKit through `WKWebView` | Screen sharing, H.264 and AAC are expected to work without a custom engine build. The engine ships with macOS, and the app stays small | Chromium through CEF: prebuilt Mac CEF has no H.264 or AAC, Teams sharing failed on CEF until it was rebuilt with those codecs, and Alloy style has no screen picker |
| Native Swift and AppKit shell | The most control over the UI, which is the user's main focus | SwiftUI for the shell. SwiftUI is used only for Settings |
| Ad blocking built in | WebKit runs compiled rules natively and needs no extension support | `WKWebExtension`, which remains possible later |
| Regular Liquid Glass only | Apple reserves clear glass for media, and the two shouldn't be mixed | Clear glass |

Rendering matches Safari. The trade-offs accepted with WebKit are no network rewriting, no Chrome DevTools Protocol automation, and no Chrome-only web APIs.

## 4. Look and feel

### Modes

| Mode | What's on screen | How you get there |
|---|---|---|
| Reading | The page only. No toolbar, no window buttons | Default |
| Rail on hover | The rail floats over the page | Pointer reaches the window's left edge |
| Rail pinned | The rail stays open and the page moves over | ⌘B, and ⌘B again to hide |
| Switcher | A centered glass panel over a slightly dimmed page | ⌘T, or ⌘K where the page doesn't use it |
| Web Inspector | WebKit's inspector docked at the bottom | ⌥⌘I |

### Rail

The rail is a floating glass panel about 240 pt wide, inset from the window edge. Top to bottom it holds:

1. Window buttons, then back, forward and reload. This is the only place these appear.
2. Address field. ⌘L opens the rail and focuses it.
3. Bookmarks marked as pinned, shown as icons.
4. Open tabs for this profile, with a New tab row. Tabs can be reordered by dragging and show a close button on hover.
5. Profile switcher, downloads and settings.

Trigger behavior:

- An 8 pt strip along the left edge opens the rail after a 60 ms dwell, so a passing pointer doesn't trigger it.
- The rail closes about 140 ms after the pointer leaves it.
- On hover the rail covers the page and doesn't change its layout.
- Pinned, the page gets a left inset through `WKWebView.obscuredContentInsets`. If that doesn't reflow pages correctly, the web view's frame shrinks instead.

### Domain pill

- A small glass pill at the bottom left shows the current host for about 2 seconds after each main-frame load, then fades.
- Hovering keeps it visible.
- Clicking copies the full URL to the clipboard and briefly shows "Copied".
- Internationalized hosts display as punycode, so lookalike domains are visible. This matters because copying from Passwords has no phishing check.
- The same pill briefly shows a filename when a download starts.

### Other details

- **Loading:** a thin line runs along the top edge of the window while a page loads.
- **Moving the window:** drag from the top of the rail, or from a thin invisible strip along the window's top edge.
- **New window with nothing to restore:** the window shows the blurred desktop with the switcher open.

### Liquid Glass rules

From Axiom's `axiom-design` and `axiom-macos` skills and the liquid-glass plugin:

- Glass is for the functional layer only: rail, switcher, domain pill, find bar, popovers, menus and permission prompts. The page is never glass.
- No glass on glass. Anything on a glass surface uses fills or vibrant text, including selected rows.
- `NSGlassEffectView` for custom surfaces, grouped in `NSGlassEffectContainerView`, with `.regular` style throughout.
- `effectIsInteractive` (macOS 27) on interactive controls only.
- Concentric corners through `NSView.cornerConfiguration` (macOS 27).
- System menus, popovers and alerts are used as they are, because they're already glass.
- Keep the number of glass effects on screen low. Apple warns that too many degrade performance.
- Tint only to signal prominence. Glass surfaces aren't tinted to match the page.
- Reduce Transparency, Increase Contrast and Reduce Motion are handled by the system for glass.
- Animations stay short, and keyboard actions never wait for one to finish.

### Transparency and blur

| Setting | Range | Default | How it works |
|---|---|---|---|
| Transparency | 0 to 80% | 18% | `alphaValue` on the web view, because pages paint their own opaque background |
| Blur | 0 to 40 | 16 | `CGSSetWindowBackgroundBlurRadius`, a private API that Ghostty and iTerm2 use |

- The window is non-opaque with a clear background. It keeps a titled style with a full-size content view, a hidden title and a transparent title bar, so it keeps normal rounded corners and a shadow.
- Liquid Glass doesn't blur the desktop, which is why a separate blur is needed.
- The default blur of 16 is a starting value from the mockup. Stage 1 tunes the real radius to match the approved look.
- If the private blur API is unavailable, an `NSVisualEffectView` with behind-window blending gives a fixed blur.
- ⌥⌘O snaps to opaque and restores the previous values when pressed again. Use it before screen sharing, because whatever is behind the window would otherwise show.
- When Reduce Transparency is on, pob stays opaque.
- Both sliders live in a small glass popover from the rail's settings button, so changes preview live over the page. The popover links to the full Settings window.
- Settings apply to all windows.

## 5. Shortcuts

WebKit gives pages the first chance at shortcuts: it passes key combinations through the page, and they reach the app's menus only if the page doesn't handle them. pob takes the first group below before WebKit sees it.

### Always reach pob

| Action | Shortcut |
|---|---|
| Switcher: search, or type to open a new tab | ⌘T |
| Address field | ⌘L |
| Close tab | ⌘W |
| Reopen closed tab | ⇧⌘T |
| New window | ⌘N |
| Private window | ⇧⌘N |
| Jump to tab | ⌘1 to ⌘9 |

### Page goes first

| Action | Shortcut |
|---|---|
| Show or hide the rail | ⌘B |
| Switcher | ⌘K |
| Find in page | ⌘F |
| Bookmark this page | ⌘D |
| Back and forward | ⌘[ and ⌘] |
| Reload | ⌘R |
| Zoom | ⌘+, ⌘- and ⌘0 |
| Web Inspector | ⌥⌘I |
| Console | ⌥⌘C |
| Page source | ⌥⌘U |
| Snap to opaque | ⌥⌘O |

The left edge always opens the rail, including in web apps that use ⌘B for Bold.

## 6. Architecture

### Project

- Xcode project with an app target and a test target.
- Swift 6 language mode, with Default Actor Isolation set to MainActor and Approachable Concurrency on.
- Deployment target macOS 27.
- App Sandbox off. Hardened Runtime on, with camera and audio input entitlements.
- Usage descriptions for camera, microphone and location in `Info.plist`.
- `http` and `https` URL types and HTML document types, so pob can be the default browser.
- Local builds are signed with an Apple Development certificate. Ad-hoc signing changes the app's identity on every rebuild, which loses Keychain access and should be expected to lose camera, mic and screen permissions too.

### Components

| Unit | Job | Depends on |
|---|---|---|
| `AppController` | App lifecycle, menu bar, reserved shortcuts, windows, opening links from other apps | `Commands`, `WindowController` |
| `Commands` | One list of every action: title, shortcut and handler. Feeds both the menu bar and the switcher | Nothing |
| `WindowController` | Window setup, transparency and blur, left-edge trigger, ⌘B, modes | `Tab`, `Rail`, `Switcher`, `DomainPill`, `PrivateAPI` |
| `Rail` | The rail's views and pinned state | `Profile`, `Tab` |
| `Switcher` | Search across tabs, bookmarks, history and commands | `Profile`, `Commands` |
| `DomainPill` | Host display, URL copy, download notices | Nothing |
| `Tab` | Owns one `WKWebView`, its delegates and its lifecycle | `Profile`, `ContentBlocker`, `Permissions`, `Downloads` |
| `Profile` | Data store, bookmarks, history, session and per-site settings | SQLite, JSON files |
| `ContentBlocker` | Fetch, convert and compile filter lists | SafariConverterLib, `WKContentRuleListStore` |
| `Downloads` | `WKDownload` handling and the downloads list | `DomainPill` |
| `Permissions` | Camera, mic, location prompts and remembered decisions | `Profile` |
| `PrivateAPI` | The only file using private APIs: blur, `drawsBackground`, Web Inspector control | Nothing |
| `SettingsView` | The Settings window, in SwiftUI | `Profile`, `ContentBlocker` |

### Adding features later

A new feature is normally a new entry in `Commands`, which puts it in the menu bar and switcher automatically, plus a rail item if it needs one. There's no plugin system in this version.

## 7. Feature behavior

### Web view setup

- `applicationNameForUserAgent` is set to `Version/<version> Safari/605.1.15`, with the version read from the installed Safari at launch, so sites treat pob as Safari.
- `isInspectable` is on and back/forward swipe gestures are on.
- `isElementFullscreenEnabled` and `allowsMagnification` are on.
- `underPageBackgroundColor` is clear.
- Each `Tab` has its own `WKUserContentController`, so ad blocking can be switched off per site.

### Tabs

Normally only the active tab's web view is in the window. Lifecycle:

| State | Web view | Moves on when |
|---|---|---|
| Active | On screen at full speed | You switch away |
| Background | Detached, `inactiveSchedulingPolicy` is `.throttle` | Idle for 10 minutes |
| Suspended | Detached, policy is `.suspend` | System memory pressure |
| Saved | Released, with URL, title and `interactionState` kept | You return, which recreates it and restores your place |

- WebKit doesn't treat a web view as idle while it's playing media or loading.
- A tab using the camera or microphone stays attached behind the active tab and never steps down, so a call keeps running while you present another tab. Muted capture counts as in use.
- One spare web view per open profile is kept ready. ⌘T uses it, then a new spare is built off the critical path.
- Links opened with ⌘-click open in a background tab.
- `createWebViewWith` opens popups as new tabs using the supplied configuration, so sign-in popups keep their link to the opener.

### Switcher and address field

- Input is classified as a URL, a search or a match.
- Results are grouped as Tabs, Bookmarks, History and Commands, with open tabs ranked first.
- Return switches to an open tab, or opens a new tab. Esc closes.
- Nothing is created until you press Return.
- The address field uses the same search but navigates the current tab.

### Bookmarks

- Stored per profile as a flat list with an optional folder name and a pinned flag.
- Pinned bookmarks appear in the rail, and all bookmarks are searchable in the switcher.
- ⌘D adds or removes the current page.
- Import reads the HTML export format that Safari and Chrome both produce.
- Icons come from the page's declared favicon, cached on disk, with a colored letter tile as the fallback.

### History

- Stored per profile in SQLite with an FTS5 index, written off the main thread.
- macOS's built-in SQLite includes FTS5, so no database dependency is needed. Verified on this Mac with SQLite 3.54.0.
- Private windows write nothing.

### Session

- Windows, tabs, the active tab and each tab's `interactionState` save on every tab change, debounced.
- On launch only the active tab of each window loads. The others start in the Saved state, which keeps launch fast.

### Profiles and private windows

- Each profile uses `WKWebsiteDataStore(forIdentifier:)`, so logins and site data stay separate.
- pob starts with one profile, which you can rename.
- A window belongs to one profile, and ⌘N opens a new window in the same profile. Switching profile saves that window's session and loads the other profile's tabs.
- Private windows use `WKWebsiteDataStore.nonPersistent()` and save no history or session. They show the bookmarks of the profile they were opened from.

### Ad blocking

- EasyList and EasyPrivacy are converted with AdGuard's SafariConverterLib, then compiled with `WKContentRuleListStore`.
- WebKit allows 150,000 rules per list, so output is split across lists when needed.
- A bundled snapshot of the lists blocks ads from first launch.
- Lists refresh weekly in the background. A failed refresh keeps the last good rules.
- Each site can be switched off, stored in per-site settings.
- Only network rules and basic cosmetic rules apply. Ads that need scripts to remove, such as on some video sites, may get through.

### Dev tools

- Web Inspector provides Elements, Console, Sources, Network, Storage and Timelines.
- `PrivateAPI` opens it docked through WebKit's `_inspector` object and enables Inspect Element through `developerExtrasEnabled`. DuckDuckGo's Mac browser uses the same approach.
- ⌥⌘U shows the page's main resource in Sources.
- The inspector is WebKit's own interface, so it stays opaque and can't be glass.
- If the private API goes away, `isInspectable` still allows inspection from Safari's Develop menu.

### Passwords

Apple's `PasswordManagerBrowserExtensionHelper` only serves Chrome, Edge and Firefox, and it verifies launch constraints. A Tor Project report says it has checked each browser's identity against an allow-list since macOS 15.4. A custom browser can't use the iCloud Passwords extension on any engine.

- pob stores no passwords.
- **Fallback, works today:** the macOS Passwords menu bar item, which is already on for this user. Search, copy, paste.
- **Tried first, in Stage 1:** a glass sign-in popover with native `NSTextField` fields using `contentType` `.username` and `.password`. If macOS AutoFill fills them, pob passes the values into the page from an isolated content world.
- **If AutoFill fails:** stay on the menu bar. Importing into pob's own Keychain store is possible, but it wouldn't sync with Apple Passwords, and it would be a new decision for the user.

iCloud passkeys need the `com.apple.developer.web-browser.public-key-credential` entitlement. Only an organization's Account Holder can request it, and Apple reviews each app. Until then, sites need a password or another sign-in method.

### Downloads, permissions and the rest

- Downloads use `WKDownload`, listed in a popover from the rail with retry and reveal in Finder. pob asks before every download.
- Camera, mic and location prompts appear as glass prompts, remembered per site per profile.
- Screen sharing relies on WebKit's built-in prompt, which it uses when the private capture delegate isn't implemented. There's no public screen capture permission API in `WKUIDelegate`.
- File uploads, JavaScript dialogs, printing, find in page, per-site zoom and default browser support use their standard public APIs.
- **Open in Safari** is a command in the switcher.

## 8. Data

```text
~/Library/Application Support/pob/
  settings.json          transparency, blur, search engine, list of profiles
  favicons/
  profiles/<id>/
    bookmarks.json
    session.json         windows, tabs, interaction state
    history.sqlite       FTS5 search
    sites.json           zoom, ad blocker off, permissions, certificate exceptions
```

WebKit manages cookies, logins and site data per profile, plus compiled ad rules. JSON files are written atomically, so a crash can't leave a half-written file.

## 9. When things go wrong

| What fails | What pob does |
|---|---|
| A page's web process crashes | Reloads the tab once, then shows a simple crash notice with Reload |
| A page won't load | Shows a minimal error page with Retry |
| A site's certificate is invalid | Blocks the page. You can allow that one host, for local dev |
| pob crashes or is force quit | Reopens your tabs on next launch |
| A macOS update removes a private API | Blur falls back to the fixed public blur. Web Inspector opens through Safari's Develop menu |
| Filter lists can't update | Keeps the last good rules |
| A filter list won't compile | Skips that list and keeps the others |
| macOS denies camera, mic or screen | Explains it and offers a button to the right System Settings page |
| Screen sharing fails in a call | Open in Safari from the switcher |
| A history write fails | Logs it and keeps browsing. History never blocks navigation |

## 10. Testing

### Automated, with Swift Testing

- Input classification: URL, search or match.
- Tab lifecycle transitions.
- Session save and restore.
- History search.
- Bookmark import.
- Punycode display of internationalized hosts in the pill.
- Filter rules compile and block a known request.
- A private API availability test that fails right after a macOS update breaks one.

### On the real app

- Teams and Meet screen sharing, Google sign-in, and H.264 and AAC video.
- Switching tabs during a Teams or Meet call, with the call and screen share continuing.
- Glass and transparency over a busy wallpaper. Judge these only from `screencapture -x`, because web capture tools can't see through a window. It captures the main display only and needs an unlocked screen.
- Reduce Transparency, Increase Contrast and Reduce Motion.
- Rail trigger timing, including near a second display.

### Speed targets

These are proposed targets, measured with signposts and Instruments:

| Action | Target |
|---|---|
| ⌘T to typing | Under 50 ms |
| Tab switch | Under 50 ms |
| Cold launch to first paint of a locally cached page | Under 500 ms |

## 11. Build stages

Each stage gets its own implementation plan.

### Stage 1: Prove it

Build one real window with a single web view, transparency, blur, the slider popover and a glass rail, kept as the app's base. Then run these checks:

| Check | Pass means | If it fails |
|---|---|---|
| Transparency, blur and glass together | Matches the approved mockup, with no artifacts | Fall back to the fixed public blur, then reassess with the user |
| Screen sharing in Teams | Remote viewers see the shared screen or window | Try the private capture delegate. If that fails, Open in Safari covers calls and the user decides whether that's acceptable |
| Screen sharing in Meet | Same | Same |
| Google sign-in | Sign-in completes with the Safari user agent | Investigate before Stage 2, because the user needs it daily |
| H.264 and AAC video | MP4 plays with sound | Investigate, because this is an expected pass |
| Apple Passwords through native AutoFill | macOS offers saved logins in native fields | Stay on the menu bar and ask the user about the import |
| Docked Web Inspector | Opens in the window with Console and Network working | Use Safari's Develop menu |

If WebKit fails screen sharing and Open in Safari isn't acceptable, the engine decision goes back to the user before Stage 2.

### Stage 2: Daily driver

Tabs, the full rail, switcher, domain pill, history, bookmarks, session restore, downloads, find, printing, permissions, ad blocking, Web Inspector shortcuts and default browser support. This stage uses the single starting profile.

Done when the user can switch to pob for a full work day, including a call with screen sharing while switching tabs.

### Stage 3: Finish

Profiles, private windows, bookmark import, Settings, the per-site ad blocker switch, a Load anyway button for pages the ad blocker stops, and a speed pass against the targets.

Done when every requirement in section 2 is met or has an agreed fallback.

## 12. Out of scope for this version

- Site notifications. WebKit has no public API, and the known JavaScript workaround is unreliable. Teams and Gmail alerts won't appear.
- Sync with iPhone.
- Chrome or Safari extensions.
- iCloud passkeys, until Apple approves the entitlement.
- Reader mode, translation, AI features, tab groups and a plugin system.
- Distribution to other people, including notarization and auto-updates.

## 13. Known risks

- **Screen sharing is unconfirmed in a `WKWebView` app.** Microsoft and Google document it for Safari. WebKit's source shows screen capture on by default on the Mac, with its own prompt, but there's no public API for it. This is the biggest risk, and Stage 1 tests it first.
- **Apple Passwords has no direct route into pob.** Stage 1 tests the one public path. It may fail, and sign-in would then stay manual.
- **Private APIs can change in macOS updates.** They're limited to one file, with public fallbacks and an availability test.
- **Glass over a translucent page is untested.** Earlier work on macOS 26 found `NSGlassEffectView` in a borderless, clear panel ignored its corner radius and didn't pin its content view. pob keeps a titled window partly for this reason.
- **Licensing:** SafariConverterLib is GPL-3.0. That's fine for personal use, but distributing pob would require GPL compliance or replacing it.

## 14. References

- Mockups and diagrams: `.superpowers/brainstorm/` in this project.
- Axiom skills in `~/.claude/plugins/cache/axiom-marketplace/axiom/`: `axiom-design`, `axiom-macos`, `axiom-performance`, `axiom-data`, `axiom-concurrency`.
- Liquid-glass plugin in `~/.claude/plugins/cache/anthropic-plugin-directory/liquid-glass/`. It covers SwiftUI, so AppKit surfaces use it for design rules.
- Both plugins are enabled only for `picky-ios`. Enable them for `pob` before building so they load automatically.
- [Nook](https://github.com/nook-browser/Nook) and [DuckDuckGo's Mac browser](https://github.com/duckduckgo/apple-browsers) are open-source `WKWebView` browsers worth reading. Nook is GPL-3.0 and DuckDuckGo's is Apache-2.0.
