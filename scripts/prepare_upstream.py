#!/usr/bin/env python3
"""Inspect an official app candidate and prepare an isolated upstream update PR."""

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path

from github_api import github
from official_app import extract, inspect
from project_metadata import (
    GENERATED,
    ROOT,
    VERSION_GENERATED,
    metadata_bytes,
    product_version,
    read_upstream,
    supported_swift,
    validate_cli_version,
    version_tuple,
)
from release import bump
from upstream_watch import app_candidate, download_app_file


def inspect_app(candidate, directory):
    archive = directory / "official-app.zip"
    expected_url = f"https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-{candidate['version']}.zip"
    if candidate["url"] != expected_url:
        raise ValueError("The candidate archive is not the expected official app URL.")
    download_app_file(
        candidate["url"], archive, max_bytes=candidate["size"], timeout=600
    )
    if archive.stat().st_size != candidate["size"]:
        raise ValueError("The official app archive size does not match its appcast.")
    extracted = directory / "extracted"
    extract(archive, extracted)
    expected = {
        "bundle_identifier": "com.openai.codex",
        "version": candidate["version"],
        "build": candidate["build"],
    }
    return inspect(extracted / "ChatGPT.app", expected)["cli_version"]


def prepare(root, candidate, version):
    current, _ = product_version(root)
    major, minor, _ = version_tuple(current)
    if major != 0:
        raise ValueError("Automatic upstream versioning requires the 0.x policy.")
    validate_cli_version(version)
    metadata = read_upstream(root)
    if int(candidate["build"]) <= int(metadata["app"]["build"]):
        raise ValueError("The candidate must advance the supported app build.")
    metadata["app"] = {
        "bundle_identifier": "com.openai.codex",
        "version": candidate["version"],
        "build": candidate["build"],
        "cli_version": version,
    }
    (root / "upstream.toml").write_bytes(metadata_bytes(metadata))
    (root / GENERATED).write_text(supported_swift(metadata))
    bump(root, f"0.{minor + 1}.0")


def publish(repository, branch, candidate, version):
    prs = github(
        f"repos/{repository}/pulls?state=all&head={repository.split('/')[0]}:{branch}"
    )
    if prs:
        print("This candidate already has a PR; human changes are preserved.")
        return
    remote = subprocess.check_output(
        ["git", "ls-remote", "--heads", "origin", branch], text=True
    )
    if remote:
        raise ValueError(
            "The candidate branch already exists without a PR; inspect it manually."
        )
    subprocess.run(["git", "switch", "-c", branch], check=True)
    subprocess.run(
        [
            "git",
            "add",
            "--",
            "upstream.toml",
            str(GENERATED),
            "packaging/Info.plist",
            str(VERSION_GENERATED),
        ],
        check=True,
    )
    subprocess.run(
        [
            "git",
            "commit",
            "-m",
            f"chore: update ChatGPT reference to {candidate['version']} "
            f"({candidate['build']})",
        ],
        check=True,
    )
    subprocess.run(["git", "push", "origin", f"HEAD:refs/heads/{branch}"], check=True)
    body = (
        "## Summary\n\n"
        f"Update the reference ChatGPT macOS app to {candidate['version']} "
        f"({candidate['build']}). "
        f"Its signed bundle reports `{version}`.\n\n"
        "The app, Engine, and Code Mode Host passed OpenAI signature inspection. "
        "Update the release reference; other installed versions remain usable. "
        "Turnrail runs the Engine "
        "from the installed ChatGPT app. "
        "Public CLI source availability is not required.\n\n"
        "## Test plan\n\n"
        "- [ ] Product CI passes for this commit.\n"
        "- [ ] Routing fixtures pass with this exact official Engine.\n"
        "- [x] Increment the Turnrail minor version and build number.\n\n"
        "This PR merges automatically after verified CI. Main CI then creates a "
        "Draft Release. Before publishing that draft, verify Codex UI turns, "
        "approvals, and account switching in ChatGPT.\n"
    )
    pr = github(
        f"repos/{repository}/pulls",
        method="POST",
        payload={
            "title": f"chore: update ChatGPT reference to {candidate['version']}",
            "head": branch,
            "base": "main",
            "draft": False,
            "body": body,
        },
    )
    print(pr["html_url"])
    # Explicit dispatch starts CI for this branch even when the PR uses GITHUB_TOKEN.
    github(
        f"repos/{repository}/actions/workflows/ci.yml/dispatches",
        method="POST",
        payload={"ref": branch, "inputs": {"scope": "auto"}},
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("observation", type=Path)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--publish", action="store_true")
    args = parser.parse_args()
    try:
        observation = json.loads(args.observation.read_text())
        if observation["supported"] != read_upstream(ROOT):
            raise ValueError("Supported metadata changed after the upstream scan.")
        if not app_candidate(observation):
            print("No newer official app candidate.")
            return 0
        candidate = observation["app"]
        branch = f"upstream/codex-app-{candidate['build']}"
        existing = github(
            f"repos/{args.repository}/pulls?state=all&head={args.repository.split('/')[0]}:{branch}"
        )
        if existing:
            print("This candidate has already been reviewed or is under review.")
            return 0
        with tempfile.TemporaryDirectory(prefix="turnrail-app-candidate-") as temporary:
            version = inspect_app(candidate, Path(temporary))
        prepare(ROOT, candidate, version)
        if args.publish:
            publish(args.repository, branch, candidate, version)
        else:
            print(f"Prepared {branch}; review the uncommitted changes.")
        return 0
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Upstream candidate preparation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
