#!/usr/bin/env python3
"""Exercise deliberate engine selection and publication in disposable Git repos.

Fork commit and comparison responses are deterministic API fixtures; local file,
index, commit, remote, retry, and concurrency behavior use real Git repositories.
No test contacts GitHub or changes the developer's checkout or Git configuration.
"""

import copy
import contextlib
import importlib.util
import io
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
COMMIT_ENDPOINT = f"/repos/QuartzBrowser/WebKit/commits/{CANDIDATE}"
ANCESTRY_ENDPOINT = f"/repos/QuartzBrowser/WebKit/compare/{PREVIOUS}...{CANDIDATE}"
PROMOTION_ENDPOINT = f"/repos/QuartzBrowser/WebKit/compare/{CANDIDATE}...{OTHER}"
RELEASE_ENDPOINT = "/repos/QuartzBrowser/Quartz/releases/latest"
BETA_ENGINE_ENDPOINT = "/repos/QuartzBrowser/WebKit/commits/quartz-dev"
BETA_RELEASE_ENDPOINT = "/repos/QuartzBrowser/Quartz/releases?per_page=100&page=1"
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
            COMMIT_ENDPOINT: {"sha": CANDIDATE},
            f"/repos/QuartzBrowser/WebKit/commits/{PREVIOUS}": {"sha": PREVIOUS},
            ANCESTRY_ENDPOINT: {
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

    def origin_head(self, branch="main"):
        return git(self.origin, "rev-parse", f"refs/heads/{branch}")

    def read_lock(self):
        return json.loads((self.repository / LOCK_NAME).read_text())

    def write_lock(self, lock):
        (self.repository / LOCK_NAME).write_text(json.dumps(lock, indent=2) + "\n")

    def plan(self, revision=CANDIDATE, channel="stable"):
        return updates.plan_update(self.repository, self.api, revision=revision, channel=channel)

    def stage(self, revision=CANDIDATE, channel="stable"):
        plan = self.plan(revision=revision, channel=channel)
        updates.stage_update(self.repository, plan)
        return plan

    def snapshot(self):
        return (
            self.head(), self.origin_head(),
            (self.repository / LOCK_NAME).read_bytes(),
            git(self.repository, "status", "--porcelain"),
            git(self.repository, "diff"), git(self.repository, "diff", "--cached"),
        )

    def assert_rejected_without_changes(self, operation):
        before = self.snapshot()
        with self.assertRaises(ERRORS):
            operation()
        self.assertEqual(self.snapshot(), before)

    def pin_candidate(self, branch="main"):
        lock = self.read_lock()
        lock["revision"] = CANDIDATE
        self.write_lock(lock)
        git(self.repository, "add", LOCK_NAME)
        git(self.repository, "commit", "-qm", "fix(webkit): advance engine")
        git(self.repository, "push", "-q", "origin", branch)

    def test_published_current_engine_is_a_noop(self):
        plan = self.plan(revision=None)
        self.assertEqual(plan, {
            "channel": "stable",
            "release_branch": "main",
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

    def test_default_plan_validates_promotion_without_following_the_fork(self):
        before = self.snapshot()
        plan = self.plan(revision=None)
        self.assertEqual(plan["revision"], PREVIOUS)
        self.assertIs(plan["release_required"], False)
        self.assertEqual(self.requests, [
            f"/repos/QuartzBrowser/WebKit/commits/{PREVIOUS}", ENGINE_ENDPOINT, ANCESTRY_ENDPOINT, RELEASE_ENDPOINT,
        ])
        self.assertEqual(self.snapshot(), before)
        for branch in [None, RuntimeError("Fork unavailable")]:
            with self.subTest(branch=branch):
                self.responses[ENGINE_ENDPOINT] = branch
                self.assert_rejected_without_changes(lambda: self.plan(revision=None))

    def test_default_plan_reads_committed_pin_and_preserves_local_edits(self):
        self.write_lock(self.original_lock | {"revision": OTHER})
        before = self.snapshot()
        plan = self.plan(revision=None)
        self.assertEqual(plan["revision"], PREVIOUS)
        self.assertEqual(plan["previous_revision"], PREVIOUS)
        self.assertEqual(self.snapshot(), before)
        self.assert_rejected_without_changes(lambda: updates.stage_update(self.repository, plan))

    def test_descendant_engine_requires_a_release(self):
        plan = self.plan()
        self.assertEqual(plan["quartz_revision"], self.initial_head)
        self.assertEqual(plan["previous_revision"], PREVIOUS)
        self.assertEqual(plan["revision"], CANDIDATE)
        self.assertEqual(plan["published_revision"], PREVIOUS)
        self.assertIs(plan["release_required"], True)
        self.assertEqual(self.requests, [COMMIT_ENDPOINT, ANCESTRY_ENDPOINT, ENGINE_ENDPOINT, RELEASE_ENDPOINT])

    def test_already_pinned_but_unpublished_engine_still_requires_a_release(self):
        self.pin_candidate()
        plan = self.plan(revision=None)
        self.assertEqual(plan["previous_revision"], CANDIDATE)
        self.assertEqual(plan["revision"], CANDIDATE)
        self.assertEqual(plan["published_revision"], PREVIOUS)
        self.assertIs(plan["release_required"], True)
        self.assertEqual(self.requests, [COMMIT_ENDPOINT, ENGINE_ENDPOINT, RELEASE_ENDPOINT])

    def test_release_before_engine_integration_has_no_published_pin(self):
        self.responses[RELEASE_ENDPOINT]["tag_name"] = "v0.9.0"
        plan = self.plan(revision=None)
        self.assertEqual(plan["published_revision"], "")
        self.assertIs(plan["release_required"], True)

    def test_no_release_requires_initial_engine_publication(self):
        self.responses[RELEASE_ENDPOINT] = None
        plan = self.plan(revision=None)
        self.assertEqual(plan["published_revision"], "")
        self.assertIs(plan["release_required"], True)

    def test_candidate_commit_must_be_a_full_valid_sha(self):
        for value in [17, "", "b" * 39, "B" * 40, "g" * 40, "refs/heads/main", "b" * 40 + "\n"]:
            with self.subTest(value=value):
                self.requests.clear()
                self.assert_rejected_without_changes(lambda: self.plan(revision=value))
                self.assertEqual(self.requests, [])

    def test_missing_engine_response_is_not_a_noop(self):
        for response in [None, [], {}, {"sha": PREVIOUS}, {"sha": "b" * 39}]:
            with self.subTest(response=response):
                self.responses[COMMIT_ENDPOINT] = response
                self.assert_rejected_without_changes(self.plan)

    def test_explicit_current_pin_is_validated_and_does_not_release_again(self):
        self.responses[ENGINE_ENDPOINT] = {"sha": PREVIOUS}
        plan = self.plan(revision=PREVIOUS)
        self.assertEqual(plan["revision"], PREVIOUS)
        self.assertIs(plan["release_required"], False)
        self.assertEqual(self.requests, [
            f"/repos/QuartzBrowser/WebKit/commits/{PREVIOUS}", ENGINE_ENDPOINT, RELEASE_ENDPOINT,
        ])

    def test_explicit_selection_can_be_older_than_promoted_main(self):
        self.responses[ENGINE_ENDPOINT] = {"sha": OTHER}
        self.responses[PROMOTION_ENDPOINT] = {"status": "ahead", "merge_base_commit": {"sha": CANDIDATE}}
        plan = self.plan()
        self.assertEqual(plan["revision"], CANDIDATE)
        self.assertIn(PROMOTION_ENDPOINT, self.requests)

    def test_unpromoted_or_invalid_membership_is_rejected(self):
        self.responses[ENGINE_ENDPOINT] = {"sha": OTHER}
        for response in [
            None, [], {}, {"status": "ahead"},
            {"status": "ahead", "merge_base_commit": {"sha": PREVIOUS}},
            *({"status": status, "merge_base_commit": {"sha": CANDIDATE}}
              for status in ["behind", "diverged", "identical", "unknown"]),
        ]:
            with self.subTest(response=response):
                self.responses[PROMOTION_ENDPOINT] = response
                self.assert_rejected_without_changes(self.plan)

    def test_missing_or_malformed_promoted_branch_is_rejected(self):
        for response in [None, [], {}, {"sha": None}, {"sha": "main"}, {"sha": "B" * 40}]:
            with self.subTest(response=response):
                self.responses[ENGINE_ENDPOINT] = response
                self.assert_rejected_without_changes(self.plan)

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
                self.assert_rejected_without_changes(self.plan)
                self.assert_rejected_without_changes(lambda: self.plan(revision=None))
                self.assert_rejected_without_changes(
                    lambda: updates.candidate_update(self.repository, self.api, CANDIDATE),
                )

    def test_rollback_and_divergence_are_rejected(self):
        endpoint = f"/repos/QuartzBrowser/WebKit/compare/{PREVIOUS}...{CANDIDATE}"
        for status in ["behind", "diverged", "identical", "unexpected"]:
            with self.subTest(status=status):
                self.responses[endpoint] = {"status": status, "merge_base_commit": {"sha": PREVIOUS}}
                self.assert_rejected_without_changes(self.plan)

    def test_ahead_comparison_must_have_the_current_pin_as_merge_base(self):
        endpoint = f"/repos/QuartzBrowser/WebKit/compare/{PREVIOUS}...{CANDIDATE}"
        for response in [
            None,
            {"status": "ahead"},
            {"status": "ahead", "merge_base_commit": {"sha": OTHER}},
        ]:
            with self.subTest(response=response):
                self.responses[endpoint] = response
                self.assert_rejected_without_changes(self.plan)

    def test_api_failure_aborts_instead_of_treating_engine_as_current(self):
        self.responses[ENGINE_ENDPOINT] = {"sha": OTHER}
        self.responses[PROMOTION_ENDPOINT] = {"status": "ahead", "merge_base_commit": {"sha": CANDIDATE}}
        for endpoint in [COMMIT_ENDPOINT, ANCESTRY_ENDPOINT, ENGINE_ENDPOINT, PROMOTION_ENDPOINT, RELEASE_ENDPOINT]:
            with self.subTest(endpoint=endpoint):
                previous = self.responses[endpoint]
                self.responses[endpoint] = RuntimeError("Synthetic API failure")
                self.assert_rejected_without_changes(self.plan)
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

    def test_candidate_stages_unpromoted_commit_without_main_or_release_requests(self):
        self.responses[ENGINE_ENDPOINT] = RuntimeError("Candidate must not query main")
        self.responses[RELEASE_ENDPOINT] = RuntimeError("Candidate must not query releases")
        untracked = self.repository / "personal-notes.txt"
        untracked.write_text("Keep this untracked file.\n")
        candidate = updates.candidate_update(self.repository, self.api, CANDIDATE)
        self.assertEqual(candidate, {
            "quartz_revision": self.initial_head,
            "previous_revision": PREVIOUS,
            "revision": CANDIDATE,
        })
        self.assertEqual(self.requests, [COMMIT_ENDPOINT, ANCESTRY_ENDPOINT])
        self.assertEqual(self.read_lock(), self.original_lock | {"revision": CANDIDATE})
        self.assertEqual(git(self.repository, "diff", "--name-only"), LOCK_NAME)
        self.assertEqual(git(self.repository, "diff", "--cached", "--name-only"), "")
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head(), self.initial_head)
        self.assertEqual(untracked.read_text(), "Keep this untracked file.\n")
        # Build evidence is deliberately not a release plan.
        self.assert_rejected_without_changes(lambda: updates.commit_update(self.repository, candidate))

    def test_candidate_current_revision_validates_existence_without_rewriting_lock(self):
        original_bytes = (self.repository / LOCK_NAME).read_bytes()
        result = updates.candidate_update(self.repository, self.api, PREVIOUS)
        self.assertEqual(result["revision"], PREVIOUS)
        self.assertEqual(self.requests, [f"/repos/QuartzBrowser/WebKit/commits/{PREVIOUS}"])
        self.assertEqual((self.repository / LOCK_NAME).read_bytes(), original_bytes)
        self.assertEqual(git(self.repository, "status", "--porcelain"), "")

    def test_candidate_rejects_malformed_revisions_before_network_access(self):
        for revision in [None, 17, "", "b" * 39, "B" * 40, "g" * 40, "main", "b" * 40 + "\n"]:
            with self.subTest(revision=revision):
                self.assert_rejected_without_changes(
                    lambda: updates.candidate_update(self.repository, self.api, revision),
                )
        self.assertEqual(self.requests, [])

    def test_candidate_rejects_unavailable_or_mismatched_fork_commits(self):
        for response in [None, [], {}, {"sha": PREVIOUS}, {"sha": "b" * 39}]:
            with self.subTest(response=response):
                self.responses[COMMIT_ENDPOINT] = response
                self.requests.clear()
                self.assert_rejected_without_changes(
                    lambda: updates.candidate_update(self.repository, self.api, CANDIDATE),
                )
                self.assertEqual(self.requests, [COMMIT_ENDPOINT])

    def test_candidate_rejects_backward_divergent_and_unverifiable_ancestry(self):
        for response in [
            None, [], {}, {"status": "ahead"},
            {"status": "ahead", "merge_base_commit": {"sha": OTHER}},
            *({"status": status, "merge_base_commit": {"sha": PREVIOUS}}
              for status in ["behind", "diverged", "identical", "unknown"]),
        ]:
            with self.subTest(response=response):
                self.responses[ANCESTRY_ENDPOINT] = response
                self.assert_rejected_without_changes(
                    lambda: updates.candidate_update(self.repository, self.api, CANDIDATE),
                )

    def test_candidate_api_failures_preserve_worktree_index_and_history(self):
        for endpoint in [COMMIT_ENDPOINT, ANCESTRY_ENDPOINT]:
            with self.subTest(endpoint=endpoint):
                previous = self.responses[endpoint]
                self.responses[endpoint] = RuntimeError("Synthetic API failure")
                self.assert_rejected_without_changes(
                    lambda: updates.candidate_update(self.repository, self.api, CANDIDATE),
                )
                self.responses[endpoint] = previous

    def test_candidate_requires_clean_tracked_tree_and_index(self):
        for path in ["README.md", LOCK_NAME]:
            with self.subTest(path=path):
                original_bytes = (self.repository / path).read_bytes()
                (self.repository / path).write_text("Preserve this local work.\n")
                self.assert_rejected_without_changes(
                    lambda: updates.candidate_update(self.repository, self.api, CANDIDATE),
                )
                git(self.repository, "add", "--", path)
                self.assert_rejected_without_changes(
                    lambda: updates.candidate_update(self.repository, self.api, CANDIDATE),
                )
                git(self.repository, "restore", "--staged", "--", path)
                (self.repository / path).write_bytes(original_bytes)
        new_file = self.repository / "new-feature.txt"
        new_file.write_text("New staged work.\n")
        git(self.repository, "add", "--", new_file.name)
        self.assert_rejected_without_changes(
            lambda: updates.candidate_update(self.repository, self.api, CANDIDATE),
        )
        self.assertEqual(self.requests, [])

    def test_candidate_preserves_edits_made_during_api_validation(self):
        for staged in [False, True]:
            with self.subTest(staged=staged):
                expected = []

                def edit_during_validation(path):
                    result = self.api(path)
                    if path == ANCESTRY_ENDPOINT:
                        self.write_lock(self.original_lock | {"minimumXcode": "99.0"})
                        if staged:
                            git(self.repository, "add", LOCK_NAME)
                        expected.append(self.snapshot())
                    return result

                with self.assertRaises(ERRORS):
                    updates.candidate_update(self.repository, edit_during_validation, CANDIDATE)
                self.assertEqual(self.snapshot(), expected[0])
                git(self.repository, "restore", "--staged", "--", LOCK_NAME)
                self.write_lock(self.original_lock)

    def test_candidate_rejects_head_changes_during_api_validation(self):
        expected = []

        def commit_during_validation(path):
            result = self.api(path)
            if path == ANCESTRY_ENDPOINT:
                git(self.repository, "commit", "--allow-empty", "-qm", "chore: concurrent local work")
                expected.append(self.snapshot())
            return result

        with self.assertRaises(ERRORS):
            updates.candidate_update(self.repository, commit_during_validation, CANDIDATE)
        self.assertEqual(self.snapshot(), expected[0])

    def test_cli_candidate_emits_build_evidence_json(self):
        stdout = io.StringIO()
        with patch.object(sys, "argv", [
            "update-webkit.py", "--repository", str(self.repository), "candidate", "--revision", CANDIDATE,
        ]), patch.object(updates, "github_api", self.api), contextlib.redirect_stdout(stdout):
            updates.main()
        self.assertEqual(json.loads(stdout.getvalue()), {
            "quartz_revision": self.initial_head, "previous_revision": PREVIOUS, "revision": CANDIDATE,
        })
        self.assertEqual(self.requests, [COMMIT_ENDPOINT, ANCESTRY_ENDPOINT])
        self.assertEqual(self.read_lock(), self.original_lock | {"revision": CANDIDATE})

    def test_cli_default_plan_writes_pinned_json_and_github_outputs(self):
        output_file = self.directory / "plans" / "engine.json"
        github_output = self.directory / "github-output.txt"
        stdout = io.StringIO()
        with patch.object(sys, "argv", [
            "update-webkit.py", "--repository", str(self.repository), "plan", "--output", str(output_file),
        ]), patch.object(updates, "github_api", self.api), patch.dict(os.environ, {
            "GITHUB_OUTPUT": str(github_output),
        }), contextlib.redirect_stdout(stdout):
            updates.main()
        plan = json.loads(stdout.getvalue())
        self.assertEqual(plan["revision"], PREVIOUS)
        self.assertEqual(json.loads(output_file.read_text()), plan)
        self.assertEqual(self.requests, [
            f"/repos/QuartzBrowser/WebKit/commits/{PREVIOUS}", ENGINE_ENDPOINT, ANCESTRY_ENDPOINT, RELEASE_ENDPOINT,
        ])
        outputs = dict(line.split("=", 1) for line in github_output.read_text().splitlines())
        self.assertEqual(json.loads(outputs["plan"]), plan)
        self.assertEqual(outputs["quartz_revision"], self.initial_head)
        self.assertEqual(outputs["release_required"], "false")

    def test_cli_invalid_selection_reports_error_without_stdout_or_mutation(self):
        for command in ["plan", "candidate"]:
            with self.subTest(command=command):
                stdout, stderr = io.StringIO(), io.StringIO()
                before = self.snapshot()
                with patch.object(sys, "argv", [
                    "update-webkit.py", "--repository", str(self.repository), command, "--revision", "main",
                ]), patch.object(updates, "github_api", self.api), contextlib.redirect_stdout(stdout), \
                        contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as failure:
                    updates.main()
                self.assertEqual(failure.exception.code, 1)
                self.assertEqual(stdout.getvalue(), "")
                self.assertIn("complete lowercase Git revision", stderr.getvalue())
                self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.requests, [])

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
        plan = self.stage(revision=None)
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
        self.assert_concurrent_push_rejected(self.stage())

    def test_unchanged_engine_app_release_still_rejects_concurrent_main_push(self):
        plan = self.stage(revision=None)
        self.assertIs(plan["release_required"], False)
        self.assert_concurrent_push_rejected(plan)

    def assert_concurrent_push_rejected(self, plan):
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

    def start_beta(self):
        git(self.repository, "switch", "-qc", "beta")
        git(self.repository, "push", "-q", "-u", "origin", "beta")
        git(self.repository, "tag", "v1.1.0-beta.1")
        self.responses[BETA_ENGINE_ENDPOINT] = {"sha": CANDIDATE}
        self.responses[BETA_RELEASE_ENDPOINT] = [
            {"tag_name": "v1.1.0-beta.1", "draft": False, "prerelease": True},
        ]

    def test_beta_selects_development_commit_without_requiring_main_promotion(self):
        self.start_beta()
        self.responses[ENGINE_ENDPOINT] = RuntimeError("Beta must not ask for stable promotion")
        plan = self.plan(channel="beta")
        self.assertEqual(plan["channel"], "beta")
        self.assertEqual(plan["release_branch"], "beta")
        self.assertEqual(plan["revision"], CANDIDATE)
        self.assertEqual(plan["published_revision"], PREVIOUS)
        self.assertNotIn(ENGINE_ENDPOINT, self.requests)
        self.assertNotIn(RELEASE_ENDPOINT, self.requests)

    def test_beta_default_retains_exact_pin_even_when_development_has_advanced(self):
        self.start_beta()
        plan = self.plan(revision=None, channel="beta")
        self.assertEqual(plan["revision"], PREVIOUS)
        self.assertFalse(plan["release_required"])
        self.assertIn(BETA_ENGINE_ENDPOINT, self.requests)

    def test_beta_rejects_feature_commit_not_integrated_into_development(self):
        self.start_beta()
        self.responses[BETA_ENGINE_ENDPOINT] = {"sha": PREVIOUS}
        self.responses[f"/repos/QuartzBrowser/WebKit/compare/{CANDIDATE}...{PREVIOUS}"] = {
            "status": "behind", "merge_base_commit": {"sha": PREVIOUS},
        }
        self.assert_rejected_without_changes(lambda: self.plan(channel="beta"))

    def test_stable_default_cannot_publish_an_unpromoted_merged_beta_pin(self):
        self.pin_candidate()
        self.responses[ENGINE_ENDPOINT] = {"sha": PREVIOUS}
        self.responses[f"/repos/QuartzBrowser/WebKit/compare/{CANDIDATE}...{PREVIOUS}"] = {
            "status": "behind", "merge_base_commit": {"sha": PREVIOUS},
        }
        self.assert_rejected_without_changes(lambda: self.plan(revision=None))
        self.responses[ENGINE_ENDPOINT] = {"sha": CANDIDATE}
        self.assertEqual(self.plan(revision=None)["revision"], CANDIDATE)

    def test_beta_chooses_greatest_beta_version_and_ignores_other_channels_and_drafts(self):
        self.start_beta()
        git(self.repository, "tag", "v1.1.0-beta.2")
        self.pin_candidate(branch="beta")
        git(self.repository, "tag", "v1.1.0-beta.10")
        self.responses[BETA_RELEASE_ENDPOINT] = [
            {"tag_name": "v1.1.0-beta.2", "draft": False, "prerelease": True},
            {"tag_name": "v2.0.0", "draft": False, "prerelease": False},
            {"tag_name": "v3.0.0-beta.1", "draft": True, "prerelease": True},
            {"tag_name": "v3.0.0-alpha.1", "draft": False, "prerelease": True},
            {"tag_name": "v1.1.0-beta.10", "draft": False, "prerelease": True},
        ]
        plan = self.plan(revision=None, channel="beta")
        self.assertEqual(plan["published_revision"], CANDIDATE)
        self.assertFalse(plan["release_required"])
        self.assertNotIn(RELEASE_ENDPOINT, self.requests)

    def test_beta_finds_its_publication_beyond_a_page_of_stable_releases(self):
        self.start_beta()
        beta_release = self.responses[BETA_RELEASE_ENDPOINT]
        self.responses[BETA_RELEASE_ENDPOINT] = [self.responses[RELEASE_ENDPOINT]] * 100
        second_page = "/repos/QuartzBrowser/Quartz/releases?per_page=100&page=2"
        self.responses[second_page] = beta_release
        plan = self.plan(revision=None, channel="beta")
        self.assertEqual(plan["published_revision"], PREVIOUS)
        self.assertFalse(plan["release_required"])
        self.assertIn(second_page, self.requests)

    def test_no_beta_publication_does_not_substitute_latest_stable_state(self):
        self.start_beta()
        self.responses[BETA_RELEASE_ENDPOINT] = [self.responses[RELEASE_ENDPOINT]]
        plan = self.plan(revision=None, channel="beta")
        self.assertEqual(plan["published_revision"], "")
        self.assertTrue(plan["release_required"])
        self.assertNotIn(RELEASE_ENDPOINT, self.requests)

    def test_beta_release_query_failures_do_not_create_a_retry_plan(self):
        self.start_beta()
        for response in (None, {}, [None], RuntimeError("API unavailable")):
            with self.subTest(response=response):
                self.responses[BETA_RELEASE_ENDPOINT] = response
                self.assert_rejected_without_changes(lambda: self.plan(channel="beta"))

    def test_beta_commit_updates_only_beta_and_published_retry_becomes_a_noop(self):
        self.start_beta()
        plan = self.stage(channel="beta")
        updates.commit_update(self.repository, plan)
        self.assertEqual(self.origin_head("beta"), self.head())
        self.assertEqual(self.origin_head("main"), self.initial_head)
        git(self.repository, "tag", "v1.1.0-beta.2")
        self.responses[BETA_RELEASE_ENDPOINT].append({"tag_name": "v1.1.0-beta.2", "draft": False, "prerelease": True})
        next_plan = self.stage(revision=None, channel="beta")
        self.assertFalse(next_plan["release_required"])
        before = self.head()
        updates.commit_update(self.repository, next_plan)
        self.assertEqual(self.head(), before)
        self.assertEqual(self.origin_head("main"), self.initial_head)

    def test_beta_unpublished_pin_creates_retry_commit_only_on_beta(self):
        self.start_beta()
        self.pin_candidate(branch="beta")
        before = self.head()
        plan = self.stage(revision=None, channel="beta")
        updates.commit_update(self.repository, plan)
        self.assertNotEqual(self.head(), before)
        self.assertEqual(git(self.repository, "diff", "HEAD^", "HEAD", "--name-only"), "")
        self.assertEqual(self.origin_head("beta"), self.head())
        self.assertEqual(self.origin_head("main"), self.initial_head)

    def test_beta_commit_checks_beta_races_even_when_engine_is_unchanged(self):
        self.start_beta()
        plan = self.stage(revision=None, channel="beta")
        self.assertFalse(plan["release_required"])
        other = self.directory / "concurrent-beta"
        git(self.directory, "clone", "-q", "--branch", "beta", str(self.origin), str(other))
        git(other, "-c", "user.name=Other Fixture", "-c", "user.email=other@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fix: concurrent beta work")
        git(other, "push", "-q", "origin", "beta")
        concurrent = git(other, "rev-parse", "HEAD")
        with self.assertRaisesRegex(RuntimeError, "beta advanced"):
            updates.commit_update(self.repository, plan)
        self.assertEqual(self.head(), self.initial_head)
        self.assertEqual(self.origin_head("beta"), concurrent)
        self.assertEqual(self.origin_head("main"), self.initial_head)

    def test_beta_commit_ignores_an_independent_main_advance(self):
        self.start_beta()
        plan = self.stage(channel="beta")
        other = self.directory / "concurrent-main"
        git(self.directory, "clone", "-q", str(self.origin), str(other))
        git(other, "-c", "user.name=Other Fixture", "-c", "user.email=other@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fix: concurrent stable work")
        git(other, "push", "-q", "origin", "main")
        concurrent = git(other, "rev-parse", "HEAD")
        updates.commit_update(self.repository, plan)
        self.assertEqual(self.origin_head("beta"), self.head())
        self.assertEqual(self.origin_head("main"), concurrent)

    def test_mismatched_plan_channel_and_branch_cannot_push_to_other_channel(self):
        plan = self.stage()
        for change in ({"channel": "beta"}, {"release_branch": "beta"}, {"channel": "other"}, {"channel": []}):
            with self.subTest(change=change):
                self.assert_rejected_without_changes(lambda: updates.commit_update(self.repository, plan | change))

    def test_commit_refuses_to_push_a_plan_from_the_wrong_local_branch(self):
        plan = self.stage()
        git(self.repository, "switch", "-qc", "feature/test")
        self.assert_rejected_without_changes(lambda: updates.commit_update(self.repository, plan))


if __name__ == "__main__":
    unittest.main(verbosity=2)
