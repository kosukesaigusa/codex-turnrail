#!/usr/bin/env python3
"""Select Engine CI from committed build and verification inputs."""

import json
import os
from pathlib import Path

from engine_artifacts import ROOT, git, revision, source_inputs


def readme_only(root, event_name, event, source):
    revision(source)
    if event_name == "workflow_dispatch":
        scope = event["inputs"]["scope"]
        if scope == "full":
            return False
        if scope != "readme":
            raise ValueError(f"Unsupported manual CI scope: {scope}")
        base = revision(git(root, "merge-base", "origin/main", source))
    elif event_name == "pull_request":
        base = revision(event["pull_request"]["base"]["sha"])
    elif event_name == "push":
        base = revision(event["before"])
    else:
        raise ValueError(f"Unsupported CI event: {event_name}")
    if base == "0" * 40:
        raise ValueError("An existing base commit is required for change detection.")
    changed = set(git(root, "diff", "--name-only", base, source).splitlines())
    only_readme = changed == {"README.md"}
    if event_name == "workflow_dispatch" and not only_readme:
        raise ValueError("README CI requires a nonempty README.md-only diff.")
    return only_readme


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
    event_name = os.environ["GITHUB_EVENT_NAME"]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    docs = readme_only(ROOT, event_name, event, source)
    required, reason = (
        (False, "Only README.md changed; run documentation checks.")
        if docs
        else classify(ROOT, event_name, event, source)
    )
    print(f"readme_only={str(docs).lower()}")
    print(f"engine_required={str(required).lower()}")
    print(f"reason={reason}")


if __name__ == "__main__":
    main()
