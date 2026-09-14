#!/usr/bin/env python3
"""Test immutable verification/active-feed routing without network or app builds.

Crypto and archive checks have separate real fixtures. These command fixtures
exercise the actual orchestration script and guard legacy bootstrap routing.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
CANONICAL = "https://raw.githubusercontent.com/QuartzBrowser/Quartz/update-feed/appcast.xml"
LEGACY = "https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml"


class PublicVerificationRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="quartz-public-check-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.scripts = self.root / "Scripts"
        self.bin = self.root / "bin"
        self.assets = self.root / "assets"
        self.local = self.root / "dist/release"
        for path in (self.scripts, self.bin, self.assets, self.local):
            path.mkdir(parents=True)
        for name in ("verify-published-update.sh", "release-version.py"):
            shutil.copy2(SCRIPTS / name, self.scripts / name)
        self.assets.joinpath("Quartz-v1.0.1-macos-universal.zip").write_bytes(b"archive fixture")
        self.assets.joinpath("appcast.xml").write_bytes(b"signed feed fixture")
        sums = "".join(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
                       for path in sorted(self.assets.iterdir()))
        self.assets.joinpath("SHA256SUMS").write_text(sums)
        for path in self.assets.iterdir():
            shutil.copy2(path, self.local / path.name)
        self.plist = self.root / "Info.plist"
        self.log = self.root / "feeds.log"
        self.operations = self.root / "operations.log"
        self.environment = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                            "DIST_DIR": str(self.root / "dist"), "SPARKLE_PUBLIC_KEY": "trusted-public-key",
                            "FIXTURE_ASSETS": str(self.assets), "FIXTURE_PLIST": str(self.plist),
                            "FIXTURE_FEED_LOG": str(self.log), "FIXTURE_FAIL_CANONICAL": "0",
                            "FIXTURE_OPERATIONS": str(self.operations), "FIXTURE_AUTH_FAILURE": "0"}
        self.command(self.bin / "curl", '''
import os, pathlib, shutil, sys
url = next(value for value in sys.argv if value.startswith('https://'))
shutil.copyfile(pathlib.Path(os.environ['FIXTURE_ASSETS']) / url.rsplit('/', 1)[1], sys.argv[sys.argv.index('--output') + 1])
''')
        self.command(self.bin / "ditto", '''
import os, pathlib, shutil, sys
with open(os.environ['FIXTURE_OPERATIONS'], 'a') as output:
    output.write('extract\\n')
destination = pathlib.Path(sys.argv[-1]) / 'Quartz.app/Contents'
destination.mkdir(parents=True)
shutil.copyfile(os.environ['FIXTURE_PLIST'], destination / 'Info.plist')
''')
        self.command(self.bin / "shasum", '''
import hashlib, pathlib, sys
for line in pathlib.Path(sys.argv[-1]).read_text().splitlines():
    digest, name = line.split()
    assert hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest() == digest
''')
        self.command(self.bin / "codesign", "pass\n")
        self.command(self.bin / "swift", '''
import os, sys
if sys.argv[1].endswith('/verify-release-archive.swift'):
    with open(os.environ['FIXTURE_OPERATIONS'], 'a') as output:
        output.write('authenticate\\n')
    if os.environ['FIXTURE_AUTH_FAILURE'] == '1':
        raise SystemExit(1)
''')
        self.command(self.scripts / "wait-for-channel-feed.sh", '''
import os, pathlib, sys
url = sys.argv[-1]
with open(os.environ['FIXTURE_FEED_LOG'], 'a') as log:
    log.write(url + '\\n')
if os.environ['FIXTURE_FAIL_CANONICAL'] == '1' and 'raw.githubusercontent.com' in url:
    raise SystemExit(1)
pathlib.Path(sys.argv[2]).write_bytes(pathlib.Path(sys.argv[1]).read_bytes())
''')

    def command(self, path, code):
        path.write_text(f"#!{sys.executable}\n" + code)
        path.chmod(0o755)

    def check(self, bundled_feed=CANONICAL, active=True, key="trusted-public-key"):
        self.plist.write_bytes(plistlib.dumps({"SUPublicEDKey": key, "SUFeedURL": bundled_feed}))
        return subprocess.run([str(self.scripts / "verify-published-update.sh"), "1.0.1"]
                              + (["--feed"] if active else []), env=self.environment, capture_output=True)

    def routes(self):
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_modern_release_verifies_canonical_feed(self):
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(self.routes(), [CANONICAL])
        self.assertEqual(self.operations.read_text().splitlines(), ["authenticate", "extract"])

    def test_legacy_activation_verifies_canonical_and_legacy_routes(self):
        result = self.check(LEGACY)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(self.routes(), [CANONICAL, LEGACY])

    def test_legacy_route_cannot_mask_failed_canonical_activation(self):
        self.environment["FIXTURE_FAIL_CANONICAL"] = "1"
        self.assertNotEqual(self.check(LEGACY).returncode, 0)
        self.assertEqual(self.routes(), [CANONICAL])

    def test_immutable_verification_never_requires_feed_activation(self):
        self.assertEqual(self.check(LEGACY, active=False).returncode, 0)
        self.assertEqual(self.routes(), [])

    def test_embedded_key_must_match_configured_trust(self):
        self.assertNotEqual(self.check(key="different-public-key").returncode, 0)
        self.assertEqual(self.routes(), [])

    def test_downloaded_asset_must_match_prepared_asset(self):
        self.assets.joinpath("appcast.xml").write_bytes(b"changed public asset")
        self.assertNotEqual(self.check().returncode, 0)
        self.assertEqual(self.routes(), [])

    def test_failed_authentication_prevents_archive_extraction(self):
        self.environment["FIXTURE_AUTH_FAILURE"] = "1"
        self.assertNotEqual(self.check().returncode, 0)
        self.assertEqual(self.operations.read_text().splitlines(), ["authenticate"])
        self.assertEqual(self.routes(), [])

    def test_missing_trusted_public_key_is_rejected_before_extraction(self):
        self.environment.pop("SPARKLE_PUBLIC_KEY")
        self.assertNotEqual(self.check().returncode, 0)
        self.assertFalse(self.operations.exists())
        self.assertEqual(self.routes(), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
