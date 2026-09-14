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

## Stable and beta channels

In a release containing the selector, choose **Quartz > Update Channel: Stable >
Beta** to receive compatible beta updates as well as newer stable releases.
Stable is the default. The preference persists across launches and remains
separate from **Automatically Check for Updates**. Downloads and installation
still require **Update & Restart**.

Choose **Update Channel: Beta > Stable** to stop receiving betas. Quartz clears
an excluded pending beta and waits for a newer compatible stable; it does not
downgrade the installed app. Channel choices are disabled during extraction and
installation. **About Quartz** displays the full installed label, such as
`1.1.0-beta.2`, independently of the chosen future update channel.

The [beta update manual](BETA_UPDATES.md) documents the user behavior, release
branches, version ordering, signed feed, recovery, and rollout checklist. Its
rollout checklist and release records distinguish deployed behavior from local
validation and installation checks.

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

## Deliberately requested releases

Maintainers start publication with **Actions > release > Run workflow**. Select
Quartz **main** for stable or **beta** for a beta prerelease. Ordinary pushes and
merges do not publish; CI still runs for pull requests and both release branches.
Conventional Commits and the selected branch determine semantic-release's version.

Leave `engine_revision` empty to retain that branch's committed engine pin, or
select a full forward fork SHA. Both explicit and retained pins must belong to
WebKit `main` for stable or WebKit `quartz-dev` for beta. No release follows an
engine branch tip automatically. See the [engine maintenance manual](WEBKIT_MAINTENANCE.md)
and [beta release procedure](BETA_UPDATES.md#publish-a-beta).

Every stable or beta release contains:

- `Quartz-vVERSION-macos-universal.zip`
- `appcast.xml`
- `SHA256SUMS`

`VERSION` is the full label, including `-beta.N` for a beta. The package preserves
that label in `QuartzReleaseVersion`, stores a numeric base in
`CFBundleShortVersionString`, and derives an ordered numeric `CFBundleVersion`
using [release-version.py](../Scripts/release-version.py). Omit `BUILD_NUMBER`
overrides unless they equal that exact derived value. See the
[version table and bounds](BETA_UPDATES.md#version-labels-and-ordering).

### Permanent signed feed

New release packages embed the
[canonical appcast](https://raw.githubusercontent.com/QuartzBrowser/Quartz/update-feed/appcast.xml).
It is `appcast.xml` on the Quartz repository's `update-feed` branch, served as raw
GitHub content. No GitHub Pages site or other website is deployed. Stable items
use Sparkle's default channel; beta items explicitly name `beta`. The native
preference changes allowed channels, not the feed URL or signing key.

The previous signed appcast is retained and updated without removing or altering
existing items. Preparation retrieves the canonical feed first; only its HTTP
404 permits a fallback to the legacy
[latest-stable appcast](https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml).
Other HTTP/network/signature errors stop preparation. Two genuine 404 responses
permit first-feed bootstrap. The release finalizer checks history and the new
item's label/channel before the final feed is signed. Delta updates are disabled.

### Publication and feed activation

The release job validates the application and real pinned engine, prepares a
universal app, verifies code signatures, signs the frozen archive and appcast,
and writes checksums. The GitHub plugin uploads assets to a draft release before
publishing it; beta is a prerelease. Asset paths use real globs because
semantic-release does not expand version expressions in a local asset path.

After publication, the workflow downloads the versioned assets anonymously and
compares them with the prepared bytes and verifies checksums. Using the configured
`SPARKLE_PUBLIC_KEY`, it authenticates the signed feed and archive before ZIP
extraction, then checks the extracted app's code signature, embedded key, and
full release metadata. Only then does
`publish-update-feed.py` verify the existing signed appcast with the public key,
check every currently advertised item is retained unchanged, and fast-forward
the feed branch. A final check verifies the public canonical feed contains the
same signed release item. A newer feed retaining that item is valid; whole-feed
byte equality is required for the versioned asset, not a later combined feed.

Release requests are serialized across stable and beta. A failed feed push does
not remove an already published GitHub release. An old client using GitHub's
latest-stable route may see a stable release before permanent-feed activation.
Inspect each stage instead of treating tag creation as proof of delivery.

### Verification and explicit recovery

`verify_version` uses the configured public key and requests read-only verification of an existing stable or beta
version's immutable assets and the canonical feed. For older bundles that embed
the legacy feed URL, it also verifies that route. Seed the canonical feed before
using this new verification workflow against historical releases. The expected
item must survive unchanged, but it need not be the newest release in the feed.

`activate_version` explicitly retries feed activation for an already published,
verified version. It uses the configured public key, not the private signing key,
and creates no new app release. It refuses to replace a newer feed with an older
snapshot that drops or changes advertised items. If newer history prevents
activation, retain that history and prepare a fresh release when necessary.

Select `main` for stable versions and `beta` for `-beta.N` versions. At most one
of `engine_revision`, `verify_version`, and `activate_version` can be nonempty.
Use a fresh **Run workflow**, not a historical run with older workflow behavior.
The [failure matrix and recovery commands](BETA_UPDATES.md#inspect-and-recover-a-release)
explain the exact boundaries and propagation checks.

### Migration for installed users

The rollout seeds the new branch with the original signed `v1.0.1` stable appcast,
then publishes an initial stable release containing the selector and canonical
feed URL. Existing updater-enabled users discover that stable through the legacy
route and acquire the new behavior by installing it. Earlier versions without
any updater still need a manual installation. This is the rollout procedure,
not evidence that those steps have completed; record the
[migration checks](BETA_UPDATES.md#roll-out-the-channel-support) against real apps.

## Local verification

Regular local development packages need no secrets:

```sh
ZIP_APP=1 Scripts/package-macos-app.sh
```

Run the release packaging tests without using a real signing key or publishing:

```sh
Scripts/test-update-packaging.sh
```

This generates disposable keys and prepares a stable/beta/beta/stable fixture
sequence. It verifies version metadata, channels, signed appcasts and archives,
retained history, tampering/wrong-key rejection, and public verification helpers.
It also runs in pull-request CI. These fixtures do not publish releases or prove
that a user installed an update.

Without prepared products matching the locked fork, explicitly use the system
engine for limited updater/native checks:

```sh
QUARTZ_USE_SYSTEM_WEBKIT=1 Scripts/test-update-packaging.sh
```

The fixture script sets its own test-only release exception. This result applies
to the system engine and host architecture; normal release validation still
requires the actual pinned fork. Do not relabel stale local engine products.

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

Authenticate an archive before extracting it by supplying its signed appcast and
the independently trusted public key to `verify-release-archive.swift`. The
[local public-audit example](BETA_UPDATES.md#run-a-public-audit-locally) obtains that
public repository variable and checks the full downloaded release/feed path.
No production private key is needed for verification.

For an already authenticated/extracted app, the metadata and archive check can
also be run directly:

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
