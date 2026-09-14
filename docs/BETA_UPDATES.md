# Stable and beta updates

Quartz separates development, validation, and publication. A commit does not
create a release. Maintainers choose when to publish a stable build from Quartz
`main` or a beta build from Quartz `beta`; users choose whether their installed
browser may receive beta updates.

Use this manual alongside the [rollout checklist](#roll-out-the-channel-support)
and the [first stable/beta rollout record](BETA_ROLLOUT_2026-09-14.md). Workflow configuration, a completed hosted build,
feed activation, native UI checks, and a real installation each establish a
different part of release readiness; record their evidence separately.

## Contents

- [Choose a channel in Quartz](#choose-a-channel-in-quartz)
- [Repositories and channels](#repositories-and-channels)
- [What runs automatically](#what-runs-automatically)
- [The signed feed and release assets](#the-signed-feed-and-release-assets)
- [Version labels and ordering](#version-labels-and-ordering)
- [Prepare a beta batch](#prepare-a-beta-batch)
- [Publish a beta](#publish-a-beta)
- [Promote a beta batch to stable](#promote-a-beta-batch-to-stable)
- [Keep the release branches synchronized](#keep-the-release-branches-synchronized)
- [Inspect and recover a release](#inspect-and-recover-a-release)
- [Roll out the channel support](#roll-out-the-channel-support)
- [Tests and release evidence](#tests-and-release-evidence)
- [Permissions and signing secrets](#permissions-and-signing-secrets)
- [Operational records](#operational-records)
- [Frequently asked questions](#frequently-asked-questions)
- [Implementation map and decisions](#implementation-map-and-decisions)

## Choose a channel in Quartz

In a release containing the channel selector, open **Quartz > Update Channel:
Stable > Beta**. The parent menu shows the current selection; the submenu offers
**Stable** and **Beta**, with a checkmark beside the selected option. Quartz
explains the choice after you change it. Use **Quartz > Check for Updates…** to
check immediately, or wait for the normal automatic check if enabled.

**Stable is the default.** Beta is an explicit opt-in. The selection persists for
your macOS user and is shared by Quartz's windows. Missing or invalid stored
preferences resolve to Stable. A manually installed beta does not silently opt
you into future betas; the saved update-channel preference still controls offers.

| Selection | Eligible offers | What changes immediately |
| --- | --- | --- |
| Stable | Compatible stable releases newer than the installed build. | Excludes future beta offers and invalidates a pending excluded beta. |
| Beta | Compatible beta releases **and** newer stable releases. | Adds Sparkle's `beta` channel to the default stable channel. |

Changing channels changes which updates may be offered. It does not replace the
installed app. **Update & Restart** still authorizes downloading and installing
an offered update. Automatic checks and channel preference are separate choices:
choosing Beta does not turn automatic checking on, and turning automatic checks
off does not erase your channel preference.

### Return to stable

Select **Quartz > Update Channel: Beta > Stable**. Quartz waits for a compatible
stable build with a higher build number. It does not downgrade the installed app
or reinstall the latest stable just because that stable has a lower version.

For example, after installing `1.1.0-beta.2`, choosing Stable can later offer
`1.1.0`. It will not offer an older `1.0.2` as a downgrade. If the next available
stable is still older than the installed beta, the correct result is to wait.
This protects profile data from an automatic transition to older application code.
A manual downgrade is outside this updater workflow and may have data-compatibility
implications; it is not the meaning of leaving Beta.

### Changing channels during an update

Quartz revokes an offered or downloading update when the newly selected channel
excludes it. It clears the stale install action, cancels/dismisses the excluded
operation where possible, and rejects late callbacks from that invalidated cycle.
Switching away and back does not resurrect the old install action; a fresh update
cycle must establish eligibility again. A pending stable update remains allowed
when either channel is selected.

Channel choices are disabled while the app is **extracting/preparing or
installing** an update. The menu explains when the choice becomes available
again. This avoids claiming that opting out can cancel a stage already committed
to installation. Download cancellation and installation progress continue to use
the existing update controls.

### Identify the installed build

**Quartz > About Quartz** shows the full release label, including a suffix such
as `-beta.2`. The label identifies the installed artifact; the channel menu
identifies which future artifacts may be offered. They can legitimately differ:
a user may run a beta while having selected Stable.

Development packages without a configured update public key still explain that
updates are unavailable. Storing a channel selection does not turn an unsigned
local package into an updater-enabled release.

## Repositories and channels

There are two repositories and three different meanings of “branch” here:

| Repository or setting | Stable path | Beta path |
| --- | --- | --- |
| Quartz application source | `QuartzBrowser/Quartz:main` | `QuartzBrowser/Quartz:beta` |
| Required engine integration history | `QuartzBrowser/WebKit:main` | `QuartzBrowser/WebKit:quartz-dev` |
| semantic-release output | `X.Y.Z`, ordinary GitHub release | `X.Y.Z-beta.N`, GitHub prerelease |
| Appcast item | Default channel: no `sparkle:channel` element | Explicit `<sparkle:channel>beta</sparkle:channel>` |
| User preference | Stable only | Default stable plus `beta` |

The Quartz `beta` branch is application code and release history. WebKit's
`quartz-dev` branch is engine integration history. They are not interchangeable
branch names and they are not watched dynamically by an installed app.

Both channels use an exact [`WebKit.lock.json`](../WebKit.lock.json) revision.
An explicit `engine_revision` must be a full 40-character lowercase hexadecimal
SHA available from the fork and must descend from the selected Quartz branch's
current pin. Stable requires membership in fork `main`; beta requires membership
in fork `quartz-dev`. A reachable earlier commit can be selected; neither path
silently substitutes the current engine branch tip.

**An empty engine input retains the committed pin and still checks the channel's
engine membership.** Merging a beta lock into Quartz `main` cannot bypass stable
promotion. If that pin is only on fork `quartz-dev`, stable release planning fails
until the intended engine is promoted to fork `main`.

The manual `build` workflow remains more permissive for experiments: it can test
a forward fork feature/sync SHA before integration into either release history.
That creates validation evidence and, for a successful explicit candidate run, a
short-lived artifact. It is not a GitHub beta release and does not enter the user
update feed. See [candidate validation](WEBKIT_MAINTENANCE.md#validate-an-engine-candidate-with-quartz).

## What runs automatically

| Event | Result |
| --- | --- |
| Quartz pull request | CI validates the PR source and committed pin. No publication. |
| Push to Quartz `main` or `beta` | CI validates the pushed branch and committed pin. No publication. |
| Push to any WebKit branch | Does not publish Quartz. Select the SHA in a Quartz validation/release request when appropriate. |
| Manual Quartz `build` with `engine_revision` | Tests the selected candidate without committing a pin or publishing. |
| Manual Quartz `release` on `main` | Stable publication path, subject to validation and releasable changes. |
| Manual Quartz `release` on `beta` | Beta publication path, subject to validation and releasable changes. |
| Manual `verify_version` | Read-only audit of an existing version and canonical/legacy feed items as applicable. |
| Manual `activate_version` | Explicit recovery that may advance the live feed using an already published signed appcast. No new app release. |

The release workflow has no push trigger, no schedule, and no free-form channel
input. The selected Quartz branch determines the channel. Only `main` and `beta`
are accepted. All release/recheck/activation requests share the release concurrency
group, so normal publication is serialized across channels.

Use **Run workflow** for a fresh request against the selected branch. Rerunning an
old Actions run uses its old source snapshot and can run historical workflow
behavior. Changing today's workflow does not rewrite or cancel an old run.

## The signed feed and release assets

### One permanent feed for both channels

New release packages embed this canonical feed URL:

[Quartz signed update feed](https://raw.githubusercontent.com/QuartzBrowser/Quartz/update-feed/appcast.xml)

The file is `appcast.xml` on the Quartz repository's **update-feed** branch, served
by GitHub's raw-content endpoint. This is not a GitHub Pages deployment and does
not require a website, custom domain, Pages workflow, or a second hosting service.
The branch holds feed publication history; do not merge it into application
`main` or `beta`.

The same signed feed retains stable and beta items. Sparkle filters those items
according to the user's allowed channels, version ordering, and compatibility.
Beta is additive: the user still receives an eligible newer stable item. This
follows [Sparkle's channel design](https://sparkle-project.org/documentation/publishing/#channels).
Quartz does not switch feed URLs when a user changes channels.

### Version-specific assets stay with each release

Every published stable or beta version has these assets under its exact GitHub
tag, for example `v1.1.0-beta.1`:

- `Quartz-v1.1.0-beta.1-macos-universal.zip`
- `appcast.xml`
- `SHA256SUMS`

The versioned ZIP includes the engine. Its appcast snapshot contains the new
release item plus retained history at preparation time. The permanent feed can
later add more items; the release's uploaded snapshot and ZIP remain the evidence
for that version. Do not replace their bytes to repair an update.

The pipeline treats versioned assets as immutable and checks that feed activation
uses exactly the bytes uploaded as that release's `appcast.xml`. GitHub permissions
can still permit a human to delete or replace assets; the word “immutable” here
describes the release contract, not an assertion that GitHub immutability settings
have been enabled.

### Verification precedes feed activation

The publication order is deliberate:

1. Build and validate the selected application/engine pair.
2. Recheck the selected source branch and commit the validated engine pin if
   needed; do not rebase onto application changes that arrived during validation.
3. Package the app, freeze the ZIP, sign the archive and final appcast, and write
   checksums. Preserve all previous feed items.
4. Publish the GitHub release and assets; beta is marked as a prerelease.
5. Download the versioned assets and compare bytes/checksums. Authenticate the
   signed feed and archive against the configured public key **before extracting
   the ZIP**, then verify app code signing, its embedded key, and release metadata.
6. Verify the appcast using the trusted public key, compare it with the published
   asset, require retention of every currently advertised item, and fast-forward
   the `update-feed` branch.
7. Check that the canonical public feed serves the exact signed release item.
   A newer feed containing that item is acceptable; unrelated additions do not invalidate
   an older release's audit.

This order means a release can exist on GitHub before it becomes visible through
the new permanent feed. If activation fails, inspect the stage and recover it
explicitly. Legacy clients using GitHub's latest-stable asset route can see a new
stable as soon as GitHub publishes it; that route is separate from the new feed
activation step.

### Preserve the signed history

Preparation retrieves the permanent feed and verifies it before adding the new
item. `generate_appcast` is asked to retain all versions; the finalizer verifies
that every earlier item survives unchanged and rejects a duplicate new build.
It sets the full display label for the new item, then the release script signs
and verifies the final bytes. Delta generation is disabled.

`publish-update-feed.py` independently checks the proposed and current feed
signatures and compares existing item semantics, including URLs, signatures,
compatibility settings, and release notes. It refuses to remove or alter an
already advertised item. Its ordinary Git push fails if another publication
moves `update-feed` first. It does not force-push, regenerate an old feed, or
silently discard later history.

Feeds are bounded to 16 MiB by the verification/publication helpers, and the
publication parser rejects XML document/entity declarations. Unlimited item
retention is a policy within that size bound, not a promise of infinite capacity.
If growth becomes material, design and test a migration; do not delete retained
items to make a failed publication pass.

### Legacy latest-stable route

Older updater-enabled builds embed:

[Legacy latest-stable appcast](https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml)

That URL remains a migration path to a stable version containing the new feed
URL and native channel selector. New release preparation falls back to this
legacy feed only when the canonical URL returns **404**. Other HTTP failures,
network errors, and signature failures stop preparation. If neither feed exists,
two verified 404 results allow a true first-feed bootstrap; this is not a recovery
path for losing an established feed.

A later combined stable snapshot can contain retained beta items, but Sparkle's
default channel excludes beta for users who did not opt in. This migration relies
on the existing updater's channel-aware Sparkle generation. The signed original
stable feed must not be edited in place to manufacture new beta metadata.

## Version labels and ordering

[`release-version.py`](../Scripts/release-version.py) is the version mapping
source of truth. All new packaging and appcast generation use it. Never alter
the mapping casually after versions with it have been published: Sparkle compares
build numbers across installed and offered releases.

Accepted release labels are `X.Y.Z` and `X.Y.Z-beta.N`, without leading zeros.
The app uses several values for different purposes:

| Field | Stable example | Beta example | Purpose |
| --- | --- | --- | --- |
| Full release label / `QuartzReleaseVersion` | `1.1.0` | `1.1.0-beta.2` | About panel, human-facing release identity, asset/tag names. |
| `QuartzReleaseChannel` | `stable` | `beta` | Metadata identifying how this app was released. |
| `CFBundleShortVersionString` | `1.1.0` | `1.1.0` | Numeric macOS marketing-version field. |
| `CFBundleVersion` / `sparkle:version` | `102.0.99` | `102.0.2` | Numeric ordering used for updates. |
| `sparkle:shortVersionString` | `1.1.0` | `1.1.0-beta.2` | Full version label displayed for the offer. |

For release `X.Y.Z`, define `A = 100 × X + Y + 1`. The build is
`A.Z.ordinal`, where beta ordinals are **1 through 98** and stable uses **99**.
Minor `Y` and patch `Z` must each be at most 99; `A` must be at most 9999.
These limits keep the build inside the chosen numeric component bounds.
Prelabels other than `beta`, build metadata suffixes, leading-zero components,
negative values, `beta.0`, and `beta.99` are rejected.

| Release | Numeric build |
| --- | --- |
| `1.0.1` using the new mapping | `101.1.99` |
| `1.1.0-beta.1` | `102.0.1` |
| `1.1.0-beta.2` | `102.0.2` |
| `1.1.0` | `102.0.99` |
| `1.1.1-beta.1` | `102.1.1` |
| `2.0.0` | `201.0.99` |

The historical `1.0.1` release may have the legacy `1.0.1` build number. Verifiers
accept that legacy stable encoding when inspecting old assets; new packaging
always uses the new mapping. This compatibility allowance does not permit a new
beta to use an arbitrary build number.

Inspect the mapping without building or publishing:

```sh
python3 Scripts/release-version.py 1.1.0-beta.2
python3 Scripts/release-version.py 1.1.0-beta.2 --field build_version
```

`VERSION` selects the label for a local package. Normally omit `BUILD_NUMBER`;
the package script derives it. An explicit override must equal the derived value
or packaging fails. Do not set `BUILD_NUMBER` equal to a semantic release label.

semantic-release selects the release label from branch history and Conventional
Commits. `release.config.cjs` declares `main` and the prerelease branch `beta`.
On beta it creates labels such as `1.1.0-beta.1`, incrementing the prerelease
sequence as that release line evolves. This is not a manual `version.txt` bump
workflow. If the sequence would exceed beta 98, stop and plan a new version line;
do not reset ordinals, reuse a tag, or bypass the mapping.

## Prepare a beta batch

### Establish the application branch

Provision Quartz `beta` from the reviewed `main` revision containing these
workflows before the first beta release. This is a one-time repository action;
if `beta` already exists, inspect its ancestry and use it. Do not overwrite it.
The following examples assume that provisioning is complete and all commands
are run in the correct repository with a clean tree. Replace uppercase example
values before use. Mutating sequences use a subshell with `set -eu` so a failed
guard stops that sequence without changing your interactive shell's options.

In the Quartz application checkout:

```sh
(
set -eu
test -z "$(git status --porcelain)"
git fetch origin --tags
git switch beta
git pull --ff-only origin beta
git switch -c feature/my-beta-change
)
```

If local `beta` does not exist, first create it explicitly with
`git branch --track beta origin/beta`. Avoid ambiguous remote guesses. Make and
review application changes through a PR targeting Quartz `beta`, run CI, and
keep unrelated experiments out of the release batch. A change meant to ship
directly to stable can target `main` instead; synchronize it into beta afterwards.

### Integrate the engine changes

Use feature and upstream-sync branches based on **WebKit `quartz-dev`** as
explained in the [engine maintenance manual](WEBKIT_MAINTENANCE.md). Merge reviewed
engine work there, then select a complete SHA from that history for the Quartz
candidate. Beta does not require that engine revision to be promoted to WebKit
`main`, but it still requires forward ancestry from Quartz beta's current pin.

Run a candidate build with the intended Quartz beta source and exact engine SHA:

```sh
(
set -eu
QUARTZ_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_ENGINE_SHA'
gh workflow run build.yml --repo QuartzBrowser/Quartz --ref beta \
  -f engine_revision="$QUARTZ_ENGINE_REVISION"
)
```

A successful manual candidate upload is named `quartz-webkit-candidate-RUN_ID`
and retained for seven days. It contains a development ZIP and an exact selection
record. Use it for the targeted packaged-browser checks. It is distinct from the
signed, versioned release ZIP later offered to beta subscribers.

Save the application SHA, engine SHA, targeted regression results, platform
coverage, and candidate run URL. Revalidate the combined branch if either source
changes. Passing a system-WebKit test or a helper fixture does not validate the
real candidate engine.

## Publish a beta

On GitHub, select **QuartzBrowser/Quartz > Actions > release > Run workflow** and
choose branch **beta**. Leave `verify_version` and `activate_version` empty.
Set `engine_revision` to the exact tested SHA, or leave it empty to keep beta's
committed lock while still checking membership in WebKit `quartz-dev`.

To publish pending application changes with beta's committed engine:

```sh
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref beta
```

To request the tested engine explicitly:

```sh
(
set -eu
QUARTZ_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_ENGINE_SHA'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref beta \
  -f engine_revision="$QUARTZ_ENGINE_REVISION"
)
```

A successful dispatch means GitHub accepted the request, not that a beta is
published. Inspect the run and wait for it:

```sh
gh run list --repo QuartzBrowser/Quartz --workflow release.yml --limit 10
gh run watch --repo QuartzBrowser/Quartz
```

Select the matching branch/source/input run. It snapshots the Quartz beta SHA at
dispatch and refuses to commit the validated result if remote `beta` advances
during validation. Both application and engine work can accumulate before this
manual action. No release occurs for every commit.

The engine plan compares the selected pin with the most recent matching beta
publication, independently of stable. An engine already shipped to stable can
still require its first beta publication, and the reverse does not satisfy stable
publication. An engine-only change is represented by `fix(webkit)`; the resulting
beta version still follows semantic-release's prerelease history and rules.

A completed request can be a no-op when semantic-release has no new releasable
changes and that channel already published the selected engine. Inspect the
actual release output. Do not label a green no-op as a newly published beta.

## Promote a beta batch to stable

A beta label is not an approval stamp. Review the exact application/engine pair,
its custom regression results, supported platforms, and remaining issues before
promotion. Resolve release-blocking failures on beta and retest.

1. Promote the tested engine SHA from WebKit `quartz-dev` to WebKit `main`,
   preserving ancestry and the tested SHA. Follow the
   [guarded fast-forward procedure](WEBKIT_MAINTENANCE.md#promote-a-tested-engine-batch).
2. Integrate the reviewed Quartz beta changes into Quartz `main` through a normal
   reviewed merge, preserving the relevant prerelease history and tags. Inspect
   `WebKit.lock.json`, `version.txt`, and `CHANGELOG.md` conflicts deliberately.
3. Run CI and any required runtime checks on the resulting stable application
   tree. A new merge SHA is a new application validation target.
4. Dispatch the release workflow on Quartz **main**, keeping the reviewed lock
   or supplying the exact promoted engine SHA.
5. Verify the stable versioned assets and permanent feed activation. Record an
   actual beta-to-stable installation check separately.

The stable selector checks WebKit `main` even with an empty input. A beta engine
pin merged into Quartz `main` must already have been promoted; the workflow
refuses to release a development-only engine to stable users.

Do not rename a beta ZIP, edit its Info.plist, move its tag, or change its appcast
channel to turn it into stable. The stable workflow creates a new label, numeric
build number, signed package, and signed feed item. For the same release line,
stable ordinal 99 sorts after beta ordinals 1–98, allowing opted-in beta users to
receive the stable release normally.

Stable publication examples:

```sh
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref main
```

```sh
(
set -eu
QUARTZ_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_PROMOTED_SHA'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref main \
  -f engine_revision="$QUARTZ_ENGINE_REVISION"
)
```

## Keep the release branches synchronized

After stable publication, merge reviewed Quartz `main` changes back into `beta`
before beginning the next beta batch. This includes stable fixes, release
metadata, the final engine pin, and the release tag history semantic-release
uses. Preserve normal merges and tags; do not reset/rebase a published beta
branch to make its commit list look shorter.

Use a sync branch and review its merge instead of immediately moving the shared
beta branch:

```sh
(
set -eu
test -z "$(git status --porcelain)"
git fetch origin --tags
git switch beta
git pull --ff-only origin beta
git switch -c sync/main-into-beta
# This pauses before the merge commit for review; conflicts stop the sequence.
git merge --no-ff --no-commit origin/main
)
```

Choose a unique sync branch name if that name already exists. Resolve and inspect
the merge, run the required checks, commit the reviewed result, and open a PR to
`beta`. `version.txt` and `CHANGELOG.md` describe releases already created; inspect
conflicts against the actual tags. The next release updates those files through
semantic-release. Do not invent a version bump or discard release history merely
to silence a conflict.

For an urgent stable fix, branch from Quartz `main`, validate and merge it there,
then manually publish stable. Bring that fix into beta promptly. If beta users
already have a higher numeric build, the older stable hotfix will not downgrade
them; publish an appropriate newer beta containing the fix as needed. Engine
hotfixes follow the same forward-history discipline in the WebKit repository.

The combined feed retains both release lines, but this configuration is not a
general long-term support release-branch system. It supports `main` and `beta`.
Adding maintenance channels or permanently parallel products requires a separate
versioning, feed, and compatibility design.

## Inspect and recover a release

### Dispatch inputs

At most one of these optional inputs may be nonempty:

| Input | Meaning | Selected Quartz branch |
| --- | --- | --- |
| `engine_revision` | Normal publication using one exact forward engine SHA. | `main` for stable; `beta` for beta. |
| `verify_version` | Read-only verification of existing assets, canonical feed, and legacy route where applicable. | Must match the version: stable on `main`, beta on `beta`. |
| `activate_version` | Explicitly activate an existing release's already signed feed after a failed activation. | Must match the version: stable on `main`, beta on `beta`. |

With all inputs empty, run normal publication using the committed engine pin.
Version inputs omit the leading `v`: use `1.1.0` or `1.1.0-beta.2`. Invalid labels,
channel/branch mismatches, and ambiguous combinations fail before publication.

### Separate the publication stages

| Failure/result | What may already exist | Correct next step |
| --- | --- | --- |
| Invalid request or engine membership/ancestry failure | No new pin from this run. | Correct branch/SHA or promote/integrate the engine; dispatch a fresh request. |
| Build, tests, or pre-commit validation fails | Temporary runner files; no validated pin commit from this path. | Fix and retest the relevant application/engine source. |
| Selected Quartz branch moved | A tested old source pair; the stale plan is refused. | Review current branch state and start a fresh release request. |
| Pin committed; semantic-release failed | A pin commit, possibly tag/draft/assets depending on the failing step. | Inspect live tag/draft/assets; repair the specific failure without replacing signed bytes, then request publication again. |
| GitHub release published; immutable download verification failed | Public versioned assets; canonical feed not advanced by this path. | Diagnose the assets and verification. Do not activate an unverified feed. |
| Immutable assets verified; feed activation failed | Valid GitHub release and signed appcast snapshot; canonical feed may still be older. | Use `activate_version` after inspecting whether later feed history exists. |
| Feed branch advanced; public feed propagation failed | Canonical branch updated but public cached content may lag. | Use `verify_version` to check propagation; activation may already be complete. |
| Older activation rejected for dropped/changed items | A newer live feed that must be preserved. | If the item is already retained, verify it. Otherwise prepare a new release against the current feed history. |
| Read-only verification passed | Existing assets and the advertised item were verified. | Record the evidence; no new version or feed commit was created. |

A stable release on the legacy `releases/latest` route can already be visible to
old clients once GitHub publishes it, even before the permanent-feed step. Record
both surfaces when diagnosing the migration period.

### Read-only verification

For a stable release:

```sh
(
set -eu
QUARTZ_RELEASE_VERSION='1.1.0'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref main \
  -f verify_version="$QUARTZ_RELEASE_VERSION"
)
```

For a beta:

```sh
(
set -eu
QUARTZ_RELEASE_VERSION='1.1.0-beta.2'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref beta \
  -f verify_version="$QUARTZ_RELEASE_VERSION"
)
```

Replace examples with an existing published version. It need not be the most
recent version if its exact item remains in the feed. The audit downloads the
release assets and always checks the canonical permanent feed. For a legacy app
that embeds the latest-stable asset URL it also checks that route. Seed the
canonical signed feed before using this new audit on historical releases.
The advertised item must match the versioned snapshot. A newer feed containing
additional releases is accepted.

`verify_version` has read-only permissions and receives the configured
`SPARKLE_PUBLIC_KEY` variable. It authenticates the feed/archive before extracting
the downloaded ZIP, then verifies the embedded key matches that external trust
anchor. It does not trust a key obtained only from the downloaded app. It does not repair missing feed
activation, regenerate a signature, rebuild an app, or create a release. Passing
this audit is not proof of a real user installing the update.

### Run a public audit locally

For a local diagnostic, fetch the **public repository variable**, download the
reference assets, and invoke the same script. This reads public assets and does
not activate a feed. Use an existing label; the canonical seed must already exist:

```sh
(
set -eu
QUARTZ_RELEASE_VERSION='1.1.0-beta.2'
SPARKLE_PUBLIC_KEY="$(gh variable get SPARKLE_PUBLIC_KEY --repo QuartzBrowser/Quartz)"
export SPARKLE_PUBLIC_KEY
QUARTZ_AUDIT_DIR="$(mktemp -d -t quartz-update-audit)"
trap 'rm -rf "$QUARTZ_AUDIT_DIR"' EXIT
mkdir -p "$QUARTZ_AUDIT_DIR/release"
gh release download "v$QUARTZ_RELEASE_VERSION" --repo QuartzBrowser/Quartz \
  --dir "$QUARTZ_AUDIT_DIR/release" \
  --pattern "Quartz-v$QUARTZ_RELEASE_VERSION-macos-universal.zip" \
  --pattern appcast.xml --pattern SHA256SUMS
DIST_DIR="$QUARTZ_AUDIT_DIR" Scripts/verify-published-update.sh "$QUARTZ_RELEASE_VERSION" --feed
)
```

`SPARKLE_PUBLIC_KEY` is a public trust anchor, not the signing secret. The script
refuses a missing key, authenticates the archive before extraction, and checks
that the extracted app embeds the same key. Omit `--feed` only when intentionally
checking versioned assets independently of activation; that narrower result does
not establish that any user can discover the release.

### Explicit feed activation recovery

When versioned assets are already published and valid but their signed feed has
not been activated, use the corresponding branch and `activate_version`:

```sh
(
set -eu
QUARTZ_RELEASE_VERSION='1.1.0-beta.2'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref beta \
  -f activate_version="$QUARTZ_RELEASE_VERSION"
)
```

For stable, use `--ref main` and a stable label. Leave the other inputs empty.
This job downloads and verifies the existing assets, verifies the signed appcast
with the configured **public key**, and attempts an ordinary forward feed push.
It does not use the private signing key and does not create a new app version.

If the same feed bytes are already active, publication is a no-op. If the current
feed contains later items that the old snapshot would remove or change, the
helper refuses the activation. Do not reset `update-feed`, edit the old snapshot,
force-push, or delete later items. If the desired release item is already retained,
just verify it. If it is absent and newer history has been published, make a fresh
release from the intended current source against the current feed. Existing
signed assets cannot be silently amended to add history.

Normal engine-publication retry logic is scoped to the selected channel's
published engine pin. Once a GitHub release is published, that comparison may
report no new engine release even when feed activation failed. This is why
activation has its own explicit recovery input instead of relying on an empty
`fix(webkit)` retry to repair everything.

### Feed propagation checks

`wait-for-channel-feed.sh` accepts only the canonical or legacy Quartz feed URL.
By default it tries up to **36 times**, waiting **10 seconds** between attempts;
requests have their own timeouts, so this is not a six-minute completion promise.
Each successful candidate response must have a valid signature and the unchanged
expected item. It does not demand equality between the entire current feed and
an older release snapshot.

The diagnostic bounds are `CHANNEL_FEED_ATTEMPTS=1..60` and
`CHANNEL_FEED_RETRY_DELAY=0..60` seconds. These variables are useful for tests or
explicit diagnostics; they are not a user channel setting or an authorization
to bypass signature/retention checks. Persistent network, signature, or item
mismatches fail the job and require investigation.

## Roll out the channel support

This sequence migrates existing updater users without treating an in-progress
implementation as a published product. Record completion evidence for every step.

1. Seed `update-feed/appcast.xml` with the **original signed `v1.0.1` release
   appcast**, after verifying its public assets and signature with the existing
   trusted key. Preserve the bytes; do not relabel, resign with another key, or
   construct a synthetic replacement. If the migration baseline has changed,
   inspect the actual latest stable and record an explicit revised baseline.
2. Verify the permanent raw URL serves that signed seed. Seeding is feed setup,
   not a new app or beta release, and does not change the URL embedded in old apps.
   The canonical feed must exist before the new `--feed` audit can pass on a
   historical release; a working legacy route cannot substitute for it.
3. Merge the reviewed implementation into Quartz `main` after required CI and
   packaging checks. Confirm the live workflow has only manual release dispatch
   and accepts `main`/`beta` with the correct input guards.
4. Publish the initial **stable** release containing the native selector and new
   canonical feed URL through the normal stable workflow. Verify its assets,
   feed activation, and legacy latest-stable route. This release delivers the
   opt-in UI and new feed to existing users.
5. Provision Quartz `beta` from the reviewed stable source containing the new
   workflows/helpers, or reconcile an existing beta branch without rewriting
   published history. Inspect any configured protections and confirm CI covers
   both branches. Keep release metadata and tags synchronized.
6. Exercise a real update from a pre-migration stable app to that stable release,
   including signature validation, installation, restart, session restoration,
   About label, Stable default, and the new packaged `SUFeedURL`.
7. Prepare, validate, and manually publish the first beta when ready. A first
   beta may deliberately validate the channel with the same application/engine
   behavior as the stable bridge; describe that purpose explicitly rather than
   claiming new features. It is still a separately versioned/signed prerelease.
   Check the GitHub prerelease flag, beta item, retained stable items, numeric
   build, and feed publication.
8. Exercise Stable exclusion, Beta inclusion, beta-to-stable updating, opt-out
   with a pending beta, and the no-downgrade behavior on the actual packaged apps.

Do not mark a step complete from its workflow definition or a local fixture.
A recorded run URL, commit, artifact/hash, and observed runtime behavior provide
different evidence and should remain distinct. Use the release record to distinguish completed rollout steps from installation
or hardware checks that remain unrun.

## Tests and release evidence

### Fast helper tests

Run from the Quartz repository root:

```sh
(
set -eu
python3 Scripts/test-release-version.py
python3 Scripts/test-release-appcast.py
python3 Scripts/test-update-feed.py
python3 Scripts/test-verify-published-update.py
python3 Scripts/test-engine-updates.py
)
```

The workflow policy suite needs the Python dependencies in
`Scripts/requirements-workflow-tests.txt`; use an existing prepared virtual
environment or install them into a task-specific virtual environment before
running `python3 Scripts/test-workflow-policy.py` there. These tests check version
boundaries, preserved item semantics, feed races/recovery, exact engine/channel
selection, authentication before extraction, canonical/legacy feed routing, and
configured workflow publication boundaries. The public routing suite uses
command fixtures; real signature fixtures separately establish crypto behavior. Inspect the actual
test output; counts may change as coverage evolves.

### Native and packaging tests

With verified products for the committed engine pin:

```sh
(
set -eu
Scripts/quartz.sh test
Scripts/test-update-packaging.sh
)
```

When developing UI/helper behavior without matching fork products, explicitly
select the system engine:

```sh
(
set -eu
QUARTZ_USE_SYSTEM_WEBKIT=1 Scripts/quartz.sh test
QUARTZ_USE_SYSTEM_WEBKIT=1 Scripts/test-update-packaging.sh
)
```

The updater fixture script creates disposable keys, isolates its output, and
sets its own test-only release exception. It must not use the production private
key. System-engine results cover the updater/native behavior on that host; they
do not establish that the currently locked fork compiles, renders, packages, or
works on another architecture. If prepared local products have a stale revision,
build the locked engine or use the explicit system mode for those limited tests;
do not edit their provenance manifest to fake a match.

Required release validation still uses the real pinned fork in hosted CI. A
local universal fixture package, even with correct signatures, is not evidence
that the real fork release build succeeded. Keep Apple Silicon, Intel, Rosetta,
and minimum-supported-macOS results separate.

### Packaged channel exercise

Record each exercised version/source pair and platform:

- [ ] A fresh preference domain selects Stable; invalid saved values fall back
  to Stable, and selection persists across a normal restart.
- [ ] The app menu shows the selected channel and About shows the full beta label.
- [ ] A stable user is not offered the beta item from a combined signed feed.
- [ ] A Beta user sees the eligible beta and can also receive a newer stable.
- [ ] The same-base stable build sorts after every allowed beta ordinal.
- [ ] Opting out from an offered/downloading beta clears the excluded install
  action; late progress/completion callbacks do not revive it.
- [ ] Channel selection is disabled during extraction and installation, and the
  existing install completion behavior remains usable.
- [ ] Switching to Stable while running a newer beta offers no automatic downgrade.
- [ ] Update installation requires Update & Restart; automatic-check preference
  remains independent of channel selection.
- [ ] Real signed archive tampering, feed tampering, wrong-key content, and
  incompatible OS behavior are rejected or explained as designed.
- [ ] The actual older app installs the newer app, restarts, and restores its
  browsing session without replacing user data outside the app bundle.

Unit tests can cover many state transitions, but the final installation and
native UI checklist requires actual runtime evidence. Record unavailable checks
as unrun rather than treating a broad green test count as proof of every path.

## Permissions and signing secrets

The release preparation phase requires the existing `SPARKLE_PRIVATE_KEY` secret
and `SPARKLE_PUBLIC_KEY` variable. Stable and beta use the same trusted key
continuity; opting into a channel is not opting into a different trust root.
Keep the key in the existing secure storage and repository secret configuration.
Never put it in a branch, appcast, artifact, command-line argument, issue, or log.
The prepare script passes private signing material through standard input and
removes its exported value before invoking compilers.

Read-only version verification requires the configured **public** key and needs
no private key. Feed activation verifies
with the configured public key and needs permission to push the Quartz feed
branch; it does not need signing authority to reuse an already signed snapshot.
The publication helper also checks GitHub tag identity, prerelease status,
uploaded required assets, and the exact public appcast bytes before pushing.

The workflow uses Quartz's existing `GITHUB_TOKEN` for its allowed writes and
reads the public engine fork. No new cross-repository token or website credential
is part of this design. Branch protections and Actions permissions can still
block pushes; inspect the exact rule instead of introducing a broad token.
Protect long-lived branches against force pushes/deletion where configured and
keep the documented required checks/review policy distinct from rules actually
installed in GitHub.

Source branch publication and feed activation run in one serialized workflow
because token-authenticated pushes are not a mechanism for dispatching a second
publication job. The branch checks also ensure a requested beta recheck/activation
cannot run as a stable request on `main`.

## Operational records

Attach a record like this to each channel release or its linked maintenance PR:

```markdown
## Channel release record

- Channel and Quartz release branch:
- Requested workflow run URL and dispatch SHA:
- Exact engine SHA and previous branch pin:
- Engine eligibility evidence: fork main / quartz-dev:
- Candidate run and targeted regression results:
- Actual hardware / macOS / engine mode exercised:
- Full release label, base version, and numeric build:
- GitHub tag and prerelease flag:
- Versioned ZIP, appcast, and SHA256SUMS evidence:
- Immutable public-asset verification result:
- update-feed commit and public item-verification result:
- Legacy latest-stable migration check, when applicable:
- Stable/Beta inclusion and opt-out runtime checks:
- Real installation/restart/session-restoration result:
- Any activation recovery input/run and reason:
- Remaining unrun gates or release limitations:
```

Retain the exact signed assets and relevant logs under the release retention
policy. Candidate artifacts expire after seven days; an expired artifact link
is not durable test evidence. Never write secrets into the record.

## Frequently asked questions

### Does every beta branch commit publish a beta?

No. Commits and merges trigger normal CI. Only a manual release dispatch on
Quartz `beta` can publish a beta. A batch can contain many application commits,
custom engine patches, and upstream changes.

### Is selecting Beta enough to install it?

It makes eligible beta updates discoverable. The user still chooses Update &
Restart. If no compatible newer beta is published/advertised, switching channels
cannot invent one.

### Why can Beta users receive stable releases?

Sparkle's beta channel supplements the default channel. A newer stable is the
normal way to finish a beta cycle. Channel selection is not a permanent fork into
an unrelated product or a separate user-data profile.

### Why am I still running a beta after selecting Stable?

Opt-out changes future eligibility, not installed bytes. Wait for a compatible
stable whose numeric build is newer. The same-base final stable has ordinal 99
and can supersede its betas; an older stable line cannot downgrade them.

### Why did stable release planning reject an empty engine input?

Empty retains the pin but does not waive stable engine membership. The committed
pin may be present only in WebKit `quartz-dev`, for example after merging beta
application changes. Promote the reviewed engine to fork `main` before stable
publication.

### Can I ship an arbitrary feature-branch engine to beta?

First use candidate CI for that feature SHA. Beta publication requires the
selected engine to be integrated into WebKit `quartz-dev`; stable additionally
requires its promotion to fork `main`. Both retain forward ancestry checks.

### Why use a separate update-feed branch?

GitHub's latest-stable release URL cannot independently advance when only a beta
is published. One permanent signed feed can advertise both channels after their
assets pass verification, preserve their history, and remain independent of the
application branches. It uses raw GitHub content and adds no website deployment.

### A release is on GitHub but testers see no update. What do I check?

Check the native channel preference, version/OS eligibility, embedded feed URL,
versioned-asset audit, feed activation result, and public propagation. `verify_version`
is diagnostic. `activate_version` is the explicit recovery when the already
signed snapshot is safe to activate. Do not turn a failed diagnostic into an
unreviewed feed rewrite.

### Can I reactivate an older feed after a later release?

Only if it retains every currently advertised item unchanged. Usually an older
snapshot would drop the later release, so the helper refuses it. If the old item
is still present, verification is enough. Otherwise prepare a fresh release with
the current feed history; never force-push the feed backwards.

### Can I fix the display label directly in the published XML?

No. Editing the feed invalidates its signature and changes an immutable release
item. Fix the generation code, create a new release, and retain the previous item.
`release-appcast.py` modifies only the new item before final signing and rejects
altered history.

### What happens when beta reaches 98?

The next beta ordinal is outside this mapping. Plan a new version line before
that point. Do not reuse numbers, label a beta as stable to pass validation, or
change the mapping without a tested migration.

### Does GitHub prerelease status alone hide a beta from Stable users?

No. Quartz also requires correct signed appcast channel metadata and native
allowed-channel behavior. GitHub release flags, full labels, numeric builds,
archive metadata, and feed item semantics must agree; the helpers validate those
relationships.

## Implementation map and decisions

| File | Responsibility |
| --- | --- |
| [QuartzUpdateChannel.swift](../Sources/Quartz/QuartzUpdateChannel.swift) | Persisted channel selection, default eligibility, and displayed installed version. |
| [QuartzUpdateController.swift](../Sources/Quartz/QuartzUpdateController.swift) | Sparkle allowed channels, feed URL from the signed app, update-cycle reset. |
| [QuartzUpdateUserDriver.swift](../Sources/Quartz/QuartzUpdateUserDriver.swift) | Excluded offer/download invalidation and install-stage switching boundaries. |
| [QuartzApp.swift](../Sources/Quartz/QuartzApp.swift) | Native Update Channel submenu and About label. |
| [release-version.py](../Scripts/release-version.py) | Accepted labels, metadata bounds, numeric ordering. |
| [update-webkit.py](../Scripts/update-webkit.py) | Exact engine selection, channel membership, channel-specific release history, race-checked pin commits. |
| [release-appcast.py](../Scripts/release-appcast.py) | Full new-item labels and unchanged history before final signing. |
| [verify-feed.swift](../Scripts/verify-feed.swift) | Public-key verification of Sparkle's signed feed envelope. |
| [verify-release-archive.swift](../Scripts/verify-release-archive.swift) | Authenticate feed/enclosure and ZIP against an external trusted public key before extraction. |
| [publish-update-feed.py](../Scripts/publish-update-feed.py) | Existing-release feed validation, retained-item check, ordinary forward feed push. |
| [wait-for-channel-feed.sh](../Scripts/wait-for-channel-feed.sh) | Public propagation and exact retained-item verification. |
| [verify-published-update.sh](../Scripts/verify-published-update.sh) | Versioned public assets, metadata/signatures, optional active-feed check. |
| [release.yml](../.github/workflows/release.yml) | Manual branch selection, publication sequence, read-only recheck, explicit activation recovery. |
| [release.config.cjs](../release.config.cjs) | Stable/prerelease branches and semantic-release asset generation/publication. |

**Decision:** one opt-in beta channel, one permanent signed feed, exact engine
pins, and deliberate publication on the matching application branch. Preserve
stable defaults, key continuity, user-controlled installation, and forward
history.

**Reason:** beta distribution needs to reach testers independently of the next
stable release, while stable users need a predictable opt-in boundary. An exact
engine pin makes each candidate reviewable. Numeric ordering lets the same-base
stable complete the beta cycle without downgrades or special installer logic.
Separate public-asset verification and feed activation make partial failures
visible and recoverable without private-key access or replacing signed bytes.

**Operational cost:** maintain both application branches, record exact source
pairs and channel tests, preserve feed history, and explicitly request publication
and recovery. The design does not automatically monitor upstream security fixes,
automatically promote beta to stable, create releases per commit, or establish
hardware support from a universal binary alone.

For platform behavior, see [Sparkle channels](https://sparkle-project.org/documentation/publishing/#channels)
and [semantic-release prerelease workflows](https://semantic-release.org/recipes/release-workflow/pre-releases/).
For the rest of the process, use [engine maintenance](WEBKIT_MAINTENANCE.md),
[update signing and verification](UPDATES.md), and the [release checklist](releases.md).
