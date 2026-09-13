#!/usr/bin/env python3
"""Format product and Engine sources from the repository root."""

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    swift = ["swift", "format"]
    swift += ["lint", "--strict"] if args.check else ["format", "--in-place"]
    swift += ["--recursive", "app/Package.swift", "app/Sources", "app/Tests"]
    python = ["uv", "run", "--frozen", "--project", "engine/scripts", "ruff"]
    python_lint = [*python, "check", "--select", "E,F,I"]
    if not args.check:
        python_lint.append("--fix")
    python_format = [*python, "format"]
    just_format = ["just", "--unstable", "--fmt"]
    if args.check:
        python_format.append("--check")
        just_format.append("--check")
    commands = [
        swift,
        [*python_format, "scripts", "tests"],
        [*python_lint, "scripts", "tests"],
        just_format,
        ["just", "--justfile", "engine/justfile", "fmt-check" if args.check else "fmt"],
        [
            "pnpm",
            "--dir",
            "engine",
            "exec",
            "prettier",
            "--check" if args.check else "--write",
            "--config",
            ".prettierrc.toml",
            "../README.md",
            "../AGENTS.md",
            "../docs/**/*.md",
            "../.github/**/*.yml",
            "../.markdownlint-cli2.jsonc",
        ],
        ["pnpm", "--dir", "engine", "run", "format" if args.check else "format:fix"],
    ]
    try:
        for command in commands:
            subprocess.run(command, cwd=ROOT, check=True)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Formatting failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
