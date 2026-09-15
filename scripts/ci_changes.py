#!/usr/bin/env python3
"""Select Engine CI from committed build and verification inputs."""

import json
import os
from pathlib import Path

from engine_artifacts import ROOT, git, revision, source_inputs


def classify(root, event_name, event, source):
    revision(source)
    if event_name == "workflow_dispatch":
        return True, "Manual CI requests Engine verification."
    if event_name == "pull_request":
        base = revision(event["pull_request"]["base"]["sha"])
    elif event_name == "push":
        base = revision(event["before"])
    else:
        raise ValueError(f"Unsupported CI event: {event_name}")
    if base == "0" * 40:
        raise ValueError("An existing base commit is required for change detection.")
    before = source_inputs(root, base)
    after = source_inputs(root, source)
    changed = sorted(path for path in after if before[path] != after[path])
    if changed:
        return True, "Changed Engine inputs: " + ", ".join(changed)
    return False, "No Engine build or verification inputs changed."


def main():
    source = revision(os.environ["GITHUB_SHA"])
    if git(ROOT, "rev-parse", "HEAD") != source:
        raise ValueError("Change detection must inspect the exact CI source commit.")
    required, reason = classify(
        ROOT,
        os.environ["GITHUB_EVENT_NAME"],
        json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()),
        source,
    )
    print(f"engine_required={str(required).lower()}")
    print(f"reason={reason}")


if __name__ == "__main__":
    main()
