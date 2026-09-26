#!/usr/bin/env python3
"""Acquire and verify the pinned, unmodified ChatGPT installation for CI fixtures."""

import argparse
import json
import plistlib
import shutil
import stat
import subprocess
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from official_runtime import LAYOUT_FILES, resolve_runtime
from project_metadata import ROOT, cli_version, read_upstream, validate_cli_version
from runtime_evidence import sha256
from upstream_watch import download_app_file


def verify_signature(target, identifier):
    requirement = 'anchor apple generic and certificate leaf[subject.OU] = "2DC432GLL2"'
    if identifier is not None:
        requirement += f' and identifier "{identifier}"'
    subprocess.run(
        [
            "codesign",
            "--verify",
            "--deep",
            "--strict",
            "-R=" + requirement,
            str(target),
        ],
        check=True,
        timeout=120,
    )


def inspect(app, expected):
    """Inspect a signed app candidate without depending on a public CLI release."""
    app = app.resolve(strict=True)
    # The enclosing resource seal authenticates the package manifest and launcher.
    verify_signature(app, "com.openai.codex")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (
        info["CFBundleIdentifier"],
        info["CFBundleShortVersionString"],
        info["CFBundleVersion"],
    ) != (
        expected["bundle_identifier"],
        expected["version"],
        expected["build"],
    ):
        raise ValueError(
            "The official app metadata does not match the expected version and build."
        )
    runtime = resolve_runtime(app)
    for target, identifier in runtime.signature_targets:
        verify_signature(target, identifier)
    version = subprocess.check_output(
        [str(runtime.launcher), "--version"], text=True, timeout=30
    ).strip()
    validate_cli_version(version)
    if (
        runtime.package_version is not None
        and version != "codex-cli " + runtime.package_version
    ):
        raise ValueError(
            "The official Engine version does not match its package manifest."
        )
    return {
        "app": {
            "bundle_identifier": info["CFBundleIdentifier"],
            "version": info["CFBundleShortVersionString"],
            "build": info["CFBundleVersion"],
            "cli_version": version,
        },
        "cli_version": version,
        "signing_team": "2DC432GLL2",
        "layout": runtime.layout,
        "binaries": {name: sha256(path) for name, path in runtime.binaries.items()},
        "files": {
            relative: sha256(app / relative)
            for relative in set(LAYOUT_FILES[runtime.layout].values())
        },
    }


def verify(app, metadata):
    evidence = inspect(app, metadata["app"])
    if evidence["cli_version"] != cli_version(metadata):
        raise ValueError(
            "The signed official Engine version does not match the supported contract."
        )
    return evidence


def extract(archive, directory):
    directory.mkdir()
    with zipfile.ZipFile(archive) as bundle:
        entries = bundle.infolist()
        if (
            len(entries) > 150000
            or sum(item.file_size for item in entries) > 8 * 1024**3
        ):
            raise ValueError("The official app archive exceeds extraction limits.")
        seen = set()
        links = []
        for entry in entries:
            path = PurePosixPath(entry.filename)
            if (
                path.is_absolute()
                or ".." in path.parts
                or "\\" in entry.filename
                or path in seen
            ):
                raise ValueError("Unsafe or duplicate official app archive path.")
            seen.add(path)
            if stat.S_ISLNK(entry.external_attr >> 16):
                target = bundle.read(entry).decode()
                if (
                    not (directory / path.parent / target)
                    .resolve()
                    .is_relative_to(directory.resolve())
                ):
                    raise ValueError(
                        "An official app archive symlink escapes extraction."
                    )
                links.append((path, target))
            else:
                destination = Path(bundle.extract(entry, directory))
                destination.chmod((entry.external_attr >> 16) & 0o777)
        for path, target in links:
            link = directory / path
            link.parent.mkdir(parents=True, exist_ok=True)
            link.symlink_to(target)
        for path, _ in links:
            if not (directory / path).resolve().is_relative_to(directory.resolve()):
                raise ValueError("An official app symlink chain escapes extraction.")


def download(output, metadata):
    if output.exists():
        raise ValueError("The official app output already exists.")
    output.parent.mkdir(parents=True, exist_ok=True)
    version = metadata["app"]["version"]
    url = f"https://persistent.oaistatic.com/codex-app-prod/ChatGPT-darwin-arm64-{version}.zip"
    with tempfile.TemporaryDirectory(
        prefix="turnrail-official-app-", dir=output.parent
    ) as temporary:
        root = Path(temporary)
        archive = root / "official.zip"
        download_app_file(url, archive, max_bytes=2 * 1024**3, timeout=600)
        extract(archive, root / "extracted")
        source = root / "extracted/ChatGPT.app"
        verify(source, metadata)
        shutil.move(source, output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("verify", "download"))
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    metadata = read_upstream(ROOT)
    if args.action == "download":
        download(args.app, metadata)
    print(json.dumps(verify(args.app, metadata), indent=2))


if __name__ == "__main__":
    main()
