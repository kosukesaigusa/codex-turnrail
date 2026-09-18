"""Verify published asset selection and README-only pull request delivery."""

import copy
import io
import tempfile
import unittest
from contextlib import ExitStack, redirect_stdout
from pathlib import Path
from unittest.mock import patch

import update_release_readme as readme


class ReleaseReadmeTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        temporary = Path(self.stack.enter_context(tempfile.TemporaryDirectory()))
        self.root = temporary / "product"
        self.root.mkdir()
        self.origin = temporary / "origin.git"
        self.git("init", "--initial-branch=main")
        self.git("config", "user.name", "README Tests")
        self.git("config", "user.email", "readme@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.old_url = readme.download_url("fixture/product", "v0.5.0")
        self.url = readme.download_url("fixture/product", "v0.6.0")
        self.text = f"# Product\n\n[Download]({self.old_url}).\n"
        (self.root / "README.md").write_text(self.text)
        (self.root / "app.txt").write_text("unchanged\n")
        self.git("add", ".")
        self.git("commit", "-qm", "fixture")
        self.git("init", "--bare", str(self.origin))
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "--quiet", "origin", "main")
        self.base = self.git("rev-parse", "HEAD")
        self.release = {
            "tag_name": "v0.6.0",
            "draft": False,
            "prerelease": False,
            "published_at": "2026-09-18T00:00:00Z",
            "assets": [
                {
                    "name": "Codex-Turnrail-v0.6.0-macos-arm64.zip",
                    "state": "uploaded",
                    "size": 100,
                    "digest": "sha256:" + "a" * 64,
                    "browser_download_url": self.url,
                }
            ],
        }
        self.latest = "v0.6.0"
        self.prs = []
        self.calls = []
        self.stack.enter_context(patch.object(readme, "github", self.github))
        self.stack.enter_context(redirect_stdout(io.StringIO()))

    def git(self, *args):
        return readme.git(self.root, *args)

    def github(self, endpoint, *, method="GET", payload=None):
        if method == "POST":
            self.calls.append((endpoint, payload))
            return {"html_url": "https://github.com/fixture/product/pull/1"}
        if endpoint.endswith("/releases/tags/v0.6.0"):
            return copy.deepcopy(self.release)
        if endpoint.endswith("/releases/latest"):
            return {"tag_name": self.latest}
        if "/pulls?" in endpoint:
            return self.prs
        self.fail(endpoint)

    def prepare(self):
        readme.prepare(self.root, "fixture/product", "v0.6.0")

    def test_creates_only_readme_change_then_pr_and_explicit_docs_ci(self):
        self.prepare()
        self.assertEqual(
            self.git("diff", "--name-only", self.base, "HEAD"), "README.md"
        )
        self.assertEqual(
            (self.root / "README.md").read_text(),
            self.text.replace(self.old_url, self.url),
        )
        remote = self.git("ls-remote", "origin", "refs/heads/docs/release-v0.6.0")
        self.assertEqual(remote.split()[0], self.git("rev-parse", "HEAD"))
        self.assertEqual(self.calls[0][1]["base"], "main")
        self.assertEqual(
            self.calls[1],
            (
                "repos/fixture/product/actions/workflows/ci.yml/dispatches",
                {"ref": "docs/release-v0.6.0", "inputs": {"scope": "readme"}},
            ),
        )

    def test_already_updated_readme_does_not_create_another_pr(self):
        self.prepare()
        self.calls.clear()
        self.prepare()
        self.assertEqual(self.calls, [])

    def test_existing_pr_is_preserved_and_can_resume_docs_ci(self):
        self.prs = [
            {"state": "open", "html_url": "https://github.com/fixture/product/pull/1"}
        ]
        self.prepare()
        self.assertEqual((self.root / "README.md").read_text(), self.text)
        self.assertEqual(len(self.calls), 1)
        self.assertTrue(self.calls[0][0].endswith("/dispatches"))
        self.calls.clear()
        self.prs[0]["state"] = "closed"
        self.prepare()
        self.assertEqual(self.calls, [])

    def test_nonlatest_release_does_not_change_readme(self):
        self.latest = "v0.7.0"
        self.prepare()
        self.assertEqual(self.calls, [])
        self.assertEqual((self.root / "README.md").read_text(), self.text)

    def test_draft_prerelease_and_unpublished_release_are_rejected(self):
        for field, value in (
            ("draft", True),
            ("prerelease", True),
            ("published_at", None),
        ):
            with self.subTest(field=field), patch.dict(self.release, {field: value}):
                with self.assertRaises(ValueError):
                    self.prepare()
        self.assertEqual(self.calls, [])

    def test_missing_duplicate_incomplete_or_foreign_assets_are_rejected(self):
        asset = copy.deepcopy(self.release["assets"][0])
        for assets in (
            [],
            [asset, asset],
            *[
                [{**asset, key: value}]
                for key, value in (
                    ("state", "new"),
                    ("size", 0),
                    ("digest", None),
                    ("browser_download_url", "https://example.invalid/app.zip"),
                )
            ],
        ):
            with (
                self.subTest(assets=assets),
                patch.dict(self.release, {"assets": assets}),
            ):
                with self.assertRaises(ValueError):
                    self.prepare()
        self.assertEqual(self.calls, [])

    def test_ambiguous_or_missing_link_fails_and_newer_link_is_never_downgraded(self):
        for text in ("No link", self.text + self.text):
            with self.assertRaises(ValueError):
                readme.update_text(text, "fixture/product", "v0.6.0", self.url)
        newer = self.text.replace("v0.5.0", "v0.7.0")
        self.assertEqual(
            readme.update_text(newer, "fixture/product", "v0.6.0", self.url), newer
        )

    def test_orphan_branch_is_not_overwritten(self):
        self.git("push", "--quiet", "origin", "HEAD:refs/heads/docs/release-v0.6.0")
        with self.assertRaisesRegex(ValueError, "without a PR"):
            self.prepare()
        self.assertEqual(self.calls, [])


if __name__ == "__main__":
    unittest.main()
