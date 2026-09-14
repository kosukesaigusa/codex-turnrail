"""Verify notarization acceptance, recovery, integrity, and credential cleanup."""

import base64
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import notarization
import release

SUBMISSION_ID = "abcd1234-1234-1234-1234-123456789abc"


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.output = Path(self.temporary.name)
        self.app = self.output / release.APP_NAME
        self.app.mkdir()
        (self.app / "binary").write_bytes(b"signed fixture executable")
        self.environment = {
            "MACOS_NOTARY_KEY_ID": "TESTKEY123",
            "MACOS_NOTARY_ISSUER_ID": "12345678-1234-1234-1234-123456789abc",
            "MACOS_NOTARY_KEY_BASE64": base64.b64encode(
                b"-----BEGIN PRIVATE KEY-----\nsynthetic test content\n"
            ).decode(),
        }
        self.calls = []
        self.key_paths = []
        self.status = "Accepted"
        self.fail_stapler = False
        self.fail_gatekeeper = False

    def execute(self, command, *, timeout):
        self.calls.append(command)
        if "--key" in command:
            key = Path(command[command.index("--key") + 1])
            self.assertTrue(key.is_file())
            self.assertEqual(key.stat().st_mode & 0o777, 0o600)
            self.assertEqual(key.parent.stat().st_mode & 0o777, 0o700)
            self.assertNotIn(self.environment["MACOS_NOTARY_KEY_BASE64"], command)
            self.key_paths.append(key)
        response = ""
        code = 0
        if command[0] == "ditto":
            Path(command[-1]).write_bytes(b"signed fixture archive")
        elif command[1:3] == ["notarytool", "submit"]:
            response = json.dumps({"id": SUBMISSION_ID})
        elif command[1:3] == ["notarytool", "wait"]:
            self.assertTrue((self.output / notarization.SUBMISSION).is_file())
            response = json.dumps({"id": SUBMISSION_ID, "status": self.status})
            code = 0 if self.status == "Accepted" else 2
        elif command[1:3] == ["notarytool", "log"]:
            Path(command[4]).write_text(json.dumps({"status": self.status}))
        elif command[1:3] == ["stapler", "staple"]:
            if self.fail_stapler:
                code = 65
            else:
                (self.app / "ticket").write_bytes(b"fixture ticket")
        elif command[0] == "spctl" and self.fail_gatekeeper:
            code = 3
        return subprocess.CompletedProcess(command, code, response, "")

    def test_accepted_app_is_stapled_verified_and_reused_without_resubmission(self):
        with patch.object(notarization, "execute", side_effect=self.execute):
            report = notarization.notarize(self.app, self.output, self.environment)
            self.assertEqual(report["status"], "Accepted")
            self.assertTrue(report["stapled"])
            self.assertTrue(report["gatekeeper_accepted"])
            self.assertEqual(
                report["bundle_sha256"], notarization.bundle_hash(self.app)
            )
            self.assertEqual(notarization.verify_report(self.app, self.output), report)
            self.assertEqual(notarization.notarize(self.app, self.output, {}), report)
        self.assertEqual(
            sum(call[1:3] == ["notarytool", "submit"] for call in self.calls), 1
        )
        self.assertTrue(any(call[0] == "spctl" for call in self.calls))
        self.assertTrue(all(not path.exists() for path in self.key_paths))

    def test_invalid_submission_preserves_log_and_never_staples(self):
        self.status = "Invalid"
        with patch.object(notarization, "execute", side_effect=self.execute):
            with self.assertRaisesRegex(ValueError, "is Invalid"):
                notarization.notarize(self.app, self.output, self.environment)
        self.assertTrue((self.output / notarization.LOG).is_file())
        self.assertFalse((self.output / notarization.REPORT).exists())
        self.assertFalse(any(call[1:3] == ["stapler", "staple"] for call in self.calls))
        self.assertTrue(all(not path.exists() for path in self.key_paths))

    def test_pending_submission_resumes_with_the_same_id(self):
        self.status = "In Progress"
        with patch.object(notarization, "execute", side_effect=self.execute):
            with self.assertRaisesRegex(ValueError, "In Progress"):
                notarization.notarize(self.app, self.output, self.environment)
            self.status = "Accepted"
            notarization.notarize(self.app, self.output, self.environment)
        submissions = [
            call for call in self.calls if call[1:3] == ["notarytool", "submit"]
        ]
        waits = [call for call in self.calls if call[1:3] == ["notarytool", "wait"]]
        self.assertEqual(len(submissions), 1)
        self.assertEqual([call[3] for call in waits], [SUBMISSION_ID, SUBMISSION_ID])

    def test_modified_app_or_uncertain_upload_is_not_submitted_again(self):
        self.status = "In Progress"
        with patch.object(notarization, "execute", side_effect=self.execute):
            with self.assertRaises(ValueError):
                notarization.notarize(self.app, self.output, self.environment)
            (self.app / "binary").write_bytes(b"changed")
            with self.assertRaisesRegex(ValueError, "does not match"):
                notarization.notarize(self.app, self.output, self.environment)
            (self.output / notarization.SUBMISSION).unlink()
            with self.assertRaisesRegex(ValueError, "without a submission ID"):
                notarization.notarize(self.app, self.output, self.environment)
        self.assertEqual(
            sum(call[1:3] == ["notarytool", "submit"] for call in self.calls), 1
        )

    def test_failed_stapling_and_changed_resources_never_verify(self):
        self.fail_stapler = True
        with patch.object(notarization, "execute", side_effect=self.execute):
            with self.assertRaisesRegex(ValueError, "exit code 65"):
                notarization.notarize(self.app, self.output, self.environment)
            self.assertFalse((self.output / notarization.REPORT).exists())
            self.fail_stapler = False
            notarization.notarize(self.app, self.output, self.environment)
            (self.app / "binary").chmod(0o755)
            with self.assertRaisesRegex(ValueError, "does not match"):
                notarization.verify_report(self.app, self.output)

    def test_credentials_fail_before_command_execution_and_cleanup_after_errors(self):
        with patch.object(notarization, "execute", side_effect=self.execute):
            with self.assertRaises(KeyError):
                notarization.preflight({})
            with self.assertRaisesRegex(ValueError, "invalid Base64"):
                notarization.preflight(
                    {**self.environment, "MACOS_NOTARY_KEY_BASE64": "!"}
                )
            self.assertEqual(self.calls, [])
        paths = []
        with self.assertRaisesRegex(RuntimeError, "synthetic failure"):
            with notarization.credentials(self.environment) as authentication:
                paths.append(Path(authentication[1]))
                raise RuntimeError("synthetic failure")
        self.assertFalse(paths[0].exists())

    def test_gatekeeper_failure_never_produces_a_verified_report(self):
        self.fail_gatekeeper = True
        with patch.object(notarization, "execute", side_effect=self.execute):
            with self.assertRaisesRegex(ValueError, "spctl failed"):
                notarization.notarize(self.app, self.output, self.environment)
        self.assertFalse((self.output / notarization.REPORT).exists())

    def test_remote_failure_does_not_echo_credential_values(self):
        sensitive = self.environment["MACOS_NOTARY_KEY_BASE64"]
        with patch.object(
            notarization,
            "execute",
            return_value=subprocess.CompletedProcess([], 1, sensitive, sensitive),
        ):
            with self.assertRaises(ValueError) as failure:
                notarization.preflight(self.environment)
        self.assertNotIn(sensitive, str(failure.exception))

    def test_archive_requires_notarized_manifest_and_unchanged_report(self):
        with patch.object(
            release, "validate_distribution", return_value={"notarized": False}
        ):
            with self.assertRaisesRegex(ValueError, "require a notarized app"):
                release.archive(self.output, "v0.1.0")
        (self.output / notarization.REPORT).write_text("changed report")
        with patch.object(
            release,
            "validate_distribution",
            return_value={"notarized": True, "notarization_report_sha256": "0" * 64},
        ):
            with self.assertRaisesRegex(ValueError, "report changed"):
                release.archive(self.output, "v0.1.0")
        self.assertFalse((self.output / "SHA256SUMS").exists())

    def test_every_executable_needs_developer_id_runtime_and_timestamp(self):
        fields = [
            "Authority=Developer ID Application: Example (ABCDEFGHIJ)",
            "flags=0x10000(runtime)",
            "Timestamp=Sep 14, 2026 at 9:00:00 AM",
        ]
        for missing in fields:
            with (
                self.subTest(missing=missing),
                patch.object(release, "validate_distribution", return_value={}),
                patch.object(
                    release.subprocess,
                    "run",
                    side_effect=[
                        subprocess.CompletedProcess([], 0, "", "\n".join(fields)),
                        subprocess.CompletedProcess(
                            [],
                            0,
                            "",
                            "\n".join(field for field in fields if field != missing),
                        ),
                    ],
                ),
                patch.object(notarization, "notarize") as submit,
                self.assertRaisesRegex(ValueError, "are required"),
            ):
                release.notarize(self.output, "v0.1.0")
            submit.assert_not_called()

    def test_archive_contains_the_verified_report_and_stapled_app(self):
        with patch.object(notarization, "execute", side_effect=self.execute):
            notarization.notarize(self.app, self.output, self.environment)
        manifest = {
            "notarized": True,
            "notarization_report_sha256": release.sha256(
                self.output / notarization.REPORT
            ),
        }
        (self.output / "build-manifest.json").write_text(json.dumps(manifest))
        (self.output / "runtime-verification.json").write_text("runtime evidence")

        def archive_command(command, **kwargs):
            self.assertTrue((Path(command[-2]) / "ticket").is_file())
            Path(command[-1]).write_bytes(b"final stapled archive")

        with (
            patch.object(release, "validate_distribution", return_value=manifest),
            patch.object(notarization, "execute", side_effect=self.execute),
            patch.object(release.subprocess, "run", side_effect=archive_command),
        ):
            artifacts = release.archive(self.output, "v0.1.0")
            with self.assertRaisesRegex(ValueError, "already exist"):
                release.archive(self.output, "v0.1.0")
        self.assertIn(self.output / notarization.REPORT, artifacts)
        sums = (self.output / "SHA256SUMS").read_text()
        self.assertIn(release.sha256(self.output / notarization.REPORT), sums)


if __name__ == "__main__":
    unittest.main()
