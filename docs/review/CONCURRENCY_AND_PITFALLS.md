# Concurrency & Pitfalls

The bug traps this codebase has already paid for. Each one caused a real defect;
each is a thing to actively check in review, not just be vaguely aware of. If a
PR touches the area, confirm it didn't re-open the trap.

## The process runner must never block a cooperative thread

`SystemProcessRunner` uses `terminationHandler` + `readabilityHandler` — **not**
`waitUntilExit()`. A blocking `waitUntilExit` starves the Swift concurrency
thread pool and freezes the whole app under load.

- A 16-concurrent-process canary test guards this. Don't regress it.
- Review check: any new process-spawning code path must be non-blocking. A
  `waitUntilExit`, a synchronous `Data(contentsOf:)` on a pipe, or a semaphore
  wait inside an async context is a defect.

## `"\r\n"` is ONE Swift Character

Splitting adb/emulator/console output on `"\n"` silently fails on CRLF — you get
one giant line and the parser returns nothing or garbage. Use
`.components(separatedBy: .newlines)`.

- Review check: any `.split(separator: "\n")` / `.components(separatedBy: "\n")`
  on device output is suspect. There should be a CRLF test.

## Cancellation kills the child

`SystemProcessRunner.run` wraps its body in `withTaskCancellationHandler`, so
cancelling the calling `.task` (navigation away, a `.task(id:)` re-key)
terminates the adb child instead of orphaning it until timeout. Keep
long-running adb work in a cancellable `Task` so this fires.

- Review check: new long-running adb work runs inside a cancellable `Task`, not
  detached or fire-and-forget.

## Device-side shell quoting (the security boundary)

Anything going through `adb shell` is joined with spaces and run by the device's
`sh`. **Every** user-controlled value — path, URL, SSID, hostname, proxy,
locale, free text — **must** go through `shellQuote()`. A missing `shellQuote`
is command injection, not just a breakage. Caller-side validation (e.g. a
`host:port` check) is UX, not security — don't rely on it to reject
metacharacters.

- `adb push`/`pull`/`exec-out` use the sync protocol — no shell, no quoting.
  Don't quote those; double-quoting breaks them.
- There's no linter for this. Add an arg-vector test asserting the **quoted**
  form (see `OverridesServiceTests`).
- Review check: new `adb shell` arguments built from variable data are quoted
  and have a test; new push/pull/exec-out paths are not quoted.

## `.task(id:)` keys must include readiness

A `.task(id:)` keyed only on a device serial won't re-fire when a device goes
from unauthorized → authorized (same serial, new state). Key on readiness too
(e.g. `targetSerials.first`). And guard `!Task.isCancelled` before writing a
fetched result into `@State` — a cancelled task writing stale data is a classic
race.

- Review check: device-dependent `.task(id:)` includes a readiness component;
  async results are cancellation-checked before assignment.

## CommandLog discipline

The Recent tab filters `CommandLog` by feature id.

- A `view` feature that runs adb directly must wrap **user-initiated** calls in
  `CommandLog.userInitiated(feature: <id>)`, or its Recent tab stays empty.
- Background polling must stay **out** of that scope — wrapping it floods the log.
- Review check: new user actions are wrapped; new polling loops are not.

## SwiftUI layout traps (also see UI_UX.md)

- Empty states under a toolbar need `.frame(maxWidth/maxHeight: .infinity)` or
  the VStack centers and the toolbar floats mid-window.
- `HSplitView` ignores SwiftUI safe-area insets (NSSplitView-backed) — content
  renders under the device bar. Use a plain HStack split.
- The ⌘=/⌘- zoom is a `scaleEffect` on RootView, bypassed at 1.0× (the transform
  breaks `.help` tooltips and hover/chart selection underneath). Don't "simplify"
  it into always-on.

## Persistence safety

`JSONStore` writes atomically and sets aside a corrupt file as `.corrupt` rather
than crashing. Don't replace it with a naive write. A new persisted type goes
through a `Stores` entry, not ad-hoc file I/O. See
[IMPACT_ANALYSIS.md](IMPACT_ANALYSIS.md) for schema-change blast radius.

## Review checklist

- [ ] No blocking call in an async/process path; the canary test still passes.
- [ ] Device output is newline-split with `.newlines`, with a CRLF test.
- [ ] `adb shell` args quoted with `shellQuote()`; push/pull paths not quoted.
- [ ] `.task(id:)` keys include readiness; async writes are cancellation-guarded.
- [ ] User actions wrap `CommandLog.userInitiated`; polling does not.
