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
        workspace = self.upstream / "codex-rs"
        (workspace / "cli/src").mkdir(parents=True)
        (workspace / "Cargo.toml").write_text(
            '[workspace]\nmembers = ["cli"]\nresolver = "2"\n'
            '[workspace.package]\nversion = "1.0.0"\n'
        )
        (workspace / "cli/Cargo.toml").write_text(
            '[package]\nname = "codex-fixture"\nversion.workspace = true\n'
            'edition = "2021"\n'
        )
        (workspace / "cli/src/lib.rs").write_text("pub fn fixture() {}\n")
        self.cargo(workspace, "generate-lockfile", "--offline")
        self.commit(self.upstream)
        self.git(self.upstream, "tag", "rust-v1.0.0")
        self.base = self.git(self.upstream, "rev-parse", "HEAD")
        engine = self.product / "engine"
        engine.mkdir()
        for path in self.upstream.iterdir():
            if path.name != ".git":
                if path.is_dir():
                    shutil.copytree(path, engine / path.name)
                else:
                    shutil.copy2(path, engine / path.name)
        (engine / "runtime.txt").write_text("product header\n\nbody\n\nfooter\n")
        (engine / "custom.txt").write_text("account routing\n")
        (self.product / "README.md").write_text("# Product\n")
        (self.product / "upstream.toml").write_bytes(
            sync_upstream.metadata_bytes(
                {
                    "codex": {
                        "repository": str(self.upstream),
                        "tag": "rust-v1.0.0",
                        "commit": self.base,
                    },
                    "app": {
                        "bundle_identifier": "com.openai.codex",
                        "cli_version": "codex-cli 1.0.0",
                        "version": "1.0.0",
                        "build": "1",
                    },
                }
            )
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

    def cargo(self, workspace, *arguments):
        return subprocess.run(
            ["cargo", *arguments],
            cwd=workspace,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=True,
        )

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
                },
                "app": {
                    "bundle_identifier": "com.openai.codex",
                    "cli_version": "codex-cli 1.0.0",
                    "version": "1.0.0",
                    "build": "1",
                },
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

    def test_version_only_upstream_update_refreshes_the_workspace_lock(self):
        manifest = self.upstream / "codex-rs/Cargo.toml"
        manifest.write_text(manifest.read_text().replace('"1.0.0"', '"2.0.0"'))
        self.publish_update("header\n\nbody\n\nnew footer\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.cargo(self.upstream / "codex-rs", "metadata", "--locked", "--offline")

        sync_upstream.update(self.product, "rust-v2.0.0")

        workspace = self.product / "engine/codex-rs"
        lock = workspace / "Cargo.lock"
        self.assertEqual(
            tomllib.loads(lock.read_text())["package"],
            [{"name": "codex-fixture", "version": "2.0.0"}],
        )
        before = lock.read_bytes()
        self.cargo(workspace, "metadata", "--locked", "--offline")
        self.assertEqual(lock.read_bytes(), before)
        self.assertEqual(self.git(self.product, "diff", "--cached"), "")

    def test_invalid_merged_manifest_stops_upstream_preparation(self):
        manifest = self.upstream / "codex-rs/cli/Cargo.toml"
        manifest.write_text(
            manifest.read_text() + '[dependencies]\nmissing = { path = "../missing" }\n'
        )
        self.publish_update("header\n\nbody\n\nnew footer\n")

        with self.assertRaisesRegex(sync_upstream.UpstreamError, "lockfile"):
            sync_upstream.update(self.product, "rust-v2.0.0")

        self.assertEqual(self.git(self.product, "diff", "--cached"), "")

    def test_prerelease_update_preserves_routing_and_exact_provenance(self):
        incoming = self.publish_update("header\n\nbody\n\nnew footer\n")
        tag = "rust-v2.0.0-alpha.6.2"
        self.git(self.upstream, "tag", tag)
        head = self.git(self.product, "rev-parse", "HEAD")
        self.assertEqual(sync_upstream.update(self.product, tag), incoming)
        metadata = sync_upstream.read_upstream(self.product)
        self.assertEqual(metadata["codex"]["tag"], tag)
        self.assertEqual(metadata["codex"]["commit"], incoming)
        self.assertEqual(
            (self.product / "engine/custom.txt").read_text(), "account routing\n"
        )
        self.assertEqual(
            (self.product / "engine/runtime.txt").read_text(),
            "product header\n\nbody\n\nnew footer\n",
        )
        self.assertEqual(self.git(self.product, "rev-parse", "HEAD"), head)
        self.assertEqual(self.git(self.product, "diff", "--cached"), "")

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
        with self.assertRaisesRegex(ValueError, "exactly"):
            sync_upstream.update(self.product, "rust-v2.0.0")
        self.assertFalse((self.product / ".git/FETCH_HEAD").exists())


if __name__ == "__main__":
    unittest.main()
