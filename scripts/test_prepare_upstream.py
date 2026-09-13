"""Reject unsafe candidates and preserve existing review work."""

import io
import plistlib
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import prepare_upstream as prepare


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.candidate = {
            "version": "26.908.40834",
            "build": "8881",
            "size": 0,
            "url": "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-26.908.40834.zip",
        }

    def archive(self, members):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            for name, value in members.items():
                archive.writestr(name, value)
        self.candidate["size"] = len(buffer.getvalue())
        return io.BytesIO(buffer.getvalue())

    def test_archive_cannot_write_outside_the_inspection_directory(self):
        archive = self.archive({"../../escaped": "unsafe"})
        with (
            patch.object(prepare.urllib.request, "urlopen", return_value=archive),
            patch.object(prepare.subprocess, "run") as sign,
            self.assertRaisesRegex(ValueError, "Unsafe path"),
        ):
            prepare.inspect_app(self.candidate, self.root)
        sign.assert_not_called()
        self.assertFalse((self.root / "escaped").exists())

    def test_untrusted_signature_prevents_cli_execution(self):
        archive = self.archive({"ChatGPT.app/Contents/Info.plist": b"fixture"})
        with (
            patch.object(prepare.urllib.request, "urlopen", return_value=archive),
            patch.object(
                prepare.subprocess,
                "run",
                side_effect=subprocess.CalledProcessError(1, ["codesign"]),
            ),
            patch.object(prepare.subprocess, "check_output") as cli,
            self.assertRaises(subprocess.CalledProcessError),
        ):
            prepare.inspect_app(self.candidate, self.root)
        cli.assert_not_called()

    def test_signed_app_metadata_must_match_the_feed_before_cli_execution(self):
        plist = plistlib.dumps(
            {
                "CFBundleIdentifier": "com.openai.codex",
                "CFBundleShortVersionString": self.candidate["version"],
                "CFBundleVersion": "1",
            }
        )
        archive = self.archive({"ChatGPT.app/Contents/Info.plist": plist})
        with (
            patch.object(prepare.urllib.request, "urlopen", return_value=archive),
            patch.object(prepare.subprocess, "run"),
            patch.object(prepare.subprocess, "check_output") as cli,
            self.assertRaisesRegex(ValueError, "metadata"),
        ):
            prepare.inspect_app(self.candidate, self.root)
        cli.assert_not_called()

    def test_existing_pr_never_changes_or_pushes_a_branch(self):
        with (
            patch.object(prepare, "github", return_value=[{"number": 3}]),
            patch.object(prepare.subprocess, "run") as write,
            patch.object(prepare.subprocess, "check_output") as read,
        ):
            prepare.publish(
                "owner/repo",
                "upstream/codex-app-8881",
                self.candidate,
                "rust-v0.154.0",
                "a" * 40,
            )
        write.assert_not_called()
        read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
