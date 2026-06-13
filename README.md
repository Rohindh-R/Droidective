# Droidective

A native macOS companion for Android and React Native debugging. One-click adb
actions in a Raycast-style command palette — no terminal required.

Built in Swift 6 + SwiftUI, with all logic in a platform-agnostic Swift package
(`ADBKit`) so the engine stays testable and a future cross-platform port only
needs a new UI layer.

> Requires macOS 14+ and the Android `adb` tool. Ad-hoc signed (not notarized);
> see [Building](#building) and [Install a release build](#install-a-release-build).

## Features

A searchable palette (`⌘K`) of 37 adb actions, organised by category. Enable
or hide any of them from the in-app catalog.

- **Input & clipboard** — send text (Unicode via ADBKeyboard, auto-offered),
  copy the device's Wi-Fi IP.
- **Connection** — reverse ports, wireless ADB wizard (tcpip + Android 11
  pairing), disconnect, run-on-all fan-out, **emulator manager** (list / launch
  / cold-boot / wipe / stop your Android Studio AVDs).
- **React Native** — dev menu, reload JS, saved deep links per app, simulate
  process death, set dev-server host.
- **Screen & capture** — scrcpy mirroring, screenshots with in-app preview and
  drag-out, screen recording with optional GIF, demo mode.
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
  bug-report zip.
- **Tool UX** — custom adb macros with `{bundleId}`/`{serial}` placeholders,
  feature catalog with favorites, per-feature + global hotkeys, menu-bar quick
  actions.

Every feature has an ⓘ "how it works" note in its toolbar. Files pulled from the
device always ask where to save (default `~/Downloads/Droidective`).

## Requirements

- macOS 14 (Sonoma) or later
- [Android platform-tools](https://developer.android.com/tools/releases/platform-tools)
  (`adb`) — found automatically via `ANDROID_HOME`, `~/Library/Android/sdk`, or
  Homebrew; the app offers a one-click install if it's missing.
- Optional: `scrcpy` (screen mirroring), `ffmpeg` (GIF export), the Android SDK
  `emulator` (AVD management).

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

The app runs **without the App Sandbox** (it must spawn `adb`, `scrcpy`,
`emulator`, and `brew`) and is **ad-hoc signed** for local development.

## Install a release build

Release `.app` zips are attached to each [GitHub release](../../releases) and
built by CI. Because the build is unsigned/unnotarized, macOS Gatekeeper will
quarantine it on first download — clear it once:

```sh
xattr -d com.apple.quarantine "Droidective.app"
```

Or just build from source, which avoids the quarantine entirely.

## Architecture

```
ADBKit/   Swift package — all logic, zero UI dependencies (swift test)
  Exec/         adb process execution, tool location, scoped command log
  Devices/      discovery (2s polling), getprop, hardware/usage overview
  Features/     declarative 37-feature registry + runners + how-to notes
  Services/     logcat streaming, overrides, file/apps explorers, capture,
                screen record, crash, bug report, wireless, emulators…
  Persistence/  JSON stores in ~/Library/Application Support/Droidective
App/      SwiftUI macOS app — command palette, device bar, feature views,
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
licenses; Droidective shells out to them and does not bundle them.
