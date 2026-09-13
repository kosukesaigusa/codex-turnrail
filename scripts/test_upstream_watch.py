"""Verify update selection, independent failures, and notification deduplication."""

import copy
import unittest
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

    def test_new_cli_does_not_prepare_an_app_update(self):
        self.data["cli"]["tag"] = "rust-v9.0.0"
        self.assertTrue(watch.report_body(self.data)[1])
        self.assertFalse(watch.app_candidate(self.data))

    def test_unchanged_observation_does_not_write_the_tracking_issue(self):
        self.data["errors"]["app"] = "HTTP 403"
        body, _ = watch.report_body(self.data)
        issue = {"title": watch.ISSUE_TITLE, "body": body, "number": 7, "state": "open"}
        with patch.object(watch, "github", return_value=[issue]) as api:
            self.assertEqual(watch.update_issue("owner/repo", self.data), issue)
        self.assertEqual(api.call_count, 1)

    def test_recovery_closes_the_existing_issue(self):
        prior = copy.deepcopy(self.data)
        prior["errors"]["app"] = "HTTP 403"
        body, _ = watch.report_body(prior)
        issue = {"title": watch.ISSUE_TITLE, "body": body, "number": 7, "state": "open"}
        with patch.object(watch, "github", side_effect=[[issue], {}]) as api:
            watch.update_issue("owner/repo", self.data)
        self.assertEqual(api.call_args.kwargs["payload"]["state"], "closed")

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
