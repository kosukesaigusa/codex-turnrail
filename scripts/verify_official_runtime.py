#!/usr/bin/env python3
"""Run real official Engine tools against a local synthetic model through the router."""

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

import official_app
from product_evidence import SCENARIOS, verify_report
from project_metadata import ROOT, read_upstream
from runtime_evidence import sha256


def stop_fixture(process):
    try:
        os.killpg(process.pid, signal.SIGINT)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait(timeout=10)


def run_fixture(command, *, env, timeout):
    with subprocess.Popen(
        command, cwd=ROOT, env=env, start_new_session=True
    ) as process:
        try:
            result = process.wait(timeout=timeout)
            if result != 0:
                raise subprocess.CalledProcessError(result, command)
        except BaseException:
            stop_fixture(process)
            raise


def verify(app, router, report, ci):
    if report.exists():
        raise ValueError("Runtime evidence already exists; use a new output location.")
    before = official_app.verify(app, read_upstream(ROOT))
    router_hash = sha256(router)
    with tempfile.TemporaryDirectory(prefix="turnrail-runtime-proof-") as temporary:
        proof = Path(temporary) / "scenarios.json"
        environment = dict(os.environ)
        environment.update(
            CODEX_TURNRAIL_TEST_OFFICIAL_APP=str(app),
            CODEX_TURNRAIL_TEST_ROUTER=str(router),
            CODEX_TURNRAIL_TEST_PROOF=str(proof),
        )
        command = [sys.executable, str(ROOT / "scripts/dev.py")]
        if ci:
            command.append("--ci")
        command += [
            "swift",
            "test",
            "--jobs",
            "2",
            "--filter",
            "RouterOfficialEngineTests",
        ]
        run_fixture(command, env=environment, timeout=600)
        cases = json.loads(proof.read_text())
        if len(cases) != len(SCENARIOS) or set(cases) != SCENARIOS:
            raise ValueError(
                "The official Engine scenarios were skipped or incomplete."
            )
    if before != official_app.verify(app, read_upstream(ROOT)) or router_hash != sha256(
        router
    ):
        raise ValueError("A tested executable changed during runtime verification.")
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "official_engine": before,
                "router_sha256": router_hash,
                "scenarios": [
                    {"case": case, "passed": True} for case in sorted(SCENARIOS)
                ],
            },
            indent=2,
        )
        + "\n"
    )
    verify_report(report)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("router", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("--ci", action="store_true")
    args = parser.parse_args()
    verify(
        args.app.resolve(strict=True),
        args.router.resolve(strict=True),
        args.report,
        args.ci,
    )


if __name__ == "__main__":
    main()
