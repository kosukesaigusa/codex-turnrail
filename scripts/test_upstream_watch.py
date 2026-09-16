"""Verify update selection, independent failures, and notification deduplication."""

import copy
import io
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import upstream_watch as watch
from project_metadata import ROOT, read_upstream


def appcast(*builds):
    items = "".join(
        f"<item><sparkle:shortVersionString>26.908.{build}</sparkle:shortVersionString>"
        f"<sparkle:version>{build}</sparkle:version>"
        '<enclosure url="https://persistent.oaistatic.com/codex-app-prod/'
        f'ChatGPT-darwin-arm64-26.908.{build}.zip" length="123" '
        'sparkle:edSignature="fixture"/></item>'
        for build in builds
    )
    return f'<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel>{items}</channel></rss>'.encode()


class UpstreamWatchTests(unittest.TestCase):
    def setUp(self):
        self.supported = read_upstream(ROOT)
        self.data = {
            "supported": self.supported,
            "app": {
                "version": self.supported["app"]["version"],
                "build": self.supported["app"]["build"],
            },
            "cli": {
                "tag": self.supported["codex"]["tag"],
                "url": "https://github.com/openai/codex/releases",
            },
            "errors": {},
        }

    def test_feed_order_does_not_decide_the_latest_build(self):
        latest = watch.parse_appcast(appcast("8881", "8720", "8837"))
        self.assertEqual(latest["build"], "8881")

    def test_empty_duplicate_or_unexpected_download_feed_is_rejected(self):
        for data in (
            appcast(),
            appcast("8881", "8881"),
            appcast("8881").replace(b"persistent.oaistatic.com", b"example.com"),
            appcast("8881").replace(b'length="123"', b'length="0"'),
        ):
            with self.subTest(data=data), self.assertRaises(ValueError):
                watch.parse_appcast(data)

    def test_app_failure_keeps_the_cli_result_and_never_means_no_update(self):
        cli = {
            "tag": "rust-v9.0.0",
            "url": "https://github.com/openai/codex/releases/tag/rust-v9.0.0",
        }
        with (
            patch.object(watch, "fetch_appcast", side_effect=OSError("HTTP 403")),
            patch.object(watch, "latest_cli", return_value=cli),
        ):
            observed = watch.observe(self.supported)
        self.assertEqual(observed["cli"], cli)
        self.assertIsNone(observed["app"])
        self.assertEqual(observed["errors"], {"app": "HTTP 403"})
        self.assertFalse(watch.app_candidate(observed))
        self.assertTrue(watch.report_body(observed)[1])

    def test_standalone_cli_releases_are_reference_only(self):
        self.data["supported"]["codex"]["tag"] = "rust-v0.154.0-alpha.6.2"
        for tag in ("rust-v0.153.0", "rust-v0.154.0", "rust-v9.0.0"):
            with self.subTest(tag=tag):
                self.data["cli"]["tag"] = tag
                body, pending = watch.report_body(self.data)
                self.assertFalse(pending)
                self.assertFalse(watch.app_candidate(self.data))
                self.assertNotIn("Latest stable Codex CLI", body)
                self.assertNotIn(f"[{tag}](", body)
                summary = watch.summary_body(self.data)
                self.assertIn("Latest stable Codex CLI (reference only)", summary)
                self.assertIn(f"[{tag}]({self.data['cli']['url']})", summary)
                self.assertNotIn(watch.ISSUE_MARKER, summary)
                with patch.object(watch, "github", return_value=[]) as api:
                    self.assertIsNone(watch.update_issue("owner/repo", self.data))
                self.assertEqual(api.call_count, 1)
                self.assertEqual(api.call_args.kwargs, {})

    def test_summary_command_reports_cli_without_touching_github(self):
        self.data["cli"]["tag"] = "rust-v9.0.0"
        with tempfile.TemporaryDirectory() as temporary:
            observation = Path(temporary) / "upstream.json"
            observation.write_text(json.dumps(self.data))
            with (
                patch.object(
                    watch.sys, "argv", ["upstream_watch", "summary", str(observation)]
                ),
                patch.object(watch.sys, "stdout", new_callable=io.StringIO) as output,
                patch.object(watch, "github") as api,
            ):
                self.assertEqual(watch.main(), 0)
            api.assert_not_called()
            self.assertIn("rust-v9.0.0", output.getvalue())
            self.assertIn("## Upstream observation", output.getvalue())

    def test_cli_lookup_failure_still_requires_attention(self):
        with (
            patch.object(watch, "fetch_appcast", return_value=self.data["app"]),
            patch.object(watch, "latest_cli", side_effect=OSError("CLI unavailable")),
        ):
            observed = watch.observe(self.supported)
        self.assertIsNone(observed["cli"])
        self.assertEqual(observed["errors"], {"cli": "CLI unavailable"})
        self.assertTrue(watch.report_body(observed)[1])
        self.assertIn(
            "cli monitoring failed: CLI unavailable", watch.summary_body(observed)
        )

    def test_public_prerelease_must_have_the_exact_requested_tag(self):
        tag = "rust-v0.154.0-alpha.6.2"
        release = {"tag_name": tag, "draft": False, "prerelease": True}
        with patch.object(watch, "github", return_value=release):
            self.assertEqual(watch.source_release(tag), release)
        for invalid in (
            {**release, "draft": True},
            {**release, "tag_name": "rust-v0.154.0"},
        ):
            with (
                self.subTest(release=invalid),
                patch.object(watch, "github", return_value=invalid),
                self.assertRaisesRegex(ValueError, "matching public source"),
            ):
                watch.source_release(tag)

    def test_download_errors_redirects_and_oversize_bodies_are_rejected(self):
        for status, code, body in (
            ("403", 22, b"denied"),
            ("302", 0, b"redirect"),
            ("200", 0, b"x" * 11),
            ("200", 0, b""),
        ):
            with (
                self.subTest(status=status, code=code, size=len(body)),
                tempfile.TemporaryDirectory() as temporary,
            ):
                destination = Path(temporary) / "appcast.xml"

                def curl(command, **kwargs):
                    destination.write_bytes(body)
                    return subprocess.CompletedProcess(
                        command, code, status, "fixture HTTP error"
                    )

                with (
                    patch.object(watch.subprocess, "run", side_effect=curl),
                    self.assertRaises(ValueError),
                ):
                    watch.download_app_file(
                        watch.APPCAST_URL, destination, max_bytes=10, timeout=30
                    )

    def test_download_preserves_existing_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / "appcast.xml"
            destination.write_bytes(b"keep")
            with (
                patch.object(watch.subprocess, "run") as curl,
                self.assertRaisesRegex(ValueError, "already exists"),
            ):
                watch.download_app_file(
                    watch.APPCAST_URL, destination, max_bytes=10, timeout=30
                )
            curl.assert_not_called()
            self.assertEqual(destination.read_bytes(), b"keep")

    def test_unchanged_observation_does_not_write_the_tracking_issue(self):
        self.data["errors"]["app"] = "HTTP 403"
        body, _ = watch.report_body(self.data)
        issue = {"title": watch.ISSUE_TITLE, "body": body, "number": 7, "state": "open"}
        with patch.object(watch, "github", return_value=[issue]) as api:
            self.assertEqual(watch.update_issue("owner/repo", self.data), issue)
        self.assertEqual(api.call_count, 1)

    def test_recovery_closes_the_existing_issue(self):
        self.data["cli"]["tag"] = "rust-v9.0.0"
        prior = copy.deepcopy(self.data)
        prior["errors"]["app"] = "HTTP 403"
        body, _ = watch.report_body(prior)
        issue = {"title": watch.ISSUE_TITLE, "body": body, "number": 7, "state": "open"}
        with patch.object(watch, "github", side_effect=[[issue], {}]) as api:
            watch.update_issue("owner/repo", self.data)
        self.assertEqual(api.call_args.kwargs["payload"]["state"], "closed")

    def test_closes_the_existing_cli_only_issue(self):
        self.data["cli"]["tag"] = "rust-v9.0.0"
        issue = {
            "title": watch.ISSUE_TITLE,
            "body": watch.ISSUE_MARKER + "\nLatest stable Codex CLI: rust-v9.0.0.\n",
            "number": 2,
            "state": "open",
        }
        with patch.object(watch, "github", side_effect=[[issue], {}]) as api:
            watch.update_issue("owner/repo", self.data)
        self.assertEqual(api.call_args.args[0], "repos/owner/repo/issues/2")
        self.assertEqual(api.call_args.kwargs["method"], "PATCH")
        self.assertEqual(api.call_args.kwargs["payload"]["state"], "closed")

    def test_cli_changes_do_not_reopen_or_rewrite_the_closed_issue(self):
        body, _ = watch.report_body(self.data)
        issue = {
            "title": watch.ISSUE_TITLE,
            "body": body,
            "number": 2,
            "state": "closed",
        }
        self.data["cli"]["tag"] = "rust-v9.0.0"
        with patch.object(watch, "github", return_value=[issue]) as api:
            self.assertEqual(watch.update_issue("owner/repo", self.data), issue)
        self.assertEqual(api.call_count, 1)
        self.assertEqual(api.call_args.kwargs, {})

    def test_app_updates_and_monitoring_failures_reopen_the_same_issue(self):
        body, _ = watch.report_body(self.data)
        issue = {
            "title": watch.ISSUE_TITLE,
            "body": body,
            "number": 2,
            "state": "closed",
        }
        for reason in ("new_app", "app", "cli", "candidate"):
            with self.subTest(reason=reason):
                observation = copy.deepcopy(self.data)
                if reason == "new_app":
                    observation["app"]["build"] = str(
                        int(self.supported["app"]["build"]) + 1
                    )
                else:
                    observation["errors"][reason] = "Inspection failed"
                with patch.object(watch, "github", side_effect=[[issue], {}]) as api:
                    watch.update_issue("owner/repo", observation)
                self.assertEqual(api.call_args.args[0], "repos/owner/repo/issues/2")
                self.assertEqual(api.call_args.kwargs["method"], "PATCH")
                self.assertEqual(api.call_args.kwargs["payload"]["state"], "open")

    def test_human_issue_with_the_same_title_is_preserved(self):
        self.data["errors"]["app"] = "HTTP 403"
        issue = {
            "title": watch.ISSUE_TITLE,
            "body": "Human notes",
            "number": 7,
            "state": "open",
        }
        with patch.object(watch, "github", side_effect=[[issue], {}]) as api:
            watch.update_issue("owner/repo", self.data)
        self.assertEqual(api.call_args.args[0], "repos/owner/repo/issues")
        self.assertEqual(api.call_args.kwargs["method"], "POST")


if __name__ == "__main__":
    unittest.main()
