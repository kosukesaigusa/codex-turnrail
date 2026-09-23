"""Check change-impact plans against real commits and Engine identities."""

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
                scope + "/fixture"
                if scope in {"engine", "tests/integration"}
                else scope
            )
            self.write(path, "initial\n")
        self.base = self.commit()
        self.git("update-ref", "refs/remotes/origin/main", self.base)

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

    def plan(self, paths, expected):
        base = self.git("rev-parse", "HEAD")
        for path in paths:
            self.write(path, base + "\n")
        source = self.commit()
        for event_name, event in (
            ("pull_request", {"pull_request": {"base": {"sha": base}}}),
            ("push", {"before": base}),
        ):
            plan, _ = ci_changes.classify(self.root, event_name, event, source)
            self.assertEqual(
                {name for name, required in plan.items() if required}, expected
            )
        return base, source

    def test_docs_images_and_root_markdown_only_need_static_checks(self):
        self.plan(
            (
                "README.md",
                "docs/releases.md",
                "docs/images/switch.png",
                "CONTRIBUTING.md",
            ),
            set(),
        )

    def test_monitor_release_automation_and_ci_control_only_need_tooling_tests(self):
        base, source = self.plan(
            (
                ".github/workflows/upstream.yml",
                ".github/workflows/ci.yml",
                ".github/workflows/release-readme.yml",
                ".github/workflows/release-prepare.yml",
                ".github/release.yml",
                "scripts/prepare_release.py",
                "scripts/upstream_watch.py",
                "scripts/ci_changes.py",
                "scripts/test_ci_changes.py",
            ),
            {"tooling"},
        )
        self.assertEqual(
            artifacts.source_inputs(self.root, base),
            artifacts.source_inputs(self.root, source),
        )

    def test_app_sources_resources_and_compatibility_metadata_skip_engine(self):
        self.plan(
            ("app/Sources/Settings.swift", "packaging/Info.plist", "upstream.toml"),
            {"tooling", "app"},
        )
        self.plan(
            ("packaging/resources/AppIcon.icns", "scripts/build-app.sh"),
            {"tooling", "app"},
        )
        for path in (
            "scripts/official_app.py",
            "scripts/product_evidence.py",
            "scripts/verify_official_runtime.py",
        ):
            with self.subTest(path=path):
                self.plan((path,), {"tooling", "app"})

    def test_engine_and_build_contract_changes_require_engine_checks(self):
        for path in (
            "engine/codex-rs/core/prompt.md",
            "engine/codex-rs/Cargo.lock",
            "scripts/engine_artifacts.py",
            "scripts/build-runtime.py",
            "scripts/runtime_evidence.py",
            "scripts/github_api.py",
            "tests/integration/verify_runtime.py",
            ".github/workflows/engine-checks.yml",
            ".github/workflows/engine-release.yml",
        ):
            with self.subTest(path=path):
                base, source = self.plan((path,), {"tooling", "engine", "dependencies"})
                self.assertNotEqual(
                    artifacts.source_inputs(self.root, base),
                    artifacts.source_inputs(self.root, source),
                )

    def test_shared_build_helper_combines_app_and_engine_requirements(self):
        self.plan(("scripts/dev.py",), set(ci_changes.FLAGS))

    def test_dependency_workflow_change_does_not_recompile_engine(self):
        self.plan(
            (".github/workflows/dependency-policy.yml",), {"tooling", "dependencies"}
        )

    def test_mixed_documentation_and_code_changes_keep_all_affected_checks(self):
        self.plan(
            (
                "docs/releases.md",
                "app/Sources/App.swift",
                "engine/codex-rs/core/prompt.md",
            ),
            set(ci_changes.FLAGS),
        )

    def test_rename_or_deletion_cannot_hide_original_engine_impact(self):
        self.write("engine/remaining", "keep scope\n")
        base = self.commit()
        (self.root / "engine/fixture").rename(self.root / "README.md")
        source = self.commit()
        plan, _ = ci_changes.classify(self.root, "push", {"before": base}, source)
        self.assertTrue(plan["engine"])
        self.assertIn(
            "engine/fixture", ci_changes.changed_paths(self.root, base, source)
        )

    def test_automatic_dispatch_uses_branch_diff_and_cannot_force_a_skip(self):
        self.write("docs/releases.md", "changed\n")
        source = self.commit()
        event = {"inputs": {"scope": "auto"}}
        plan, _ = ci_changes.classify(self.root, "workflow_dispatch", event, source)
        self.assertFalse(any(plan.values()))
        self.write("engine/fixture", "changed\n")
        source = self.commit()
        plan, _ = ci_changes.classify(self.root, "workflow_dispatch", event, source)
        self.assertTrue(plan["engine"])
        self.git("update-ref", "refs/remotes/origin/main", source)
        plan, _ = ci_changes.classify(self.root, "workflow_dispatch", event, source)
        self.assertTrue(plan["engine"])

    def test_explicit_full_dispatch_runs_every_check_even_without_changes(self):
        plan, _ = ci_changes.classify(
            self.root, "workflow_dispatch", {"inputs": {"scope": "full"}}, self.base
        )
        self.assertTrue(all(plan.values()))

    def test_missing_unknown_empty_and_invalid_comparisons_fail(self):
        for event_name, event in (
            ("schedule", {}),
            ("pull_request", {}),
            ("push", {"before": "0" * 40}),
            ("push", {"before": "missing"}),
            ("push", {"before": "f" * 40}),
            ("push", {"before": self.base}),
            ("workflow_dispatch", {"inputs": {"scope": "readme"}}),
        ):
            with (
                self.subTest(event=event),
                self.assertRaises(
                    (ValueError, KeyError, subprocess.CalledProcessError)
                ),
            ):
                ci_changes.classify(self.root, event_name, event, self.base)
        for path in (
            "new-product/main.swift",
            "scripts/new-build-helper.py",
            ".github/workflows/new-build.yml",
        ):
            with (
                self.subTest(path=path),
                self.assertRaisesRegex(ValueError, "No CI impact rule"),
            ):
                ci_changes.impacts(path)

    def test_every_tracked_product_file_has_an_explicit_impact_category(self):
        paths = artifacts.git(artifacts.ROOT, "ls-files", "-z").split("\0")
        for path in filter(None, paths):
            with self.subTest(path=path):
                ci_changes.impacts(path)

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
        self.assertLess(api.call_count, len(artifacts.SCOPES))

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
