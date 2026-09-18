#!/usr/bin/env python3
"""Require successful checks and only explicitly planned job skips."""

import json
import os

REQUIRED = {"changes"}
SOURCE = {"checks", "dependencies", "spelling", "blob-size"}
DOCS = {"readme"}
ENGINE = {"engine-inputs", "engine"}


def main():
    needs = json.loads(os.environ["NEEDS"])
    if set(needs) != REQUIRED | SOURCE | DOCS | ENGINE:
        raise SystemExit(
            "The required CI job has incomplete or unexpected dependencies."
        )
    if needs["changes"]["result"] != "success":
        raise SystemExit("CI change detection did not succeed.")
    required = needs["changes"]["outputs"]["engine_required"]
    docs = needs["changes"]["outputs"]["readme_only"]
    if required not in {"true", "false"} or docs not in {"true", "false"}:
        raise SystemExit("Change detection must return true or false for each plan.")
    if docs == "true" and required != "false":
        raise SystemExit("README-only changes cannot require Engine verification.")
    skipped = SOURCE if docs == "true" else DOCS
    if required == "false":
        skipped = skipped | ENGINE
    failures = sorted(
        (name, dependency["result"])
        for name, dependency in needs.items()
        if dependency["result"] != ("skipped" if name in skipped else "success")
    )
    if failures:
        for name, result in failures:
            print(f"CI dependency did not succeed: {name}: {result}")
        raise SystemExit(1)
    print("All required checks succeeded; skipped jobs matched the change plan.")


if __name__ == "__main__":
    main()
