#!/usr/bin/env python3
"""Finalize one generated release label while preserving every prior feed item.

Input feeds must already have passed signature verification. This operation
changes display metadata on the exact new build, checks its channel and URL,
and rejects missing or altered historical entries. It invalidates the feed
signature; prepare-release.sh must sign and verify the final bytes afterwards.
"""

import argparse
import importlib.util
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("release_version", Path(__file__).with_name("release-version.py"))
versions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(versions)
SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def canonical(element):
    return (element.tag, tuple(sorted(element.attrib.items())), (element.text or "").strip(),
            tuple(canonical(child) for child in element))


def feed_items(root):
    if root.tag != "rss" or len(root.findall("channel")) != 1:
        raise ValueError("Expected a single RSS channel")
    result = {}
    for item in root.findall("./channel/item"):
        enclosure = item.find("enclosure")
        if len(item.findall(f"{{{SPARKLE}}}version")) > 1:
            raise ValueError("Feed contains ambiguous build metadata")
        build = item.findtext(f"{{{SPARKLE}}}version")
        enclosure_build = enclosure.get(f"{{{SPARKLE}}}version") if enclosure is not None else None
        if build is not None and enclosure_build is not None and build != enclosure_build:
            raise ValueError("Feed contains conflicting build metadata")
        if build is None and enclosure is not None:
            build = enclosure.get(f"{{{SPARKLE}}}version")
        if not build or build in result:
            raise ValueError("Feed contains a missing or duplicate build version")
        result[build] = item
    return result


def finalize(path, label, download_url, previous=None):
    metadata = versions.release_version(label)
    tree = ET.parse(path)
    items = feed_items(tree.getroot())
    build = metadata["build_version"]
    if build not in items:
        raise ValueError("Generated feed is missing the exact new release build")
    item = items[build]
    expected_channel = "beta" if metadata["channel"] == "beta" else None
    if (len(item.findall(f"{{{SPARKLE}}}channel")) != (1 if expected_channel else 0)
            or item.findtext(f"{{{SPARKLE}}}channel") != expected_channel):
        raise ValueError("Generated release has the wrong Sparkle channel")
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1 or enclosures[0].get("url") != download_url:
        raise ValueError("Generated release has the wrong download URL")
    for name in ("title", f"{{{SPARKLE}}}shortVersionString"):
        elements = item.findall(name)
        if len(elements) != 1:
            raise ValueError("Generated release has ambiguous display metadata")
        elements[0].text = label
    if previous:
        prior_items = feed_items(ET.parse(previous).getroot())
        if build in prior_items:
            raise ValueError("Release build already exists; reuse its signed assets instead of regenerating it")
        for prior_build, prior_item in prior_items.items():
            if prior_build not in items or canonical(prior_item) != canonical(items[prior_build]):
                raise ValueError(f"Generated feed dropped or modified retained build {prior_build}")
    tree.write(path, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--appcast", type=Path, required=True)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--previous-appcast", type=Path)
    args = parser.parse_args()
    try:
        finalize(args.appcast, args.version, args.download_url, args.previous_appcast)
    except (ValueError, OSError, ET.ParseError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
