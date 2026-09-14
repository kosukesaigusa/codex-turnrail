"""Reject stale timing evidence and retain reports across failures and cleanup."""

import json
import shutil
import subprocess
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

import dev
import measure_release as measurement


class ReleaseMeasurementTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(
            self.stack.enter_context(tempfile.TemporaryDirectory())
        ).resolve()
        self.target = self.root / "engine/codex-rs/target"
        self.timings = self.target / "cargo-timings"
        self.timings.mkdir(parents=True)
        (self.timings / "cargo-timing.html").write_text("stale cached report")
        self.report = self.root / "reports/release"
        for module, variable, value in [
            (dev, "REPO_ROOT", self.root),
            (dev, "ENGINE_ROOT", self.root / "engine"),
            (dev, "TARGET", self.target),
            (dev, "RUST_ROOT", self.target.parent),
            (measurement, "TARGET", self.target),
            (measurement, "APP_ROOT", self.root / "app"),
        ]:
            self.stack.enter_context(patch.object(module, variable, value))
        self.stack.enter_context(
            patch.dict(
                measurement.os.environ,
                {"GITHUB_ACTIONS": "true", "CARGO_BUILD_JOBS": "2"},
                clear=True,
            )
        )
        self.stack.enter_context(
            patch.object(
                measurement.subprocess, "check_output", return_value="fixture\n"
            )
        )

    def build(self, returncode, produce_timings):
        def run(command, **kwargs):
            self.assertFalse(self.timings.exists())
            Path(command[3]).write_text("fixture resource usage\n")
            if produce_timings:
                self.timings.mkdir()
                (self.timings / "cargo-timing.html").write_text("fresh timing report")
            return subprocess.CompletedProcess(command, returncode)

        return run

    def test_successful_reports_survive_target_cleanup(self):
        with patch.object(
            measurement.subprocess, "run", side_effect=self.build(0, True)
        ):
            self.assertEqual(measurement.measure(self.report, ["fixture-build"]), 0)
        shutil.rmtree(self.target)
        self.assertEqual(
            (self.report / "cargo-timings/cargo-timing.html").read_text(),
            "fresh timing report",
        )
        summary = json.loads((self.report / "summary.json").read_text())
        self.assertEqual(summary["command_returncode"], 0)
        self.assertEqual(summary["source_commit"], "fixture")
        self.assertTrue(summary["cargo_timings_available"])
        self.assertTrue((self.report / "swap-after.txt").is_file())

    def test_failed_build_retains_resources_without_reusing_cached_timings(self):
        with patch.object(
            measurement.subprocess, "run", side_effect=self.build(101, False)
        ):
            self.assertEqual(measurement.measure(self.report, ["fixture-build"]), 101)
        summary = json.loads((self.report / "summary.json").read_text())
        self.assertEqual(summary["command_returncode"], 101)
        self.assertFalse(summary["cargo_timings_available"])
        self.assertFalse((self.report / "cargo-timings").exists())
        self.assertTrue((self.report / "resources.txt").is_file())

    def test_success_without_fresh_cargo_evidence_is_rejected(self):
        with (
            patch.object(
                measurement.subprocess, "run", side_effect=self.build(0, False)
            ),
            self.assertRaisesRegex(ValueError, "fresh Cargo timings"),
        ):
            measurement.measure(self.report, ["fixture-build"])

    def test_report_inside_cleanup_scope_cannot_start_a_build(self):
        with (
            patch.object(measurement.subprocess, "run") as process,
            self.assertRaisesRegex(ValueError, "survive"),
        ):
            measurement.measure(self.target / "report", ["fixture-build"])
        process.assert_not_called()
        self.assertEqual(
            (self.timings / "cargo-timing.html").read_text(), "stale cached report"
        )

    def test_active_build_prevents_removal_of_its_timing_reports(self):
        with dev.workspace_lock():
            with self.assertRaises(dev.StoragePolicyError):
                measurement.measure(self.report, ["fixture-build"])
        self.assertEqual(
            (self.timings / "cargo-timing.html").read_text(), "stale cached report"
        )


if __name__ == "__main__":
    unittest.main()
