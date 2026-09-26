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
from official_runtime import LAYOUT_FILES
from project_metadata import ROOT, read_upstream
from test_official_runtime import app_fixture


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
            self.assertEqual(signature.call_count, 1)
            execute.assert_not_called()

    def test_layout_verifies_signatures_before_launch_and_hashes_actual_binary(
        self,
    ):
        metadata = read_upstream(ROOT)
        for layout, paths in LAYOUT_FILES.items():
            with (
                self.subTest(layout=layout),
                tempfile.TemporaryDirectory() as temporary,
            ):
                app = app_fixture(Path(temporary).resolve(), layout, metadata["app"])
                signatures = []

                def verify(command, **kwargs):
                    self.assertIn("--strict", command)
                    if not signatures:
                        self.assertIn('identifier "com.openai.codex"', command[4])
                    elif layout == "packageV1" and len(signatures) < 3:
                        self.assertIn('identifier "codex"', command[4])
                    signatures.append(command[-1])

                def execute(command, **kwargs):
                    expected = [str(app)]
                    if layout == "packageV1":
                        expected.append(
                            str(app / "Contents/Resources/codex-cli/CodexCLI.app")
                        )
                    expected.extend(
                        str(app / paths[key]) for key in ("executable", "host")
                    )
                    self.assertEqual(signatures, expected)
                    self.assertEqual(
                        command, [str(app / paths["launcher"]), "--version"]
                    )
                    return metadata["app"]["cli_version"] + "\n"

                with (
                    patch.object(official_app.subprocess, "run", side_effect=verify),
                    patch.object(
                        official_app.subprocess, "check_output", side_effect=execute
                    ),
                ):
                    evidence = official_app.verify(app, metadata)
                self.assertEqual(evidence["layout"], layout)
                self.assertEqual(set(evidence["files"]), set(paths.values()))
                self.assertEqual(
                    evidence["binaries"]["codex"],
                    official_app.sha256(app / paths["executable"]),
                )
                if layout == "packageV1":
                    self.assertNotEqual(
                        evidence["binaries"]["codex"],
                        official_app.sha256(app / paths["launcher"]),
                    )

    def test_any_packaged_signature_failure_prevents_launcher_execution(self):
        for failure in range(4):
            with (
                self.subTest(failure=failure),
                tempfile.TemporaryDirectory() as temporary,
            ):
                metadata = read_upstream(ROOT)
                app = app_fixture(Path(temporary), "packageV1", metadata["app"])
                with (
                    patch.object(
                        official_app.subprocess,
                        "run",
                        side_effect=[None] * failure
                        + [subprocess.CalledProcessError(1, "codesign")],
                    ),
                    patch.object(official_app.subprocess, "check_output") as execute,
                    self.assertRaises(subprocess.CalledProcessError),
                ):
                    official_app.verify(app, metadata)
                execute.assert_not_called()

    def test_manifest_version_must_match_the_executable_version(self):
        with tempfile.TemporaryDirectory() as temporary:
            metadata = read_upstream(ROOT)
            app = app_fixture(Path(temporary), "packageV1", metadata["app"])
            with (
                patch.object(official_app.subprocess, "run"),
                patch.object(
                    official_app.subprocess,
                    "check_output",
                    return_value="codex-cli 0.999.0",
                ),
                self.assertRaisesRegex(ValueError, "package manifest"),
            ):
                official_app.inspect(app, metadata["app"])

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
