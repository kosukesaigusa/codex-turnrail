#!/usr/bin/env python3
"""Prepare a README-only PR for the latest published stable app archive."""

import argparse
import re
import subprocess
import sys

from engine_artifacts import git
from github_api import github
from project_metadata import ROOT, VERSION, version_tuple


def download_url(repository, tag):
    version_tuple(tag.removeprefix("v"))
    if not tag.startswith("v"):
        raise ValueError("The release tag must start with v.")
    return (
        f"https://github.com/{repository}/releases/download/{tag}/"
        f"Codex-Turnrail-{tag}-macos-arm64.zip"
    )


def published_url(repository, tag):
    expected = download_url(repository, tag)
    release = github(f"repos/{repository}/releases/tags/{tag}")
    if release["tag_name"] != tag:
        raise ValueError("The release response does not match the requested tag.")
    if release["draft"] or release["prerelease"] or release["published_at"] is None:
        raise ValueError("README downloads require a published stable release.")
    if github(f"repos/{repository}/releases/latest")["tag_name"] != tag:
        print("This release is not the latest published release; README unchanged.")
        return None
    assets = [
        asset
        for asset in release["assets"]
        if asset["name"] == f"Codex-Turnrail-{tag}-macos-arm64.zip"
    ]
    if len(assets) != 1:
        raise ValueError("The published release must contain exactly one app ZIP.")
    asset = assets[0]
    if (
        asset["state"] != "uploaded"
        or asset["size"] <= 0
        or not isinstance(asset["digest"], str)
        or re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"]) is None
        or asset["browser_download_url"] != expected
    ):
        raise ValueError("The published app asset has invalid metadata.")
    return expected


def update_text(text, repository, tag, url):
    pattern = (
        rf"https://github\.com/{re.escape(repository)}/releases/download/"
        rf"(?P<tag>v{VERSION})/Codex-Turnrail-(?P=tag)-macos-arm64\.zip"
    )
    matches = list(re.finditer(pattern, text))
    if len(matches) != 1:
        raise ValueError("README must contain exactly one versioned app download link.")
    current = matches[0].group("tag")
    if version_tuple(current[1:]) >= version_tuple(tag[1:]):
        return text
    return re.sub(pattern, lambda _: url, text)


def dispatch_ci(repository, branch):
    github(
        f"repos/{repository}/actions/workflows/ci.yml/dispatches",
        method="POST",
        payload={"ref": branch, "inputs": {"scope": "auto"}},
    )


def prepare(root, repository, tag):
    url = published_url(repository, tag)
    if url is None:
        return
    path = root / "README.md"
    updated = update_text(path.read_text(), repository, tag, url)
    if updated == path.read_text():
        print("README already links to this version or a newer release.")
        return
    if git(root, "status", "--porcelain"):
        raise ValueError("README automation requires a clean main checkout.")
    branch = f"docs/release-{tag}"
    prs = github(
        f"repos/{repository}/pulls?state=all&head={repository.split('/')[0]}:{branch}"
    )
    if prs:
        print(f"README PR already exists: {prs[0]['html_url']}; edits are preserved.")
        if prs[0]["state"] == "open":
            dispatch_ci(repository, branch)
        return
    if git(root, "ls-remote", "origin", f"refs/heads/{branch}"):
        raise ValueError("The README branch exists without a PR; inspect it manually.")
    git(root, "switch", "-c", branch)
    path.write_text(updated)
    git(root, "add", "--", "README.md")
    git(root, "commit", "-m", f"docs: link to the {tag} app download")
    git(root, "push", "origin", f"HEAD:refs/heads/{branch}")
    pr = github(
        f"repos/{repository}/pulls",
        method="POST",
        payload={
            "title": f"docs: link to the {tag} app download",
            "head": branch,
            "base": "main",
            "body": (
                "## Summary\n\n"
                f"Point the README download link to the published {tag} app ZIP.\n\n"
                "## Test plan\n\n"
                "- [x] Confirm the latest stable release and its uploaded app asset.\n"
                "- [ ] README formatting and Markdown checks.\n\n"
                "CI selects checks from the actual changed files. This PR merges "
                "automatically after CI if only the verified download URL changed. "
                "Convert it to a draft to pause automatic merging."
            ),
        },
    )
    print(pr["html_url"])
    dispatch_ci(repository, branch)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    try:
        prepare(ROOT, args.repository, args.tag)
        return 0
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Release README update failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
