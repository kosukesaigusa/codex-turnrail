#!/usr/bin/env python3
"""Create a release tag only for a clean main revision with successful CI."""

import argparse
import subprocess
import sys

from project_metadata import ROOT, validate
from upstream_watch import github


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args], text=True).strip()


def require_ci(repository, commit):
    runs = github(
        f"repos/{repository}/actions/workflows/ci.yml/runs?head_sha={commit}&branch=main&event=push&per_page=1"
    )["workflow_runs"]
    if (
        not runs
        or runs[0]["status"] != "completed"
        or runs[0]["conclusion"] != "success"
    ):
        raise ValueError(
            "The latest main CI run for this exact source revision must succeed."
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    try:
        metadata = validate(ROOT)
        tag = "v" + metadata["version"]
        if git("status", "--porcelain") or git("branch", "--show-current") != "main":
            raise ValueError("Release tags require a clean main worktree.")
        commit = git("rev-parse", "HEAD")
        remote = git("ls-remote", "origin", "refs/heads/main").split()
        if not remote or remote[0] != commit:
            raise ValueError("Local main must match origin/main.")
        if git("tag", "--list", tag) or git("ls-remote", "origin", f"refs/tags/{tag}"):
            raise ValueError(
                "This release tag already exists; never move an existing tag."
            )
        require_ci(args.repository, commit)
        print(f"Release tag: {tag}, source: {commit}")
        if not args.dry_run:
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(ROOT),
                    "tag",
                    "-a",
                    tag,
                    commit,
                    "-m",
                    f"Codex Turnrail {tag}",
                ],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(ROOT), "push", "origin", f"refs/tags/{tag}"],
                check=True,
            )
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Release tagging failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
