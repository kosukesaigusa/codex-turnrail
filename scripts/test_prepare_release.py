"""Exercise automatic release selection with real commits and immutable refs."""

import copy
import io
import plistlib
import subprocess
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import prepare_release


class PrepareReleaseTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        temporary = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.root = temporary / "product"
        self.origin = temporary / "origin.git"
        self.root.mkdir()
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Release Tests")
        self.git("config", "user.email", "release@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("init", "--bare", str(self.origin))
        self.git("remote", "add", "origin", str(self.origin))
        (self.root / "packaging").mkdir()
        self.before = self.commit_version("0.5.0")
        self.source = self.commit_version("0.6.0")
        self.run = {
            "repository": {"full_name": "fixture/product"},
            "head_repository": {"full_name": "fixture/product"},
            "path": ".github/workflows/ci.yml",
            "event": "push",
            "head_branch": "main",
            "status": "completed",
            "conclusion": "success",
            "head_sha": self.source,
        }
        self.calls = []
        self.fail_dispatch = False
        self.stack.enter_context(patch.object(prepare_release, "github", self.github))
        self.ci = self.stack.enter_context(patch.object(prepare_release, "require_ci"))
        self.stack.enter_context(redirect_stdout(io.StringIO()))

    def git(self, *arguments):
        return prepare_release.git(self.root, *arguments)

    def commit_version(self, version):
        (self.root / "packaging/Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleShortVersionString": version,
                }
            )
        )
        self.git("add", ".")
        self.git("commit", "-qm", version)
        self.git("push", "--quiet", "origin", "main")
        return self.git("rev-parse", "HEAD")

    def github(self, endpoint, *, method="GET", payload=None):
        if method == "GET":
            self.assertEqual(endpoint, "repos/fixture/product/actions/runs/123")
            return copy.deepcopy(self.run)
        self.calls.append((endpoint, payload))
        if endpoint.endswith("/git/refs"):
            self.git(
                "--git-dir=" + str(self.origin),
                "update-ref",
                payload["ref"],
                payload["sha"],
            )
        elif endpoint.endswith("/dispatches"):
            self.assertIn(
                self.source, self.git("ls-remote", "origin", "refs/tags/v0.6.0")
            )
            if self.fail_dispatch:
                raise subprocess.CalledProcessError(1, ["gh"])
        else:
            self.fail(endpoint)

    def prepare(self):
        prepare_release.prepare(self.root, "fixture/product", 123)

    def test_verified_version_bump_tags_exact_source_then_dispatches_from_main(self):
        self.prepare()
        self.ci.assert_called_once_with("fixture/product", self.source)
        self.assertEqual(
            self.calls,
            [
                (
                    "repos/fixture/product/git/refs",
                    {"ref": "refs/tags/v0.6.0", "sha": self.source},
                ),
                (
                    "repos/fixture/product/actions/workflows/release.yml/dispatches",
                    {
                        "ref": "main",
                        "inputs": {"tag": "v0.6.0"},
                    },
                ),
            ],
        )

    def test_duplicate_completion_does_not_dispatch_or_move_tag_again(self):
        self.prepare()
        self.calls.clear()
        self.prepare()
        self.assertEqual(self.calls, [])

    def test_readme_merge_without_version_change_does_not_release(self):
        (self.root / "README.md").write_text("Updated link.\n")
        self.git("add", ".")
        self.git("commit", "-qm", "docs")
        self.git("push", "--quiet", "origin", "main")
        self.run["head_sha"] = self.git("rev-parse", "HEAD")
        self.prepare()
        self.assertEqual(self.calls, [])
        self.ci.assert_not_called()

    def test_newer_version_on_main_supersedes_old_successful_ci(self):
        self.commit_version("0.7.0")
        self.prepare()
        self.assertEqual(self.calls, [])

    def test_same_version_docs_after_bump_do_not_change_the_release_source(self):
        (self.root / "README.md").write_text("Docs after bump.\n")
        self.git("add", ".")
        self.git("commit", "-qm", "docs")
        self.git("push", "--quiet", "origin", "main")
        self.prepare()
        self.assertEqual(self.calls[0][1]["sha"], self.source)

    def test_failure_pr_fork_and_other_workflows_cannot_create_tags(self):
        for key, value in (
            ("conclusion", "failure"),
            ("status", "in_progress"),
            ("event", "pull_request"),
            ("event", "workflow_dispatch"),
            ("head_branch", "feature"),
            ("path", ".github/workflows/other.yml"),
            ("head_repository", {"full_name": "fork/product"}),
            ("repository", {"full_name": "other/product"}),
        ):
            with self.subTest(key=key, value=value), patch.dict(self.run, {key: value}):
                with self.assertRaises(ValueError):
                    self.prepare()
        self.assertEqual(self.calls, [])

    def test_latest_ci_failure_cannot_tag_a_previously_successful_revision(self):
        self.ci.side_effect = ValueError("Latest CI failed")
        with self.assertRaises(ValueError):
            self.prepare()
        self.assertEqual(self.calls, [])

    def test_existing_tag_on_another_commit_is_an_error(self):
        self.git("tag", "v0.6.0", self.before)
        self.git("push", "--quiet", "origin", "refs/tags/v0.6.0")
        with self.assertRaisesRegex(ValueError, "another commit"):
            self.prepare()
        self.assertEqual(self.calls, [])

    def test_dispatch_failure_retains_tag_for_explicit_release_workflow_retry(self):
        self.fail_dispatch = True
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()
        self.calls.clear()
        self.prepare()
        self.assertEqual(self.calls, [])

    def test_version_downgrade_is_rejected(self):
        self.run["head_sha"] = self.commit_version("0.4.0")
        with self.assertRaisesRegex(ValueError, "must increase"):
            self.prepare()
        self.assertEqual(self.calls, [])

    def test_main_rollback_cannot_release_an_obsolete_higher_version(self):
        self.commit_version("0.5.0")
        with self.assertRaisesRegex(ValueError, "decreased"):
            self.prepare()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
