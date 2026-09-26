"""Resolve explicit official runtime layouts without executing package contents."""

import json
import os
from dataclasses import dataclass
from pathlib import Path

from project_metadata import validate_cli_version

PACKAGE = "Contents/Resources/codex-cli"
LAYOUT_FILES = {
    "flat": {
        "launcher": "Contents/Resources/codex",
        "executable": "Contents/Resources/codex",
        "host": "Contents/Resources/codex-code-mode-host",
    },
    "packageV1": {
        "launcher": f"{PACKAGE}/bin/codex",
        "executable": f"{PACKAGE}/CodexCLI.app/Contents/MacOS/codex",
        "host": f"{PACKAGE}/bin/codex-code-mode-host",
        "manifest": f"{PACKAGE}/codex-package.json",
    },
}


def present(path):
    try:
        path.lstat()
        return True
    except FileNotFoundError:
        return False


def checked(path, app, *, directory=False, executable=False):
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(app) or resolved == app:
        raise ValueError("The official Engine package contains a path outside ChatGPT.")
    valid_type = resolved.is_dir() if directory else resolved.is_file()
    if not valid_type or (executable and not os.access(resolved, os.X_OK)):
        raise ValueError(f"A required official Engine component is unavailable: {path}")
    return resolved


@dataclass(frozen=True)
class OfficialRuntime:
    app: Path
    layout: str
    files: dict[str, Path]
    package_version: str | None

    @property
    def launcher(self):
        return self.files["launcher"]

    @property
    def binaries(self):
        return {
            "codex": self.files["executable"],
            "codex-code-mode-host": self.files["host"],
        }

    @property
    def signature_targets(self):
        if self.layout == "packageV1":
            return [
                (self.app / PACKAGE / "CodexCLI.app", "codex"),
                (self.files["executable"], "codex"),
                (self.files["host"], None),
            ]
        return [(path, None) for path in self.binaries.values()]


def resolve_runtime(app):
    app = app.resolve(strict=True)
    has_package = present(app / PACKAGE)
    has_flat = any(present(app / path) for path in set(LAYOUT_FILES["flat"].values()))
    if has_package == has_flat:
        raise ValueError("ChatGPT has an unknown or ambiguous official Engine layout.")
    package_version = None
    if has_package:
        checked(app / PACKAGE, app, directory=True)
        manifest_path = checked(app / LAYOUT_FILES["packageV1"]["manifest"], app)
        if manifest_path.stat().st_size > 1024 * 1024:
            raise ValueError(
                "The official Engine package manifest exceeds the supported size."
            )
        manifest = json.loads(manifest_path.read_text())
        expected = {
            "layoutVersion": 1,
            "target": "aarch64-apple-darwin",
            "variant": "codex",
            "entrypoint": "bin/codex",
            "resourcesDir": "codex-resources",
            "pathDir": "codex-path",
        }
        if (
            not isinstance(manifest, dict)
            or type(manifest.get("layoutVersion")) is not int
            or any(manifest.get(key) != value for key, value in expected.items())
            or not isinstance(manifest.get("version"), str)
        ):
            raise ValueError("The official Engine package manifest is not supported.")
        package_version = manifest["version"]
        validate_cli_version("codex-cli " + package_version)
        for directory in ("codex-resources", "codex-path", "CodexCLI.app"):
            checked(app / PACKAGE / directory, app, directory=True)
    layout = "packageV1" if has_package else "flat"
    files = {
        name: checked(app / relative, app, executable=name != "manifest")
        for name, relative in LAYOUT_FILES[layout].items()
    }
    return OfficialRuntime(app, layout, files, package_version)
