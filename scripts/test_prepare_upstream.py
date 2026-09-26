"""Reject unsafe candidates and preserve existing review work."""

import io
import plistlib
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import prepare_upstream as prepare
from test_official_runtime import app_fixture


class CandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "packaging").mkdir()
        (self.root / "packaging/Info.plist").write_bytes(
            plistlib.dumps(
                {"CFBundleShortVersionString": "0.7.3", "CFBundleVersion": "34"}
            )
        )
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
                item = zipfile.ZipInfo(name)
                kind = stat.S_IFDIR if name.endswith("/") else stat.S_IFREG
                item.external_attr = (kind | 0o755) << 16
                archive.writestr(item, value)
        self.candidate["size"] = len(buffer.getvalue())

        def download(url, destination, **kwargs):
            destination.write_bytes(buffer.getvalue())

        return download

    def test_archive_cannot_write_outside_the_inspection_directory(self):
        archive = self.archive({"../../escaped": "unsafe"})
        with (
            patch.object(prepare, "download_app_file", side_effect=archive),
            patch.object(prepare.subprocess, "run") as sign,
            self.assertRaisesRegex(ValueError, "Unsafe.*path"),
        ):
            prepare.inspect_app(self.candidate, self.root)
        sign.assert_not_called()
        self.assertFalse((self.root / "escaped").exists())

    def test_untrusted_signature_prevents_cli_execution(self):
        archive = self.archive({"ChatGPT.app/Contents/Info.plist": b"fixture"})
        with (
            patch.object(prepare, "download_app_file", side_effect=archive),
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
            patch.object(prepare, "download_app_file", side_effect=archive),
            patch.object(prepare.subprocess, "run"),
            patch.object(prepare.subprocess, "check_output") as cli,
            self.assertRaisesRegex(ValueError, "metadata"),
        ):
            prepare.inspect_app(self.candidate, self.root)
        cli.assert_not_called()

    def test_signed_official_app_can_select_its_exact_prerelease_cli(self):
        plist = plistlib.dumps(
            {
                "CFBundleIdentifier": "com.openai.codex",
                "CFBundleShortVersionString": self.candidate["version"],
                "CFBundleVersion": self.candidate["build"],
            }
        )
        archive = self.archive(
            {
                "ChatGPT.app/Contents/Info.plist": plist,
                "ChatGPT.app/Contents/Resources/codex": b"fixture",
                "ChatGPT.app/Contents/Resources/codex-code-mode-host": b"fixture-host",
            }
        )
        with (
            patch.object(prepare, "download_app_file", side_effect=archive),
            patch.object(prepare.subprocess, "run") as signature,
            patch.object(
                prepare.subprocess,
                "check_output",
                return_value="codex-cli 0.154.0-alpha.6.2\n",
            ),
        ):
            self.assertEqual(
                prepare.inspect_app(self.candidate, self.root),
                "codex-cli 0.154.0-alpha.6.2",
            )
        self.assertEqual(signature.call_count, 3)

    def test_packaged_candidate_uses_its_launcher_without_a_flat_engine(self):
        version = "codex-cli 0.158.0-alpha.2"
        app = app_fixture(
            self.root / "fixture",
            "packageV1",
            {
                "bundle_identifier": "com.openai.codex",
                "version": self.candidate["version"],
                "build": self.candidate["build"],
                "cli_version": version,
            },
        )
        members = {}
        for path in app.rglob("*"):
            relative = path.relative_to(app.parent).as_posix()
            members[relative + "/" if path.is_dir() else relative] = (
                b"" if path.is_dir() else path.read_bytes()
            )
        archive = self.archive(members)
        with (
            patch.object(prepare, "download_app_file", side_effect=archive),
            patch.object(prepare.subprocess, "run") as signature,
            patch.object(
                prepare.subprocess, "check_output", return_value=version + "\n"
            ) as execute,
        ):
            self.assertEqual(prepare.inspect_app(self.candidate, self.root), version)
        self.assertEqual(signature.call_count, 4)
        self.assertTrue(
            execute.call_args.args[0][0].endswith(
                "/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"
            )
        )
        self.assertEqual(execute.call_args.args[0][1:], ["--version"])

    def test_candidate_includes_next_minor_and_build_with_generated_version(self):
        from project_metadata import (
            GENERATED,
            VERSION_GENERATED,
            metadata_bytes,
            product_version,
            product_version_swift,
            read_upstream,
        )

        metadata = {
            "codex": {
                "repository": "https://github.com/openai/codex.git",
                "tag": "rust-v0.154.0",
                "commit": "a" * 40,
            },
            "app": {
                "bundle_identifier": "com.openai.codex",
                "version": "26.900.1",
                "build": "1",
                "cli_version": "codex-cli 0.154.0",
            },
        }
        (self.root / "upstream.toml").write_bytes(metadata_bytes(metadata))
        for path in (GENERATED, VERSION_GENERATED):
            (self.root / path).parent.mkdir(parents=True, exist_ok=True)
        # A bundled CLI with no matching public source is still a valid candidate.
        # There is no reference Engine tree in this fixture and no network is allowed.
        with patch.object(
            prepare, "github", side_effect=AssertionError("Unexpected source lookup")
        ):
            prepare.prepare(self.root, self.candidate, "codex-cli 0.999.0-alpha.7")
        updated = read_upstream(self.root)
        self.assertEqual(updated["codex"], metadata["codex"])
        self.assertEqual(updated["app"]["cli_version"], "codex-cli 0.999.0-alpha.7")
        self.assertFalse((self.root / "engine").exists())
        self.assertEqual(product_version(self.root), ("0.8.0", "35"))
        self.assertEqual(
            (self.root / VERSION_GENERATED).read_text(), product_version_swift("0.8.0")
        )
        self.assertIn('"8881"', (self.root / GENERATED).read_text())

    def test_published_candidate_stages_versions_and_starts_ci_without_approval(self):
        calls = []

        def api(endpoint, *, method="GET", payload=None):
            if method == "GET":
                return []
            calls.append((endpoint, payload))
            return {"html_url": "https://github.com/owner/repo/pull/2"}

        with (
            patch.object(prepare, "github", side_effect=api),
            patch.object(prepare.subprocess, "run") as write,
            patch.object(prepare.subprocess, "check_output", return_value=""),
        ):
            prepare.publish(
                "owner/repo",
                "upstream/codex-app-8881",
                self.candidate,
                "codex-cli 0.154.0",
            )
        staged = next(
            call.args[0]
            for call in write.call_args_list
            if call.args[0][:2] == ["git", "add"]
        )
        self.assertIn("packaging/Info.plist", staged)
        self.assertIn(str(prepare.VERSION_GENERATED), staged)
        self.assertNotIn("engine", staged)
        self.assertFalse(calls[0][1]["draft"])
        self.assertEqual(
            calls[1][1], {"ref": "upstream/codex-app-8881", "inputs": {"scope": "auto"}}
        )

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
                "codex-cli 0.154.0",
            )
        write.assert_not_called()
        read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
