# Maintaining the Quartz WebKit fork

Quartz has two development histories and one shipped application. Maintain engine
changes in `QuartzBrowser/WebKit`, test selected engine commits with Quartz, and
publish a batch only when a maintainer runs Quartz's `release` workflow. Quartz
`main` publishes stable releases; Quartz `beta` publishes opt-in prereleases.
The [beta update manual](BETA_UPDATES.md) covers the native selector, application
branch synchronization, version ordering, shared signed feed, and recovery. Ordinary
commits, merges, engine promotions, and candidate builds do not publish Quartz.

This manual is the operating procedure for the workflows committed alongside it.
It takes effect for GitHub's default branch when those workflow changes are
merged into Quartz `main`. Editing a local copy of this document does not change
GitHub's triggers, cancel an already queued run, or prove that a candidate passed its release checks.

## Contents

- [The rules that matter](#the-rules-that-matter)
- [Repositories, branches, and immutable revisions](#repositories-branches-and-immutable-revisions)
- [What triggers a build or publication](#what-triggers-a-build-or-publication)
- [Set up an engine development checkout](#set-up-an-engine-development-checkout)
- [Make and maintain custom changes](#make-and-maintain-custom-changes)
- [Bring in upstream WebKit changes](#bring-in-upstream-webkit-changes)
- [Validate an engine candidate with Quartz](#validate-an-engine-candidate-with-quartz)
- [Promote a tested engine batch](#promote-a-tested-engine-batch)
- [Publish a Quartz release deliberately](#publish-a-quartz-release-deliberately)
- [Release planning and failure recovery](#release-planning-and-failure-recovery)
- [Revert a bad change without rewriting history](#revert-a-bad-change-without-rewriting-history)
- [Caches, builds, and evidence](#caches-builds-and-evidence)
- [Maintenance cadence](#maintenance-cadence)
- [Records and checklists](#records-and-checklists)
- [Permissions and repository settings](#permissions-and-repository-settings)
- [Troubleshooting and FAQ](#troubleshooting-and-faq)
- [Decision record](#decision-record)

## The rules that matter

1. Commit and experiment on engine `feature/*` branches based on `quartz-dev`.
2. Merge upstream WebKit into an engine `sync/upstream-*` branch based on
   `quartz-dev`; resolve, review, and test there before integration.
3. Preserve upstream ancestry and published fork history. Do not reset the fork
   to upstream, force-push the long-lived branches, or squash an upstream sync.
4. Test the exact engine SHA with the intended Quartz code. A green run for a
   different commit is useful context, but does not validate the new candidate.
5. Integrate a tested engine into fork `quartz-dev` for beta eligibility; promote
   it to fork `main` before stable release. Neither action publishes Quartz.
6. In **Quartz > Actions > release > Run workflow**, choose application branch
   `main` for stable or `beta` for prereleases and supply the exact eligible SHA.
   Empty keeps that branch's committed pin and still checks engine eligibility.
7. Let the release job validate, commit the pin, version, package, sign, and
   publish. Record its actual result and the public-download verification.

Twenty custom commits and hundreds of upstream commits can become one promotion
and one Quartz release. Quartz's own `main` can also collect multiple application
changes before that release. Commit frequency is independent of release frequency.

## Repositories, branches, and immutable revisions

| Location | Role | Moves when |
| --- | --- | --- |
| `WebKit/WebKit`, remote `upstream`, branch `main` | Original WebKit development history | Upstream maintainers integrate changes. |
| `QuartzBrowser/WebKit`, remote `origin`, branch `quartz-dev` | Shared integration of Quartz customizations and accepted upstream updates | A feature or sync is reviewed and integrated. |
| Fork `feature/*` | Individual experiments and custom behavior | You work, test, and commit. |
| Fork `sync/upstream-*` | An upstream merge under review | You resolve conflicts and validate the combined engine. |
| Fork `main` | Engine revisions considered ready for Quartz release validation | You deliberately promote a tested batch. |
| `QuartzBrowser/Quartz`, branch `main` | Application changes eligible for the next stable release | Reviewed stable changes are merged. |
| `QuartzBrowser/Quartz`, branch `beta` | Application changes eligible for beta prereleases | Reviewed beta work and stable synchronization are merged. |
| Quartz `update-feed` branch | Permanent signed stable/beta appcast served by raw GitHub | Verified published appcast activation fast-forwards the branch. |
| Quartz `WebKit.lock.json` | Exact engine source used by normal Quartz builds | A validated release update commits a selected revision, or an explicitly reviewed lock change is merged. |
| Quartz release tag, such as `v0.16.0` | Historical application source and engine pin associated with a version | semantic-release creates a release. |

`upstream/main` is a remote-tracking ref in your engine checkout, not a new branch
that needs to be published in the fork. The feed branch is publication data, not application source; do not merge it
into `main` or `beta`. The branch names in the two repositories are independent: a Quartz application branch called `main` does not refer to
engine `main`.

```mermaid
flowchart LR
    U[Upstream WebKit main] --> S[Fork sync/upstream branch]
    F[Fork feature branches] --> D[Fork quartz-dev]
    S --> D
    D --> T[Test exact engine SHA with Quartz]
    T --> M[Promote SHA to fork main]
    M --> R[Manually run Quartz release with SHA]
    Q[Quartz main application changes] --> R
    R --> V[Validate engine and application]
    V --> P[Commit pin and publish signed Quartz update]
```

The release selector accepts a complete **40-character lowercase hexadecimal Git
SHA**, not `main`, `quartz-dev`, a tag, or an abbreviated hash. The selected SHA
must be available from the public fork, must descend from Quartz's current pin,
and must be reachable from fork `main` for stable or `quartz-dev` for beta.
These membership checks also apply to a retained pin when the input is empty.
An earlier integrated commit can be selected if it meets the ancestry rules;
the job does not substitute the latest engine tip.

A manual **build** accepts a forward candidate from a development or feature
branch before either release integration/promotion gate. Beta release eligibility
requires `quartz-dev`; stable requires `main`. This separates experimental testing
from publication eligibility. Existing release pins and version tags remain the source of truth
for what users actually received.

## What triggers a build or publication

| Action | Quartz validation | Publishes Quartz? |
| --- | --- | --- |
| Push a WebKit feature, sync, or `quartz-dev` branch | No automatic cross-repository Quartz build; dispatch one when useful. | No. |
| Promote engine `quartz-dev` into engine `main` | Select its SHA for a Quartz candidate build or release. | No. |
| Open or update a Quartz pull request | Automatic `build` workflow using that PR's lock. | No. |
| Push or merge into Quartz `main` or `beta` | Automatic `build` workflow using the committed lock. | No. |
| Run Quartz `build` manually with an engine SHA | Builds and tests that SHA in the runner's working tree. | No. |
| Run Quartz `release` on `main` or `beta`, with verification/activation inputs empty | Validates the selected pair before stable/prerelease publication. | Yes, if there are releasable changes or an unpublished channel engine pin. |
| Run Quartz `release` with only `verify_version` set | Rechecks an existing version's assets and advertised feed item. | No. |
| Run Quartz `release` with only `activate_version` set | Verifies and may activate an existing signed appcast if all current items are retained. | No new app release; can advance the live feed. |
| Create an engine tag | No Quartz release trigger. | No. |

The workflow files are [build.yml](../.github/workflows/build.yml) and
[release.yml](../.github/workflows/release.yml). There is no scheduled polling or
push trigger in the release workflow. Existing workflows in the WebKit fork may
have their own CI behavior; the table describes Quartz's integration.

A `fix:` or `feat:` commit describes version impact. It does not press the
publication button. The selected branch/channel and accumulated Quartz commits determine the version
through [release.config.cjs](../release.config.cjs).

## Set up an engine development checkout

Use a separate, full engine checkout for editing and history work. Quartz's build
cache is a shallow, sparse, clean checkout optimized for one pinned revision. It
is intentionally unsuitable as your long-lived editing repository and may omit
upstream test directories. The build helper also rejects an existing source
checkout with local changes, a different revision, or a different origin URL.

From a parent development directory, create a new clone if you do not already
have a suitable engine checkout. The example directory avoids whitespace because
WebKit's upstream Makefiles require whitespace-free source and raw build paths.
Cloning all of WebKit can take substantial storage and time.

```sh
git clone --branch quartz-dev https://github.com/QuartzBrowser/WebKit.git QuartzWebKit
cd QuartzWebKit
git branch --track main origin/main
git remote add upstream https://github.com/WebKit/WebKit.git
git fetch origin
git fetch upstream
git switch quartz-dev
```

For an existing clone, inspect `git remote -v` first and add `upstream` only if it
is absent. Create a local tracking branch only when it does not already exist:
`git branch --track main origin/main` or
`git branch --track quartz-dev origin/quartz-dev`. The explicit remote avoids
ambiguity between `origin/main` and `upstream/main`. If local `quartz-dev` already
exists, use `git switch quartz-dev` and `git pull --ff-only origin quartz-dev`.
Stop and review divergence instead of replacing local work.

The fork's default branch is `quartz-dev`; the fresh-clone command selects it
explicitly. Existing clones can refresh their symbolic default with
`git remote set-head origin -a`; this does not move your working branch.

The initial `quartz-dev` branch was created on 2026-09-13 at the existing fork
`main` revision `4a523b0b3d1ddf66abbf9ec9b6351248e57db73c`, preserving the already
integrated history. This is an initialization record, not a permanently current
branch tip. Inspect live refs before starting new work.

Before every merge, promotion, or release-related local operation, inspect:

```sh
git status -sb
git diff
git diff --cached
```

The merge and candidate commands below assume a clean tracked working tree and
index. Commit intended work on its branch or preserve it in another worktree
before proceeding. Do not discard unrelated changes to make the commands pass.
Stop when a command fails; resolve the stated condition before continuing.

## Make and maintain custom changes

### Start a feature

In the engine development checkout:

```sh
git switch quartz-dev
git pull --ff-only origin quartz-dev
git switch -c feature/my-engine-change
```

Develop the change and its regression coverage, commit focused changes, and push
that feature branch. Open a WebKit-fork pull request with base `quartz-dev` when
ready for review. Record both the behavior you want and the upstream behavior
being changed. For a UI-only Quartz feature, prefer an application change when
WebKit's public API can express the behavior; an engine patch creates an ongoing
upstream maintenance obligation.

Keep engine customizations small and localized where practical. Preserve normal
upstream behavior outside the Quartz-specific condition. Include the reason for
non-obvious opt-outs near the relevant code, and link the change to its ledger
entry. An experimental change that affects page capabilities or compatibility
should have a deliberate default and a way to test both configurations.

### Keep a customization ledger

Maintain the fork's tracked [QUARTZ_PATCHES.md](https://github.com/QuartzBrowser/WebKit/blob/quartz-dev/QUARTZ_PATCHES.md)
as customizations evolve. Its initial source inventory records the retained
Writing Tools and Quick Look changes, their exact commits and files, and which
regression checks still need runtime evidence. The template below is a format
for future entries. Add an entry with every customization and update it during
every upstream sync; a source inventory does not prove runtime correctness.

```markdown
## QWK-001: Short behavior name

- Status: active / upstreamed / retired
- Owner:
- User-visible reason:
- First fork commit or pull request:
- Upstream issue or proposal, if any:
- Files / upstream subsystem:
- Configuration or public API condition:
- Expected behavior with the change enabled:
- Expected behavior with the change disabled or absent:
- Regression tests and exact commands:
- Manual reproduction and expected result:
- Latest upstream sync reviewed:
- Latest tested engine SHA and Quartz SHA:
- macOS / architecture / Xcode actually exercised:
- Potential conflict or API migration points:
- Removal condition:
- Last review outcome and evidence links:
```

The existing integration's documentation identifies Writing Tools opt-outs,
Quick Look lifecycle behavior, and the prevention of mixed system/fork engine
images as important compatibility obligations. Review them when the relevant
upstream AppKit/WebKit code changes. Their mention here does not assert a fresh
runtime test or replace an inventory of the actual fork commits.

A long-lived customization should have an explicit removal condition, such as
an accepted upstream fix or a public API becoming available. Before dropping it,
prove that the relevant regression still passes against the updated engine.
Keep the retired ledger entry so future maintainers can understand its history.

### Integrate a feature

Review the patch, run the relevant upstream tests in the full engine checkout,
and run the Quartz candidate checks below. Merge the completed feature into
`quartz-dev` using a normal merge when its commit-level history is useful. The
critical rule is to preserve shared and upstream history: never squash an
upstream synchronization or rewrite a commit already used as a Quartz pin.

After integration, obtain the new `quartz-dev` SHA and test that combined tree
before promotion. Separate green feature runs do not establish that their merged
result works together. Development branches can contain work for the next batch;
keep unrelated experiments out of the batch you intend to promote.

## Bring in upstream WebKit changes

### Prepare a sync branch

From the full engine development checkout, fetch both repositories and create a
branch for this integration attempt:

```sh
git fetch origin
git fetch upstream
git switch quartz-dev
git pull --ff-only origin quartz-dev
QUARTZ_SYNC_BRANCH="sync/upstream-$(date +%Y-%m-%d)-1"
git switch -c "$QUARTZ_SYNC_BRANCH"
git log --oneline HEAD..upstream/main
git merge --no-ff --no-commit upstream/main
```

Choose another suffix if that sync branch already exists. `--no-commit` gives you
an inspection point before recording the merge; `--no-ff` preserves that point
even when the branch can fast-forward. If Git reports that everything is already
up to date, there is no upstream merge to record. The intended upstream snapshot
is whatever `upstream/main` resolved to at this fetch, not a continually moving
source during the build.

### Resolve and review

If there are conflicts, inspect them and resolve the intended combined behavior:

```sh
git diff --name-only --diff-filter=U
git status --short
git diff --check
```

Review conflict resolutions file by file. Avoid taking all of `ours` or `theirs`
for the merge: that can silently lose upstream changes or Quartz behavior.
An automatically clean merge is only a text merge. It cannot prove that changed
upstream call ordering, ownership, entitlements, feature flags, or APIs still
match the assumptions in a custom patch.

For every active customization, check its touched subsystem, inspect upstream
changes in that area, rerun its regression, and record whether it remains needed.
Inspect any removed or renamed APIs, deployment target changes, minimum Xcode
changes, and framework/service layout changes. The Quartz lock, build scripts,
and packaging validation may need corresponding changes in a Quartz branch.
Do not lower metadata values simply to bypass a new toolchain requirement.

Stage each resolved path deliberately, inspect the staged merge, then commit it:

```sh
git diff --cached --stat
git diff --cached
```

Use `git add -- path/to/resolved-file` for the actual resolved files, and
`git commit` once the merge is resolved and reviewed. Run the relevant upstream
and Quartz validation, push the sync branch, and open a fork PR targeting
`quartz-dev`. Preserve the upstream merge commit when integrating that PR.
If abandoning an uncommitted merge, `git merge --abort` is appropriate only for
this clean-started merge; inspect its result and keep any independent work safe.

### Review the resulting batch

After the sync PR is integrated, fetch the fork and inspect what will be promoted:

```sh
git fetch origin
git log --oneline --first-parent origin/main..origin/quartz-dev
git diff --stat origin/main...origin/quartz-dev
git merge-base --is-ancestor origin/main origin/quartz-dev
```

The ancestry check must succeed before a fast-forward promotion. These summaries
help review the batch but do not replace inspecting the customization changes,
conflict resolutions, and test evidence. A huge upstream commit count is normal;
it is not a reason to erase the history.

## Validate an engine candidate with Quartz

### Record the exact candidate

In the engine checkout after fetching the intended branch:

```sh
git fetch origin
QUARTZ_ENGINE_REVISION="$(git rev-parse origin/quartz-dev)"
printf '%s\n' "$QUARTZ_ENGINE_REVISION"
```

Use the SHA of `origin/feature/my-engine-change` or `origin/sync/upstream-...` when
testing that branch instead. The candidate must already be pushed to the public
fork so the runner can retrieve it. Transfer the complete displayed SHA to your
Quartz checkout or the workflow input; shell variables do not follow you into a
new terminal automatically.

### Run hosted validation without publishing

On GitHub, open **QuartzBrowser/Quartz > Actions > build > Run workflow**. Select
the Quartz branch whose application changes you intend to test, enter the full
SHA in `engine_revision`, and run it. Leave `engine_revision` empty to test the
engine already pinned on that Quartz branch.

Equivalent GitHub CLI commands, from an authenticated shell:

```sh
QUARTZ_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_ENGINE_SHA'
gh workflow run build.yml --repo QuartzBrowser/Quartz --ref main \
  -f engine_revision="$QUARTZ_ENGINE_REVISION"
gh run list --repo QuartzBrowser/Quartz --workflow build.yml --limit 5
gh run watch --repo QuartzBrowser/Quartz
```

Replace `main` with your Quartz candidate branch if application changes are part
of the experiment. Use the workflow run whose recorded application SHA and
engine input match your test, especially if someone else dispatches a build at
the same time. Builds share cancellation concurrency by Quartz branch; a newer
build on the same branch can cancel an older candidate. Use a dedicated Quartz
test branch when that isolation is useful. GitHub dispatch is asynchronous; command success means the run
was requested, not that validation passed.

The build workflow stages the candidate lock before preparing the engine,
validates the engine/bundling helpers, builds both architectures, runs Quartz
tests, packages and extracts the app, checks bundled runtime rendering/network
behavior, and tests updater signing/tamper rejection with disposable keys. It
does not commit the temporary pin, push it, or create a release. Runtime checks
exercise the host architecture; separate Intel and supported-OS runs remain
necessary to claim those combinations.

A successful explicit manual engine candidate run uploads the development app
and selection record as **quartz-webkit-candidate-RUN_ID**, retained for **7 days**.
The artifact contains `dist/Quartz.zip` and `.build/engine-candidate.json`; the JSON
records `quartz_revision`, `previous_revision`, and `revision`. The packaged
engine manifest carries the selected engine's provenance. The upload occurs only
after validation succeeds and only when the manual `engine_revision` input is
nonempty. Ordinary PR/main builds and manual builds with no engine input do not
upload this candidate artifact.

A rerun keeps its run ID and replaces that run's development artifact after
successful validation. Download evidence you need to retain before rerunning;
a fresh **Run workflow** request gets a separate run ID and artifact. This
replacement behavior applies only to candidate artifacts, not published releases.

Download it through the run's **Artifacts** section, or use the exact run ID:

```sh
QUARTZ_CANDIDATE_RUN_ID='PASTE_THE_RUN_ID'
QUARTZ_CANDIDATE_DIR="$(mktemp -d -t quartz-engine-candidate)"
gh run download "$QUARTZ_CANDIDATE_RUN_ID" --repo QuartzBrowser/Quartz \
  --name "quartz-webkit-candidate-$QUARTZ_CANDIDATE_RUN_ID" \
  --dir "$QUARTZ_CANDIDATE_DIR"
cat "$QUARTZ_CANDIDATE_DIR/.build/engine-candidate.json"
ditto -x -k "$QUARTZ_CANDIDATE_DIR/dist/Quartz.zip" "$QUARTZ_CANDIDATE_DIR/unpacked"
"$QUARTZ_CANDIDATE_DIR/unpacked/Quartz.app/Contents/MacOS/Quartz" --quartz-webkit-info
```

Compare the recorded SHAs with your intended test before launching. The candidate
is ad-hoc signed and has development update settings; it is not a production
release. Follow the [packaged-app checks](releases.md#packaged-app-smoke-test) and
save evidence before artifact expiry. Gatekeeper behavior for downloaded ad-hoc
apps is described in the [local build checklist](releases.md#local-ad-hoc-build).

### Test locally or through a candidate lock pull request

In a clean Quartz checkout, first create a temporary application branch. The
helper verifies that the selected fork revision is forward from the current pin
and changes only `WebKit.lock.json` in the working tree:

```sh
git switch -c test/webkit-candidate
QUARTZ_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_ENGINE_SHA'
python3 Scripts/update-webkit.py candidate --revision "$QUARTZ_ENGINE_REVISION"
git diff -- WebKit.lock.json
WEBKIT_ARCHS=arm64 Scripts/build-webkit.sh
Scripts/quartz.sh test
QUARTZ_APP_ARCHS=arm64 Scripts/package-macos-app.sh
python3 Scripts/test-webkit-runtime.py dist/Quartz.app/Contents/MacOS/Quartz
```

These local commands are a faster Apple Silicon check. For universal validation,
run `Scripts/build-webkit.sh` and `Scripts/package-macos-app.sh` without those
architecture overrides, then follow the [release checklist](releases.md).
The script builds clean source at the selected SHA; it does not incorporate
uncommitted engine source edits from your separate development checkout.

For a shareable Quartz candidate branch, explicitly commit `WebKit.lock.json`
on that branch and open a Quartz pull request; PR CI then uses that pin. Keep
application changes needed by the engine in the same candidate branch. A test
PR may be left unmerged while you use its evidence to promote the engine and
select it in the release workflow. Candidate testing does not require committing
a lock change to Quartz `main`.

If you merge an explicit lock update, review it as a production dependency
change, ensure its revision meets the target channel's engine membership, and
preserve the evidence. Empty release input keeps the committed pin but still
checks membership: fork `main` for stable, `quartz-dev` for beta. A beta-only pin
merged into Quartz `main` is rejected until the engine is promoted. The selector
does not repair the lock or promote the engine for you.

### Cover the intended behavior

In addition to the generic workflow, record the changed behavior in the packaged
browser. Exercise ordinary and error cases, multiple windows, networking,
downloads, extensions, and any affected page features. Use upstream regression
tests appropriate to the touched subsystem: the existing Quartz tests are not
the complete WebKit layout, JavaScriptCore, or API test suites. Refer to the
upstream checkout's `Tools/Scripts` and [WebKit testing guidance](https://docs.webkit.org/Build%20%26%20Debug/Tests.html)
for the supported commands for that revision.

A feature can be ready for integration before every shipping platform is tested.
Record exactly what passed and what remains unrun; resolve the release-relevant
gaps before declaring the batch ready for users.

## Promote a tested engine batch

For beta publication, the engine must already be integrated into fork
`quartz-dev`; promotion to fork `main` is the additional stable gate.
Promotion moves fork `main` to the tested integration revision while preserving
its SHA. Avoid a squash or a new promotion merge commit, which would create a
revision different from the one you just tested.

In the full engine checkout, after reviewing a successful candidate run:

```sh
(
set -eu
git fetch origin
git switch main
git pull --ff-only origin main
QUARTZ_TESTED_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_TESTED_SHA'
test "$(git rev-parse origin/quartz-dev)" = "$QUARTZ_TESTED_ENGINE_REVISION"
git merge --ff-only origin/quartz-dev
test "$(git rev-parse HEAD)" = "$QUARTZ_TESTED_ENGINE_REVISION"
git push origin main
)
```

The subshell stops at the first failed command without changing your interactive
shell's options. Stop if either `test` fails: development advanced after your
validation, or you selected the wrong revision. Test the new combined tip before promoting it.
Stop if the fast-forward fails and reconcile why `main` contains separate work;
do not force-push it to make the branch names line up. If the remote changes
between fetch and push, the ordinary push must refuse a non-fast-forward update.

Inspect the pushed result and preserve the tested SHA:

```sh
git fetch origin
git rev-parse origin/main
```

This push makes the engine eligible for a release input. It does not change
Quartz's committed lock, publish a GitHub release, or update an installed app.
A stable release may still reject or fail the candidate during final validation.
Beta publication uses the corresponding `quartz-dev` membership gate and still
requires the selected source pair to pass the release workflow.

An annotated engine tag is optional provenance, for example a consistently named
`quartz-engine-*` tag recorded in the batch log. Create it only for the intended
exact SHA. The Quartz selector uses the SHA, not the tag; there is no requirement
to create separate WebKit GitHub releases or distribute a standalone engine ZIP.

## Publish a Quartz release deliberately

### Choose the release inputs

Open **QuartzBrowser/Quartz > Actions > release > Run workflow**. Select
application branch **main** for stable or **beta** for prereleases. The selected
branch determines the channel; there is no free-form channel input.

| Input | Value | Result |
| --- | --- | --- |
| `engine_revision` | Empty | Keep the selected branch's committed lock; still verify channel membership. |
| `engine_revision` | Full 40-character lowercase SHA | Select that exact forward engine for validation and publication. Stable requires fork `main`; beta requires `quartz-dev`. |
| `verify_version` | Existing full label, without `v` | Read-only audit of versioned assets, canonical feed, and legacy feed where applicable. |
| `activate_version` | Existing full label, without `v` | Explicit recovery that verifies and may activate that release's already signed feed. No new app release. |

At most one input may be nonempty. All empty means normal publication with the
committed pin. Version labels must match the application branch: `1.1.0` on
`main`, or `1.1.0-beta.2` on `beta`. Candidate experiments belong in the `build`
workflow. Supporting workflows must exist on the default branch for normal
manual-dispatch availability.

### Publish application changes with the existing engine

For stable:

```sh
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref main
```

For a beta prerelease:

```sh
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref beta
```

Both requests preserve the committed engine SHA and check its channel membership.
A request with no releasable application changes and no unpublished engine for
that channel may complete without a new version. A green no-op is not publication.

### Publish an explicitly selected engine batch

The stable command uses a SHA already promoted to WebKit `main`:

```sh
(
set -eu
QUARTZ_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_PROMOTED_SHA'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref main \
  -f engine_revision="$QUARTZ_ENGINE_REVISION"
)
```

For beta, use a tested SHA integrated into WebKit `quartz-dev`:

```sh
(
set -eu
QUARTZ_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_BETA_ENGINE_SHA'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref beta \
  -f engine_revision="$QUARTZ_ENGINE_REVISION"
)
```

Check the actual run rather than treating dispatch success as a release:

```sh
gh run list --repo QuartzBrowser/Quartz --workflow release.yml --limit 10
gh run watch --repo QuartzBrowser/Quartz
```

The workflow snapshots the selected Quartz branch at dispatch and builds that
application tree. If that remote branch advances during validation, the commit
gate stops instead of rebasing the tested result onto untested application
changes. Review the new source and start a fresh request. Stable and beta share
serialized publication; repeatedly dispatching requests does not hurry a build.

Engine-only batches produce an automatically generated `fix(webkit)` commit.
Stable normally gets patch impact; beta follows semantic-release's prerelease
sequence for the selected version line. Pending `feat:`/breaking application
commits can raise the base version. Upstream engine commit messages do not each
independently bump Quartz's version. Describe intended user-visible feature or
breaking impact deliberately in accompanying Quartz commits and release notes.

Users receive the engine embedded in the signed Quartz application update.
Stable users remain on stable by default; Beta users opt in through the native
channel menu and remain eligible for newer stable releases. They do not select
Git branches or install a separate engine. See [beta/stable operation](BETA_UPDATES.md)
for branch synchronization, numeric versions, promotion, and no-downgrade behavior.

## Release planning and failure recovery

### What the workflow does

The sequence in [release.yml](../.github/workflows/release.yml),
[update-webkit.py](../Scripts/update-webkit.py), and
[publish-update-feed.py](../Scripts/publish-update-feed.py) is:

1. Validate branch and mutually exclusive inputs; snapshot the selected Quartz
   application revision and choose stable or beta from the branch.
2. Validate the exact engine's forward ancestry and channel membership, including
   retained pins. Read the latest matching channel release's lock to determine
   whether that channel already published the engine.
3. Stage the candidate lock in the runner's working tree.
4. Restore an exact verified engine cache or build the fork; run tests,
   packaging/runtime checks, and updater fixtures.
5. Recheck the planned application tree and remote release branch, commit only
   the validated lock or a needed empty engine retry, and push without rewriting.
6. Run semantic-release to prepare and sign a universal app/archive and a feed
   retaining stable/beta history, then publish the versioned GitHub assets.
7. Compare public versioned assets with the prepared bytes, verify checksums,
   and authenticate the signed feed/archive with the configured public key before
   ZIP extraction. Then check app code signing, embedded key, full/base/build/
   channel metadata, and download URL. This audit does not launch the engine again.
8. Verify the already signed appcast using the public key, require unchanged
   retention of currently advertised items, and fast-forward the `update-feed`
   branch. This is raw GitHub feed hosting; it creates no Pages site.
9. Verify the canonical public feed retains the exact signed release item, and
   also verify the legacy route for releases that embedded it. A newer combined
   feed may contain extra items without invalidating the older version's audit.

Local planning is read-only. Fetch release tags first and run the appropriate
channel on the intended application source:

```sh
(
set -eu
git fetch origin --tags
python3 Scripts/update-webkit.py plan --channel stable
)
```

```sh
(
set -eu
git fetch origin --tags
QUARTZ_ENGINE_REVISION='PASTE_THE_FULL_LOWERCASE_BETA_ENGINE_SHA'
python3 Scripts/update-webkit.py plan --channel beta --revision "$QUARTZ_ENGINE_REVISION"
)
```

The plan's `channel` and `release_branch` accompany its exact app/engine SHAs.
`release_required` concerns engine publication on that channel; `false` does not
mean there are no releasable application changes. Planning can fail for missing
tags, unavailable APIs, wrong channel membership, or invalid ancestry. An empty
input never means “follow the branch tip” or “skip the promotion check.”

The lower-level `stage --plan` and `commit --plan` commands are the workflow's
transaction. `commit` can push the selected Quartz `main` or `beta` branch and
requires the matching local branch. It is not a dry run or a substitute for the
validation gates. Use `candidate` for experiments and manual workflows for release.

### Respond according to the failure stage

| Observed result | What may have changed | Next action |
| --- | --- | --- |
| Input, channel membership, or ancestry failure | No new pin committed by the run. | Select the correct branch/SHA, integrate or promote as needed. |
| Build/tests/pre-commit package failure | Temporary candidate files; no validated pin commit from this path. | Fix the cause, retest, and dispatch a fresh request. |
| Selected Quartz branch moved | The old plan is refused. | Review and validate against the new source. |
| Pin committed; app publication failed | Pin, tag, draft, or partial assets depending on stage. | Inspect the actual state and fix the specific failure before publication retry. |
| GitHub assets published; immutable audit failed | Public assets exist; new feed has not been activated by this path. | Investigate and verify assets before activating anything. |
| Assets verified; feed activation failed | A valid signed release snapshot may exist without an active feed item. | Use explicit `activate_version` if it retains current history. |
| Feed pushed; public propagation check failed | Branch may already advertise the new item. | Use read-only `verify_version` and investigate persistent mismatches. |
| Older activation would drop/change newer items | Newer feed history is preserved; activation refuses. | Verify an already retained item or prepare a fresh release against current history. |

A legacy client may see a new stable through GitHub's latest-stable route as soon
as the release is published, before the permanent-feed activation stage. Keep
that migration boundary in view when deciding who may already have an update.

Retries are explicit. Use **Run workflow** against the current selected branch;
historical reruns use old code and can execute obsolete release behavior. Old
queued/running jobs are not cancelled by editing the current workflow. There is
no five-minute schedule or automatic publication retry.

If the selected channel's published release still lacks a committed engine pin,
a new manual publication can create an empty `fix(webkit)` commit to make it
releasable. Once the GitHub release exists, that comparison may be satisfied even
if feed activation failed: use the dedicated activation recovery path for that
case. Do not blindly delete tags, rewrite branches, or replace signed assets.

For a read-only beta recheck:

```sh
(
set -eu
QUARTZ_RELEASE_VERSION='1.1.0-beta.2'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref beta \
  -f verify_version="$QUARTZ_RELEASE_VERSION"
)
```

For explicit activation of that existing beta's verified signed snapshot:

```sh
(
set -eu
QUARTZ_RELEASE_VERSION='1.1.0-beta.2'
gh workflow run release.yml --repo QuartzBrowser/Quartz --ref beta \
  -f activate_version="$QUARTZ_RELEASE_VERSION"
)
```

Use the actual published version. For stable use `--ref main` and a label such
as `1.1.0`; omit `v` and leave other inputs empty. An older version can be audited
if its item remains unchanged in the feed. Activation is allowed only when every
currently advertised item is retained unchanged, and needs the public key rather
than private signing material. Seed the canonical feed before the new verifier
is used on historical assets. See [detailed recovery and migration](BETA_UPDATES.md#inspect-and-recover-a-release)
and [public verification](releases.md#automated-release-boundary).

## Revert a bad change without rewriting history

Before publication, fix or revert the offending customization on a new branch
from the relevant integration state, retest it, and promote the replacement
forward revision. An older selected SHA can be used only if it still descends
from Quartz's currently committed pin and is reachable from fork `main`.

After publication, do not reset `main`, move a release tag, or repin Quartz to an
older engine SHA. Create a new engine commit that reverts the faulty behavior,
validate it, promote it, and publish a new Quartz version. This preserves the
updater's forward engine history and gives installed applications a higher
version to install.

For a single ordinary custom commit, work on a new feature/hotfix branch from
the appropriate current engine state and use:

```sh
git revert FULL_SHA_OF_THE_BAD_NON_MERGE_COMMIT
```

Choose the exact affected commit after inspecting its patch and dependencies.
Reverting a merge requires choosing the correct mainline parent and changes how
later merges are treated; investigate that history separately instead of copying
a generic `-m` command. Reverting an entire upstream sync may discard important
fixes, so prefer a focused regression fix when it is viable.

If `quartz-dev` contains unrelated unfinished work, create a hotfix branch from
fork `main`, test the fix against the release application tree, and fast-forward
`main` to that tested hotfix. Then merge the resulting fork `main` back into
`quartz-dev` before the next normal promotion. Preserve both histories and retest
the integration. The release's forward ancestry checks remain in force.

## Caches, builds, and evidence

### Test the maintenance tools and workflow rules

These checks exercise engine selection and transaction behavior in disposable
Git repositories, parse the actual workflow event/permission rules, and execute
the promotion instructions against temporary remotes. They do not build WebKit,
contact GitHub, or push a real repository:

```sh
python3 Scripts/test-engine-updates.py
python3 -m venv .build/workflow-tests-venv
.build/workflow-tests-venv/bin/python -m pip install -r Scripts/requirements-workflow-tests.txt
.build/workflow-tests-venv/bin/python Scripts/test-workflow-policy.py
```

Installing the pinned PyYAML dependency requires package-registry access unless
it is already cached. The tests themselves run locally. Normal hosted CI runs
both suites in its Linux policy job before starting the macOS build. Changes to
engine selection, publication permissions/triggers, or the documented promotion
commands should retain these checks and extend them for changed behavior.

### Separate development source from reproducible builds

Keep three different things distinct:

- A full engine editing checkout with branch history, local work, and regression
  tests.
- A clean source/raw-build cache per pinned revision under a whitespace-free
  path, used by `Scripts/build-webkit.sh`.
- Prepared engine products containing manifests, binary hashes, architecture
  information, source revision, and relocated framework/service dependencies.

The default local source/raw cache is
`~/Library/Caches/Quartz/WebKit/REVISION/`. Prepared products normally live at
`.build/quartz-webkit/products/Release` in the Quartz checkout. See the complete
[path and environment variable table](WEBKIT.md#build-the-engine). When retaining
multiple candidates, give them separate source, raw build, and products paths;
set `QUARTZ_WEBKIT_PRODUCTS_DIR` to the selected products for Quartz commands.
The directories must not overlap. Do not edit `QuartzWebKit.json` to pretend old
binaries came from a new source revision.

### Treat caches as acceleration

Hosted CI caches exact prepared engine products for the source/build/toolchain
identity and verifies a restored cache before use. A candidate build can warm a
usable cache, but that is not guaranteed: branch visibility rules, retention,
eviction, runner/toolchain changes, or changed build inputs can cause a miss.
An uncached universal build may take substantial time and disk space even when a
previous candidate built successfully. See [CI cache details](WEBKIT.md#ci-cache).

A cache is not a release archive. Preserve release assets and evidence separately.
Workflow logs and any Actions artifacts follow GitHub/repository retention and
can expire; save the evidence needed for a long-lived customization or release
record. A build's existence in the Actions list does not guarantee its outputs
remain available for later testing. Downloaded candidate packages, if supplied
by a workflow, are development artifacts until the publication pipeline signs
and verifies the actual release bytes.

### Record what each check establishes

| Evidence | Establishes | Does not establish by itself |
| --- | --- | --- |
| Python/shell helper tests | Selected validation, pin, packaging, and retry behaviors in fixtures. | A compiled engine or a working browser. |
| System-engine development tests | Quartz behavior against the installed Apple WebKit. | Compatibility with the custom fork. |
| Completed arm64 engine and Quartz test run | That tested source/toolchain combination on Apple Silicon. | Universal products or Intel runtime behavior. |
| Universal binary architecture checks | Both required slices are present. | Successful launch on both processor types. |
| Packaged engine diagnostic | Which engine images the launched process loaded and their provenance checks. | All content-process/networking behavior. |
| Packaged rendering/network smoke test | The exercised host's isolated page, JavaScript/layout, and loopback networking path. | The whole WebKit test suite or every real website. |
| Targeted upstream regression tests | The covered custom engine behavior for the selected configuration. | Uncovered browser integration paths. |
| Disposable updater signing/tamper tests | Fixture update creation and rejection behavior. | A successful production publication or installed-user upgrade. |
| Public-download verification | The checks actually logged against the published assets and URLs. | Every supported hardware/OS combination or a complete in-app upgrade exercise. |

Use [WEBKIT.md](WEBKIT.md) for build/runtime mechanics,
[releases.md](releases.md) for packaging/platform verification, and
[UPDATES.md](UPDATES.md) for signing and the actual update installation checks.

## Maintenance cadence

A reasonable starting policy is to review upstream activity each working day,
prepare small upstream sync batches regularly, and publish when the tested batch
is ready. Adjust the cadence to upstream change volume and available build
capacity. This is a maintainer routine, not a newly installed scheduled job.
Record the last reviewed upstream SHA/date and the current fork lag.

Treat relevant security fixes as a separate urgency decision. Check upstream
security information, affected functionality, and the actual commits available
to the fork; do not infer safety solely from a browser version label. When a fix
matters to Quartz, prepare and validate a focused forward update promptly rather
than waiting for the next feature batch. A selective cherry-pick may be suitable
for an urgent fix, but record the original upstream SHA, dependencies, conflicts,
and eventual reconciliation in the next full upstream merge.

For each sync, review the customization ledger and toolchain/deployment changes.
For each promotion, record the exact tested engine/app pair. For each publication,
review the release output and public-download result. Periodically retire
customizations upstream now supports, remove obsolete one-time cache migrations
when appropriate, and exercise a cold build so cache reuse does not conceal a
broken reproduction path.

## Records and checklists

### Upstream sync record

Copy this into the fork PR or its linked maintenance record:

```markdown
## Upstream sync

- Previous quartz-dev SHA:
- Upstream main SHA fetched:
- Resulting merge / integration SHA:
- Commit range reviewed:
- Customization ledger entries reviewed:
- Conflicts and resolution rationale:
- Customizations removed or replaced, with evidence:
- Toolchain / SDK / deployment / framework-layout changes:
- Upstream regression commands and results:
- Quartz candidate branch, SHA, and run URL:
- Runtime platforms exercised:
- Remaining gaps or blockers:
- Promotion decision:
```

### Engine promotion checklist

- [ ] The candidate descends from both current fork `main` and Quartz's current
  pinned engine revision.
- [ ] The intended upstream updates and custom changes are included; unrelated
  experiments are excluded from the batch.
- [ ] The customization ledger and conflict-resolution record are current.
- [ ] Required upstream regressions pass for the actual combined integration SHA.
- [ ] The Quartz candidate run records the exact engine/app SHA pair and passes
  the required build, tests, package, and runtime gates.
- [ ] Supported platform evidence and any unresolved limitations are recorded.
- [ ] Fork `main` fast-forwards to the tested SHA without history rewriting.
- [ ] The pushed SHA is verified and recorded. No publication is implied.

### Quartz publication record

Copy this into the release's maintenance record or linked issue/PR:

```markdown
## Quartz publication

- Requested date / maintainer:
- Channel and Quartz application release branch:
- Quartz application SHA at dispatch:
- Previous committed engine pin:
- Selected engine SHA, or explicit keep-current-pin decision:
- Fork promotion evidence:
- Engine upstream base and customization summary:
- Candidate CI and targeted regression evidence:
- Release workflow URL and conclusion:
- Final Quartz release tag / source SHA:
- Published WebKit.lock.json revision:
- Published version, assets, and SHA256SUMS:
- Versioned public-asset verification run and outcome:
- update-feed commit and active public-item verification:
- Legacy feed check, if applicable:
- verify_version / activate_version recovery, if any:
- Apple Silicon / Intel / macOS versions actually exercised:
- In-app update installation and restoration result:
- Checks still unrun and operational follow-up:
```

Do not put signing secrets or credential values in these records. Keep exact
asset bytes and logs wherever your release retention policy requires; a link to
an expired workflow artifact is not durable evidence.

## Permissions and repository settings

The Quartz workflow reads the public WebKit fork and uses Quartz's existing
`GITHUB_TOKEN` plus its existing Sparkle signing configuration for publication.
No cross-repository personal access token, engine publication webhook, or engine
GitHub release is required. Human fork pushes and Quartz workflow dispatches use
your normal GitHub access to those repositories.

Workflow dispatch requires the relevant GitHub repository permissions. The
release commit also needs permission to update Quartz `main`; if branch rules
block the existing automation, inspect that rule and choose a narrowly scoped
repository policy. Do not introduce a broad token just to bypass a failing gate.
The [update signing setup](UPDATES.md#one-time-repository-configuration) describes the existing
keys and the [release checklist](releases.md) explains the ad-hoc signing boundary.

On 2026-09-13, the fork's default branch was set to `quartz-dev`. Both `main`
and `quartz-dev` received protection that disallows force pushes and deletion,
including for administrators. Normal direct/fast-forward pushes remain allowed.
No required pull request reviews, required status checks, or push-actor
restrictions were added. The PR review, candidate validation, and promotion
checklists in this manual are maintainer procedures; the branch rules do not
mechanically prove those checks were performed.

Inspect the live rules before relying on that dated configuration. If adding
stricter rules later, align merge settings with preserved upstream ancestry and
fast-forward promotions; a blanket squash-only policy or required linear history
can conflict with real upstream merges. Required checks should be actual checks
that run for the protected branch, with the intended policy explicitly configured.
These fork protections do not change Quartz's application-branch permissions.

GitHub's [manual workflow instructions](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)
cover the UI, permissions, and CLI. Its [workflow event reference](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch)
explains dispatch behavior. The workflow definitions in this repository determine
which inputs and guards Quartz actually implements.

## Troubleshooting and FAQ

### I committed ten times. Did that create ten releases?

No. Neither fork pushes nor Quartz `main`/`beta` pushes start the release workflow.
They can contribute to one later manually requested release. Quartz PR/main/beta CI
still runs automatically so everyday integration receives validation.

### I promoted WebKit main. Why has my installed Quartz not changed?

Promotion only makes an engine revision eligible. Request a Quartz release with
that SHA, wait for successful publication/public verification, and install the
resulting Quartz update. An installed app uses its embedded engine, not a live
Git branch.

### I left engine_revision empty. Will it pick up the latest fork main?

No. Empty means keep the selected Quartz branch's committed lock and still check
engine membership: fork `main` for stable, `quartz-dev` for beta. Supply the full
eligible SHA when you intentionally want an engine update. This applies even if fork `main`
is hundreds of commits ahead.

### Can I test a branch before it is on WebKit main?

Yes. Push its commit to the fork, then use manual `build` or local `candidate`.
Beta publication requires integration into fork `quartz-dev`; stable publication
requires promotion to fork `main`. A candidate artifact alone reaches neither
user update channel.

### Can I type a branch name, a GitHub URL, or a short SHA?

No. Use the complete lowercase SHA returned by `git rev-parse` for the intended
commit. This avoids a branch moving between your decision and an expensive build.
Workflow input is passed as data through an environment variable; do not embed
shell commands or expressions in it.

### Why does the helper refuse a candidate with unrelated or older history?

Quartz requires forward ancestry from its committed pin. Fetch the right fork
refs and inspect the merge history. Fix the development history through reviewed
forward changes; resetting the lock or force-pushing a branch defeats that
contract. Published regression recovery uses a new revert/fix commit.

### Why does promotion fail after the candidate passed?

The development branch may have advanced, or fork `main` may contain a separate
hotfix. Reconcile that history, test the resulting combined SHA, and promote the
tested revision. Do not silently ship new commits because an older run was green.

### Why did the release say Quartz main changed?

The application changed after the release snapshot. That engine was validated
against a different app tree. Review the new Quartz head and dispatch a fresh
run. Avoid merging into Quartz `main` during a release if you want that run to
complete without becoming stale.

### Why did a release request finish without creating a version?

There may be no releasable Quartz commits and no unpublished engine revision.
Check the semantic-release output and latest release instead of counting a green
workflow as a release. Engine-only publication is represented by `fix(webkit)`;
ordinary documentation/chore changes may not require a new version.

### Does every upstream feat commit increase Quartz's version?

No. semantic-release analyzes Quartz's application history. The engine selector
represents the selected batch with one `fix(webkit)` commit. Describe any intended
Quartz feature/breaking impact deliberately in accompanying application commits.

### Can I make a separate WebKit release for every tested engine?

You can maintain optional tags or release records if useful, but Quartz neither
requires nor consumes engine GitHub releases. The lock's SHA and bundled engine
manifest identify the actual source. Avoid extra publication work without a
specific consumer or retention need.

### Can I edit the cached source checkout directly?

Use the full development clone for engine work. The default source cache is
shallow, sparse, and expected to be clean at an exact revision. Commit and push
engine changes, select their SHA, then let the build helper create a clean source
checkout. Use separate build paths when retaining older candidates.

### Why did candidate CI rebuild an engine that previously passed?

Prepared product reuse needs a compatible exact cache identity and access to the
cache under GitHub's rules. Eviction, retention, toolchain/runner differences,
and build-script changes can require a fresh build. Source equality alone does
not imply interchangeable binaries or cache availability.

### Is universal packaging proof that Intel works?

It proves the required slices are present when those checks pass. Runtime tests
run on the host architecture. Record an actual Intel run, Rosetta run, and tested
macOS versions separately; none is an automatic substitute for the others.

### Does a successful recheck publish a fixed app?

No. `verify_version` rechecks existing assets and their retained feed item.
`activate_version` can advertise an existing signed snapshot only when it retains
current history. If the app needs correction, create a forward fix and publish
a higher version on the intended channel; do not replace the signed ZIP.

### Where do I look when documentation and GitHub disagree?

Inspect the workflow on the live default branch, the exact run's source SHA and
inputs, Quartz's committed lock, the fork's actual refs, and the release tag and
assets. Local edits, this manual, or an old green run do not prove current hosted
configuration or publication. Check for runs queued before a trigger change.

## Decision record

**Decision:** use `quartz-dev` for engine integration, preserve real upstream
merges, promote tested engine SHAs to fork `main`, and publish Quartz through a
manual workflow with an exact engine selector and stable/beta application branch
selection. Both retained and selected pins obey the channel's integration gate. Keep normal CI automatic.

**Reason:** engine development, upstream synchronization, validation, and user
release each have different timing and evidence needs. A moving branch is useful
for collaboration; an immutable SHA is necessary for a reproducible candidate.
A deliberate publication action lets application and engine work collect into
reviewable batches without making every commit a release.

**Alternatives considered:** using engine `main` as an automatic publication
signal would keep promotion simple, but it would make a branch-management action
also start delivery. Scheduled polling of fork `main` would couple source drift
to expensive release builds and retry publication without a fresh decision.
A release per commit would produce needless updates and does not improve test
coverage. Replacing the fork with a repeatedly rebased patch stack would rewrite
shared history and conflict with the forward-only pin contract.

**Consequences:** maintainers must explicitly select engine upgrades and request
publication. There is no automatic upstream monitor or unattended publication
retry supplied by this change. A regular review routine matters, particularly
for security updates. Long-lived customizations require a regression inventory,
and upstream conflict resolution remains engineering work. Cache reuse can
reduce build cost but is not guaranteed. These are deliberate operating choices,
not hidden behavior in a commit hook.

**Review this decision when:** maintainers need a supported release branch for a
long-lived version, build capacity makes candidate testing impractical, upstream
changes require a different integration model, or reliable automated monitoring
with human-controlled publication becomes desirable. Preserve explicit source
selection and verifiable release gates in any replacement process.
