# Extensions Policy

## Ad blockers are welcome. That is a commitment.

**I will not ban, block, sabotage, or deliberately get in the way of an extension
because it blocks ads or trackers.** This applies to third-party ad blockers,
including ones that compete with, outperform, or completely replace Quartz's
built-in blocker.

**You do not have to use Quartz's built-in ad blocker.** You can turn it off and
use a compatible extension instead. Choosing another blocker is a supported user
choice, not a problem for Quartz to prevent.

This commitment applies to Quartz's maintenance, extension support, and future
development. It does not expire when the built-in blocker gets better.

## What Quartz will not do

- Ban, reject, remove, or disable an extension for blocking ads or trackers.
- Deliberately break or weaken an ad blocker, restrict extension APIs to defeat
  ad blocking, or add installation obstacles aimed at ad blockers.
- Favor a Quartz-maintained blocker by deliberately disadvantaging alternatives.
- Require the built-in blocker to stay enabled as a condition of using extensions,
  or turn it back on to override your choice of another blocker.
- Require an ad blocker to allow particular ads, advertisers, or trackers in
  exchange for being allowed in Quartz.
- Use advertising revenue, sponsorships, partnerships, or pressure from websites
  as a reason to obstruct your chosen ad blocker.

**Blocking ads is not grounds for an extension ban. Replacing Quartz's built-in
blocker is not grounds for an extension ban.**

## About the built-in blocker

Right now, frankly, Quartz's built-in ad blocker sucks. It has a small set of
rules for some obvious third-party ad resources, and it misses plenty. I will
keep working on it, but you should not have to wait for that work or settle for
it if a compatible extension works better for you.

Use **View > Disable Basic Ad Blocker** to turn it off in the current browser
window. The shield button and **Shift-Command-B** toggle it too. Keeping it on,
turning it off, or using an extension instead is your choice.

## Compatibility and security

Quartz loads WebExtensions through WebKit on macOS 15.4 or newer. An extension
being welcome does not guarantee that every Chrome extension or API works in
Quartz. Missing APIs, platform limits, and bugs can affect ad blockers too. These
are technical limitations to explain and work on, not reasons to prohibit ad
blocking. Quartz will not deliberately create or preserve a compatibility
problem to suppress an ad blocker.

Extensions still need your permission for the access they request. An extension
that steals data, bypasses consent, or otherwise harms users can be restricted
for that behavior, whether or not it also blocks ads. Any such restriction must
address the specific harmful behavior and apply equally to Quartz-maintained and
third-party extensions. Blocking ads or trackers, competing with the built-in
blocker, and reducing advertising revenue are not harmful behavior under this
policy. Security and compatibility must never be used as pretexts to suppress
ad blockers.

## For contributors and users

Changes to extension installation, permissions, APIs, and content blocking must
respect this policy. If a change breaks an ad blocker, investigate it as a
compatibility regression rather than treating the blocker as unwelcome.

Report compatibility problems or behavior that contradicts this policy through
the repository's GitHub issues, with the Quartz, macOS, and extension versions
and steps to reproduce. Report security vulnerabilities privately through
[SECURITY.md](SECURITY.md). See the [extension guide](docs/extensions.md) for
installation, permissions, and troubleshooting.
