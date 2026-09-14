# Stable and beta update rollout record

On 2026-09-14, Quartz published stable `1.1.0` with the native channel selector
and first beta `1.1.1-beta.1` to validate opt-in distribution. Both retain the
same engine revision. This record separates source/CI checks, signed public feed
eligibility, and installation evidence. Operating procedures remain in the
[beta update manual](BETA_UPDATES.md),
[engine maintenance manual](WEBKIT_MAINTENANCE.md), and
[release checklist](releases.md).

## Implementation and validation

- Implementation: [PR #67](https://github.com/QuartzBrowser/Quartz/pull/67), tested
  head `a1fc416692f24fa32727a5dc78b22ebc03a3e35c`.
- Merge to Quartz main: `0fbc211ccc01fc53f0c2c6e6f19565f601a06f7a`.
- Engine retained: `4a523b0b3d1ddf66abbf9ec9b6351248e57db73c`.
- [PR build run](https://github.com/QuartzBrowser/Quartz/actions/runs/34855487842):
  succeeded. Workflow policy and real fork test/package jobs passed.
- Hosted Xcode 26.6 run: 228 Swift tests passed; exact verified universal fork
  cache restored; universal app/ZIP, extracted app signing, fork provenance,
  host rendering/network checks, and disposable updater fixtures passed.
  Cache reuse is not a fresh engine compilation result.
- [CodeQL run](https://github.com/QuartzBrowser/Quartz/actions/runs/34855483555):
  JavaScript/TypeScript and Python analyses succeeded.
- [Post-merge build](https://github.com/QuartzBrowser/Quartz/actions/runs/34856682147):
  succeeded on the merge SHA above; 228 Swift tests passed with the real pinned
  fork, together with the configured package/runtime/update gates.
- [Stable publication run](https://github.com/QuartzBrowser/Quartz/actions/runs/34856709293):
  succeeded. Published the stable bridge and passed immutable public-asset and
  canonical active-feed verification; details appear below.

Local implementation evidence is preserved in ignored logs. Local engine mode
was explicitly system WebKit; these results do not prove the bundled fork path.
The hosted PR run above supplies final-head fork integration evidence.

| Local gate | Observed result | Log retained under `.build/` |
| --- | --- | --- |
| Full native suite, system engine | 228 tests, 0 failures. | `beta-full-swift-tests.log` |
| Engine planning and workflow policy | 61 engine-selection tests and 16 workflow/promotion tests passed. | Hosted logs and `beta-workflow-policy-tests.log` |
| Version mapping | 6 tests passed. | `beta-version-tests.log` |
| Appcast finalization/history | 9 tests passed. | `beta-appcast-tests.log` |
| Feed publication/signature/race fixtures | 28 tests passed. | `beta-feed-tests.log` |
| Public verification routing/authentication order | 8 tests passed; orchestration fixtures. | `beta-public-verification-tests.log` |
| Preparation fixtures | 6 tests passed. | `beta-prepare-tests.log` |
| Universal updater fixtures, system engine | Legacy migration, stable/beta/beta/stable sequence, signed history, channel/label/tamper and missing-key rejection passed. | `beta-update-packaging.log` |
| Documentation integrity | 127 local links/anchors and 70 shell examples validated during documentation integration. | Tool result; no standalone retained log. |

## Seed and branch state

- Migration baseline: original signed GitHub `v1.0.1` appcast.
- Seed `update-feed` commit observed:
  `1e43eb2af5a41b6231ddb73cfd559fd8fc75b88f`.
- Seed signature: verified by the signed baseline eligibility probe. The seed
  preserves the original signed stable appcast bytes.
- Seed appcast SHA-256:
  `886ad92dd2fd3ad2452b46255bfc6add2311de2c9568f7a0f9a9a66d1456a6ec`.
- `update-feed` no-force-push/no-deletion protection, including administrators,
  was confirmed during rollout.
- Stable engine `main` was exactly the retained engine SHA at preparation.
- Engine `quartz-dev` was `2f8a73b69760b8eb87109d7f3cfdbbb9622a775e`, one commit
  ahead, with merge base equal to the retained pin. Both channel membership checks
  passed without moving the lock.
- Quartz beta was created from the exact stable `v1.1.0` semantic-release/tag
  commit `d68cddefd78cb381228423ccc188d153875984f8`.
- Quartz beta and `update-feed` protections were rechecked at approximately
  `15:02Z`: force pushes and deletion remained disabled, including for admins.
  WebKit refs still matched the `main` and `quartz-dev` revisions recorded above.

## Stable bridge publication

| Field | Evidence |
| --- | --- |
| Workflow | [34856709293](https://github.com/QuartzBrowser/Quartz/actions/runs/34856709293) |
| Dispatch application SHA | `0fbc211ccc01fc53f0c2c6e6f19565f601a06f7a` |
| Engine input and final pin | Empty input; tagged lock retains `4a523b0b3d1ddf66abbf9ec9b6351248e57db73c`. |
| Final conclusion | **SUCCESS** |
| Released tag / full label | [v1.1.0](https://github.com/QuartzBrowser/Quartz/releases/tag/v1.1.0); published `2026-09-14T14:45:11Z`. |
| Final semantic-release source commit | `d68cddefd78cb381228423ccc188d153875984f8` |
| Numeric build / base version | `102.0.99` / `1.1.0`; full label `1.1.0`. |
| GitHub stable/prerelease flags | Published ordinary release; `prerelease: false`. |
| Versioned ZIP size / SHA-256 | 146,025,416 bytes; `6d837b3a331da514d34b8fd1675bdf2055e72811abb7e9a4b7bcb89850b1232b`. |
| Versioned appcast SHA-256 | `c4c840275d0c0ac3a19c2358e399a93e07436b1a638de0473fd050d6fbeb3f55` |
| SHA256SUMS asset SHA-256 | `c3ece731f11ed150c7aa70d2064a1ded4fdf6068b82768d2c20bd3d4b455e1d8` |
| Authentication before extraction / embedded key | Passed in the hosted stable publication run; retained in `.build/beta-stable-release.log`. |
| Activated update-feed commit | `398da4971f48e28bc1261f5e5b57f9cc1ee90b4e` |
| Canonical public item verification | Passed on attempt 27 of 36 at `14:50:03Z`; feed contains signed `1.1.0` plus all five original items. |
| Canonical feed SHA-256 at stable activation | `c4c840275d0c0ac3a19c2358e399a93e07436b1a638de0473fd050d6fbeb3f55` |
| Legacy latest-stable route check | Real isolated Sparkle probe selected signed `1.1.0` / build `102.0.99` for legacy current build `1.0.1` and Stable channel. See matrix below. |
| Activation recovery | None; ordinary propagation retries succeeded. |

The independent metadata audit is retained at
`.build/public-release-audit/evidence/20260914T144952.374547Z/v1.1.0/audit.json`.
It downloaded and authenticated the appcast and read checksum/release metadata;
its ZIP digest agrees between GitHub's reported digest and `SHA256SUMS`. It did
**not** download or independently hash/verify the ZIP. Full archive authentication,
extraction, embedded-key checks, and byte comparisons were performed by the hosted
stable release job, which also passed 228 Swift tests. The hosted job supplies the archive verification evidence.

## Initial beta publication

Beta was created from the completed stable semantic-release source, not the
pre-release merge commit. The initial dispatch validates channel distribution
with the same browser/engine behavior as the stable bridge; its release version,
numeric build, signatures, and channel metadata are still separate.

No prior beta existed, so channel-specific planning treated the unchanged engine
as unpublished on beta. The empty `fix(webkit)` commit
`ac1bb3ebae009e25ca71fed612113c0c9ee316d4` supplied patch impact and semantic-release
created `1.1.1-beta.1`, build `102.1.1`. Comparing the stable and beta source tags
changes only `CHANGELOG.md` and `version.txt`; browser and engine code are the
same. The prerelease validates distribution rather than introducing new features.

| Field | Evidence |
| --- | --- |
| Beta initialization SHA / equality with stable tag | `d68cddefd78cb381228423ccc188d153875984f8`, equal to stable `v1.1.0` tag. |
| Purpose | Channel validation with unchanged browser/engine behavior. |
| Workflow run URL | [34858253881](https://github.com/QuartzBrowser/Quartz/actions/runs/34858253881) |
| Dispatch application SHA | `d68cddefd78cb381228423ccc188d153875984f8` |
| Engine input / final pin | Empty input; tagged lock retains `4a523b0b3d1ddf66abbf9ec9b6351248e57db73c`. |
| Final workflow conclusion | **SUCCESS**; 228 Swift tests, signed package fixtures, public archive authentication, feed activation, and active-feed verification passed. |
| Published tag / full label | [v1.1.1-beta.1](https://github.com/QuartzBrowser/Quartz/releases/tag/v1.1.1-beta.1); published `2026-09-14T14:59:45Z`. |
| Final beta semantic-release commit | `faf297d491f341d87769f8105a03d017a213d76e` |
| Numeric build / base version | `102.1.1` / `1.1.1`; full label `1.1.1-beta.1`. |
| GitHub prerelease flag | `true`; GitHub's latest-stable API remained `v1.1.0`. |
| Versioned ZIP size / SHA-256 | 146,025,417 bytes; `037107c9fd1ac09c3148bd53a6145d243abee303581596c0a80a2887b8925e4e`. |
| Versioned appcast SHA-256 | `de58aa81c09cfdef0b293383fe6068a707f4ebed97ad11ac0a6fee2eacb0c00b` |
| SHA256SUMS asset SHA-256 | `62eebb8d17b6a62489df1e08690d18af6f811c8f0da491f4935a17e7a36ff066` |
| Immutable public-asset audit | Passed in the hosted publication path before feed activation. Independent feed/checksum metadata audit also passed; its scope is described below. |
| Activated update-feed commit | `6c2bfac9096a52775b9d60931a9ffe58a8a0fbbb` |
| Canonical public item verification | Passed in the six-case real Sparkle probe at `2026-09-14T15:01:46.811601Z` and in the release workflow on attempt 26 of 36 at `15:04:38Z`. |
| Retained feed history | Seven signed-feed items: the new beta plus all six previous stable items unchanged. Direct `ensure_retained` checks passed for both the original seed and stable bridge against the final feed. |
| Canonical bytes / branch equality | Signed canonical bytes exactly matched `origin/update-feed` at `6c2bfac9096a52775b9d60931a9ffe58a8a0fbbb`; SHA-256 `de58aa81c09cfdef0b293383fe6068a707f4ebed97ad11ac0a6fee2eacb0c00b`. |
| Activation recovery | None requested; normal publication advanced the feed. |

The independent beta audit is retained at
`.build/public-release-audit/evidence/20260914T150111.085004Z/v1.1.1-beta.1/audit.json`.
As with the stable audit, it authenticated the signed feed and checked release,
engine-lock, checksum, and GitHub-reported ZIP digest metadata. It did not download
or independently hash/authenticate the beta ZIP; that archive gate belongs to
the hosted publication run.

## Live eligibility matrix

Live selection evidence comes from an **isolated real Sparkle probe**, not a
running distributed Quartz app. The probe creates a UUID metadata-only host,
sets its numeric current build and allowed channel, and calls Sparkle's public
`checkForUpdateInformation` API against the signed public feed. It verifies the
feed signature and records Sparkle's selected item or no-update result. It does
not download an archive, install anything, launch an installed Quartz profile,
or touch that profile's preferences.

The six-case matrix ran at `2026-09-14T15:01:46.811601Z` on Apple Silicon
(`arm64`), macOS `26.6.2` build `25G83`. It used the original Sparkle SwiftPM
checkout `ac2def288cbff5cfc7df3ffef6abdf45b72bcb0a`. Every case verified the feed
signature, reported `installation_attempted: false`, and used a separate UUID
identity. The temporary hosts were removed and their preference values cleared afterwards.
The exact [six-case eligibility JSON](release-evidence/2026-09-14-beta-eligibility.json)
is retained alongside this record. Workspace copies remain in
`.build/beta-live-eligibility.json` and `.build/beta-live-eligibility.log`.

This proves real Sparkle eligibility decisions for the supplied host metadata
and live signed feeds. It does not establish native menu interaction, a packaged
Quartz runtime, or update replacement/relaunch.

| Probe current numeric host build | Requested channel | Public feed | Observed signed selection | Result |
| --- | --- | --- | --- | --- |
| `1.0.1` | `stable` | Legacy latest-stable URL | `1.1.0`, build `102.0.99`, Stable item. | Passed |
| `1.0.1` | `stable` | Canonical combined feed | `1.1.0`, build `102.0.99`, Stable item. | Passed |
| `102.0.99` | `stable` | Canonical combined feed | `no_update`; beta excluded. | Passed |
| `102.0.99` | `beta` | Canonical combined feed | `1.1.1-beta.1`, build `102.1.1`, Beta item. | Passed |
| `102.1.1` | `stable` | Canonical combined feed | `no_update`; no downgrade to older stable. | Passed |
| `102.1.1` | `beta` | Canonical combined feed | `no_update`; latest beta already current. | Passed |

Earlier baseline probes recorded signed `no_update` for current `1.0.1` before
the bridge and selected stable `1.1.0` after it published. Those snapshots remain
in `.build/beta-live-seed-eligibility.json` and
`.build/beta-live-stable-legacy-eligibility.json`.

A live same-base `1.1.1-beta.1` to final stable `1.1.1` selection could not be
observed because stable `1.1.1` had not been published. Same-base beta-to-stable
ordering and selection are covered by the signed local/hosted fixture sequence,
not by a fabricated live-feed item.

Native channel behavior has separate **unit-test evidence** in the passed
`QuartzUpdateMenuTests`, `QuartzUpdateControllerTests`, and
`QuartzUpdateUserDriverTests` suites. Those tests cover menu selection/state,
channel persistence/allowed channels, revocation of an excluded pending update,
late-callback rejection, and extraction/installation switching boundaries. See
`beta-full-swift-tests.log` and the hosted PR test run above. They are not live
menu clicks on the distributed app and are not performed by the eligibility
probe.

## Unrun or separate gates

- Distributed-app update discovery, archive download, replacement, relaunch,
  and session restoration: **intentionally unrun on the current account**.
  The unchanged Quartz application identity cannot safely isolate its defaults,
  IPC, and process-replacement behavior from the user's installed browser here.
  The UUID metadata-only probe verifies signed eligibility without exercising
  those operations; it is not an installation test.
- Native menu interaction on a distributed stable/beta app: **unrun**. Menu/controller/race unit tests passed; the live Sparkle
  probe does not exercise the native menu or packaged Quartz runtime.
- Intel hardware runtime, Rosetta-specific execution, and the full supported macOS
  matrix: **unrun in this rollout**. Universal slices do not prove them.
- A fresh cold compilation of the entire engine in this rollout: **not proved by
  the verified-cache CI run**.
- Developer ID signing, notarization, and Gatekeeper acceptance as notarized
  software: **not configured/claimed**; releases use ad-hoc app signing and
  Ed25519 update signatures.

The signed assets and workflow links identify the published releases. Ignored
local logs and probe JSON paths identify retained workspace evidence; they are
not additional public downloads or installation claims.
