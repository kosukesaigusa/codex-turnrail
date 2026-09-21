"""Verify immutable tagging and main-ref dispatch against a local Git remote."""

import io
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import release_tag


class MainCITests(unittest.TestCase):
    def test_explicit_main_ci_after_a_bot_merge_satisfies_the_release_gate(self):
        with patch.object(
            release_tag,
            "github",
            return_value={
                "workflow_runs": [
                    {
                        "event": "workflow_dispatch",
                        "status": "completed",
                        "conclusion": "success",
                    }
                ]
            },
        ):
            release_tag.require_ci("fixture/product", "a" * 40)

    def test_latest_failed_or_pending_main_run_cannot_use_older_success(self):
        for status, conclusion in (("completed", "failure"), ("in_progress", None)):
            with (
                patch.object(
                    release_tag,
                    "github",
                    return_value={
                        "workflow_runs": [
                            {
                                "event": "workflow_dispatch",
                                "status": status,
                                "conclusion": conclusion,
                            },
                            {
                                "event": "push",
                                "status": "completed",
                                "conclusion": "success",
                            },
                        ]
                    },
                ),
                self.assertRaises(ValueError),
            ):
                release_tag.require_ci("fixture/product", "a" * 40)

    def test_pr_ci_is_not_evidence_for_a_main_release(self):
        with (
            patch.object(
                release_tag,
                "github",
                return_value={
                    "workflow_runs": [
                        {
                            "event": "pull_request",
                            "status": "completed",
                            "conclusion": "success",
                        }
                    ]
                },
            ),
            self.assertRaises(ValueError),
        ):
            release_tag.require_ci("fixture/product", "a" * 40)


class ReleaseTagTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        temporary = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.repo = temporary / "product"
        self.origin = temporary / "origin.git"
        self.repo.mkdir()
        self.real_run = subprocess.run
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "Release Tests")
        self.git("config", "user.email", "release@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "tag.gpgsign", "false")
        (self.repo / "source.txt").write_text("fixture\n")
        self.git("add", "source.txt")
        self.git("commit", "-m", "fixture")
        self.git("init", "--bare", str(self.origin))
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "origin", "main")
        self.commit = self.git("rev-parse", "HEAD")
        self.stack.enter_context(patch.object(release_tag, "ROOT", self.repo))
        self.stack.enter_context(
            patch.object(release_tag, "validate", return_value={"version": "0.2.0"})
        )
        self.ci = self.stack.enter_context(patch.object(release_tag, "require_ci"))
        self.dispatched = []
        self.fail_dispatch = False

        def run(command, **kwargs):
            if command[0] == "gh":
                remote = self.git("ls-remote", "origin", "refs/tags/v0.2.0^{}")
                self.assertEqual(remote.split()[0], self.commit)
                self.dispatched.append(command)
                if self.fail_dispatch:
                    raise subprocess.CalledProcessError(1, command)
                return subprocess.CompletedProcess(command, 0)
            return self.real_run(command, **kwargs)

        self.stack.enter_context(patch.object(release_tag.subprocess, "run", run))
        self.stack.enter_context(redirect_stdout(io.StringIO()))
        self.stack.enter_context(redirect_stderr(io.StringIO()))

    def git(self, *arguments):
        return self.real_run(
            ["git", "-C", str(self.repo), *arguments],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def invoke(self, *arguments):
        with patch.object(
            sys,
            "argv",
            ["release_tag.py", "--repository", "fixture/product", *arguments],
        ):
            return release_tag.main()

    def test_verified_tag_is_pushed_before_main_workflow_dispatch(self):
        self.assertEqual(self.invoke(), 0)
        self.ci.assert_called_once_with("fixture/product", self.commit)
        remote = self.git("ls-remote", "origin", "refs/tags/v0.2.0^{}")
        self.assertEqual(remote.split()[0], self.commit)
        self.assertEqual(
            self.dispatched,
            [
                [
                    "gh",
                    "workflow",
                    "run",
                    "release.yml",
                    "--repo",
                    "fixture/product",
                    "--ref",
                    "main",
                    "--field",
                    "tag=v0.2.0",
                ]
            ],
        )

    def test_dry_run_neither_creates_tags_nor_dispatches(self):
        self.assertEqual(self.invoke("--dry-run"), 0)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertEqual(self.git("ls-remote", "origin", "refs/tags/v0.2.0"), "")
        self.assertEqual(self.dispatched, [])

    def test_failed_ci_cannot_tag_or_dispatch(self):
        self.ci.side_effect = ValueError("CI failed")
        self.assertEqual(self.invoke(), 1)
        self.assertEqual(self.git("tag", "--list"), "")
        self.assertEqual(self.dispatched, [])

    def test_dispatch_failure_preserves_the_pushed_immutable_tag(self):
        self.fail_dispatch = True
        self.assertEqual(self.invoke(), 1)
        remote = self.git("ls-remote", "origin", "refs/tags/v0.2.0^{}")
        self.assertEqual(remote.split()[0], self.commit)
        self.dispatched.clear()
        self.assertEqual(self.invoke(), 1)
        self.assertEqual(self.dispatched, [])
        self.assertEqual(self.git("ls-remote", "origin", "refs/tags/v0.2.0^{}"), remote)


if __name__ == "__main__":
    unittest.main()
