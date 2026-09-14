#!/usr/bin/env python3
"""Identify release caches by compiler contract and exact source revision."""

import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import tomllib

ROOT = Path(__file__).resolve().parents[1]


def cache_keys(root, revision, toolchain, environment):
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("A full source commit is required for the release cache.")
    rust = root / "engine/codex-rs"
    manifest = tomllib.loads((rust / "Cargo.toml").read_text())
    build_variables = {
        "RUSTFLAGS",
        "RUSTC",
        "CARGO_ENCODED_RUSTFLAGS",
        "CARGO_BUILD_RUSTFLAGS",
        "CARGO_BUILD_RUSTC",
        "RUSTC_WRAPPER",
        "RUSTC_WORKSPACE_WRAPPER",
        "MACOSX_DEPLOYMENT_TARGET",
        "SDKROOT",
        "CC",
        "CXX",
        "CFLAGS",
        "CXXFLAGS",
        "LDFLAGS",
        "AR",
    }
    contract = {
        "target": "aarch64-apple-darwin",
        "profile": manifest["profile"]["release"],
        "cargo_config": (rust / ".cargo/config.toml").read_text(),
        "toolchain": toolchain,
        "environment": {
            key: value
            for key, value in environment.items()
            if key in build_variables
            or key.startswith("CARGO_PROFILE_RELEASE_")
            or key.startswith("CARGO_TARGET_AARCH64_APPLE_DARWIN_")
        },
    }
    digest = hashlib.sha256(json.dumps(contract, sort_keys=True).encode()).hexdigest()
    prefix = f"turnrail-release-v1-{digest}-"
    return {"key": prefix + revision, "prefix": prefix}


def main():
    try:
        if os.environ["GITHUB_ACTIONS"] != "true":
            raise ValueError("Release cache keys require GitHub Actions.")
        revision = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
        ).strip()
        subprocess.run(["git", "diff", "--quiet", "HEAD"], cwd=ROOT, check=True)
        toolchain = {
            name: subprocess.check_output(command, text=True).strip()
            for name, command in {
                "rustc": ["rustc", "--version", "--verbose"],
                "xcode": ["xcodebuild", "-version"],
                "sdk": ["xcrun", "--show-sdk-version"],
            }.items()
        }
        for key, value in cache_keys(ROOT, revision, toolchain, os.environ).items():
            print(f"{key}={value}")
        return 0
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"Release cache identification failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
