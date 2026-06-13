# Contributing to Droidective

Thanks for your interest! This is a SwiftUI macOS app with its logic in a
testable Swift package. Bug reports, feature ideas, and PRs are all welcome.

## Getting set up

```sh
brew install xcodegen
make test     # ADBKit unit tests — no device or Xcode required
make build    # generate the Xcode project + build the app
make run      # build and launch
```

You only need a connected Android device (or emulator) to exercise the live
features — the entire `ADBKit` engine, including every command runner and
parser, is unit-tested with a mocked process runner.

## Architecture, in one rule

All logic lives in **`ADBKit/`** (a SwiftPM package with no UI imports); the
SwiftUI shell lives in **`App/`**. When you add a feature:

1. Put the adb/Process logic in an `ADBKit` service, with a parser/runner test.
2. Add the feature to `FeatureRegistry` and a how-it-works note to `FeatureNotes`.
3. Add the SwiftUI view under `App/Sources/FeatureDetail/Views/`.

Never call `adb`/`Process` directly from a SwiftUI view — go through `ADBKit`.

`CLAUDE.md` documents the key types and the non-obvious conventions (process
threading, CRLF handling, device-shell quoting, `.task(id:)` readiness keys,
empty-state layout). Please skim it before a non-trivial change.

## Before you open a PR

- `make test` is green (`swift test` in `ADBKit`).
- `make build` succeeds with **zero warnings** — the project treats warnings as
  things to fix.
- Add or update tests for parsers and command construction.
- Keep commits focused and in imperative mood (e.g. "Add foo", not "added foo").
- Open the PR against `main` with a short description of what changed and why.

## Reporting bugs

Include your macOS version, the device/emulator and its Android version, the
feature involved, and — if relevant — the adb command from the in-app
**Command Log** (Settings → Data → Command log → View).
