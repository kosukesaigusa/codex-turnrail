"""Keep product runtime evidence bound to official identities and complete scenarios."""

import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import verify_official_runtime
from official_runtime import LAYOUT_FILES
from product_evidence import SCENARIOS, verify_report
from project_metadata import ROOT, cli_version, read_upstream


def report_fixture():
    metadata = read_upstream(ROOT)
    return {
        "schema_version": 1,
        "official_engine": {
            "app": metadata["app"],
            "cli_version": cli_version(metadata),
            "signing_team": "2DC432GLL2",
            "binaries": {"codex": "a" * 64, "codex-code-mode-host": "b" * 64},
            "layout": "flat",
            "files": {
                "Contents/Resources/codex": "a" * 64,
                "Contents/Resources/codex-code-mode-host": "b" * 64,
            },
        },
        "router_sha256": "c" * 64,
        "scenarios": [{"case": name, "passed": True} for name in sorted(SCENARIOS)],
    }


class ProductEvidenceTests(unittest.TestCase):
    def test_packaged_evidence_requires_launcher_manifest_and_actual_binary_hashes(
        self,
    ):
        valid = report_fixture()
        engine = valid["official_engine"]
        engine["layout"] = "packageV1"
        paths = LAYOUT_FILES["packageV1"]
        engine["files"] = {path: "d" * 64 for path in paths.values()}
        engine["files"][paths["executable"]] = engine["binaries"]["codex"]
        engine["files"][paths["host"]] = engine["binaries"]["codex-code-mode-host"]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_text(json.dumps(valid))
            self.assertEqual(verify_report(path), valid)
            for field in paths:
                invalid = copy.deepcopy(valid)
                del invalid["official_engine"]["files"][paths[field]]
                path.write_text(json.dumps(invalid))
                with self.assertRaises(ValueError):
                    verify_report(path)
            invalid = copy.deepcopy(valid)
            invalid["official_engine"]["binaries"]["codex"] = "d" * 64
            path.write_text(json.dumps(invalid))
            with self.assertRaises(ValueError):
                verify_report(path)

    def test_report_requires_all_scenarios_once_and_valid_binary_hashes(self):
        valid = report_fixture()
        missing = copy.deepcopy(valid)
        missing["scenarios"].pop()
        duplicate = copy.deepcopy(valid)
        duplicate["scenarios"][0] = duplicate["scenarios"][1]
        failed = copy.deepcopy(valid)
        failed["scenarios"][0]["passed"] = False
        bad_hash = copy.deepcopy(valid)
        bad_hash["router_sha256"] = "not-a-digest"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "report.json"
            path.write_text(json.dumps(valid))
            self.assertEqual(verify_report(path), valid)
            for report in [missing, duplicate, failed, bad_hash]:
                with self.subTest(report=report):
                    path.write_text(json.dumps(report))
                    with self.assertRaises(ValueError):
                        verify_report(path)

    def test_skipped_fixture_or_changed_router_cannot_create_verification_report(self):
        for changed in [False, True]:
            with (
                self.subTest(changed=changed),
                tempfile.TemporaryDirectory() as temporary,
            ):
                root = Path(temporary)
                router = root / "router"
                router.write_bytes(b"original")
                report = root / "report.json"

                def fixture(*args, **kwargs):
                    proof = Path(kwargs["env"]["CODEX_TURNRAIL_TEST_PROOF"])
                    if changed:
                        proof.write_text(json.dumps(sorted(SCENARIOS)))
                        router.write_bytes(b"changed")
                    else:
                        proof.write_text("[]")

                with (
                    patch.object(
                        verify_official_runtime.official_app,
                        "verify",
                        return_value=report_fixture()["official_engine"],
                    ),
                    patch.object(
                        verify_official_runtime.subprocess, "run", side_effect=fixture
                    ),
                    self.assertRaises(ValueError),
                ):
                    verify_official_runtime.verify(
                        root / "ChatGPT.app", router, report, False
                    )
                self.assertFalse(report.exists())

    def test_missing_or_wrong_official_signature_stops_verification(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            report = report_fixture()
            report["official_engine"]["signing_team"] = "OTHER"
            path.write_text(json.dumps(report))
            with self.assertRaisesRegex(ValueError, "official OpenAI signature"):
                verify_report(path)

    def test_engine_only_report_is_not_product_routing_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text(json.dumps([{"case": "code_mode", "passed": True}]))
            with self.assertRaises(ValueError):
                verify_report(path)
