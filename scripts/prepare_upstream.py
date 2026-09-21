#!/usr/bin/env python3
"""Inspect an official app candidate and prepare an isolated upstream update PR."""

import argparse
import json
import plistlib
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from github_api import github
from project_metadata import (
    GENERATED,
    ROOT,
    VERSION_GENERATED,
    codex_version,
    metadata_bytes,
    product_version,
    read_upstream,
    supported_swift,
    version_tuple,
)
from release import bump
from sync_upstream import UpstreamError, update
from upstream_watch import app_candidate, download_app_file, source_release


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
    extracted.mkdir()
    with zipfile.ZipFile(archive) as bundle:
        links = []
        for entry in bundle.infolist():
            path = PurePosixPath(entry.filename)
            if path.is_absolute() or ".." in path.parts or "\\" in entry.filename:
                raise ValueError("Unsafe path in official app archive.")
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = bundle.read(entry).decode()
                resolved = (extracted / path.parent / target).resolve()
                if not resolved.is_relative_to(extracted.resolve()):
                    raise ValueError("Unsafe symlink in official app archive.")
                links.append((path, target))
            else:
                destination = Path(bundle.extract(entry, extracted))
                destination.chmod((entry.external_attr >> 16) & 0o777)
        # Create symlinks only after ordinary files, so extraction cannot traverse one.
        for path, target in links:
            link = extracted / path
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)
        for path, _ in links:
            if not (extracted / path).resolve().is_relative_to(extracted.resolve()):
                raise ValueError(
                    "The extracted app contains an escaping symlink chain."
                )
    app = extracted / "ChatGPT.app"
    requirement = (
        'anchor apple generic and identifier "com.openai.codex" '
        'and certificate leaf[subject.OU] = "2DC432GLL2"'
    )
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", "-R=" + requirement, str(app)],
        check=True,
    )
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {
        "CFBundleIdentifier": "com.openai.codex",
        "CFBundleShortVersionString": candidate["version"],
        "CFBundleVersion": candidate["build"],
    }
    if any(info[key] != value for key, value in expected.items()):
        raise ValueError("The signed app metadata does not match the update feed.")
    version = subprocess.check_output(
        [str(app / "Contents/Resources/codex"), "--version"], text=True
    ).strip()
    if not version.startswith("codex-cli "):
        raise ValueError("The candidate app does not report a Codex CLI version.")
    tag = "rust-v" + version.removeprefix("codex-cli ")
    codex_version(tag)
    return tag


def prepare(root, candidate, tag):
    current, _ = product_version(root)
    major, minor, _ = version_tuple(current)
    if major != 0:
        raise ValueError("Automatic upstream versioning requires the 0.x policy.")
    source_release(tag)
    commit = update(root, tag)
    metadata = read_upstream(root)
    metadata["app"] = {
        "bundle_identifier": "com.openai.codex",
        "version": candidate["version"],
        "build": candidate["build"],
    }
    (root / "upstream.toml").write_bytes(metadata_bytes(metadata))
    (root / GENERATED).write_text(supported_swift(metadata))
    bump(root, f"0.{minor + 1}.0")
    return commit


def publish(repository, branch, candidate, tag, commit):
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
            "engine",
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
            f"chore: support ChatGPT {candidate['version']} ({candidate['build']})",
        ],
        check=True,
    )
    subprocess.run(["git", "push", "origin", f"HEAD:refs/heads/{branch}"], check=True)
    body = (
        "## Summary\n\n"
        f"Update the supported ChatGPT macOS app to {candidate['version']} "
        f"({candidate['build']}). "
        f"Its signed bundle reports Codex CLI {tag[6:]}; Engine base is `{commit}`.\n\n"
        "The official Apple signature and exact app metadata passed inspection. "
        "The Engine changes were prepared with a three-way upstream merge.\n\n"
        "## Test plan\n\n"
        "- [ ] Product CI passes for this commit.\n"
        "- [x] Increment the Turnrail minor version and build number.\n\n"
        "This PR merges automatically after verified CI. Main CI then creates a "
        "Draft Release. Before publishing that draft, verify Codex UI turns, "
        "approvals, and account switching in ChatGPT.\n"
    )
    pr = github(
        f"repos/{repository}/pulls",
        method="POST",
        payload={
            "title": f"chore: support ChatGPT {candidate['version']}",
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
            tag = inspect_app(candidate, Path(temporary))
        commit = prepare(ROOT, candidate, tag)
        if args.publish:
            publish(args.repository, branch, candidate, tag, commit)
        else:
            print(f"Prepared {branch}; review the uncommitted changes.")
        return 0
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        UpstreamError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Upstream candidate preparation failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
