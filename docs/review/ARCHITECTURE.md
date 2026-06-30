# Architecture

The one rule that everything else serves: **all logic lives in `ADBKit`; `App`
is a thin SwiftUI shell.** The two layers are strictly separated so a future
cross-platform port only re-does the UI. A change that violates this gets sent
back even if it works.

## The layer boundary

**`ADBKit/`** — a SwiftPM package with *zero UI imports*. No `SwiftUI`, no
`AppKit`. Feature icons are SF Symbol *name strings*, not `Image`s. Stateful
services are actors; values crossing concurrency boundaries are `Sendable`
value types; strict concurrency is complete. Testable with `cd ADBKit &&
swift test` — no Xcode, no device.

**`App/`** — the SwiftUI shell. `@Observable @MainActor AppState` consumes
ADBKit. Views render; they don't compute. Built via XcodeGen + xcodebuild; the
`.xcodeproj` is gitignored and regenerated.

### Review checks

- [ ] **No `adb`/`Process` in a view.** Any shelling out goes through an
      `ADBKit` service. A view calling `AdbClient` directly is the most common
      violation — it belongs in a service with a test.
- [ ] **No `import SwiftUI`/`import AppKit` anywhere in `ADBKit/Sources`.** If a
      type needs a color or an icon, it carries a *string* the App layer maps.
- [ ] **No business logic in `AppState` or a view.** Parsing, command
      construction, polling, state machines — all in `ADBKit`. `AppState`
      orchestrates and exposes; it doesn't parse.
- [ ] New logic landed in the right service directory (`Devices/`, `Exec/`,
      `Features/`, `Persistence/`, `Services/<domain>/`). A new domain gets its
      own service, not a new method bolted onto an unrelated one.

## Concurrency shape

- Stateful services are **actors** (`DeviceMonitor`, `ToolLocator`, `CommandLog`,
  the `JSONStore`s). Shared mutable state that isn't an actor is a red flag.
- Types that cross an actor or `Task` boundary are `Sendable` value types
  (structs/enums). Reaching for a `class` or a lock is the exception and needs a
  reason.
- The process runner must **never block a cooperative thread** — this is
  load-bearing, see [CONCURRENCY_AND_PITFALLS.md](CONCURRENCY_AND_PITFALLS.md).

## The feature system

A feature's string `id` is a contract spread across several files —
`FeatureRegistry` (the `FeatureDef`), `FeatureNotes` (how-it-works),
`FeatureCommands` (command reference), `FeatureEngine` (runner dispatch +
`implementedIDs`) for actions, and `FeatureDetailView.detailByKind` + a view in
`App` for view features. **`CLAUDE.md` → "Adding a feature — the checklist" is
the source of truth** for the order and which steps have enforcing tests vs.
silent failure modes.

### Review checks

- [ ] New feature is in `FeatureRegistry` with a stable id, keywords, and a
      hotkey, plus a `FeatureNotes` note and a `FeatureCommands` reference (all
      three have enforcing tests — flag a gap in review so it isn't a CI surprise).
- [ ] **Actions** wire `FeatureEngine.dispatch` *and* `implementedIDs`
      *and* an arg-vector test asserting the exact adb arguments. A feature in
      `implementedIDs` with no dispatch case, or vice versa, is caught by tests —
      but the arg-vector test (correct/quoted arguments) is on the author.
- [ ] **View features** add the `detailByKind` case (a missing case renders
      "Coming Soon" *silently* — no test catches it) and `implementedIDs`.
- [ ] If absorbed by a hub (`react-native`, `simulate`, `connection`,
      `apk-studio`), it's in `absorbedByHub` and its keywords fold into the hub
      (a test enforces the hub matches each member's primary keyword). It must
      not also appear as a standalone catalog/sidebar/search row.
- [ ] `view` features that run adb directly wrap user-initiated calls in
      `CommandLog.userInitiated(feature:)` so the Recent tab works; background
      polling stays out of it.
- [ ] Parsers are **pure and static** (`static func parseX(_:) -> …`, no I/O) so
      they're tested directly.

## When the architecture should bend

It mostly shouldn't. But: a genuinely UI-only concern (a view-model that holds
no logic, a SwiftUI animation helper) belongs in `App`. The test is "could this
run in `swift test` without a UI?" — if yes and it's logic, it's `ADBKit`; if
it's purely presentation, it's `App`. When unsure, put it in `ADBKit` behind a
test.
