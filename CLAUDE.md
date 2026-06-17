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
make test          # ADBKit unit tests (cd ADBKit && swift test) — 111 tests, keep green
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
  `CommandLog.$isUserInitiated.withValue(true)` — background polling stays out).
- `Devices/`: `DeviceMonitor` (actor, 2s poll, `AsyncStream<[Device]>`),
  `DeviceListParser`, `DeviceProps` (getprop), `DeviceOverview` (RAM/storage/
  battery/CPU/app counts), `DeviceDetails` (picker enrichment).
- `Features/`: `FeatureRegistry` (39 features, declarative), `FeatureModel`,
  `FeatureEngine` (runner dispatch +
  `implementedIDs` + every sub-service), `FeatureNotes` (the ⓘ how-it-works
  text — every feature must have one; a test enforces it).
- `Services/`: one per domain — TextInput, AppControl, AppInspection (perms/
  info/meminfo/sandbox), AppsExplorer, FileExplorer, Overrides, ScreenCapture,
  ScreenRecorder, Crash, BugReport, Connection (wireless), CustomCommand,
  ToolDetection, AdbKeyboardInstaller, Emulator, Performance (CPU/RAM/FPS).
- `Persistence/`: `JSONStore<T>` (actor, atomic write, sets aside corrupt
  files as `.corrupt`), `Stores` (Bundles, DeepLinks, CustomCommands,
  LayoutState, Presets, OverridesMap, Prefs) in
  `~/Library/Application Support/Droidective/`.

## The 39 features

15 view-features have bespoke SwiftUI panels (file-explorer, apps, emulators,
device-info, logcat, crash-catcher, app-management, permissions, app-info,
meminfo, sandbox-browser, deep-link, wireless-adb, screen-record, performance,
network-speed + the custom-commands/catalog system panels). The rest are generic
instant-action /
form-action / toggle-action driven by the registry. Default-enabled set is 16;
`LayoutState.adoptNewDefaults()` auto-enables newly-shipped default features
for existing users via a `knownIds` migration.

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
- Every pull asks for a save location (`askSaveLocation`/`askSaveFolder`);
  defaults to `~/Downloads/Droidective`.
- UI automation for verification: prefer AX element refs over coordinate
  clicks; the user works on the Mac alongside you (see memory).

## Git / contributing

- Work on a feature branch; open a PR to `main`. Keep `swift test` green and the
  build warning-free before pushing.
- Commits are imperative-mood, one logical change each.

## Status

Feature-complete across all planned milestones plus several UX rounds; 111 tests
green; builds clean with zero warnings. Verified live against a physical device
and an Android emulator. Open gaps: no notarization (ad-hoc signed — see README
for the Gatekeeper workaround), the Apps list/detail divider isn't
drag-resizable.
