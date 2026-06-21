# CLAUDE.md — Droidective

Native macOS app for Android/React-Native debugging over adb. A Raycast-style
command palette: searchable feature sidebar, persistent device bar, a detail
pane per feature. Swift 6 + SwiftUI, macOS 14+.

## Architecture (the load-bearing rule)

Two layers, strictly separated so a future cross-platform port only re-does UI:

- **`ADBKit/`** — a SwiftPM package holding *all* logic. Zero UI imports
  (feature icons are SF Symbol *name strings*). Actors for stateful services,
  `Sendable` value types, strict concurrency complete. Test with
  `cd ADBKit && swift test` — no Xcode, no device needed.
- **`App/`** — thin SwiftUI shell. `@Observable @MainActor AppState` consumes
  ADBKit. Built via XcodeGen (`project.yml`) + xcodebuild; `.xcodeproj` is
  gitignored and regenerated.

When adding a feature: logic + a parser test go in ADBKit; the view goes in
`App/Sources/FeatureDetail/Views/`. Never put adb/Process logic in a SwiftUI view.

## Build / test / run

```
make test          # ADBKit unit tests (cd ADBKit && swift test) — 186 tests, keep green
make build         # xcodegen generate + xcodebuild Debug
make run           # build + open the .app
```

The agent loop I use: edit → `cd ADBKit && swift test` → `xcodegen generate` →
`xcodebuild ... build` → relaunch the .app → screenshot to verify. Build output
lands at `DerivedData/Build/Products/Debug/Droidective.app`.

`brew install xcodegen` if missing. App is ad-hoc signed, sandbox OFF (it must
spawn adb/scrcpy/emulator/brew).

## Key types (ADBKit)

- `Exec/`: `ProcessRunning` protocol → `SystemProcessRunner` (real) +
  `MockProcessRunner` (tests). `ToolLocator` (actor) resolves adb/scrcpy/brew/
  ffmpeg/emulator via SDK paths → Homebrew → `zsh -lc` fallback, cached.
  `AdbClient` (structured `AdbResult`, never throws on non-zero exit, only on
  `.adbNotFound`). `CommandLog` (actor; records only inside
  `CommandLog.$isUserInitiated.withValue(true)` — background polling stays out —
  and tags each entry with `$currentFeatureID`, set via
  `CommandLog.userInitiated(feature:)`, so the command bar's Recent tab can
  filter by feature).
- `Devices/`: `DeviceMonitor` (actor, 2s poll, `AsyncStream<[Device]>`),
  `DeviceListParser`, `DeviceProps` (getprop), `DeviceOverview` (RAM/storage/
  battery/CPU/app counts), `DeviceDetails` (picker enrichment).
- `Features/`: `FeatureRegistry` (45 features, declarative; `absorbedByHub`
  maps a hub screen to the features it gathers, flattened to
  `absorbedFeatureIDs`; `catalogFeatureIDs` is the registry minus those),
  `FeatureModel`,
  `FeatureEngine` (runner dispatch +
  `implementedIDs` + every sub-service), `FeatureNotes` (the ⓘ how-it-works
  text — every feature must have one; a test enforces it), `SidebarOrdering`
  (pure `reorder`/`move`/`moveToEnd` helpers for the sidebar, unit-tested
  without UI). The grouped sidebar uses **custom `.onDrag`/`.onDrop`** (not
  `List.onMove`, which raced the row tap gestures and dropped intermittently):
  a feature drag reorders within its group, a header drag moves the whole group,
  and `SidebarDrop` draws the insertion guideline between rows for features and
  only at group boundaries for groups. Persisted as
  `LayoutState.sidebarOrder`/`categoryOrder`/`collapsedCategories`.
- `Services/`: one per domain — TextInput, AppControl, AppInspection (perms/
  info/meminfo/sandbox), AppsExplorer, FileExplorer, Overrides, ScreenCapture,
  ScreenRecorder, Crash, BugReport, Connection (wireless), CustomCommand,
  ToolDetection, AdbKeyboardInstaller, Emulator, AppIcon, Performance
  (per-core CPU/RAM/FPS/per-process), NetworkSpeed (`/proc/net/dev` throughput).
  `ScreenTools` holds the pure `ScrcpyOptions`/`ScreenRecordOptions` arg builders.
- `Persistence/`: `JSONStore<T>` (actor, atomic write, sets aside corrupt
  files as `.corrupt`), `Stores` (Bundles, DeepLinks, CustomCommands,
  LayoutState, Presets, OverridesMap, Prefs) in
  `~/Library/Application Support/Droidective/`.

## The 45 features

Most `.view` features are full-screen bespoke panels (file-explorer, apps,
emulators, device-info, logcat, crash-catcher, sandbox-browser, performance,
network-speed, wifi, root-status, screen-record, scrcpy + the custom-commands/
catalog system panels). Three are **hub** screens — `react-native`, `simulate`,
and `connection` — that gather related instant-/form-/toggle-actions into one
scrollable grouped `Form` (the Apps explorer similarly covers per-app
management — its detail pane carries the old "Manage App" controls: open,
force-stop, clear cache/data, plus disable/uninstall). A hub's gathered features
(`FeatureRegistry.absorbedByHub` → `absorbedFeatureIDs`) are managed only from
the hub: the display layer filters `FeatureDef.isAbsorbedByHub` out of the
catalog, the sidebar (`AppState.enabledFeatures`), and search
(`disabledMatches` + the ⌘K palette), so they never appear as standalone rows or
"disabled" search hits. Discoverability is preserved by folding each member's
keywords into its hub (a test enforces the hub matches each member's primary
keyword), so searching e.g. "battery" or "force stop" surfaces the Simulate /
Apps hub. They stay hotkey-able (every feature registers a shortcut; the Hotkeys
tab lists bound members under "Hidden features"). This is a pure display filter —
no persisted migration — so it also covers a hub that grows later. The rest are generic instant-/form-/toggle-actions
driven by the registry. The catalog and Home's "All N features" count use
`catalogFeatureIDs` (27). **Every feature is enabled by default**
(`defaultEnabledIDs == catalogFeatureIDs`); the catalog (Manage features) is for
turning OFF the ones you don't want, not opting in — there's no Restore button.
`LayoutState.adoptAllEnabled()` is a one-time migration that turns everything on
for existing layouts; `adoptNewDefaults()` still auto-enables a newly-shipped
feature for existing users via `knownIds`.

## Conventions / gotchas learned the hard way

- **Process runner must never block a cooperative thread.** `SystemProcessRunner`
  uses `terminationHandler` + `readabilityHandler`, not `waitUntilExit`. A
  blocking design starved the async pool and froze the whole app. There's a
  16-concurrent-process canary test guarding this — don't regress it.
- **`"\r\n"` is ONE Swift Character.** Splitting adb/emu console output on
  `"\n"` silently fails on CRLF. Use `.components(separatedBy: .newlines)`.
- **Device-side shell quoting:** anything going through `adb shell` is joined
  with spaces and run by the device's `sh`. Quote URLs/paths with
  `shellQuote()` (deep links, sandbox, file explorer). `adb push`/`pull` use
  the sync protocol — no shell, no quoting.
- **Pull progress** is the destination file's on-disk size polled against the
  known source size (real %). Screenshots/recordings/dir pulls stay
  indeterminate (no reliable total). The progress strip lives in RootView's
  safe-area inset, not inside DeviceBarView.
- **`.task(id:)` keys must include readiness** (`targetSerials.first`), not just
  serial — a device authorizing keeps the same serial and the view must reload.
  Guard `!Task.isCancelled` before writing fetched results into @State.
- **Empty states under a toolbar must `.frame(maxWidth/maxHeight: .infinity)`** —
  otherwise the whole VStack centers and the toolbar floats mid-window.
- **`HSplitView` ignores SwiftUI safe-area insets** (it's NSSplitView-backed) —
  content renders under the device bar. Use a plain HStack split.
- **Command bar Recent tab filters CommandLog by featureID.** A view-feature
  that runs adb directly (logcat, device-info, file-explorer…) must wrap its
  user-initiated calls in `CommandLog.userInitiated(feature: <id>)` or its Recent
  tab stays empty. Keep background polling OUT (don't wrap it). Every feature's
  how-it-works note now renders inline beneath its content (the old ⓘ popover is
  gone), and `FeatureRegistry.commands(for:)` powers the Commands tab.
- **⌘=/⌘- font zoom is a `scaleEffect` on RootView, not dynamic type.** macOS
  ignores SwiftUI `dynamicTypeSize` for rendering, so the content is laid out at
  `size/scale` and scaled up. It's bypassed entirely at 1.0× because the
  transform breaks `.help` tooltips (and `chartXSelection`/hover) underneath it.
- Every pull asks for a save location (`askSaveLocation`/`askSaveFolder`);
  defaults to `~/Downloads/Droidective`.
- **Screenshot is a capture-and-annotate editor.** The Screenshot *view*
  captures into `ScreenshotEditorView` (pen/highlighter/shapes/arrow/text/redact
  + zoom + crop) and writes nothing until you Save/Copy — `captureForEditor`
  returns the PNG bytes (`ScreenCaptureService.captureScreenshotData`), not a
  file. The quick paths (sidebar ⏎, global hotkey, menu bar) call `runScreenshot`,
  which now grabs and saves straight to the capture folder with no dialog.
  Annotations are normalized (0…1) points so the on-screen canvas and the
  full-resolution export share `ScreenshotMarkup.draw`; export/crop flatten via
  `ImageRenderer`. Redact has two styles: solid (drawn in the canvas) and blur
  (a blurred copy of the base image masked to the regions — `RedactBlurLayer`,
  layered under the canvas in both the editor and the export). Undo/redo
  (⌘Z / ⇧⌘Z) is snapshot-based (full image+annotations) and reaches the editor
  via `CommandGroup(replacing: .undoRedo)` + a `focusedSceneValue` — nil'd while
  typing a text label so ⌘Z falls through to the text field.
- UI automation for verification: prefer AX element refs over coordinate
  clicks; the user works on the Mac alongside you (see memory).

## Git / contributing

- Work on a feature branch; open a PR to `main`. Keep `swift test` green and the
  build warning-free before pushing.
- Commits are imperative-mood, one logical change each.

## Status

Feature-complete across all planned milestones plus several UX rounds (latest:
**v2.2.0** — theme/hub overhaul, screenshot annotation editor, all-features-on
default, live memory graph); 186 tests green; builds clean with zero warnings.
Verified live against a physical device and an Android emulator. Open gaps: no
notarization (ad-hoc signed — see README for the Gatekeeper workaround), the Apps
list/detail divider isn't drag-resizable.
