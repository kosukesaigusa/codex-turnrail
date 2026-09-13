"""Exercise release invariants before network publication or binary execution."""

import io
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import project_metadata as metadata
import release
from release_tag import require_ci


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "packaging").mkdir()
        self.info = {
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "26",
            "UnrelatedValue": "0.1.0",
        }
        (self.root / "packaging/Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_version_bump_changes_only_release_fields(self):
        release.bump(self.root, "0.2.0")
        self.assertEqual(
            plistlib.loads((self.root / "packaging/Info.plist").read_bytes()),
            {
                **self.info,
                "CFBundleShortVersionString": "0.2.0",
                "CFBundleVersion": "27",
            },
        )

    def test_invalid_or_nonincreasing_versions_preserve_metadata(self):
        path = self.root / "packaging/Info.plist"
        before = path.read_bytes()
        for version in ("0.1.0", "0.0.9", "0.2", "0.2.0-rc.1", "00.2.0"):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release.bump(self.root, version)
            self.assertEqual(path.read_bytes(), before)

    def test_tag_and_generated_contract_drift_are_rejected(self):
        upstream = metadata.read_upstream(metadata.ROOT)
        (self.root / "upstream.toml").write_bytes(metadata.metadata_bytes(upstream))
        cargo = self.root / "engine/codex-rs/Cargo.toml"
        cargo.parent.mkdir(parents=True)
        cargo.write_text(
            f'[workspace.package]\nversion = "{upstream["codex"]["tag"][6:]}"\n'
        )
        generated = self.root / metadata.GENERATED
        generated.parent.mkdir(parents=True)
        generated.write_text(metadata.supported_swift(upstream))
        metadata.validate(self.root, tag="v0.1.0")
        with self.assertRaisesRegex(ValueError, "Release tag"):
            metadata.validate(self.root, tag="v0.2.0")
        generated.write_text(
            generated.read_text().replace(upstream["app"]["build"], "99999")
        )
        with self.assertRaisesRegex(ValueError, "stale"):
            metadata.validate(self.root)

    def test_incomplete_or_failed_runtime_reports_are_rejected(self):
        path = self.root / "runtime.json"
        cases = [
            {"case": name, "passed": True}
            for name in ("code_mode", "approval_accept", "approval_decline")
        ]
        path.write_text(json.dumps(cases))
        release.verify_report(path)
        for report in (
            cases[:2],
            [cases[0], cases[0], cases[2]],
            [*cases[:2], {"case": "approval_decline", "passed": False}],
        ):
            path.write_text(json.dumps(report))
            with self.subTest(report=report), self.assertRaises(ValueError):
                release.verify_report(path)

    def test_corrupt_official_download_is_never_executed(self):
        upstream = metadata.read_upstream(metadata.ROOT)
        responses = [
            {"object": {"type": "commit", "sha": upstream["codex"]["commit"]}},
            {
                "draft": False,
                "prerelease": False,
                "assets": [
                    {
                        "name": "codex-aarch64-apple-darwin.tar.gz",
                        "digest": "sha256:" + "0" * 64,
                        "browser_download_url": "https://example.com/archive",
                        "size": 3,
                    }
                ],
            },
        ]
        with (
            patch.object(release, "github", side_effect=responses),
            patch.object(
                release.urllib.request, "urlopen", return_value=io.BytesIO(b"bad")
            ),
            patch.object(release, "check_cli") as execute,
            self.assertRaisesRegex(ValueError, "checksum"),
        ):
            release.download_cli(self.root / "codex", upstream)
        execute.assert_not_called()
        self.assertFalse((self.root / "codex").exists())

    def test_latest_exact_revision_ci_must_succeed(self):
        for conclusion, status in (
            ("failure", "completed"),
            (None, "in_progress"),
            ("cancelled", "completed"),
        ):
            with (
                self.subTest(conclusion=conclusion),
                patch(
                    "release_tag.github",
                    return_value={
                        "workflow_runs": [{"status": status, "conclusion": conclusion}]
                    },
                ),
                self.assertRaises(ValueError),
            ):
                require_ci("owner/repo", "a" * 40)
        with patch(
            "release_tag.github",
            return_value={
                "workflow_runs": [{"status": "completed", "conclusion": "success"}]
            },
        ):
            require_ci("owner/repo", "a" * 40)


if __name__ == "__main__":
    unittest.main()
