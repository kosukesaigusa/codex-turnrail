"""Keep runtime verification bounded without orphaning its development command."""

import os
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

import verify_official_runtime as verification


class RuntimeProcessTests(unittest.TestCase):
    @staticmethod
    def stop_child(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def test_completed_fixture_preserves_environment_and_nonzero_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "marker"
            environment = {**os.environ, "RUNTIME_PROBE": "isolated fixture"}
            command = [
                sys.executable,
                "-c",
                "import os,pathlib,sys; "
                "pathlib.Path(sys.argv[1]).write_text(os.environ['RUNTIME_PROBE'])",
                str(marker),
            ]
            verification.run_fixture(command, env=environment, timeout=10)
            self.assertEqual(marker.read_text(), "isolated fixture")
            with self.assertRaises(subprocess.CalledProcessError) as failure:
                verification.run_fixture(
                    [sys.executable, "-c", "raise SystemExit(7)"],
                    env=environment,
                    timeout=10,
                )
            self.assertEqual(failure.exception.returncode, 7)

    def test_timeout_stops_children_and_releases_the_development_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child = root / "child.py"
            child.write_text(
                "import os,pathlib,signal,sys,time\n"
                "signal.signal(signal.SIGINT, signal.SIG_IGN)\n"
                "pathlib.Path(sys.argv[1]).write_text(str(os.getpid()))\n"
                "time.sleep(60)\n"
            )
            parent = root / "parent.py"
            parent.write_text(
                textwrap.dedent(
                    """\
                    import pathlib,subprocess,sys,time
                    sys.path.insert(0, sys.argv[1])
                    import dev
                    dev.REPO_ROOT = pathlib.Path(sys.argv[2])
                    with dev.workspace_lock():
                        subprocess.Popen([sys.executable, sys.argv[3], sys.argv[4]])
                        time.sleep(60)
                    """
                )
            )
            pid_file = root / "child.pid"
            with self.assertRaises(subprocess.TimeoutExpired):
                verification.run_fixture(
                    [
                        sys.executable,
                        str(parent),
                        str(Path(verification.__file__).parent),
                        str(root),
                        str(child),
                        str(pid_file),
                    ],
                    env=dict(os.environ),
                    timeout=5,
                )
            pid = int(pid_file.read_text())
            self.addCleanup(self.stop_child, pid)
            self.assertFalse((root / ".cache/turnrail-dev.lock").exists())
            result = subprocess.run(
                ["ps", "-p", str(pid), "-o", "stat="],
                text=True,
                capture_output=True,
                timeout=10,
            )
            self.assertTrue(
                result.returncode == 1 or result.stdout.strip().startswith("Z")
            )


if __name__ == "__main__":
    unittest.main()
