# Quartz updates

Installed releases check for new versions hourly while Quartz is open. When an
update is available, the browser's update button downloads, verifies, installs,
and relaunches Quartz. Downloads are validated with the Ed25519 public key
embedded in the installed app before extraction. The appcast itself is also
signed. Updates do not bypass macOS permissions or replace a running app by
executing a downloaded shell script.

The first version containing this updater must be installed once. Earlier Quartz
versions cannot acquire the updater automatically. Development packages built
without a public key explain that in-app installation is unavailable.

## One-time repository configuration

No paid Apple Developer account is required. Run the one-time setup helper from
an authenticated GitHub CLI session with access to the Quartz repository:

```sh
Scripts/setup-update-signing.sh
```

It creates or reuses Quartz's dedicated Ed25519 signing key in the macOS Keychain
and configures the repository's **Actions secret** `SPARKLE_PRIVATE_KEY` and
**Actions variable** `SPARKLE_PUBLIC_KEY`. It refuses to replace an existing,
unrecognized configuration. The private key is transferred through standard
input, never committed to the repository. The public key is embedded in every
released app.

Back up the Keychain signing key securely before distributing the first updater
release. Reuse the same key for all subsequent versions. Changing the key on each
build prevents installed copies from verifying their updates. The release script
rejects missing keys and mismatched public/private keys before semantic-release
creates a tag or publishes a release.

| Setting | GitHub configuration | Purpose |
| --- | --- | --- |
| `SPARKLE_PRIVATE_KEY` | Secret, required | Base64 private key exported by Sparkle; supplied to signing tools through standard input |
| `SPARKLE_PUBLIC_KEY` | Variable, required | Base64 public key embedded in every distributable app |

Releases use free Ed25519 update signing and ad-hoc application signatures.
macOS may still show its unverified-developer warning on the first download.
Developer ID signing and notarization could remove that initial warning in a
future release process, but neither is required or configured by this updater.

The initial installation should be moved into `/Applications` or
`~/Applications`. A read-only disk image, macOS app translocation, or a location
owned by another user can require moving the app or macOS authorization. Sparkle
handles installation and relaunch; Quartz retains its existing application
support data and session restoration.

## Automatic releases

Conventional Commits on `main` continue to drive semantic-release. The release job
runs the Swift tests, builds a universal app with the pinned Sparkle framework,
signs nested helper executables before their containing bundles, and verifies
code signatures. It then signs the final ZIP and appcast and independently verifies
the archive against the app's embedded public key.

Every release contains:

- `Quartz-vVERSION-macos-universal.zip`
- `appcast.xml`
- `SHA256SUMS`

The feed URL embedded in the app is
`https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml`.
Each update in it points to the corresponding versioned GitHub ZIP. The previous
signed appcast is retained and updated, keeping compatible releases when macOS
requirements change. A 404 is accepted when bootstrapping the first feed; other
fetch failures stop publication. Existing feeds must verify with the release
key. Delta updates are disabled so release artifacts remain self-contained.

The GitHub plugin uploads all assets to a draft release before publishing it.
Asset paths use real glob patterns because semantic-release does not expand
`${nextRelease.gitTag}` in a local asset path. After publication, the workflow
downloads all assets anonymously, compares them with the prepared bytes, checks
the checksums, verifies the extracted app, and checks the stable latest-feed URL.
Only one release job runs at a time. A failed public-download audit needs review;
it does not delete or rewrite an already published release. Transient network
errors in the browser can be retried with its update button.

## Local verification

Regular local development packages need no secrets:

```sh
ZIP_APP=1 Scripts/package-macos-app.sh
```

Run the release packaging tests without using a real signing key or publishing:

```sh
Scripts/test-update-packaging.sh
```

This generates disposable keys, prepares two universal releases, verifies the
signed appcast and archive, rejects changed bytes and missing keys, and checks
that the next feed retains the previous release. It also runs in pull-request CI.

For a signed local release rehearsal, supply an isolated test private/public key
pair via `SPARKLE_PRIVATE_KEY` and `SPARKLE_PUBLIC_KEY`, then run:

```sh
DIST_DIR=/private/path/rehearsal Scripts/prepare-release.sh 9.8.7
```

The result is under `rehearsal/release`, with the app under
`rehearsal/release-bundle`. `PREVIOUS_APPCAST_FILE` can provide an existing signed
feed for a local retention test; otherwise the canonical feed is fetched. Never
publish a test key or arbitrary test version. For local HTTP update tests only,
packaging supports `SPARKLE_FEED_URL` with `ALLOW_INSECURE_TEST_FEED=1`.
When the public feed exists, an isolated test key must use its own signed
`PREVIOUS_APPCAST_FILE`, because the production feed is signed by a different key.

The independent archive check can also be run directly:

```sh
swift Scripts/verify-update.swift /path/Quartz.app /path/Quartz.zip /path/appcast.xml VERSION DOWNLOAD_URL
```

Complete verification includes a packaged older build discovering and installing
a newer signed build, the restart restoring the session, and rejection of a
tampered archive or signature. Unit tests, bundle signature checks, and generated
feeds alone do not prove this end-to-end behavior. This free release pipeline does not claim Developer ID signing or notarization.

## Signing-key continuity

Back up the update key before the first public updater release. Never change or
remove the embedded public key casually. With pre-extraction validation enabled,
Sparkle's recovery path for a lost Ed25519 key requires a Developer ID signed DMG;
the current ZIP pipeline cannot perform that recovery. A planned key rotation
needs a separate tested migration, not a replacement repository secret alone.

See the official [Sparkle setup](https://sparkle-project.org/documentation/),
[publishing guide](https://sparkle-project.org/documentation/publishing/), and
[helper signing guidance](https://sparkle-project.org/documentation/sandboxing/#code-signing).
