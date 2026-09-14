#!/usr/bin/env python3
"""Validate a Quartz release label and derive unambiguous macOS/Sparkle versions.

Accept X.Y.Z or X.Y.Z-beta.N without leading zeros. CFBundleShortVersionString
uses X.Y.Z; QuartzReleaseVersion retains the full label; QuartzReleaseChannel is
stable or beta. Numeric CFBundleVersion is (100*X + Y + 1).Z.ordinal, where beta
ordinal is 1..98 and stable is 99. Minor/patch must be <=99 and the encoded first
component <=9999. This respects even Apple's archived 4/2/2 digit bounds, orders
stable after every beta of its release line, and orders later release lines
after earlier ones. Never change this mapping after publishing versions with it.

The default CLI output is JSON; --field prints a single validated metadata value.
"""

import argparse
import json
import re


def release_version(value):
    match = re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-beta\.([1-9][0-9]*))?", value)
    if not match:
        raise ValueError("Expected X.Y.Z or X.Y.Z-beta.N without leading zeros")
    major, minor, patch = map(int, match.group(1, 2, 3))
    ordinal = int(match.group(4)) if match.group(4) else 99
    build_major = 100 * major + minor + 1
    if minor > 99 or patch > 99 or build_major > 9999:
        raise ValueError("Release version exceeds metadata bounds: minor/patch <=99 and 100*major+minor+1 <=9999")
    if match.group(4) and not 1 <= ordinal <= 98:
        raise ValueError("Beta ordinal must be between 1 and 98; 99 is reserved for the stable release")
    return {
        "version": value,
        "base_version": f"{major}.{minor}.{patch}",
        "build_version": f"{build_major}.{patch}.{ordinal}",
        "channel": "beta" if match.group(4) else "stable",
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--field", choices=["version", "base_version", "build_version", "channel"])
    args = parser.parse_args()
    try:
        result = release_version(args.version)
    except ValueError as error:
        parser.exit(1, f"error: {error}\n")
    print(result[args.field] if args.field else json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    main()
