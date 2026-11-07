# Stage 2 results

Run by the user on 2026-11-06 on macOS 27.0.1, with an Apple M5 Pro, on branch `stage-2-daily-driver`.

| Check | Result | Evidence |
|---|---|---|
| Tabs | Pass | The user reported everything looking and working as expected |
| Windows | Pass | Same report |
| Switcher | Pass | Same report |
| Domain pill | Pass | Same report |
| Sign-in | Pass | Same report |
| Session | Pass | Same report. Closing the last window empties the session by design, and ⌘Q restores it |
| Downloads | Pass | Same report. The prompt before each download came after this check, so it hasn't been tried by hand |
| Find, print, zoom | Pass | Same report |
| Permissions | Pass | Same report |
| Ad blocking | Pass | No ads appeared on speedtest.net, which normally has many |
| Default browser | Pass, optional | Same report, but this item was optional, so it may not have been tried |
| Failures | Pass | Same report |
| Speed | Pass | Same report. Not measured against the spec's targets, which is Stage 3's speed pass |
| Work day | Not done | The user hasn't spent a full work day in pob yet |
| Screen sharing | Not tested | The user will run Teams or Meet on demand |

Stage 2 is done when the last two rows pass.

## Automated checks

- 585 tests in 37 suites pass, with no Swift warnings, also with the screen locked.
- The Liquid Glass audit found no glass on content, no glass on glass and no clear glass.
- Real binary runs on a scratch home passed: a fresh launch, a restored HTTPS tab, garbage and hostile `session.json` files, force quits, and rules compiling on first launch and being reused on relaunch.
- EasyList converts 78,146 lines to 59,774 rules, and EasyPrivacy 56,458 lines to 56,480 rules. Both are well under WebKit's limit of 150,000.

## Found during the build

- **HTTPS crash:** one commit crashed on every HTTPS page while all 344 tests passed, because no test loaded HTTPS. A windowless trust test now covers it, and later tasks had to prove their main path with real WebKit.
- **Plain `http://` sites:** App Transport Security had blocked them on real hostnames since Stage 1, and every test site had been HTTPS. `NSAllowsArbitraryLoadsInWebContent` fixes it.
- **Certificate prompt:** an image from another site could ask the user to trust that site's bad certificate permanently. Only the page's own host can ask now.
- **Session loss:** a NaN window frame or a held ⌘W could wipe the session. Both are fixed, and any JSON file pob can't read is now kept as `<name>.unreadable`.

## Decisions

- **Ad block conversion:** the user chose AdGuard's SafariConverterLib 4.3.1 and clicked Trust & Enable for its build plugin. It's GPL-3.0, which only matters if pob is ever distributed.
- **Last tab:** ⌘W keeps the window with the switcher open, so ⇧⌘T can bring the tab back. A second ⌘W closes the window. This reverses the plan.
- **Switcher:** Return on a typed word searches. ↓ then Return runs a matching command. This reverses the plan's row order.
- **App links:** `msteams:`, `zoommtg:`, `mailto:` and similar links ask before opening the app. This goes beyond the spec's Stage 2 list, for the work day goal.
- **Site permissions:** answers are remembered for the page's own host, not an embedded frame's.
- **Downloads:** the user chose to be asked before every download, because hidden frames and page scripts could start one with no click.
- **Blocked pages:** a link to a host on a filter list shows the error page, and Retry is blocked again. The user wants a Load anyway button in Stage 3.

## Not individually confirmed

The user's report covered the main checks. These smaller ones came from the task reports, and nobody has confirmed them one by one.

### First launch on the real profile

- A fresh start shows the blurred desktop with the switcher open and the field ready. The first Return opens quickly.
- The first download raises macOS's Downloads folder prompt, and allowing it lets the file land.

### Look, in light and dark

- Rail: tab rows, pinned bookmark icons (7 across), hover close button, footer with downloads and settings.
- Switcher: position and size, 22% dim, row spacing, section headers, long URL truncation, selected row fill and corners.
- Domain pill and loading line. Find bar position. Downloads popover, including an empty one saying "No downloads yet", and a long list scrolling.
- Error page, certificate sheet, password sheet, permission sheets, the "Open in…" sheet.

### Keyboard and pointer, by hand

- Rail: drag a tab row while the pointer leaves the rail, and the rail stays open until the drag ends.
- Switcher: click the dim, including its top 32 pt, and it closes without touching the page. Double-click a row and the dim, and the second click does no harm. Scrolling over the dim doesn't move the page. Page hover effects under the dim don't look wrong.
- Switcher: typing fast, the panel's bottom edge holds still.
- Switcher: type `teh ` and `--`, and they stay as typed. Same in the address field.
- Switcher: ⌘T then Return closes it and changes nothing. ⌘T then ⌘W leaves the page alone.
- Switcher: with the rail pinned, it clears the rail at any window width. At the 480 pt minimum width the panel is about 125 pt wide, so judge whether it needs a floor.
- Switcher: a word matching a command now searches on Return (Ruling 42), and ↓ then Return runs the command. Decide if that's right.
- Rail suggestions fill the space the tab list had, and the list comes back when editing ends.
- Hold ⌘W: one tab closes. Hold ⌘N: one window opens. ⌘N steps away from the window behind.
- Last tab: ⌘W leaves the window with the switcher open, ⇧⌘T brings the tab back, a second ⌘W closes the window.
- Fullscreen video: do ⌘T and ⌘W work? By reading they probably don't, because WebKit's fullscreen window is key. Esc still exits.
- Find: ⇧Return goes backwards. Find highlights stay after closing, which WebKit gives no public way to clear.
- Pill: hover holds it, a click shows Copied for about a second.
- With a page's `alert` sheet or the sign-in popover up, ⌘T and ⌘N do nothing and the sheet keeps its keys.
- ⌘` cycles pob windows. Minimize every window, then click the Dock icon: one comes back, with no extra window. With every window minimized, ⌘N and ⌘T open one.
- Quit with a window on an external monitor, unplug it, relaunch.
- VoiceOver reads tab rows and marks the active one as selected.

### Real sites and permissions

- Certificates: Go Back, Allow This Site on `expired.badssl.com`, then Back after Allow. A page embedding an image from a bad-certificate site raises nothing.
- ⌘-click a link to a bad-certificate or password site, then switch to the tab: the question appears then.
- Camera and mic: with a remembered Deny on a site, no prompt appears. A macOS-level denial explains itself and offers System Settings.
- Location: prompt text names the site.
- Reset Permissions for This Site makes the site ask again.
- App links: a Teams or Zoom link asks, Open launches the app, Cancel stays put. On a page that keeps asking, Cancel then ⌘W closes the tab in the 3 second pause.
- Make Default Browser: cancelling macOS's confirmation doesn't show a false error (only try this if you want pob as default).
- A link from another app opens as a new active tab, also when pob isn't running. A saved local file comes back after a relaunch.
- Memory pressure, if you want it: `sudo memory_pressure -S -l warn` with a running build shouldn't crash pob.

### Downloads prompt, added after the main checks

- The sheet names the file and site, Download keeps going, and Cancel leaves nothing behind.
- After answering Download, the pill shows the filename. This is untested on a real sheet, because the Mac was locked.
- ⌘-click a download link: the sheet appears on the front window.
- Start a download in fullscreen video, then leave fullscreen: nothing hangs, and that page's next download still asks.

## Rulings made during the build

Every decision taken on the user's behalf, in order: what, why, and what it costs if wrong.

- Ruling 1: Task 3 adds a test that a fresh web view reports `PrivateAPI.isCapturingDisplay == false` and `Tab.isCapturing == false`, and `missingSelectors` pins `_displayCaptureState` — Review Focus 1 promises a test and real capture can't be simulated — costs one small test if wrong.
- Ruling 2: a capturing tab gets `inactiveSchedulingPolicy = .none`, not `.throttle` — the spec says a call tab never steps down — costs one line if wrong.
- Ruling 3: Task 9 guards `applicationWillTerminate` and every other AppController session write with `isRunningTests` — otherwise running tests blanks the user's real `session.json` — no cost.
- Ruling 4: `restoring` defaults to nil — earlier tasks' tests call the two-argument form — no cost.
- Ruling 5: Task 10 keeps error pages out of history and favicons, even though Task 10's file list omits `TabManager` — a typo shouldn't become a switcher suggestion — costs one flag on `Tab` if wrong.
- Ruling 6: Task 3 adds its `decidePolicyFor navigationAction` selector and Task 12 adds `webView:didCommitNavigation:` to `TabDelegateTests` — the global delegate rule requires it, and saved zoom relies on didCommit — no cost.
- Ruling 7: with no active tab, submitting the address field or clicking a bookmark opens a new tab — Task 7 makes an empty window possible — no cost.
- Ruling 8: the Trust & Enable step moves earlier, into a scratch project with the same package, so the user can do it now and Tasks 1-13 never wait on it. `pob`'s `project.yml` changes only in Task 14 as planned — the trust is recorded per plugin, not per project — if wrong, the user clicks it once more at Task 14.
- Ruling 9: order at the end is Tasks 1-15, then the final whole-branch review and its fixes, then Task 16 with the user, so the user tests the reviewed code — the plan puts Task 16 last but doesn't place the final review — costs nothing if wrong.
- Ruling 10: closing a popup through window.close() returns to its opener, not the right-hand neighbor — a finished sign-in landing on an unrelated tab reads as a bug — goes into Task 3's fix round — costs one stored opener id if wrong.
- Ruling 11: Task 4's recordsFollowTheirTabs may wait with eventually — the implementer measured webView.title arriving about 0.3 s after didFinish in a windowless web view — assertion stays the same — no cost.
- Ruling 12: Task 5 must also update a history entry's title when the title arrives after didFinish, without counting another visit — otherwise history stores empty titles and title search fails — adds one HistoryStore method — small cost.
- Ruling 13: element fullscreen check goes on the Task 16 list: by reading, WebKit's fullscreen window is key, so isBrowserWindowKey would turn off reserved and menu commands during fullscreen video — not run yet; Esc still exits — if confirmed and annoying, widen the guard then.
- Ruling 14: a capturing tab behind the active page keeps showing its dialogs as sheets — hiding them could swallow something a live call needs, and the only way there is an active call the user started — stays in the deferred minors, costs a sheet with no site name on rare occasions.
- Ruling 15: carried to Task 13: a no-window denial must not be remembered as the user's answer.
- Task 4: Ruling: New Tab row calls perform(.openSwitcher) rather than TabManager directly — the spec's new-tab flow is the switcher, and after Task 7 the row and ⌘T match with nothing created until Return — plan's "routes to TabManager" was loose — costs one line if the user wants an instant blank tab.
- Ruling 16: with an empty switcher field and no row arrowed to, Return closes the switcher and changes nothing — "first row is what Return chooses" is for matches, and ⌘T Return shouldn't jump tabs — goes into Task 7's next fix message — costs one if if wrong.
- Ruling 17: Task 7: while the rail shows, the switcher centers over the page area with 56% of that area's width — the brief's 56%-of-window overlapped a pinned rail in any window under 1127 pt, against the no-glass-on-glass rule — small layout change, cheap to reverse.
- Ruling 18: Task 7: re-graded "history rows vanish on every keystroke" to Important and fixed by keeping still-matching rows until the new answer lands — the panel edge pumping on each key is visible on every use — not yet seen on a real screen, so if wrong it's a few wasted lines.
- Ruling 19: Task 7: spell correction, text replacement, smart quotes and dashes off in the switcher and address fields — these take URLs and searches — no cost.
- Ruling 20: Task 7: a word matching a command keeps running that command on Return, as the brief's row order mandates — commands in the switcher exist to be run by typing — if wrong, the user flips the order at Task 16, one line in the model.
- Ruling 21: subagent commits may carry their own model's Co-Authored-By trailer (Task 8 uses Sonnet 5.5) — it comes from the harness reminder those agents get and is the honest attribution — left as is, no cost.
- Ruling 22: saveSoon waits from the first change, not the last — a strict debounce can be held off forever by a ticking title, which is itself a loss path — costs a session rewrite at up to 2 Hz while a title ticks.
- Ruling 23: WindowController.onNewWindow accepted, not in the brief — the switcher's New Window row has no other route to AppController — no cost.
- Ruling 24: SessionStore.save drops an empty snapshot until it has seen tabs — single write point for the "never replace a good session" rule — no cost.
- Ruling 25: an unreadable session.json is logged and copied to session.json.unreadable before anything can overwrite it, overriding the plan's silent overwrite — a typo or a later required field shouldn't cost a whole session — one extra file if wrong.
- Ruling 26: re-graded held ⌘W to Important and made close commands ignore key repeats — key repeat closing everything in a second is data loss, unlike Safari only in that nothing survives the window — if wrong, holding ⌘W closes one tab per press only, which is the safer failure.
- Ruling 27: new windows cascade from the key window — a ⌘N window exactly over the old one looks like nothing happened — one line.
- Ruling 28: Profile.dataStore becomes lazy — a normal TEST was building the real WKWebsiteDataStore through Profile.initial, against Task 1's intent — no cost.
- Ruling 29: .newWindow ignores key repeats too — same class as held ⌘W — no cost.
- Ruling 30: the unreadable-file copy moves into JSONFile, covering bookmarks, sites and settings — a corrupt bookmarks.json then ⌘D would overwrite every bookmark — one extra file when something is corrupt.
- Ruling 31: SecTrustEvaluateAsyncWithError runs with .main, called from main — the API requires the call to come from the given queue, evaluation still happens off the main thread (returned in 0 ms, callback 3 ms later), and a true background hop adds Sendable warnings — replaces my earlier "background queue" instruction — no cost.
- Ruling 32: add NSAllowsArbitraryLoadsInWebContent to Info.plist — without it App Transport Security blocks every plain-http site on a real hostname, which a browser must load — was missed in Stage 1 because every test site was https — no cost.
- Ruling 33: keep interactionState for failed tabs (removes the branch I asked for conditionally) — measured: WebKit restores the error page's state to the real page with the back list intact — no cost.
- Ruling 34: a challenge refused only because the tab has no window retries when the tab next becomes active — otherwise a ⌘-clicked bad-certificate tab stays blank and "allow that one host" can't be reached — a few lines.
- Ruling 35: Task 11: re-graded target=_blank attachments leaving a blank tab, and the unscrollable popover, to Important — a person meets both in ordinary use — plus small fixes (indeterminate bar, NSDownloadsFolderUsageDescription, bidi scalars, KVO test, test log noise) — a few lines each.
- Ruling 36: Task 13 keys remembered permissions on the top-level page's host, not the requesting frame's — makes Reset Permissions for This Site work, and stops a grant given at b.com being reused when evil.com embeds b.com — costs one prompt per embedding site.
- Ruling 37: Task 15 runs before Task 14 while the plugin trust is pending — the plan says no other task depends on Task 14 — no cost.
- Ruling 38: the final whole-branch review runs now, on Tasks 1-13 and 15, while Task 14 waits for the user's plugin trust; Task 14 then gets its own task review plus a scoped pass over how it touches the rest — keeps work moving through the only blocker — costs a second, smaller review.
- Final: Ruling 39: fix the subresource certificate prompt — Critical, a page could get a certificate for another host trusted permanently — one guard.
- Final: Ruling 40: closing the last tab keeps the window with the switcher open, and the next ⌘W closes the empty window; ⇧⌘T brings the tab back — reverses the plan's "closing the last tab closes the window", because that lost the tab for good — costs one extra ⌘W to close a window, one line to reverse.
- Final: Ruling 41: links to other apps (msteams:, zoommtg:, mailto:) open after a confirm sheet naming the app — outside the spec's Stage 2 list, but its "done" is a work day with Teams and Meet — no remembered answers, one prompt at a time, nothing from a background tab — cheap to remove if the user doesn't want it.
- Final: Ruling 42: the search row goes above commands, reversing Ruling 20 — typing "close" or "bookmark" then Return shouldn't act on the page; a wrong search is harmless and a wrong command isn't — costs one Down press to run a command by typing, one line to flip back.
- Final: Ruling 43: rail rebuild guards land now, taken from Task 4 and Task 6's deferred minors — a ticking background tab would drop clicks and snap the list — no cost.
- Final: Ruling 44: row accessibility labels land now, promoted from Task 4's minor — accessibility isn't cut, and it's a couple of lines — no cost.
- Final: Ruling: JS dialogs carry no site name — Stage 1 code, a host label is worth adding in Stage 3 — a phishing-shaped gap stays until then.
- Final: Ruling: NTLM and Negotiate get default handling — the spec names Basic only — corporate sign-in pages using them fail; Open in Safari is the fallback.
- Final: Ruling: loadFileURL grants read access to the parent folder — standard practice, needed for relative images — a local HTML file can reach its siblings.
- Final: Ruling: favicon fetches let a page make pob GET any http(s) URL without cookies — no capability the page lacks — none.
- Final: Ruling: hidden iframes can start downloads with no click — quarantined, spec silent — offered to the user as a decision in the final message.
- Final: Ruling: IncomingLink accepts file — required for the HTML document type — none.
- Final: Ruling: applicationWillTerminate isn't reached on SIGTERM — the 500 ms save covered it in every run — up to half a second of changes.
- Final: Ruling 45: after Cancel on the external-link sheet, that tab's requests are dropped for 3 seconds — reserved keys don't reach the window under a sheet, so a loop could trap the user — a real click after 3 s still prompts.
- Final: Ruling 46: a capturing background tab can still show the external-link sheet, against the letter of Ruling 41 — it takes a live call the user started, and the sheet names the host — rare.
- Ruling 47: Task 14's departures accepted — each is better than the brief, as the reviewer measured — no cost.
- Ruling 48: an unasked failure keeps its row and notice, and its Retry asks — a dead-server click must not fail silently, and a page spamming rows gets no file — costs a few stray rows from a hostile page.
- Ruling 49: Download stays the default button, as briefed — the user moves fast and the sheet exists to show the file and host — Return while typing could accept a page-raised sheet, for a quarantined file.

## Deferred minor findings

Found in review and left for later. The whole-branch review triaged them, and none blocks daily use.

- Task 1: TestSupport.eventually has no callers until Task 5 (brief mandates it)
- Task 1: finishLoading hangs if start() never triggers a load (same as the old helpers)
- Task 1: SiteSettings setter rewrites the whole file on each set
- Task 1: Profile.temporary() folders are never cleaned up
- Task 2: TabList.init doesn't validate a non-nil activeID (Task 9 derives it from the index, so it's always valid today)
- Task 2: no tests for guard branches (close on unknown id, reopenLast on empty, out-of-range move, update)
- Task 3: release edits the list outside changeList, so saving a tab fires no onChange; comment overstates it
- Task 3: webView.title is "" before arrival, so a rebuilt tab closed quickly loses its stored title
- Task 3: with a popover or detached inspector key, menu commands silently do nothing, ⌘W no longer closes a detached inspector; isBrowserWindowKey has no test
- Task 3: capture changes noticed only on the 60 s tick; a tab that starts capturing while detached stays detached
- Task 3: a capturing page behind the active tab can show its dialog as a sheet over the wrong tab
- Task 3: real openPopover?.close() has no committed test (a hosted window is never shown); verified once on a real window
- Task 3: a dialog regression shows as a test-host exit, not a clean expect failure
- Task 4: update reloads and scrolls to the active row on every change, so a title change snaps a scrolled list back, and a reload mid-drag invalidates the stored row index
- Task 4: configure resets close button alpha, so a hovered row loses it after a title update
- Task 4: old title stays while a new page loads
- Task 4: quaternaryLabelColor.cgColor resolved once, doesn't follow an appearance change (address row too)
- Task 4: no tests for close, move or new-tab routing; drop math untested
- Task 4: rows expose no accessibility role or label for selection
- Task 4: acceptDrop trusts the pasteboard row index without its own source check (validateDrop guards it today)
- Task 5: at didFinish a new page can briefly take the previous page's title, and it doesn't heal if the new page's title is empty
- Task 5: updateTitle and record run in separate unstructured Tasks, order not guaranteed
- Task 5: url TEXT PRIMARY KEY with rowid-keyed FTS, a future VACUUM could renumber rowids (brief mandates the keying)
- Task 5: tests leave sqlite files in temp; no last_visit index
- Task 6: PinnedBookmarksView rebuilds every button on each rail update, which can drop a click or open context menu
- Task 6: each finished load re-runs the icon query and re-fetches, even when cached; missing /favicon.ico re-requested per page
- Task 6: AsyncBytes reads one byte at a time, and decode and scaling run on the main actor
- Task 6: aFileIconIsNeverRead can pass for the wrong reason; the iconURL unit test is the real guard
- Task 6: no test for ⌘D doing nothing with no page or on about:
- Task 7: a double-click can reach the page, because the first click removes the overlay (Task 16 check)
- Task 7: shouldSelectRow has no direct test
- Task 7: SwitcherModel reaches into TabListView.displayTitle; it belongs on TabRecord
- Task 7: WindowController calls commands.command(id)?.perform(), which only loops back to perform(id)
- Task 7: SwitcherView repeats about 15 lines of table setup from TabListView
- Task 7: test trims (HeldHistory helper, merging two tests, three 50 ms sleeps)
- Task 7: LiteralTextFieldCell turns substitutions off on the shared field editor and nothing turns them back on (fine while every field is literal)
- Task 7: a hovering rail can overlap the panel for its 170 ms slide-out; panel is about 125 pt wide at the 480 pt minimum with the rail showing (Task 16 check)
- Task 8: pill still takes clicks during its 0.2 s fade (harmless, shows Copied)
- Task 8: no tests for tab switch updating the line at once, hover hold, or Reduce Motion
- Task 8: mouseExited during the Copied second reschedules 2 s, so Copied can stay up to 2 s after the pointer leaves
- Task 8: the animated hide's hover reset has no test
- Task 8: a pill re-shown under a resting pointer has no hover hold until the pointer moves out and back (unverified on device)
- Task 9: !isShowingAWindow has no test
- Task 9: every launch counts as a visit, because didFinish on a restored active tab raises visit_count
- Task 9: SessionStoreTests is 512 lines; SessionWindowsTests belongs in AppControllerTests
- Task 9: hasFiniteFrame is vacuously true for an empty or short descriptor (empty measured safe; short unconfirmed)
- Task 9: a failed .unreadable copy only blocks session saves; bookmarks, sites and settings log and still overwrite
- Task 9: load() writes a copy, so it mustn't be polled
- Task 9: readingTheInitialProfileBuildsNoDataStore reads lazy storage through Mirror
- Task 10: the record keeps "Can't open localhost" as a failed tab's title
- Task 10: CrashRecovery doesn't belong in SignInChallenge.swift, and the alert code grows Tab.swift instead of following Permissions.ask
- Task 10: the sign-in sheet doesn't warn when a password goes unencrypted over http (receivesCredentialSecurely is available)
- Task 10: the host-match clause in askForPassword's retry has no test of its own
- Task 11: HTTP errors count as success, so a retry answered with 403 finishes with the error page as the file
- Task 11: claims outlive files; requests[id] stays for finished rows
- Task 11: a file:// folder URL fires a notice and adds a failed row
- Task 11: tests: weak Running.download undetected; row test counts rows only; no test for rail.onDownloads or showNotice
- Task 11: a Retry that fails before any response appends its row at the end, not its old position
- Task 11: a background tab from a link click (no opener) that turns into an attachment may still leave a blank tab
- Task 11: no test for the dangling-symlink branch of discardPartialFile
- Task 12: a find finishing after the user types can set Not found on stale text
- Task 12: printOperationIsBuiltToThePageSize may pass without the frame line
- Task 12: find highlights stay when the bar closes, because WebKit has no public way to clear them
- Task 12: empty field plus Return doesn't clear an earlier Not found
- Task 13: Permissions.ask, promptText(host:type:) and deviceName are dead production code used only by a test
- Task 13: the two delegate wrapper bodies have no test (WKSecurityOrigin can't be built)
- Task 13: decide's doc comment says an embedded frame can't reuse a grant, but a third-party iframe on a granted page does
- Task 13: locationServicesEnabled runs on the main thread on the prompt path
- Task 15: two open overloads differ only in [URL] and [AddressInput]
- Task 15: aSavedLocalFileComesBack can't distinguish a read-access bug in a new process
- Task 15: theSwitcherRowRunsIt indexes windows[0] without waiting
- Final: every launch counts as a visit; Task 2's audio tab saved under memory pressure; .unreadable copy has no timestamp; ⌘-clicked attachment leaves a blank background tab; ChallengeSheets and Suggestions extractions for Stage 3; media-playback check at the phase tick for Stage 3.
- Final: every rail update probes FaviconStore on disk for icon-less hosts (a negative cache is one line if the Stage 3 speed pass shows it)
- Task 14: a listed host as a page is a dead end; Retry re-blocks and only the switcher command gets through (Stage 3: "Load anyway")
- Task 14: compileContentRuleList holds the main thread 33-51 ms per list on first launch and weekly refresh; can't move
- Task 14: the package prints unconvertible rules to stderr
- Task 14: hostedTestsNeverBuildTheRealProfilesBlocker compares Mirror output; the main-actor stall test could flake on a loaded machine; ContentBlockerTests is 767 lines
- Task 17: finish guard for a failure while a sheet is up has no test; webView.window first choice has no test; frontWindow closure can't be tested; pill fade completion no longer reached by tests; cancelledAt never pruned and keyed by address; offscreenWindow opens a window in hosted tests (justified)
