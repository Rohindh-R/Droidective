# Testing

The whole architecture exists to make logic testable without a device:
`ADBKit` is a pure SwiftPM package, run with `cd ADBKit && swift test`. The test
suite is the contract — keep it green and keep it meaningful.

## What must have a test

- **Every parser.** adb/getprop/dumpsys/`/proc` output → structured value. This
  is where bugs live (CRLF, locale, empty output, missing fields).
- **Every command construction.** The exact argv handed to adb, including
  quoting of device-side shell input.
- **Every error path the code handles.** If the code branches on a failure
  (device offline, tool not found, malformed output), a test triggers that
  branch.
- **New feature wiring.** A feature must be in `FeatureRegistry`, have a
  `FeatureNotes` note and a `FeatureCommands` reference, and (if hub-absorbed)
  fold its keywords into the hub — there are tests enforcing each
  (`everyFeatureHasAHowToNote`, `everyFeatureHasACommandReference`,
  `hubsStaySearchableByTheirMembersPrimaryKeyword`, and the feature count). Don't
  remove them to make a PR pass.
- **Action arg-vectors.** An implemented action needs a test asserting the
  *exact* adb argument vector, including the quoted form of any user value
  (see `FeatureEngineTests`, `OverridesServiceTests`). The dispatch/`implementedIDs`
  link is test-guarded; the *arguments* are only as correct as your arg-vector
  test.

## How to test it

- **Mock the boundary, not the logic.** Use `MockProcessRunner` (the
  `ProcessRunning` protocol) to feed canned process output and assert on the
  parsed result and the argv. Don't mock the parser you're testing.
- Mock only what's slow (process/network/filesystem), non-deterministic (time,
  randomness), or external. Pure functions get real inputs.
- **Test behavior, not implementation.** If a refactor that preserves behavior
  breaks a test, the test was asserting on internals — fix the test. Assert on
  what the function returns/does, not which private method it called.
- **Test the edges.** Empty input, a single line, CRLF (`"\r\n"`), missing
  fields, a device that's unauthorized/offline, output in an unexpected locale,
  truncated dumpsys. The happy path is the least interesting test.

## Verify the test actually catches the bug

A test that passes whether or not the code is correct is worse than no test —
it's false confidence. Before relying on a new test: break the code, confirm
the test fails, then fix it. For parsers and serialization especially, this is
non-negotiable.

## What tests do *not* cover

`swift test` runs no UI and talks to no device. It cannot tell you that a view
renders correctly, that a real device produces the output your parser expects,
or that a hotkey fires. Those are verified by **running the app** — see
[UI_UX.md](UI_UX.md) and the PR pre-flight checklist. A green suite is necessary,
not sufficient.

## The process-threading canary

There is a test that runs 16 concurrent processes to guard that
`SystemProcessRunner` never blocks a cooperative thread (see
[CONCURRENCY_AND_PITFALLS.md](CONCURRENCY_AND_PITFALLS.md)). **Don't delete or
weaken it** to make unrelated work pass. If it fails, the runner regressed — fix
the runner.

## Review checklist

- [ ] New parsing/command logic has tests, and they assert on behavior.
- [ ] Edge and error cases are covered, not just the happy path.
- [ ] Mocks are at boundaries only; the thing under test isn't mocked.
- [ ] No enforcement test (FeatureNotes, hub keywords, the 16-process canary) was
      removed or hollowed out to go green.
- [ ] If the change is a bug fix, there's a test that fails without the fix.
