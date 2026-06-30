# Security

Droidective is an **open-source, public repo** that spawns local tools (adb,
scrcpy, emulator, ffmpeg, brew) and runs commands against a connected device. The
threat model is small but real: leaked secrets in git history, shell injection
through device-side commands, and unsafe file operations on the user's machine.

## Secrets — the public-repo rule

Never commit credentials, API keys, tokens, or DSNs. This repo is public; a
committed secret is a leaked secret even after a later removal.

- Telemetry keys (Sentry DSN, PostHog key) are **build-time injected**:
  Info.plist ← build settings ← CI secrets / a gitignored `.env.telemetry`.
  Signing config comes from a gitignored `.env.signing`. They are never in
  source.
- A **gitleaks** pre-commit hook (`.pre-commit-config.yaml`, `.gitleaks.toml`)
  blocks staged secrets. Install it: `prek install`. CI/contributors rely on it —
  don't disable it to push.
- Review check: no DSN/key/token literal in the diff; no `.env.*` file staged;
  `prek run` passes.

## On-device command injection

Everything through `adb shell` is joined with spaces and run by the device's
`sh`. **Every** user-controlled value (path, URL, SSID, hostname, proxy, locale,
package name, free text) **must** go through `shellQuote()`. This is the security
boundary — caller-side validation (a `host:port` check) is UX, not security, and
must not be relied on to reject metacharacters.

- `adb push`/`pull`/`exec-out` use the sync protocol (no shell) — don't quote
  those.
- There's no linter for this; a missing `shellQuote` is command injection. Add
  an arg-vector test asserting the quoted form (see `OverridesServiceTests`).
- Review check: any `adb shell` argument built from a variable is quoted and
  tested; a new command path that interpolates user/device data without quoting
  is a defect. See [CONCURRENCY_AND_PITFALLS.md](CONCURRENCY_AND_PITFALLS.md).

## Secrets handed to local tools

The APK toolchain shells out to signing tools. A keystore password must reach
`apksigner` via a **0600 temp file, never argv** (argv is world-readable via
`ps`) — `ApkSigningService` does this; a new code path that puts a credential on
a command line is a defect.

## Downloaded tools (provenance)

`ManagedToolStore` downloads jadx, apktool, uber-apk-signer, frida, and a Temurin
JRE from their GitHub releases into `Application Support/tools`. It **verifies
the asset digest** before extracting and version-tracks each tool.

- Review check: a new managed tool verifies its download digest before use;
  download URLs point at the expected upstream release, not a mutable redirect.

## File operations

The app reads and writes the user's filesystem (pulls, screenshots, recordings,
exports, persisted state).

- Pulls/saves go to a user-chosen location (`askSaveLocation`/`askSaveFolder`),
  defaulting to `~/Downloads/Droidective` — don't write to arbitrary paths
  without asking.
- Persisted state writes atomically via `JSONStore` and quarantines corrupt
  files — don't bypass it with raw writes that can truncate user data on crash.
- Don't widen what the app touches on disk without reason; the sandbox is off
  (it must spawn external tools), so there's no OS backstop — the code is the
  backstop.

## External tools & supply chain

- The app resolves adb/scrcpy/brew/ffmpeg/emulator via `ToolLocator`. Don't add a
  new external binary dependency without justification — each is attack surface.
- Bundled binaries (scrcpy-server, static ffmpeg) are refreshed by a script and
  versioned in one place (`BundledTools`); a new or bumped binary is reviewed for
  provenance (GPLv3 ffmpeg is noted in `THIRD_PARTY_NOTICES.md`).
- New SwiftPM dependencies need a reason — justify the addition, not just the
  feature it enables.

## No AI attribution

Unrelated to security but enforced repo-wide and easy to leak into a commit:
zero AI attribution in committed content — no co-author trailer, no "Generated
with…", no "claude" in commit messages, PR bodies, or source. Check the diff and
the commit messages.

## Review checklist

- [ ] No secrets, keys, tokens, or `.env.*` in the diff; `prek`/gitleaks passes.
- [ ] `adb shell` arguments from variable data are `shellQuote()`d.
- [ ] File writes go to asked/known locations and through `JSONStore` for state.
- [ ] No new external binary or SwiftPM dependency without justification.
- [ ] No AI attribution in commits, PR body, or source.
