#!/usr/bin/env python3
"""Activate an already published, signed Quartz feed with a fast-forward Git push.

No signing key is used here. The release assets must have passed
verify-published-update.sh first. This tool independently checks the feed's
public signature, GitHub release identity, immutable feed bytes, and retention
of every currently advertised item. A racing publication fails without force.

--check-feed FILE performs a read-only check that FILE advertises the same
version/item as --feed, allowing an existing release to be verified after newer
releases have been added. It makes no Git or network calls.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
FEED_BRANCH = "refs/heads/update-feed"
FEED_URL = "https://raw.githubusercontent.com/QuartzBrowser/Quartz/update-feed/appcast.xml"
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
MAX_FEED_BYTES = 16 * 1024 * 1024


def metadata(version):
    # Keep the script's validated CLI contract as the single version mapping.
    result = subprocess.run(["python3", str(ROOT / "Scripts/release-version.py"), version],
                            text=True, capture_output=True, check=False)
    if result.returncode:
        raise ValueError("Invalid Quartz release version")
    return json.loads(result.stdout)


def read_feed(path):
    data = Path(path).read_bytes()
    if not data or len(data) > MAX_FEED_BYTES:
        raise ValueError("Expected a nonempty update feed of at most 16 MiB")
    return data


def entries(data):
    if not data or len(data) > MAX_FEED_BYTES or b"<!DOCTYPE" in data.upper() or b"<!ENTITY" in data.upper():
        raise ValueError("Invalid update feed size or XML declarations")
    root = ET.fromstring(data)
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1:
        raise ValueError("Expected one RSS update channel")
    result = {}
    for item in channels[0].findall("item"):
        for field in ("version", "shortVersionString"):
            if len(item.findall(SPARKLE + field)) != 1:
                raise ValueError("Ambiguous update version metadata")
        if len(item.findall(SPARKLE + "channel")) > 1:
            raise ValueError("Ambiguous update channel metadata")
        label = item.findtext(SPARKLE + "shortVersionString")
        build = item.findtext(SPARKLE + "version")
        channel = item.findtext(SPARKLE + "channel", "")
        if not label or not build or channel not in ("", "beta"):
            raise ValueError("An update item has an invalid version or channel")
        if label in result:
            raise ValueError("Duplicate release label in update feed")
        # Canonicalization ignores formatting and attribute order, preserving all
        # signed update semantics (URLs, signatures, OS requirements, and notes).
        fingerprint = ET.canonicalize(ET.tostring(item, encoding="unicode"), strip_text=True)
        result[label] = {"build": build, "channel": channel, "item": item, "fingerprint": fingerprint}
    return result


def expected_entry(data, version):
    info = metadata(version)
    item = entries(data).get(version)
    expected_channel = "beta" if info["channel"] == "beta" else ""
    if item is None or item["channel"] != expected_channel:
        raise ValueError("The feed does not advertise the expected release/channel")
    allowed_builds = {info["build_version"]}
    if info["channel"] == "stable":
        allowed_builds.add(version)  # Existing updater-enabled stable releases.
    if item["build"] not in allowed_builds:
        raise ValueError("Unexpected release build number in update feed")
    enclosures = item["item"].findall("enclosure")
    expected_url = (f"https://github.com/QuartzBrowser/Quartz/releases/download/v{version}/"
                    f"Quartz-v{version}-macos-universal.zip")
    if len(enclosures) != 1 or enclosures[0].get("url") != expected_url:
        raise ValueError("Unexpected release download URL in update feed")
    return item


def ensure_retained(previous, proposed):
    old, new = entries(previous), entries(proposed)
    for version, item in old.items():
        if version not in new or new[version]["fingerprint"] != item["fingerprint"]:
            raise RuntimeError("The proposed feed would remove or change an advertised release; prepare a fresh release instead")


def verify_signature(path, public_key):
    result = subprocess.run(["/usr/bin/swift", str(ROOT / "Scripts/verify-feed.swift"), str(path), public_key],
                            text=True, capture_output=True, check=False, timeout=90)
    if result.returncode:
        raise ValueError("Update feed signature verification failed")


def check_feed(expected_path, current_path, version, public_key, verifier=verify_signature):
    verifier(expected_path, public_key)
    verifier(current_path, public_key)
    expected = expected_entry(read_feed(expected_path), version)
    current = expected_entry(read_feed(current_path), version)
    if expected["fingerprint"] != current["fingerprint"]:
        raise ValueError("Published feed does not contain the expected immutable release item")


def download(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Quartz-update-feed"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            if not response.url.startswith("https://"):
                raise RuntimeError("Update metadata must use HTTPS")
            data = response.read(MAX_FEED_BYTES + 1)
    except (urllib.error.URLError, TimeoutError):
        raise RuntimeError("Could not download published update metadata") from None
    if not data or len(data) > MAX_FEED_BYTES:
        raise ValueError("Published update metadata is empty or too large")
    return data


def release_metadata(version):
    request = urllib.request.Request(
        f"https://api.github.com/repos/QuartzBrowser/Quartz/releases/tags/v{version}",
        headers={"Accept": "application/vnd.github+json", "User-Agent": "Quartz-update-feed"},
    )
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)
    except (urllib.error.URLError, TimeoutError):
        raise RuntimeError("Could not verify the published GitHub release") from None


def git(repository, *arguments, input=None, env=None, check=True):
    result = subprocess.run(["git", "-C", str(repository), *arguments], input=input,
                            capture_output=True, check=False, env=env)
    if check and result.returncode:
        # Remote output/URLs may contain credentials; never echo them.
        raise RuntimeError(f"Git {arguments[0]} failed; no feed was force-pushed")
    return result


def publish(repository, version, feed_path, public_key, *, verifier=verify_signature,
            lookup=release_metadata, fetch=download, before_push=None):
    info = metadata(version)
    proposed = read_feed(feed_path)
    verifier(feed_path, public_key)
    expected_entry(proposed, version)
    release = lookup(version)
    if (not isinstance(release, dict) or release.get("tag_name") != "v" + version
            or release.get("draft") is not False
            or release.get("prerelease") is not (info["channel"] == "beta")):
        raise ValueError("Release tag, publication state, or prerelease status does not match")
    assets = release.get("assets")
    if not isinstance(assets, list) or any(not isinstance(asset, dict) for asset in assets):
        raise ValueError("Invalid public release asset list")
    names = {asset.get("name") for asset in assets
             if asset.get("state") == "uploaded" and isinstance(asset.get("size"), int) and asset["size"] > 0}
    if not {f"Quartz-v{version}-macos-universal.zip", "appcast.xml", "SHA256SUMS"} <= names:
        raise ValueError("Required public release assets are not uploaded")
    immutable_url = f"https://github.com/QuartzBrowser/Quartz/releases/download/v{version}/appcast.xml"
    if fetch(immutable_url) != proposed:
        raise ValueError("Proposed feed bytes do not match the published release asset")

    advertised = git(repository, "ls-remote", "--exit-code", "origin", FEED_BRANCH, check=False)
    if advertised.returncode not in (0, 2):
        raise RuntimeError("Could not inspect the current feed branch")
    parent = ""
    if advertised.returncode == 0:
        lines = advertised.stdout.decode().splitlines()
        if len(lines) != 1 or lines[0].split()[1] != FEED_BRANCH:
            raise ValueError("Ambiguous feed branch")
        parent = lines[0].split()[0]
        if not re.fullmatch(r"[0-9a-f]{40}", parent):
            raise ValueError("Invalid feed branch revision")
        git(repository, "fetch", "--no-tags", "origin", parent)

    with tempfile.TemporaryDirectory(prefix="quartz-feed-") as temporary:
        directory = Path(temporary)
        if parent:
            previous = git(repository, "show", f"{parent}:appcast.xml").stdout
            previous_file = directory / "previous.xml"
            previous_file.write_bytes(previous)
            verifier(previous_file, public_key)
            ensure_retained(previous, proposed)
            if previous == proposed:
                return {"revision": parent, "changed": False, "version": version}

        environment = {**os.environ, "GIT_INDEX_FILE": str(directory / "index"),
                       "GIT_AUTHOR_NAME": "Quartz release automation",
                       "GIT_AUTHOR_EMAIL": "41898282+github-actions[bot]@users.noreply.github.com",
                       "GIT_COMMITTER_NAME": "Quartz release automation",
                       "GIT_COMMITTER_EMAIL": "41898282+github-actions[bot]@users.noreply.github.com"}
        git(repository, "read-tree", parent if parent else "--empty", env=environment)
        blob = git(repository, "hash-object", "-w", "--stdin", input=proposed).stdout.decode().strip()
        git(repository, "update-index", "--add", "--cacheinfo", "100644", blob, "appcast.xml", env=environment)
        tree = git(repository, "write-tree", env=environment).stdout.decode().strip()
        parent_args = ["-p", parent] if parent else []
        revision = git(repository, "-c", "commit.gpgsign=false", "commit-tree", tree, *parent_args,
                       input=f"chore(updates): advertise Quartz {version}\n".encode(), env=environment).stdout.decode().strip()
        if before_push:
            before_push()
        git(repository, "push", "origin", f"{revision}:{FEED_BRANCH}")
        return {"revision": revision, "changed": True, "version": version}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--feed", type=Path, default=ROOT / "dist/release/appcast.xml")
    parser.add_argument("--public-key", default=os.environ.get("SPARKLE_PUBLIC_KEY"), required=False)
    parser.add_argument("--repository", type=Path, default=ROOT)
    parser.add_argument("--check-feed", type=Path, help="Read-only: verify this feed retains the exact release item")
    args = parser.parse_args()
    try:
        if not args.public_key:
            raise ValueError("SPARKLE_PUBLIC_KEY or --public-key is required")
        if args.check_feed:
            check_feed(args.feed, args.check_feed, args.version, args.public_key)
            print("Published feed advertises the verified release item.")
        else:
            print(json.dumps(publish(args.repository, args.version, args.feed, args.public_key)))
    except (ValueError, RuntimeError, OSError, ET.ParseError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
