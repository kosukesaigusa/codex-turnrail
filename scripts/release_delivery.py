#!/usr/bin/env python3
"""Verify the uploaded draft asset against the original release checksums."""

import argparse
import datetime
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from github_api import github
from product_evidence import verify_report
from runtime_evidence import sha256

PENDING = "Uploaded ZIP verification: pending."
PASSED = (
    "Uploaded ZIP verification: SHA-256 and size matched after downloading from GitHub."
)
REPORT = "upload-verification.json"


def local_evidence(output, tag):
    if not re.fullmatch(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", tag):
        raise ValueError("A product release tag is required.")
    name = f"Codex-Turnrail-{tag}-macos-arm64.zip"
    required = {
        name,
        "build-manifest.json",
        "runtime-verification.json",
        "notarization-report.json",
    }
    checksums = {}
    for line in (output / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        if match is None or match[2] not in required or match[2] in checksums:
            raise ValueError("The original checksum list is malformed.")
        checksums[match[2]] = match[1]
    if checksums.keys() != required:
        raise ValueError("The original checksum list is incomplete.")
    for filename, digest in checksums.items():
        if sha256(output / filename) != digest:
            raise ValueError(
                f"A release file changed before delivery verification: {filename}"
            )
    manifest = json.loads((output / "build-manifest.json").read_text())
    if manifest["version"] != tag[1:] or manifest["notarized"] is not True:
        raise ValueError("The build manifest must match the notarized release.")
    if not re.fullmatch(r"[0-9a-f]{40}", manifest["source_commit"]):
        raise ValueError("The build manifest must identify the exact source commit.")
    verify_report(output / "runtime-verification.json")
    return manifest, name, checksums[name], (output / name).stat().st_size


def require_draft(details, tag, commit, name, digest, size):
    if (
        details["tag_name"] != tag
        or details["target_commitish"] != commit
        or details["draft"] is not True
        or details["prerelease"] is not False
    ):
        raise ValueError(
            "Delivery verification requires the exact source's draft release."
        )
    assets = details["assets"]
    if len(assets) != 1 or assets[0]["name"] != name:
        raise ValueError("The draft must contain only the app ZIP.")
    asset = assets[0]
    if (
        asset["state"] != "uploaded"
        or asset["digest"] != "sha256:" + digest
        or asset["size"] != size
        or type(asset["id"]) is not int
        or asset["id"] <= 0
    ):
        raise ValueError(
            "The uploaded asset metadata differs from the original archive."
        )
    return asset


def prepare_notes(output, repository, tag):
    manifest, name, digest, size = local_evidence(output, tag)
    app = manifest["upstream"]["app"]
    download = f"https://github.com/{repository}/releases/download/{tag}/{name}"
    note = f"[Download Codex Turnrail for macOS (Apple silicon)]({download}).\n\n"
    note += (
        "Unzip the app, move it to Applications, and open it. "
        "No Terminal commands are required.\n\n"
    )
    note += f"ChatGPT release reference: {app['version']} ({app['build']}).\n\n"
    note += (
        "Other ChatGPT versions can also be used. Version matching is not required "
        "and does not guarantee that every feature will work.\n\n"
    )
    note += "<details>\n<summary>Verification</summary>\n\n"
    note += f"- Product: {manifest['version']} ({manifest['build']}).\n"
    note += f"- Source: `{manifest['source_commit']}`.\n"
    note += f"- SHA-256: `{digest}`\n"
    note += f"- Archive size: {size} bytes.\n"
    note += "- Signature: " + manifest["signing_authorities"][0] + ".\n"
    note += (
        "- Apple notarization accepted; ticket attached and "
        "Gatekeeper assessment passed.\n"
    )
    note += (
        "- Runtime checks passed: Code Mode, approval acceptance, "
        "and approval rejection.\n"
    )
    note += f"- {PENDING}\n\n</details>\n"
    with (output / "notes.md").open("x") as target:
        target.write(note)


def download_asset(repository, asset_id, destination):
    with destination.open("xb") as target:
        subprocess.run(
            [
                "gh",
                "api",
                f"repos/{repository}/releases/assets/{asset_id}",
                "--header",
                "Accept: application/octet-stream",
            ],
            stdout=target,
            stderr=subprocess.PIPE,
            check=True,
            timeout=300,
        )


def verify_upload(output, repository, tag):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("A GitHub owner/repository is required.")
    report_path = output / REPORT
    if report_path.exists():
        raise ValueError("Delivery verification evidence already exists.")
    manifest, name, digest, size = local_evidence(output, tag)
    identity = json.loads(
        subprocess.check_output(
            [
                "gh",
                "release",
                "view",
                tag,
                "--repo",
                repository,
                "--json",
                "databaseId",
            ],
            text=True,
            timeout=60,
        )
    )
    release_id = identity["databaseId"]
    if type(release_id) is not int or release_id <= 0:
        raise ValueError("GitHub did not return a valid release ID.")
    endpoint = f"repos/{repository}/releases/{release_id}"
    details = github(endpoint)
    if details["id"] != release_id:
        raise ValueError("GitHub returned a different release ID.")
    commit = manifest["source_commit"]
    asset = require_draft(details, tag, commit, name, digest, size)
    if (
        details["body"].count(PENDING) != 1
        or f"SHA-256: `{digest}`" not in details["body"]
    ):
        raise ValueError(
            "The draft notes must contain the original hash and pending verification."
        )
    with tempfile.TemporaryDirectory(prefix="turnrail-release-download-") as temporary:
        downloaded = Path(temporary) / name
        download_asset(repository, asset["id"], downloaded)
        if downloaded.stat().st_size != size or sha256(downloaded) != digest:
            raise ValueError("The downloaded asset differs from the original archive.")
    payload = {
        "tag_name": tag,
        "target_commitish": commit,
        "name": details["name"],
        "draft": True,
        "prerelease": False,
        "body": details["body"].replace(PENDING, PASSED),
    }
    github(endpoint, method="PATCH", payload=payload)
    saved = github(endpoint)
    saved_asset = require_draft(saved, tag, commit, name, digest, size)
    if (
        saved["id"] != release_id
        or saved["name"] != details["name"]
        or saved["body"] != payload["body"]
        or saved_asset["id"] != asset["id"]
    ):
        raise ValueError("GitHub did not preserve the verified draft and its asset.")
    report = {
        "repository": repository,
        "tag": tag,
        "source_commit": commit,
        "release_id": release_id,
        "asset_id": asset["id"],
        "asset_name": name,
        "size": size,
        "sha256": digest,
        "verified_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "passed": True,
    }
    with report_path.open("x") as target:
        json.dump(report, target, indent=2)
        target.write("\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("notes", "verify"))
    parser.add_argument("output", type=Path)
    parser.add_argument("repository")
    parser.add_argument("tag")
    args = parser.parse_args()
    try:
        if args.action == "notes":
            prepare_notes(args.output, args.repository, args.tag)
        else:
            report = verify_upload(args.output, args.repository, args.tag)
            print(f"Verified uploaded {report['asset_name']}: {report['sha256']}")
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
    ) as error:
        print(f"Release delivery verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
