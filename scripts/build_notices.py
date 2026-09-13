#!/usr/bin/env python3
"""Assemble dependency license texts for the exact source and packaged tools."""

import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile
import tempfile
import urllib.parse
import urllib.request
from pathlib import Path

import tomllib
from project_metadata import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    output = args.output
    output.mkdir(parents=True, exist_ok=False)
    for source, name in (
        ("LICENSE", "Turnrail-LICENSE.txt"),
        ("NOTICE", "Turnrail-NOTICE.txt"),
        ("engine/LICENSE", "Codex-LICENSE.txt"),
        ("engine/NOTICE", "Codex-NOTICE.txt"),
        ("packaging/licenses/zsh-LICENCE.txt", "zsh-LICENCE.txt"),
    ):
        shutil.copyfile(ROOT / source, output / name)
    subprocess.run(
        [
            "cargo-about",
            "about",
            "generate",
            "--locked",
            "--fail",
            "--workspace",
            "--manifest-path",
            str(ROOT / "engine/codex-rs/Cargo.toml"),
            "--target",
            "aarch64-apple-darwin",
            "--config",
            str(ROOT / "packaging/about.toml"),
            "--output-file",
            str(output / "Rust-LICENSES.txt"),
            str(ROOT / "packaging/licenses.hbs"),
        ],
        check=True,
    )
    metadata = json.loads(
        subprocess.check_output(
            [
                "cargo",
                "metadata",
                "--locked",
                "--format-version",
                "1",
                "--manifest-path",
                str(ROOT / "engine/codex-rs/Cargo.toml"),
            ]
        )
    )
    revision = subprocess.check_output(
        ["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True
    ).strip()
    sources = []
    for package in metadata["packages"]:
        source = package["source"]
        if source is None:
            directory = Path(package["manifest_path"]).parent.relative_to(ROOT)
            url = f"https://github.com/kosukesaigusa/codex-turnrail/tree/{revision}/{directory}"
        elif source == "registry+https://github.com/rust-lang/crates.io-index":
            url = f"https://crates.io/api/v1/crates/{package['name']}/{package['version']}/download"
        elif source.startswith("git+https://github.com/"):
            location = urllib.parse.urlsplit(source.removeprefix("git+"))
            if not location.fragment:
                raise ValueError("A Git dependency source must include its revision.")
            url = f"https://github.com{location.path.removesuffix('.git')}/tree/{location.fragment}"
        else:
            raise ValueError(f"Review the unsupported dependency source: {source}")
        sources.append(
            {
                "name": package["name"],
                "version": package["version"],
                "license": package["license"],
                "source": url,
            }
        )
    (output / "Rust-SOURCES.json").write_text(json.dumps(sources, indent=2) + "\n")
    packages = [package for package in metadata["packages"] if package["name"] == "v8"]
    if len(packages) != 1:
        raise ValueError(
            "Exactly one pinned V8 crate is required for its source notices."
        )
    v8 = Path(packages[0]["manifest_path"]).parent
    pins = tomllib.loads((ROOT / "packaging/licenses/runtime.toml").read_text())
    source = json.loads((v8 / ".cargo_vcs_info.json").read_text())["git"]["sha1"]
    if (
        packages[0]["version"] != pins["v8"]["version"]
        or source != pins["v8"]["rusty_v8_commit"]
    ):
        raise ValueError(
            "Review V8 component notices for the updated source before packaging."
        )
    shutil.copyfile(
        ROOT / "packaging/licenses/V8-NOTICES.txt", output / "V8-NOTICES.txt"
    )
    zsh = (ROOT / "engine/scripts/codex_package/codex-zsh").read_text()
    zsh_spec = json.loads(zsh[zsh.index("{") :])["platforms"]["macos-aarch64"]
    if zsh_spec["digest"] != pins["zsh"]["archive_sha256"]:
        raise ValueError(
            "Review zsh component notices for the updated runtime before packaging."
        )
    launcher = (ROOT / "engine/scripts/codex_package/rg").read_text()
    spec = json.loads(launcher[launcher.index("{") :])["platforms"]["macos-aarch64"]
    if len(spec["providers"]) != 1 or spec["hash"] != "sha256":
        raise ValueError(
            "Review the ripgrep source before changing its license inputs."
        )
    with tempfile.TemporaryDirectory(prefix="turnrail-rg-license-") as temporary:
        archive = Path(temporary) / "rg.tar.gz"
        with urllib.request.urlopen(spec["providers"][0]["url"], timeout=60) as source:
            data = source.read()
        if (
            len(data) != spec["size"]
            or hashlib.sha256(data).hexdigest() != spec["digest"]
        ):
            raise ValueError("The ripgrep notice archive failed checksum verification.")
        archive.write_bytes(data)
        with tarfile.open(archive) as bundle:
            prefix = str(Path(spec["path"]).parent)
            for name in ("COPYING", "LICENSE-MIT", "UNLICENSE"):
                member = bundle.getmember(f"{prefix}/{name}")
                if not member.isfile():
                    raise ValueError(
                        "The ripgrep license entry must be a regular file."
                    )
                (output / f"ripgrep-{name}.txt").write_bytes(
                    bundle.extractfile(member).read()
                )
    print(f"Prepared component notices: {output}")


if __name__ == "__main__":
    main()
