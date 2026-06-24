# Releasing Droidective

Droidective ships as a Developer ID-signed, notarized DMG via GitHub Releases
and a Homebrew cask, and updates itself with
[Sparkle](https://sparkle-project.org). The marketing site and the Sparkle
appcast are both served from GitHub Pages at
`https://droidective.github.io/Droidective/`.

## One-time setup

Do these once. Steps 1–3 are required before the first auto-updating release.

### 1. Generate the EdDSA signing key

Every update is signed with an ed25519 key. The public half is embedded in the
app; the private half signs updates (locally from your Keychain, in CI from a
secret).

```sh
./scripts/fetch-sparkle-tools.sh        # downloads Sparkle's tools to .sparkle/bin
./.sparkle/bin/generate_keys            # creates the key, prints the public key
```

`generate_keys` stores the private key in your **login Keychain** (approve the
prompt) and prints something like:

```
<key>SUPublicEDKey</key>
<string>aB3…long-base64…=</string>
```

Copy that base64 string into `project.yml`, replacing the placeholder:

```yaml
        SUPublicEDKey: aB3…long-base64…=     # was: REPLACE_WITH_OUTPUT_OF_generate_keys
```

Then `make build` (or `xcodegen generate`) so the key lands in `App/Info.plist`.

> **Back this key up.** If you lose the private key, you can't ship updates that
> already-installed copies will trust. Export and store it somewhere safe:
> `./.sparkle/bin/generate_keys -x sparkle-private-key.txt` (then keep that file
> in a password manager, not in git).

### 2. Add the private key as a CI secret

CI signs each release with the same key:

```sh
./.sparkle/bin/generate_keys -x sparkle-private-key.txt
```

In the repo: **Settings → Secrets and variables → Actions → New repository
secret**, name it `SPARKLE_ED_PRIVATE_KEY`, and paste the file's contents. Then
delete the file (`trash sparkle-private-key.txt`).

### 3. Enable GitHub Pages

**Settings → Pages → Build and deployment → Source = GitHub Actions.**

After this, every push to `main` deploys the marketing site and the committed
`site/appcast.xml`. The appcast in `site/` is the single source of truth: the
release job signs a new version's entry and commits it back to `main` (see the
`RELEASE_PUSH_TOKEN` secret below), which re-runs the `pages` job to deploy it.
GitHub Pages only serves deployments from the source branch, so the release must
publish through `main` rather than deploying from its tag ref directly. (Until
Pages is enabled, the `pages` job will fail — that's expected.)

### 4. Developer ID signing and notarization

Release builds are signed with a Developer ID Application certificate and
notarized by Apple, so users get no Gatekeeper warning. Set this up once:

1. **Create a "Developer ID Application" certificate** — Xcode → Settings →
   Accounts → your team → Manage Certificates → ＋. Export it from Keychain
   Access (My Certificates → right-click → Export) as a `.p12` with a password.
2. **Create an App Store Connect API key** (used by `notarytool`) — App Store
   Connect → Users and Access → Integrations → App Store Connect API → generate
   (role *Developer*). Download `AuthKey_XXXX.p8` once; note the Key ID and
   Issuer ID.
3. **Add these repository secrets** (Settings → Secrets and variables → Actions):

   | Secret | Value |
   | --- | --- |
   | `DEVELOPER_ID_CERT_P12` | `base64 -i Cert.p12` |
   | `DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password |
   | `DEVELOPER_ID_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
   | `KEYCHAIN_PASSWORD` | any random string (throwaway CI keychain) |
   | `AC_API_KEY_P8` | `base64 -i AuthKey_XXXX.p8` |
   | `AC_API_KEY_ID` | the key id |
   | `AC_API_ISSUER_ID` | the issuer id |
   | `APPLE_TEAM_ID` | your 10-character team id |

### 4b. Appcast publish token

The release job commits the freshly signed `site/appcast.xml` (its enclosure
carries the Sparkle EdDSA signature) back to `main` via the GitHub contents API.
Add a `RELEASE_PUSH_TOKEN` secret: a fine-grained PAT with *Contents: read and
write* on this repo, owned by the repo admin. `main` is protected (locked,
requires reviews, requires signed commits), and this commit is itself unsigned —
it lands only because the admin PAT bypasses all of those rules, which works
because **"Include administrators" (`enforce_admins`) is off**. Keep it off, or
this step (and the auto-update feed) breaks. Without the token the release still
publishes the DMG, but the appcast won't update.

To build a notarizable DMG **locally**, create `.env.signing` (gitignored):

```sh
SIGN_IDENTITY=Developer ID Application: Your Name (TEAMID)
DEVELOPMENT_TEAM=TEAMID
```

`make dmg` then signs the app — the scrcpy-server and a static ffmpeg already
ship inside it (in `App/Resources/`) — and packages the DMG; notarize the result
with `AC_API_KEY_PATH=… AC_API_KEY_ID=… AC_API_ISSUER_ID=… ./scripts/notarize.sh <dmg>`.
Without `.env.signing`, `make dmg` produces an ad-hoc DMG — fine for testing,
but Gatekeeper still warns.

### 5. Homebrew cask (optional)

Releases publish a cask to a tap repo so users can
`brew install --cask rohindh-r/tap/droidective`.

1. Create an empty public repo **`Rohindh-R/homebrew-tap`**.
2. Add a `HOMEBREW_TAP_TOKEN` secret — a fine-grained PAT with *contents: write*
   on that repo.

The release job renders `Casks/droidective.rb` (version + DMG sha256) and commits
it. Without the token, the cask step is skipped.

### 6. SEO / discoverability (optional but recommended)

On-page SEO is already in `site/index.html` (title, meta description, Open
Graph, Twitter card, JSON-LD `SoftwareApplication`, `sitemap.xml`, `robots.txt`).
Ranking for competitive terms still needs links and time:

- Set the repo's **About → Website** to `https://droidective.github.io/Droidective/`.
- Add the URL to the README and link it from anywhere you can.
- Verify the site in **Google Search Console** (URL-prefix property; use the
  meta-tag method — add the `google-site-verification` tag to `index.html`), then
  submit `sitemap.xml`.
- Earn backlinks: Show HN, r/androiddev, r/reactnative, Product Hunt, and
  "awesome-android" / "awesome-react-native" lists.
- Expect long-tail phrases ("all-in-one Android debugging tool for macOS") to
  land first; head terms like "adb tool" take sustained authority.

### 7. Configure telemetry (optional)

Crash reporting (Sentry) and opt-in analytics (PostHog) stay disabled until you
supply keys. They are **not** committed to source — they're injected at build
time from the `SENTRY_DSN` and `POSTHOG_KEY` build settings into Info.plist
(`project.yml` → `info.properties`), so forks don't report to your projects and
the values can be rotated without a code change. Any build without them leaves
both empty, and neither SDK starts.

- **Sentry** — your DSN (Sentry → Project Settings → Client Keys). Crash +
  performance monitoring; anonymous (no PII); on by default for users, opt-out in
  Settings → Privacy.
- **PostHog** — your project token (starts with `phc_`). Product analytics;
  anonymous (`personProfiles = .never`, never identified); **opt-in only**. The
  host is hardcoded to the US endpoint in `TelemetryConfig.swift` — change it
  there if you're on EU.

**For CI release builds:** add two repository secrets under **Settings → Secrets
and variables → Actions** — `SENTRY_DSN` and `POSTHOG_KEY`. The `release` job
passes them to `xcodebuild`; the plain PR/`main` `build` job leaves them empty on
purpose (throwaway builds, and fork PRs can't read secrets anyway).

**For local builds:** create `.env.telemetry` (gitignored) in the repo root:

```sh
SENTRY_DSN=https://…@…ingest.sentry.io/…
POSTHOG_KEY=phc_…
```

`make build` / `make dmg` pick it up automatically. Without it, local builds run
with telemetry disabled — fine for development.

Both are client-side write keys, safe to ship in the binary. Users get a one-time
privacy disclosure on first launch, managed afterward in Settings → Privacy.
Analytics sends only the feature id — never device serials, package names, paths,
IPs, or command contents. Sentry owns crash handling (PostHog's `autoCapture` is
off).

## Cutting a release

1. Add a `## Droidective vX.Y.Z` section to the top of `RELEASE_NOTES.md`.
2. Tag and push:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

CI (the `release` job) then:

- builds Release with `MARKETING_VERSION=X.Y.Z` and `CURRENT_PROJECT_VERSION=`
  the GitHub Actions run number (Sparkle compares this monotonically increasing
  `CFBundleVersion`);
- signs the app — with the scrcpy-server and ffmpeg bundled inside it — with the
  Developer ID, and packages `Droidective-vX.Y.Z.dmg`;
- notarizes the DMG with Apple and staples the ticket;
- publishes the GitHub release with that DMG and the latest release notes;
- signs the stapled DMG with the EdDSA key and commits the regenerated
  `site/appcast.xml` to `main`;
- updates the Homebrew cask.

That commit to `main` re-runs the `pages` job, which deploys the site and the
new appcast to GitHub Pages. Installed copies then pick up the new appcast and
offer the update automatically.

> **First Sparkle release:** existing v2.0.0 installs predate Sparkle, so they
> won't auto-update *to* the first Sparkle-enabled build — download that one
> manually. Every release after it updates in place.

## Release checklist

Copy this into the release PR and tick each item.

### Prepare (on the feature branch)

- [ ] `cd ADBKit && swift test` is green (no skips).
- [ ] `make build` is clean — zero warnings.
- [ ] App runs and the changed features are verified live against a device or emulator.
- [ ] Bump `MARKETING_VERSION` in `project.yml` to the new `X.Y.Z`.
- [ ] Add a `## Droidective vX.Y.Z` section to the top of `RELEASE_NOTES.md` (summary, New features, Improvements, Install). Plain, factual language — no superlatives.
- [ ] Feature counts updated if they changed: registry total in `README.md` and `CLAUDE.md`, marketing count in `site/index.html`.
- [ ] Screenshots refreshed if the UI changed: `site/assets/screenshot-home.png` and `screenshot-catalog.png` (1512×948 window → 3024×1896 @2× Retina; Dock hidden; default layout — nothing pinned/collapsed).
- [ ] `README.md`, `CLAUDE.md`, and `docs/` updated for new features or changed behavior.
- [ ] Diff re-read for leftover debug/seed/temp code, dead code, and unclear naming; nothing agent-only (`.claude/`) committed.

### Land

- [ ] Branch pushed; PR opened against `main` describing what changed (factual).
- [ ] PR reviewed and merged to `main`.

### Release (CI does the build — triggered by the tag)

- [ ] Tag from `main` and push: `git tag vX.Y.Z && git push origin vX.Y.Z`.
- [ ] The Actions `release` job succeeds: builds Release with `MARKETING_VERSION=X.Y.Z` (scrcpy-server + ffmpeg ship inside the app), signs with the Developer ID, packages `Droidective-vX.Y.Z.dmg`, notarizes + staples it, signs it with the Sparkle EdDSA key, updates the Homebrew cask, publishes the GitHub release with the DMG + latest notes, and commits the regenerated `site/appcast.xml` to `main`.
- [ ] The follow-up `pages` run (triggered by that appcast commit) deploys the site + appcast to GitHub Pages.

### Verify (post-release)

- [ ] GitHub release page shows the right version, the notes, and a downloadable DMG.
- [ ] Fresh download launches cleanly: mount the DMG, drag to `/Applications`, open — no Gatekeeper warning. `spctl -a -vvv -t install Droidective-vX.Y.Z.dmg` reports *accepted, source=Notarized Developer ID*.
- [ ] `brew install --cask rohindh-r/tap/droidective` installs the new version.
- [ ] `https://droidective.github.io/Droidective/` shows the new screenshots and copy.
- [ ] `https://droidective.github.io/Droidective/appcast.xml` lists the new version with a valid `sparkle:edSignature`.
- [ ] A prior install (v2.1.0+) offers the update via Sparkle and applies it in place.
- [ ] Repo **About → Website** still points at the Pages URL.

## Mac App Store builds

Not a supported target. The Mac App Store mandates the App Sandbox, which forbids
spawning external executables — and Droidective's whole job is driving `adb`,
the bundled `ffmpeg`, the Android `emulator`, and `brew` (and pushing the
scrcpy-server to the device). The emulator additionally needs a
hypervisor entitlement the App Store doesn't grant. So Droidective is distributed
only as a Developer ID-signed, notarized build.

The `#if !APPSTORE` guard around Sparkle is kept (a self-updater couldn't ship in
a MAS build anyway), but there is no MAS build to produce.
