"""The official runtime must be signed and pinned before any executable is run."""

import plistlib
import stat
import subprocess
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import official_app
from project_metadata import ROOT, read_upstream


class OfficialAppTests(unittest.TestCase):
    def test_signature_failure_prevents_cli_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "ChatGPT.app"
            app.mkdir()
            with (
                patch.object(
                    official_app.subprocess,
                    "run",
                    side_effect=subprocess.CalledProcessError(1, "codesign"),
                ),
                patch.object(official_app.subprocess, "check_output") as execute,
                self.assertRaises(subprocess.CalledProcessError),
            ):
                official_app.verify(app, read_upstream(ROOT))
            execute.assert_not_called()

    def test_other_signed_app_build_is_rejected_before_cli_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "ChatGPT.app"
            (app / "Contents").mkdir(parents=True)
            metadata = read_upstream(ROOT)
            (app / "Contents/Info.plist").write_bytes(
                plistlib.dumps(
                    {
                        "CFBundleIdentifier": metadata["app"]["bundle_identifier"],
                        "CFBundleShortVersionString": metadata["app"]["version"],
                        "CFBundleVersion": "1",
                    }
                )
            )
            with (
                patch.object(official_app.subprocess, "run") as signature,
                patch.object(official_app.subprocess, "check_output") as execute,
                self.assertRaisesRegex(ValueError, "version and build"),
            ):
                official_app.verify(app, metadata)
            self.assertEqual(signature.call_count, 3)
            execute.assert_not_called()

    def test_unsafe_archive_paths_and_symlink_targets_are_rejected(self):
        for filename, target in [
            ("../outside", None),
            ("/absolute", None),
            ("ChatGPT.app/link", "../../outside"),
        ]:
            with (
                self.subTest(filename=filename),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                archive = root / "app.zip"
                with zipfile.ZipFile(archive, "w") as bundle:
                    item = zipfile.ZipInfo(filename)
                    item.external_attr = (
                        (stat.S_IFLNK | 0o777) << 16
                        if target
                        else (stat.S_IFREG | 0o644) << 16
                    )
                    bundle.writestr(item, target if target else "fixture")
                with self.assertRaises(ValueError):
                    official_app.extract(archive, root / "unpacked")

    def test_correctly_signed_but_unpinned_cli_cannot_pass_verification(self):
        metadata = read_upstream(ROOT)
        evidence = {"cli_version": "codex-cli 0.999.0-alpha.7"}
        with (
            patch.object(official_app, "inspect", return_value=evidence),
            self.assertRaisesRegex(ValueError, "supported contract"),
        ):
            official_app.verify(Path("ChatGPT.app"), metadata)

    def test_internal_framework_symlinks_and_executable_modes_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "app.zip"
            with zipfile.ZipFile(archive, "w") as bundle:
                binary = zipfile.ZipInfo("ChatGPT.app/Framework/Versions/A/binary")
                binary.external_attr = (stat.S_IFREG | 0o755) << 16
                bundle.writestr(binary, "fixture")
                link = zipfile.ZipInfo("ChatGPT.app/Framework/Versions/Current")
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                bundle.writestr(link, "A")
            official_app.extract(archive, root / "unpacked")
            linked = root / "unpacked/ChatGPT.app/Framework/Versions/Current/binary"
            self.assertEqual(linked.read_text(), "fixture")
            self.assertEqual(linked.stat().st_mode & 0o777, 0o755)


if __name__ == "__main__":
    unittest.main()
