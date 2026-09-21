"""Exercise release invariants before network publication or binary execution."""

import hashlib
import io
import json
import plistlib
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import project_metadata as metadata
import release
from engine_artifacts import digest, identity
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
        (self.root / metadata.VERSION_GENERATED).parent.mkdir(parents=True)
        metadata.write_product_version(self.root)

    def test_reused_engine_preserves_its_original_source_without_changing_app_source(
        self,
    ):
        source_inputs = {
            name: "c" * 40
            for name in ("engine", ".github", "scripts", "tests", "justfile")
        }
        inputs = identity(source_inputs, {"rustc": "fixture"})
        manifest = {
            "source_commit": "a" * 40,
            "profile": "release",
            "engine": {
                "origin": "verified-artifact",
                "evidence": {
                    "schema_version": 1,
                    "kind": "verified",
                    "identity": inputs,
                    "key": digest(inputs),
                    "source_commit": "b" * 40,
                    "workflow_commit": "b" * 40,
                },
            },
        }
        with patch(
            "engine_artifacts.source_inputs", return_value=source_inputs
        ) as read:
            release.validate_engine_source(manifest)
        read.assert_called_once_with(release.ROOT, "a" * 40)
        self.assertEqual(manifest["engine"]["evidence"]["source_commit"], "b" * 40)
        self.assertEqual(manifest["source_commit"], "a" * 40)
        with (
            patch("engine_artifacts.source_inputs", return_value={}),
            self.assertRaisesRegex(ValueError, "Engine inputs"),
        ):
            release.validate_engine_source(manifest)

    def test_source_build_and_unknown_origins_cannot_hide_source_drift(self):
        manifest = {
            "source_commit": "a" * 40,
            "profile": "release",
            "engine": {
                "origin": "source-build",
                "source_commit": "a" * 40,
                "profile": "release",
            },
        }
        release.validate_engine_source(manifest)
        manifest["engine"]["source_commit"] = "b" * 40
        with self.assertRaisesRegex(ValueError, "source and profile"):
            release.validate_engine_source(manifest)
        manifest["engine"]["origin"] = "unknown"
        with self.assertRaisesRegex(ValueError, "unknown Engine origin"):
            release.validate_engine_source(manifest)

    def test_reused_engine_cannot_weaken_exact_tagged_app_source_validation(self):
        manifest = {
            "version": "0.3.0",
            "build": "29",
            "profile": "release",
            "dirty": False,
            "source_commit": "a" * 40,
            "signing_authorities": ["Developer ID Application: Fixture"],
        }
        (self.root / "build-manifest.json").write_text(release.json.dumps(manifest))
        with (
            patch.object(
                release, "validate", return_value={"version": "0.3.0", "build": "29"}
            ),
            patch.object(release, "run", return_value="b" * 40),
            patch.object(release, "validate_engine_source") as engine,
            patch.object(release.subprocess, "run") as signature,
            self.assertRaisesRegex(ValueError, "different source revision"),
        ):
            release.validate_distribution(self.root, "v0.3.0")
        engine.assert_not_called()
        signature.assert_not_called()

    def test_version_bump_updates_the_displayed_version_and_preserves_other_fields(
        self,
    ):
        release.bump(self.root, "0.2.0")
        self.assertEqual(
            plistlib.loads((self.root / "packaging/Info.plist").read_bytes()),
            {
                **self.info,
                "CFBundleShortVersionString": "0.2.0",
                "CFBundleVersion": "27",
            },
        )
        self.assertIn(
            'static let current = "0.2.0"',
            (self.root / metadata.VERSION_GENERATED).read_text(),
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
        displayed_version = self.root / metadata.VERSION_GENERATED
        displayed_version.write_text(metadata.product_version_swift("0.0.9"))
        with self.assertRaisesRegex(ValueError, "Turnrail app version is stale"):
            metadata.validate(self.root)
        metadata.write_product_version(self.root)
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
        source = {
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
        }
        with (
            patch.object(
                release,
                "github",
                return_value={
                    "object": {"type": "commit", "sha": upstream["codex"]["commit"]}
                },
            ),
            patch.object(release, "source_release", return_value=source),
            patch.object(
                release.urllib.request, "urlopen", return_value=io.BytesIO(b"bad")
            ),
            patch.object(release, "check_cli") as execute,
            self.assertRaisesRegex(ValueError, "checksum"),
        ):
            release.download_cli(self.root / "codex", upstream)
        execute.assert_not_called()
        self.assertFalse((self.root / "codex").exists())

    def test_pinned_prerelease_download_keeps_commit_checksum_and_version_gates(self):
        upstream = metadata.read_upstream(metadata.ROOT)
        upstream["codex"]["tag"] = "rust-v0.154.0-alpha.6.2"
        content = b"fixture binary"
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            member = tarfile.TarInfo("codex-aarch64-apple-darwin")
            member.size = len(content)
            archive.addfile(member, io.BytesIO(content))
        data = buffer.getvalue()
        source = {
            "tag_name": upstream["codex"]["tag"],
            "draft": False,
            "prerelease": True,
            "assets": [
                {
                    "name": "codex-aarch64-apple-darwin.tar.gz",
                    "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                    "browser_download_url": "https://example.com/archive",
                    "size": len(data),
                }
            ],
        }
        output = self.root / "codex"
        with (
            patch.object(
                release,
                "github",
                return_value={
                    "object": {"type": "commit", "sha": upstream["codex"]["commit"]}
                },
            ),
            patch.object(release, "source_release", return_value=source) as source_api,
            patch.object(
                release.urllib.request, "urlopen", return_value=io.BytesIO(data)
            ),
            patch.object(
                release, "run", return_value="codex-cli 0.154.0-alpha.6.2"
            ) as execute,
        ):
            release.download_cli(output, upstream)
        source_api.assert_called_once_with("rust-v0.154.0-alpha.6.2")
        execute.assert_called_once()
        self.assertEqual(output.read_bytes(), content)

    def test_changed_source_commit_stops_before_downloading_a_release(self):
        upstream = metadata.read_upstream(metadata.ROOT)
        with (
            patch.object(
                release,
                "github",
                return_value={"object": {"type": "commit", "sha": "0" * 40}},
            ),
            patch.object(release, "source_release") as source_api,
            self.assertRaisesRegex(ValueError, "pinned source commit"),
        ):
            release.download_cli(self.root / "codex", upstream)
        source_api.assert_not_called()

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
                        "workflow_runs": [
                            {
                                "event": "push",
                                "status": status,
                                "conclusion": conclusion,
                            }
                        ]
                    },
                ),
                self.assertRaises(ValueError),
            ):
                require_ci("owner/repo", "a" * 40)
        with patch(
            "release_tag.github",
            return_value={
                "workflow_runs": [
                    {"event": "push", "status": "completed", "conclusion": "success"}
                ]
            },
        ):
            require_ci("owner/repo", "a" * 40)


if __name__ == "__main__":
    unittest.main()
