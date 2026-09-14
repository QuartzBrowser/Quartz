#!/usr/bin/env python3
"""Check publication boundaries in the real GitHub Actions workflows.

Install Scripts/requirements-workflow-tests.txt before running this script.
Conditions are exercised as event/input scenarios. The release input validator is
executed directly from its workflow, so its rejection behavior is also covered.
"""

import ast
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml


ROOT = Path(__file__).resolve().parent.parent
REVISION = "a" * 40


def condition(expression, context):
    """Evaluate the small, side-effect-free Actions condition subset used here."""
    if expression is None:
        return True
    expression = str(expression).strip()
    if expression.startswith("${{") and expression.endswith("}}"):
        expression = expression[3:-2].strip()
    expression = expression.replace("&&", " and ").replace("||", " or ")
    expression = re.sub(r"!(?!=)", " not ", expression).strip()

    def evaluate(node):
        if isinstance(node, ast.Constant):
            return node.value
        if isinstance(node, ast.Name):
            if node.id in ("true", "false"):
                return node.id == "true"
            return context.get(node.id, "")
        if isinstance(node, ast.Attribute):
            owner = evaluate(node.value)
            return owner.get(node.attr, "") if isinstance(owner, dict) else ""
        if isinstance(node, ast.BoolOp):
            values = [bool(evaluate(value)) for value in node.values]
            return all(values) if isinstance(node.op, ast.And) else any(values)
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.Not):
            return not evaluate(node.operand)
        if isinstance(node, ast.Compare):
            left = evaluate(node.left)
            for operator, right_node in zip(node.ops, node.comparators):
                right = evaluate(right_node)
                if isinstance(operator, ast.Eq):
                    matched = left == right
                elif isinstance(operator, ast.NotEq):
                    matched = left != right
                else:
                    raise AssertionError(f"Unsupported comparison: {expression}")
                if not matched:
                    return False
                left = right
            return True
        raise AssertionError(f"Unsupported workflow condition: {expression}")

    return bool(evaluate(ast.parse(expression, mode="eval").body))


def request(event="workflow_dispatch", ref="refs/heads/main", engine="", verify="", activate=""):
    return {
        "github": {"event_name": event, "ref": ref, "sha": REVISION},
        "inputs": {"engine_revision": engine, "verify_version": verify, "activate_version": activate},
    }


def steps(workflow):
    for job in workflow["jobs"].values():
        yield from job.get("steps", [])


def step_with_id(workflow, identifier):
    matching = [step for step in steps(workflow) if step.get("id") == identifier]
    if len(matching) != 1:
        raise AssertionError(f"Expected exactly one workflow step with id {identifier}")
    return matching[0]


class WorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflows = {}
        for name in ("build", "release"):
            path = ROOT / ".github" / "workflows" / f"{name}.yml"
            # BaseLoader preserves GitHub's `on` key instead of YAML 1.1's bool.
            cls.workflows[name] = yaml.load(path.read_text(), Loader=yaml.BaseLoader)
        cls.build = cls.workflows["build"]
        cls.release = cls.workflows["release"]

    def test_publication_has_only_an_explicit_manual_entrypoint(self):
        self.assertEqual(set(self.release["on"]), {"workflow_dispatch"})
        inputs = self.release["on"]["workflow_dispatch"]["inputs"]
        for name in ("engine_revision", "verify_version", "activate_version"):
            self.assertEqual(inputs[name]["type"], "string")
            self.assertEqual(inputs[name].get("default", ""), "")
            self.assertEqual(inputs[name].get("required", "false"), "false")

    def test_normal_development_keeps_automatic_read_only_ci(self):
        self.assertEqual(set(self.build["on"]), {"push", "pull_request", "workflow_dispatch"})
        self.assertEqual(set(self.build["on"]["push"]["branches"]), {"main", "beta"})
        self.assertEqual(self.build["permissions"], {"contents": "read"})
        for job in self.build["jobs"].values():
            self.assertNotIn("write", job.get("permissions", {}).values())
        for step in steps(self.build):
            action = step.get("uses", "").lower()
            self.assertNotIn("semantic-release", action)
            self.assertNotRegex(action, r"(?:action-gh-release|release-action)@")
            self.assertNotRegex(step.get("run", ""), r"\b(?:git\s+push|gh\s+release\s+(?:create|edit|upload|delete))\b")
            self.assertNotRegex(step.get("run", ""), r"\b(?:update-webkit\.py\s+commit|prepare-release\.sh)\b")
            if action.startswith("actions/checkout@"):
                self.assertEqual(step.get("with", {}).get("persist-credentials"), "false")
        self.assertNotRegex(str(self.build), r"\$\{\{\s*secrets\.")

    def test_only_publication_and_explicit_feed_activation_receive_write_permissions(self):
        self.assertEqual(self.release["permissions"], {"contents": "read"})
        for name, job in self.release["jobs"].items():
            permissions = job.get("permissions", self.release["permissions"])
            if name in ("release", "activate-published-feed"):
                self.assertEqual(permissions.get("contents"), "write")
                if name == "activate-published-feed":
                    self.assertEqual(permissions, {"contents": "write"})
            else:
                self.assertNotIn("write", permissions.values(), name)
                for step in job.get("steps", []):
                    if step.get("uses", "").startswith("actions/checkout@"):
                        self.assertEqual(step.get("with", {}).get("persist-credentials"), "false")
        verifier = self.release["jobs"]["verify-published-release"]
        self.assertEqual(verifier.get("permissions", self.release["permissions"]), {"contents": "read"})

    def test_all_release_checkouts_use_the_requested_immutable_app_revision(self):
        checkouts = [step for step in steps(self.release) if step.get("uses", "").startswith("actions/checkout@")]
        self.assertTrue(checkouts)
        for step in checkouts:
            self.assertEqual(step.get("with", {}).get("ref", "").replace(" ", ""), "${{github.sha}}")

    def test_release_and_verification_wait_for_request_validation(self):
        jobs = self.release["jobs"]
        self.assertIn("validate-request", jobs)
        for name in ("engine-update", "verify-published-release", "activate-published-feed"):
            dependencies = jobs[name].get("needs", [])
            if isinstance(dependencies, str):
                dependencies = [dependencies]
            self.assertIn("validate-request", dependencies)
        dependencies = jobs["release"].get("needs", [])
        if isinstance(dependencies, str):
            dependencies = [dependencies]
        self.assertIn("engine-update", dependencies)

    def test_verification_cannot_enter_the_publishing_jobs(self):
        for name in ("engine-update", "release", "verify-published-release", "activate-published-feed"):
            expression = self.release["jobs"][name].get("if")
            for event in ("workflow_dispatch", "push", "pull_request", "schedule"):
                for ref in ("refs/heads/main", "refs/heads/beta", "refs/heads/feature"):
                    for verify in ("", "1.2.3"):
                        for engine in ("", REVISION):
                            for activate in ("", "1.2.3"):
                                expected = event == "workflow_dispatch" and ref in ("refs/heads/main", "refs/heads/beta")
                                if name == "verify-published-release":
                                    expected = expected and bool(verify) and not activate
                                elif name == "activate-published-feed":
                                    expected = expected and bool(activate) and not verify
                                else:
                                    expected = expected and not verify and not activate
                                with self.subTest(job=name, event=event, ref=ref, verify=verify, engine=engine, activate=activate):
                                    self.assertEqual(condition(expression, request(event, ref, engine, verify, activate)), expected)

    def test_stable_beta_and_feed_recovery_share_one_publication_queue(self):
        self.assertEqual(self.release["concurrency"]["group"], "quartz-release")
        self.assertEqual(self.release["concurrency"]["cancel-in-progress"], "false")
        for job in self.release["jobs"].values():
            self.assertNotIn("concurrency", job)

    def test_semantic_release_treats_beta_as_a_prerelease_channel(self):
        result = subprocess.run(["node", "-e", "process.stdout.write(JSON.stringify(require('./release.config.cjs').branches))"],
                                cwd=ROOT, text=True, capture_output=True, check=True, timeout=10)
        self.assertEqual(json.loads(result.stdout), ["main", {"name": "beta", "prerelease": True}])

    def test_feed_activation_requires_immutable_verification_and_then_feed_verification(self):
        for name in ("release", "activate-published-feed"):
            job_steps = self.release["jobs"][name]["steps"]
            publications = [index for index, step in enumerate(job_steps) if "Scripts/publish-update-feed.py" in step.get("run", "")]
            self.assertEqual(len(publications), 1)
            publication = publications[0]
            immutable = [index for index, step in enumerate(job_steps) if "Scripts/verify-published-update.sh" in step.get("run", "")
                         and "--feed" not in step["run"]]
            active_feed = [index for index, step in enumerate(job_steps) if "Scripts/verify-published-update.sh" in step.get("run", "")
                           and "--feed" in step["run"]]
            self.assertTrue(any(index < publication for index in immutable))
            self.assertTrue(any(index > publication for index in active_feed))
        verifier = self.release["jobs"]["verify-published-release"]
        self.assertNotIn("Scripts/publish-update-feed.py", str(verifier))
        self.assertNotIn("SPARKLE_PRIVATE_KEY", str(self.release["jobs"]["activate-published-feed"]))

    def test_candidate_builds_require_an_explicit_manual_input(self):
        candidate = step_with_id(self.build, "stage-engine-candidate")
        for event in ("workflow_dispatch", "push", "pull_request", "pull_request_target"):
            for engine in ("", REVISION):
                with self.subTest(event=event, engine=engine):
                    self.assertEqual(condition(candidate.get("if"), request(event=event, engine=engine)),
                                     event == "workflow_dispatch" and bool(engine))

    def test_development_artifacts_require_an_explicit_manual_candidate(self):
        uploads = [step for step in steps(self.build) if step.get("uses", "").startswith("actions/upload-artifact@")]
        self.assertTrue(uploads)
        for upload in uploads:
            # A rerun retains its run ID. Replacing this development artifact
            # avoids failing after a full build because its name already exists.
            self.assertEqual(upload.get("with", {}).get("overwrite"), "true")
            for event in ("workflow_dispatch", "push", "pull_request"):
                for engine in ("", REVISION):
                    with self.subTest(event=event, engine=engine):
                        self.assertEqual(condition(upload.get("if"), request(event=event, engine=engine)),
                                         event == "workflow_dispatch" and bool(engine))

    def test_user_inputs_are_passed_as_data_to_shell_steps(self):
        for name, workflow in self.workflows.items():
            for step in steps(workflow):
                with self.subTest(workflow=name, step=step.get("name", step.get("id"))):
                    self.assertNotRegex(step.get("run", ""), r"\$\{\{[^}]*\binputs\.")

    def test_release_request_validator_accepts_only_unambiguous_valid_requests(self):
        validator = step_with_id(self.release, "validate-inputs")
        script = validator["run"]
        cases = [
            ("main", "", "", "", True),
            ("main", REVISION, "", "", True),
            ("main", "", "1.2.3", "", True),
            ("main", "", "", "1.2.3", True),
            ("beta", "", "", "", True),
            ("beta", REVISION, "", "", True),
            ("beta", "", "1.2.3-beta.1", "", True),
            ("beta", "", "", "1.2.3-beta.98", True),
            ("main", REVISION, "1.2.3", "", False),
            ("main", REVISION, "", "1.2.3", False),
            ("main", "", "1.2.3", "1.2.3", False),
            ("main", REVISION, "1.2.3", "1.2.3", False),
            ("feature", "", "", "", False),
            ("main", "main", "", "", False),
            ("main", REVISION[:12], "", "", False),
            ("main", "g" * 40, "", "", False),
            ("main", REVISION.upper(), "", "", False),
            ("main", "", "v1.2.3", "", False),
            ("main", "", "1.2", "", False),
            ("main", "", "1.2.3\n4.5.6", "", False),
            ("main", "", "1.2.3-beta.1", "", False),
            ("main", "", "", "1.2.3-beta.1", False),
            ("beta", "", "1.2.3", "", False),
            ("beta", "", "", "1.2.3", False),
            ("beta", "", "1.2.3-beta.0", "", False),
            ("beta", "", "", "1.2.3-beta.99", False),
        ]
        with tempfile.TemporaryDirectory(prefix="quartz-workflow-inputs-") as directory:
            scripts = Path(directory) / "Scripts"
            scripts.mkdir()
            (scripts / "release-version.py").write_bytes((ROOT / "Scripts" / "release-version.py").read_bytes())
            for branch, engine, verify, activate, accepted in cases:
                environment = {
                    "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
                    "GITHUB_EVENT_NAME": "workflow_dispatch",
                    "GITHUB_REF": f"refs/heads/{branch}",
                    "GITHUB_OUTPUT": str(Path(directory) / "outputs"),
                    "QUARTZ_ENGINE_REVISION": engine,
                    "QUARTZ_VERIFY_VERSION": verify,
                    "QUARTZ_ACTIVATE_VERSION": activate,
                }
                with self.subTest(branch=branch, engine=engine, verify=verify, activate=activate):
                    result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                                            cwd=directory, env=environment, text=True, capture_output=True, timeout=10)
                    self.assertEqual(result.returncode == 0, accepted, result.stdout + result.stderr)

            for event in ("push", "pull_request", "schedule"):
                environment.update({
                    "GITHUB_EVENT_NAME": event,
                    "GITHUB_REF": "refs/heads/main",
                    "QUARTZ_ENGINE_REVISION": "",
                    "QUARTZ_VERIFY_VERSION": "",
                    "QUARTZ_ACTIVATE_VERSION": "",
                })
                with self.subTest(event=event):
                    result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", script],
                                            cwd=directory, env=environment, text=True, capture_output=True, timeout=10)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)


class DocumentedPromotionTests(unittest.TestCase):
    """Run the copyable promotion procedure against disposable Git histories."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="quartz-doc-promotion-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.repository = self.directory / "checkout"
        self.origin = self.directory / "origin.git"
        self.environment = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
        }
        self.git(self.directory, "init", "--bare", "-q", "-b", "main", str(self.origin))
        self.git(self.directory, "init", "-q", "-b", "main", str(self.repository))
        for key, value in (
            ("user.name", "Promotion Fixture"),
            ("user.email", "fixture@example.invalid"),
            ("commit.gpgsign", "false"),
            ("tag.gpgsign", "false"),
            ("core.hooksPath", os.devnull),
        ):
            self.git(self.repository, "config", key, value)
        self.initial = self.commit_file("base.txt", "Initial shared engine\n")
        self.git(self.repository, "remote", "add", "origin", str(self.origin))
        self.git(self.repository, "push", "-q", "-u", "origin", "main")
        self.git(self.repository, "switch", "-qc", "quartz-dev")
        self.candidate = self.commit_file("feature.txt", "Tested engine customization\n")
        self.git(self.repository, "push", "-q", "-u", "origin", "quartz-dev")

    def git(self, repository, *arguments):
        result = subprocess.run(["git", "-C", str(repository), *arguments],
                                env=self.environment, text=True, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def commit_file(self, filename, contents):
        (self.repository / filename).write_text(contents)
        self.git(self.repository, "add", "--", filename)
        self.git(self.repository, "commit", "-qm", f"Fixture change: {filename}")
        return self.git(self.repository, "rev-parse", "HEAD")

    def promote(self, tested_revision):
        document = (ROOT / "docs" / "WEBKIT_MAINTENANCE.md").read_text()
        section = document.split("## Promote a tested engine batch\n", 1)[1].split("\n## ", 1)[0]
        match = re.search(r"```sh\n(.*?)\n```", section, re.DOTALL)
        self.assertIsNotNone(match, "Missing copyable engine promotion procedure")
        script = match.group(1)
        self.assertEqual(script.count("PASTE_THE_FULL_LOWERCASE_TESTED_SHA"), 1)
        script = script.replace("PASTE_THE_FULL_LOWERCASE_TESTED_SHA", tested_revision)
        # Deliberately do not add -e: the pasted procedure must enforce its own
        # abort behavior in a normal interactive shell.
        return subprocess.run(["bash", "--noprofile", "--norc", "-c", script],
                              cwd=self.repository, env=self.environment,
                              text=True, capture_output=True, timeout=20)

    def test_exact_tested_candidate_promotes_without_changing_its_sha(self):
        result = self.promote(self.candidate)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), self.candidate)
        self.assertEqual(self.git(self.repository, "rev-parse", "HEAD"), self.candidate)

    def test_development_advancing_past_the_tested_sha_cannot_be_promoted(self):
        self.commit_file("untested.txt", "Work added after candidate validation\n")
        self.git(self.repository, "push", "-q", "origin", "quartz-dev")
        result = self.promote(self.candidate)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), self.initial)

    def test_diverged_main_cannot_be_replaced_by_a_tested_development_tip(self):
        self.git(self.repository, "switch", "-q", "main")
        hotfix = self.commit_file("hotfix.txt", "Separately promoted engine hotfix\n")
        self.git(self.repository, "push", "-q", "origin", "main")
        self.git(self.repository, "switch", "-q", "quartz-dev")
        result = self.promote(self.candidate)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"), hotfix)


if __name__ == "__main__":
    unittest.main()
