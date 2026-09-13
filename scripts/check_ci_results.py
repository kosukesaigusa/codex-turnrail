#!/usr/bin/env python3
"""Require explicit success from every dependency of the final CI job."""

import json
import os


def main():
    needs = json.loads(os.environ["NEEDS"])
    if not needs:
        raise SystemExit("The required CI job must have dependencies.")
    failures = sorted(
        (name, dependency["result"])
        for name, dependency in needs.items()
        if dependency["result"] != "success"
    )
    if failures:
        for name, result in failures:
            print(f"CI dependency did not succeed: {name}: {result}")
        raise SystemExit(1)
    print("All CI dependencies succeeded.")


if __name__ == "__main__":
    main()
