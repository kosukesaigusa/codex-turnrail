#!/usr/bin/env python3
"""Build and verify reusable Engine evidence independently of product versions."""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

from project_metadata import ROOT
from release import RUNTIME_BINARIES, sha256, verify_report
from upstream_watch import github

SCOPES = (
    "engine",
    "scripts",
    "tests",
    "justfile",
    ".github/workflows/ci.yml",
    ".github/workflows/source-checks.yml",
    ".github/workflows/dependency-policy.yml",
    ".github/workflows/engine-inputs.yml",
    ".github/workflows/engine.yml",
    ".github/workflows/engine-checks.yml",
    ".github/workflows/engine-release.yml",
    ".github/workflows/release.yml",
)
KINDS = {
    "checks": {"ci-runtime.json", "junit.xml"},
    "release": {"release-runtime.json", "runtime.tar.gz"},
    "verified": {
        "ci-runtime.json",
        "junit.xml",
        "release-runtime.json",
        "runtime.tar.gz",
    },
}
WORKFLOW = ".github/workflows/engine.yml"
MAX_ARCHIVE = 1024**3


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def revision(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ValueError("A full source commit is required.")
    return value


def git(root, *arguments):
    return subprocess.check_output(
        ["git", "-C", str(root), *arguments], text=True
    ).strip()


def source_inputs(root, commit):
    revision(commit)
    return {path: git(root, "rev-parse", f"{commit}:{path}") for path in SCOPES}


def remote_inputs(repository, commit):
    revision(commit)
    trees = {}

    def entries(tree):
        if tree not in trees:
            data = github(f"repos/{repository}/git/trees/{tree}")
            if data["truncated"] is not False:
                raise ValueError("The source tree response is truncated.")
            trees[tree] = {entry["path"]: entry["sha"] for entry in data["tree"]}
        return trees[tree]

    inputs = {}
    for path in SCOPES:
        value = commit
        for component in path.split("/"):
            value = entries(value)[component]
        inputs[path] = value
    return inputs


def runner_contract():
    if os.environ["GITHUB_ACTIONS"] != "true":
        raise ValueError("Engine artifact operations require GitHub Actions.")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Engine builds require an Apple silicon macOS runner.")
    # Do not let externally supplied compiler flags change the recorded contract.
    overrides = {
        "RUSTFLAGS",
        "RUSTC",
        "CARGO_ENCODED_RUSTFLAGS",
        "CARGO_BUILD_RUSTFLAGS",
        "CARGO_BUILD_RUSTC",
        "RUSTC_WRAPPER",
        "RUSTC_WORKSPACE_WRAPPER",
        "SDKROOT",
        "MACOSX_DEPLOYMENT_TARGET",
        "CC",
        "CXX",
        "CFLAGS",
        "CXXFLAGS",
        "LDFLAGS",
        "AR",
        "V8_FROM_SOURCE",
        "RUSTY_V8_ARCHIVE",
        "RUSTY_V8_SRC_BINDING_PATH",
    }
    for name in os.environ:
        if name in overrides or name.startswith(
            ("CARGO_PROFILE_", "CARGO_TARGET_AARCH64_")
        ):
            raise ValueError(f"Remove the external build override: {name}")
    commands = {
        "rustc": ["rustc", "--version", "--verbose"],
        "xcode": ["xcodebuild", "-version"],
        "sdk": ["xcrun", "--show-sdk-version"],
        "clang": ["xcrun", "clang", "--version"],
        "macos": ["sw_vers", "-buildVersion"],
    }
    return {
        **{
            key: subprocess.check_output(
                command, cwd=ROOT / "engine/codex-rs", text=True
            ).strip()
            for key, command in commands.items()
        },
        "image_os": os.environ["ImageOS"],
        "image_version": os.environ["ImageVersion"],
    }


def identity(inputs, runner):
    return {
        "schema_version": 1,
        "target": "aarch64-apple-darwin",
        "profiles": ["dev-small", "release"],
        "source_inputs": inputs,
        "runner": runner,
    }


def expected_identity():
    expected = json.loads(os.environ["ENGINE_IDENTITY"])
    actual = identity(
        source_inputs(ROOT, git(ROOT, "rev-parse", "HEAD")), expected["runner"]
    )
    if expected != actual:
        raise ValueError(
            "The checked-out Engine inputs do not match the selected identity."
        )
    if git(ROOT, "status", "--porcelain"):
        raise ValueError("Engine artifacts require a clean committed worktree.")
    return expected


def artifact_name(kind, key, attempt):
    if kind not in KINDS or not re.fullmatch(r"[0-9a-f]{64}", key) or int(attempt) < 1:
        raise ValueError("Invalid Engine artifact identity.")
    prefix = "turnrail-engine" if kind == "verified" else f"turnrail-engine-{kind}"
    return f"{prefix}-{key}-{attempt}"


def verify_junit(path):
    root = ET.fromstring(path.read_bytes())
    if root.tag != "testsuites" or int(root.attrib["tests"]) < 1:
        raise ValueError("Engine test evidence must contain executed tests.")
    if int(root.attrib["failures"]) != 0 or int(root.attrib["errors"]) != 0:
        raise ValueError("Engine test evidence contains failures.")
    if root.findall(".//failure") or root.findall(".//error"):
        raise ValueError("Engine test cases contain failures.")
    if len(root.findall(".//testcase")) != int(root.attrib["tests"]):
        raise ValueError("Engine test evidence has an inconsistent test count.")


def verify_files(directory, manifest, kind):
    names = KINDS[kind]
    if {path.name for path in directory.iterdir()} != names | {"manifest.json"}:
        raise ValueError("Unexpected or missing Engine evidence files.")
    if set(manifest["files"]) != names:
        raise ValueError("Engine evidence has incomplete checksums.")
    for name in names:
        path = directory / name
        if (
            path.is_symlink()
            or not path.is_file()
            or sha256(path) != manifest["files"][name]
        ):
            raise ValueError(f"Engine artifact checksum mismatch: {name}")
    if kind in {"checks", "verified"}:
        verify_report(directory / "ci-runtime.json")
        verify_junit(directory / "junit.xml")
    if kind in {"release", "verified"}:
        verify_report(directory / "release-runtime.json")


def read_manifest(directory, expected, kind):
    manifest = json.loads((directory / "manifest.json").read_text())
    if (
        manifest["schema_version"] != 1
        or manifest["kind"] != kind
        or manifest["identity"] != expected
        or manifest["key"] != digest(expected)
    ):
        raise ValueError(
            "Engine evidence does not match the required build and test inputs."
        )
    revision(manifest["source_commit"])
    revision(manifest["workflow_commit"])
    verify_files(directory, manifest, kind)
    return manifest


def write_manifest(directory, expected, kind):
    names = KINDS[kind]
    manifest = {
        "schema_version": 1,
        "kind": kind,
        "key": digest(expected),
        "identity": expected,
        "source_commit": git(ROOT, "rev-parse", "HEAD"),
        "workflow_commit": revision(os.environ["GITHUB_WORKFLOW_SHA"]),
        "repository": os.environ["GITHUB_REPOSITORY"],
        "run_id": int(os.environ["GITHUB_RUN_ID"]),
        "run_attempt": int(os.environ["GITHUB_RUN_ATTEMPT"]),
        "files": {name: sha256(directory / name) for name in sorted(names)},
    }
    (directory / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    verify_files(directory, manifest, kind)
    return manifest


def require_run(run, repository, *, current):
    if run["repository"]["full_name"] != repository:
        raise ValueError("Engine evidence must originate in this repository.")
    if run["head_repository"]["full_name"] != repository and not current:
        raise ValueError("Fork runs cannot provide reusable Engine evidence.")
    if run["path"] not in {".github/workflows/ci.yml", ".github/workflows/release.yml"}:
        raise ValueError("Engine evidence came from an unexpected workflow.")
    if run["event"] not in {"push", "pull_request", "workflow_dispatch"}:
        raise ValueError("Engine evidence came from an unexpected event.")
    if run["event"] == "push" and run["head_branch"] != "main":
        raise ValueError("Only main push runs may produce reusable Engine evidence.")
    if current:
        if run["status"] != "in_progress" or run["conclusion"] is not None:
            raise ValueError("The current Engine producer is not running.")
    elif run["status"] != "completed" or run["conclusion"] != "success":
        raise ValueError(
            "Reusable Engine evidence requires a successful completed run."
        )


def verify_provenance(manifest, artifact, run, repository, expected):
    if (
        manifest["repository"] != repository
        or manifest["run_id"] != run["id"]
        or manifest["run_attempt"] != run["run_attempt"]
        or artifact["workflow_run"]["id"] != run["id"]
    ):
        raise ValueError("Engine evidence run provenance does not match GitHub.")
    if artifact["name"] != artifact_name(
        manifest["kind"], digest(expected), run["run_attempt"]
    ):
        raise ValueError("The Engine artifact name does not match its provenance.")
    referenced = [
        item
        for item in run["referenced_workflows"]
        if item["path"] == f"{repository}/{WORKFLOW}@{item['sha']}"
    ]
    if len(referenced) != 1 or referenced[0]["sha"] != manifest["workflow_commit"]:
        raise ValueError("GitHub did not run the recorded Engine workflow revision.")
    for commit in {manifest["source_commit"], manifest["workflow_commit"]}:
        if remote_inputs(repository, commit) != expected["source_inputs"]:
            raise ValueError(
                "The producer source or workflow inputs differ from this checkout."
            )


def download(artifact, repository, directory):
    if artifact["expired"] is not False:
        raise ValueError(
            "The selected Engine artifact has expired; rerun CI to rebuild it."
        )
    if not 0 < artifact["size_in_bytes"] <= MAX_ARCHIVE:
        raise ValueError("The Engine artifact has an invalid size.")
    if not isinstance(artifact["digest"], str) or not re.fullmatch(
        r"sha256:[0-9a-f]{64}", artifact["digest"]
    ):
        raise ValueError("GitHub must provide the Engine artifact SHA-256.")
    if directory.exists():
        raise ValueError("The Engine artifact destination must not already exist.")
    with tempfile.TemporaryDirectory(prefix="turnrail-engine-download-") as temporary:
        archive = Path(temporary) / "artifact.zip"
        with archive.open("wb") as output:
            subprocess.run(
                [
                    "gh",
                    "api",
                    f"repos/{repository}/actions/artifacts/{artifact['id']}/zip",
                ],
                stdout=output,
                check=True,
                timeout=300,
            )
        if (
            archive.stat().st_size != artifact["size_in_bytes"]
            or "sha256:" + sha256(archive) != artifact["digest"]
        ):
            raise ValueError(
                "The downloaded Engine artifact failed size or checksum verification."
            )
        with zipfile.ZipFile(archive) as bundle:
            members = bundle.infolist()
            names = [member.filename for member in members]
            allowed = set.union(*KINDS.values()) | {"manifest.json"}
            if (
                len(names) != len(set(names))
                or not set(names) <= allowed
                or sum(member.file_size for member in members) > MAX_ARCHIVE
                or any(stat.S_ISLNK(member.external_attr >> 16) for member in members)
            ):
                raise ValueError("The Engine evidence archive contains unsafe entries.")
            directory.mkdir(parents=True)
            for member in members:
                with (
                    bundle.open(member) as source,
                    (directory / member.filename).open("xb") as target,
                ):
                    shutil.copyfileobj(source, target)


def restore(
    repository, artifact_id, expected, directory, *, kind="verified", current=False
):
    artifact = github(f"repos/{repository}/actions/artifacts/{int(artifact_id)}")
    run = github(f"repos/{repository}/actions/runs/{artifact['workflow_run']['id']}")
    if current and run["id"] != int(os.environ["GITHUB_RUN_ID"]):
        raise ValueError(
            "Only the current workflow may consume unfinished-run evidence."
        )
    require_run(run, repository, current=current)
    download(artifact, repository, directory)
    manifest = read_manifest(directory, expected, kind)
    verify_provenance(manifest, artifact, run, repository, expected)
    return manifest


def find_artifact(repository, expected, current_run):
    key = digest(expected)
    pattern = re.compile(rf"turnrail-engine-{key}-[1-9][0-9]*")
    page = 1
    while True:
        data = github(f"repos/{repository}/actions/artifacts?per_page=100&page={page}")
        for artifact in data["artifacts"]:
            if not pattern.fullmatch(artifact["name"]) or artifact["expired"]:
                continue
            producer = artifact["workflow_run"]
            if (
                producer["id"] == current_run
                or producer["head_repository_id"] != producer["repository_id"]
            ):
                continue
            run = github(f"repos/{repository}/actions/runs/{producer['id']}")
            # A queued duplicate can reach this point immediately after the Engine
            # gate finishes, a few seconds before its parent CI run completes.
            deadline = time.monotonic() + 180
            while run["status"] != "completed":
                if time.monotonic() >= deadline:
                    raise ValueError(
                        "An Engine producer is still running; retry after it completes."
                    )
                time.sleep(5)
                run = github(f"repos/{repository}/actions/runs/{producer['id']}")
            if run["conclusion"] != "success":
                continue
            if artifact["name"] != artifact_name("verified", key, run["run_attempt"]):
                continue
            require_run(run, repository, current=False)
            with tempfile.TemporaryDirectory(
                prefix="turnrail-engine-plan-"
            ) as temporary:
                restore(
                    repository, artifact["id"], expected, Path(temporary) / "evidence"
                )
            return {
                "mode": "reuse",
                "artifact_id": str(artifact["id"]),
                "reason": "matching verified Engine inputs",
            }
        if len(data["artifacts"]) < 100:
            return {
                "mode": "build",
                "artifact_id": "",
                "reason": "no retained successful artifact for these Engine inputs",
            }
        page += 1


def gate(needs):
    if needs["plan"]["result"] != "success":
        raise ValueError("Engine planning did not succeed.")
    mode = needs["plan"]["outputs"]["mode"]
    required = {"build": "success", "reuse": "skipped"}
    if mode not in required:
        raise ValueError("Engine plan must explicitly select build or reuse.")
    if any(needs[name]["result"] != required[mode] for name in ("checks", "release")):
        raise ValueError("Engine jobs do not satisfy the selected plan.")
    if mode == "reuse" and not needs["plan"]["outputs"]["artifact_id"].isdigit():
        raise ValueError("Engine reuse requires a verified artifact ID.")
    return mode


def pack_runtime(runtime, archive):
    for name in RUNTIME_BINARIES:
        if not (runtime / name).is_file() or not os.access(runtime / name, os.X_OK):
            raise ValueError(f"The runtime executable is missing: {name}")
    paths = sorted(runtime.rglob("*"))
    if any(
        path.is_symlink() or not (path.is_file() or path.is_dir()) for path in paths
    ):
        raise ValueError(
            "Runtime packages must contain only regular files and directories."
        )
    with tarfile.open(archive, "x:gz") as bundle:
        for path in paths:
            bundle.add(
                path, arcname=path.relative_to(runtime).as_posix(), recursive=False
            )


def unpack_runtime(archive, destination):
    if not destination.is_absolute() or destination.exists():
        raise ValueError("Runtime output must be a new absolute path.")
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        names = [member.name for member in members]
        if (
            len(names) != len(set(names))
            or sum(member.size for member in members) > MAX_ARCHIVE
            or any(
                not (member.isfile() or member.isdir())
                or member.name.startswith("/")
                or ".." in Path(member.name).parts
                or member.mode & 0o7000
                for member in members
            )
        ):
            raise ValueError("The runtime archive contains unsafe entries.")
        binaries = {
            member.name for member in members if member.isfile() and member.mode & 0o111
        }
        if not set(RUNTIME_BINARIES) <= binaries:
            raise ValueError("The runtime archive is missing an executable.")
        destination.mkdir(parents=True)
        bundle.extractall(destination, filter="data")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("identify")
    commands.add_parser("assert-runner")
    commands.add_parser("plan")
    commands.add_parser("gate")
    record = commands.add_parser("record")
    record.add_argument("kind", choices=("checks", "release"))
    record.add_argument("directory", type=Path)
    pack = commands.add_parser("pack")
    pack.add_argument("runtime", type=Path)
    pack.add_argument("archive", type=Path)
    seal = commands.add_parser("seal")
    seal.add_argument("checks_id", type=int)
    seal.add_argument("release_id", type=int)
    seal.add_argument("directory", type=Path)
    fetch = commands.add_parser("restore")
    fetch.add_argument("artifact_id", type=int)
    fetch.add_argument("directory", type=Path)
    fetch.add_argument("--current-run", action="store_true")
    install = commands.add_parser("install")
    install.add_argument("evidence", type=Path)
    install.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "gate":
            print(gate(json.loads(os.environ["NEEDS"])))
            return 0
        if args.command == "pack":
            pack_runtime(args.runtime, args.archive)
            return 0
        if args.command == "identify":
            current = git(ROOT, "rev-parse", "HEAD")
            if git(ROOT, "status", "--porcelain"):
                raise ValueError("Engine identification requires committed source.")
            value = identity(source_inputs(ROOT, current), runner_contract())
            print(f"key={digest(value)}")
            print(f"identity={json.dumps(value, sort_keys=True)}")
            print(f"source={current}")
            return 0
        expected = expected_identity()
        repository = os.environ["GITHUB_REPOSITORY"]
        if args.command == "assert-runner":
            if runner_contract() != expected["runner"]:
                raise ValueError(
                    "Runner image or compiler changed after Engine planning; rerun CI."
                )
        elif args.command == "plan":
            if (
                remote_inputs(repository, revision(os.environ["GITHUB_WORKFLOW_SHA"]))
                != expected["source_inputs"]
            ):
                raise ValueError(
                    "The invoking workflow and selected source "
                    "have different Engine inputs."
                )
            result = find_artifact(
                repository, expected, int(os.environ["GITHUB_RUN_ID"])
            )
            for key, value in result.items():
                print(f"{key}={value}")
        elif args.command == "record":
            write_manifest(args.directory, expected, args.kind)
        elif args.command == "restore":
            if args.current_run:
                # Release packaging may consume the result of its own completed
                # Engine gate, while the parent release workflow is still running.
                jobs = github(
                    f"repos/{repository}/actions/runs/{os.environ['GITHUB_RUN_ID']}/attempts/{os.environ['GITHUB_RUN_ATTEMPT']}/jobs?per_page=100"
                )["jobs"]
                gates = [
                    job
                    for job in jobs
                    if job["name"].endswith(" / Seal verified Engine")
                ]
                if len(gates) != 1 or gates[0]["conclusion"] != "success":
                    raise ValueError("The current run has no successful Engine gate.")
            restore(
                repository,
                args.artifact_id,
                expected,
                args.directory,
                current=args.current_run,
            )
        elif args.command == "install":
            read_manifest(args.evidence, expected, "verified")
            unpack_runtime(args.evidence / "runtime.tar.gz", args.destination)
        elif args.command == "seal":
            args.directory.mkdir(parents=True, exist_ok=False)
            with tempfile.TemporaryDirectory(
                prefix="turnrail-engine-seal-"
            ) as temporary:
                for kind, artifact_id in (
                    ("checks", args.checks_id),
                    ("release", args.release_id),
                ):
                    directory = Path(temporary) / kind
                    manifest = restore(
                        repository,
                        artifact_id,
                        expected,
                        directory,
                        kind=kind,
                        current=True,
                    )
                    if manifest["source_commit"] != git(ROOT, "rev-parse", "HEAD"):
                        raise ValueError("Engine jobs built different source commits.")
                    for name in KINDS[kind]:
                        shutil.copy2(directory / name, args.directory / name)
            write_manifest(args.directory, expected, "verified")
        return 0
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.CalledProcessError,
        subprocess.TimeoutExpired,
        tarfile.TarError,
        zipfile.BadZipFile,
        ET.ParseError,
    ) as error:
        print(f"Engine artifact verification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
