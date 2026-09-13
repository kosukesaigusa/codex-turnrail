"""Exercise upstream imports in disposable repositories with real Git merges."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import sync_upstream
import tomllib


class UpstreamTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="turnrail-upstream-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name).resolve()
        self.upstream = self.directory / "upstream"
        self.product = self.directory / "product"
        for repository in (self.upstream, self.product):
            repository.mkdir()
            self.git(repository, "init", "--initial-branch=main")
            self.git(repository, "config", "user.name", "Test Fixture")
            self.git(repository, "config", "user.email", "fixture@example.invalid")
            self.git(repository, "config", "commit.gpgsign", "false")
        self.git(self.upstream, "config", "uploadpack.allowFilter", "true")
        (self.upstream / "runtime.txt").write_text("header\n\nbody\n\nfooter\n")
        (self.upstream / "old.txt").write_text("remove in next release\n")
        (self.upstream / "binary.dat").write_bytes(b"old\x00binary\n")
        self.commit(self.upstream)
        self.git(self.upstream, "tag", "rust-v1.0.0")
        self.base = self.git(self.upstream, "rev-parse", "HEAD")
        engine = self.product / "engine"
        engine.mkdir()
        for path in self.upstream.iterdir():
            if path.name != ".git":
                shutil.copy2(path, engine / path.name)
        (engine / "runtime.txt").write_text("product header\n\nbody\n\nfooter\n")
        (engine / "custom.txt").write_text("account routing\n")
        (self.product / "README.md").write_text("# Product\n")
        (self.product / "upstream.toml").write_bytes(
            sync_upstream.metadata_bytes(str(self.upstream), "rust-v1.0.0", self.base)
        )
        self.commit(self.product)

    def git(self, root, *arguments):
        return subprocess.check_output(
            ["git", "-C", str(root), *arguments],
            env={
                **os.environ,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": os.devnull,
            },
            stderr=subprocess.PIPE,
            text=True,
        ).strip()

    def commit(self, root):
        self.git(root, "add", "--all")
        self.git(root, "commit", "--message", "Fixture revision")

    def publish_update(self, text):
        (self.upstream / "runtime.txt").write_text(text)
        (self.upstream / "old.txt").unlink()
        (self.upstream / "new.txt").write_text("upstream addition\n")
        (self.upstream / "binary.dat").write_bytes(b"new\x00binary\n")
        executable = self.upstream / "helper.sh"
        executable.write_text("#!/bin/sh\nexit 0\n")
        executable.chmod(0o755)
        self.commit(self.upstream)
        self.git(self.upstream, "tag", "rust-v2.0.0")
        return self.git(self.upstream, "rev-parse", "HEAD")

    def test_update_preserves_product_changes_and_does_not_commit(self):
        incoming = self.publish_update("header\n\nbody\n\nnew footer\n")
        head = self.git(self.product, "rev-parse", "HEAD")

        result = sync_upstream.update(self.product, "rust-v2.0.0")

        self.assertEqual(result, incoming)
        self.assertEqual(self.git(self.product, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(self.product, "diff", "--cached"), "")
        self.assertEqual(self.git(self.product, "remote"), "")
        self.assertEqual(self.git(self.product, "tag", "--list"), "")
        engine = self.product / "engine"
        self.assertEqual(
            (engine / "runtime.txt").read_text(),
            "product header\n\nbody\n\nnew footer\n",
        )
        self.assertEqual((engine / "custom.txt").read_text(), "account routing\n")
        self.assertEqual((self.product / "README.md").read_text(), "# Product\n")
        self.assertFalse((engine / "old.txt").exists())
        self.assertEqual((engine / "new.txt").read_text(), "upstream addition\n")
        self.assertEqual((engine / "binary.dat").read_bytes(), b"new\x00binary\n")
        self.assertTrue(os.access(engine / "helper.sh", os.X_OK))
        self.assertEqual(
            tomllib.loads((self.product / "upstream.toml").read_text()),
            {
                "codex": {
                    "repository": str(self.upstream),
                    "tag": "rust-v2.0.0",
                    "commit": incoming,
                }
            },
        )

    def test_conflict_does_not_change_files_or_provenance(self):
        self.publish_update("upstream header\n\nbody\n\nfooter\n")
        before = (self.product / "upstream.toml").read_bytes()

        with self.assertRaisesRegex(sync_upstream.UpstreamError, "conflict resolution"):
            sync_upstream.update(self.product, "rust-v2.0.0")

        self.assertEqual(self.git(self.product, "status", "--porcelain=v1"), "")
        self.assertEqual((self.product / "upstream.toml").read_bytes(), before)
        self.assertEqual(
            (self.product / "engine/runtime.txt").read_text(),
            "product header\n\nbody\n\nfooter\n",
        )

    def test_dirty_worktree_is_rejected_before_fetching(self):
        (self.product / "README.md").write_text("# Work in progress\n")
        with self.assertRaisesRegex(sync_upstream.UpstreamError, "local changes"):
            sync_upstream.update(self.product, "rust-v2.0.0")
        self.assertFalse((self.product / ".git/FETCH_HEAD").exists())
        self.assertEqual(
            (self.product / "README.md").read_text(), "# Work in progress\n"
        )

    def test_missing_provenance_rejects_the_update_before_fetching(self):
        (self.product / "upstream.toml").write_text('[codex]\ntag = "rust-v1.0.0"\n')
        self.commit(self.product)
        with self.assertRaisesRegex(
            sync_upstream.UpstreamError, "repository, tag, and commit"
        ):
            sync_upstream.update(self.product, "rust-v2.0.0")
        self.assertFalse((self.product / ".git/FETCH_HEAD").exists())


if __name__ == "__main__":
    unittest.main()
