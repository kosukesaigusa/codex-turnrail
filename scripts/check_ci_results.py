#!/usr/bin/env python3
"""Require successful checks and only explicitly planned Engine skips."""

import json
import os

REQUIRED = {"changes", "checks", "dependencies", "spelling", "blob-size"}
ENGINE = {"engine-inputs", "engine"}


def main():
    needs = json.loads(os.environ["NEEDS"])
    if set(needs) != REQUIRED | ENGINE:
        raise SystemExit(
            "The required CI job has incomplete or unexpected dependencies."
        )
    if needs["changes"]["result"] != "success":
        raise SystemExit("Engine change detection did not succeed.")
    required = needs["changes"]["outputs"]["engine_required"]
    if required not in {"true", "false"}:
        raise SystemExit("Engine change detection must return true or false.")
    failures = sorted(
        (name, dependency["result"])
        for name, dependency in needs.items()
        if dependency["result"]
        != ("skipped" if name in ENGINE and required == "false" else "success")
    )
    if failures:
        for name, result in failures:
            print(f"CI dependency did not succeed: {name}: {result}")
        raise SystemExit(1)
    print("All required checks succeeded; Engine jobs matched the change plan.")


if __name__ == "__main__":
    main()
