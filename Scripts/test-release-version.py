#!/usr/bin/env python3
"""Check release-channel identity, Apple metadata bounds, and update ordering."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).with_name("release-version.py")
SPEC = importlib.util.spec_from_file_location("release_version", SCRIPT)
versions = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(versions)


def build(label):
    return tuple(map(int, versions.release_version(label)["build_version"].split(".")))


class ReleaseVersionTests(unittest.TestCase):
    def test_stable_and_beta_share_base_but_have_distinct_ordered_builds(self):
        self.assertEqual(versions.release_version("1.0.2-beta.1"), {
            "version": "1.0.2-beta.1", "base_version": "1.0.2",
            "build_version": "101.2.1", "channel": "beta",
        })
        self.assertEqual(versions.release_version("1.0.2"), {
            "version": "1.0.2", "base_version": "1.0.2",
            "build_version": "101.2.99", "channel": "stable",
        })
        ordered = ["1.0.1", "1.0.2-beta.1", "1.0.2-beta.2", "1.0.2-beta.98", "1.0.2", "1.0.3-beta.1"]
        self.assertEqual(sorted(ordered, key=build), ordered)
        self.assertGreater(build("1.0.2-beta.1"), (1, 0, 1))  # published legacy build

    def test_patch_minor_and_major_rollovers_preserve_release_line_order(self):
        for older, newer in [("0.0.0", "0.0.1-beta.1"), ("1.0.99", "1.1.0-beta.1"),
                             ("1.99.99", "2.0.0-beta.1"), ("98.99.99", "99.0.0-beta.1")]:
            with self.subTest(older=older, newer=newer):
                self.assertLess(build(older), build(newer))

    def test_all_beta_ordinals_are_unique_and_before_stable(self):
        builds = [build(f"1.2.3-beta.{ordinal}") for ordinal in range(1, 99)] + [build("1.2.3")]
        self.assertEqual(len(set(builds)), 99)
        self.assertEqual(builds, sorted(builds))

    def test_metadata_bounds_include_first_nonzero_and_maximum_legal_build(self):
        self.assertEqual(build("0.0.0-beta.1"), (1, 0, 1))
        self.assertEqual(build("99.98.99"), (9999, 99, 99))

    def test_malformed_or_unrepresentable_labels_are_rejected(self):
        for label in ["", "v1.0.0", "1.0", "01.0.0", "1.00.0", "1.0.00", "1.0.0\n",
                      "1.0.0-beta.0", "1.0.0-beta.01", "1.0.0-beta.99", "1.0.0-beta.998",
                      "1.0.0-rc.1", "1.0.0+build", "1.100.0", "1.0.100", "99.99.0", "100.0.0"]:
            with self.subTest(label=label), self.assertRaises(ValueError):
                versions.release_version(label)

    def test_cli_json_field_and_invalid_input(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "1.2.3-beta.2"], capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(result.stdout), versions.release_version("1.2.3-beta.2"))
        field = subprocess.run([sys.executable, str(SCRIPT), "1.2.3-beta.2", "--field", "channel"], capture_output=True, text=True, check=True)
        self.assertEqual(field.stdout, "beta\n")
        invalid = subprocess.run([sys.executable, str(SCRIPT), "1.2.3-beta.99"], capture_output=True, text=True)
        self.assertEqual(invalid.returncode, 1)
        self.assertEqual(invalid.stdout, "")
        self.assertIn("Beta ordinal", invalid.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
