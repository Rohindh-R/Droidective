## Droidective v2.8.0

A feature release that adds a tabbed workspace with split panes and a React
Native JS Console, curates the "Run on all devices" toggle, and fixes a round of
light-mode and layout issues.

### New features

- **Tabbed workspace with split panes** — open features in tabs (up to ten)
  instead of one detail pane at a time. Tabs stay mounted while hidden, so a
  screen recording or a live view keeps running in the background. Split the
  window into two panes and drag tabs between them, reorder tabs by dragging, and
  navigate with ⌘T, ⌘W, ⌃Tab, and ⌃1–9. The open tabs and the split layout are
  restored on the next launch.
- **React Native JS Console** — a console over the Hermes runtime via the Chrome
  DevTools Protocol: it connects to a Metro target, streams `console.*` output
  with syntax-highlighted objects, and evaluates expressions against the running
  app.

### Improvements

- **Curated "Run on all devices"** — the toggle now appears only for the features
  where running on every device makes sense (send text, React Native, Simulate,
  install app) and is hidden elsewhere.
- **Live mirror follows the active device** — switching the device while
  mirroring re-targets the mirror instead of staying on the previous one.
- **Command palette opens centered**, the **sidebar search shows all matches** and
  locks the group/reorder controls while a query is active, and the **close button
  on toasts and the notification panel** is a single restyled control.

### Fixes

- **Light-mode colors** — named colors resolve per color scheme, and foreground
  text now picks black or white by the background's luminance, so labels no longer
  render white-on-white on light or bright-accent backgrounds (device pill,
  palette rows, copy buttons, toggle styles).
- **Simulate** shows an empty state when no device is connected; **Home** feature
  cards keep their height with short text; **System Restrictions** cards are
  visible in light mode and no longer reload the whole list on each toggle.
- Fully tappable rows for **Settings** disclosures and **Screen Record** advanced
  options; **form action pickers** fill the available width; the **notification
  panel** slide no longer janks the layout.

Installed copies update in place via Sparkle.

## Droidective v2.7.1

A bug-fix release: screen mirroring no longer stops when a device can't capture
audio.

### Fixes

- **Screen mirror on emulators** — scrcpy aborts the whole session (video
  included) when its audio encoder can't start, which happens on most emulators,
  where the device can't create an `AudioRecord`. The in-app mirror requested
  audio unconditionally, so it stopped right after connecting. It now detects an
  audio-only failure — the session ending before the first video frame — and
  reconnects once, video-only, so mirroring keeps working.

Installed copies update in place via Sparkle.

## Droidective v2.7.0

A feature release that adds a full APK toolchain and Frida setup, a custom accent
color, and emulator launching from the device bar, plus a round of UI and
hotkey-recording improvements.

### New features

- **APK Studio** — one workspace over a loaded APK: **Inspect** (manifest,
  permissions, SDK, signing certificates), **Decompile** (`jadx` for readable
  Java or `apktool` for smali + resources, with an in-app source viewer, code
  search that jumps to the matched line, and "open in jadx-GUI" / reveal for
  external editing), **Recompile** an edited `apktool` tree, and **Sign** with the
  debug key, your keystore, or a brand-new keystore created right there. jadx,
  apktool, and a Java runtime are downloaded from their GitHub releases on first
  use and managed in Settings ▸ Tools.
- **Frida setup** — matches the device architecture and downloads the right
  `frida-server` / `frida-gadget`; on a rooted device it pushes and starts
  frida-server so you can attach with your own frida CLI.
- **Custom accent color** — pick your own accent in Settings ▸ Appearance; it
  recolors buttons, toggles, selection, and active icons across the app.
- **Launch emulators from the device bar** — start an Android Studio AVD, or open
  the Emulators screen, straight from the device menu.

### Improvements

- **Settings** is reorganized into **Appearance** and **Privacy** tabs, in a
  roomier window.
- **Connect-a-device prompts** — features that need a device (Send Text, the
  quick actions, Frida, Private DNS…) now show a tailored "connect a device"
  message instead of silently disabled controls.
- **Hotkey recording** — the sidebar's Set-Hotkey popover starts recording the
  moment it opens, and both it and the Hotkeys settings show the modifiers live
  as you hold them.
- **Tools settings** show each downloaded tool's on-disk size, with reveal and
  delete; the decompiled-source cache is reused while the app is open and cleared
  on quit.

Installed copies update in place via Sparkle.

## Droidective v2.6.2

A bug-fix release with security, correctness, and stability hardening, plus a
safer navigation flow and a clearer APK install.

### New features

- **APK pre-install preview** — opening an `.apk` from Finder (double-click, Open
  With, or drag onto the icon) now stages it in the Install App screen with a card
  showing the app name, package, version, target SDK, and size (read via the SDK's
  `aapt2`), so you can see what you're about to install before clicking Install.
  Falls back to the file name and size when build-tools aren't installed.

### Improvements

- **Leave confirmation** — switching feature or device, or quitting, while an
  active screen/mirror recording, performance/network capture, or unsaved
  screenshot/video edit is in flight now asks before discarding it. Recordings
  offer Stop & Save; editors offer Keep or Discard. Background file pulls and
  installs continue uninterrupted.

### Bug fixes

- **Video editor** — an applied crop no longer clips away the video and its
  playback controls; the crop region is shown as an overlay and still applied on
  export.
- **Screen mirroring** — the video, audio, and control decoders cap how much they
  buffer, so a corrupt or desynced stream can no longer grow memory toward a crash.
- **Network speed** — a `/proc/net/dev` counter that resets on reboot no longer
  reports a one-off throughput spike.
- **Reactotron** — "Take snapshot" times out and reports it instead of waiting
  forever when no store plugin is connected; the built-in server now listens on
  loopback only (off the local network); state-tree nodes whose key contains a
  slash no longer collide; and clearing one connection no longer affects another.
- **Device info** — storage reads correctly on devices with dynamic partitions,
  and the battery level ignores an unrelated "Max charging level" line.
- **File Explorer** — an operation that prints a warning but still succeeds is no
  longer reported as a failure.

### Security

- Proxy and locale values passed to the device shell are quoted, and a cancelled
  action now terminates its underlying `adb` process instead of leaving it running.

Installed copies update in place via Sparkle.

## Droidective v2.6.1

A bug-fix release that polishes the v2.6.0 features — Reactotron, the crash
catcher, app install, notifications, and mirroring — and adds a preset library
to custom commands.

### New features

- **Custom command presets** — start from a curated library of common adb
  commands (force-stop, clear data, launch, list packages, key events, toggle
  animations, battery, clear logcat, reboot, and more) instead of a blank
  editor; add one and run or edit it.

### Improvements

- **Reactotron** — copy-as-cURL no longer turns a GET request into a POST (the
  method is stated explicitly when a body is attached, and empty bodies aren't
  sent); export now writes only the items currently shown in a pane after its
  search and category filters, with the export action moved into each pane; the
  connection stays alive when you switch features, with no "Keep Reactotron
  running?" prompt; and the timeline search reads as search, with a magnifying
  glass and clear button matching the other searches.
- **adb install failures** show a plain-English reason (e.g. "Not enough storage
  on the device.") instead of a raw error code; the full adb output stays on the
  Copy button in the toast and the notifications panel.
- **Notifications** — the flowing toast now has a dismiss (×) button, and the
  panel's bulk action reads "Clear all" and appears only when there's more than
  one notification.
- **Mirroring survives device rotation** — the view refreshes its dimensions and
  re-primes the renderer on the new orientation, so taps stay accurate after a
  rotate.
- **Welcome screen** no longer collapses one letter per line in a narrow detail
  pane; the header is responsive and the window's minimum width grows with the
  side panels.

### Bug fixes

- **Crash Catcher** bounds the fetched crash (caps the logcat dump and keeps the
  diagnostic head plus the most recent lines) so a large log can't freeze the UI
  while rendering.
- The **mirror audio engine** is built off the main thread, fixing an app hang
  on first use.

Installed copies update in place via Sparkle.

## Droidective v2.6.0

### New features

- **Reactotron** — a built-in Reactotron debugger for React Native apps, with no
  desktop app required: Droidective runs the Reactotron server itself on :9090
  and auto-reverses the port. A live timeline of logs, API calls (with cURL
  export), state changes, and images; a store browser with live subscriptions,
  action dispatch, and snapshots; custom commands; and a REPL. Switches between
  multiple connected apps, and can keep the connection alive as you move around
  the app.
- **Install App** — install an APK onto your device(s) by dragging it onto the
  new Install App screen or picking a file (reinstalls keep app data, and it
  installs on every selected device). Double-clicking an `.apk` in Finder opens
  Droidective and asks which device to install onto.

### Improvements

- **Dark by default** — new installs start in dark mode. Light mode is now marked
  **Beta** in Settings → Appearance while a few screens are tuned for it; Auto and
  your own choice still work as before.
- **Emulators in the dev roles** — the Android and React Native roles now include
  the Emulators feature, and existing users on those roles pick it up
  automatically (no need to re-pick your role).

Installed copies update in place via Sparkle.

## Droidective v2.5.0

A big UX release: pick your role on first launch and get a focused Home, a faster
command palette, a sidebar you can rearrange, and refreshed screens throughout.

### New features

- **Role-based start** — on first launch, pick a role (Android, React Native, QA,
  Support, or "everything") and Droidective curates a focused feature set and a
  Home launchpad of your most-used tools, ordered by real usage. Change your role
  anytime in Settings; nothing is ever removed.
- **Bug Report screen** — capturing a bug report now has its own screen instead
  of firing blind.
- **Forward Metro (React Native)** — one click runs `adb reverse tcp:8081` so the
  device reaches Metro on your Mac.

### Improvements

- **Command palette (⌘K)** — rebuilt as a tight, centered Spotlight-style panel.
  Pin features with `⌘P` (pinned items lead the sidebar and palette), enable or
  disable with `⌘E`, and search now matches every word you type — so "copy ip"
  finds "Copy Device IP". Keyboard hints throughout.
- **Reorder the sidebar** — a reorder button drops the sidebar into an edit mode
  (rows jiggle) where you drag to rearrange. Grouped and ungrouped layouts keep
  independent orders, and pinning moved to right-click so rows stay clean.
- **Grouping toggle** — group-by-category is now a button next to the search
  field instead of a Settings option.
- **Refreshed screens** — Connection, Device Info, Simulate, React Native, Deep
  Links, App Info, System Restrictions, and the Apps detail pane share one card
  layout.
- **Emulators** — click a running emulator to bring its window to the front, and
  a freshly launched emulator comes forward on its own.
- **Screenshot editor** — press Delete to remove the selected annotation.
- **Theme** — a neutral charcoal dark palette (no blue cast) and brand-green
  feature icons throughout.
- **Update notes** — the in-app updater shows release notes in its own window
  instead of opening the web page.
- **First-run privacy screen** — appears after a few launches instead of the
  first. Anonymous crash reports and usage analytics stay opt-out in
  Settings → Privacy.
- **Star prompt** — a one-time nudge to star the project on GitHub.

Installed copies update in place via Sparkle.

## Droidective v2.4.1

### Improvements

- **Sidebar footer** — the "Manage features" button stays on one line, and the
  sidebar has a higher minimum width so the footer no longer wraps when narrowed.

Installed copies update in place via Sparkle.

## Droidective v2.4.0

A live in-app screen mirror, a video editor, and self-contained tools — scrcpy
and ffmpeg now ship inside the app, so there's nothing to `brew install`. The
build is also signed with a Developer ID and notarized by Apple.

### New features

- **In-app screen mirror** — mirror and control the device live in the app
  window, built on a native scrcpy engine (no `scrcpy` install). Take a
  screenshot, record the screen, hear device audio, sync the clipboard both
  ways, adjust volume, and drive Back / Home / Recents.
- **Video Editor** — trim, rotate, flip, crop, change speed, mute, convert the
  format (MP4 / MOV / MKV / WebM / GIF), and compress — with undo/redo
  (`⌘Z` / `⇧⌘Z`). A finished recording opens straight in the editor, and you can
  open any existing video to edit.
- **Self-contained tools** — scrcpy-server and a static ffmpeg are bundled in the
  app, so mirroring, recording, and video export work with no `brew install`.

### Improvements

- **Screen recording** runs through the mirror — no ~3-minute cap, device audio,
  and it survives rotation — with pause/resume and a discard / save / edit prompt
  when you stop.
- **Live edit preview** — rotate, flip, crop, speed, and mute reflect in the
  preview as you change them. Crop is a focused mode with the player controls
  hidden and Apply / Cancel / Reset (Esc) actions.
- **Privacy consent redesigned** — the first-launch telemetry screen is clearer,
  with iconned rows, a recommendation, and both anonymous crash reports and usage
  analytics on by default (still nothing is sent until you continue, and it's
  changeable anytime in Settings → Privacy).

### Install

Download the `.dmg` below and drag **Droidective** into **Applications**. This
build is signed with a Developer ID and notarized by Apple, so it opens without
any quarantine workaround.

Installed copies from v2.1.0+ update in place via Sparkle.

## Droidective v2.3.0

A big screenshot-editor update — annotations you can move, resize, and rotate
after drawing, blur and opacity controls, editable text, and a rotatable crop —
plus a handful of fixes.

### New features

- **Editable annotations** — select any markup (shapes, arrows, pen, text,
  redactions) to move, resize, or delete it; a freshly drawn one is selected
  automatically so you can adjust it right away.
- **Rotate** — rotate any annotation, the crop box, or the whole screenshot
  (90°) with a drag handle.
- **Redaction controls** — adjustable blur strength for blur redactions, and
  fill opacity for solid ones.
- **Editable text** — re-open a text label to change it, and drag a handle to
  resize it.
- **Rotatable crop** — tilt the crop box to straighten as you crop.

### Fixes

- Text fields now show the brand-green focus ring on every Mac (it followed the
  macOS system accent before) and dim when the window is inactive.
- Blur redaction no longer leaks the original image at its edges.
- ⌘= / ⌘- zoom no longer discards in-progress work, such as a captured
  screenshot.
- **Apps** — uninstalling a user app no longer reports a false "protected"
  error, and the detail pane clears once the app is removed.
- Demo Mode is a sidebar toggle instead of a separate screen.
- Renamed **Current Activity** to **Copy Current Activity**.

### Install

Download the `.dmg` below and drag **Droidective** into **Applications**. The
build is ad-hoc signed but not notarized, so clear the quarantine once:

```sh
xattr -dr com.apple.quarantine "/Applications/Droidective.app"
```

Installed copies from v2.1.0+ update in place via Sparkle.

## Droidective v2.2.1

A fix for the accent color on Macs set to a specific system accent.

### Fixes

- Buttons, toggles, sliders, and other standard controls now always use the
  brand green. They previously followed the macOS system accent color, so on a
  Mac set to a specific accent (for example Blue) they rendered in that color
  instead of green.

### Install

Download the `.dmg` below and drag **Droidective** into **Applications**. The
build is ad-hoc signed but not notarized, so clear the quarantine once:

```sh
xattr -dr com.apple.quarantine "/Applications/Droidective.app"
```

Installed copies from v2.1.0+ update in place via Sparkle.

## Droidective v2.2.0

A UI overhaul: a refreshed theme, feature hubs that keep the sidebar short, a
screenshot annotation editor, and every feature on by default.

### New features

- **Screenshot editor** — a capture now opens in an editor with pen, highlighter,
  shapes (rectangle, ellipse, arrow, line), text, and redaction (blur or solid),
  plus zoom, crop, and undo/redo (`⌘Z` / `⇧⌘Z`). Save or copy when you're ready;
  nothing is written to disk until then. Captures from the sidebar, a global
  hotkey, or the menu bar still save straight to the capture folder.
- **Feature hubs** — React Native, Simulate, and Connection each gather their
  related actions onto one screen, and the Apps explorer now also handles per-app
  management (open, force-stop, clear cache/data, disable, uninstall) alongside
  info and permissions. Gathered tools stay searchable and hotkey-able.
- **Live memory graph** — Memory Usage charts Total PSS over time on an axis that
  scales to the live range.
- **Notifications panel** — a side panel keeps the toasts that matter (errors,
  warnings, and results that produced a file).

### Improvements

- **Theme** — a new dark/light terminal palette and logo, and detail panes that
  center their content instead of stretching edge to edge.
- **Sidebar** — features group by category with drag-to-reorder (within a group
  or whole groups), tighter rows, and a centered drop guideline. Instant actions
  fire straight from the sidebar without opening a screen.
- **Every feature on by default** — the catalog ("Manage features") is now for
  hiding the ones you don't want; Restore Defaults is gone.

### Install

Download the `.dmg` below and drag **Droidective** into **Applications**. The
build is ad-hoc signed but not notarized, so clear the quarantine once:

```sh
xattr -dr com.apple.quarantine "/Applications/Droidective.app"
```

Installed copies from v2.1.0+ update in place via Sparkle.

## Droidective v2.1.0

Device control, in-app feedback, and automatic updates.

### New features

- **Device control suite** — **Wi-Fi** (connection details, radio toggle, saved
  networks, and saved passwords on rooted devices), **Private DNS** (off /
  automatic / DNS-over-TLS provider), **Root Status** (multi-signal root
  detection), and **System Restrictions** (dev toggles for the package verifier,
  hidden-API access, and stay-awake, plus SELinux and read-write remount on root).
- **About & Feedback** — report a bug or request a feature through pre-filled
  GitHub issues (app/OS/device diagnostics attached), star the project, and find
  author info, from a new sidebar panel.
- **Automatic updates** — Droidective now updates itself with signed updates via
  Sparkle; also available from the app menu.

### Privacy

- Anonymous crash reporting (on by default, opt-out) and opt-in usage analytics,
  with a first-launch disclosure and controls in Settings → Privacy. No device
  serials, file paths, or command contents are ever sent.

## Droidective v2.0.0

A round of new tools and workflow upgrades on top of v1. Now 39 features; ADBKit
has 146 unit tests.

### New features

- **Performance Monitor** — per-core CPU, system + per-process RAM, app FPS/jank,
  and network throughput, charted live with dynamic axes and a hover crosshair.
  Record a session and export it to JSON + CSV.
- **Network Speed** — a dedicated download/upload monitor (device-wide and
  per-interface) with session totals, recording, and export.
- **Home screen + welcome tour** — a getting-started landing page and a
  first-launch walkthrough (replayable anytime).
- **Per-feature command bar** — Recent runs (the exact adb commands + output),
  the Commands a feature uses (copyable), and an embedded terminal, beneath every
  feature.

### Improvements

- **Mirror Screen (scrcpy)** options — max size, bit-rate, FPS, record-to-file,
  view-only, always-on-top, fullscreen, keep-awake, turn-screen-off.
- **Screen Record** options — resolution, bit-rate, time limit, rotate, timestamp
  overlay. **Screenshot** — capture delay and copy-to-clipboard.
- **Sidebar** — VS Code-style flat list, drag-to-reorder (when ungrouped),
  `⌘1`–`⌘9` quick-select, pinned items, category-grouping toggle.
- **Setup Doctor** verifies the toolchain (adb / scrcpy / emulator / ffmpeg /
  Homebrew). App icons in the Apps list. `⌘=`/`⌘-` font zoom. The device + bundle
  pickers lock while a recording is in flight.

### Notes

The "Frequent" sidebar section was removed. Each feature's how-it-works note now
shows inline beneath the feature rather than in a toolbar popover.

## Droidective v1.0.0

The first public release of **Droidective** — a native macOS companion for
Android and React Native debugging. A Raycast-style command palette puts 37
one-click `adb` actions a `⌘K` away, with no terminal required.

Built in Swift 6 + SwiftUI, with all logic in a platform-agnostic `ADBKit`
package (111 unit tests, runs without a device).

### Highlights

- **Command palette (`⌘K`)** — search and run any feature; arrow-key navigation,
  a Frequent section, and per-feature hotkeys.
- **Device bar** — pick a device (with Android version + battery), run-on-all
  fan-out, a contextual app-bundle picker, and an active-overrides pill.
- **Emulator manager** — list, launch (normal / cold boot / wipe data), and stop
  your Android Studio AVDs.
- **File Explorer** — browse device storage with multi-select, copy/cut/paste,
  delete, new folder, Get Info, drag-in / push from the Mac, and pull with a
  real progress bar.
- **Apps explorer** — every user + system app, searchable by name/version/bundle,
  with live runtime-permission control and APK pull.
- **Logcat** — live stream with level/app/tag/text filters, follow-to-bottom,
  tag highlighting, and export.
- **Screen** — scrcpy mirroring, screenshots with in-app preview and drag-out,
  screen recording with optional GIF, demo mode.
- **Device state overrides** — fake battery, dark mode, font & density,
  animation scale, locale, network toggles, HTTP proxy — all reset-tracked.
- **Diagnostics** — crash catcher (Slack/Jira formatting), one-click bug-report
  zip, device overview (RAM, storage, battery health & cycle count, CPU, app
  counts).
- **Custom commands** — your own `adb` macros with `{bundleId}`/`{serial}`
  placeholders, tokenized safely (never run through a shell).

Every feature carries an ⓘ "how it works" note, and every file pulled from the
device asks where to save.

### Requirements

- macOS 14 (Sonoma) or later
- Android `adb` (the app finds it via `ANDROID_HOME`, `~/Library/Android/sdk`, or
  Homebrew, and offers a one-click install if missing)
- Optional: `scrcpy`, `ffmpeg`, the Android SDK `emulator`

### Install

Download the `.dmg` below, open it, and drag **Droidective** into
**Applications**.

The build is ad-hoc signed but not notarized, so on first launch macOS shows
*"Droidective is damaged and can't be opened."* Clear the Gatekeeper quarantine
once:

```sh
xattr -dr com.apple.quarantine "/Applications/Droidective.app"
```

Then open it normally. Building from source (`brew install xcodegen && make run`)
avoids the quarantine entirely.
