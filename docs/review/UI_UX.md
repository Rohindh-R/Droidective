# UI / UX

Droidective is a Raycast-style command palette: a searchable feature sidebar, a
persistent device bar, a detail pane per feature. UI lives entirely in `App/`
and consumes `ADBKit` — a view never computes or shells out (see
[ARCHITECTURE.md](ARCHITECTURE.md)).

**You cannot review UI without running it.** `swift test` renders nothing.
`make run` builds, relaunches, and opens the app; verify the change live before
signing off.

## Layout correctness

These are the specific traps that have bitten this app — check them when a PR
touches layout:

- **Empty states under a toolbar** must `.frame(maxWidth: .infinity,
  maxHeight: .infinity)`, or the content centers and the toolbar floats in the
  middle of the window.
- **Don't use `HSplitView`** for the main split — it's NSSplitView-backed and
  ignores SwiftUI safe-area insets, so content renders under the device bar. Use
  a plain HStack split.
- **Pull-progress / safe-area strips** live in RootView's safe-area inset, not
  inside the device bar view.
- A hidden-title-bar window still reserves a 32pt title bar — account for it with
  a full-bleed material ZStack and content that respects the safe area (this was
  the ⌘K palette dead-strip bug).
- The ⌘=/⌘- font zoom is a `scaleEffect`, not dynamic type — macOS ignores
  SwiftUI `dynamicTypeSize` for rendering. It's bypassed at 1.0× on purpose.

## Feature UX contract

Every feature ships a complete, consistent experience:

- [ ] A **how-it-works note** (`FeatureNotes`) renders inline beneath the
      content, and a **command reference** (`FeatureCommands`) powers the
      Commands tab. Every feature has both; tests enforce them.
- [ ] For a `view` feature, the `FeatureDetailView.detailByKind` case exists —
      a missing case renders a **"Coming Soon"** placeholder *silently* (no test
      catches it), so confirm the real view shows.
- [ ] A **hotkey** is registered (every feature has one; hub-absorbed features
      appear under "Hidden features" in the Hotkeys tab).
- [ ] **Discoverable in search** — keywords are set; hub members fold their
      keywords into the hub so the hub surfaces for the member's terms.
- [ ] **Recent tab works** — user-initiated adb calls are wrapped in
      `CommandLog.userInitiated(feature:)` (see
      [CONCURRENCY_AND_PITFALLS.md](CONCURRENCY_AND_PITFALLS.md)).
- [ ] **Pulls ask for a save location** (`askSaveLocation`/`askSaveFolder`),
      defaulting to `~/Downloads/Droidective`.

## Interaction feel

- **Loading / empty / error are distinct states**, each handled — not a spinner
  that hangs forever on a failed adb call. Surface the failure with a message
  the user can act on.
- **Destructive actions** (uninstall, clear data, force-stop) confirm before
  acting.
- **No layout jump** when data arrives — reserve space or animate.
- Match the existing panels' spacing, typography, and control style. A new panel
  should feel like it shipped with the others, not like a bolt-on.

## Verifying UI in review

1. `make run` (build → relaunch → open). Never review against a stale build.
2. Exercise the change against a real device *and* an emulator if the behavior
   differs (USB vs. wireless, app presence, permissions).
3. Check the empty/error states deliberately — disconnect the device, point at
   an app that isn't installed, feed it nothing.
4. For drag/canvas/annotation flows that can't be driven by automation, build it
   and hand interactive testing to a human — don't claim a visual pass you
   didn't do.
5. Attach a screenshot or GIF to the PR for any visible change.

## Review checklist

- [ ] You ran the app and saw the change.
- [ ] Loading/empty/error states all handled and tested live.
- [ ] No toolbar-floats / under-device-bar / title-bar-strip regression.
- [ ] FeatureNotes + hotkey + search keywords + Recent-tab wiring present.
- [ ] Destructive actions confirm; pulls ask for a destination.
- [ ] Screenshot/GIF attached for visible changes.
