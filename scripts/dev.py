#!/usr/bin/env python3
"""Run product development commands with one storage and test-isolation policy."""

import argparse
import os
import shutil
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ENGINE_ROOT = REPO_ROOT / "engine"
APP_ROOT = REPO_ROOT / "app"
RUST_ROOT = ENGINE_ROOT / "codex-rs"
TARGET = RUST_ROOT / "target"
MIN_FREE_BYTES = 30 * 1024**3


class StoragePolicyError(Exception):
    """The requested command cannot safely use the development workspace."""


def available_space():
    free = shutil.disk_usage(RUST_ROOT).free
    print(f"Turnrail storage: {free / 1024**3:.1f} GiB available", flush=True)
    return free


def require_space(minimum):
    if available_space() < minimum:
        raise StoragePolicyError(
            f"At least {minimum // 1024**3} GiB must be available "
            "before starting a build, test, or lint. "
            "Finish active development commands, then run just finish."
        )


@contextmanager
def workspace_lock():
    cache = REPO_ROOT / ".cache"
    if cache.is_symlink():
        raise StoragePolicyError(f"Cache directory must not be a symlink: {cache}")
    cache.mkdir(exist_ok=True)
    lock = cache / "turnrail-dev.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise StoragePolicyError(
            f"Another development command holds {lock}. If it was interrupted, "
            "verify that it has stopped before removing the lock directory."
        ) from None
    try:
        yield
    finally:
        lock.rmdir()


def cargo_environment(inherited):
    if TARGET.is_symlink():
        raise StoragePolicyError(f"Target directory must not be a symlink: {TARGET}")
    environment = dict(inherited)
    for name in ("CARGO_TARGET_DIR", "CARGO_BUILD_TARGET_DIR", "CARGO_BUILD_BUILD_DIR"):
        if name in environment:
            configured = Path(environment[name])
            if not configured.is_absolute():
                configured = RUST_ROOT / configured
            if configured.resolve() != TARGET.resolve():
                raise StoragePolicyError(f"{name} must point to {TARGET}")
    environment["CARGO_INCREMENTAL"] = "0"
    environment["CARGO_TARGET_DIR"] = str(TARGET)
    environment["CARGO_BUILD_BUILD_DIR"] = str(TARGET)
    environment["CODEX_REPO_ROOT"] = str(ENGINE_ROOT)
    return environment


def cargo_command(arguments):
    if not arguments:
        raise StoragePolicyError("A Cargo command is required.")
    cargo_options = (
        arguments[: arguments.index("--")] if "--" in arguments else arguments
    )
    nextest = arguments[:2] == ["nextest", "run"]
    forbidden = {
        "--cargo-profile",
        "--release",
        "-r",
        "--target-dir",
        "--config",
        "--manifest-path",
    }
    if not nextest:
        forbidden.add("--profile")
    for option in cargo_options:
        if option.split("=", 1)[0] in forbidden:
            raise StoragePolicyError(
                f"{option.split('=', 1)[0]} conflicts with the "
                "dev-small storage policy."
            )
    if nextest:
        return [
            "cargo",
            "nextest",
            "run",
            "--cargo-profile",
            "dev-small",
            *arguments[2:],
        ]
    if arguments[0] in {"build", "check", "clippy", "run"}:
        return ["cargo", arguments[0], "--profile", "dev-small", *arguments[1:]]
    raise StoragePolicyError(
        "Use build, check, clippy, run, or nextest run for local development."
    )


def swift_command(arguments):
    if not arguments or arguments[0] not in {"build", "test"}:
        raise StoragePolicyError("Use build or test for local Swift development.")
    for option in arguments:
        if option.split("=", 1)[0] in {"--package-path", "--scratch-path"}:
            raise StoragePolicyError(f"{option} conflicts with the product layout.")
    return ["swift", arguments[0], "--package-path", str(APP_ROOT), *arguments[1:]]


def release_command(arguments):
    """Build the two distribution binaries with the upstream release profile."""
    if arguments:
        raise StoragePolicyError(
            "The distribution build does not accept Cargo overrides."
        )
    return [
        "cargo",
        "build",
        "--locked",
        "--profile",
        "release",
        "--timings",
        "--target",
        "aarch64-apple-darwin",
        "-p",
        "codex-cli",
        "-p",
        "codex-code-mode-host",
        "--bin",
        "codex",
        "--bin",
        "codex-code-mode-host",
    ]


def finish():
    if (
        not (APP_ROOT / "Package.swift").is_file()
        or not (APP_ROOT / "Sources/CodexTurnrailApp").is_dir()
    ):
        raise StoragePolicyError(f"App sources are missing: {APP_ROOT}")
    swift_build = APP_ROOT / ".build"
    if (
        swift_build.is_symlink()
        or APP_ROOT.is_symlink()
        or ENGINE_ROOT.is_symlink()
        or APP_ROOT.resolve().is_relative_to(TARGET.resolve())
        or REPO_ROOT.is_relative_to(swift_build.resolve())
    ):
        raise StoragePolicyError(
            "Cleanup paths must be independent directories, not symlinks."
        )
    environment = cargo_environment(os.environ)
    subprocess.run(
        ["cargo", "clean", "--target-dir", str(TARGET)],
        cwd=RUST_ROOT,
        env=environment,
        check=True,
    )
    subprocess.run(
        ["swift", "package", "--package-path", str(APP_ROOT), "clean"], check=True
    )
    print(
        "Cleaned Rust target and Swift build artifacts. "
        "Source and packaged apps are retained."
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ci",
        action="store_true",
        help="Use the explicit ephemeral-runner storage policy.",
    )
    commands = parser.add_subparsers(dest="action", required=True)
    commands.add_parser("storage")
    cargo = commands.add_parser("cargo")
    cargo.add_argument("arguments", nargs=argparse.REMAINDER)
    release = commands.add_parser("release-build")
    release.add_argument("arguments", nargs=argparse.REMAINDER)
    swift = commands.add_parser("swift")
    swift.add_argument("arguments", nargs=argparse.REMAINDER)
    commands.add_parser("finish")
    args = parser.parse_args()
    try:
        if args.ci and (
            "GITHUB_ACTIONS" not in os.environ or os.environ["GITHUB_ACTIONS"] != "true"
        ):
            raise StoragePolicyError("--ci requires an actual GitHub Actions runner.")
        if args.action == "storage":
            require_space(MIN_FREE_BYTES)
            return 0
        with workspace_lock():
            if args.action == "finish":
                finish()
            else:
                if args.action in {"cargo", "release-build"}:
                    command = (
                        cargo_command(args.arguments)
                        if args.action == "cargo"
                        else release_command(args.arguments)
                    )
                    environment = cargo_environment(os.environ)
                    working_directory = RUST_ROOT
                    is_test = args.arguments[:2] == ["nextest", "run"]
                else:
                    command = swift_command(args.arguments)
                    environment = dict(os.environ)
                    working_directory = APP_ROOT
                    is_test = args.arguments[0] == "test"
                if is_test:
                    # Tests supply their own account fixtures, never the host registry.
                    if "CODEX_TURNRAIL_ROOT" in environment:
                        del environment["CODEX_TURNRAIL_ROOT"]
                        print(
                            "Turnrail tests: removed inherited account routing.",
                            flush=True,
                        )
                require_space(5 * 1024**3 if args.ci else MIN_FREE_BYTES)
                subprocess.run(
                    command, cwd=working_directory, env=environment, check=True
                )
            available_space()
        return 0
    except (OSError, StoragePolicyError, subprocess.CalledProcessError) as error:
        print(f"Turnrail development failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
