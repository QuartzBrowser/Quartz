#!/usr/bin/env python3
"""Verify WebKit cache identity with portable toolchain-output fixtures."""

import copy
import hashlib
import importlib.util
from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("webkit_toolchain", Path(__file__).with_name("webkit-toolchain.py"))
toolchain = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(toolchain)


class WebKitToolchainTests(unittest.TestCase):
    def setUp(self):
        self.components = {
            "xcode": b"Xcode 26.6\nBuild version 17G100\n",
            "swift": (
                b"Apple Swift version 6.3 (swiftlang-6.3.0.1.1 clang-1700.4.1)\n"
                b"Target: arm64-apple-macosx26.0\n"
                b"InstalledDir: /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin\n"
            ),
            "sdk-version": b"26.5\n",
            "metal": (
                b"Apple metal version 32023.100 (metalfe-32023.100)\n"
                b"Target: air64-apple-darwin26.0.0\n"
                b"Thread model: posix\n"
                b"InstalledDir: /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v17.0.308.0.Ba73c/Metal.xctoolchain/usr/metal/current/bin\n"
            ),
            "os": b"26G100\n",
            "arch": b"arm64\n",
            "sdk-settings": b'{"CanonicalName":"macosx26.5","Version":"26.5"}\n',
        }
        self.identity = toolchain.identity_for_components(self.components)

    def identity_with(self, component, value):
        return toolchain.identity_for_components(self.components | {component: value})

    def migration_fixture(self, components=None):
        components = self.components if components is None else components
        old_directory = "/var/run/com.apple.security.cryptexd/mnt/MetalToolchain.previous/Metal.xctoolchain/usr/metal/current/bin"
        old_metal = b"".join(
            b"InstalledDir: " + old_directory.encode() + (b"\r\n" if line.endswith(b"\r\n") else b"\n")
            if line.startswith(b"InstalledDir:") else line
            for line in components["metal"].splitlines(keepends=True)
        )
        original = components | {"metal": old_metal}
        order = ["xcode", "swift", "sdk-version", "metal", "os", "arch", "sdk-settings"]
        legacy_identity = hashlib.sha256(b"".join(original[name] for name in order)).hexdigest()
        source_hashes = {
            "Scripts/build-webkit.sh": hashlib.sha256(b"fixture engine builder").hexdigest(),
            "Scripts/webkit-bundle.py": hashlib.sha256(b"fixture engine bundler").hexdigest(),
            "WebKit.lock.json": hashlib.sha256(b"fixture engine pin").hexdigest(),
        }
        migration = {
            "schemaVersion": 1,
            "legacyIdentity": legacy_identity,
            "legacyKey": "quartz-webkit-universal-macOS-ARM64-" + legacy_identity + "-" + "d" * 64,
            "metalInstalledDirs": [old_directory],
            "sourceHashes": source_hashes.copy(),
        }
        return migration, source_hashes

    def test_identity_is_a_deterministic_sha256_digest(self):
        self.assertRegex(self.identity, r"^[0-9a-f]{64}$")
        self.assertEqual(toolchain.identity_for_components(self.components), self.identity)
        reversed_components = dict(reversed(list(self.components.items())))
        self.assertEqual(toolchain.identity_for_components(reversed_components), self.identity)

    def test_metal_cryptex_mount_suffix_does_not_invalidate_cache(self):
        metal = self.components["metal"].replace(b".Ba73c/", b".F9d12/")
        self.assertNotEqual(metal, self.components["metal"])
        self.assertEqual(self.identity_with("metal", metal), self.identity)

    def test_metal_install_location_does_not_invalidate_cache(self):
        lines = self.components["metal"].splitlines(keepends=True)
        metal = b"".join(lines[:-1]) + b"InstalledDir: /Applications/Toolchains/Metal.xctoolchain/usr/bin\n"
        self.assertEqual(self.identity_with("metal", metal), self.identity)

    def test_swift_install_location_does_not_invalidate_cache(self):
        swift = self.components["swift"].replace(b"/Applications/Xcode.app/", b"/Applications/Xcode_26.6.app/")
        self.assertEqual(self.identity_with("swift", swift), self.identity)

    def test_absent_installed_dir_lines_have_the_same_identity(self):
        for component in ["metal", "swift"]:
            with self.subTest(component=component):
                output = b"".join(
                    line for line in self.components[component].splitlines(keepends=True)
                    if not line.startswith(b"InstalledDir:")
                )
                self.assertEqual(self.identity_with(component, output), self.identity)

    def test_actual_metal_version_invalidates_cache(self):
        metal = self.components["metal"].replace(b"32023.100", b"32023.101")
        self.assertNotEqual(self.identity_with("metal", metal), self.identity)

    def test_metal_target_invalidates_cache(self):
        metal = self.components["metal"].replace(b"darwin26.0.0", b"darwin26.1.0")
        self.assertNotEqual(self.identity_with("metal", metal), self.identity)

    def test_metal_thread_model_invalidates_cache(self):
        metal = self.components["metal"].replace(b"Thread model: posix", b"Thread model: alternate")
        self.assertNotEqual(self.identity_with("metal", metal), self.identity)

    def test_swift_compiler_version_invalidates_cache(self):
        swift = self.components["swift"].replace(b"swiftlang-6.3.0.1.1", b"swiftlang-6.3.0.1.2")
        self.assertNotEqual(self.identity_with("swift", swift), self.identity)

    def test_swift_target_invalidates_cache(self):
        swift = self.components["swift"].replace(b"arm64-apple-macosx26.0", b"x86_64-apple-macosx26.0")
        self.assertNotEqual(self.identity_with("swift", swift), self.identity)

    def test_xcode_build_invalidates_cache(self):
        xcode = self.components["xcode"].replace(b"17G100", b"17G101")
        self.assertNotEqual(self.identity_with("xcode", xcode), self.identity)

    def test_sdk_version_invalidates_cache(self):
        self.assertNotEqual(self.identity_with("sdk-version", b"26.6\n"), self.identity)

    def test_sdk_settings_contents_invalidate_cache(self):
        settings = self.components["sdk-settings"].replace(b'"Version":"26.5"', b'"Version":"26.5","NewSetting":true')
        self.assertNotEqual(self.identity_with("sdk-settings", settings), self.identity)

    def test_os_build_invalidates_cache(self):
        self.assertNotEqual(self.identity_with("os", b"26G101\n"), self.identity)

    def test_architecture_invalidates_cache(self):
        self.assertNotEqual(self.identity_with("arch", b"x86_64\n"), self.identity)

    def test_installed_dir_is_not_removed_from_other_components(self):
        for component in ["xcode", "sdk-version", "sdk-settings", "os", "arch"]:
            with self.subTest(component=component):
                first = self.components[component] + b"InstalledDir: /first\n"
                second = self.components[component] + b"InstalledDir: /second\n"
                self.assertNotEqual(self.identity_with(component, first), self.identity_with(component, second))

    def test_other_version_output_bytes_are_preserved(self):
        for component in ["metal", "swift"]:
            for suffix in [b"\n", b" ", b"Additional output\n"]:
                with self.subTest(component=component, suffix=suffix):
                    self.assertNotEqual(
                        self.identity_with(component, self.components[component] + suffix),
                        self.identity,
                    )
            with self.subTest(component=component, modification="line endings"):
                self.assertNotEqual(
                    self.identity_with(component, self.components[component].replace(b"\n", b"\r\n")),
                    self.identity,
                )

    def test_sdk_settings_are_hashed_as_raw_bytes(self):
        settings = self.components["sdk-settings"].replace(b'"Version":', b' "Version":')
        self.assertNotEqual(self.identity_with("sdk-settings", settings), self.identity)

    def test_every_required_component_must_be_present(self):
        for component in self.components:
            with self.subTest(component=component):
                incomplete = self.components.copy()
                del incomplete[component]
                with self.assertRaises(ValueError):
                    toolchain.identity_for_components(incomplete)

    def test_empty_components_are_rejected(self):
        for component in self.components:
            with self.subTest(component=component):
                with self.assertRaises(ValueError):
                    self.identity_with(component, b"")

    def test_legacy_migration_matches_only_the_pinned_raw_identity(self):
        migration, source_hashes = self.migration_fixture()
        actual = toolchain.legacy_key_for_components(self.components, source_hashes, migration)
        self.assertEqual(actual, migration["legacyKey"])
        reordered = dict(reversed(list(self.components.items())))
        self.assertEqual(
            toolchain.legacy_key_for_components(reordered, source_hashes, migration),
            migration["legacyKey"],
        )

    def test_legacy_migration_accepts_only_an_exact_historical_metal_path(self):
        migration, source_hashes = self.migration_fixture()
        migration["metalInstalledDirs"] = ["/different/historical/metal/bin"]
        self.assertEqual(toolchain.legacy_key_for_components(self.components, source_hashes, migration), "")

    def test_legacy_migration_checks_all_explicit_historical_paths(self):
        migration, source_hashes = self.migration_fixture()
        migration["metalInstalledDirs"].insert(0, "/other/historical/metal/bin")
        self.assertEqual(
            toolchain.legacy_key_for_components(self.components, source_hashes, migration),
            migration["legacyKey"],
        )

    def test_legacy_migration_preserves_installed_dir_line_endings(self):
        components = self.components.copy()
        lines = components["metal"].splitlines(keepends=True)
        components["metal"] = b"".join(lines[:-1]) + lines[-1].replace(b"\n", b"\r\n")
        migration, source_hashes = self.migration_fixture(components)
        self.assertEqual(
            toolchain.legacy_key_for_components(components, source_hashes, migration),
            migration["legacyKey"],
        )
        self.assertEqual(toolchain.legacy_key_for_components(self.components, source_hashes, migration), "")

    def test_legacy_migration_rejects_every_changed_retained_component(self):
        migration, source_hashes = self.migration_fixture()
        for component in self.components:
            with self.subTest(component=component):
                changed = self.components | {component: self.components[component] + b"Changed toolchain output\n"}
                self.assertEqual(toolchain.legacy_key_for_components(changed, source_hashes, migration), "")

    def test_legacy_migration_does_not_substitute_swift_install_location(self):
        migration, source_hashes = self.migration_fixture()
        changed = self.components | {
            "swift": self.components["swift"].replace(b"/Applications/Xcode.app/", b"/Applications/AnotherXcode.app/"),
        }
        self.assertEqual(toolchain.identity_for_components(changed), self.identity)
        self.assertEqual(toolchain.legacy_key_for_components(changed, source_hashes, migration), "")

    def test_legacy_migration_rejects_changed_missing_or_extra_source_hashes(self):
        migration, source_hashes = self.migration_fixture()
        changed = source_hashes | {"Scripts/build-webkit.sh": "f" * 64}
        missing = source_hashes.copy()
        del missing["Scripts/build-webkit.sh"]
        extra = source_hashes | {"Scripts/unexpected.py": "e" * 64}
        for hashes in [changed, missing, extra, {}]:
            with self.subTest(hashes=hashes):
                self.assertEqual(toolchain.legacy_key_for_components(self.components, hashes, migration), "")

    def test_legacy_migration_rejects_missing_duplicate_or_malformed_metal_directory(self):
        migration, source_hashes = self.migration_fixture()
        lines = self.components["metal"].splitlines(keepends=True)
        prefix, directory_line = b"".join(lines[:-1]), lines[-1]
        malformed_outputs = [
            prefix,
            prefix + directory_line + directory_line,
            prefix + b"InstalledDir:\n",
            prefix + b"InstalledDir: \n",
            prefix + b"InstalledDir: relative/path\n",
            prefix + b"InstalledDir: /invalid\x00path\n",
            prefix + directory_line.replace(b"InstalledDir: ", b"InstalledDir="),
        ]
        for metal in malformed_outputs:
            with self.subTest(metal=metal):
                changed = self.components | {"metal": metal}
                self.assertEqual(toolchain.legacy_key_for_components(changed, source_hashes, migration), "")

    def test_legacy_migration_rejects_invalid_schema_or_incomplete_metadata(self):
        migration, source_hashes = self.migration_fixture()
        invalid_metadata = [{}, migration | {"schemaVersion": 2}, migration | {"schemaVersion": "1"}]
        for field in migration:
            incomplete = copy.deepcopy(migration)
            del incomplete[field]
            invalid_metadata.append(incomplete)
        for metadata in invalid_metadata:
            with self.subTest(metadata=metadata):
                self.assertEqual(toolchain.legacy_key_for_components(self.components, source_hashes, metadata), "")

    def test_legacy_migration_rejects_malformed_or_mismatched_identity(self):
        migration, source_hashes = self.migration_fixture()
        for identity in [None, "", "a" * 63, "z" * 64, "a" * 64, migration["legacyIdentity"] + "\n"]:
            with self.subTest(identity=identity):
                metadata = migration | {"legacyIdentity": identity}
                self.assertEqual(toolchain.legacy_key_for_components(self.components, source_hashes, metadata), "")

    def test_legacy_migration_rejects_malformed_or_mismatched_cache_key(self):
        migration, source_hashes = self.migration_fixture()
        key = migration["legacyKey"]
        for value in [
            None,
            "",
            key.replace("macOS-ARM64", "Linux-X64"),
            key.replace(migration["legacyIdentity"], "a" * 64),
            key[:-1],
            key + "\n",
            key + "-another-cache",
        ]:
            with self.subTest(key=value):
                metadata = migration | {"legacyKey": value}
                self.assertEqual(toolchain.legacy_key_for_components(self.components, source_hashes, metadata), "")

    def test_legacy_migration_rejects_malformed_historical_paths(self):
        migration, source_hashes = self.migration_fixture()
        old_path = migration["metalInstalledDirs"][0]
        for paths in [None, [], old_path, [""], ["relative/path"], [old_path + "\n"], [old_path + "\x00"]]:
            with self.subTest(paths=paths):
                metadata = migration | {"metalInstalledDirs": paths}
                self.assertEqual(toolchain.legacy_key_for_components(self.components, source_hashes, metadata), "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
