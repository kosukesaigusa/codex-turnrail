"""Runtime evidence for the Swift router and separately installed official Engine."""

import json
import re

from official_runtime import LAYOUT_FILES

PRODUCT_BINARIES = ("CodexTurnrailApp", "CodexTurnrailRouter")
SCENARIOS = {
    "code_mode",
    "account_switch",
    "title_routing",
    "approval_accept",
    "approval_decline",
    "no_replay",
    "connection_recovery",
    "connection_limit_recovery",
    "compaction",
    "failure_recovery",
    "web_search",
    "model_wait",
    "model_wait_cancellation",
    "engine_idle_timeout",
}


def verify_report(path):
    report = json.loads(path.read_text())
    if not isinstance(report, dict) or report["schema_version"] != 1:
        raise ValueError("Unsupported product runtime evidence.")
    cases = report["scenarios"]
    if (
        not isinstance(cases, list)
        or len(cases) != len(SCENARIOS)
        or {row["case"] for row in cases} != SCENARIOS
        or any(row["passed"] is not True for row in cases)
    ):
        raise ValueError("Every required official Engine routing scenario must pass.")
    if report["official_engine"]["signing_team"] != "2DC432GLL2":
        raise ValueError("Runtime evidence requires the official OpenAI signature.")
    engine = report["official_engine"]
    hashes = engine["binaries"]
    layout = engine["layout"]
    if layout not in LAYOUT_FILES:
        raise ValueError("Runtime evidence requires a known official Engine layout.")
    files = engine["files"]
    paths = LAYOUT_FILES[layout]
    if (
        set(files) != set(paths.values())
        or files[paths["executable"]] != hashes["codex"]
        or files[paths["host"]] != hashes["codex-code-mode-host"]
    ):
        raise ValueError(
            "Runtime evidence must bind the launcher, executable, and package files."
        )
    if set(hashes) != {"codex", "codex-code-mode-host"} or any(
        not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None
        for value in [report["router_sha256"], *hashes.values(), *files.values()]
    ):
        raise ValueError("Runtime evidence requires hashes of every tested executable.")
    return report
