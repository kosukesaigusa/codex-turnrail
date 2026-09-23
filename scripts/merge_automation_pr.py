#!/usr/bin/env python3
"""Merge verified bot candidates using only trusted main code and GitHub metadata."""

import argparse
import base64
import plistlib
import re
import subprocess
import sys
from urllib.parse import quote

import tomllib
from github_api import github
from project_metadata import (
    GENERATED,
    VERSION_GENERATED,
    product_version_swift,
    supported_swift,
    validate_upstream,
    version_tuple,
)
from update_release_readme import dispatch_ci, published_url, update_text

BOT = "github-actions[bot]"


def kind(branch):
    if re.fullmatch(r"upstream/codex-app-[1-9][0-9]*", branch):
        return "upstream"
    if re.fullmatch(r"docs/release-v[0-9]+\.[0-9]+\.[0-9]+", branch):
        return "readme"
    return None


def read_file(repository, commit, path):
    data = github(f"repos/{repository}/contents/{path}?ref={commit}")
    if data["type"] != "file" or data["encoding"] != "base64":
        raise ValueError(f"Expected an ordinary encoded source file: {path}")
    return base64.b64decode(data["content"])


def all_files(repository, pr):
    files = []
    for page in range(1, 31):
        batch = github(
            f"repos/{repository}/pulls/{pr['number']}/files?per_page=100&page={page}"
        )
        files.extend(batch)
        if len(files) == pr["changed_files"]:
            return files
        if len(batch) < 100:
            break
    raise ValueError("Cannot validate the complete PR file list.")


def check_contents(repository, pr, main, files):
    branch, head = pr["head"]["ref"], pr["head"]["sha"]
    paths = {entry["filename"] for entry in files}
    if any(entry["status"] == "renamed" for entry in files):
        raise ValueError("Renamed files require manual review.")
    if kind(branch) == "readme":
        if paths != {"README.md"}:
            raise ValueError("Automatic README merges may only change README.md.")
        tag = branch.removeprefix("docs/release-")
        url = published_url(repository, tag)
        if url is None:
            raise ValueError("This README candidate is no longer the latest release.")
        before = read_file(repository, main, "README.md").decode()
        after = read_file(repository, head, "README.md").decode()
        if after != update_text(before, repository, tag, url):
            raise ValueError(
                "README contains changes beyond the published download URL."
            )
        return
    allowed = {
        "upstream.toml",
        "packaging/Info.plist",
        str(GENERATED),
        str(VERSION_GENERATED),
    }
    if paths != allowed:
        raise ValueError("Upstream candidate changes automation or unrelated files.")
    before = plistlib.loads(read_file(repository, main, "packaging/Info.plist"))
    after = plistlib.loads(read_file(repository, head, "packaging/Info.plist"))
    major, minor, _ = version_tuple(before["CFBundleShortVersionString"])
    if major != 0:
        raise ValueError("Automatic upstream versioning requires the 0.x policy.")
    version = f"0.{minor + 1}.0"
    expected = {
        **before,
        "CFBundleShortVersionString": version,
        "CFBundleVersion": str(int(before["CFBundleVersion"]) + 1),
    }
    if after != expected:
        raise ValueError(
            "Candidate must increment the current minor version and build."
        )
    if read_file(
        repository, head, str(VERSION_GENERATED)
    ).decode() != product_version_swift(version):
        raise ValueError("The generated product version does not match the candidate.")
    metadata = validate_upstream(
        tomllib.loads(read_file(repository, head, "upstream.toml").decode())
    )
    old = validate_upstream(
        tomllib.loads(read_file(repository, main, "upstream.toml").decode())
    )
    if (
        metadata["app"]["build"] != branch.removeprefix("upstream/codex-app-")
        or int(metadata["app"]["build"]) <= int(old["app"]["build"])
        or metadata["codex"]["repository"] != "https://github.com/openai/codex.git"
        or metadata["codex"] != old["codex"]
        or metadata["app"]["bundle_identifier"] != "com.openai.codex"
    ):
        raise ValueError("Candidate must advance the official ChatGPT build.")
    if read_file(repository, head, str(GENERATED)).decode() != supported_swift(
        metadata
    ):
        raise ValueError("The generated compatibility contract is stale.")


def merge(repository, run_id):
    run = github(f"repos/{repository}/actions/runs/{run_id}")
    branch = run["head_branch"]
    if kind(branch) is None:
        print("Not an automation candidate; no merge needed.")
        return
    if (
        run["repository"]["full_name"] != repository
        or run["head_repository"]["full_name"] != repository
        or run["path"] != ".github/workflows/ci.yml"
        or run["event"] != "workflow_dispatch"
        or run["actor"]["login"] != BOT
        or run["status"] != "completed"
        or run["conclusion"] != "success"
    ):
        raise ValueError("Automatic merging requires successful bot-dispatched CI.")
    latest = github(
        f"repos/{repository}/actions/workflows/ci.yml/runs?"
        f"head_sha={run['head_sha']}&branch={quote(branch, safe='')}&"
        "event=workflow_dispatch&per_page=1"
    )["workflow_runs"]
    if not latest or any(
        latest[0][key] != run[key]
        for key in ("id", "run_attempt", "status", "conclusion")
    ):
        raise ValueError("A newer CI run or attempt supersedes this completion.")
    prs = github(
        f"repos/{repository}/pulls?state=all&head={repository.split('/')[0]}:{branch}"
    )
    if len(prs) != 1:
        raise ValueError("Expected exactly one PR for this automation branch.")
    pr = github(f"repos/{repository}/pulls/{prs[0]['number']}")
    if pr["state"] != "open":
        if (
            pr["merged"]
            and pr["user"]["login"] == BOT
            and pr["merged_by"]["login"] == BOT
            and pr["base"]["ref"] == "main"
            and pr["head"]["sha"] == run["head_sha"]
        ):
            ensure_main_ci(repository, pr["merge_commit_sha"])
        print("The PR is already closed; no merge needed.")
        return
    if pr["draft"]:
        print("Draft PR pauses automatic merging.")
        return
    if (
        pr["user"]["login"] != BOT
        or pr["head"]["repo"]["full_name"] != repository
        or pr["base"]["repo"]["full_name"] != repository
        or pr["base"]["ref"] != "main"
        or pr["head"]["ref"] != branch
        or pr["head"]["sha"] != run["head_sha"]
    ):
        raise ValueError(
            "PR identity or head no longer matches the verified bot candidate."
        )
    commits = github(f"repos/{repository}/pulls/{pr['number']}/commits?per_page=100")
    if (
        len(commits) != pr["commits"]
        or not commits
        or any(
            commit["author"] is None or commit["author"]["login"] != BOT
            for commit in commits
        )
    ):
        raise ValueError(
            "Human edits or an incomplete commit list require manual review."
        )
    main = github(f"repos/{repository}/git/ref/heads/main")["object"]["sha"]
    check_contents(repository, pr, main, all_files(repository, pr))
    comparison = github(f"repos/{repository}/compare/{main}...{run['head_sha']}")
    if comparison["status"] != "ahead":
        # A fresh merge of main must pass CI before automatic merging can resume.
        github(
            f"repos/{repository}/pulls/{pr['number']}/update-branch",
            method="PUT",
            payload={"expected_head_sha": run["head_sha"]},
        )
        # Updating a branch is asynchronous. Its completion is checked by the caller
        # before dispatching CI so the previous head cannot be tested again.
        wait_for_update(repository, pr["number"], branch, run["head_sha"])
        return
    if github(f"repos/{repository}/git/ref/heads/main")["object"]["sha"] != main:
        raise ValueError("Main changed during verification; rerun this merge workflow.")
    result = github(
        f"repos/{repository}/pulls/{pr['number']}/merge",
        method="PUT",
        payload={"merge_method": "merge", "sha": run["head_sha"]},
    )
    if result["merged"] is not True:
        raise ValueError("GitHub did not merge the verified candidate.")
    # GITHUB_TOKEN merges do not trigger push workflows. Explicit main CI is required
    # before release preparation may create a tag from the new version.
    ensure_main_ci(repository, result["sha"])
    print(f"Merged PR #{pr['number']} at {result['sha']}; started main CI.")


def ensure_main_ci(repository, commit):
    runs = github(
        f"repos/{repository}/actions/workflows/ci.yml/runs?"
        f"head_sha={commit}&branch=main&per_page=100"
    )["workflow_runs"]
    if any(run["event"] in {"push", "workflow_dispatch"} for run in runs):
        return
    if github(f"repos/{repository}/git/ref/heads/main")["object"]["sha"] != commit:
        raise ValueError(
            "Main advanced before post-merge CI started; inspect the release candidate."
        )
    dispatch_ci(repository, "main")


def wait_for_update(repository, number, branch, previous):
    import time

    for _ in range(12):
        pr = github(f"repos/{repository}/pulls/{number}")
        if pr["head"]["sha"] != previous:
            dispatch_ci(repository, branch)
            print(f"Updated PR #{number} with main; started fresh CI.")
            return
        time.sleep(5)
    raise ValueError("Branch update has not completed; inspect the PR and dispatch CI.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    args = parser.parse_args()
    try:
        merge(args.repository, args.run_id)
        return 0
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Automatic PR merge stopped: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
