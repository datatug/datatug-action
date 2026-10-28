"""Exercise release decisions against real, isolated Git histories."""

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("tag_plan", Path(__file__).with_name("plan-action-tag.py"))
tag_plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tag_plan)


class TagPlanTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        previous = os.getcwd()
        os.chdir(self.tmp.name)
        self.addCleanup(os.chdir, previous)
        self.git("init", "-q", "--initial-branch=main")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "user.name", "Release fixture")
        self.base = self.commit("action.yml", "initial action", "feat: validator")
        self.git("tag", "v0.0.1")

    def git(self, *args):
        return subprocess.check_output(["git", *args], text=True, stderr=subprocess.PIPE).strip()

    def commit(self, path, value, subject):
        file = Path(path)
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(value)
        self.git("add", "--", path)
        self.git("commit", "-qm", subject)
        return self.git("rev-parse", "HEAD")

    def test_initial_tag_requires_reviewed_bootstrap(self):
        self.git("tag", "-d", "v0.0.1")
        self.assertIsNone(tag_plan.plan(self.base)["tag"])

    def test_docs_tests_and_internal_helpers_do_not_tag(self):
        for path in ("README.md", "docs/guide.md", "renovate.json",
                     ".github/workflows/test.yml", "scripts/test-datatug-cli.sh",
                     "scripts/plan-action-tag.py"):
            with self.subTest(path=path):
                sha = self.commit(path, "maintenance", "feat: maintenance only")
                self.assertIsNone(tag_plan.plan(sha)["tag"])

    def test_runtime_fix_increments_patch(self):
        sha = self.commit("scripts/datatug-cli.sh", "fixed runtime", "fix: validate paths")
        self.assertEqual(tag_plan.plan(sha)["tag"], "v0.0.2")

    def test_metadata_feature_increments_minor(self):
        sha = self.commit("action.yml", "new input", "feat(action): add input")
        self.assertEqual(tag_plan.plan(sha)["tag"], "v0.1.0")

    def test_docs_feature_does_not_change_runtime_patch_increment(self):
        self.commit("README.md", "feature prose", "feat: docs feature")
        sha = self.commit("action.yml", "fixed", "fix: runtime")
        self.assertEqual(tag_plan.plan(sha)["tag"], "v0.0.2")

    def test_reverted_runtime_change_does_not_tag(self):
        self.commit("action.yml", "temporary", "fix: temporary")
        sha = self.commit("action.yml", "initial action", "revert: temporary")
        self.assertIsNone(tag_plan.plan(sha)["tag"])

    def test_repeated_run_does_not_tag(self):
        self.assertIsNone(tag_plan.plan(self.base)["tag"])

    def test_old_ci_completion_cannot_tag_backwards(self):
        earlier = self.commit("action.yml", "older", "fix: older")
        self.commit("action.yml", "newer", "fix: newer")
        self.git("tag", "v0.0.2")
        self.assertEqual(tag_plan.plan(earlier)["reason"], "stale or divergent candidate")

    def test_latest_version_is_numeric_and_can_be_annotated(self):
        self.git("tag", "-a", "v0.0.9", "-m", "fixture")
        self.git("tag", "v0.0.10")
        sha = self.commit("action.yml", "fix", "fix: behavior")
        self.assertEqual(tag_plan.plan(sha)["tag"], "v0.0.11")

    def test_unqualified_major_alias_is_not_a_release(self):
        self.git("tag", "v1")
        sha = self.commit("action.yml", "fix", "fix: behavior")
        self.assertEqual(tag_plan.plan(sha)["tag"], "v0.0.2")

    def test_breaking_change_requires_explicit_release(self):
        for message in ("feat!: remove input", "fix(action)!: remove output",
                        "fix: output\n\nBREAKING CHANGE: changed format"):
            with self.subTest(message=message):
                sha = self.commit("action.yml", message, message)
                with self.assertRaisesRegex(ValueError, "explicit release decision"):
                    tag_plan.plan(sha)

    def merge_runtime(self, message):
        self.git("checkout", "-qb", "feature")
        self.commit("action.yml", "changed runtime", "refactor: adjust action interface")
        self.git("checkout", "-q", "main")
        self.commit("README.md", "documentation", "docs: explain the action")
        self.git("merge", "--no-ff", "feature", "-m", message)
        return self.git("rev-parse", "HEAD")

    def test_feature_on_runtime_merge_increments_minor(self):
        sha = self.merge_runtime("feat: add optional input")
        self.assertEqual(tag_plan.plan(sha)["tag"], "v0.1.0")

    def test_docs_merge_feature_does_not_change_runtime_patch_increment(self):
        self.commit("action.yml", "fixed runtime", "fix: runtime")
        self.git("checkout", "-qb", "docs", self.base)
        self.commit("README.md", "new copy", "feat: docs")
        self.git("checkout", "-q", "main")
        self.git("merge", "--no-ff", "docs", "-m", "feat: merge documentation")
        sha = self.git("rev-parse", "HEAD")
        self.assertEqual(tag_plan.plan(sha)["tag"], "v0.0.2")

    def test_breaking_runtime_merge_requires_explicit_release(self):
        sha = self.merge_runtime("feat!: remove supported input")
        with self.assertRaisesRegex(ValueError, "explicit release decision"):
            tag_plan.plan(sha)

    def test_breaking_footer_on_runtime_merge_requires_explicit_release(self):
        sha = self.merge_runtime("fix: adjust input\n\nBREAKING CHANGE: removed input")
        with self.assertRaisesRegex(ValueError, "explicit release decision"):
            tag_plan.plan(sha)

    def test_missing_or_invalid_candidate_refuses(self):
        with self.assertRaises(ValueError):
            tag_plan.plan("main")
        with self.assertRaises(subprocess.CalledProcessError):
            tag_plan.plan("0" * 40)


if __name__ == "__main__":
    unittest.main()
