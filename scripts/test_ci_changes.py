"""Check Engine selection against real committed source changes."""

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import ci_changes
import engine_artifacts as artifacts


class CiChangesTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "CI fixture")
        self.git("config", "user.email", "ci@example.invalid")
        for scope in artifacts.SCOPES:
            path = (
                scope + "/fixture" if scope in {"engine", "scripts", "tests"} else scope
            )
            self.write(path, "initial\n")
        self.base = self.commit()

    def git(self, *args):
        return artifacts.git(self.root, *args)

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)

    def commit(self):
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")
        return self.git("rev-parse", "HEAD")

    def test_monitor_docs_app_and_version_changes_skip_engine_without_artifacts(self):
        for path in (
            ".github/workflows/upstream.yml",
            ".github/release.yml",
            "docs/releases.md",
            "README.md",
            "app/Sources/Settings.swift",
            "packaging/Info.plist",
            "upstream.toml",
        ):
            self.write(path, "changed\n")
        source = self.commit()
        for event_name, event in (
            ("pull_request", {"pull_request": {"base": {"sha": self.base}}}),
            ("push", {"before": self.base}),
        ):
            with self.subTest(event=event_name):
                required, _ = ci_changes.classify(self.root, event_name, event, source)
                self.assertFalse(required)
        self.assertEqual(
            artifacts.source_inputs(self.root, self.base),
            artifacts.source_inputs(self.root, source),
        )

    def test_build_test_workflow_and_embedded_markdown_changes_require_engine(self):
        base = self.base
        for path in (
            "engine/codex-rs/core/prompt.md",
            "engine/codex-rs/Cargo.lock",
            "scripts/engine_artifacts.py",
            "tests/integration/verify_runtime.py",
            "justfile",
            ".github/workflows/ci.yml",
            ".github/workflows/engine-checks.yml",
            ".github/workflows/engine-release.yml",
            ".github/workflows/release.yml",
        ):
            self.write(path, "changed\n")
            source = self.commit()
            with self.subTest(path=path):
                required, _ = ci_changes.classify(
                    self.root, "push", {"before": base}, source
                )
                self.assertTrue(required)
            base = source

    def test_deletion_or_rename_out_of_engine_scope_still_requires_engine(self):
        path = self.root / "engine/fixture"
        self.write("engine/remaining", "keep scope\n")
        base = self.commit()
        path.rename(self.root / "README.md")
        source = self.commit()
        required, _ = ci_changes.classify(self.root, "push", {"before": base}, source)
        self.assertTrue(required)

    def test_manual_ci_verifies_engine_even_without_source_changes(self):
        required, _ = ci_changes.classify(self.root, "workflow_dispatch", {}, self.base)
        self.assertTrue(required)

    def test_missing_or_invalid_comparison_data_cannot_skip_engine(self):
        for event_name, event in (
            ("schedule", {}),
            ("pull_request", {}),
            ("push", {"before": "0" * 40}),
            ("push", {"before": "missing"}),
            ("push", {"before": "f" * 40}),
        ):
            with (
                self.subTest(event=event),
                self.assertRaises(
                    (ValueError, KeyError, subprocess.CalledProcessError)
                ),
            ):
                ci_changes.classify(self.root, event_name, event, self.base)

    def test_local_and_remote_nested_git_objects_match_without_recursive_tree_limit(
        self,
    ):
        def github(endpoint):
            tree = endpoint.rsplit("/", 1)[1]
            rows = self.git("ls-tree", "-z", tree).split("\0")
            entries = []
            for row in rows:
                if not row:
                    continue
                metadata, path = row.split("\t")
                entries.append({"path": path, "sha": metadata.split()[2]})
            return {"truncated": False, "tree": entries}

        with patch.object(artifacts, "github", side_effect=github) as api:
            remote = artifacts.remote_inputs("fixture/repo", self.base)
        self.assertEqual(remote, artifacts.source_inputs(self.root, self.base))
        self.assertEqual(api.call_count, 3)

    def test_truncated_or_missing_remote_tree_data_cannot_authorize_reuse(self):
        for response in (
            {"truncated": True, "tree": []},
            {"truncated": False, "tree": []},
        ):
            with (
                self.subTest(response=json.dumps(response)),
                patch.object(artifacts, "github", return_value=response),
                self.assertRaises((ValueError, KeyError)),
            ):
                artifacts.remote_inputs("fixture/repo", self.base)


if __name__ == "__main__":
    unittest.main()
