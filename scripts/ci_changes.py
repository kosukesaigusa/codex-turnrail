#!/usr/bin/env python3
"""Select CI checks from the actual impact of committed file changes."""

import json
import os
from pathlib import Path, PurePosixPath

from engine_artifacts import ROOT, SCOPES, git, revision

FLAGS = ("tooling", "app", "engine", "dependencies")
APP_INPUTS = (
    "app",
    "packaging",
    "upstream.toml",
    "LICENSE",
    "NOTICE",
    "scripts/build-app.sh",
    "scripts/build_notices.py",
    "scripts/project_metadata.py",
    "scripts/dev.py",
    ".github/workflows/source-checks.yml",
)
LINT_FILES = {".codespellrc", ".gitignore", ".markdownlint-cli2.jsonc"}
TOOLING_FILES = {
    "scripts/merge_automation_pr.py",
    ".github/workflows/automation-merge.yml",
    "scripts/check_ci_results.py",
    "scripts/ci_changes.py",
    "scripts/format.py",
    "scripts/notarization.py",
    "scripts/prepare_release.py",
    "scripts/prepare_upstream.py",
    "scripts/release.py",
    "scripts/release_delivery.py",
    "scripts/release_tag.py",
    "scripts/sync_upstream.py",
    "scripts/update_release_readme.py",
    "scripts/upstream_watch.py",
    "scripts/verify-protocol-compatibility.sh",
    ".github/blob-size-allowlist.txt",
    ".github/release.yml",
    ".github/workflows/blob-size.yml",
    ".github/workflows/ci.yml",
    ".github/workflows/dependency-policy.yml",
    ".github/workflows/release-benchmarks.yml",
    ".github/workflows/release-build-check.yml",
    ".github/workflows/release-prepare.yml",
    ".github/workflows/release-readme.yml",
    ".github/workflows/release.yml",
    ".github/workflows/spelling.yml",
    ".github/workflows/upstream.yml",
}


def in_scope(path, scopes):
    return any(path == scope or path.startswith(scope + "/") for scope in scopes)


def impacts(path):
    result = set()
    if in_scope(path, SCOPES):
        result.update(("engine", "dependencies", "tooling"))
    if in_scope(path, APP_INPUTS):
        result.update(("app", "tooling"))
    if path == "justfile":
        result.update(("tooling", "app"))
    if path == ".github/workflows/dependency-policy.yml":
        result.add("dependencies")
    if (
        path in TOOLING_FILES
        or (path.startswith("scripts/test_") and path.endswith(".py"))
        or path.startswith("tests/")
    ):
        result.add("tooling")
    if result:
        return result
    # Product documentation includes images and other presentation assets.
    if (
        path.startswith("docs/")
        or path.startswith(".github/ISSUE_TEMPLATE/")
        or path.startswith(".github/PULL_REQUEST_TEMPLATE")
        or (len(PurePosixPath(path).parts) == 1 and path.endswith(".md"))
        or path in LINT_FILES
    ):
        return set()
    raise ValueError(
        f"No CI impact rule for {path!r}; classify the new path explicitly."
    )


def changed_paths(root, base, source):
    revision(base)
    revision(source)
    if base == "0" * 40:
        raise ValueError("An existing base commit is required for change detection.")
    # Treat renames as deletion plus addition so neither side loses its checks.
    return tuple(
        filter(
            None,
            git(root, "diff", "--no-renames", "--name-only", "-z", base, source).split(
                "\0"
            ),
        )
    )


def classify(root, event_name, event, source):
    revision(source)
    if event_name == "workflow_dispatch":
        mode = event["inputs"]["scope"]
        if mode == "full":
            return {flag: True for flag in FLAGS}, "Explicit full verification."
        if mode != "auto":
            raise ValueError(f"Unsupported manual CI scope: {mode}")
        main = revision(git(root, "rev-parse", "origin/main"))
        base = (
            revision(git(root, "rev-parse", f"{source}^1"))
            if source == main
            else revision(git(root, "merge-base", "origin/main", source))
        )
    elif event_name == "pull_request":
        base = revision(event["pull_request"]["base"]["sha"])
    elif event_name == "push":
        base = revision(event["before"])
    else:
        raise ValueError(f"Unsupported CI event: {event_name}")
    paths = changed_paths(root, base, source)
    if not paths:
        raise ValueError(
            "CI needs a nonempty comparison or explicit full verification."
        )
    selected = set()
    for path in paths:
        selected.update(impacts(path))
    plan = {flag: flag in selected for flag in FLAGS}
    return plan, json.dumps({"changed_files": paths, "checks": sorted(selected)})


def main():
    source = revision(os.environ["GITHUB_SHA"])
    if git(ROOT, "rev-parse", "HEAD") != source:
        raise ValueError("Change detection must inspect the exact CI source commit.")
    plan, reason = classify(
        ROOT,
        os.environ["GITHUB_EVENT_NAME"],
        json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()),
        source,
    )
    for flag, required in plan.items():
        print(f"{flag}_required={str(required).lower()}")
    print(f"reason={reason}")


if __name__ == "__main__":
    main()
