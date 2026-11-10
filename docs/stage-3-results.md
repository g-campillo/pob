# Stage 3 results

Built on 2026-11-09 on macOS 27.0.1, with an Apple M5 Pro, on branch `stage-3-finish`. The user merged it into `main` the same day, before running the hands-on checks, and will fix what turns up in later sessions.

| Check | Result | Evidence |
|---|---|---|
| Upgrade from Stage 2 | Not run by hand | A real binary on a scratch home restored a Stage 2 session, removed the old rules folder and compiled the shared rules |
| Profiles | Not run by hand | Tests only |
| Private windows | Not run by hand | Tests, including a real page load that leaves nothing in history or favicons |
| Settings | Not run by hand | Tests only. Nobody has seen the layout |
| Deleting a profile | Not run by hand | The real data store removal has only run in a probe outside the app |
| Load anyway and the site switch | Not run by hand | Tests with real WebKit |
| Bookmark import | Not run by hand | Tests with files in Chrome's and Safari's format, not real exports |
| Dialogs name their site | Not run by hand | Tests |
| Speed | Pass | Measured, see Speed below |
| Screen sharing | Not tested | Open since Stage 1 |
| Work day | Not done | Open since Stage 2 |

Stage 3 is done when every row passes or has a fallback the user agrees to.

## Automated checks

- 697 tests in 43 suites pass, with no Swift warnings.
- Each task had its own review, and a final review covered the whole branch. It found nothing critical and three important problems, which were fixed and reviewed again.
- A real binary run on a scratch home passed: a Stage 2 `session.json` came back in one window, `profiles/<id>/rules` was removed, and EasyList and EasyPrivacy compiled into `pob/rules`.

## Found during the build

- **Private site settings on disk:** zoom, permission answers and the ad block switch in a private window were written to a temp file that outlived quitting. A private window now keeps them in memory only.
- **Private sessions in memory:** a closed private session, with its cookies, stayed in memory until quit. Closing its last window now releases it.
- **Load anyway from another window:** a probe showed a page could set a popup's address to pob's Load anyway link and get an ad host loaded with every rule off. Only a click on the blocked page itself counts now.
- **Bookmark files that hang:** the first parser took 51 seconds on 560 KB of junk. It's now one forward pass, off the main thread, and the same kind of input takes about 0.01 seconds.
- **Deleting a profile:** WebKit refuses to remove a data store that anything still holds, so every delete of a profile used in the session would have failed. The profile now lets go of its store first, and the removal retries for about 2 seconds.
- **Two deletes at once:** both could pass the "keep at least one profile" check and empty the last profile. A delete in progress now counts as done.
- **Tests and real data:** a test that forgot its stub could have removed the real Main profile's cookies and logins, because tests run inside pob. The real removal now refuses to run in a test.
- **Shortcuts from Settings:** ⌘T pressed with Settings in front opened the switcher in the window behind, and typing still went to Settings. The browser window now comes forward first.
- **History after a restore:** a restored tab that never finished loading made the next page opened in it miss history.
- **Parked tabs:** after switching a window to another profile and closing it, a new window in the first profile came up empty. A profile's first window now brings its parked tabs back.
- **Entering a profile being deleted:** a new window could open in it during the wait. New windows and profile switches now avoid it.
- **Clear History:** cleared entries stayed readable in the file. Clearing now rebuilds the search index and compacts the file, and a test reads the raw bytes.

## Decisions

- The plan's decisions, which the user approved with the plan, are listed at the top of `docs/superpowers/plans/2026-11-09-pob-stage-3-finish.md`. The main ones: the starting profile is called Main, a profile switch happens in place and parks the window's tabs, Load anyway works once and isn't remembered, and the search engines are Google, DuckDuckGo and Bing.
- **Styling:** the tweaks the user mentioned after Stage 1 were never listed, so the user left them out of this stage.
- **Merge before the checks:** the user's choice on 2026-11-09.

## Going back to the Stage 2 build

A Stage 2 build still starts on this data. It ignores `profiles.json` and recompiles its own rules. When it saves `session.json` it drops any tabs parked by a profile switch, so don't alternate between the two builds while tabs are parked.

## Not confirmed by hand

Nobody has run these. Back up `~/Library/Application Support/pob` before the first launch on the real profile.

### Upgrade

- Every Stage 2 tab, bookmark and history entry is there, with the same transparency and blur, in a profile called Main.

### Profiles

- ⌘, then New Profile, and type a name. Return saves it, and so does moving to another field or closing Settings. Clicking a button doesn't.
- Switch to it from the rail's profile button and sign in somewhere. Switch back: Main's tabs return, and the sign-in doesn't carry over.
- ⌘N stays in the same profile.
- Switch a window, close it, press ⌘N: the parked tabs come back.
- Quit and relaunch: both profiles' windows come back.
- With the rail shown by hovering, it stays open while the profile menu is up.
- A window in a call asks before switching, and Cancel changes nothing.

### Private windows

- ⇧⌘N opens a window whose rail says Private. A site signed in to elsewhere isn't signed in there.
- After closing it, the switcher in a normal window suggests nothing visited privately.

### Settings

- The layout in light and dark, with a profile selected.
- Choosing DuckDuckGo changes where ⌘T searches go.
- ⌘T pressed with Settings in front brings the browser window forward, and typing lands in the switcher.
- Clear History empties the history rows for that profile only.
- Turn On puts ad blocking back for a site that had it off.
- Delete a profile that had a window open earlier in the session. This is the one that has never run for real.

### Blocking

- `https://pagead2.googlesyndication.com/` shows "pob blocked …" with Load anyway, and the link loads it. If it redirects to another listed host, a second blocked page appears.
- The rail popover shows "Block ads on …" on a normal site, and unticking it reloads the page with ads.

### Import and dialogs

- Import a real export from Safari (File > Export > Bookmarks) and from Chrome (Bookmark manager > Export). The switcher then finds them by title.
- A page's `alert()` names its site.

### Still open from earlier stages

- A Teams or Meet call sharing the screen while switching tabs, with camera and mic on and then off. If it fails, the spec's fallback is Open in Safari from the switcher.
- A full work day in pob.

## Speed

Measured on 2026-11-09 on macOS 27.0.1, with an Apple M5 Pro, from the Debug build in `build/s3`. A Release build wasn't measured. Launch was measured warm, not after a reboot. A page served from the HTTP cache and a session with many tabs weren't measured either.

| Target | Spec | Median | Slowest | Result |
|---|---|---|---|---|
| ⌘T to typing | Under 50 ms | 5.2 ms | 7.5 ms | Pass |
| Tab switch, live tab | Under 50 ms | 1.5 ms | 2.1 ms | Pass |
| Tab switch, saved tab | Under 50 ms | 18.8 ms | 19.9 ms | Pass |
| Launch to first page | Under 500 ms | 298 ms | 309 ms | Pass |

Every target was met on the first measurement, so nothing was changed for speed and there are no before and after numbers. The Stage 2 candidates, the favicon lookups on disk for hosts with no icon and the pinned bookmarks view, were left as they are.

### How each was measured

- **⌘T and tab switching:** `SpeedTests`, which run only with `TEST_RUNNER_POB_SPEED=1`. Each test does 3 warm-ups and 30 timed runs in a window that isn't on screen, over pages served from a loopback server.
  - ⌘T times `perform(.openSwitcher)` and the window's layout, with 5 tabs open. After each run the test checks that the switcher's field has the keyboard, then closes the switcher.
  - A tab switch is timed until `TabManager.activate` returns. That is after `showActiveTab` and the rail update that follows it.
  - The saved tab is put back into the saved state before each run, rebuilt with a new web view when it's activated, and timed to the window showing it, not to the end of its load.
  - A second run gave medians of 5.3, 1.7 and 18.3 ms.
  - The window isn't on screen, so these numbers don't include drawing the frame. pob also marks both actions as signpost intervals (subsystem `pob`, category `Speed`, named "Switcher" and "Tab switch"), so Instruments can time them in the real app. The "Switcher" interval ends one main-queue turn later. In the test run, it had a median of 10.1 ms and a slowest of 17.7 ms.
- **Launch:** five runs of `pob.app/Contents/MacOS/pob` with `CFFIXED_USER_HOME` set to a scratch home. Its session had one window with one tab, a local 30 KB `file://` HTML page. Each run was quit with `kill -TERM`. pob logs `Launch to first page` once, from the process start time that `sysctl` reports to the first `didFinish` of the restored active tab. `didFinish` comes at or after first paint, so the times are an upper bound on first paint.
  - The five runs took 298, 296, 291, 309 and 305 ms.
  - An earlier launch compiled the ad block rules and isn't counted. It took 324 ms.
  - Read with `log show --predicate 'subsystem == "pob" AND category == "Speed"'`.

## Rulings made during the build

Every decision taken on the user's behalf, in order: what, why, and what it costs if wrong.

1. A private window labels its rail "Private" itself. Other windows get their profile's name from `AppController` — a window can be built without `AppController`, as the tests do — no cost.
2. The popover's ad block checkbox relies on AppKit's own toggle and doesn't flip its state again — the plan's "flips its own state" would have flipped it twice — no cost.
3. Work ran on a branch in the main checkout, with builds in `build/s3` — that kept the user's Stage 2 build in `build/dd` untouched — a checkout of `main` mid-stage would have switched the tree under the agents.
4. The plan's test for parked tabs surviving a save was changed to open a window in that profile first — as written it read back the file it had just written and guarded nothing — one line.
5. Cookie separation between profiles has no test with a real cookie — it comes from `WKWebsiteDataStore(forIdentifier:)`, unchanged from Stage 2, and tests check each profile uses its own store — a leak between profiles would only show in the hand check.
6. The plan's `\.url?.host()` key paths became closures — Swift can't make a key path to a method call — no cost.
7. Closing a private profile's last window drops its spare tab — otherwise each private session leaked a web view and kept its cookies in memory until quit — a few lines.
8. A private profile's site settings live in memory and never reach a file — the spec says private windows write nothing, and fixing the source beats cleaning up at quit — zoom and permission answers in a private window are forgotten when it closes.
9. Manage Profiles… opens Settings with the window's profile selected, and from a private window it selects the parent profile — a private window has no entry of its own — no cost.
10. ⌘W and ⇧⌘W close Settings when it's in front, though other commands go to the browser window behind — closing a tab in a window behind would surprise — no cost.
11. ⌘, from a browser window also selects that window's profile in Settings — Settings shows the selected profile's details — no cost.
12. The plan's test that commands from Settings reach the browser window got an extra check with ⌘T — as written it passed even with the routing deleted — one assertion.
13. A profile can't be deleted while a private window opened from it is open — that window shares the profile's bookmarks, so ⌘D there would recreate the deleted folder — the user closes private windows before deleting.
14. Deleting a profile first makes the profile let go of its data store, then retries the removal for about 2 seconds — WebKit refuses to remove a store anything still holds, so the plan's steps alone always failed — a delete can take up to 2 seconds, and the real removal has only run in a probe.
15. In a test run, the real data store removal refuses to run — tests run inside pob, so a test that forgot its stub could remove the real Main profile's cookies and logins — one guard.
16. No test calls the real data store removal — the same risk to real data — if WebKit still refuses in the app, the hand check is what finds it.
17. Load anyway counts only as a click on the blocked page itself, in that tab's main frame, and loads the address of the blocked page — a probe showed another window could trigger it — one guard.
18. The bookmark parser is a hand-written forward pass with no length limits — a limit would silently drop real Chrome bookmarks, whose icons are stored inline — about 100 lines replaced the regex.
19. The final whole-branch review ran before the user's checks — so the user tests reviewed code — no cost.
20. The final review's three important findings and three small ones were fixed in one round — the user's first look at profiles would have hit them — no cost.
21. A private window's profile button stays disabled with no menu, as the plan decided, so the menu code for private windows can't be reached from the rail — ⌘, still opens Settings — a few dead lines.
22. Left as is: a session write already under way can recreate a deleted profile's folder — it needs the write to outlast the confirmation and the store removal — an empty folder left behind, nothing destroyed.
23. Left as is: a save skipped because its profile was being deleted isn't retried if the delete then fails — rare — a closed window can come back after a crash.
24. Left as is: unparking has no explicit check for private profiles — private profiles never have parked tabs — one word if that changes.
25. Left as is: two Settings tests wait on fixed sleeps — on a loaded machine they can pass without testing anything, but can't fail falsely — test only.
26. Left as is: ⌘Q with a typed profile name not yet saved loses it — Return or leaving the field saves it — a retype.

## Deferred minor findings

Found in review and left for later. The final review went through them and none blocks daily use. Ones fixed later in the stage aren't listed.

### Behavior

- A download in one profile can ask, or show its notice, in another profile's window.
- A link from another app opens in the front window, which can be a private one. Safari does the same, and the user hasn't decided.
- After launch, the last listed profile's window is in front.
- A pinned rail comes back hidden after a profile switch, because the switch makes a new window.
- The hover-shown rail may close while the profile menu is open. Untested.
- A new profile's default name, "Profile N", can repeat an existing name after a removal.
- A private window closed before its spare tab is built keeps its session in memory until quit.
- On a page opened with Load anyway, the popover's switch shows ticked while the rules are off. A long host name widens the popover.
- Load anyway on a host that redirects to another listed host shows a second blocked page.
- `window.open('pob:load-anyway')` reaches the "open in another app" question. Harmless while no app registers `pob:`.
- A ⌘-clicked download tab that closes lands in Recently Closed, so ⇧⌘T asks about the download again.
- A restore that redirects counts as a visit. A cancelled restore followed by a click to the same address doesn't.
- The sign-in sheet's text gets a blank line at the start or in the middle, depending on the realm and retry lines.
- Bookmark import: `&#38;lt;` decodes twice, `&apos;` and `&nbsp;` aren't decoded, an `<h3>` with no `<dl>` after it names the next folder, and a UTF-16 export reads as "No bookmarks found".
- If a deleted profile's folder can't be removed, that's only logged, and the profile still leaves the list.
- Changing the Settings selection during a delete drops the error alert, and there's no progress indicator during the wait.
- A failed search engine save is only logged. An engine name this build doesn't know in `settings.json` resets transparency and blur.
- The ⌘T signpost forces a layout one turn after every ⌘T.

### Code

- Every window adds an observer to the appearance model and its profile's bookmarks that is never removed. A profile switch makes a new window, so they pile up.
- `SettingsModel.searchEngine` duplicates `AppearanceModel.searchEngine`. `canDeleteProfile` isn't observable, so a delete started outside Settings doesn't refresh it.
- `SettingsModel.delete` clears "Deleting…" early when a second delete of the same profile is refused.
- `blockedNavigation` is never cleared. `onActivePageFinished` stays set after the launch log.
- `TabManager` finds a new tab's id by searching its tabs.
- Whether `close` clears a tab's restore mark wasn't confirmed. `release` does.

### Tests

- `app()` and `window()` are reached through `ProfileWindowsTests()`, not a shared helper.
- No test pins that a private window shares its parent's content blocker and favicons. Losing it would silently drop ad blocking in private windows.
- No test that quitting writes nothing for a private profile.
- `aWindowsChangesSaveOnlyItsProfile` uses the default profile, so a save routed to the wrong profile would pass.
- Profile switching: no test for answering Switch on the sheet, for switching into a profile with a window open, or for the new profile's save on disk.
- Several negative checks wait on fixed sleeps of 100 to 300 ms.
- The 1 MB bookmark test's 1 second limit has about twice the time it needs in a Debug build.
- The delete retry loop, the over-50 MB and unreadable-file import alerts, Back after a restore, a dialog from a cross-origin frame, and a rename of an unknown profile have no tests.
- The sign-in warning test uses a fake challenge, not one from the local server.
- The process start test fails if a test run lasts over an hour, and its name has a typo.
- `appintentsmetadataprocessor` prints "Metadata extraction skipped" in test output. It predates this stage.
