#!/usr/bin/env python3
"""Test packaging mechanics with synthetic Mach-O fixtures, not a real WebKit build."""

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("webkit_bundle", Path(__file__).with_name("webkit-bundle.py"))
bundle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bundle)


def run(*args, **kwargs):
    result = subprocess.run([str(arg) for arg in args], capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {args}\n{result.stderr}")
    return result.stdout.strip()


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Mach-O tools and clang")
class WebKitBundleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="quartz-webkit-fixtures-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        cls.source = cls.root / "source"
        cls.source.mkdir()
        (cls.source / "LICENSE").write_text("Synthetic packaging test fixture; this is not WebKit.\n")
        run("git", "init", "-q", cls.source)
        run("git", "-C", cls.source, "add", "LICENSE")
        run("git", "-C", cls.source, "-c", "commit.gpgsign=false", "-c", "user.name=Fixture", "-c",
            "user.email=fixture@example.invalid", "commit", "-qm", "test: synthetic engine fixture")
        revision = run("git", "-C", cls.source, "rev-parse", "HEAD")
        cls.lock = cls.root / "fixture.lock.json"
        # A dependency can require a newer OS than the requested engine target.
        cls.lock.write_text(json.dumps({"repository": bundle.REPOSITORY, "revision": revision,
                                        "macOSDeploymentTarget": "13.0"}))
        cls.build = cls.root / "original-build-products"
        cls.build.mkdir()
        cls.arch = "arm64" if platform.machine() == "arm64" else "x86_64"
        cls.compile_flags = ["-arch", cls.arch, "-mmacosx-version-min=14.0", "-Wl,-headerpad_max_install_names"]
        cls.make_products()
        cls.prepared = cls.root / "prepared"
        with contextlib.redirect_stdout(io.StringIO()):
            bundle.prepare(argparse.Namespace(build_dir=cls.build, output_dir=cls.prepared,
                                              source_dir=cls.source, lock_file=cls.lock))
        raw_alias = cls.build / "WebCore.framework/Frameworks"
        cls.raw_optional_alias_unchanged = raw_alias.is_symlink() and not raw_alias.exists()
        # All successful execution checks below run without the original paths.
        shutil.rmtree(cls.build)

    @classmethod
    def compile(cls, source, output, *arguments):
        code = cls.root / (output.name.replace(".", "-") + "-source.c")
        code.write_text(source)
        run("xcrun", "clang", *cls.compile_flags, code, *arguments, "-o", output)

    @classmethod
    def framework(cls, name, source, dependency=None, private=False):
        directory = cls.build / (name + ".framework")
        version = directory / "Versions/A"
        resources = version / "Resources"
        resources.mkdir(parents=True)
        (directory / "Versions/Current").symlink_to("A")
        (directory / name).symlink_to("Versions/Current/" + name)
        # Xcode also emits absolute links within its products directory.
        (directory / "Resources").symlink_to(resources)
        with (resources / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": name, "CFBundleIdentifier": "invalid.fixture." + name,
                          "CFBundlePackageType": "FMWK", "CFBundleVersion": "1.0"}, stream)
        binary = version / name
        prefix = "/System/Library/PrivateFrameworks" if private else "/System/Library/Frameworks"
        arguments = ["-dynamiclib", "-Wl,-not_for_dyld_shared_cache",
                     "-Wl,-install_name," + prefix + "/" + name + ".framework/Versions/A/" + name]
        if dependency:
            arguments.append(dependency)
        cls.compile(source, binary, *arguments)
        return binary

    @classmethod
    def make_products(cls):
        support = cls.build / "libFixtureSupport.dylib"
        cls.compile("int fixture_support(void) { return 39; }\n", support,
                    "-dynamiclib", "-Wl,-install_name," + str(support))
        (cls.build / "libFixtureAlias.dylib").symlink_to(support.name)
        jsc = cls.framework("JavaScriptCore", "extern int fixture_support(void); int fixture_jsc(void) { return fixture_support() + 1; }\n", support)
        core = cls.framework("WebCore", "extern int fixture_jsc(void); int fixture_core(void) { return fixture_jsc() + 1; }\n", jsc, private=True)
        # Upstream Release creates this install-layout alias without its target.
        (cls.build / "WebCore.framework/Frameworks").symlink_to("Versions/Current/Frameworks")
        webkit = cls.framework("WebKit", "extern int fixture_core(void); int fixture_webkit(void) { return fixture_core() + 1; }\n", core)
        xpc = cls.build / "invalid.fixture.WebContent.xpc"
        helper = xpc / "Contents/MacOS/FixtureWebContent"
        helper.parent.mkdir(parents=True)
        with (xpc / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": helper.name, "CFBundleIdentifier": "invalid.fixture.WebContent",
                          "CFBundlePackageType": "XPC!", "CFBundleVersion": "1.0",
                          "XPCService": {}}, stream)
        cls.compile('#include <stdio.h>\nextern int fixture_webkit(void); int main(void) { printf("%d\\n", fixture_webkit()); return fixture_webkit() == 42 ? 0 : 1; }\n',
                    helper, webkit, "-Wl,-rpath," + str(cls.build))
        xpc_links = cls.build / "WebKit.framework/Versions/A/XPCServices"
        xpc_links.mkdir()
        (xpc_links / xpc.name).symlink_to("../../../../" + xpc.name)
        # Keep an unsigned browser fixture outside products; embed relocates it.
        cls.browser = cls.root / "FixtureQuartz"
        cls.compile('#include <stdio.h>\nextern int fixture_webkit(void); int main(void) { printf("%d\\n", fixture_webkit()); return fixture_webkit() == 42 ? 0 : 1; }\n',
                    cls.browser, webkit, "-Wl,-rpath," + str(cls.build))

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="case-", dir=self.root))
        self.addCleanup(shutil.rmtree, self.directory)
        self.products = self.directory / "products"
        shutil.copytree(self.prepared, self.products, symlinks=True)

    def validate(self, **kwargs):
        return bundle.validate(self.products, self.lock, **kwargs)

    def manifest(self):
        return json.loads((self.products / bundle.MANIFEST).read_text())

    def write_manifest(self, manifest):
        (self.products / bundle.MANIFEST).write_text(json.dumps(manifest))

    def update_hash(self, relative):
        manifest = self.manifest()
        manifest["sha256"][relative] = bundle.digest(self.products / relative)
        self.write_manifest(manifest)

    def test_framework_and_dylib_closure_relocated_from_absolute_install_ids(self):
        info = self.validate(archs=[self.arch])
        self.assertEqual(info["architectures"], [self.arch])
        self.assertEqual(len(info["sha256"]), 5)
        for path in bundle.macho_files(self.products):
            for dependency in bundle.dependencies(path):
                self.assertFalse(dependency.startswith(str(self.build)))
                self.assertFalse(any(name in dependency for name in bundle.REQUIRED) and dependency.startswith("/System/Library/"))
        webkit = self.products / "WebKit.framework/Versions/A/WebKit"
        self.assertIn("@rpath/WebCore.framework/Versions/A/WebCore", bundle.dependencies(webkit))
        jsc = self.products / "JavaScriptCore.framework/Versions/A/JavaScriptCore"
        self.assertIn("@rpath/libFixtureSupport.dylib", bundle.dependencies(jsc))
        self.assertEqual(bundle.install_ids(webkit), ["@rpath/WebKit.framework/Versions/A/WebKit"])

    def test_sibling_xpc_and_absolute_framework_symlinks_survive_relocation(self):
        self.validate()
        linked = self.products / "WebKit.framework/Versions/A/XPCServices/invalid.fixture.WebContent.xpc"
        self.assertTrue(linked.is_symlink())
        self.assertEqual(linked.resolve(), self.products / "invalid.fixture.WebContent.xpc")
        resources = self.products / "WebKit.framework/Resources"
        self.assertTrue(resources.is_symlink())
        self.assertFalse(os.path.isabs(os.readlink(resources)))
        self.assertTrue(resources.resolve().is_relative_to(self.products))
        self.assertTrue((self.products / "libFixtureAlias.dylib").is_symlink())

    def test_unused_webcore_frameworks_alias_removed_only_from_staged_copy(self):
        self.assertTrue(self.raw_optional_alias_unchanged)
        self.assertFalse((self.products / "WebCore.framework/Frameworks").is_symlink())
        self.validate()

    def test_populated_webcore_frameworks_alias_preserved(self):
        target = self.products / "WebCore.framework/Versions/A/Frameworks"
        target.mkdir()
        dependency = target / "libFixtureSupport.dylib"
        dependency.symlink_to("../../../../libFixtureSupport.dylib")
        alias = self.products / "WebCore.framework/Frameworks"
        alias.symlink_to("Versions/Current/Frameworks")
        bundle.normalize_webcore_frameworks_link(self.products)
        bundle.check_symlinks(self.products)
        self.assertTrue(alias.is_symlink())
        self.assertEqual((alias / dependency.name).resolve(), self.products / dependency.name)

    def test_dangling_code_symlink_is_not_normalized(self):
        alias = self.products / "WebCore.framework/Frameworks"
        alias.symlink_to("Versions/Current/MissingCode")
        bundle.normalize_webcore_frameworks_link(self.products)
        self.assertTrue(alias.is_symlink())
        with self.assertRaises(FileNotFoundError):
            bundle.check_symlinks(self.products)

    def test_xpc_executes_using_local_rpath_after_original_build_is_removed(self):
        self.assertFalse(self.build.exists())
        executable = self.products / "invalid.fixture.WebContent.xpc/Contents/MacOS/FixtureWebContent"
        self.assertIn("@loader_path/../../..", bundle.rpaths(executable))
        self.assertNotIn(str(self.build), bundle.rpaths(executable))
        environment = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
        self.assertEqual(run(executable, env=environment), "42")

    def embedded_app(self, archs=None):
        app = self.directory / "FixtureQuartz.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Resources").mkdir()
        with (app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "FixtureQuartz", "CFBundleIdentifier": "invalid.fixture.Quartz",
                          "CFBundlePackageType": "APPL", "CFBundleVersion": "1.0"}, stream)
        shutil.copy2(self.browser, app / "Contents/MacOS/FixtureQuartz")
        original_validate = bundle.validate
        def validate_fixture(products, **kwargs):
            return original_validate(products, self.lock, **kwargs)
        with patch.object(bundle, "validate", side_effect=validate_fixture), contextlib.redirect_stdout(io.StringIO()):
            bundle.embed(argparse.Namespace(products_dir=self.products, app_dir=app, executable="FixtureQuartz",
                                            arch=archs if archs is not None else [self.arch]))
        return app

    def test_embed_relocates_browser_and_executes_after_products_are_removed(self):
        app = self.embedded_app()
        shutil.rmtree(self.products)
        run("codesign", "--force", "--sign", "-", app / "Contents/MacOS/FixtureQuartz")
        run("codesign", "--force", "--sign", "-", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
        self.assertEqual(run(app / "Contents/MacOS/FixtureQuartz", env=environment), "42")
        self.assertTrue((app / "Contents/Resources/WebKit-Licenses/LICENSE").is_file())
        self.assertTrue((app / "Contents/Resources/QuartzWebKit.json").is_file())
        helper = app / "Contents/Frameworks/WebKit.framework/Versions/A/XPCServices/invalid.fixture.WebContent.xpc/Contents/MacOS/FixtureWebContent"
        self.assertEqual(run(helper, env=environment), "42")
        self.assertTrue((app / "Contents/Frameworks/libFixtureAlias.dylib").is_symlink())

    def sparkle_fixture(self):
        source = self.directory / "downloaded-artifact/Sparkle.framework"
        version = source / "Versions/B"
        resources = version / "Resources"
        resources.mkdir(parents=True)
        (source / "Versions/Current").symlink_to("B")
        (source / "Sparkle").symlink_to("Versions/Current/Sparkle")
        (source / "Resources").symlink_to("Versions/Current/Resources")
        with (resources / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "Sparkle", "CFBundleIdentifier": "invalid.fixture.Sparkle",
                          "CFBundlePackageType": "FMWK", "CFBundleVersion": "1.0"}, stream)
        webkit = self.products / "WebKit.framework/Versions/A/WebKit"
        sparkle = version / "Sparkle"
        self.compile("extern int fixture_webkit(void); int fixture_sparkle(void) { return fixture_webkit(); }\n",
                     sparkle, webkit, "-dynamiclib", "-Wl,-install_name,@rpath/Sparkle.framework/Versions/B/Sparkle")
        # Model both Sparkle's direct system WebKit edge and nested helper edges.
        helpers = [version / "XPCServices/FixtureDownloader.xpc/Contents/MacOS/FixtureDownloader",
                   version / "Updater.app/Contents/MacOS/Updater"]
        for helper in helpers:
            helper.parent.mkdir(parents=True)
            with (helper.parent.parent / "Info.plist").open("wb") as stream:
                plistlib.dump({"CFBundleExecutable": helper.name,
                              "CFBundleIdentifier": "invalid.fixture." + helper.name,
                              "CFBundlePackageType": "XPC!" if helper.name == "FixtureDownloader" else "APPL",
                              "CFBundleVersion": "1.0", "XPCService": {}}, stream)
            self.compile('#include <stdio.h>\nextern int fixture_webkit(void); extern int fixture_sparkle(void); int main(void) { int value = fixture_webkit() + fixture_sparkle(); printf("%d\\n", value); return value == 84 ? 0 : 1; }\n',
                         helper, sparkle, webkit, "-Wl,-rpath,@loader_path/" + os.path.relpath(source.parent, helper.parent))
        for binary in bundle.macho_files(source):
            run("install_name_tool", "-change", "@rpath/WebKit.framework/Versions/A/WebKit",
                "/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit", binary)
        entitlements = self.directory / "sparkle-entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.network.client": True}))
        for helper in helpers:
            run("codesign", "--force", "--sign", "-", "--entitlements", entitlements, helper)
        bundle.sign(source.parent)
        run("codesign", "--verify", "--deep", "--strict", source)
        return source, [path.relative_to(source) for path in helpers]

    def prepare_sparkle(self, source, output, products=None, manifest=None, system=False):
        original_validate = bundle.validate
        def validate_fixture(directory, **kwargs):
            return original_validate(directory, self.lock, **kwargs)
        with patch.object(bundle, "validate", side_effect=validate_fixture), contextlib.redirect_stdout(io.StringIO()):
            bundle.prepare_sparkle(argparse.Namespace(source_framework=source, output_dir=output,
                                                     products_dir=products or self.products, manifest=manifest, system=system))

    def test_sparkle_copy_replaces_swiftpm_symlink_without_mutating_artifact(self):
        source, helpers = self.sparkle_fixture()
        original = {str(path.relative_to(source)): bundle.digest(path) for path in source.rglob("*") if path.is_file()}
        engine_manifest = (self.products / bundle.MANIFEST).read_bytes()
        output = self.directory / "swiftpm-bin"
        output.mkdir()
        destination = output / "Sparkle.framework"
        destination.symlink_to(source)
        self.prepare_sparkle(source, output)
        self.assertFalse(destination.is_symlink())
        self.assertEqual(original, {str(path.relative_to(source)): bundle.digest(path) for path in source.rglob("*") if path.is_file()})
        self.assertEqual((self.products / bundle.MANIFEST).read_bytes(), engine_manifest)
        self.assertEqual(bundle.install_ids(destination / "Sparkle"), ["@rpath/Sparkle.framework/Versions/B/Sparkle"])
        for path in bundle.macho_files(destination):
            self.assertIn("@rpath/WebKit.framework/Versions/A/WebKit", bundle.dependencies(path))
            self.assertNotIn("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit", bundle.dependencies(path))
        environment = {key: value for key, value in os.environ.items() if not key.startswith(("DYLD_", "__XPC_DYLD_"))}
        for relative in helpers:
            helper = destination / relative
            self.assertIn("@rpath/Sparkle.framework/Versions/B/Sparkle", bundle.dependencies(helper))
            self.assertEqual(run(helper, env=environment), "84")
            self.assertEqual(plistlib.loads(run("codesign", "-d", "--entitlements", ":-", helper).encode()),
                             {"com.apple.security.network.client": True})
            self.assertEqual(helper.stat().st_mode, (source / relative).stat().st_mode)
        run("codesign", "--verify", "--deep", "--strict", destination)
        self.validate()

    def test_packaged_sparkle_and_helpers_use_embedded_engine_after_sources_removed(self):
        source, helpers = self.sparkle_fixture()
        app = self.embedded_app()
        frameworks = app / "Contents/Frameworks"
        manifest = app / "Contents/Resources" / bundle.MANIFEST
        original_manifest = manifest.read_bytes()
        self.prepare_sparkle(source, frameworks, products=frameworks, manifest=manifest)
        self.assertEqual(manifest.read_bytes(), original_manifest)
        shutil.rmtree(source.parent)
        shutil.rmtree(self.products)
        environment = {key: value for key, value in os.environ.items() if not key.startswith(("DYLD_", "__XPC_DYLD_"))}
        for relative in helpers:
            self.assertEqual(run(frameworks / "Sparkle.framework" / relative, env=environment), "84")
        run("codesign", "--force", "--sign", "-", app)
        run("codesign", "--verify", "--deep", "--strict", app)

    def test_system_sparkle_restoration_preserves_original_signed_bytes(self):
        source, _ = self.sparkle_fixture()
        output = self.directory / "swiftpm-bin"
        self.prepare_sparkle(source, output)
        destination = output / "Sparkle.framework"
        self.assertNotEqual(bundle.digest(source / "Sparkle"), bundle.digest(destination / "Sparkle"))
        self.prepare_sparkle(source, output, system=True)
        self.assertEqual({str(path.relative_to(source)): bundle.digest(path) for path in source.rglob("*") if path.is_file()},
                         {str(path.relative_to(destination)): bundle.digest(path) for path in destination.rglob("*") if path.is_file()})
        self.assertIn("/System/Library/Frameworks/WebKit.framework/Versions/A/WebKit", bundle.dependencies(destination / "Sparkle"))
        run("codesign", "--verify", "--deep", "--strict", destination)

    def test_sparkle_leaves_unrelated_helper_load_commands_unchanged(self):
        source, _ = self.sparkle_fixture()
        helper = source / "Versions/B/Helpers/UnrelatedHelper"
        helper.parent.mkdir()
        code = self.directory / "unrelated-helper.c"
        code.write_text('#include <stdio.h>\nint main(void) { puts("7"); return 0; }\n')
        run("xcrun", "clang", "-arch", self.arch, "-mmacosx-version-min=14.0",
            "-Wl,-headerpad,0", code, "-o", helper)
        bundle.sign(source.parent)
        original_dependencies = bundle.dependencies(helper)
        original_rpaths = bundle.rpaths(helper)
        output = self.directory / "swiftpm-bin"
        self.prepare_sparkle(source, output)
        copied = output / "Sparkle.framework" / helper.relative_to(source)
        self.assertEqual(bundle.dependencies(copied), original_dependencies)
        self.assertEqual(bundle.rpaths(copied), original_rpaths)
        environment = {key: value for key, value in os.environ.items() if not key.startswith(("DYLD_", "__XPC_DYLD_"))}
        self.assertEqual(run(copied, env=environment), "7")

    def test_sparkle_rejects_tampered_engine_before_replacing_existing_copy(self):
        source, _ = self.sparkle_fixture()
        output = self.directory / "swiftpm-bin"
        output.mkdir()
        destination = output / "Sparkle.framework"
        destination.symlink_to(source)
        with (self.products / "WebKit.framework/Versions/A/WebKit").open("ab") as stream:
            stream.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.prepare_sparkle(source, output)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(destination.resolve(), source)

    def test_sparkle_cannot_replace_its_downloaded_source(self):
        source, _ = self.sparkle_fixture()
        original = bundle.digest(source / "Sparkle")
        with self.assertRaisesRegex(ValueError, "overlap"):
            self.prepare_sparkle(source, source.parent)
        self.assertEqual(bundle.digest(source / "Sparkle"), original)

    def test_sign_refreshes_only_packaged_engine_hashes_after_signature_changes(self):
        support = self.products / "libFixtureSupport.dylib"
        run("codesign", "--force", "--sign", "-", "--identifier", "invalid.fixture.input-signature",
            "--options", "runtime", support)
        self.update_hash("libFixtureSupport.dylib")
        original_manifest = (self.products / bundle.MANIFEST).read_bytes()
        original = self.manifest()
        app = self.embedded_app()
        frameworks = app / "Contents/Frameworks"
        manifest_path = app / "Contents/Resources" / bundle.MANIFEST

        # Add unrelated, real Mach-O code to establish Sparkle stays outside the
        # engine inventory. It does not need to implement Sparkle's updater API.
        sparkle = frameworks / "Sparkle.framework"
        version = sparkle / "Versions/A"
        resources = version / "Resources"
        resources.mkdir(parents=True)
        (sparkle / "Versions/Current").symlink_to("A")
        (sparkle / "Sparkle").symlink_to("Versions/Current/Sparkle")
        (sparkle / "Resources").symlink_to("Versions/Current/Resources")
        shutil.copy2(support, version / "Sparkle")
        with (resources / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleExecutable": "Sparkle", "CFBundleIdentifier": "invalid.fixture.Sparkle",
                          "CFBundlePackageType": "FMWK", "CFBundleVersion": "1.0"}, stream)

        run(sys.executable, Path(__file__).with_name("webkit-bundle.py"), "sign", frameworks,
            "--manifest", manifest_path)
        updated = json.loads(manifest_path.read_text())
        self.assertNotEqual(updated["sha256"]["libFixtureSupport.dylib"], original["sha256"]["libFixtureSupport.dylib"])
        self.assertEqual(set(updated["sha256"]), set(original["sha256"]))
        self.assertEqual({key: value for key, value in updated.items() if key != "sha256"},
                         {key: value for key, value in original.items() if key != "sha256"})
        for relative, expected in updated["sha256"].items():
            self.assertEqual(bundle.digest(frameworks / relative), expected)
            self.assertFalse(relative.startswith("Sparkle.framework/"))
        self.assertEqual((self.products / bundle.MANIFEST).read_bytes(), original_manifest)
        for relative, expected in original["sha256"].items():
            self.assertEqual(bundle.digest(self.products / relative), expected)
        run("codesign", "--force", "--sign", "-", app)
        run("codesign", "--verify", "--deep", "--strict", app)

    def test_sign_rejects_tampered_input_before_updating_manifest_or_other_binaries(self):
        manifest_path = self.products / bundle.MANIFEST
        original_manifest = manifest_path.read_bytes()
        webkit = self.products / "WebKit.framework/Versions/A/WebKit"
        original_webkit_hash = bundle.digest(webkit)
        with (self.products / "libFixtureSupport.dylib").open("ab") as stream:
            stream.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            bundle.sign(self.products, manifest=manifest_path)
        self.assertEqual(manifest_path.read_bytes(), original_manifest)
        self.assertEqual(bundle.digest(webkit), original_webkit_hash)

    def test_sign_rejects_missing_or_extra_engine_binaries(self):
        for change in ["missing", "extra"]:
            with self.subTest(change=change):
                products = self.directory / change
                shutil.copytree(self.products, products, symlinks=True)
                manifest_path = products / bundle.MANIFEST
                original_manifest = manifest_path.read_bytes()
                if change == "missing":
                    (products / "WebKit.framework/Versions/A/WebKit").unlink()
                else:
                    shutil.copy2(products / "libFixtureSupport.dylib",
                                 products / "WebKit.framework/Versions/A/extra.dylib")
                with self.assertRaisesRegex(ValueError, "Missing WebKit|inventory"):
                    bundle.sign(products, manifest=manifest_path)
                self.assertEqual(manifest_path.read_bytes(), original_manifest)

    def test_sign_rejects_manifest_path_escape_and_symlink(self):
        outside = self.directory / "outside.dylib"
        shutil.copy2(self.products / "libFixtureSupport.dylib", outside)
        original_hash = bundle.digest(outside)
        manifest_path = self.products / bundle.MANIFEST
        manifest = self.manifest()
        manifest["sha256"]["../outside.dylib"] = original_hash
        self.write_manifest(manifest)
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            bundle.sign(self.products, manifest=manifest_path)
        self.assertEqual(bundle.digest(outside), original_hash)
        alias = self.directory / "manifest-alias.json"
        alias.symlink_to(manifest_path)
        with self.assertRaisesRegex(ValueError, "symlinked WebKit signing manifest"):
            bundle.sign(self.products, manifest=alias)

    def test_universal_products_relocate_and_report_all_slices(self):
        # Reuse the C fixture graph with independent directories for each slice.
        class SliceFixture(WebKitBundleTests):
            pass

        slices = {}
        browsers = {}
        for arch, minimum in [("arm64", "14.0"), ("x86_64", "15.0")]:
            SliceFixture.root = self.directory / arch
            SliceFixture.root.mkdir()
            SliceFixture.build = SliceFixture.root / "raw"
            SliceFixture.build.mkdir()
            SliceFixture.compile_flags = ["-arch", arch, "-mmacosx-version-min=" + minimum,
                                          "-Wl,-headerpad_max_install_names"]
            SliceFixture.make_products()
            slices[arch] = SliceFixture.build
            browsers[arch] = SliceFixture.browser

        raw = self.directory / "universal-raw"
        shutil.copytree(slices["arm64"], raw, symlinks=True)
        for path in raw.rglob("*"):
            if path.is_symlink() and os.path.isabs(os.readlink(path)):
                target = Path(os.readlink(path)).relative_to(slices["arm64"])
                path.unlink()
                path.symlink_to(raw / target)
        for arm_binary in bundle.macho_files(slices["arm64"]):
            relative = arm_binary.relative_to(slices["arm64"])
            run("lipo", "-create", arm_binary, slices["x86_64"] / relative, "-output", raw / relative)
        browser = self.directory / "UniversalQuartz"
        run("lipo", "-create", browsers["arm64"], browsers["x86_64"], "-output", browser)

        products = self.directory / "universal-products"
        with contextlib.redirect_stdout(io.StringIO()):
            bundle.prepare(argparse.Namespace(build_dir=raw, output_dir=products,
                                              source_dir=self.source, lock_file=self.lock))
        info = bundle.validate(products, self.lock, archs=["arm64", "x86_64"])
        self.assertEqual(info["architectures"], ["arm64", "x86_64"])
        self.assertEqual(info["minimumSystemVersion"], "15.0")
        self.products = products
        self.browser = browser
        app = self.embedded_app(archs=["arm64", "x86_64"])
        frameworks = app / "Contents/Frameworks"
        manifest = app / "Contents/Resources" / bundle.MANIFEST
        bundle.sign(frameworks, manifest=manifest)

        for arch in ["arm64", "x86_64"]:
            with self.subTest(architecture=arch):
                webkit = frameworks / "WebKit.framework/Versions/A/WebKit"
                support = frameworks / "libFixtureSupport.dylib"
                helper = frameworks / "invalid.fixture.WebContent.xpc/Contents/MacOS/FixtureWebContent"
                self.assertIn("@rpath/WebKit.framework/Versions/A/WebKit", run("otool", "-arch", arch, "-D", webkit))
                self.assertIn("@rpath/libFixtureSupport.dylib", run("otool", "-arch", arch, "-D", support))
                for binary in [*bundle.macho_files(frameworks), app / "Contents/MacOS/FixtureQuartz"]:
                    commands = run("otool", "-arch", arch, "-l", binary)
                    dependencies = run("otool", "-arch", arch, "-L", binary)
                    self.assertNotIn(str(slices["arm64"]), commands)
                    self.assertNotIn(str(slices["x86_64"]), commands)
                    self.assertNotIn("/System/Library/Frameworks/WebKit.framework/", dependencies)
                    self.assertNotIn("/System/Library/Frameworks/JavaScriptCore.framework/", dependencies)
                    self.assertNotIn("/System/Library/PrivateFrameworks/WebCore.framework/", dependencies)
                    self.assertIn("LC_RPATH", commands)
                self.assertIn("@loader_path/../../..", run("otool", "-arch", arch, "-l", helper))
        for directory in [raw, products, *slices.values()]:
            shutil.rmtree(directory)
        run("codesign", "--force", "--sign", "-", app)
        run("codesign", "--verify", "--deep", "--strict", app)
        environment = {key: value for key, value in os.environ.items() if not key.startswith("DYLD_")}
        # This executes the host slice; inspecting Intel load commands is not an
        # assertion that the x86_64 runtime was exercised on an arm64 host.
        self.assertEqual(run(app / "Contents/MacOS/FixtureQuartz", env=environment), "42")

    def test_requested_architecture_must_be_present_in_every_binary(self):
        other = "x86_64" if self.arch == "arm64" else "arm64"
        with self.assertRaisesRegex(ValueError, "missing requested architectures"):
            self.validate(archs=[self.arch, other])

    def test_manifest_cannot_claim_an_architecture_absent_from_binaries(self):
        manifest = self.manifest()
        manifest["architectures"] = ["arm64", "x86_64"]
        self.write_manifest(manifest)
        with self.assertRaisesRegex(ValueError, "architecture manifest"):
            self.validate()

    def test_prepared_framework_and_xpc_signatures_verify(self):
        for name in [*bundle.REQUIRED, "invalid.fixture.WebContent.xpc", "libFixtureSupport.dylib"]:
            with self.subTest(product=name):
                # Strict symlink containment is checked on the enclosing app:
                # WebKit's XPC symlinks intentionally reference sibling bundles.
                run("codesign", "--verify", self.products / name)

    def test_missing_manifest_is_rejected(self):
        (self.products / bundle.MANIFEST).unlink()
        with self.assertRaises(FileNotFoundError):
            self.validate()

    def test_tampered_revision_and_binary_hash_are_rejected(self):
        manifest = self.manifest()
        manifest["revision"] = "0" * 40
        self.write_manifest(manifest)
        with self.assertRaisesRegex(ValueError, "do not match"):
            self.validate()
        manifest["revision"] = json.loads(self.lock.read_text())["revision"]
        self.write_manifest(manifest)
        with (self.products / "libFixtureSupport.dylib").open("ab") as stream:
            stream.write(b"tampered")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.validate()

    def test_missing_transitive_library_is_rejected_even_with_updated_inventory(self):
        (self.products / "libFixtureSupport.dylib").unlink()
        (self.products / "libFixtureAlias.dylib").unlink()
        manifest = self.manifest()
        del manifest["sha256"]["libFixtureSupport.dylib"]
        manifest["products"].remove("libFixtureSupport.dylib")
        manifest["products"].remove("libFixtureAlias.dylib")
        self.write_manifest(manifest)
        with self.assertRaisesRegex(ValueError, "Unbundled dependency|Missing embedded dependency"):
            self.validate()

    def test_system_webcore_fallback_is_rejected_even_with_updated_hash(self):
        relative = "WebKit.framework/Versions/A/WebKit"
        run("install_name_tool", "-change", "@rpath/WebCore.framework/Versions/A/WebCore",
            "/System/Library/PrivateFrameworks/WebCore.framework/Versions/A/WebCore", self.products / relative)
        self.update_hash(relative)
        with self.assertRaisesRegex(ValueError, "Unrelocated WebKit dependency|System WebKit dependency"):
            self.validate()

    def test_added_binary_is_rejected(self):
        shutil.copy2(self.products / "libFixtureSupport.dylib", self.products / "unexpected.dylib")
        with self.assertRaisesRegex(ValueError, "inventory|products"):
            self.validate()

    def test_required_framework_cannot_be_a_non_macho_placeholder(self):
        relative = "WebKit.framework/Versions/A/WebKit"
        (self.products / relative).write_text("not a framework executable")
        manifest = self.manifest()
        del manifest["sha256"][relative]
        self.write_manifest(manifest)
        with self.assertRaises(ValueError):
            self.validate()

    def test_lowered_manifest_minimum_version_is_rejected(self):
        manifest = self.manifest()
        manifest["minimumSystemVersion"] = "10.9"
        self.write_manifest(manifest)
        with self.assertRaises(ValueError):
            self.validate()

    def test_requested_target_and_higher_actual_minimum_are_recorded_separately(self):
        manifest = self.validate()
        self.assertEqual(manifest["macOSDeploymentTarget"], "13.0")
        self.assertEqual(manifest["minimumSystemVersion"], "14.0")
        self.assertGreater(bundle.version_tuple(manifest["minimumSystemVersion"]),
                           bundle.version_tuple(manifest["macOSDeploymentTarget"]))

    def test_old_or_missing_requested_target_metadata_is_rejected(self):
        original = self.manifest()
        for target in ["26.5", None]:
            with self.subTest(target=target):
                manifest = original.copy()
                if target is None:
                    del manifest["macOSDeploymentTarget"]
                else:
                    manifest["macOSDeploymentTarget"] = target
                self.write_manifest(manifest)
                with self.assertRaisesRegex(ValueError, "macOSDeploymentTarget does not match"):
                    self.validate()

    def test_changed_lock_target_rejects_unchanged_products_at_same_revision(self):
        lock = json.loads(self.lock.read_text())
        lock["macOSDeploymentTarget"] = "15.4"
        changed_lock = self.directory / "changed.lock.json"
        changed_lock.write_text(json.dumps(lock))
        with self.assertRaisesRegex(ValueError, "macOSDeploymentTarget does not match"):
            bundle.validate(self.products, changed_lock)

    def test_manifest_products_cannot_escape_or_omit_the_products_directory(self):
        for invalid in ["../outside.framework", "/tmp/outside.framework", "WebKit.framework/../outside.framework"]:
            with self.subTest(product=invalid):
                manifest = self.manifest()
                manifest["products"] = [invalid]
                self.write_manifest(manifest)
                with self.assertRaises(ValueError):
                    self.validate()

    def test_symlink_cannot_escape_the_products_directory(self):
        outside = self.directory / "outside"
        outside.write_text("outside products")
        (self.products / "WebKit.framework/Versions/A/Resources/escape").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            self.validate()

    def test_prepare_replaces_its_own_prior_products(self):
        previous = self.manifest()
        previous["revision"] = "0" * 40
        self.write_manifest(previous)
        bundle.check_output(self.products)
        with contextlib.redirect_stdout(io.StringIO()):
            bundle.prepare(argparse.Namespace(build_dir=self.prepared, output_dir=self.products,
                                              source_dir=self.source, lock_file=self.lock))
        self.assertEqual(self.validate()["revision"], json.loads(self.lock.read_text())["revision"])
        self.assertTrue((self.products / bundle.MANAGED_MARKER).is_file())

    def test_managed_products_with_unrelated_user_file_cannot_be_replaced(self):
        note = self.products / "my-notes.txt"
        note.write_text("Preserve this user file.\n")
        with self.assertRaisesRegex(ValueError, "unrelated files"):
            bundle.check_output(self.products)
        self.assertEqual(note.read_text(), "Preserve this user file.\n")


class WebKitOutputSafetyTests(unittest.TestCase):
    def test_prepare_refuses_an_unmanaged_directory_without_changing_it(self):
        with tempfile.TemporaryDirectory(prefix="quartz-webkit-output-test-") as temporary:
            root = Path(temporary)
            output = root / "unmanaged"
            output.mkdir()
            note = output / "my-notes.txt"
            note.write_text("Preserve this user file.\n")
            with self.assertRaisesRegex(ValueError, "unmanaged directory"):
                bundle.prepare(argparse.Namespace(build_dir=root / "raw", source_dir=root / "source",
                                                  output_dir=output, lock_file=root / "missing-lock.json"))
            self.assertEqual(list(output.iterdir()), [note])
            self.assertEqual(note.read_text(), "Preserve this user file.\n")

    def test_check_output_refuses_a_directory_symlink(self):
        with tempfile.TemporaryDirectory(prefix="quartz-webkit-output-test-") as temporary:
            root = Path(temporary)
            directory = root / "actual"
            directory.mkdir()
            alias = root / "alias"
            alias.symlink_to(directory)
            with self.assertRaisesRegex(ValueError, "ordinary directory"):
                bundle.check_output(alias)
            self.assertTrue(alias.is_symlink())

    def test_new_and_empty_output_directories_are_allowed(self):
        with tempfile.TemporaryDirectory(prefix="quartz-webkit-output-test-") as temporary:
            output = Path(temporary) / "output"
            bundle.check_output(output)
            self.assertFalse(output.exists())
            output.mkdir()
            bundle.check_output(output)
            self.assertEqual(list(output.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
