# Impact Area Analysis

Most defects in a mature app aren't in the lines you changed — they're in the
thing downstream of the lines you changed. Before approving, ask: *what else
consumes this?* This doc is the map of the high-blast-radius areas and how to
reason about them.

## How to do an impact pass

1. Find the callers. For a changed `ADBKit` type, who imports it? A change to a
   shared service (`AdbClient`, `ToolLocator`, `DeviceMonitor`, a parser) ripples
   to every feature that uses it.
2. Ask what state it touches: in-memory only, or persisted to disk?
3. Ask what it's part of: a single feature, the registry, the release pipeline?
4. The PR description must name the impact area (the template has a section). If
   it says "isolated to one feature", verify that's true — grep the type's
   callers.

## High-blast-radius areas

### Shared `ADBKit` services

`AdbClient`, `ToolLocator`, `DeviceMonitor`, `CommandLog`, and the per-domain
services are used across many features. A behavior change here (argv shape,
result structure, polling cadence, error semantics) affects all of them.

- Changing `AdbResult` handling, the device poll interval, or tool resolution
  order is **never** a one-feature change. Check every consumer.

### Persisted state (`Persistence/` + `Stores`)

State lives in `~/Library/Application Support/Droidective/*.json` via
`JSONStore`. A schema change to a persisted type hits **existing users'
on-disk data**.

- Adding a field: ensure decoding tolerates its absence in old files
  (optional / default). `JSONStore` quarantines a file it can't decode as
  `.corrupt` — that means *silent data loss for the user* if you break the
  schema. Verify old data still loads.
- Renaming/removing a field is a migration, not an edit. There's precedent:
  `LayoutState.adoptAllEnabled()` (one-time) and `adoptNewDefaults()` (auto-enable
  newly-shipped features via `knownIds`). A new persisted change needs the
  equivalent thought.
- **Test it with real data** — `HOME=` does not sandbox this; launching can read
  and rewrite the real files. Back up the JSON before first-run/layout/role tests.

### The feature registry

`FeatureRegistry` is consumed by the sidebar, search, the ⌘K palette, the
catalog count, hotkeys, hub absorption, and `FeatureEngine` dispatch. Adding or
moving a feature touches all of them.

- A new feature must be enabled-by-default (the catalog is opt-*out*),
  hotkey-able, noted, searchable, and — if hub-absorbed — filtered from the
  standalone display surfaces. Several tests enforce slices of this; the impact
  is wider than the one file you edited.
- Changing `catalogFeatureIDs` / `absorbedFeatureIDs` / `defaultEnabledIDs`
  changes the Home "All N features" count and what existing users see.

### Bundled tools & release pipeline

scrcpy-server and the static ffmpeg are bundled in `App/Resources/`, versioned by
`BundledTools`, refreshed by `scripts/update-bundled-tools.sh`. The release path
(sign → notarize → DMG → appcast → Homebrew cask) runs on `v*` tags.

- Touching bundled binaries, signing, the appcast, or `RELEASING.md` affects
  *distribution*, not just the build. Read `RELEASING.md`; a broken appcast
  breaks auto-update for every existing install.
- The appcast in `site/appcast.xml` is the single source of truth and is
  committed back to `main` by the release job — don't hand-edit it in a feature
  PR.

## Review checklist

- [ ] Callers of any changed shared type were checked, not assumed.
- [ ] Persisted-schema changes load old on-disk data (or carry a migration).
- [ ] Registry changes account for sidebar/search/palette/hotkeys/count/hubs.
- [ ] Release/bundled/appcast changes were weighed against `RELEASING.md`.
- [ ] The PR's stated impact area matches what the diff actually reaches.
