#!/usr/bin/env python3
"""Retain fresh Cargo timings and macOS resource measurements for a CI build."""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from dev import (
    APP_ROOT,
    REPO_ROOT,
    TARGET,
    StoragePolicyError,
    cargo_environment,
    workspace_lock,
)


def memory_snapshot(directory, phase):
    for name, command in {
        "vm-stat": ["vm_stat"],
        "swap": ["sysctl", "vm.swapusage"],
    }.items():
        (directory / f"{name}-{phase}.txt").write_text(
            subprocess.check_output(command, text=True)
        )


def measure(directory, command):
    if os.environ["GITHUB_ACTIONS"] != "true":
        raise ValueError("Release measurements require GitHub Actions.")
    jobs = int(os.environ["CARGO_BUILD_JOBS"])
    if jobs < 1:
        raise ValueError("CARGO_BUILD_JOBS must be positive.")
    if not directory.is_absolute():
        raise ValueError("The build report directory must be absolute.")
    for generated in (TARGET, APP_ROOT / ".build"):
        if directory.resolve().is_relative_to(generated.resolve()):
            raise ValueError("Build reports must survive generated-file cleanup.")
    directory.mkdir(parents=True, exist_ok=False)
    timings = TARGET / "cargo-timings"
    with workspace_lock():
        cargo_environment(os.environ)
        if timings.is_symlink():
            raise ValueError("Cargo timing reports must not be a symlink.")
        if timings.exists():
            shutil.rmtree(timings)
    (directory / "hardware.txt").write_text(
        subprocess.check_output(["sysctl", "hw.memsize", "hw.logicalcpu"], text=True)
    )
    memory_snapshot(directory, "before")
    source_commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=REPO_ROOT, text=True
    ).strip()
    started = time.monotonic()
    result = subprocess.run(
        ["/usr/bin/time", "-l", "-o", str(directory / "resources.txt"), *command],
        check=False,
    )
    elapsed = time.monotonic() - started
    memory_snapshot(directory, "after")
    available = (timings / "cargo-timing.html").is_file()
    if available:
        shutil.copytree(timings, directory / "cargo-timings")
    summary = {
        "schema_version": 1,
        "source_commit": source_commit,
        "elapsed_seconds": elapsed,
        "command_returncode": result.returncode,
        "cargo_build_jobs": jobs,
        "cargo_timings_available": available,
    }
    (directory / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    if result.returncode == 0 and not available:
        raise ValueError("The successful build did not produce fresh Cargo timings.")
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report_directory", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("A build command is required.")
    try:
        return measure(args.report_directory, command)
    except (
        OSError,
        ValueError,
        KeyError,
        StoragePolicyError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Release measurement failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
