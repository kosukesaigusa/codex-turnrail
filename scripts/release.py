#!/usr/bin/env python3
"""Prepare product versions and verified, immutable draft release artifacts."""

import argparse
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path

import notarization
from product_evidence import PRODUCT_BINARIES, verify_report
from project_metadata import (
    ROOT,
    cli_version,
    product_version,
    validate,
    version_tuple,
    write_product_version,
)
from runtime_evidence import sha256

APP_NAME = "Codex Turnrail.app"


def run(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


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


def runtime_hashes(output):
    directory = output / APP_NAME / "Contents/MacOS"
    if (output / APP_NAME / "Contents/Resources/engine").exists():
        raise ValueError("Turnrail must not distribute a replacement Engine.")
    return {name: sha256(directory / name) for name in PRODUCT_BINARIES}


def record(output):
    metadata = validate(ROOT)
    report = output / "runtime-verification.json"
    evidence = verify_report(report)
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
        "profile": "release",
        "signing_authorities": authorities,
        "notarized": False,
        "swift": run("swift", "--version"),
        "binaries": runtime_hashes(output),
        "runtime_report_sha256": sha256(report),
    }
    manifest["engine"] = {
        "origin": "installed-official",
        "evidence": evidence["official_engine"],
    }
    if evidence["router_sha256"] != manifest["binaries"]["CodexTurnrailRouter"]:
        raise ValueError("The verified router differs from the packaged executable.")
    validate_engine_source(manifest)
    (output / "build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def validate_engine_source(manifest):
    engine = manifest["engine"]
    if engine["origin"] != "installed-official":
        raise ValueError("Turnrail requires an unmodified installed official Engine.")
    evidence = engine["evidence"]
    if (
        evidence["app"] != manifest["upstream"]["app"]
        or evidence["cli_version"] != cli_version(manifest["upstream"])
        or evidence["signing_team"] != "2DC432GLL2"
    ):
        raise ValueError(
            "Official Engine evidence does not match the supported contract."
        )


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
    evidence = verify_report(report)
    if (
        evidence["official_engine"] != manifest["engine"]["evidence"]
        or evidence["router_sha256"] != manifest["binaries"]["CodexTurnrailRouter"]
    ):
        raise ValueError(
            "Runtime evidence does not match the packaged router and official Engine."
        )
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
        *(app / "Contents/MacOS" / name for name in PRODUCT_BINARIES),
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
    commands.add_parser("notary-preflight")
    notarized = commands.add_parser("notarize")
    notarized.add_argument("output", type=Path)
    notarized.add_argument("tag")
    manifest = commands.add_parser("record")
    manifest.add_argument("output", type=Path)
    package = commands.add_parser("archive")
    package.add_argument("output", type=Path)
    package.add_argument("tag")
    args = parser.parse_args()
    try:
        if args.action == "version":
            bump(ROOT, args.version)
        elif args.action == "record":
            record(args.output)
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
