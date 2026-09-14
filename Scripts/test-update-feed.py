#!/usr/bin/env python3
"""Exercise release feed retention, public checks, and real Git publication races.

Git tests inject only HTTP/signature boundaries. macOS tests separately verify
real Ed25519 feed bytes using both CryptoKit and the pinned Sparkle tools.
"""

import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("feed", ROOT / "Scripts/publish-update-feed.py")
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


def run(*args, cwd=None, input=None, env=None):
    return subprocess.run(args, cwd=cwd, input=input, capture_output=True, check=True, env=env).stdout


def appcast(*versions):
    ET.register_namespace("sparkle", feed.SPARKLE[1:-1])
    root = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(root, "channel")
    ET.SubElement(channel, "title").text = "Quartz updates"
    for version in versions:
        info = feed.metadata(version)
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = "Quartz " + version
        ET.SubElement(item, feed.SPARKLE + "version").text = info["build_version"]
        ET.SubElement(item, feed.SPARKLE + "shortVersionString").text = version
        if info["channel"] == "beta":
            ET.SubElement(item, feed.SPARKLE + "channel").text = "beta"
        ET.SubElement(item, feed.SPARKLE + "minimumSystemVersion").text = "15.4"
        ET.SubElement(item, "enclosure", {
            "url": f"https://github.com/QuartzBrowser/Quartz/releases/download/v{version}/Quartz-v{version}-macos-universal.zip",
            "length": "123", feed.SPARKLE + "edSignature": base64.b64encode(bytes(64)).decode(),
        })
    return ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"


class FeedPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="quartz-feed-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.remote = self.directory / "origin.git"
        self.repository = self.directory / "checkout"
        run("git", "init", "--bare", str(self.remote))
        run("git", "init", "-b", "main", str(self.repository))
        self.git("config", "user.name", "Test maintainer")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.repository / "tracked").write_text("original\n")
        self.git("add", "tracked")
        self.git("commit", "-m", "initial")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "origin", "main")
        self.verified = []

    def git(self, *arguments):
        return run("git", "-C", str(self.repository), *arguments)

    def lookup(self, version):
        return {"tag_name": "v" + version, "draft": False, "prerelease": "-beta." in version,
                "assets": [{"name": name, "state": "uploaded", "size": 123} for name in
                           (f"Quartz-v{version}-macos-universal.zip", "appcast.xml", "SHA256SUMS")]}

    def verifier(self, path, public_key):
        self.verified.append(Path(path).read_bytes())

    def publish(self, version, data, **overrides):
        path = self.directory / "proposed.xml"
        path.write_bytes(data)
        options = {"verifier": self.verifier, "lookup": self.lookup, "fetch": lambda url: data}
        options.update(overrides)
        return feed.publish(self.repository, version, path, "test-public-key", **options)

    def active(self):
        return run("git", "--git-dir", str(self.remote), "show", "update-feed:appcast.xml")

    def test_bootstrap_creates_only_feed_branch_and_preserves_user_index(self):
        original_head = self.git("rev-parse", "HEAD")
        (self.repository / "tracked").write_text("staged user work\n")
        self.git("add", "tracked")
        (self.repository / "tracked").write_text("unstaged user work\n")
        index = self.git("diff", "--cached")
        worktree = self.git("diff")
        data = appcast("1.1.0")
        result = self.publish("1.1.0", data)
        self.assertTrue(result["changed"])
        self.assertEqual(self.active(), data)
        self.assertEqual(original_head, self.git("rev-parse", "HEAD"))
        self.assertEqual(index, self.git("diff", "--cached"))
        self.assertEqual(worktree, self.git("diff"))
        self.assertEqual(self.verified, [data])

    def test_beta_and_older_stable_patch_retain_both_channels(self):
        self.publish("1.0.2", appcast("1.0.2"))
        self.publish("1.1.0-beta.1", appcast("1.0.2", "1.1.0-beta.1"))
        proposed = appcast("1.0.2", "1.1.0-beta.1", "1.0.3")
        self.publish("1.0.3", proposed)
        self.assertEqual(self.active(), proposed)
        self.assertEqual(len(self.verified), 5)

    def test_retry_same_feed_does_not_create_commit(self):
        data = appcast("1.1.0-beta.1")
        first = self.publish("1.1.0-beta.1", data)
        second = self.publish("1.1.0-beta.1", data)
        self.assertFalse(second["changed"])
        self.assertEqual(first["revision"], second["revision"])

    def test_stale_recovery_cannot_remove_newer_beta(self):
        data = appcast("1.0.2", "1.1.0-beta.1")
        self.publish("1.1.0-beta.1", data)
        with self.assertRaisesRegex(RuntimeError, "remove or change"):
            self.publish("1.0.2", appcast("1.0.2"))
        self.assertEqual(self.active(), data)

    def test_changed_existing_requirement_is_rejected(self):
        self.publish("1.0.2", appcast("1.0.2"))
        data = appcast("1.0.2", "1.1.0-beta.1").replace(b"15.4", b"26.0", 1)
        with self.assertRaisesRegex(RuntimeError, "remove or change"):
            self.publish("1.1.0-beta.1", data)

    def test_force_push_is_never_used_for_racing_publication(self):
        initial = appcast("1.0.2")
        self.publish("1.0.2", initial)
        newer = appcast("1.0.2", "1.1.0-beta.2")
        def advance():
            self.publish("1.1.0-beta.2", newer)
        with self.assertRaisesRegex(RuntimeError, "no feed was force-pushed"):
            self.publish("1.1.0-beta.1", appcast("1.0.2", "1.1.0-beta.1"), before_push=advance)
        self.assertEqual(self.active(), newer)

    def test_signature_failure_prevents_publication(self):
        def reject(path, public_key):
            raise ValueError("bad signature")
        with self.assertRaisesRegex(ValueError, "bad signature"):
            self.publish("1.1.0", appcast("1.1.0"), verifier=reject)
        self.assertEqual(self.git("ls-remote", "origin", feed.FEED_BRANCH), b"")

    def test_current_feed_signature_must_also_verify(self):
        self.publish("1.0.2", appcast("1.0.2"))
        def reject_previous(path, public_key):
            if Path(path).name == "previous.xml":
                raise ValueError("untrusted previous feed")
        with self.assertRaisesRegex(ValueError, "untrusted previous feed"):
            self.publish("1.1.0", appcast("1.0.2", "1.1.0"), verifier=reject_previous)

    def test_release_must_be_published_in_correct_channel(self):
        for changes in ({"draft": True}, {"prerelease": False}, {"tag_name": "v9.9.9"}):
            with self.subTest(changes=changes), self.assertRaisesRegex(ValueError, "publication state"):
                self.publish("1.1.0-beta.1", appcast("1.1.0-beta.1"),
                             lookup=lambda version: {**self.lookup(version), **changes})

    def test_incomplete_release_assets_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "assets"):
            self.publish("1.1.0", appcast("1.1.0"), lookup=lambda version: {**self.lookup(version), "assets": []})

    def test_only_exact_published_feed_bytes_can_be_activated(self):
        with self.assertRaisesRegex(ValueError, "bytes"):
            self.publish("1.1.0", appcast("1.1.0"), fetch=lambda url: appcast("1.0.2"))

    def test_read_only_check_accepts_newer_items_without_git_mutation(self):
        reference = self.directory / "reference.xml"
        current = self.directory / "current.xml"
        reference.write_bytes(appcast("1.0.2"))
        current.write_bytes(appcast("1.0.2", "1.1.0-beta.1"))
        feed.check_feed(reference, current, "1.0.2", "key", verifier=self.verifier)
        self.assertEqual(self.git("ls-remote", "origin", feed.FEED_BRANCH), b"")

    def test_read_only_check_rejects_missing_or_changed_release(self):
        reference = self.directory / "reference.xml"
        current = self.directory / "current.xml"
        reference.write_bytes(appcast("1.0.2"))
        for data in (appcast("1.1.0-beta.1"), appcast("1.0.2").replace(b"15.4", b"26.0")):
            current.write_bytes(data)
            with self.assertRaises(ValueError):
                feed.check_feed(reference, current, "1.0.2", "key", verifier=self.verifier)

    def test_duplicate_labels_and_external_entities_are_rejected(self):
        for data in (appcast("1.0.2", "1.0.2"), b'<!DOCTYPE rss [<!ENTITY x "bad">]><rss/>'):
            with self.assertRaises(ValueError):
                feed.entries(data)

    def test_beta_without_channel_is_rejected(self):
        data = appcast("1.1.0-beta.1").replace(b"<sparkle:channel>beta</sparkle:channel>", b"")
        with self.assertRaisesRegex(ValueError, "channel"):
            feed.expected_entry(data, "1.1.0-beta.1")

    def test_wrong_build_and_download_url_are_rejected(self):
        original = appcast("1.1.0-beta.1")
        for data in (original.replace(b"102.0.1", b"999.0.1"), original.replace(b"https://github.com/", b"https://example.invalid/")):
            with self.assertRaises(ValueError):
                feed.expected_entry(data, "1.1.0-beta.1")

    def test_legacy_stable_build_is_accepted(self):
        data = appcast("1.0.1").replace(b"101.1.99", b"1.0.1")
        self.assertEqual(feed.expected_entry(data, "1.0.1")["build"], "1.0.1")


@unittest.skipUnless(sys.platform == "darwin", "CryptoKit feed verification runs on macOS")
class SignedFeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="quartz-signed-feed-")
        cls.directory = Path(cls.temporary.name)
        cls.verifier = cls.directory / "verify-feed"
        run("swiftc", str(ROOT / "Scripts/verify-feed.swift"), "-o", str(cls.verifier))
        cls.archive_verifier = cls.directory / "verify-release-archive"
        run("swiftc", str(ROOT / "Scripts/verify-release-archive.swift"), "-o", str(cls.archive_verifier))
        cls.source = cls.directory / "source.xml"
        cls.source.write_bytes(appcast("1.0.2"))
        run("swift", "-", str(cls.directory), input=b'''import CryptoKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let archive = Data("signed Quartz archive fixture".utf8)
try archive.write(to: directory.appendingPathComponent("archive.zip"))
let document = try XMLDocument(contentsOf: directory.appendingPathComponent("source.xml"))
let enclosure = document.rootElement()!.elements(forName: "channel")[0].elements(forName: "item")[0].elements(forName: "enclosure")[0]
enclosure.attribute(forName: "length")!.stringValue = String(archive.count)
enclosure.attribute(forName: "sparkle:edSignature")!.stringValue = try key.signature(for: archive).base64EncodedString()
let data = document.xmlData
try data.write(to: directory.appendingPathComponent("source.xml"))
let signature = try key.signature(for: data).base64EncodedString()
let block = "<!-- sparkle-signatures:\\nedSignature: \\(signature)\\nlength: \\(data.count)\\n-->\\n"
try (data + Data(block.utf8)).write(to: directory.appendingPathComponent("signed.xml"))
try key.publicKey.rawRepresentation.base64EncodedData().write(to: directory.appendingPathComponent("public-key"))
try key.rawRepresentation.base64EncodedData().write(to: directory.appendingPathComponent("private-key"))
''')
        cls.key = (cls.directory / "public-key").read_text()
        cls.signed = (cls.directory / "signed.xml").read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def verify(self, data, key=None):
        path = self.directory / "input.xml"
        path.write_bytes(data)
        return subprocess.run([str(self.verifier), str(path), key or self.key], capture_output=True).returncode

    def test_valid_signature_and_pinned_sparkle_agree(self):
        self.assertEqual(self.verify(self.signed), 0)
        sparkle = ROOT / ".build/artifacts/sparkle/Sparkle/bin/sign_update"
        if sparkle.exists():
            run(str(sparkle), "--verify", "--ed-key-file", str(self.directory / "private-key"), str(self.directory / "signed.xml"))

    def test_content_tampering_is_rejected(self):
        self.assertNotEqual(self.verify(self.signed.replace(b"15.4", b"26.0")), 0)

    def test_wrong_key_is_rejected(self):
        self.assertNotEqual(self.verify(self.signed, base64.b64encode(bytes(32)).decode()), 0)

    def test_unsigned_feed_is_rejected(self):
        self.assertNotEqual(self.verify(self.source.read_bytes()), 0)

    def test_trailing_unsigned_content_is_rejected(self):
        self.assertNotEqual(self.verify(self.signed + b"<rss/>"), 0)

    def test_duplicate_signature_blocks_are_rejected(self):
        block = self.signed[self.signed.index(b"<!-- sparkle-signatures:"):]
        self.assertNotEqual(self.verify(self.signed + block), 0)

    def test_invalid_length_is_rejected(self):
        expected = str(len(self.source.read_bytes())).encode()
        self.assertNotEqual(self.verify(self.signed.replace(b"length: " + expected, b"length: 1")), 0)

    def test_archive_authentication_accepts_valid_bytes_and_rejects_changed_bytes(self):
        original = self.directory / "archive.zip"
        command = [str(self.archive_verifier), str(original), str(self.directory / "signed.xml"), "1.0.2", self.key]
        self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
        damaged = self.directory / "damaged.zip"
        damaged.write_bytes(original.read_bytes().replace(b"Quartz", b"quartz"))
        command[1] = str(damaged)
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def test_archive_authentication_rejects_an_untrusted_signer(self):
        command = [str(self.archive_verifier), str(self.directory / "archive.zip"),
                   str(self.directory / "signed.xml"), "1.0.2", base64.b64encode(bytes(32)).decode()]
        self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)

    def wait_with_downloads(self, succeed):
        shim = self.directory / "bin"
        shim.mkdir(exist_ok=True)
        curl = shim / "curl"
        curl.write_text('''#!/usr/bin/env python3
import os, pathlib, sys
counter = pathlib.Path(os.environ['FEED_TEST_COUNTER'])
attempt = int(counter.read_text()) + 1 if counter.exists() else 1
counter.write_text(str(attempt))
destination = pathlib.Path(sys.argv[sys.argv.index('--output') + 1])
if os.environ['FEED_TEST_SUCCEED'] == '1' and attempt > 1:
    destination.write_bytes(pathlib.Path(os.environ['FEED_TEST_SIGNED']).read_bytes())
else:
    destination.write_bytes(b'partial or unsigned response')
''')
        curl.chmod(0o755)
        counter = self.directory / "attempts"
        counter.unlink(missing_ok=True)
        output = self.directory / "downloaded.xml"
        output.unlink(missing_ok=True)
        environment = {**os.environ, "PATH": str(shim) + os.pathsep + os.environ["PATH"],
                       "CHANNEL_FEED_ATTEMPTS": "2", "CHANNEL_FEED_RETRY_DELAY": "0",
                       "FEED_TEST_COUNTER": str(counter), "FEED_TEST_SUCCEED": "1" if succeed else "0",
                       "FEED_TEST_SIGNED": str(self.directory / "signed.xml")}
        result = subprocess.run([str(ROOT / "Scripts/wait-for-channel-feed.sh"),
                                 str(self.directory / "signed.xml"), str(output), "1.0.2", self.key,
                                 feed.FEED_URL], env=environment, capture_output=True)
        return result, counter, output

    def test_feed_propagation_retries_unsigned_response_before_acceptance(self):
        result, counter, output = self.wait_with_downloads(True)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(counter.read_text(), "2")
        self.assertEqual(output.read_bytes(), self.signed)

    def test_feed_propagation_failure_does_not_leave_success_output(self):
        result, counter, output = self.wait_with_downloads(False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(counter.read_text(), "2")
        self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
