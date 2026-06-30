<!--
PR guidelines: docs/PULL_REQUESTS.md
Describe what the code does NOW — not discarded approaches. Plain, factual
language. No AI attribution (no co-author trailer, no "Generated with…").
-->

## What changed

<!-- One or two sentences. What does the code do now? -->

## Why

<!-- The problem or motivation. Closes #NN if applicable. -->

## Impact area

<!-- What else could this affect? Delete the lines that don't apply. -->

- [ ] Shared `ADBKit` service used by other features
- [ ] `FeatureRegistry` / `FeatureNotes` / hub membership
- [ ] Persisted state schema (`Persistence/`, `~/Library/Application Support/Droidective/`)
- [ ] Bundled tools / release / signing / appcast
- [ ] None — isolated to one feature

## How verified

<!-- swift test + build, and what you exercised live. Screenshots/GIF for UI. -->

- [ ] `make test` green
- [ ] `make build` succeeds with **zero warnings**
- [ ] Ran the app and verified live (device/emulator + Android version): …

## Checklist

- [ ] Logic lives in `ADBKit`, not in a SwiftUI view
- [ ] New parsers / command construction are tested
- [ ] New feature registered in `FeatureRegistry` **and** has a `FeatureNotes` entry
- [ ] `prek run` passes (gitleaks secret scan)
- [ ] No secrets, no commented-out code, no relative `..` imports, no AI attribution
