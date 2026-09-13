#!/usr/bin/env python3
"""Identify compiler/SDK inputs without temporary compiler installation paths."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent
COMPONENTS = ("xcode", "swift", "sdk-version", "metal", "os", "arch", "sdk-settings")
COMMANDS = (
    ("xcode", ["xcodebuild", "-version"]),
    ("swift", ["xcrun", "swift", "--version"]),
    ("sdk-version", ["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
    ("metal", ["xcrun", "--sdk", "macosx", "metal", "--version"]),
    ("os", ["sw_vers"]),
    ("arch", ["uname", "-m"]),
)


def normalized_components(components):
    if set(components) != set(COMPONENTS):
        raise ValueError("Expected all compiler, SDK, OS, and architecture components")
    normalized = {}
    for name in COMPONENTS:
        value = components[name]
        if not isinstance(value, bytes) or not value:
            raise ValueError(f"Missing toolchain identity bytes: {name}")
        if name in ("metal", "swift"):
            value = b"".join(line for line in value.splitlines(keepends=True)
                             if not line.startswith(b"InstalledDir:"))
        if not value:
            raise ValueError(f"Missing compiler version information: {name}")
        normalized[name] = value
    return normalized


def component_hashes(components):
    return {name: hashlib.sha256(value).hexdigest()
            for name, value in normalized_components(components).items()}


def identity_for_components(components):
    record = {"schemaVersion": 1, "components": component_hashes(components)}
    return hashlib.sha256(json.dumps(record, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def legacy_key_for_components(components, current_hashes, migration):
    """Replay one old identity exactly; never broaden restoration by prefix."""
    try:
        normalized_components(components)
        if (type(migration.get("schemaVersion")) is not int or migration["schemaVersion"] != 1
                or not migration.get("sourceHashes")
                or current_hashes != migration["sourceHashes"]):
            return ""
        expected = migration["legacyIdentity"]
        key = migration["legacyKey"]
        if not re.fullmatch(r"[0-9a-f]{64}", expected):
            return ""
        if not re.fullmatch(r"quartz-webkit-universal-macOS-ARM64-" + expected + r"-[0-9a-f]{64}", key):
            return ""
        lines = components["metal"].splitlines(keepends=True)
        indices = [index for index, line in enumerate(lines) if line.startswith(b"InstalledDir:")]
        if len(indices) != 1 or not lines[indices[0]].startswith(b"InstalledDir: "):
            return ""
        index = indices[0]
        line = lines[index]
        ending = b"\r\n" if line.endswith(b"\r\n") else b"\n" if line.endswith(b"\n") else b""
        current_path = line[len(b"InstalledDir: "):].rstrip(b"\r\n")
        if not current_path.startswith(b"/") or b"\x00" in current_path or b"\r" in current_path:
            return ""
        for path in migration["metalInstalledDirs"]:
            if (not isinstance(path, str) or not path.startswith("/")
                    or any(character in path for character in ("\n", "\r", "\x00"))):
                return ""
            previous_lines = lines.copy()
            previous_lines[index] = b"InstalledDir: " + path.encode() + ending
            previous = {**components, "metal": b"".join(previous_lines)}
            digest = hashlib.sha256(b"".join(previous[name] for name in COMPONENTS)).hexdigest()
            if digest == expected:
                return key
    except (KeyError, TypeError, ValueError, AttributeError):
        return ""
    return ""


def main():
    components = {name: subprocess.check_output(command) for name, command in COMMANDS}
    sdk = Path(subprocess.check_output(
        ["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip())
    components["sdk-settings"] = (sdk / "SDKSettings.json").read_bytes()
    identity = identity_for_components(components)
    record = {"schemaVersion": 1, "identity": identity, "components": component_hashes(components)}
    print(json.dumps(record, indent=2))

    legacy_key = ""
    migration_path = ROOT / "WebKit.cache-migration.json"
    if migration_path.exists():
        migration = json.loads(migration_path.read_text())
        hashes = {}
        for name in migration.get("sourceHashes", {}):
            relative = Path(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ValueError("Cache migration paths must be repository relative")
            hashes[name] = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
        legacy_key = legacy_key_for_components(components, hashes, migration)
    print("Compatible legacy cache: " + (legacy_key or "none"))
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"identity={identity}\nlegacy-key={legacy_key}\n")


if __name__ == "__main__":
    main()
