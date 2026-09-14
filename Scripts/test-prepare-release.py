#!/usr/bin/env python3
"""Test previous-feed selection without network access or compiling an app.

Disposable command fixtures stop at prior-feed verification. They prove request
routing and failure behavior only; test-update-packaging.sh uses real Sparkle
tools and signatures for the complete release pipeline.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT_DIR = Path(__file__).resolve().parent
CANONICAL = "https://raw.githubusercontent.com/QuartzBrowser/Quartz/update-feed/appcast.xml"
LEGACY = "https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml"


class PreviousFeedSelectionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="quartz-feed-source-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.scripts = self.root / "Scripts"
        self.commands = self.root / "commands"
        self.tools = self.root / "sparkle"
        for directory in [self.scripts, self.commands, self.tools]:
            directory.mkdir()
        for name in ["prepare-release.sh", "release-version.py"]:
            shutil.copy2(SCRIPT_DIR / name, self.scripts / name)
        self.command(self.scripts / "package-macos-app.sh", '''
import os
from pathlib import Path
assert "SPARKLE_PRIVATE_KEY" not in os.environ, "Signing key leaked to packaging subprocess"
(Path(os.environ["DIST_DIR"]) / "Quartz.app").mkdir(parents=True, exist_ok=True)
''')
        for name in ["codesign", "unzip"]:
            self.command(self.commands / name, "pass\n")
        self.command(self.commands / "ditto", 'import sys\nfrom pathlib import Path\nPath(sys.argv[-1]).write_bytes(b"fixture archive")\n')
        self.command(self.tools / "generate_appcast", 'raise SystemExit("Unexpected generation beyond verification fixture")\n')
        self.command(self.tools / "sign_update", '''
import sys
assert "--verify" in sys.argv
assert sys.stdin.read() == "disposable-signing-key"
raise SystemExit(77)
''')
        self.command(self.commands / "curl", '''
import json, os, sys
from pathlib import Path
url = sys.argv[-1]
with open(os.environ["FIXTURE_REQUEST_LOG"], "a") as output:
    output.write(url + "\\n")
response = json.loads(os.environ["FIXTURE_RESPONSES"])[url]
if response.get("network_error"):
    raise SystemExit(7)
Path(sys.argv[sys.argv.index("--output") + 1]).write_text(response["body"])
print(response["status"], end="")
''')
        self.requests = self.root / "requests.txt"
        self.responses = {}

    def command(self, path, source):
        path.write_text(f"#!{sys.executable}\n" + source)
        path.chmod(0o755)

    def run_preparation(self, previous=None):
        environment = os.environ.copy()
        environment.pop("PREVIOUS_APPCAST_FILE", None)
        environment.update({
            "PATH": str(self.commands) + os.pathsep + environment["PATH"],
            "SPARKLE_TOOLS_DIR": str(self.tools), "DIST_DIR": str(self.root / "dist"),
            "SPARKLE_PRIVATE_KEY": "disposable-signing-key", "SPARKLE_PUBLIC_KEY": "fixture-public-key",
            "QUARTZ_USE_SYSTEM_WEBKIT": "1", "QUARTZ_TEST_SYSTEM_RELEASE": "1",
            "FIXTURE_REQUEST_LOG": str(self.requests), "FIXTURE_RESPONSES": json.dumps(self.responses),
        })
        if previous:
            environment["PREVIOUS_APPCAST_FILE"] = str(previous)
        result = subprocess.run(["bash", str(self.scripts / "prepare-release.sh"), "1.1.0-beta.1"],
                                env=environment, text=True, capture_output=True)
        requests = self.requests.read_text().splitlines() if self.requests.exists() else []
        return result, requests

    def test_explicit_previous_file_never_fetches_network(self):
        previous = self.root / "prior.xml"
        previous.write_text("explicit signed feed fixture")
        result, requests = self.run_preparation(previous)
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertEqual(requests, [])
        self.assertEqual((self.root / "dist/release/appcast.xml").read_text(), previous.read_text())

    def test_canonical_success_never_fetches_legacy(self):
        self.responses[CANONICAL] = {"status": 200, "body": "canonical signed feed fixture"}
        result, requests = self.run_preparation()
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertEqual(requests, [CANONICAL])
        self.assertEqual((self.root / "dist/release/appcast.xml").read_text(), "canonical signed feed fixture")

    def test_only_canonical_404_fetches_legacy_feed(self):
        self.responses[CANONICAL] = {"status": 404, "body": "not found"}
        self.responses[LEGACY] = {"status": 200, "body": "legacy stable signed feed fixture"}
        result, requests = self.run_preparation()
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertEqual(requests, [CANONICAL, LEGACY])
        self.assertEqual((self.root / "dist/release/appcast.xml").read_text(), "legacy stable signed feed fixture")

    def test_canonical_http_error_does_not_erase_history_by_falling_back(self):
        for status in [401, 403, 429, 500, 503]:
            with self.subTest(status=status):
                self.requests.unlink(missing_ok=True)
                self.responses[CANONICAL] = {"status": status, "body": "request failed"}
                result, requests = self.run_preparation()
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(requests, [CANONICAL])
                self.assertIn(f"HTTP {status}", result.stderr)

    def test_network_failure_does_not_fall_back(self):
        self.responses[CANONICAL] = {"network_error": True}
        result, requests = self.run_preparation()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, [CANONICAL])

    def test_legacy_failure_is_fatal_after_canonical_404(self):
        self.responses[CANONICAL] = {"status": 404, "body": "not found"}
        self.responses[LEGACY] = {"status": 500, "body": "request failed"}
        result, requests = self.run_preparation()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(requests, [CANONICAL, LEGACY])
        self.assertIn("legacy stable appcast (HTTP 500)", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
