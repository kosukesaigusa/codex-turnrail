"""Keep unpublished releases tied to the verified bytes uploaded to GitHub."""

import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import release_delivery as delivery
from test_product_evidence import report_fixture


class ReleaseDeliveryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.output = Path(temporary.name)
        self.tag = "v0.2.1"
        self.repository = "owner/repo"
        self.archive_name = f"Codex-Turnrail-{self.tag}-macos-arm64.zip"
        self.contents = b"verified archive contents"
        self.digest = hashlib.sha256(self.contents).hexdigest()
        self.commit = "a" * 40
        self.manifest = {
            "version": "0.2.1",
            "build": "28",
            "source_commit": self.commit,
            "notarized": True,
            "signing_authorities": ["Developer ID Application: Fixture"],
            "upstream": {"app": {"version": "26.908.40834", "build": "8881"}},
        }
        (self.output / self.archive_name).write_bytes(self.contents)
        (self.output / "build-manifest.json").write_text(json.dumps(self.manifest))
        (self.output / "runtime-verification.json").write_text(
            json.dumps(report_fixture())
        )
        (self.output / "notarization-report.json").write_text(
            json.dumps({"status": "Accepted", "stapled": True})
        )
        self.write_checksums()
        delivery.prepare_notes(self.output, self.repository, self.tag)
        self.remote = {
            "id": 42,
            "tag_name": self.tag,
            "target_commitish": self.commit,
            "name": "Codex Turnrail v0.2.1",
            "draft": True,
            "prerelease": False,
            "body": (self.output / "notes.md").read_text()
            + "\n## What's Changed\n\n- Existing PR notes.\n",
            "assets": [
                {
                    "id": 123,
                    "name": self.archive_name,
                    "state": "uploaded",
                    "digest": "sha256:" + self.digest,
                    "size": len(self.contents),
                }
            ],
        }
        self.updates = []
        self.enterContext(patch.object(delivery, "github", side_effect=self.github))
        self.lookup = self.enterContext(
            patch.object(
                delivery.subprocess,
                "check_output",
                return_value=json.dumps({"databaseId": 42}),
            )
        )
        self.download = self.enterContext(
            patch.object(delivery, "download_asset", side_effect=self.download_asset)
        )

    def write_checksums(self):
        names = (
            self.archive_name,
            "build-manifest.json",
            "runtime-verification.json",
            "notarization-report.json",
        )
        checksums = []
        for name in names:
            digest = hashlib.sha256((self.output / name).read_bytes()).hexdigest()
            checksums.append(f"{digest}  {name}\n")
        (self.output / "SHA256SUMS").write_text("".join(checksums))

    def github(self, endpoint, *, method="GET", payload=None):
        self.assertEqual(endpoint, "repos/owner/repo/releases/42")
        if method == "PATCH":
            self.updates.append(copy.deepcopy(payload))
            self.remote.update(payload)
        else:
            self.assertEqual(method, "GET")
        return copy.deepcopy(self.remote)

    def download_asset(self, repository, asset_id, destination):
        self.assertEqual((repository, asset_id), (self.repository, 123))
        self.assertFalse(destination.exists())
        destination.write_bytes(self.contents)

    def verify(self):
        return delivery.verify_upload(self.output, self.repository, self.tag)

    def assert_no_success(self):
        self.assertEqual(self.updates, [])
        self.assertFalse((self.output / delivery.REPORT).exists())

    def test_notes_offer_one_download_and_record_versions_hash_and_pending_status(self):
        notes = (self.output / "notes.md").read_text()
        self.assertIn(
            f"https://github.com/owner/repo/releases/download/{self.tag}/{self.archive_name}",
            notes,
        )
        self.assertEqual(notes.count("]("), 1)
        self.assertIn(f"SHA-256: `{self.digest}`", notes)
        self.assertIn(self.commit, notes)
        self.assertIn("0.2.1 (28)", notes)
        self.assertIn("26.908.40834 (8881)", notes)
        self.assertIn(delivery.PENDING, notes)
        self.assertNotIn(delivery.PASSED, notes)

    def test_success_preserves_tag_commit_draft_asset_and_generated_pr_notes(self):
        original_asset = copy.deepcopy(self.remote["assets"])
        report = self.verify()
        self.assertEqual(report["sha256"], self.digest)
        self.assertEqual(report["size"], len(self.contents))
        self.assertEqual(report["asset_id"], 123)
        self.assertEqual(report["source_commit"], self.commit)
        self.assertTrue(report["passed"])
        self.assertEqual(
            json.loads((self.output / delivery.REPORT).read_text()), report
        )
        self.assertEqual(len(self.updates), 1)
        self.assertEqual(self.updates[0]["tag_name"], self.tag)
        self.assertEqual(self.updates[0]["target_commitish"], self.commit)
        self.assertIs(self.updates[0]["draft"], True)
        self.assertIs(self.updates[0]["prerelease"], False)
        self.assertEqual(self.remote["assets"], original_asset)
        self.assertIn(delivery.PASSED, self.remote["body"])
        self.assertNotIn(delivery.PENDING, self.remote["body"])
        self.assertIn("- Existing PR notes.", self.remote["body"])

    def test_corrupt_or_truncated_download_never_marks_a_draft_verified(self):
        for contents in (b"", b"x" * len(self.contents)):
            with self.subTest(download=contents):
                self.download.side_effect = lambda repository, asset_id, destination: (
                    destination.write_bytes(contents)
                )
                with self.assertRaisesRegex(ValueError, "downloaded asset differs"):
                    self.verify()
                self.assert_no_success()

    def test_download_error_preserves_pending_status(self):
        self.download.side_effect = subprocess.CalledProcessError(1, ["gh", "api"])
        with self.assertRaises(subprocess.CalledProcessError):
            self.verify()
        self.assert_no_success()
        self.assertIn(delivery.PENDING, self.remote["body"])

    def test_wrong_release_or_asset_is_rejected_before_downloading(self):
        original = copy.deepcopy(self.remote)
        candidates = []
        for field, value in (
            ("id", 43),
            ("draft", False),
            ("prerelease", True),
            ("tag_name", "v0.2.2"),
            ("target_commitish", "b" * 40),
            ("assets", []),
            ("assets", original["assets"] * 2),
        ):
            candidates.append({**original, field: value})
        for field, value in (
            ("name", "other.zip"),
            ("digest", None),
            ("digest", "sha256:" + "0" * 64),
            ("size", len(self.contents) + 1),
            ("state", "starter"),
            ("id", -1),
        ):
            candidates.append(
                {**original, "assets": [{**original["assets"][0], field: value}]}
            )
        for candidate in candidates:
            with self.subTest(remote=candidate):
                self.remote = candidate
                with self.assertRaises(ValueError):
                    self.verify()
                self.download.assert_not_called()
                self.assert_no_success()

    def test_changed_local_archive_is_rejected_before_using_github(self):
        (self.output / self.archive_name).write_bytes(b"different local archive")
        with self.assertRaisesRegex(ValueError, "changed before delivery"):
            self.verify()
        self.lookup.assert_not_called()
        self.assert_no_success()

    def test_incomplete_duplicate_or_malformed_checksums_are_rejected(self):
        path = self.output / "SHA256SUMS"
        original = path.read_text()
        for contents in (
            "not a checksum\n",
            "\n".join(original.splitlines()[:-1]) + "\n",
            original + original.splitlines()[0] + "\n",
            original + "0" * 64 + "  ../unexpected.zip\n",
        ):
            with self.subTest(checksums=contents):
                path.write_text(contents)
                with self.assertRaises(ValueError):
                    self.verify()
                self.lookup.assert_not_called()
                self.assert_no_success()

    def test_unnotarized_manifest_and_failed_runtime_cannot_prepare_notes(self):
        notes = self.output / "notes.md"
        notes.unlink()
        self.manifest["notarized"] = False
        manifest_path = self.output / "build-manifest.json"
        manifest_path.write_text(json.dumps(self.manifest))
        self.write_checksums()
        with self.assertRaisesRegex(ValueError, "notarized release"):
            delivery.prepare_notes(self.output, self.repository, self.tag)
        self.assertFalse(notes.exists())
        self.manifest["notarized"] = True
        manifest_path.write_text(json.dumps(self.manifest))
        runtime = self.output / "runtime-verification.json"
        cases = json.loads(runtime.read_text())
        cases["scenarios"][0]["passed"] = False
        runtime.write_text(json.dumps(cases))
        self.write_checksums()
        with self.assertRaisesRegex(ValueError, "must pass"):
            delivery.prepare_notes(self.output, self.repository, self.tag)
        self.assertFalse(notes.exists())

    def test_saved_release_drift_does_not_create_success_evidence(self):
        def changing_github(endpoint, *, method="GET", payload=None):
            result = self.github(endpoint, method=method, payload=payload)
            if method == "PATCH":
                self.remote["tag_name"] = "untagged-unexpected"
            return result

        with patch.object(delivery, "github", side_effect=changing_github):
            with self.assertRaisesRegex(ValueError, "exact source"):
                self.verify()
        self.assertFalse((self.output / delivery.REPORT).exists())

    def test_existing_success_evidence_is_never_reused_or_replaced(self):
        self.verify()
        path = self.output / delivery.REPORT
        original = path.read_bytes()
        self.lookup.reset_mock()
        self.download.reset_mock()
        with self.assertRaisesRegex(ValueError, "already exists"):
            self.verify()
        self.lookup.assert_not_called()
        self.download.assert_not_called()
        self.assertEqual(path.read_bytes(), original)
        self.assertEqual(len(self.updates), 1)


if __name__ == "__main__":
    unittest.main()
