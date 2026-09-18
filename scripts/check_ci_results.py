#!/usr/bin/env python3
"""Require successful checks and only explicitly planned job skips."""

import json
import os

REQUIRED = {"changes", "checks", "spelling", "blob-size"}
CONDITIONAL = {
    "dependencies": "dependencies_required",
    "engine-inputs": "engine_required",
    "engine": "engine_required",
}
OUTPUTS = {
    "tooling_required",
    "app_required",
    "engine_required",
    "dependencies_required",
}


def main():
    needs = json.loads(os.environ["NEEDS"])
    if set(needs) != REQUIRED | set(CONDITIONAL):
        raise SystemExit(
            "The required CI job has incomplete or unexpected dependencies."
        )
    if needs["changes"]["result"] != "success":
        raise SystemExit("CI change detection did not succeed.")
    plan = needs["changes"]["outputs"]
    if set(plan) != OUTPUTS or any(
        value not in {"true", "false"} for value in plan.values()
    ):
        raise SystemExit("Change detection must return true or false for every impact.")
    if plan["engine_required"] == "true" and plan["dependencies_required"] != "true":
        raise SystemExit("Engine verification requires dependency checks.")
    for name, dependency in needs.items():
        skip = name in CONDITIONAL and plan[CONDITIONAL[name]] == "false"
        expected = "skipped" if skip else "success"
        if dependency["result"] != expected:
            raise SystemExit(
                f"CI dependency did not match its plan: {name}: {dependency['result']}"
            )
    print("All required checks succeeded; skipped jobs matched the change plan.")


if __name__ == "__main__":
    main()
