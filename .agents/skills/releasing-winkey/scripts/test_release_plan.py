#!/usr/bin/env python3
"""Exercise release planning in disposable repositories, without remote side effects."""

import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
from release_plan import plan


class ReleasePlanTests(unittest.TestCase):
    def setUp(self):
        work = Path.cwd() / ".work"
        work.mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix="release-plan-test-", dir=work)
        self.addCleanup(temporary.cleanup)
        self.repo = Path(temporary.name)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Release Planner Test")
        self.git("config", "user.email", "release-test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-C", str(self.repo), *args], stderr=subprocess.PIPE
        )

    def prepare(self, version="0.3.0", build="5", tag="v0.3.0", annotated=False):
        self.write_version(version, build)
        self.git("add", "Info.plist")
        self.git("commit", "-qm", f"Release {version}")
        if tag:
            if annotated:
                self.git("tag", "-a", tag, "-m", tag)
            else:
                self.git("tag", tag)

    def write_version(self, version, build):
        (self.repo / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleShortVersionString": version, "CFBundleVersion": build,
        }))

    def test_patch_and_feature_choices(self):
        self.prepare()
        self.assertEqual(plan(self.repo, "patch")["tag"], "v0.3.1")
        self.assertEqual(plan(self.repo, "minor")["tag"], "v0.4.0")
        self.assertEqual(plan(self.repo, "patch")["build"], 6)

    def test_major_for_stable_release(self):
        self.prepare("1.4.2", "12", "v1.4.2")
        self.assertEqual(plan(self.repo, "major")["version"], "2.0.0")

    def test_prepared_version_and_build_are_preserved(self):
        self.prepare()
        self.write_version("0.4.0", "8")
        result = plan(self.repo, "minor")
        self.assertEqual((result["version"], result["build"]), ("0.4.0", 8))

    def test_tags_sort_numerically_and_support_annotated_tags(self):
        self.prepare("0.9.0", "9", "v0.9.0")
        self.prepare("0.10.0", "10", "v0.10.0", annotated=True)
        self.git("tag", "v0.11.0-rc.1")
        result = plan(self.repo, "patch")
        self.assertEqual(result["latest_tag"], "v0.10.0")
        self.assertEqual(result["version"], "0.10.1")
        self.assertEqual(result["other_tags"], ["v0.11.0-rc.1"])

    def test_build_number_exceeds_all_prior_builds(self):
        self.prepare("0.2.0", "9", "v0.2.0")
        self.prepare("0.3.0", "5", "v0.3.0")
        self.assertEqual(plan(self.repo, "patch")["build"], 10)

    def test_first_release_keeps_valid_working_version(self):
        self.prepare(tag=None)
        result = plan(self.repo, "minor")
        self.assertEqual((result["version"], result["build"]), ("0.3.0", 5))
        self.assertIsNone(result["latest_tag"])

    def test_explicit_version_and_existing_version_rejection(self):
        self.prepare()
        self.assertEqual(plan(self.repo, explicit_version="0.5.0")["tag"], "v0.5.0")
        with self.assertRaises(ValueError):
            plan(self.repo, explicit_version="0.3.0")

    def test_invalid_versions_are_rejected(self):
        self.prepare()
        for version in ("v0.4.0", "0.04.0", "0.4.0-rc.1", "0.4"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                plan(self.repo, explicit_version=version)

    def test_outdated_working_version_is_rejected(self):
        self.prepare()
        self.write_version("0.2.0", "5")
        with self.assertRaises(ValueError):
            plan(self.repo, "patch")

    def test_mismatched_tag_and_committed_version_is_rejected(self):
        self.prepare(tag="v0.4.0")
        with self.assertRaises(ValueError):
            plan(self.repo, "patch")

    def test_unrelated_release_history_is_rejected(self):
        self.prepare()
        self.git("checkout", "--orphan", "unrelated")
        self.write_version("0.4.0", "6")
        self.git("add", "Info.plist")
        self.git("commit", "-qm", "Unrelated history")
        with self.assertRaises(subprocess.CalledProcessError):
            plan(self.repo, "minor")

    def test_planning_does_not_modify_files_index_or_tags(self):
        self.prepare()
        self.write_version("0.4.0", "6")
        before = (self.git("status", "--porcelain"), self.git("show-ref"),
                  (self.repo / "Info.plist").read_bytes())
        plan(self.repo, "minor")
        after = (self.git("status", "--porcelain"), self.git("show-ref"),
                 (self.repo / "Info.plist").read_bytes())
        self.assertEqual(before, after)


if __name__ == "__main__":
    unittest.main()
