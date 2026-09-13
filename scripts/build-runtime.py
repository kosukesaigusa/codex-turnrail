#!/usr/bin/env python3
"""Build the native Codex package using the Engine checkout's verified V8 pair."""

import argparse
import os
import platform
import subprocess
import sys
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package_directory", type=Path)
    parser.add_argument("profile", choices=("dev-small", "release"))
    parser.add_argument("--ci", action="store_true")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    engine = repository / "engine"
    package = args.package_directory
    if not package.is_absolute():
        parser.error(f"Path must be absolute: {package}")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("Codex Turnrail requires Apple silicon macOS.")
    if package.exists():
        parser.error(f"Package output already exists: {package}")
    for generated in (
        engine / "codex-rs/target",
        repository / "app/.build",
    ):
        if package.resolve().is_relative_to(generated.resolve()):
            parser.error(
                f"Output must be outside generated build directories: {generated}"
            )
    for name in ("V8_FROM_SOURCE", "RUSTY_V8_ARCHIVE", "RUSTY_V8_SRC_BINDING_PATH"):
        if name in os.environ:
            parser.error(
                f"Remove {name}; this build uses the verified upstream V8 pair."
            )

    os.environ["CODEX_REPO_ROOT"] = str(engine)
    sys.path.insert(0, str(engine / "scripts"))
    from codex_package.targets import TARGET_SPECS, default_target
    from codex_package.v8 import resolve_codex_v8_cargo_env

    target = default_target()
    just = ["just", "--justfile", str(engine / "justfile")]
    if args.ci:
        if args.profile != "release":
            parser.error("The CI distribution path requires the release profile.")
        if "GITHUB_ACTIONS" not in os.environ or os.environ["GITHUB_ACTIONS"] != "true":
            parser.error("--ci requires a GitHub Actions runner.")
    else:
        subprocess.run([*just, "storage"], check=True)
    environment = {
        **os.environ,
        **resolve_codex_v8_cargo_env(TARGET_SPECS[target]),
    }
    if args.profile == "release":
        build = [sys.executable, str(repository / "scripts/dev.py")]
        if args.ci:
            build.append("--ci")
        build.append("release-build")
    else:
        build = [
            *just,
            "build",
            "--locked",
            "--target",
            target,
            "-p",
            "codex-cli",
            "-p",
            "codex-code-mode-host",
            "--bin",
            "codex",
            "--bin",
            "codex-code-mode-host",
        ]
    subprocess.run(build, env=environment, check=True)
    binaries = engine / "codex-rs/target" / target / args.profile
    subprocess.run(
        [
            *just,
            "assemble-codex-package",
            "--variant",
            "codex",
            "--target",
            target,
            "--package-dir",
            str(package),
            "--entrypoint-bin",
            str(binaries / "codex"),
            "--code-mode-host-bin",
            str(binaries / "codex-code-mode-host"),
        ],
        env=environment,
        check=True,
    )


if __name__ == "__main__":
    main()
