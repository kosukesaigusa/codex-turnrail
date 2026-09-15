"""Exercise reuse, provenance, and artifact safety without executing binaries."""

import copy
import io
import json
import os
import subprocess
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import engine_artifacts as artifacts

REPO = "example/turnrail"
SOURCE = "a" * 40
WORKFLOW_SOURCE = "b" * 40
INPUTS = {scope: f"{index:040x}" for index, scope in enumerate(artifacts.SCOPES)}
IDENTITY = artifacts.identity(INPUTS, {"rustc": "1.95.0", "image_version": "fixture"})
ENVIRONMENT = {
    "GITHUB_REPOSITORY": REPO,
    "GITHUB_WORKFLOW_SHA": WORKFLOW_SOURCE,
    "GITHUB_RUN_ID": "123",
    "GITHUB_RUN_ATTEMPT": "1",
}
REPORT = [
    {"case": case, "passed": True}
    for case in ("code_mode", "approval_accept", "approval_decline")
]
JUNIT = (
    '<testsuites tests="1" failures="0" errors="0"><testsuite>'
    '<testcase name="fixture"/></testsuite></testsuites>'
)


def run_data():
    return {
        "id": 123,
        "run_attempt": 1,
        "repository": {"full_name": REPO},
        "head_repository": {"full_name": REPO},
        "path": ".github/workflows/ci.yml",
        "event": "pull_request",
        "head_branch": "feature/example",
        "status": "completed",
        "conclusion": "success",
        "referenced_workflows": [
            {
                "path": f"{REPO}/{artifacts.WORKFLOW}@{WORKFLOW_SOURCE}",
                "sha": WORKFLOW_SOURCE,
            }
        ],
    }


def artifact_data():
    return {
        "id": 456,
        "name": artifacts.artifact_name("verified", artifacts.digest(IDENTITY), 1),
        "expired": False,
        "workflow_run": {"id": 123, "repository_id": 1, "head_repository_id": 1},
    }


class IdentityTests(unittest.TestCase):
    def test_only_effective_inputs_are_hashed_across_product_commits(self):
        with patch.object(
            artifacts,
            "git",
            side_effect=lambda root, command, ref: INPUTS[ref.split(":")[1]],
        ) as git:
            first = artifacts.identity(
                artifacts.source_inputs(Path("."), SOURCE), IDENTITY["runner"]
            )
            second = artifacts.identity(
                artifacts.source_inputs(Path("."), WORKFLOW_SOURCE), IDENTITY["runner"]
            )
        self.assertEqual(artifacts.digest(first), artifacts.digest(second))
        self.assertFalse(
            any(
                "Info.plist" in call.args[-1]
                or "upstream.toml" in call.args[-1]
                or "README.md" in call.args[-1]
                for call in git.call_args_list
            )
        )
        self.assertIn(".github/workflows/engine-checks.yml", first["source_inputs"])
        self.assertNotIn(".github/workflows/upstream.yml", first["source_inputs"])
        self.assertNotIn(".github", first["source_inputs"])

    def test_every_engine_tooling_validation_and_runner_change_invalidates_reuse(self):
        for key in INPUTS:
            with self.subTest(scope=key):
                value = artifacts.identity(
                    {**INPUTS, key: "f" * 40}, IDENTITY["runner"]
                )
                self.assertNotEqual(artifacts.digest(IDENTITY), artifacts.digest(value))
        for field in IDENTITY["runner"]:
            value = artifacts.identity(INPUTS, {**IDENTITY["runner"], field: "changed"})
            self.assertNotEqual(artifacts.digest(IDENTITY), artifacts.digest(value))

    def test_uncommitted_or_mismatched_checkout_cannot_claim_a_committed_identity(self):
        with (
            patch.dict(os.environ, {"ENGINE_IDENTITY": json.dumps(IDENTITY)}),
            patch.object(artifacts, "source_inputs", return_value=INPUTS),
        ):
            with (
                patch.object(
                    artifacts,
                    "git",
                    side_effect=[SOURCE, " M scripts/engine_artifacts.py"],
                ),
                self.assertRaisesRegex(ValueError, "clean committed"),
            ):
                artifacts.expected_identity()
            with (
                patch.object(artifacts, "git", return_value=SOURCE),
                patch.object(artifacts, "source_inputs", return_value={}),
                self.assertRaisesRegex(ValueError, "do not match"),
            ):
                artifacts.expected_identity()

    def test_external_compiler_flags_cannot_bypass_the_runner_contract(self):
        for name in (
            "RUSTFLAGS",
            "CARGO_PROFILE_RELEASE_LTO",
            "CC",
            "RUSTY_V8_ARCHIVE",
        ):
            with (
                self.subTest(name=name),
                patch.dict(
                    os.environ, {"GITHUB_ACTIONS": "true", name: "override"}, clear=True
                ),
                patch.object(artifacts.platform, "system", return_value="Darwin"),
                patch.object(artifacts.platform, "machine", return_value="arm64"),
                self.assertRaisesRegex(ValueError, "external build override"),
            ):
                artifacts.runner_contract()


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.directory = self.root / "evidence"
        self.directory.mkdir()
        for name in ("ci-runtime.json", "release-runtime.json"):
            (self.directory / name).write_text(json.dumps(REPORT))
        (self.directory / "junit.xml").write_text(JUNIT)
        (self.directory / "runtime.tar.gz").write_bytes(b"fixture archive")
        with (
            patch.dict(os.environ, ENVIRONMENT),
            patch.object(artifacts, "git", return_value=SOURCE),
        ):
            self.manifest = artifacts.write_manifest(
                self.directory, IDENTITY, "verified"
            )

    def test_complete_evidence_binds_reports_and_unsigned_runtime_to_its_inputs(self):
        self.assertEqual(
            artifacts.read_manifest(self.directory, IDENTITY, "verified"), self.manifest
        )
        self.assertEqual(self.manifest["source_commit"], SOURCE)
        self.assertEqual(
            self.manifest["files"]["runtime.tar.gz"],
            artifacts.sha256(self.directory / "runtime.tar.gz"),
        )

    def test_modified_missing_and_additional_files_are_rejected(self):
        path = self.directory / "runtime.tar.gz"
        path.write_bytes(b"different binary")
        with self.assertRaisesRegex(ValueError, "checksum"):
            artifacts.read_manifest(self.directory, IDENTITY, "verified")
        path.unlink()
        with self.assertRaisesRegex(ValueError, "missing"):
            artifacts.read_manifest(self.directory, IDENTITY, "verified")
        path.write_bytes(b"fixture archive")
        (self.directory / "unrecorded").write_text("extra")
        with self.assertRaisesRegex(ValueError, "Unexpected"):
            artifacts.read_manifest(self.directory, IDENTITY, "verified")

    def test_failing_runtime_cannot_be_blessed_by_recalculating_checksums(self):
        report = copy.deepcopy(REPORT)
        report[0]["passed"] = False
        (self.directory / "release-runtime.json").write_text(json.dumps(report))
        with (
            patch.dict(os.environ, ENVIRONMENT),
            patch.object(artifacts, "git", return_value=SOURCE),
            self.assertRaisesRegex(ValueError, "scenario must pass"),
        ):
            artifacts.write_manifest(self.directory, IDENTITY, "verified")

    def test_empty_failed_or_incomplete_junit_is_not_success_evidence(self):
        invalid = (
            '<testsuites tests="0" failures="0" errors="0"/>',
            JUNIT.replace('failures="0"', 'failures="1"'),
            JUNIT.replace('errors="0"', 'errors="1"'),
            JUNIT.replace('tests="1"', 'tests="2"'),
            JUNIT.replace(
                '<testcase name="fixture"/>', "<testcase><failure/></testcase>"
            ),
        )
        for data in invalid:
            with self.subTest(xml=data), self.assertRaises(ValueError):
                path = self.root / "junit.xml"
                path.write_text(data)
                artifacts.verify_junit(path)

    def test_equivalent_source_can_be_reused_from_a_previous_commit(self):
        with patch.object(artifacts, "remote_inputs", return_value=INPUTS) as remote:
            artifacts.verify_provenance(
                self.manifest, artifact_data(), run_data(), REPO, IDENTITY
            )
        self.assertEqual(
            {call.args[1] for call in remote.call_args_list}, {SOURCE, WORKFLOW_SOURCE}
        )

    def test_forged_inputs_workflow_run_attempt_or_artifact_name_are_rejected(self):
        mutations = (
            ("manifest", "run_id", 999),
            ("manifest", "run_attempt", 2),
            ("manifest", "workflow_commit", "c" * 40),
            ("artifact", "name", "unrelated"),
            ("run", "referenced_workflows", []),
        )
        for target, key, value in mutations:
            data = {
                "manifest": copy.deepcopy(self.manifest),
                "artifact": artifact_data(),
                "run": run_data(),
            }
            data[target][key] = value
            with (
                self.subTest(target=target, key=key),
                patch.object(artifacts, "remote_inputs", return_value=INPUTS),
                self.assertRaises(ValueError),
            ):
                artifacts.verify_provenance(
                    data["manifest"], data["artifact"], data["run"], REPO, IDENTITY
                )
        with (
            patch.object(
                artifacts,
                "remote_inputs",
                return_value={**INPUTS, ".github/workflows/engine.yml": "c" * 40},
            ),
            self.assertRaisesRegex(ValueError, "workflow inputs differ"),
        ):
            artifacts.verify_provenance(
                self.manifest, artifact_data(), run_data(), REPO, IDENTITY
            )

    def test_archive_digest_is_checked_before_extracting_any_file(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr("manifest.json", "{}")
        archive_bytes = data.getvalue()
        metadata = {
            **artifact_data(),
            "digest": "sha256:" + "0" * 64,
            "size_in_bytes": len(archive_bytes),
        }

        def download(command, *, stdout, **kwargs):
            stdout.write(archive_bytes)

        with (
            patch.object(artifacts.subprocess, "run", side_effect=download),
            self.assertRaisesRegex(ValueError, "checksum"),
        ):
            artifacts.download(metadata, REPO, self.root / "download")
        self.assertFalse((self.root / "download").exists())

    def test_download_rejects_path_traversal_even_with_matching_github_digest(self):
        data = io.BytesIO()
        with zipfile.ZipFile(data, "w") as archive:
            archive.writestr("../escaped", "unsafe")
        archive_bytes = data.getvalue()
        metadata = {
            **artifact_data(),
            "digest": "sha256:" + artifacts.hashlib.sha256(archive_bytes).hexdigest(),
            "size_in_bytes": len(archive_bytes),
        }

        def download(command, *, stdout, **kwargs):
            stdout.write(archive_bytes)

        with (
            patch.object(artifacts.subprocess, "run", side_effect=download),
            self.assertRaisesRegex(ValueError, "unsafe"),
        ):
            artifacts.download(metadata, REPO, self.root / "download")
        self.assertFalse((self.root / "escaped").exists())

    def test_runtime_round_trip_preserves_executable_modes(self):
        runtime = self.root / "runtime"
        for name in artifacts.RUNTIME_BINARIES:
            path = runtime / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"fixture executable")
            path.chmod(0o755)
        (runtime / "codex-package.json").write_text("{}")
        archive = self.root / "runtime.tar.gz"
        artifacts.pack_runtime(runtime, archive)
        destination = self.root / "installed"
        artifacts.unpack_runtime(archive, destination)
        for name in artifacts.RUNTIME_BINARIES:
            self.assertEqual(
                (runtime / name).read_bytes(), (destination / name).read_bytes()
            )
            self.assertTrue(os.access(destination / name, os.X_OK))

    def test_verified_transport_round_trip_preserves_the_selected_engine(self):
        runtime = self.root / "built-runtime"
        for name in artifacts.RUNTIME_BINARIES:
            executable = runtime / name
            executable.parent.mkdir(parents=True, exist_ok=True)
            executable.write_bytes(b"tested binary")
            executable.chmod(0o755)
        (self.directory / "runtime.tar.gz").unlink()
        artifacts.pack_runtime(runtime, self.directory / "runtime.tar.gz")
        with (
            patch.dict(os.environ, ENVIRONMENT),
            patch.object(artifacts, "git", return_value=SOURCE),
        ):
            artifacts.write_manifest(self.directory, IDENTITY, "verified")
        payload = io.BytesIO()
        with zipfile.ZipFile(payload, "w") as archive:
            for path in self.directory.iterdir():
                archive.write(path, path.name)
        data = payload.getvalue()
        artifact = {
            **artifact_data(),
            "size_in_bytes": len(data),
            "digest": "sha256:" + artifacts.hashlib.sha256(data).hexdigest(),
        }

        def api(endpoint):
            if "actions/artifacts/456" in endpoint:
                return artifact
            if "actions/runs/123" in endpoint:
                return run_data()
            raise AssertionError(endpoint)

        def transfer(command, *, stdout, **kwargs):
            stdout.write(data)

        destination = self.root / "downloaded"
        with (
            patch.object(artifacts, "github", side_effect=api),
            patch.object(artifacts.subprocess, "run", side_effect=transfer),
            patch.object(artifacts, "remote_inputs", return_value=INPUTS),
        ):
            manifest = artifacts.restore(REPO, 456, IDENTITY, destination)
        artifacts.unpack_runtime(
            destination / "runtime.tar.gz", self.root / "assembled-runtime"
        )
        self.assertEqual(manifest["source_commit"], SOURCE)
        for name in artifacts.RUNTIME_BINARIES:
            self.assertEqual(
                (self.root / "assembled-runtime" / name).read_bytes(), b"tested binary"
            )

    def test_unsafe_runtime_paths_and_links_are_rejected_before_extraction(self):
        for name, kind in (
            ("../escape", tarfile.REGTYPE),
            ("/escape", tarfile.REGTYPE),
            ("link", tarfile.SYMTYPE),
            ("link", tarfile.LNKTYPE),
        ):
            with self.subTest(name=name, kind=kind):
                archive = self.root / "unsafe.tar.gz"
                with tarfile.open(archive, "w:gz") as bundle:
                    member = tarfile.TarInfo(name)
                    member.type = kind
                    member.linkname = "/tmp/escape"
                    bundle.addfile(member)
                with self.assertRaisesRegex(ValueError, "unsafe"):
                    artifacts.unpack_runtime(archive, self.root / "installed")
                self.assertFalse((self.root / "installed").exists())


class PlanningTests(unittest.TestCase):
    def api(self, artifact, run):
        def response(endpoint):
            if "actions/artifacts?" in endpoint:
                return {"artifacts": [artifact]}
            if "actions/runs/" in endpoint:
                return run
            raise AssertionError(endpoint)

        return response

    def test_unchanged_engine_reuses_evidence_instead_of_running_builds(self):
        with (
            patch.object(
                artifacts, "github", side_effect=self.api(artifact_data(), run_data())
            ),
            patch.object(artifacts, "restore") as restore,
        ):
            result = artifacts.find_artifact(REPO, IDENTITY, 999)
        self.assertEqual(result["mode"], "reuse")
        self.assertEqual(result["artifact_id"], "456")
        restore.assert_called_once()

    def test_missing_expired_failed_fork_and_wrong_attempt_select_explicit_build(self):
        cases = []
        expired = artifact_data()
        expired["expired"] = True
        cases.append((expired, run_data()))
        fork = artifact_data()
        fork["workflow_run"]["head_repository_id"] = 2
        cases.append((fork, run_data()))
        for conclusion in ("failure", "cancelled", "skipped", "neutral"):
            run = run_data()
            run["conclusion"] = conclusion
            cases.append((artifact_data(), run))
        run = run_data()
        run["run_attempt"] = 2
        cases.append((artifact_data(), run))
        different = artifact_data()
        different["name"] = artifacts.artifact_name("verified", "c" * 64, 1)
        cases.append((different, run_data()))
        for artifact, run in cases:
            with (
                self.subTest(artifact=artifact["name"], run=run["conclusion"]),
                patch.object(artifacts, "github", side_effect=self.api(artifact, run)),
                patch.object(artifacts, "restore") as restore,
            ):
                self.assertEqual(
                    artifacts.find_artifact(REPO, IDENTITY, 999)["mode"], "build"
                )
                restore.assert_not_called()
        with patch.object(artifacts, "github", return_value={"artifacts": []}):
            self.assertEqual(
                artifacts.find_artifact(REPO, IDENTITY, 999)["mode"], "build"
            )

    def test_corrupt_or_unavailable_selected_evidence_fails_instead_of_rebuilding(self):
        for error in (
            ValueError("checksum mismatch"),
            subprocess.CalledProcessError(1, "gh"),
        ):
            with (
                self.subTest(error=error),
                patch.object(
                    artifacts,
                    "github",
                    side_effect=self.api(artifact_data(), run_data()),
                ),
                patch.object(artifacts, "restore", side_effect=error),
                self.assertRaises(type(error)),
            ):
                artifacts.find_artifact(REPO, IDENTITY, 999)

    def test_duplicate_waits_for_successful_parent_ci_completion(self):
        running = run_data()
        running.update(status="in_progress", conclusion=None)
        with (
            patch.object(
                artifacts,
                "github",
                side_effect=[{"artifacts": [artifact_data()]}, running, run_data()],
            ),
            patch.object(artifacts, "restore"),
            patch.object(artifacts.time, "sleep") as sleep,
        ):
            self.assertEqual(
                artifacts.find_artifact(REPO, IDENTITY, 999)["mode"], "reuse"
            )
        sleep.assert_called_once_with(5)

    def test_pagination_finds_an_older_retained_matching_engine(self):
        irrelevant = {"name": "other", "expired": False}
        with (
            patch.object(
                artifacts,
                "github",
                side_effect=[
                    {"artifacts": [irrelevant] * 100},
                    {"artifacts": [artifact_data()]},
                    run_data(),
                ],
            ) as api,
            patch.object(artifacts, "restore"),
        ):
            self.assertEqual(
                artifacts.find_artifact(REPO, IDENTITY, 999)["mode"], "reuse"
            )
        self.assertIn("page=2", api.call_args_list[1].args[0])

    def test_wait_timeout_does_not_start_a_competing_build(self):
        run = run_data()
        run.update(status="in_progress", conclusion=None)
        with (
            patch.object(
                artifacts, "github", side_effect=self.api(artifact_data(), run)
            ),
            patch.object(artifacts.time, "monotonic", side_effect=[0, 181]),
            self.assertRaisesRegex(ValueError, "still running"),
        ):
            artifacts.find_artifact(REPO, IDENTITY, 999)

    def test_own_in_progress_artifacts_do_not_deadlock_a_rerun(self):
        with patch.object(
            artifacts, "github", side_effect=self.api(artifact_data(), run_data())
        ):
            self.assertEqual(
                artifacts.find_artifact(REPO, IDENTITY, 123)["mode"], "build"
            )

    def test_only_the_current_fork_run_can_complete_its_own_ci_gate(self):
        run = run_data()
        run["head_repository"]["full_name"] = "fork/turnrail"
        with self.assertRaisesRegex(ValueError, "Fork runs"):
            artifacts.require_run(run, REPO, current=False)
        run.update(status="in_progress", conclusion=None)
        artifacts.require_run(run, REPO, current=True)

    def test_wrong_workflow_and_unsuccessful_runs_are_never_trusted(self):
        for key, value in (
            ("path", ".github/workflows/unknown.yml"),
            ("event", "workflow_run"),
            ("conclusion", "failure"),
            ("status", "in_progress"),
        ):
            run = run_data()
            run[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                artifacts.require_run(run, REPO, current=False)

    def test_ci_gate_only_accepts_complete_execution_or_explicit_verified_reuse(self):
        for mode, status in (("build", "success"), ("reuse", "skipped")):
            needs = {
                "plan": {
                    "result": "success",
                    "outputs": {"mode": mode, "artifact_id": "456"},
                },
                "checks": {"result": status},
                "release": {"result": status},
            }
            self.assertEqual(artifacts.gate(needs), mode)
            for job in ("plan", "checks", "release"):
                for failure in (
                    "failure",
                    "cancelled",
                    "neutral",
                    "skipped" if mode == "build" else "success",
                ):
                    if failure == needs[job]["result"]:
                        continue
                    changed = copy.deepcopy(needs)
                    changed[job]["result"] = failure
                    with (
                        self.subTest(mode=mode, job=job, failure=failure),
                        self.assertRaises(ValueError),
                    ):
                        artifacts.gate(changed)
        for outputs in (
            {"mode": "unknown", "artifact_id": "456"},
            {"mode": "reuse", "artifact_id": ""},
        ):
            needs = {
                "plan": {"result": "success", "outputs": outputs},
                "checks": {"result": "skipped"},
                "release": {"result": "skipped"},
            }
            with self.assertRaises(ValueError):
                artifacts.gate(needs)


if __name__ == "__main__":
    unittest.main()
