# Release signing and notarization checklist

Quartz's automated releases use **ad-hoc application signatures** and separate
**Ed25519 signatures** for Sparkle updates. They are not Developer ID signed or
Apple notarized. Ed25519 protects the update feed and archive; it does not establish
an Apple developer identity or satisfy Gatekeeper on a first download.

Use the local checklist for every packaging change. The optional Developer ID
checklist requires an Apple Developer account, a signing identity with its private
key, and notarization credentials. Record unavailable checks as unrun.

## Package settings

Run commands from the repository root. `Scripts/package-macos-app.sh` rebuilds
the destination app, so use a dedicated output directory when retaining artifacts.
Build the pinned universal WebKit engine first with `Scripts/build-webkit.sh`.
See [the engine guide](WEBKIT.md) for prerequisites and architecture selection.
The pinned engine build targets macOS 15.4 using the public SDK; package metadata
and the update feed derive their minimum OS from the built engine.

| Environment variable | Default | Meaning |
| --- | --- | --- |
| `SIGN_IDENTITY` | `-` | Ad-hoc signing; set a Developer ID Application identity for the optional notarized build. |
| `ZIP_APP` | `0` | Set to `1` to create `Quartz.zip` alongside the app. |
| `VERSION` | Contents of `version.txt` | `CFBundleShortVersionString`; numeric `major.minor.patch`. |
| `BUILD_NUMBER` | `VERSION` | `CFBundleVersion`; one to three dot-separated numeric components. |
| `CONFIGURATION` | `release` | Swift build configuration. |
| `DIST_DIR` | Repository `dist/` | App and optional ZIP output directory. |
| `QUARTZ_WEBKIT_PRODUCTS_DIR` | `.build/quartz-webkit/products/Release` | Verified universal products from the locked QuartzBrowser WebKit fork. |
| `SPARKLE_PUBLIC_KEY` | Unset | Existing base64 Ed25519 public key for updater-enabled packages. Without it, in-app updates are unavailable. |
| `SPARKLE_FEED_URL` | Canonical GitHub latest `appcast.xml` URL | HTTPS feed location; see [update setup](UPDATES.md). |

Keep the bundle ID (`org.quartzbrowser.Quartz`), update public key, and version
ordering consistent for public upgrades. The package script also supports
`PRODUCT_NAME`, `BUNDLE_ID`, and `SPARKLE_FRAMEWORK` overrides; normal Quartz
releases use their defaults.

## Local ad-hoc build

- [ ] Record `git rev-parse HEAD`, `git status --short`, `sw_vers`, and
  `swift --version` with the verification results. Use a checkout containing only
  the intended release changes.
- [ ] Run the tests and package into a new directory:

```sh
Scripts/build-webkit.sh
Scripts/quartz.sh test
python3 Scripts/test-webkit-bundle.py
bash -n Scripts/package-macos-app.sh
QUARTZ_DIST="$(mktemp -d -t quartz-local)"
DIST_DIR="$QUARTZ_DIST" SIGN_IDENTITY=- ZIP_APP=1 Scripts/package-macos-app.sh
```

- [ ] Verify the app metadata, nested signatures, and both architectures:

```sh
plutil -lint "$QUARTZ_DIST/Quartz.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$QUARTZ_DIST/Quartz.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$QUARTZ_DIST/Quartz.app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$QUARTZ_DIST/Quartz.app"
codesign --display --verbose=4 "$QUARTZ_DIST/Quartz.app"
xcrun lipo "$QUARTZ_DIST/Quartz.app/Contents/MacOS/Quartz" -verify_arch arm64 x86_64
xcrun lipo "$QUARTZ_DIST/Quartz.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle" -verify_arch arm64 x86_64
"$QUARTZ_DIST/Quartz.app/Contents/MacOS/Quartz" --quartz-webkit-info
"$QUARTZ_DIST/Quartz.app/Contents/MacOS/Quartz" --quartz-webkit-smoke-test
```

The display output should identify an ad-hoc signature. The package script builds
both `arm64` and `x86_64`, embeds the verified WebKit fork, and signs the engine's
frameworks and XPC services before the app. It also signs Sparkle's nested helpers,
preserving the Downloader's entitlements. The engine diagnostic must report
`mode: fork`, `valid: true`, and the framework path inside this app. A successful build or signature
check does not prove launch on both architectures.

- [ ] Test the ZIP and the app extracted from those exact bytes:

```sh
unzip -t "$QUARTZ_DIST/Quartz.zip"
QUARTZ_UNPACKED="$(mktemp -d -t quartz-unpacked)"
ditto -x -k "$QUARTZ_DIST/Quartz.zip" "$QUARTZ_UNPACKED"
codesign --verify --deep --strict --verbose=2 "$QUARTZ_UNPACKED/Quartz.app"
"$QUARTZ_UNPACKED/Quartz.app/Contents/MacOS/Quartz" --quartz-webkit-info
"$QUARTZ_UNPACKED/Quartz.app/Contents/MacOS/Quartz" --quartz-webkit-smoke-test
open "$QUARTZ_UNPACKED/Quartz.app"
```

`Quartz.app` must be at the archive root with its executable, WebKit frameworks,
supporting libraries, XPC services, and Sparkle intact. The diagnostic must load
WebKit from this extracted app, without depending on the original build directory.
Quit any other Quartz process before launching this test copy. Follow the
smoke checklist below.

Gatekeeper rejection is expected for downloaded ad-hoc builds. For a local test
copy whose source you trust, inspect and, if present, remove its quarantine
attribute, then open it again:

```sh
xattr -lr "$QUARTZ_UNPACKED/Quartz.app"
xattr -dr com.apple.quarantine "$QUARTZ_UNPACKED/Quartz.app"
open "$QUARTZ_UNPACKED/Quartz.app"
```

Removing quarantine does not sign or notarize the app. Do not count a launch after
this step as a successful Gatekeeper test for a public notarized build.

## Optional Developer ID and notarized download

This manual path is separate from the current release workflow.
`Scripts/prepare-release.sh` explicitly uses `SIGN_IDENTITY=-`; setting a CI
variable alone does not enable Developer ID signing or notarization there.

- [ ] Install full Xcode and select it for this shell if needed with
  `DEVELOPER_DIR`. Check the available identities with:

```sh
security find-identity -v -p codesigning
xcrun notarytool --version
```

- [ ] Store notarization credentials in Keychain. This command prompts for the
  account/team and app-specific password; do not put passwords into tracked files:

```sh
xcrun notarytool store-credentials quartz-notary
```

- [ ] Replace the example identity with your actual Developer ID Application
  identity and build. `VERSION` and `BUILD_NUMBER` below use the repository version;
  change both when rehearsing a planned release:

```sh
QUARTZ_RELEASE_DIST="$(mktemp -d -t quartz-developer-id)"
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  VERSION="$(cat version.txt)" BUILD_NUMBER="$(cat version.txt)" \
  DIST_DIR="$QUARTZ_RELEASE_DIST" ZIP_APP=1 Scripts/package-macos-app.sh
codesign --verify --deep --strict --verbose=2 "$QUARTZ_RELEASE_DIST/Quartz.app"
codesign --display --verbose=4 "$QUARTZ_RELEASE_DIST/Quartz.app"
unzip -t "$QUARTZ_RELEASE_DIST/Quartz.zip"
```

For an updater-enabled build, also supply the existing `SPARKLE_PUBLIC_KEY` and
intended HTTPS feed when packaging. The script adds hardened runtime and a secure
timestamp for a non-ad-hoc identity. Verify the displayed authority, team,
timestamp, and runtime flag before submission. These are Apple's
[notarization prerequisites](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

- [ ] Submit the ZIP and wait for **Accepted**. Preserve the submission ID, fetch
  its log, and review warnings as well as errors:

```sh
xcrun notarytool submit "$QUARTZ_RELEASE_DIST/Quartz.zip" --keychain-profile quartz-notary --wait
xcrun notarytool log YOUR_SUBMISSION_ID --keychain-profile quartz-notary "$QUARTZ_RELEASE_DIST/notary-log.json"
```

If the result is invalid or pending, resolve it before continuing. Follow Apple's
[command-line notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

- [ ] Staple to the app, validate the ticket, then make a **new ZIP from the
  stapled app**. A ZIP itself cannot be stapled; the pre-submission ZIP does not
  acquire the app's ticket automatically:

```sh
xcrun stapler staple "$QUARTZ_RELEASE_DIST/Quartz.app"
xcrun stapler validate "$QUARTZ_RELEASE_DIST/Quartz.app"
codesign --verify --deep --strict --verbose=2 "$QUARTZ_RELEASE_DIST/Quartz.app"
spctl --assess --type execute --verbose=4 "$QUARTZ_RELEASE_DIST/Quartz.app"
ditto -c -k --norsrc --keepParent "$QUARTZ_RELEASE_DIST/Quartz.app" "$QUARTZ_RELEASE_DIST/Quartz-notarized.zip"
unzip -t "$QUARTZ_RELEASE_DIST/Quartz-notarized.zip"
```

- [ ] Extract that final ZIP into a new location and verify it again:

```sh
QUARTZ_NOTARIZED_TEST="$(mktemp -d -t quartz-notarized-test)"
ditto -x -k "$QUARTZ_RELEASE_DIST/Quartz-notarized.zip" "$QUARTZ_NOTARIZED_TEST"
codesign --verify --deep --strict --verbose=2 "$QUARTZ_NOTARIZED_TEST/Quartz.app"
xcrun stapler validate "$QUARTZ_NOTARIZED_TEST/Quartz.app"
spctl --assess --type execute --verbose=4 "$QUARTZ_NOTARIZED_TEST/Quartz.app"
shasum -a 256 "$QUARTZ_RELEASE_DIST/Quartz-notarized.zip"
open "$QUARTZ_NOTARIZED_TEST/Quartz.app"
```

Gatekeeper should accept the extracted app as notarized Developer ID software.
Also download the final distribution through a browser on a clean macOS test
account or machine and launch it with quarantine intact. Test offline launch to
exercise the stapled ticket. Do not remove quarantine for this verification.

## Packaged-app smoke test

- [ ] Run `--quartz-webkit-info` against the extracted app and record its fork
  revision, loaded framework path, and minimum macOS version.
- [ ] Run `--quartz-webkit-smoke-test` against that app. It checks offline HTML
  layout and JavaScript in an isolated nonpersistent web view with a 45-second
  timeout. This exercises the host architecture; it is not an Intel hardware test.
- [ ] Load a real HTTPS page, execute JavaScript, and inspect the app's WebContent,
  Networking, and GPU processes. A passing framework-path diagnostic alone does
  not establish that the engine's child processes work.
- [ ] Confirm the native window opens; use the address field, back/forward, and
  Home. Relaunch after visiting a page and check session restoration.
- [ ] Exercise the behavior changed in the release, including an ordinary page,
  an error path, and opening/closing a browser window.
- [ ] On macOS 15.4+, install the [Hello Quartz extension](extensions.md), open
  its popup, and verify it remains available after restarting.
- [ ] Test on Apple Silicon and Intel hardware when available. Record separately
  any Intel run under Rosetta and any unrun hardware/OS combinations.
- [ ] For updater-enabled releases, verify discovery, download, installation,
  restart, session restoration, and rejection of a tampered update as described
  in [update verification](UPDATES.md#local-verification).

## Automated release boundary

Conventional Commits merged into `main` drive `.github/workflows/release.yml` and
`release.config.cjs`. The workflow selects Xcode 26.6 on `macos-26`, restores
verified products from an exact engine/toolchain cache key or builds the locked
fork, and runs the tests against that engine. It prepares a universal ad-hoc app
with the engine embedded, signs the frozen ZIP and appcast with the existing Sparkle
key, publishes them with `SHA256SUMS`, and verifies fresh public downloads.

System-WebKit development mode is rejected by normal release preparation. The
updater test script's `QUARTZ_TEST_SYSTEM_RELEASE=1` exception is only for
disposable fixtures; the hosted release job does not select the system engine.
An uncached fork build can be lengthy. A workflow definition or a successful
fixture test is not evidence of a completed engine build or published release;
record actual hosted and packaged runtime results before release approval.

The version-specific downloads must match the prepared release assets exactly.
The public `releases/latest/download/appcast.xml` route can briefly serve the
previous feed after publication, so verification retries that exact URL up to
12 times, waiting 10 seconds between attempts. It succeeds only when the feed
matches the version-specific appcast byte for byte. Persistent mismatches and
download failures still fail the job. `Scripts/test-published-feed.sh` checks
propagation, download failures, and retry exhaustion without network access.

If publication succeeds but public verification fails, use **Actions > release >
Run workflow** and set `verify_version` to the published version (for example,
`0.14.0`). This runs a read-only verification job: it obtains reference assets
through the GitHub API, downloads them again through the public URLs, and checks
checksums, the latest-feed route, application signatures, version, and update
archive signature. It does not rebuild, replace, or publish release assets.
The requested version must still be the latest release. Leave `verify_version`
empty for a normal release run. Simply rerunning the original release job can
skip public verification when semantic-release finds no new version to publish.

- [ ] Run `Scripts/test-update-packaging.sh` for changes to that pipeline; it uses
  disposable update keys. See [update setup](UPDATES.md) for production key setup.
- [ ] Check the release job and the public-download audit, not just the tag.
- [ ] If adding notarization to this pipeline, complete Developer ID signing,
  notary submission, stapling, and rearchiving **before** Sparkle signs the ZIP,
  generates the appcast, and writes checksums. Replacing a signed release ZIP
  afterward invalidates its update signature and checksums.
- [ ] Keep the exact final bytes, checksums, source revision, test results, and
  (when applicable) notarization ID/log. Distinguish local packaging, hardware
  smoke tests, Gatekeeper acceptance, and public-download verification in the
  release record.
