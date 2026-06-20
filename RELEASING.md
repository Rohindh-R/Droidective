# Releasing Droidective

Droidective ships as a notarization-free DMG via GitHub Releases and updates
itself with [Sparkle](https://sparkle-project.org). The marketing site and the
Sparkle appcast are both served from GitHub Pages at
`https://rohindh-r.github.io/Droidective/`.

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

After this, every push to `main` deploys the marketing site, and each release
deploys the site plus a freshly signed appcast. (Until Pages is enabled, the
`pages` job and the release's deploy step will fail — that's expected.)

### 4. SEO / discoverability (optional but recommended)

On-page SEO is already in `site/index.html` (title, meta description, Open
Graph, Twitter card, JSON-LD `SoftwareApplication`, `sitemap.xml`, `robots.txt`).
Ranking for competitive terms still needs links and time:

- Set the repo's **About → Website** to `https://rohindh-r.github.io/Droidective/`.
- Add the URL to the README and link it from anywhere you can.
- Verify the site in **Google Search Console** (URL-prefix property; use the
  meta-tag method — add the `google-site-verification` tag to `index.html`), then
  submit `sitemap.xml`.
- Earn backlinks: Show HN, r/androiddev, r/reactnative, Product Hunt, and
  "awesome-android" / "awesome-react-native" lists.
- Expect long-tail phrases ("all-in-one Android debugging tool for macOS") to
  land first; head terms like "adb tool" take sustained authority.

### 5. Configure telemetry (optional)

Crash reporting (Sentry) and opt-in analytics (PostHog) stay disabled until you
add keys in `App/Sources/Telemetry/TelemetryConfig.swift`:

- **Sentry** — paste your DSN (Sentry → Project Settings → Client Keys) into
  `sentryDSN`. Crash + performance monitoring; anonymous (no PII); on by default
  for users, opt-out in Settings → Privacy.
- **PostHog** — paste your project token (starts with `phc_`) into `postHogKey`
  and set `postHogHost` to your region (`us` or `eu`). Product analytics;
  anonymous (`personProfiles = .never`, never identified); **opt-in only**.

Both are client-side write keys, safe to ship in the binary; with the
placeholders left in place neither SDK starts. Users get a one-time privacy
disclosure on first launch, managed afterward in Settings → Privacy. Analytics
sends only the feature id — never device serials, package names, paths, IPs, or
command contents. Sentry owns crash handling (PostHog's `autoCapture` is off).

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
- packages and ad-hoc-signs `Droidective-vX.Y.Z.dmg`;
- publishes the GitHub release with that DMG and the latest release notes;
- signs the DMG with the EdDSA key and writes `appcast.xml`;
- deploys the site + appcast to GitHub Pages.

Installed copies pick up the new appcast and offer the update automatically.

> **First Sparkle release:** existing v2.0.0 installs predate Sparkle, so they
> won't auto-update *to* the first Sparkle-enabled build — download that one
> manually. Every release after it updates in place.

## Mac App Store builds

Sparkle is wrapped in `#if !APPSTORE` (App Store apps update through the App
Store and can't bundle a self-updater). For a MAS build:

- add `APPSTORE` to `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, and
- remove the `Sparkle` package + dependency from `project.yml`.

Everything Sparkle-related then compiles out cleanly.
