"""Shared runtime file and validation contract for Engine evidence and releases."""

import hashlib
import json

RUNTIME_BINARIES = (
    "bin/codex",
    "bin/codex-code-mode-host",
    "codex-path/rg",
    "codex-resources/zsh/bin/zsh",
)


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def verify_report(path):
    report = json.loads(path.read_text())
    expected = {"code_mode", "approval_accept", "approval_decline"}
    if not isinstance(report, list) or len(report) != len(expected):
        raise ValueError("The runtime verification report is incomplete.")
    if {case["case"] for case in report} != expected or any(
        case["passed"] is not True for case in report
    ):
        raise ValueError("Every required runtime scenario must pass.")
