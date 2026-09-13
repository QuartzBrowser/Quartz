#!/usr/bin/env python3
"""Exercise engine release planning and publication against disposable Git repositories."""

import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("update_webkit", Path(__file__).with_name("update-webkit.py"))
updates = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updates)

PREVIOUS = "a" * 40
CANDIDATE = "b" * 40
OTHER = "c" * 40
LOCK_NAME = "WebKit.lock.json"
ENGINE_ENDPOINT = "/repos/QuartzBrowser/WebKit/commits/main"
RELEASE_ENDPOINT = "/repos/QuartzBrowser/Quartz/releases/latest"
ERRORS = (RuntimeError, ValueError)


def git(repository, *arguments):
    result = subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True, text=True, capture_output=True,
    )
    return result.stdout.strip()


class EngineUpdateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="quartz-engine-update-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        # Never use the developer's signing, hooks, credentials, or remotes.
        environment = patch.dict(os.environ, {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        })
        environment.start()
        self.addCleanup(environment.stop)
        self.repository = self.directory / "Quartz"
        self.origin = self.directory / "origin.git"
        self.repository.mkdir()
        git(self.repository, "init", "-q", "-b", "main")
        git(self.repository, "config", "user.name", "Fixture Developer")
        git(self.repository, "config", "user.email", "fixture@example.invalid")
        git(self.repository, "config", "commit.gpgsign", "false")
        git(self.repository, "config", "tag.gpgsign", "false")
        (self.repository / "README.md").write_text("Disposable Quartz release fixture.\n")
        git(self.repository, "add", "README.md")
        git(self.repository, "commit", "-qm", "chore: initialize fixture")
        git(self.repository, "tag", "v0.9.0")
        self.original_lock = {
            "schemaVersion": 1,
            "repository": "https://github.com/QuartzBrowser/WebKit.git",
            "revision": PREVIOUS,
            "minimumXcode": "26.2",
            "macOSDeploymentTarget": "15.4",
        }
        self.write_lock(self.original_lock)
        git(self.repository, "add", LOCK_NAME)
        git(self.repository, "commit", "-qm", "feat: bundle WebKit")
        git(self.repository, "tag", "v1.0.0")
        git(self.directory, "init", "-q", "--bare", "-b", "main", str(self.origin))
        git(self.repository, "remote", "add", "origin", str(self.origin))
        git(self.repository, "push", "-q", "-u", "origin", "main", "--tags")
        self.initial_head = self.head()
        self.responses = {
            ENGINE_ENDPOINT: {"sha": CANDIDATE},
            f"/repos/QuartzBrowser/WebKit/compare/{PREVIOUS}...{CANDIDATE}": {
                "status": "ahead", "merge_base_commit": {"sha": PREVIOUS},
            },
            RELEASE_ENDPOINT: {"tag_name": "v1.0.0", "draft": False, "prerelease": False},
        }
        self.requests = []

    def api(self, path):
        self.requests.append(path)
        if path not in self.responses:
            raise AssertionError(f"Unexpected API request: {path}")
        result = self.responses[path]
        if isinstance(result, Exception):
            raise result
        return copy.deepcopy(result)

    def head(self):
        return git(self.repository, "rev-parse", "HEAD")

    def origin_head(self):
        return git(self.origin, "rev-parse", "refs/heads/main")

    def read_lock(self):
        return json.loads((self.repository / LOCK_NAME).read_text())

    def write_lock(self, lock):
        (self.repository / LOCK_NAME).write_text(json.dumps(lock, indent=2) + "\n")

    def plan(self):
        return updates.plan_update(self.repository, self.api)

    def stage(self):
        plan = self.plan()
        updates.stage_update(self.repository, plan)
        return plan

    def pin_candidate(self):
        lock = self.read_lock()
        lock["revision"] = CANDIDATE
        self.write_lock(lock)
        git(self.repository, "add", LOCK_NAME)
        git(self.repository, "commit", "-qm", "fix(webkit): advance engine")
        git(self.repository, "push", "-q", "origin", "main")

    def test_published_current_engine_is_a_noop(self):
        self.responses[ENGINE_ENDPOINT] = {"sha": PREVIOUS}
        plan = self.plan()
        self.assertEqual(plan, {
            "quartz_revision": self.initial_head,
            "previous_revision": PREVIOUS,
            "revision": PREVIOUS,
            "published_revision": PREVIOUS,
            "release_required": False,
        })
        updates.stage_update(self.repository, plan)
        updates.commit_update(self.repository, plan)
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), self.initial_head)
        self.assertEqual(git(self.repository, "status", "--porcelain"), "")

    def test_descendant_engine_requires_a_release(self):
        plan = self.plan()
        self.assertEqual(plan["quartz_revision"], self.initial_head)
        self.assertEqual(plan["previous_revision"], PREVIOUS)
        self.assertEqual(plan["revision"], CANDIDATE)
        self.assertEqual(plan["published_revision"], PREVIOUS)
        self.assertIs(plan["release_required"], True)

    def test_already_pinned_but_unpublished_engine_still_requires_a_release(self):
        self.pin_candidate()
        plan = self.plan()
        self.assertEqual(plan["previous_revision"], CANDIDATE)
        self.assertEqual(plan["revision"], CANDIDATE)
        self.assertEqual(plan["published_revision"], PREVIOUS)
        self.assertIs(plan["release_required"], True)
        self.assertFalse(any("/compare/" in path for path in self.requests))

    def test_release_before_engine_integration_has_no_published_pin(self):
        self.responses[RELEASE_ENDPOINT]["tag_name"] = "v0.9.0"
        self.responses[ENGINE_ENDPOINT] = {"sha": PREVIOUS}
        plan = self.plan()
        self.assertEqual(plan["published_revision"], "")
        self.assertIs(plan["release_required"], True)

    def test_no_release_requires_initial_engine_publication(self):
        self.responses[RELEASE_ENDPOINT] = None
        self.responses[ENGINE_ENDPOINT] = {"sha": PREVIOUS}
        plan = self.plan()
        self.assertEqual(plan["published_revision"], "")
        self.assertIs(plan["release_required"], True)

    def test_candidate_commit_must_be_a_full_valid_sha(self):
        for value in [None, 17, "", "b" * 39, "g" * 40, "refs/heads/main", "b" * 40 + "\n"]:
            with self.subTest(value=value):
                self.responses[ENGINE_ENDPOINT] = {"sha": value}
                with self.assertRaises(ERRORS):
                    self.plan()

    def test_missing_engine_response_is_not_a_noop(self):
        self.responses[ENGINE_ENDPOINT] = None
        with self.assertRaises(ERRORS):
            self.plan()

    def test_malformed_lock_is_rejected(self):
        changes = [
            {"schemaVersion": 2},
            {"repository": "https://github.com/untrusted/WebKit.git"},
            {"revision": "main"},
        ]
        for change in changes:
            with self.subTest(change=change):
                self.write_lock(self.original_lock | change)
                git(self.repository, "add", LOCK_NAME)
                git(self.repository, "commit", "-qm", "test: record malformed engine metadata")
                with self.assertRaises(ERRORS):
                    self.plan()

    def test_rollback_and_divergence_are_rejected(self):
        endpoint = f"/repos/QuartzBrowser/WebKit/compare/{PREVIOUS}...{CANDIDATE}"
        for status in ["behind", "diverged", "identical", "unexpected"]:
            with self.subTest(status=status):
                self.responses[endpoint] = {"status": status, "merge_base_commit": {"sha": PREVIOUS}}
                with self.assertRaises(ERRORS):
                    self.plan()

    def test_ahead_comparison_must_have_the_current_pin_as_merge_base(self):
        endpoint = f"/repos/QuartzBrowser/WebKit/compare/{PREVIOUS}...{CANDIDATE}"
        for response in [
            None,
            {"status": "ahead"},
            {"status": "ahead", "merge_base_commit": {"sha": OTHER}},
        ]:
            with self.subTest(response=response):
                self.responses[endpoint] = response
                with self.assertRaises(ERRORS):
                    self.plan()

    def test_api_failure_aborts_instead_of_treating_engine_as_current(self):
        for endpoint in list(self.responses):
            with self.subTest(endpoint=endpoint):
                previous = self.responses[endpoint]
                self.responses[endpoint] = RuntimeError("Synthetic API failure")
                with self.assertRaises(ERRORS):
                    self.plan()
                self.responses[endpoint] = previous
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.read_lock(), self.original_lock)

    def test_release_tag_must_be_a_valid_stable_version(self):
        for tag in [None, "", "main", "--help", "v1.0.0:WebKit.lock.json", "v1.0.0\n", "v1.0.0-beta.1"]:
            with self.subTest(tag=tag):
                self.responses[RELEASE_ENDPOINT]["tag_name"] = tag
                with self.assertRaises(ERRORS):
                    self.plan()

    def test_unavailable_published_tag_is_not_treated_as_an_old_release(self):
        self.responses[RELEASE_ENDPOINT]["tag_name"] = "v99.0.0"
        with self.assertRaises(ERRORS):
            self.plan()

    def test_malformed_published_lock_is_not_treated_as_an_old_release(self):
        self.write_lock(self.original_lock | {"revision": "not-a-commit"})
        git(self.repository, "add", LOCK_NAME)
        git(self.repository, "commit", "-qm", "test: record malformed published metadata")
        git(self.repository, "tag", "v1.0.1")
        self.write_lock(self.original_lock)
        git(self.repository, "add", LOCK_NAME)
        git(self.repository, "commit", "-qm", "test: restore current engine metadata")
        self.responses[RELEASE_ENDPOINT]["tag_name"] = "v1.0.1"
        with self.assertRaises(ERRORS):
            self.plan()

    def test_stage_changes_only_engine_revision(self):
        self.stage()
        self.assertEqual(self.read_lock(), self.original_lock | {"revision": CANDIDATE})
        self.assertEqual(git(self.repository, "diff", "HEAD", "--name-only"), LOCK_NAME)
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), self.initial_head)

    def test_stage_rejects_changed_head(self):
        plan = self.plan()
        git(self.repository, "commit", "--allow-empty", "-qm", "chore: concurrent local work")
        with self.assertRaises(ERRORS):
            updates.stage_update(self.repository, plan)
        self.assertEqual(self.read_lock(), self.original_lock)

    def test_stage_rejects_a_changed_lock(self):
        plan = self.plan()
        self.write_lock(self.original_lock | {"revision": OTHER})
        with self.assertRaises(ERRORS):
            updates.stage_update(self.repository, plan)
        self.assertEqual(self.read_lock()["revision"], OTHER)

    def test_stage_rejects_unrelated_tracked_or_staged_changes(self):
        plan = self.plan()
        (self.repository / "README.md").write_text("Unrelated local work.\n")
        with self.assertRaises(ERRORS):
            updates.stage_update(self.repository, plan)
        git(self.repository, "add", "README.md")
        with self.assertRaises(ERRORS):
            updates.stage_update(self.repository, plan)
        self.assertEqual(self.read_lock(), self.original_lock)

    def test_commit_pushes_only_the_lock_with_scoped_automation_identity(self):
        untracked = self.repository / "personal-notes.txt"
        untracked.write_text("Unrelated untracked work.\n")
        plan = self.stage()
        result = updates.commit_update(self.repository, plan)
        self.assertEqual(result, self.head())
        self.assertNotEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), self.head())
        self.assertEqual(git(self.repository, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"), LOCK_NAME)
        self.assertRegex(git(self.repository, "log", "-1", "--format=%s"), r"^fix(?:\([^)]+\))?: .+")
        self.assertNotEqual(git(self.repository, "log", "-1", "--format=%an"), "Fixture Developer")
        self.assertEqual(git(self.repository, "config", "user.name"), "Fixture Developer")
        self.assertEqual(git(self.repository, "config", "user.email"), "fixture@example.invalid")
        self.assertEqual(untracked.read_text(), "Unrelated untracked work.\n")
        self.assertEqual(git(self.repository, "status", "--porcelain"), "?? personal-notes.txt")

    def test_commit_can_be_validated_without_pushing(self):
        plan = self.stage()
        result = updates.commit_update(self.repository, plan, push=False)
        self.assertEqual(result, self.head())
        self.assertNotEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), self.initial_head)

    def test_pending_publication_creates_a_release_retry_commit(self):
        self.pin_candidate()
        previous_head = self.head()
        plan = self.stage()
        updates.commit_update(self.repository, plan)
        self.assertNotEqual(self.head(), previous_head)
        self.assertEqual(self.origin_head(), self.head())
        self.assertEqual(git(self.repository, "diff", "HEAD^", "HEAD", "--name-only"), "")
        self.assertRegex(git(self.repository, "log", "-1", "--format=%s"), r"^fix(?:\([^)]+\))?: .+")

    def test_a_fresh_plan_after_publication_does_not_release_again(self):
        plan = self.stage()
        updates.commit_update(self.repository, plan)
        published_head = self.head()
        git(self.repository, "tag", "v1.0.1")
        self.responses[RELEASE_ENDPOINT]["tag_name"] = "v1.0.1"
        second_plan = self.plan()
        self.assertIs(second_plan["release_required"], False)
        updates.stage_update(self.repository, second_plan)
        updates.commit_update(self.repository, second_plan)
        self.assertEqual(self.head(), published_head)
        self.assertEqual(self.origin_head(), published_head)

    def test_consumed_plan_cannot_commit_twice(self):
        plan = self.stage()
        updates.commit_update(self.repository, plan)
        published_head = self.head()
        with self.assertRaises(ERRORS):
            updates.commit_update(self.repository, plan)
        self.assertEqual(self.head(), published_head)
        self.assertEqual(self.origin_head(), published_head)

    def test_concurrent_main_push_is_refused_before_creating_a_commit(self):
        plan = self.stage()
        other = self.directory / "other-clone"
        git(self.directory, "clone", "-q", str(self.origin), str(other))
        git(other, "config", "user.name", "Other Fixture")
        git(other, "config", "user.email", "other@example.invalid")
        (other / "README.md").write_text("Concurrent upstream work.\n")
        git(other, "add", "README.md")
        git(other, "-c", "commit.gpgsign=false", "commit", "-qm", "fix: concurrent upstream work")
        git(other, "push", "-q", "origin", "main")
        concurrent_head = git(other, "rev-parse", "HEAD")
        with self.assertRaises(ERRORS):
            updates.commit_update(self.repository, plan)
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), concurrent_head)

    def test_commit_rejects_local_head_changes(self):
        plan = self.stage()
        git(self.repository, "commit", "--allow-empty", "-qm", "chore: concurrent local commit")
        concurrent_head = self.head()
        with self.assertRaises(ERRORS):
            updates.commit_update(self.repository, plan)
        self.assertEqual(self.head(), concurrent_head)
        self.assertEqual(self.origin_head(), self.initial_head)

    def test_commit_rejects_unrelated_tracked_or_index_changes(self):
        plan = self.stage()
        (self.repository / "README.md").write_text("Unrelated local work.\n")
        with self.assertRaises(ERRORS):
            updates.commit_update(self.repository, plan)
        git(self.repository, "add", "README.md")
        with self.assertRaises(ERRORS):
            updates.commit_update(self.repository, plan)
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), self.initial_head)

    def test_commit_rejects_changes_to_other_lock_metadata(self):
        plan = self.stage()
        lock = self.read_lock()
        lock["minimumXcode"] = "99.0"
        self.write_lock(lock)
        with self.assertRaises(ERRORS):
            updates.commit_update(self.repository, plan)
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), self.initial_head)

    def test_commit_requires_the_planned_candidate_to_be_staged(self):
        plan = self.plan()
        with self.assertRaises(ERRORS):
            updates.commit_update(self.repository, plan)
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), self.initial_head)


if __name__ == "__main__":
    unittest.main(verbosity=2)
