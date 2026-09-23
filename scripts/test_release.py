"""Exercise release invariants before network publication or binary execution."""

import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import project_metadata as metadata
import release
from release_tag import require_ci
from test_product_evidence import report_fixture


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

    def test_official_engine_identity_must_match_the_supported_contract(self):
        upstream = metadata.read_upstream(metadata.ROOT)
        manifest = {
            "upstream": upstream,
            "engine": {
                "origin": "installed-official",
                "evidence": report_fixture()["official_engine"],
            },
        }
        release.validate_engine_source(manifest)
        manifest["engine"]["evidence"]["signing_team"] = "ANOTHERTEAM"
        with self.assertRaisesRegex(ValueError, "supported contract"):
            release.validate_engine_source(manifest)
        for origin in ("source-build", "verified-artifact", "unknown"):
            manifest["engine"]["origin"] = origin
            with self.assertRaisesRegex(
                ValueError, "unmodified installed official Engine"
            ):
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
        report = report_fixture()
        path.write_text(json.dumps(report))
        release.verify_report(path)
        cases = report["scenarios"]
        for invalid in (
            cases[:2],
            [cases[0]] * len(cases),
            [*cases[:-1], {"case": cases[-1]["case"], "passed": False}],
        ):
            report["scenarios"] = invalid
            path.write_text(json.dumps(report))
            with self.subTest(cases=invalid), self.assertRaises(ValueError):
                release.verify_report(path)

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
