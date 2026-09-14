#!/usr/bin/env python3
"""Exercise exact release labeling and lossless stable/beta feed retention.

These are metadata fixtures. test-update-packaging.sh separately exercises real
Sparkle signing, signed-feed verification, and complete app archives.
"""

import copy
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("release_appcast", Path(__file__).with_name("release-appcast.py"))
appcasts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(appcasts)
NS = appcasts.SPARKLE


def item(label, legacy=False):
    metadata = appcasts.versions.release_version(label)
    result = ET.Element("item")
    ET.SubElement(result, "title").text = metadata["base_version"]
    ET.SubElement(result, f"{{{NS}}}version").text = label if legacy else metadata["build_version"]
    ET.SubElement(result, f"{{{NS}}}shortVersionString").text = metadata["base_version"]
    if metadata["channel"] == "beta":
        ET.SubElement(result, f"{{{NS}}}channel").text = "beta"
    ET.SubElement(result, "enclosure", {"url": f"https://example.invalid/{label}.zip",
        "length": "1234", f"{{{NS}}}edSignature": "existing archive signature"})
    return result


class ReleaseAppcastTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="quartz-appcast-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.feed = self.directory / "appcast.xml"
        self.prior = self.directory / "prior.xml"
        self.label = "1.1.0-beta.2"
        self.old_items = [item("1.0.1", legacy=True), item("1.1.0-beta.1")]
        self.new_item = item(self.label)
        self.write(self.prior, self.old_items)
        self.write(self.feed, [self.new_item, *self.old_items])

    def write(self, path, items):
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Quartz updates"
        for entry in items:
            channel.append(copy.deepcopy(entry))
        ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)

    def finalize(self):
        appcasts.finalize(self.feed, self.label, f"https://example.invalid/{self.label}.zip", self.prior)

    def rejected(self):
        before = self.feed.read_bytes()
        with self.assertRaises(ValueError):
            self.finalize()
        self.assertEqual(self.feed.read_bytes(), before)

    def test_beta_display_label_changes_only_exact_new_item(self):
        self.finalize()
        entries = appcasts.feed_items(ET.parse(self.feed).getroot())
        current = entries["102.0.2"]
        self.assertEqual(current.findtext("title"), self.label)
        self.assertEqual(current.findtext(f"{{{NS}}}shortVersionString"), self.label)
        self.assertEqual(current.findtext(f"{{{NS}}}channel"), "beta")
        for build, old in appcasts.feed_items(ET.parse(self.prior).getroot()).items():
            self.assertEqual(appcasts.canonical(old), appcasts.canonical(entries[build]))

    def test_stable_publication_preserves_newer_beta_and_legacy_stable(self):
        self.label = "1.0.2"
        self.new_item = item(self.label)
        self.write(self.feed, [self.old_items[1], self.new_item, self.old_items[0]])
        self.finalize()
        entries = appcasts.feed_items(ET.parse(self.feed).getroot())
        self.assertEqual(set(entries), {"102.0.1", "101.2.99", "1.0.1"})
        self.assertIsNone(entries["101.2.99"].find(f"{{{NS}}}channel"))
        self.assertEqual(entries["102.0.1"].findtext(f"{{{NS}}}channel"), "beta")

    def test_beta_then_beta_then_same_line_stable_retains_history(self):
        self.finalize()
        self.prior.write_bytes(self.feed.read_bytes())
        entries = list(appcasts.feed_items(ET.parse(self.prior).getroot()).values())
        self.label = "1.1.0"
        self.write(self.feed, [item(self.label), *entries])
        self.finalize()
        entries = appcasts.feed_items(ET.parse(self.feed).getroot())
        self.assertEqual(set(entries), {"1.0.1", "102.0.1", "102.0.2", "102.0.99"})
        stable = [build for build, entry in entries.items() if entry.find(f"{{{NS}}}channel") is None]
        self.assertEqual(set(stable), {"1.0.1", "102.0.99"})

    def test_channel_mismatch_and_duplicate_channels_rejected(self):
        for channel in [None, "stable", "nightly"]:
            with self.subTest(channel=channel):
                changed = copy.deepcopy(self.new_item)
                changed.remove(changed.find(f"{{{NS}}}channel"))
                if channel:
                    ET.SubElement(changed, f"{{{NS}}}channel").text = channel
                self.write(self.feed, [changed, *self.old_items])
                self.rejected()
        ET.SubElement(self.new_item, f"{{{NS}}}channel").text = "beta"
        self.write(self.feed, [self.new_item, *self.old_items])
        self.rejected()

    def test_stable_requires_default_channel(self):
        self.label = "1.1.0"
        changed = item(self.label)
        ET.SubElement(changed, f"{{{NS}}}channel").text = "stable"
        self.write(self.feed, [changed, *self.old_items])
        self.rejected()

    def test_missing_duplicate_or_conflicting_current_build_rejected(self):
        for items in [self.old_items, [self.new_item, self.new_item, *self.old_items]]:
            self.write(self.feed, items)
            self.rejected()
        self.new_item.find("enclosure").set(f"{{{NS}}}version", "999.9.9")
        self.write(self.feed, [self.new_item, *self.old_items])
        self.rejected()

    def test_changed_download_or_ambiguous_display_metadata_rejected(self):
        for name in ["enclosure", "title", f"{{{NS}}}shortVersionString"]:
            with self.subTest(name=name):
                changed = copy.deepcopy(self.new_item)
                changed.append(copy.deepcopy(changed.find(name)))
                self.write(self.feed, [changed, *self.old_items])
                self.rejected()
        self.new_item.find("enclosure").set("url", "https://example.invalid/wrong.zip")
        self.write(self.feed, [self.new_item, *self.old_items])
        self.rejected()

    def test_dropped_or_modified_history_rejected(self):
        self.write(self.feed, [self.new_item, self.old_items[0]])
        self.rejected()
        for mutate in [lambda old: old.find("enclosure").set("length", "999"),
                       lambda old: old.find("enclosure").set(f"{{{NS}}}edSignature", "replacement"),
                       lambda old: setattr(old.find(f"{{{NS}}}channel"), "text", "nightly")]:
            changed = copy.deepcopy(self.old_items[1])
            mutate(changed)
            self.write(self.feed, [self.new_item, self.old_items[0], changed])
            self.rejected()

    def test_already_published_build_cannot_be_regenerated(self):
        self.prior.write_bytes(self.feed.read_bytes())
        self.rejected()


if __name__ == "__main__":
    unittest.main(verbosity=2)
