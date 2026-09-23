"""Runtime evidence for the Swift router and separately installed official Engine."""

import json
import re

PRODUCT_BINARIES = ("CodexTurnrailApp", "CodexTurnrailRouter")
SCENARIOS = {
    "code_mode",
    "account_switch",
    "title_routing",
    "approval_accept",
    "approval_decline",
    "no_replay",
    "connection_recovery",
    "compaction",
    "failure_recovery",
    "web_search",
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
    hashes = report["official_engine"]["binaries"]
    if set(hashes) != {"codex", "codex-code-mode-host"} or any(
        not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None
        for value in [report["router_sha256"], *hashes.values()]
    ):
        raise ValueError("Runtime evidence requires hashes of every tested executable.")
    return report
