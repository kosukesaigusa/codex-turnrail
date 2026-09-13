"""Verify that packaged app outputs cannot be removed by automatic cleanup."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]


class BuildAppTests(unittest.TestCase):
    def test_output_in_build_directory_is_rejected_before_building(self):
        for output in [
            REPOSITORY / "engine/codex-rs/target/app-output",
            REPOSITORY / "app/.build/app-output",
        ]:
            for script, command in [
                ("build-app.sh", ["zsh"]),
                ("build-runtime.py", ["python3"]),
            ]:
                with self.subTest(output=output, script=script):
                    arguments = [str(output)]
                    if script == "build-app.sh":
                        arguments.append("fixture identity")
                    result = subprocess.run(
                        [*command, str(REPOSITORY / "scripts" / script), *arguments],
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(
                        "Output must be outside generated build directories",
                        result.stderr,
                    )
                    self.assertFalse((output / "Codex Turnrail.app").exists())

    def test_unverified_v8_overrides_are_rejected_before_building(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            overrides = (
                "V8_FROM_SOURCE",
                "RUSTY_V8_ARCHIVE",
                "RUSTY_V8_SRC_BINDING_PATH",
            )
            clean_environment = {
                key: value for key, value in os.environ.items() if key not in overrides
            }
            for key in overrides:
                with self.subTest(override=key):
                    result = subprocess.run(
                        [
                            "python3",
                            str(REPOSITORY / "scripts/build-runtime.py"),
                            str(root / "runtime"),
                        ],
                        env={**clean_environment, key: "unverified"},
                        capture_output=True,
                        text=True,
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(f"Remove {key}", result.stderr)
                    self.assertFalse((root / "runtime").exists())


if __name__ == "__main__":
    unittest.main()
