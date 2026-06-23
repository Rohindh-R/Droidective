<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/icon.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/icon-light.png">
    <img src="docs/icon.png" width="120" alt="Droidective app icon">
  </picture>
</p>

# Droidective

A native macOS companion for Android and React Native debugging. One-click adb
actions in a Raycast-style command palette — no terminal required.

Built in Swift 6 + SwiftUI, with all logic in a platform-agnostic Swift package
(`ADBKit`) so the engine stays testable and a future cross-platform port only
needs a new UI layer.

> Requires macOS 14+ and the Android `adb` tool. Release builds are signed with a
> Developer ID and notarized; see [Building](#building) and
> [Install a release build](#install-a-release-build).

## Features

A searchable palette (`⌘K`) of 45 adb actions, organised by category and
gathered into focused hubs (React Native, Simulate, Connection) so the sidebar
stays short. Every action is on by default; hide the ones you don't want from
the in-app catalog.

- **Input & clipboard** — send text (Unicode via ADBKeyboard, auto-offered),
  copy the device's Wi-Fi IP.
- **Connection** — reverse ports, wireless ADB wizard (tcpip + Android 11
  pairing), disconnect, run-on-all fan-out, **emulator manager** (list / launch
  / cold-boot / wipe / stop your Android Studio AVDs), and a live **network
  speed** monitor (download/upload over time, per-interface, recorded + exported).
- **React Native** — dev menu, reload JS, saved deep links per app, simulate
  process death, set dev-server host.
- **Screen & capture** — scrcpy mirroring with common options (max size,
  bit-rate, FPS, record-to-file, view-only, turn screen off…), a screenshot
  editor (pen, shapes, text, blur/solid redaction, zoom, crop, undo/redo) that
  saves or copies on demand, screen recording with resolution / bit-rate /
  time-limit / rotate options and optional GIF, demo mode.
- **Device state** — searchable device info (RAM, storage, battery health &
  cycle count, CPU, app counts, every getprop), **file explorer** (browse,
  copy/cut/paste, delete, new folder, push from Mac, pull), fake battery, dark
  mode, font & density, animation scale, locale, network toggles, HTTP proxy —
  all tracked as resettable overrides.
- **App management** — **Apps explorer** (every user + system app, searchable by
  name/version/bundle, with live permission control), manage app
  (open/stop/clear/uninstall), permissions, app info + APK pull, current
  activity, foreground bundle id, live memory, run-as sandbox browser, monkey.
- **Logs & diagnostics** — live logcat (level/app/tag/text filters,
  follow-to-bottom, export), crash catcher with Slack/Jira formatting, one-click
  bug-report zip, and a **performance monitor** (per-core CPU, RAM, FPS, network,
  and per-process usage charted live, recorded, and exported to JSON/CSV).
- **Tool UX** — custom adb macros with `{bundleId}`/`{serial}` placeholders,
  feature catalog with pinned items, per-feature + global hotkeys, menu-bar quick
  actions.

Every feature has a how-it-works description and a command bar beneath it with
**Recent** runs (the exact adb commands + output), the **Commands** it uses (copyable),
and an embedded **Terminal**. A **Home** screen and first-launch tour explain the
basics; the sidebar adds drag-to-reorder, `⌘1`–`⌘9` quick-select, and `⌘=`/`⌘-`
font zoom. Files pulled from the device always ask where to save (default
`~/Downloads/Droidective`).

## Requirements

- macOS 14 (Sonoma) or later
- [Android platform-tools](https://developer.android.com/tools/releases/platform-tools)
  (`adb`) — found automatically via `ANDROID_HOME`, `~/Library/Android/sdk`, or
  Homebrew; the app offers a one-click install if it's missing.
- Optional: the Android SDK `emulator` (AVD management). `scrcpy` (the server
  payload) and `ffmpeg` ship inside the app — no `brew install` needed.

## Building

```sh
brew install xcodegen     # one-time
make test                 # ADBKit unit tests — no device needed
make build                # generate the Xcode project + build
make run                  # build and launch
```

`make` targets wrap XcodeGen + xcodebuild. The `.xcodeproj` is generated from
`project.yml` and is gitignored — run `make generate` (or `xcodegen generate`)
after a fresh clone if you want to open it in Xcode.

The app runs **without the App Sandbox** (it must spawn `adb`, the bundled
`ffmpeg`, the `emulator`, and `brew`). Local builds are ad-hoc signed; release
builds are signed with a Developer ID and notarized.

## Install a release build

Each [GitHub release](../../releases) ships a `Droidective-<version>.dmg` built
by CI, signed with a Developer ID and notarized by Apple. Open it and drag
**Droidective** into **Applications** — no quarantine workaround needed.

Installed copies update in place via Sparkle.

## Architecture

```
ADBKit/   Swift package — all logic, zero UI dependencies (swift test)
  Exec/         adb process execution, tool location, scoped command log
  Devices/      discovery (2s polling), getprop, hardware/usage overview
  Features/     declarative 45-feature registry + runners + how-to notes
  Services/     logcat streaming, overrides, file/apps explorers, capture,
                screen record, crash, bug report, wireless, emulators,
                performance + network monitors, scrcpy/screenrecord options…
  Persistence/  JSON stores in ~/Library/Application Support/Droidective
App/      SwiftUI macOS app — command palette, device bar, feature views,
          Home + tour, per-feature command bar with an embedded terminal,
          settings, menu-bar extra, ⌘K search window
```

The split is strict: `ADBKit` imports no UI frameworks (feature icons are SF
Symbol *name strings*), so the whole engine is unit-tested without a device or
Xcode. See [`CLAUDE.md`](CLAUDE.md) for the full design notes and conventions.

## Contributing

Issues and PRs welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

[MIT](LICENSE) © 2026 Rohindh R.

scrcpy, ffmpeg, adb, and the Android emulator are separate tools with their own
licenses. The app bundles the scrcpy server payload and a static ffmpeg (GPLv3);
adb and the emulator are used from your Android SDK. See
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
