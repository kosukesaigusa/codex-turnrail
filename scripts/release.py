#!/usr/bin/env python3
"""Prepare product versions and verified, immutable draft release artifacts."""

import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

import notarization
from project_metadata import (
    ROOT,
    cli_version,
    product_version,
    validate,
    version_tuple,
    write_product_version,
)
from upstream_watch import github, source_release

APP_NAME = "Codex Turnrail.app"
RUNTIME_BINARIES = (
    "bin/codex",
    "bin/codex-code-mode-host",
    "codex-path/rg",
    "codex-resources/zsh/bin/zsh",
)


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def bump(root, version):
    current, build = product_version(root)
    if version_tuple(version) <= version_tuple(current):
        raise ValueError(
            "The next product version must be greater than the current version."
        )
    path = root / "packaging/Info.plist"
    info = plistlib.loads(path.read_bytes())
    info["CFBundleShortVersionString"] = version
    info["CFBundleVersion"] = str(int(build) + 1)
    path.write_bytes(plistlib.dumps(info, sort_keys=False))
    write_product_version(root)


def check_cli(path, metadata):
    actual = run(str(path), "--version")
    expected = cli_version(metadata)
    if actual != expected:
        raise ValueError(f"Official CLI must report {expected}; received {actual}.")


def download_cli(output, metadata):
    if output.exists():
        raise ValueError(f"Official CLI output already exists: {output}")
    codex = metadata["codex"]
    tag = codex["tag"]
    ref = github(f"repos/openai/codex/git/ref/tags/{tag}")["object"]
    if ref["type"] == "tag":
        ref = github(f"repos/openai/codex/git/tags/{ref['sha']}")["object"]
    if ref["type"] != "commit" or ref["sha"] != codex["commit"]:
        raise ValueError(
            "The official release tag no longer matches the pinned source commit."
        )
    release = source_release(tag)
    name = "codex-aarch64-apple-darwin.tar.gz"
    assets = [asset for asset in release["assets"] if asset["name"] == name]
    if len(assets) != 1:
        raise ValueError("The official CLI release must contain one arm64 archive.")
    asset = assets[0]
    digest = asset["digest"]
    if not isinstance(digest, str) or not digest.startswith("sha256:"):
        raise ValueError("GitHub did not provide the official CLI archive SHA-256.")
    with tempfile.TemporaryDirectory(prefix="turnrail-official-cli-") as temporary:
        archive = Path(temporary) / name
        with urllib.request.urlopen(
            asset["browser_download_url"], timeout=60
        ) as source:
            with archive.open("wb") as target:
                while block := source.read(1024 * 1024):
                    if target.tell() + len(block) > asset["size"]:
                        raise ValueError(
                            "The official CLI archive exceeds its declared size."
                        )
                    target.write(block)
        if (
            archive.stat().st_size != asset["size"]
            or "sha256:" + sha256(archive) != digest
        ):
            raise ValueError(
                "The official CLI archive failed size or checksum verification."
            )
        with tarfile.open(archive) as bundle:
            members = bundle.getmembers()
            if len(members) != 1 or not members[0].isfile():
                raise ValueError(
                    "The official CLI archive must contain exactly one file."
                )
            if members[0].name != "codex-aarch64-apple-darwin":
                raise ValueError("Unexpected official CLI executable name.")
            bundle.extractall(temporary, filter="data")
        executable = Path(temporary) / members[0].name
        check_cli(executable, metadata)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(executable.read_bytes())
        output.chmod(0o755)


def runtime_hashes(output):
    resources = output / APP_NAME / "Contents/Resources/engine"
    hashes = {name: sha256(resources / name) for name in RUNTIME_BINARIES}
    hashes["CodexTurnrailApp"] = sha256(
        output / APP_NAME / "Contents/MacOS/CodexTurnrailApp"
    )
    return hashes


def verify_report(path):
    report = json.loads(path.read_text())
    expected = {"code_mode", "approval_accept", "approval_decline"}
    if not isinstance(report, list) or len(report) != len(expected):
        raise ValueError("The runtime verification report is incomplete.")
    if {case["case"] for case in report} != expected or any(
        case["passed"] is not True for case in report
    ):
        raise ValueError("Every required runtime scenario must pass.")


def record(output, profile, engine_provenance):
    metadata = validate(ROOT)
    report = output / "runtime-verification.json"
    verify_report(report)
    signature = subprocess.run(
        ["codesign", "-dvv", str(output / APP_NAME)],
        capture_output=True,
        text=True,
        check=True,
    ).stderr
    authorities = [
        line[10:] for line in signature.splitlines() if line.startswith("Authority=")
    ]
    if not authorities:
        raise ValueError(
            "The app must have an identity signature; ad-hoc signing is not accepted."
        )
    manifest = {
        **metadata,
        "source_commit": run("git", "-C", str(ROOT), "rev-parse", "HEAD"),
        "dirty": bool(run("git", "-C", str(ROOT), "status", "--porcelain")),
        "target": "aarch64-apple-darwin",
        "profile": profile,
        "signing_authorities": authorities,
        "notarized": False,
        "rustc": subprocess.check_output(
            ["rustc", "--version"], cwd=ROOT / "engine/codex-rs", text=True
        ).strip(),
        "swift": run("swift", "--version"),
        "binaries": runtime_hashes(output),
        "runtime_report_sha256": sha256(report),
    }
    if engine_provenance is None:
        manifest["engine"] = {
            "origin": "source-build",
            "source_commit": manifest["source_commit"],
            "profile": profile,
        }
    else:
        from engine_artifacts import expected_identity, read_manifest

        evidence = read_manifest(
            engine_provenance.parent, expected_identity(), "verified"
        )
        if profile != "release":
            raise ValueError("Verified Engine artifacts require the release profile.")
        manifest["engine"] = {"origin": "verified-artifact", "evidence": evidence}
    (output / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def validate_engine_source(manifest):
    from engine_artifacts import digest, identity, revision, source_inputs

    engine = manifest["engine"]
    if engine["origin"] == "source-build":
        if (
            engine["source_commit"] != manifest["source_commit"]
            or engine["profile"] != manifest["profile"]
        ):
            raise ValueError(
                "The Engine build does not match the app source and profile."
            )
    elif engine["origin"] == "verified-artifact":
        evidence = engine["evidence"]
        expected = identity(
            source_inputs(ROOT, manifest["source_commit"]),
            evidence["identity"]["runner"],
        )
        if (
            manifest["profile"] != "release"
            or evidence["schema_version"] != 1
            or evidence["kind"] != "verified"
            or evidence["identity"] != expected
            or evidence["key"] != digest(expected)
        ):
            raise ValueError(
                "The Engine evidence does not match the app's Engine inputs."
            )
        revision(evidence["source_commit"])
        revision(evidence["workflow_commit"])
    else:
        raise ValueError("The app manifest has an unknown Engine origin.")


def validate_distribution(output, tag):
    metadata = validate(ROOT, tag=tag)
    manifest_path = output / "build-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    for key, value in metadata.items():
        if manifest[key] != value:
            raise ValueError(f"Build manifest does not match current {key} metadata.")
    if manifest["profile"] != "release" or manifest["dirty"] is not False:
        raise ValueError(
            "Release archives require a release-profile build from committed source."
        )
    if not manifest["signing_authorities"][0].startswith("Developer ID Application: "):
        raise ValueError("Distribution requires Developer ID Application signing.")
    if manifest["source_commit"] != run("git", "-C", str(ROOT), "rev-parse", "HEAD"):
        raise ValueError("The app was built from a different source revision.")
    if run("git", "-C", str(ROOT), "status", "--porcelain"):
        raise ValueError("Commit source changes before preparing a release archive.")
    validate_engine_source(manifest)
    if manifest["binaries"] != runtime_hashes(output):
        raise ValueError("A packaged binary changed after runtime verification.")
    report = output / "runtime-verification.json"
    verify_report(report)
    if sha256(report) != manifest["runtime_report_sha256"]:
        raise ValueError("The runtime verification report changed after the build.")
    app = output / APP_NAME
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (
        metadata["version"],
        metadata["build"],
    ):
        raise ValueError("The packaged app version does not match the release.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    return manifest


def notarize(output, tag):
    manifest = validate_distribution(output, tag)
    app = output / APP_NAME
    executables = [
        app,
        *(app / "Contents/Resources/engine" / name for name in RUNTIME_BINARIES),
    ]
    for executable in executables:
        signature = subprocess.run(
            ["codesign", "--display", "--verbose=4", str(executable)],
            capture_output=True,
            text=True,
            check=True,
        ).stderr
        if not all(
            value in signature
            for value in (
                "Authority=Developer ID Application: ",
                "(runtime)",
                "Timestamp=",
            )
        ):
            raise ValueError(
                "Developer ID signing, hardened runtime, and a timestamp "
                f"are required: {executable.name}"
            )
    notarization.notarize(app, output, os.environ)
    manifest["notarized"] = True
    manifest["notarization_report_sha256"] = sha256(output / notarization.REPORT)
    notarization.write_json(output / "build-manifest.json", manifest)


def archive(output, tag):
    manifest = validate_distribution(output, tag)
    manifest_path = output / "build-manifest.json"
    app = output / APP_NAME
    report = output / "runtime-verification.json"
    notary_report = output / notarization.REPORT
    if manifest["notarized"] is not True:
        raise ValueError("Release archives require a notarized app.")
    if sha256(notary_report) != manifest["notarization_report_sha256"]:
        raise ValueError("The notarization report changed after verification.")
    notarization.verify_report(app, output)
    archive_path = output / f"Codex-Turnrail-{tag}-macos-arm64.zip"
    checksum = output / "SHA256SUMS"
    if archive_path.exists() or checksum.exists():
        raise ValueError(
            "Release artifacts already exist; do not replace verified files."
        )
    subprocess.run(
        [
            "ditto",
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            str(app),
            str(archive_path),
        ],
        check=True,
    )
    artifacts = [archive_path, manifest_path, report, notary_report]
    checksum.write_text("".join(f"{sha256(path)}  {path.name}\n" for path in artifacts))
    return [archive_path]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    prepare = commands.add_parser("version")
    prepare.add_argument("version")
    cli = commands.add_parser("check-cli")
    cli.add_argument("executable", type=Path)
    download = commands.add_parser("download-cli")
    download.add_argument("output", type=Path)
    commands.add_parser("notary-preflight")
    notarized = commands.add_parser("notarize")
    notarized.add_argument("output", type=Path)
    notarized.add_argument("tag")
    manifest = commands.add_parser("record")
    manifest.add_argument("output", type=Path)
    manifest.add_argument("profile", choices=("dev-small", "release"))
    manifest.add_argument("--engine-provenance", type=Path)
    package = commands.add_parser("archive")
    package.add_argument("output", type=Path)
    package.add_argument("tag")
    args = parser.parse_args()
    try:
        if args.action == "version":
            bump(ROOT, args.version)
        elif args.action == "check-cli":
            check_cli(args.executable, validate(ROOT)["upstream"])
        elif args.action == "download-cli":
            download_cli(args.output, validate(ROOT)["upstream"])
        elif args.action == "record":
            record(args.output, args.profile, args.engine_provenance)
        elif args.action == "notary-preflight":
            notarization.preflight(os.environ)
        elif args.action == "notarize":
            notarize(args.output, args.tag)
        else:
            for path in archive(args.output, args.tag):
                print(path)
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
