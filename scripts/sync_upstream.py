#!/usr/bin/env python3
"""Merge a pinned Codex release into engine without committing product changes."""

import argparse
import subprocess
import sys
from pathlib import Path

from project_metadata import codex_version, metadata_bytes, read_upstream


class UpstreamError(Exception):
    """The upstream update cannot be applied without operator intervention."""


def git(root, *arguments, input_bytes=None):
    result = subprocess.run(
        ["git", "-C", str(root), *arguments],
        input=input_bytes,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode:
        raise UpstreamError(result.stderr.decode().strip())
    return result.stdout


def product_tree(root, head, engine_tree, metadata_blob):
    entries = git(root, "ls-tree", "-z", head).split(b"\0")
    replacements = {
        b"engine": f"040000 tree {engine_tree}\tengine".encode(),
        b"upstream.toml": f"100644 blob {metadata_blob}\tupstream.toml".encode(),
    }
    result = []
    replaced = set()
    for entry in entries:
        if not entry:
            continue
        _, name = entry.split(b"\t", 1)
        if name in replacements:
            result.append(replacements[name])
            replaced.add(name)
        else:
            result.append(entry)
    if replaced != set(replacements):
        raise UpstreamError(
            "Commit engine/ and upstream.toml before updating upstream."
        )
    return (
        git(root, "mktree", "-z", input_bytes=b"\0".join(result) + b"\0")
        .decode()
        .strip()
    )


def require_clean(root):
    if git(root, "status", "--porcelain=v1", "--untracked-files=normal"):
        raise UpstreamError("Commit or remove local changes before updating upstream.")


def update(root, tag):
    require_clean(root)
    head = git(root, "rev-parse", "HEAD").decode().strip()
    metadata = read_upstream(root)
    codex = metadata["codex"]
    if not tag.startswith("rust-v"):
        raise UpstreamError(
            "Select an upstream Codex release tag beginning with rust-v."
        )
    codex_version(tag)
    git(root, "check-ref-format", f"refs/tags/{tag}")

    # Fetch objects without adding an upstream remote or changing local tag refs.
    git(
        root,
        "fetch",
        "--no-tags",
        codex["repository"],
        codex["commit"],
    )
    baseline = git(root, "rev-parse", "FETCH_HEAD^{commit}").decode().strip()
    if baseline != codex["commit"]:
        raise UpstreamError("The fetched baseline does not match upstream.toml.")
    git(
        root,
        "fetch",
        "--no-tags",
        codex["repository"],
        f"refs/tags/{tag}",
    )
    incoming = git(root, "rev-parse", "FETCH_HEAD^{commit}").decode().strip()

    current_metadata = git(root, "rev-parse", f"{head}:upstream.toml").decode().strip()
    incoming_values = {
        **metadata,
        "codex": {"repository": codex["repository"], "tag": tag, "commit": incoming},
    }
    incoming_metadata = (
        git(
            root,
            "hash-object",
            "-w",
            "--stdin",
            input_bytes=metadata_bytes(incoming_values),
        )
        .decode()
        .strip()
    )
    baseline_tree = product_tree(
        root,
        head,
        git(root, "rev-parse", f"{baseline}^{{tree}}").decode().strip(),
        current_metadata,
    )
    incoming_tree = product_tree(
        root,
        head,
        git(root, "rev-parse", f"{incoming}^{{tree}}").decode().strip(),
        incoming_metadata,
    )
    # These temporary commit objects provide a merge base without moving any refs.
    baseline_commit = (
        git(
            root,
            "commit-tree",
            baseline_tree,
            input_bytes=b"Codex upstream merge base\n",
        )
        .decode()
        .strip()
    )
    incoming_commit = (
        git(
            root,
            "commit-tree",
            incoming_tree,
            input_bytes=b"Codex upstream candidate\n",
        )
        .decode()
        .strip()
    )
    merge = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "merge-tree",
            "--write-tree",
            f"--merge-base={baseline_commit}",
            head,
            incoming_commit,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if merge.returncode:
        details = (merge.stdout + merge.stderr).decode().strip()
        raise UpstreamError(
            "Upstream merge requires conflict resolution; "
            f"files are unchanged.\n{details}"
        )
    merged_tree = merge.stdout.decode().splitlines()[0]
    patch = git(
        root,
        "diff",
        "--binary",
        "--full-index",
        "--no-ext-diff",
        "--no-textconv",
        "--no-renames",
        head,
        merged_tree,
        "--",
        "engine",
        "upstream.toml",
    )
    require_clean(root)
    if git(root, "rev-parse", "HEAD").decode().strip() != head:
        raise UpstreamError("HEAD changed while preparing the upstream update.")
    if patch:
        git(root, "apply", "--check", "--binary", input_bytes=patch)
        git(root, "apply", "--binary", input_bytes=patch)
    workspace = root / "engine/codex-rs"
    if not (workspace / "Cargo.lock").is_file():
        raise UpstreamError("The merged Engine must contain its Cargo.lock lockfile.")
    try:
        # Refresh workspace versions without unlocking existing external dependencies.
        subprocess.run(["cargo", "update", "--workspace"], cwd=workspace, check=True)
        subprocess.run(
            [
                "cargo",
                "metadata",
                "--locked",
                "--all-features",
                "--format-version",
                "1",
            ],
            cwd=workspace,
            stdout=subprocess.DEVNULL,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        raise UpstreamError(
            "Engine lockfile refresh or validation failed; inspect the pending update."
        ) from error
    return incoming


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        commit = update(root, args.tag)
    except (OSError, KeyError, TypeError, ValueError, UpstreamError) as error:
        print(f"Upstream update failed: {error}", file=sys.stderr)
        return 1
    print(f"Prepared {args.tag} ({commit}). Review and test the uncommitted changes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
