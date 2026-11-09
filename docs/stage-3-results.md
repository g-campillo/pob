# Stage 3 results

## Speed

Measured on 2026-11-09 on macOS 27.0.1, with an Apple M5 Pro, from the Debug build in `build/s3`. A Release build wasn't measured. Launch was measured warm, not after a reboot.

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
