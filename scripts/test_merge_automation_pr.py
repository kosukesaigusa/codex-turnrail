"""Exercise automated merge gates, stale-base refresh, and post-merge CI dispatch."""

import base64
import copy
import plistlib
import unittest
from unittest.mock import patch

import merge_automation_pr as auto
from project_metadata import metadata_bytes


class AutomationMergeTests(unittest.TestCase):
    def setUp(self):
        self.repo = "fixture/product"
        self.base, self.head = "a" * 40, "b" * 40
        self.branch = "upstream/codex-app-100"
        self.run = {
            "id": 123,
            "run_attempt": 1,
            "head_branch": self.branch,
            "head_sha": self.head,
            "event": "workflow_dispatch",
            "status": "completed",
            "conclusion": "success",
            "actor": {"login": auto.BOT},
            "repository": {"full_name": self.repo},
            "head_repository": {"full_name": self.repo},
            "path": ".github/workflows/ci.yml",
        }
        self.pr = {
            "number": 8,
            "user": {"login": auto.BOT},
            "state": "open",
            "merged": False,
            "draft": False,
            "head": {
                "ref": self.branch,
                "sha": self.head,
                "repo": {"full_name": self.repo},
            },
            "base": {"ref": "main", "repo": {"full_name": self.repo}},
            "commits": 1,
            "changed_files": 5,
        }
        self.commits = [{"author": {"login": auto.BOT}}]
        self.files = [
            {"filename": name, "status": "modified"}
            for name in (
                "upstream.toml",
                "packaging/Info.plist",
                str(auto.GENERATED),
                str(auto.VERSION_GENERATED),
                "engine/codex-rs/Cargo.lock",
            )
        ]
        before = {
            "CFBundleShortVersionString": "0.7.2",
            "CFBundleVersion": "34",
            "CFBundleIdentifier": "com.example.app",
        }
        after = {
            **before,
            "CFBundleShortVersionString": "0.8.0",
            "CFBundleVersion": "35",
        }
        old = {
            "codex": {
                "repository": "https://github.com/openai/codex.git",
                "tag": "rust-v0.155.0",
                "commit": "a" * 40,
            },
            "app": {
                "bundle_identifier": "com.openai.codex",
                "version": "26.900.1",
                "build": "99",
            },
        }
        new = {**old, "app": {**old["app"], "version": "26.900.2", "build": "100"}}
        self.contents = {
            (self.base, "packaging/Info.plist"): plistlib.dumps(before),
            (self.head, "packaging/Info.plist"): plistlib.dumps(after),
            (self.head, str(auto.VERSION_GENERATED)): auto.product_version_swift(
                "0.8.0"
            ).encode(),
            (self.base, "upstream.toml"): metadata_bytes(old),
            (self.head, "upstream.toml"): metadata_bytes(new),
            (self.head, str(auto.GENERATED)): auto.supported_swift(new).encode(),
        }
        self.latest = copy.deepcopy(self.run)
        self.comparison = "ahead"
        self.current_main = self.base
        self.main_runs = []
        self.writes = []
        self.api = patch.object(auto, "github", side_effect=self.github)
        self.api.start()
        self.addCleanup(self.api.stop)
        self.dispatch = patch.object(auto, "dispatch_ci")
        self.dispatched = self.dispatch.start()
        self.addCleanup(self.dispatch.stop)

    def github(self, endpoint, *, method="GET", payload=None):
        if method != "GET":
            self.writes.append((endpoint, method, payload))
            if endpoint.endswith("/merge"):
                self.current_main = "c" * 40
                return {"merged": True, "sha": "c" * 40}
            if endpoint.endswith("/update-branch"):
                self.pr["head"]["sha"] = "d" * 40
                return {}
            self.fail(endpoint)
        if endpoint.endswith("/actions/runs/123"):
            return copy.deepcopy(self.run)
        if "/actions/workflows/ci.yml/runs?" in endpoint and "branch=main" in endpoint:
            return {"workflow_runs": self.main_runs}
        if "/actions/workflows/ci.yml/runs?" in endpoint:
            return {"workflow_runs": [self.latest]}
        if "/pulls?" in endpoint:
            return [{"number": 8}]
        if endpoint.endswith("/pulls/8"):
            return copy.deepcopy(self.pr)
        if "/commits?" in endpoint:
            return self.commits
        if endpoint.endswith("/git/ref/heads/main"):
            return {"object": {"sha": self.current_main}}
        if "/files?" in endpoint:
            return self.files
        if "/compare/" in endpoint:
            return {"status": self.comparison}
        if "/contents/" in endpoint:
            path, commit = endpoint.split("/contents/")[1].split("?ref=")
            return {
                "type": "file",
                "encoding": "base64",
                "content": base64.b64encode(self.contents[(commit, path)]).decode(),
            }
        self.fail(endpoint)

    def merge(self):
        auto.merge(self.repo, 123)

    def test_verified_upstream_merges_exact_head_then_dispatches_main_ci(self):
        self.merge()
        self.assertEqual(
            self.writes,
            [
                (
                    "repos/fixture/product/pulls/8/merge",
                    "PUT",
                    {"merge_method": "squash", "sha": self.head},
                )
            ],
        )
        self.dispatched.assert_called_once_with(self.repo, "main")

    def test_retry_after_merge_recovers_missing_main_ci_without_merging_twice(self):
        self.merge()
        self.writes.clear()
        self.dispatched.reset_mock()
        self.pr.update(
            state="closed",
            merged=True,
            merged_by={"login": auto.BOT},
            merge_commit_sha="c" * 40,
        )
        self.merge()
        self.assertEqual(self.writes, [])
        self.dispatched.assert_called_once_with(self.repo, "main")
        self.dispatched.reset_mock()
        self.main_runs = [{"event": "workflow_dispatch"}]
        self.merge()
        self.dispatched.assert_not_called()

    def test_main_race_after_merge_does_not_dispatch_ci_for_the_wrong_commit(self):
        with self.assertRaisesRegex(ValueError, "Main advanced"):
            auto.ensure_main_ci(self.repo, "c" * 40)
        self.dispatched.assert_not_called()

    def test_failed_untrusted_or_non_dispatch_ci_cannot_merge(self):
        for key, value in (
            ("conclusion", "failure"),
            ("status", "in_progress"),
            ("event", "pull_request"),
            ("actor", {"login": "someone"}),
            ("repository", {"full_name": "foreign/repo"}),
            ("head_repository", {"full_name": "fork/product"}),
            ("path", ".github/workflows/other.yml"),
        ):
            with (
                self.subTest(key=key),
                patch.dict(self.run, {key: value}),
                self.assertRaises(ValueError),
            ):
                self.merge()
        self.assertEqual(self.writes, [])
        self.dispatched.assert_not_called()

    def test_newer_ci_run_or_rerun_supersedes_the_successful_completion(self):
        for key, value in (
            ("id", 124),
            ("run_attempt", 2),
            ("conclusion", "failure"),
            ("status", "queued"),
        ):
            with (
                self.subTest(key=key),
                patch.dict(self.latest, {key: value}),
                self.assertRaises(ValueError),
            ):
                self.merge()
        self.assertEqual(self.writes, [])

    def test_changed_head_fork_or_nonbot_pr_cannot_merge(self):
        for part, key, value in (
            (self.pr["head"], "sha", "d" * 40),
            (self.pr["head"], "repo", {"full_name": "fork/product"}),
            (self.pr["base"], "ref", "develop"),
            (self.pr["user"], "login", "human"),
        ):
            with (
                self.subTest(key=key),
                patch.dict(part, {key: value}),
                self.assertRaises(ValueError),
            ):
                self.merge()
        self.assertEqual(self.writes, [])

    def test_human_edits_and_extra_automation_changes_require_review(self):
        self.commits.append({"author": {"login": "human"}})
        self.pr["commits"] = 2
        with self.assertRaisesRegex(ValueError, "Human edits"):
            self.merge()
        self.commits.pop()
        self.pr["commits"] = 1
        self.files[4]["filename"] = ".github/workflows/ci.yml"
        with self.assertRaisesRegex(ValueError, "unrelated files"):
            self.merge()
        self.assertEqual(self.writes, [])

    def test_draft_closed_and_ordinary_prs_are_not_automatically_merged(self):
        self.pr["draft"] = True
        self.merge()
        self.pr["draft"] = False
        self.pr["state"] = "closed"
        self.merge()
        self.run["head_branch"] = "feature/manual"
        self.merge()
        self.assertEqual(self.writes, [])

    def test_stale_base_is_updated_and_must_pass_new_ci_before_merging(self):
        self.comparison = "diverged"
        self.merge()
        self.assertEqual(
            self.writes,
            [
                (
                    "repos/fixture/product/pulls/8/update-branch",
                    "PUT",
                    {"expected_head_sha": self.head},
                )
            ],
        )
        self.dispatched.assert_called_once_with(self.repo, self.branch)

    def test_incomplete_file_list_and_renames_are_rejected(self):
        self.pr["changed_files"] += 1
        with self.assertRaisesRegex(ValueError, "complete PR file list"):
            self.merge()
        self.pr["changed_files"] -= 1
        self.files[0]["status"] = "renamed"
        with self.assertRaisesRegex(ValueError, "Renamed files"):
            self.merge()
        self.assertEqual(self.writes, [])

    def test_version_collision_and_unrelated_plist_edits_are_rejected(self):
        key = (self.head, "packaging/Info.plist")
        original = self.contents[key]
        for field, value in (
            ("CFBundleVersion", "34"),
            ("CFBundleShortVersionString", "0.9.0"),
            ("CFBundleIdentifier", "other"),
        ):
            changed = plistlib.loads(original)
            changed[field] = value
            self.contents[key] = plistlib.dumps(changed)
            with (
                self.subTest(field=field),
                self.assertRaisesRegex(ValueError, "increment"),
            ):
                self.merge()
        self.assertEqual(self.writes, [])

    def test_only_the_exact_published_download_link_change_can_auto_merge(self):
        self.branch = "docs/release-v0.8.0"
        self.run["head_branch"] = self.branch
        self.latest["head_branch"] = self.branch
        self.pr["head"]["ref"] = self.branch
        self.files = [{"filename": "README.md", "status": "modified"}]
        self.pr["changed_files"] = 1
        old = "https://github.com/fixture/product/releases/download/v0.7.0/Codex-Turnrail-v0.7.0-macos-arm64.zip"
        new = old.replace("v0.7.0", "v0.8.0")
        self.contents[(self.base, "README.md")] = f"Download: {old}\n".encode()
        self.contents[(self.head, "README.md")] = f"Download: {new}\n".encode()
        with patch.object(auto, "published_url", return_value=new):
            self.merge()
            self.assertEqual(len(self.writes), 1)
            self.writes.clear()
            self.current_main = self.base
            self.contents[(self.head, "README.md")] += b"Unrelated edit\n"
            with self.assertRaisesRegex(ValueError, "beyond"):
                self.merge()
        self.assertEqual(self.writes, [])


if __name__ == "__main__":
    unittest.main()
