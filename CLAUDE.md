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
Follow the **Adding a feature** checklist below — a feature's `id` is a contract
spread across several files, and most omissions fail *silently* (a "Coming Soon"
screen), not loudly.

## Adding a feature — the checklist

A feature's string `id` is the contract across several files. Do these in order.
**[test]** steps fail `swift test` if skipped; **[silent]** steps have *no*
automated guard, so the failure mode is a non-working feature you only catch by
opening it — verify those by hand.

1. **Define it** — add a `FeatureDef` to `FeatureRegistry.all` (unique `id`,
   title, keywords, category, `kind`). **[test: `hasAll48Features` — bump the
   count; `byID` traps on a duplicate id]**
2. **How-it-works note** — add to `FeatureNotes`. **[test: `everyFeatureHasAHowToNote`]**
3. **Command reference** — add to `FeatureCommands` (each entry leads with the
   tool name). **[test: `everyFeatureHasACommandReference`, `commandReferenceLeadsWithTheTool`]**
4. **If it's an action** (`.instantAction`/`.formAction`/`.toggleAction`):
   - add the runner `case` to `FeatureEngine.dispatch`,
   - add the `id` to `FeatureEngine.implementedIDs`,
   - add an arg-vector test in `FeatureEngineTests` asserting the exact adb
     arguments (and the quoted form of any user value). **[test:
     `everyImplementedActionResolvesToARunner` catches a missing dispatch case;
     `implementedIDsAreAllRealFeatures` catches a typo'd id; your arg-vector test
     catches wrong/omitted-quote arguments]**
5. **If it's a view** (`.view`/`.system`):
   - build the SwiftUI view in `App/Sources/FeatureDetail/Views/`,
   - add the `id` → view `case` in `FeatureDetailView.detailByKind`,
   - add the `id` to `implementedIDs`,
   - if it runs adb directly, wrap each user action in
     `CommandLog.userInitiated(feature: <id>)`. **[test: `implementedIDsAreAllRealFeatures`
     for the id] · [silent: a missing `detailByKind` case renders "Coming Soon";
     missing `userInitiated` leaves the Recent tab empty]**
6. **If it joins a hub** — add it to `FeatureRegistry.absorbedByHub` and fold its
   keywords into the hub's `keywords`. **[test: `hubsStaySearchableByTheirMembersPrimaryKeyword`]**
7. **Logic lives in ADBKit.** adb/Process/parsing go in an ADBKit service with a
   pure, static, tested parser — never `Process`/`adb` in a SwiftUI view.
   **[silent — but a review red flag]**
8. **Verify** — `cd ADBKit && swift test` green, then `make build` with zero
   warnings (warnings are errors).

## Build / test / run

```
make test          # ADBKit unit tests (cd ADBKit && swift test) — 350 tests, keep green
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
- `Features/`: `FeatureRegistry` (52 `FeatureDef`s, declarative; `absorbedByHub`
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
  ScreenRecorder (records through a headless `MirrorSession` on the bundled
  scrcpy server — no desktop scrcpy), Crash, BugReport, Connection (wireless),
  CustomCommand, ToolDetection, AdbKeyboardInstaller, Emulator, AppIcon,
  Performance (per-core CPU/RAM/FPS/per-process), NetworkSpeed (`/proc/net/dev`
  throughput), VideoEditService (ffmpeg export). `ScreenTools` holds the
  `ScreenRecordOptions` struct. **Bundled binaries** (scrcpy-server + a static
  GPLv3 ffmpeg) live in `App/Resources/`, resolved by the App-layer `BundledTools`
  (single version source); `scripts/update-bundled-tools.sh` refreshes them. The
  app needs no `brew install scrcpy`/`ffmpeg`; the Doctor only checks adb /
  emulator / Homebrew.
- `Persistence/`: `JSONStore<T>` (actor, atomic write, sets aside corrupt
  files as `.corrupt`), `Stores` (Bundles, DeepLinks, CustomCommands,
  LayoutState, Presets, OverridesMap, Prefs) in
  `~/Library/Application Support/Droidective/`.
- `Tools/` + APK services: `ManagedTool`/`ManagedToolStore` (actor) download jadx,
  apktool, uber-apk-signer, frida-server/-gadget, and a Temurin JRE from their
  GitHub releases into `Application Support/tools`, verify the asset digest,
  extract (zip/tar.gz/`.xz` via the Compression framework), version-track, and
  upgrade in place. `ApkToolchain` resolves SDK build-tools (aapt2/apksigner/
  zipalign — detected, not downloaded) + the managed tools + `java` (a system JDK
  first, else the managed Temurin). The APK features are services over the
  toolchain with arg-vector tests: `ApkInspectionService` (aapt2 badging +
  apksigner certs), `ApkSigningService` (zipalign + apksigner; keystore password
  via a 0600 temp file, never argv), `DecompileService` (jadx + apktool + a
  `FileNode` tree), `FridaService` (ABI→arch match + frida-server push/run).
  Downloads are point-of-use (a gate in the decompile/Frida views) or from
  Settings ▸ Tools.

## The 52 features

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
`catalogFeatureIDs` (34). **Every feature is enabled by default**
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
- **Device-side shell quoting is the security boundary.** Anything going through
  `adb shell` is joined with spaces and run by the device's `sh`, so EVERY
  user-controlled value (path, URL, SSID, hostname, proxy, locale, free text)
  must be wrapped with `shellQuote()` — never rely on caller-side validation to
  reject metacharacters (an engine `host:port` check is UX, not security).
  `adb push`/`pull`/`exec-out` use the sync protocol — no shell, no quoting.
  There's no linter for this; a missing `shellQuote` is command injection, so
  add an arg-vector test asserting the quoted form (see `OverridesServiceTests`).
- **Cancellation kills the child.** `SystemProcessRunner.run` wraps its body in
  `withTaskCancellationHandler`, so cancelling the calling `.task` (navigation, a
  `.task(id:)` re-key) terminates the adb child instead of orphaning it until its
  timeout. Keep long-running adb work in a cancellable `Task` so this fires.
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

## Standards

The bar: every change ships with tests, leaves the build warning-free, and keeps
the ADBKit/App boundary intact. The architecture exists to make bugs *fail at
compile or test time* — lean on it instead of manual vigilance.

### Development

- **Logic in ADBKit, UI in App.** A new capability is an ADBKit service (a small
  `Sendable` struct/actor over `AdbClient`) plus a pure parser; the view only
  renders and calls it. If a view reaches for `Process`/`adb`/parsing, stop —
  move it down. The boundary is what keeps logic testable without a device.
- **Parsers are pure and static.** `static func parseX(_:) -> …` with no I/O, so
  it's tested directly. Split adb output on `.newlines`, never `"\n"` (CRLF).
- **Quote every device-shell value with `shellQuote()`** (see Conventions). It's
  the security boundary, not caller validation.
- **Long-running work goes in a cancellable `Task`**; `.task(id:)` keys include
  device readiness; guard `!Task.isCancelled` before writing `@State`.
- **No new dependency without a reason.** Each is attack surface + maintenance.
- **Replace, don't deprecate.** Delete dead code in the same change; no shims or
  unused fields (a test like `everyImplementedActionResolvesToARunner` is cheaper
  than a stale parallel list).
- **Keep files focused.** `AppState` and the largest views are already big — put
  a new feature's glue in its own type/extension, not the nearest god-object.

### Testing

- **Test behavior, not implementation** — assert observable output and the exact
  adb argument vector (via `MockProcessRunner`), never private state. A
  behavior-preserving refactor must not break tests.
- **Cover edges and errors, not just the happy path** — empty input, CRLF,
  malformed/partial output, non-zero exit, the failure branch. Mock only the
  boundary (`ProcessRunning`, the filesystem via temp dirs), never logic.
- **Every new parser/runner gets a test in the same change.** For anything taking
  user input that hits `adb shell`, assert the `shellQuote`d form appears in
  `runner.invocations`.
- **Registry invariants are tests, not review folklore** — when you add a
  cross-feature rule, add a loop over `FeatureRegistry.all` that enforces it (the
  `everyFeature*` / `*ResolvesToARunner` tests are the pattern to copy).
- Device-dependent checks are `@Test(.enabled(if:))` gated on `MIRROR_LIVE_TEST=1`
  so they skip cleanly in CI.

### Review (in order: architecture → correctness → tests → quality)

- **Architecture:** does ADBKit stay UI-free? Any `Process`/`adb` in a view? Is
  the new logic in a testable service?
- **Correctness:** every device-shell value `shellQuote`d? output split on
  `.newlines`? `.task(id:)` readiness + `!Task.isCancelled` guard present?
  failure paths handled (not optimistic success)?
- **Tests:** parser + arg-vector tests present and meaningful (would they fail if
  the code broke)? edges covered?
- **Quality:** dead code removed, file not bloated, names clear, zero warnings.
- Adversarially verify a finding before acting on it — read the cited code; many
  plausible findings misread it (a refactor that "removes dead code" can delete a
  live path). Sync to `origin` first.

### Bug-prevention gates (already wired — keep them green)

- `swift test -Xswiftc -warnings-as-errors` (CI) and
  `SWIFT_TREAT_WARNINGS_AS_ERRORS` on the App target — warnings are build errors.
- Swift 6 complete strict concurrency (pinned in `Package.swift` and project.yml)
  — data races fail the build.
- The 16-process starvation canary, the feature-dispatch consistency tests, and
  the registry-invariant tests guard the highest-risk seams. Don't regress them.

### Git / contributing

- Work on a feature branch; open a PR to `main`. `swift test` green and the build
  warning-free before pushing.
- Commits are imperative-mood, one logical change each. PR descriptions state
  what the diff does in plain, factual language — no "critical/comprehensive".
- Never commit secrets (gitleaks runs pre-commit); telemetry keys are build-time
  injected, never committed.

## Status

Feature-complete across all planned milestones plus several UX rounds (latest:
**v2.6.2** — bug fixes plus security, correctness, and test hardening:
shell-quoting and process-cancellation audit fixes, scrcpy decoder size caps, a
navigation leave-guard, opening `.apk` files from Finder with a pre-install
preview, and the start of an AppState refactor); 350 tests green; builds clean
with zero warnings (now enforced as errors in CI). Verified live against a physical device and an Android emulator. Release builds
are Developer ID-signed + notarized and bundle scrcpy/ffmpeg
(see `RELEASING.md`). Open gaps: the Apps list/detail divider isn't
drag-resizable.
