# Stage 1 results

Run by the user on 2026-11-04 on macOS 27.0.1, with an Apple M5 Pro.

| Check | Result | Evidence |
|---|---|---|
| Glass, transparency and blur together | Pass | The user confirmed it looks like the mockup, with minor styling changes saved for later |
| H.264 and AAC video | Pass | YouTube played with sound. `canPlayType` also reports `probably` for H.264 and AAC in `TabTests` |
| Google sign-in | Pass | Sign-in completed with no issue |
| Docked Web Inspector | Pass | The user confirmed it works |
| Apple Passwords through native AutoFill | Fail | On a site with a saved login, macOS offered no credentials in the native fields |
| Screen sharing in Teams | Not tested | The user will test this on demand |
| Screen sharing in Meet | Not tested | The user will test this on demand |

## Quick checks

- Links at the top of a page and ⌘W with a popup in front appear to work, per the user.
- Not run: Reduce Transparency, Increase Contrast, Reduce Motion, and the `screencapture` checks. This session has no Screen Recording permission.

## Decisions

- **Passwords:** native AutoFill doesn't work, so the Passwords menu bar item stays the way to sign in until the user decides whether they want a one-way import into pob's own Keychain store.
- **Screen sharing:** this remains the biggest open risk. Stage 2 goes ahead without it. If it fails later, the fallback is Open in Safari, and the engine decision goes back to the user only if that isn't acceptable.

## Found during testing

The first launch looked like nothing had opened, because a blank page left the window fully clear with no controls. A faint backdrop now sits behind the page, and the rail opens at launch with the address field focused.

## Expected gaps

The domain pill and tabs weren't missing by mistake. Both are part of Stage 2.
