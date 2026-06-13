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
