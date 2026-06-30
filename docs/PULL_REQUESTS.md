# Pull Requests

How to take a change from idea to a merged PR. The goal is a PR that a reviewer
can understand and verify quickly, against a green CI and a warning-free build.

## 1. Scope a PR

One PR = one logical change. If you can't describe it in a single sentence
without "and", it's probably two PRs.

- A feature, a bug fix, a refactor, and a docs change are four PRs, not one.
- Refactors that touch many files should land *separately* from behavior
  changes — mixing them hides the real diff from review.
- If a change grows past what one sitting can review (~400 lines of real diff is
  a soft signal, not a rule), split it or call out in the description why it
  can't be split.

## 2. Branch

Never push to `main`. Branch from an up-to-date `main`:

```sh
git fetch origin
git switch -c <type>/<short-slug> origin/main
```

`<type>` is one of `feat`, `fix`, `refactor`, `docs`, `chore`, `test`, `perf`.
Example: `feat/rn-devtools`, `fix/logcat-crlf-split`.

## 3. Build the change the project way

The load-bearing rule is the architecture: **all logic in `ADBKit`, UI in
`App`** (see [review/ARCHITECTURE.md](review/ARCHITECTURE.md)).

A feature's string `id` is a contract spread across several files, and most
omissions fail *silently* (a "Coming Soon" screen, an empty Recent tab), not at
compile time. **`CLAUDE.md` → "Adding a feature — the checklist" is the
authoritative step-by-step** — follow it in order rather than working from
memory. In short: define the `FeatureDef` in `FeatureRegistry`, add a
`FeatureNotes` how-it-works note and a `FeatureCommands` reference, then either
wire the runner (`FeatureEngine.dispatch` + `implementedIDs` + an arg-vector
test) for an action, or build the view (`App/Sources/FeatureDetail/Views/` +
`FeatureDetailView.detailByKind` + `implementedIDs`) for a view feature. Several
of those steps have enforcing tests; the silent ones you verify by opening the
feature.

## 4. Commits

- Imperative mood, ≤72-char subject: "Add logcat CRLF guard", not "added" or
  "fixes".
- One logical change per commit. A commit should build and pass tests on its
  own where practical.
- Don't amend or force-push commits already pushed to a shared branch.
- Don't commit secrets, generated artifacts (`*.xcodeproj` is gitignored and
  regenerated), `DerivedData`, or `.env.*` files.

## 5. Pre-flight checklist (run before you open the PR)

This is exactly what the PR template asks you to confirm.

- [ ] `make test` is green (`cd ADBKit && swift test`).
- [ ] `make build` succeeds with **zero warnings** — see the
      [zero-warning policy](review/CODE_QUALITY.md#zero-warnings).
- [ ] New/changed parsers and command construction have tests
      ([review/TESTING.md](review/TESTING.md)).
- [ ] New feature follows the `CLAUDE.md` "Adding a feature" checklist
      (`FeatureRegistry` + `FeatureNotes` + `FeatureCommands`, then runner or
      view wiring).
- [ ] `prek run` passes (the gitleaks secret scan in particular).
- [ ] You ran the app and verified the change live if it touches UI or
      device behavior — tests don't cover rendering or real adb output.
- [ ] No secrets, no `claude`/AI-attribution in committed content, no
      relative-`..` imports, no commented-out code.

## 6. PR description standard

A reviewer should understand the change without reading the diff first. Include:

- **What changed** — describe what the code does *now*. Not the discarded
  approaches, not the journey. Only what's in the diff.
- **Why** — the problem or motivation. Link the issue if there is one
  (`Closes #NN`).
- **Impact area** — what else this could affect: shared services, persistence
  schema, the feature registry, release/signing. See
  [review/IMPACT_ANALYSIS.md](review/IMPACT_ANALYSIS.md).
- **How verified** — `swift test`, build, and what you exercised live (device or
  emulator, Android version, the feature screen). Screenshots/GIF for UI.
- **Risks / follow-ups** — known gaps, anything deferred.

Use plain, factual language. A bug fix is a bug fix — avoid "critical",
"comprehensive", "robust", "elegant". No AI attribution anywhere (no co-author
trailer, no "Generated with…", no "claude" in the body or commits).

## 7. CI gates

Opening a PR runs CI (`.github/workflows/ci.yml`):

- **test** — `swift test` on macOS.
- **build** — `xcodegen generate` + `xcodebuild` Debug with signing disabled.

Both must be green to merge. CI does not run the app or exercise a device, so
live verification is on you (item 6 above). The release pipeline (sign / notarize
/ appcast / cask) runs only on `v*` tags, not on PRs — see `RELEASING.md`.

## 8. Merging

- Open against `main`. Address review comments with new commits (don't
  force-push over a review in progress).
- Keep the branch current with `main` if it drifts; resolve conflicts locally
  and re-run `make test` + `make build`.
- Squash or keep history per the change's shape — but the merged result should
  read as clean, focused commits.
