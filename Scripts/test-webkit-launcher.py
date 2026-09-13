#!/usr/bin/env python3
"""Exercise the WebKit app launcher's paths and environment with a disposable C runtime."""

import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


def run(*arguments, **kwargs):
    return subprocess.run([str(value) for value in arguments], capture_output=True, check=True, **kwargs)


@unittest.skipUnless(platform.system() == "Darwin", "requires the macOS compiler and code signing tools")
class QuartzLauncherTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="quartz-launcher-fixture-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        cls.launcher = cls.root / "launcher"
        run("xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-mmacosx-version-min=15.4",
            ROOT / "Scripts/QuartzLauncher.c", "-o", cls.launcher)
        run("codesign", "--force", "--sign", "-", "--options", "runtime", cls.launcher)
        source = cls.root / "runtime.c"
        source.write_text(r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern char **environ;
int main(int argc, char **argv) {
    for (int i = 0; i < argc; ++i) { fputs(argv[i], stdout); fputc(0, stdout); }
    fputs("ENVIRONMENT", stdout); fputc(0, stdout);
    for (char **entry = environ; *entry; ++entry) {
        if (!strncmp(*entry, "DYLD_", 5) || !strncmp(*entry, "__XPC_DYLD_", 11)
            || !strncmp(*entry, "QUARTZ_LAUNCHER_TEST=", 21)) {
            fputs(*entry, stdout); fputc(0, stdout);
        }
    }
    return 17;
}
''')
        cls.runtime = cls.root / "runtime"
        run("xcrun", "clang", "-mmacosx-version-min=15.4", source, "-o", cls.runtime)
        entitlements = cls.root / "entitlements.plist"
        entitlements.write_bytes(plistlib.dumps({"com.apple.security.cs.allow-dyld-environment-variables": True}))
        run("codesign", "--force", "--sign", "-", "--options", "runtime", "--entitlements", entitlements, cls.runtime)

    def setUp(self):
        self.directory = Path(tempfile.mkdtemp(prefix="case-", dir=self.root))
        self.addCleanup(shutil.rmtree, self.directory)
        self.app = self.directory / "Quartz.app"
        self.macos = self.app / "Contents/MacOS"
        self.macos.mkdir(parents=True)
        (self.app / "Contents/Frameworks").mkdir()
        shutil.copy2(self.launcher, self.macos / "Quartz")
        shutil.copy2(self.runtime, self.macos / "QuartzRuntime")

    def launch(self, path=None, arguments=(), environment=None):
        return subprocess.run([str(path or self.macos / "Quartz"), *arguments], env=environment,
                              capture_output=True, timeout=10)

    def test_moved_bundle_preserves_arguments_and_sets_only_own_loader_paths(self):
        moved = self.directory / "Moved Ω browser with spaces.app"
        self.app.rename(moved)
        self.app = moved
        self.macos = moved / "Contents/MacOS"
        environment = os.environ.copy()
        environment.update({"DYLD_FRAMEWORK_PATH": "/invalid/inherited", "DYLD_LIBRARY_PATH": "/invalid/library",
                            "DYLD_INSERT_LIBRARIES": "/invalid/injected.dylib", "DYLD_PRINT_LIBRARIES": "1",
                            "__XPC_DYLD_FRAMEWORK_PATH": "/invalid/xpc", "__XPC_DYLD_INSERT_LIBRARIES": "/invalid/xpc.dylib",
                            "QUARTZ_LAUNCHER_TEST": "retained", "PATH": "/invalid/no-search"})
        arguments = ["--quartz-webkit-info", "two words", "", "literal\nnewline", "$(unchanged)"]
        result = self.launch(arguments=arguments, environment=environment)
        self.assertEqual(result.returncode, 17, result.stderr.decode())
        records = result.stdout.decode().split("\0")[:-1]
        self.assertEqual(records[:len(arguments) + 1], [str(self.macos / "QuartzRuntime"), *arguments])
        self.assertEqual(records[len(arguments) + 1], "ENVIRONMENT")
        frameworks = str(moved / "Contents/Frameworks")
        self.assertEqual(set(records[len(arguments) + 2:]), {
            "DYLD_FRAMEWORK_PATH=" + frameworks,
            "__XPC_DYLD_FRAMEWORK_PATH=" + frameworks,
            "QUARTZ_LAUNCHER_TEST=retained",
        })

    def test_launching_through_symlink_uses_the_real_bundle(self):
        alias = self.directory / "launch-link"
        alias.symlink_to(self.macos / "Quartz")
        result = self.launch(path=alias)
        self.assertEqual(result.returncode, 17, result.stderr.decode())
        self.assertIn(("DYLD_FRAMEWORK_PATH=" + str(self.app / "Contents/Frameworks")).encode(), result.stdout)

    def test_colon_in_bundle_path_fails_before_starting_runtime(self):
        moved = self.directory / "Quartz: browser.app"
        self.app.rename(moved)
        result = self.launch(path=moved / "Contents/MacOS/Quartz")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"location without a colon", result.stderr)

    def test_missing_runtime_fails_clearly(self):
        (self.macos / "QuartzRuntime").unlink()
        result = self.launch()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Missing executable Contents/MacOS/QuartzRuntime", result.stderr)

    def test_missing_frameworks_fails_clearly(self):
        (self.app / "Contents/Frameworks").rmdir()
        result = self.launch()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Missing Contents/Frameworks", result.stderr)

    def test_runtime_symlink_cannot_escape_the_bundle(self):
        runtime = self.macos / "QuartzRuntime"
        runtime.unlink()
        runtime.symlink_to(self.runtime)
        result = self.launch()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"Missing executable", result.stderr)

    def test_launcher_links_only_libsystem(self):
        output = run("xcrun", "otool", "-L", self.launcher).stdout.decode().splitlines()[1:]
        self.assertEqual([line.strip().split(" ")[0] for line in output], ["/usr/lib/libSystem.B.dylib"])


if __name__ == "__main__":
    unittest.main()
