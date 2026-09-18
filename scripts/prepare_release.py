#!/usr/bin/env python3
"""Start a Draft Release only for a verified main version increase."""

import argparse
import plistlib
import subprocess
import sys

from engine_artifacts import git, revision
from github_api import github
from project_metadata import ROOT, version_tuple
from release_tag import require_ci


def version_at(root, commit):
    info = plistlib.loads(git(root, "show", f"{commit}:packaging/Info.plist").encode())
    version = info["CFBundleShortVersionString"]
    version_tuple(version)
    return version


def select_tag(root, repository, run_id):
    run = github(f"repos/{repository}/actions/runs/{run_id}")
    if (
        run["repository"]["full_name"] != repository
        or run["head_repository"]["full_name"] != repository
        or run["path"] != ".github/workflows/ci.yml"
        or run["event"] != "push"
        or run["head_branch"] != "main"
        or run["status"] != "completed"
        or run["conclusion"] != "success"
    ):
        raise ValueError("Automatic releases require successful main push CI.")
    commit = revision(run["head_sha"])
    git(root, "merge-base", "--is-ancestor", commit, "origin/main")
    before = version_at(root, f"{commit}^1")
    after = version_at(root, commit)
    if before == after:
        print("No product version change; no Draft Release needed.")
        return None
    if version_tuple(after) < version_tuple(before):
        raise ValueError("The product version must increase before release.")
    current = version_at(root, "origin/main")
    if version_tuple(current) > version_tuple(after):
        print("A newer product version is already on main; skip this revision.")
        return None
    if current != after:
        raise ValueError("The product version on main has decreased since this CI run.")
    require_ci(repository, commit)
    tag = "v" + after
    refs = git(root, "ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}")
    if refs:
        targets = {ref: sha for sha, ref in (row.split() for row in refs.splitlines())}
        peeled = f"refs/tags/{tag}^{{}}"
        target = targets[peeled] if peeled in targets else targets[f"refs/tags/{tag}"]
        if target != commit:
            raise ValueError("The release tag already points to another commit.")
        print(f"{tag} already exists; no duplicate release dispatch.")
        return None
    return tag, commit


def prepare(root, repository, run_id):
    selected = select_tag(root, repository, run_id)
    if selected is None:
        return
    tag, commit = selected
    github(
        f"repos/{repository}/git/refs",
        method="POST",
        payload={"ref": f"refs/tags/{tag}", "sha": commit},
    )
    github(
        f"repos/{repository}/actions/workflows/release.yml/dispatches",
        method="POST",
        payload={"ref": "main", "inputs": {"tag": tag}},
    )
    print(f"Started Draft Release {tag} from verified commit {commit}.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    args = parser.parse_args()
    try:
        prepare(ROOT, args.repository, args.run_id)
        return 0
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Automatic release preparation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
