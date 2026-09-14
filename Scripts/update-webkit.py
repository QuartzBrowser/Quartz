#!/usr/bin/env python3
"""Select, validate, and stage deliberate Quartz WebKit engine updates.

`plan` is read-only and keeps the committed engine pin by default. An explicit
`plan --revision FULL_SHA` selects an exact forward descendant. Stable publication
always requires WebKit/main membership, even for an unchanged committed pin;
`--channel beta` instead requires WebKit/quartz-dev membership. The release
workflow builds the staged plan before calling `commit`; publication retries
are isolated to the selected channel and retain the same validated engine.

`candidate --revision FULL_SHA` validates any forward fork commit, including a
development branch, and changes only the local lock revision for build testing.
It requires a clean tracked tree/index, leaves the change unstaged, and never
queries releases or the promoted branch, commits, pushes, or publishes anything.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = "WebKit.lock.json"
ENGINE_REPOSITORY = "https://github.com/QuartzBrowser/WebKit.git"
RELEASE_BRANCHES = {"stable": "main", "beta": "beta"}
VERSION_PATTERN = r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"


def git(repository, *arguments, check=True):
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        text=True, capture_output=True, check=False,
    )
    if check and result.returncode:
        # Do not echo command arguments or remote output: credentials may occur
        # in a developer's remote configuration.
        raise RuntimeError(f"Git operation failed ({arguments[0]}, exit {result.returncode})")
    return result


def sha(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ValueError("Expected a complete lowercase Git revision")
    return value


def read_lock(contents):
    lock = json.loads(contents)
    if not isinstance(lock, dict) or type(lock.get("schemaVersion")) is not int or lock["schemaVersion"] != 1:
        raise ValueError("Unsupported WebKit lock schema")
    if lock.get("repository") != ENGINE_REPOSITORY:
        raise ValueError("The engine must come from QuartzBrowser/WebKit")
    sha(lock.get("revision"))
    for field in ("minimumXcode", "macOSDeploymentTarget"):
        if not isinstance(lock.get(field), str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", lock[field]):
            raise ValueError(f"Invalid {field} in WebKit lock")
    return lock


def head(repository):
    return sha(git(repository, "rev-parse", "HEAD").stdout.strip())


def validate_plan(plan):
    if not isinstance(plan, dict):
        raise ValueError("Expected an engine update plan")
    if (not isinstance(plan.get("channel"), str) or plan["channel"] not in RELEASE_BRANCHES
            or plan.get("release_branch") != RELEASE_BRANCHES[plan["channel"]]):
        raise ValueError("Invalid release channel or branch in engine update plan")
    for field in ("quartz_revision", "previous_revision", "revision"):
        sha(plan.get(field))
    if plan.get("published_revision") != "":
        sha(plan.get("published_revision"))
    required = plan["revision"] != plan["previous_revision"] or plan["revision"] != plan["published_revision"]
    if type(plan.get("release_required")) is not bool or plan["release_required"] != required:
        raise ValueError("Inconsistent engine update plan")


def ensure_descendant(api, previous, revision, message):
    """Require exact ancestry, rather than accepting a merely newer timestamp."""
    if revision == previous:
        return
    comparison = api(f"/repos/QuartzBrowser/WebKit/compare/{previous}...{revision}")
    if (not isinstance(comparison, dict) or comparison.get("status") != "ahead"
            or not isinstance(comparison.get("merge_base_commit"), dict)
            or comparison["merge_base_commit"].get("sha") != previous):
        raise RuntimeError(message)


def select_revision(api, previous, revision, promoted, engine_branch="main"):
    """Resolve an exact fork SHA and enforce forward, optionally promoted history."""
    sha(revision)
    candidate = api(f"/repos/QuartzBrowser/WebKit/commits/{revision}")
    if not isinstance(candidate, dict) or candidate.get("sha") != revision:
        raise RuntimeError("The selected WebKit revision is unavailable in QuartzBrowser/WebKit")
    ensure_descendant(
        api, previous, revision,
        "The selected WebKit revision must descend from the current pin; refusing a rollback or divergent history",
    )
    if promoted:
        if engine_branch not in ("main", "quartz-dev"):
            raise ValueError("Unexpected engine release branch")
        branch = api(f"/repos/QuartzBrowser/WebKit/commits/{engine_branch}")
        if not isinstance(branch, dict):
            raise RuntimeError(f"Could not resolve WebKit {engine_branch}")
        promoted_revision = sha(branch.get("sha"))
        ensure_descendant(
            api, revision, promoted_revision,
            f"The selected WebKit revision must be on QuartzBrowser/WebKit/{engine_branch}",
        )
    return revision


def latest_release(api, channel):
    if channel == "stable":
        release = api("/repos/QuartzBrowser/Quartz/releases/latest")
        if release is not None and (not isinstance(release, dict) or release.get("draft") is not False
                                    or release.get("prerelease") is not False):
            raise ValueError("Expected a published stable Quartz release")
        return release
    selected = None
    selected_version = None
    # Published stable/other prereleases can fill an entire page. Read through
    # them, rather than accidentally treating a beta as never published.
    for page in range(1, 101):
        releases = api(f"/repos/QuartzBrowser/Quartz/releases?per_page=100&page={page}")
        if not isinstance(releases, list):
            raise ValueError("Expected a Quartz release list")
        for release in releases:
            if not isinstance(release, dict):
                raise ValueError("Invalid Quartz release list entry")
            if release.get("draft") is not False or release.get("prerelease") is not True:
                continue
            tag = release.get("tag_name")
            match = re.fullmatch("v" + VERSION_PATTERN + r"-beta\.([1-9][0-9]*)", tag) if isinstance(tag, str) else None
            if match:
                version = tuple(map(int, match.groups()))
                if selected_version is None or version > selected_version:
                    selected, selected_version = release, version
        if len(releases) < 100:
            return selected
    raise RuntimeError("Too many Quartz releases to establish the current beta publication safely")


def plan_update(repository, api, revision=None, channel="stable"):
    """Plan publication using the committed pin, or an explicitly selected SHA.

    An unchanged pin may still require publication when this channel's release
    predates it. Omission of revision must never implicitly follow a fork branch.
    """
    if not isinstance(channel, str) or channel not in RELEASE_BRANCHES:
        raise ValueError("Expected stable or beta release channel")
    quartz_revision = head(repository)
    lock = read_lock(git(repository, "show", f"{quartz_revision}:{LOCK}").stdout)
    previous = lock["revision"]
    revision = select_revision(api, previous, previous if revision is None else revision,
                               promoted=True, engine_branch="main" if channel == "stable" else "quartz-dev")

    published = ""
    release = latest_release(api, channel)
    if release is not None:
        tag = release.get("tag_name")
        pattern = "v" + VERSION_PATTERN + (r"-beta\.[1-9][0-9]*" if channel == "beta" else "")
        if not isinstance(tag, str) or not re.fullmatch(pattern, tag):
            raise ValueError("Invalid published Quartz version")
        ref = f"refs/tags/{tag}"
        if git(repository, "rev-parse", "--verify", f"{ref}^{{commit}}", check=False).returncode:
            raise RuntimeError(f"Published tag {tag} is missing locally; fetch all tags before planning")
        # A pre-integration release legitimately has no engine lock. A present
        # but malformed lock must fail instead of pretending the release is old.
        paths = git(repository, "ls-tree", "--name-only", ref, "--", LOCK).stdout.splitlines()
        if LOCK in paths:
            published = read_lock(git(repository, "show", f"{ref}:{LOCK}").stdout)["revision"]

    return {
        "channel": channel,
        "release_branch": RELEASE_BRANCHES[channel],
        "quartz_revision": quartz_revision,
        "previous_revision": previous,
        "revision": revision,
        "published_revision": published,
        "release_required": revision != previous or revision != published,
    }


def ensure_base(repository, plan):
    validate_plan(plan)
    if head(repository) != plan["quartz_revision"]:
        raise RuntimeError("Quartz HEAD changed after planning; retry with a fresh plan")


def ensure_clean_index(repository):
    if git(repository, "diff", "--cached", "--name-only").stdout.strip():
        raise RuntimeError("Refusing to include existing staged work in an engine update")


def ensure_clean_worktree(repository):
    ensure_clean_index(repository)
    if git(repository, "diff", "--name-only", "HEAD").stdout.strip():
        raise RuntimeError("Engine staging requires a clean tracked working tree")


def write_revision(repository, lock, revision):
    if lock["revision"] != revision:
        lock = {**lock, "revision": revision}
        (repository / LOCK).write_text(json.dumps(lock, indent=2) + "\n")


def candidate_update(repository, api, revision):
    """Stage an exact forward fork commit locally for build-only validation.

    No release plan is produced: unpromoted candidates cannot enter publication
    by passing this operation's output to `commit`. Check the base and tracked
    files again after network validation to preserve intervening local work.
    """
    sha(revision)
    quartz_revision = head(repository)
    ensure_clean_worktree(repository)
    lock = read_lock(git(repository, "show", f"{quartz_revision}:{LOCK}").stdout)
    select_revision(api, lock["revision"], revision, promoted=False)
    if head(repository) != quartz_revision:
        raise RuntimeError("Quartz HEAD changed during candidate validation; retry against its new HEAD")
    ensure_clean_worktree(repository)
    write_revision(repository, lock, revision)
    return {
        "quartz_revision": quartz_revision,
        "previous_revision": lock["revision"],
        "revision": revision,
    }


def stage_update(repository, plan):
    ensure_base(repository, plan)
    ensure_clean_worktree(repository)
    lock = read_lock((repository / LOCK).read_text())
    if lock["revision"] != plan["previous_revision"]:
        raise RuntimeError("The engine pin changed after planning")
    write_revision(repository, lock, plan["revision"])


def commit_update(repository, plan, push=True):
    ensure_base(repository, plan)
    release_branch = plan["release_branch"]
    if git(repository, "symbolic-ref", "--short", "HEAD").stdout.strip() != release_branch:
        raise RuntimeError(f"Engine publication must run on local Quartz {release_branch}")
    ensure_clean_index(repository)
    changed = set(git(repository, "diff", "HEAD", "--name-only").stdout.splitlines())
    if changed - {LOCK}:
        raise RuntimeError("Refusing to commit unrelated tracked changes")
    original = read_lock(git(repository, "show", f"HEAD:{LOCK}").stdout)
    staged = read_lock((repository / LOCK).read_text())
    if original["revision"] != plan["previous_revision"] or staged != {**original, "revision": plan["revision"]}:
        raise RuntimeError("The staged engine lock does not match the validated plan")

    # No force-push or rebase of an engine tested against a different app tree.
    git(repository, "fetch", "--no-tags", "origin", f"refs/heads/{release_branch}")
    if git(repository, "rev-parse", "FETCH_HEAD").stdout.strip() != plan["quartz_revision"]:
        raise RuntimeError(f"Quartz {release_branch} advanced during validation; retry against its new HEAD")
    if not plan["release_required"]:
        return head(repository)

    git(repository, "add", "--", LOCK)
    action = "update engine to" if plan["revision"] != plan["previous_revision"] else "publish engine"
    git(repository, "-c", "user.name=Quartz release automation",
        "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com",
        "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m",
        f"fix(webkit): {action} {plan['revision'][:12]}")
    if push:
        git(repository, "push", "origin", f"HEAD:refs/heads/{release_branch}")
    return head(repository)


def github_api(path):
    if (not path.startswith("/repos/QuartzBrowser/") or any(character in path for character in ("#", "\n"))
            or ("?" in path and not re.fullmatch(r"/repos/QuartzBrowser/Quartz/releases\?per_page=100&page=[1-9][0-9]*", path))):
        raise ValueError("Unexpected GitHub API path")
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "Quartz-engine-updates",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request("https://api.github.com" + path, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise RuntimeError(f"GitHub API request failed (HTTP {error.code})") from None
    except urllib.error.URLError:
        raise RuntimeError("GitHub API request failed") from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", type=Path, default=ROOT)
    commands = parser.add_subparsers(dest="command", required=True)
    planner = commands.add_parser("plan", help="Plan a channel release with the committed pin or an explicit eligible SHA")
    planner.add_argument("--output", type=Path)
    planner.add_argument("--revision", help="Exact full lowercase fork SHA on main (stable) or quartz-dev (beta); default: committed pin")
    planner.add_argument("--channel", choices=RELEASE_BRANCHES, default="stable", help="Publication channel (default: stable)")
    candidate = commands.add_parser("candidate", help="Stage a forward fork SHA locally for build testing, without publication")
    candidate.add_argument("--revision", required=True, help="Full lowercase fork commit SHA, including development commits")
    for name in ("stage", "commit"):
        command = commands.add_parser(name)
        command.add_argument("--plan", type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == "plan":
            plan = plan_update(args.repository, github_api, revision=args.revision, channel=args.channel)
            encoded = json.dumps(plan, separators=(",", ":"))
            if args.output:
                args.output.parent.mkdir(parents=True, exist_ok=True)
                args.output.write_text(encoded + "\n")
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a") as output:
                    output.write(f"plan={encoded}\nquartz_revision={plan['quartz_revision']}\n")
                    output.write(f"release_required={str(plan['release_required']).lower()}\n")
            print(encoded)
        elif args.command == "candidate":
            print(json.dumps(candidate_update(args.repository, github_api, args.revision), separators=(",", ":")))
        else:
            plan = json.loads(args.plan.read_text())
            if args.command == "stage":
                stage_update(args.repository, plan)
                print(f"Engine candidate: {plan['revision']}")
            else:
                print(f"Validated Quartz revision: {commit_update(args.repository, plan)}")
    except (RuntimeError, ValueError, OSError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
