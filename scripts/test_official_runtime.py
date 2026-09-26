"""Keep both official layouts explicit and reject unknown or escaping components."""

import json
import plistlib
import tempfile
import unittest
from pathlib import Path

from official_runtime import LAYOUT_FILES, PACKAGE, resolve_runtime


def app_fixture(root, layout, metadata):
    app = root / "ChatGPT.app"
    (app / "Contents").mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(
        plistlib.dumps(
            {
                "CFBundleIdentifier": metadata["bundle_identifier"],
                "CFBundleShortVersionString": metadata["version"],
                "CFBundleVersion": metadata["build"],
            }
        )
    )
    for path in set(LAYOUT_FILES[layout].values()):
        target = app / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("fixture:" + path)
        target.chmod(0o755)
    if layout == "packageV1":
        manifest = {
            "layoutVersion": 1,
            "version": metadata["cli_version"].removeprefix("codex-cli "),
            "target": "aarch64-apple-darwin",
            "variant": "codex",
            "entrypoint": "bin/codex",
            "resourcesDir": "codex-resources",
            "pathDir": "codex-path",
        }
        (app / PACKAGE / "codex-package.json").write_text(json.dumps(manifest))
        for directory in ("codex-resources", "codex-path"):
            (app / PACKAGE / directory).mkdir()
    return app


class OfficialRuntimeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.metadata = {
            "bundle_identifier": "com.openai.codex",
            "version": "26.924.20706",
            "build": "11431",
            "cli_version": "codex-cli 0.158.0-alpha.2",
        }

    def test_each_layout_resolves_its_launcher_and_actual_binary(self):
        for layout, files in LAYOUT_FILES.items():
            with self.subTest(layout=layout):
                app = app_fixture(self.root / layout, layout, self.metadata)
                resolved = resolve_runtime(app)
                self.assertEqual(resolved.layout, layout)
                self.assertEqual(resolved.launcher, app / files["launcher"])
                self.assertEqual(resolved.binaries["codex"], app / files["executable"])
                self.assertEqual(
                    resolved.binaries["codex-code-mode-host"], app / files["host"]
                )
                self.assertEqual(
                    resolved.files, {key: app / value for key, value in files.items()}
                )

    def test_unknown_ambiguous_and_broken_package_do_not_select_flat_layout(self):
        for problem in ("unknown", "ambiguous", "broken-package"):
            with self.subTest(problem=problem):
                app = app_fixture(self.root / problem, "flat", self.metadata)
                if problem == "unknown":
                    for path in set(LAYOUT_FILES["flat"].values()):
                        (app / path).unlink()
                elif problem == "ambiguous":
                    (app / PACKAGE).mkdir()
                else:
                    (app / PACKAGE).symlink_to("does-not-exist")
                with self.assertRaisesRegex(ValueError, "unknown or ambiguous"):
                    resolve_runtime(app)

    def test_invalid_manifests_do_not_select_an_alternate_executable(self):
        for key, value in [
            ("layoutVersion", 2),
            ("layoutVersion", True),
            ("target", "x86_64-apple-darwin"),
            ("variant", "other"),
            ("entrypoint", "../../outside"),
            ("entrypoint", "/tmp/codex"),
            ("resourcesDir", "../outside"),
            ("pathDir", "other"),
            ("version", "unknown"),
            ("version", "1.2.3\n"),
            ("entrypoint", None),
        ]:
            with (
                self.subTest(key=key, value=value),
                tempfile.TemporaryDirectory() as directory,
            ):
                app = app_fixture(Path(directory), "packageV1", self.metadata)
                path = app / PACKAGE / "codex-package.json"
                manifest = json.loads(path.read_text())
                manifest[key] = value
                path.write_text(json.dumps(manifest))
                with self.assertRaises(ValueError):
                    resolve_runtime(app)

    def test_package_files_and_ancestors_cannot_escape_the_app(self):
        paths = (
            set(LAYOUT_FILES["flat"].values())
            | set(LAYOUT_FILES["packageV1"].values())
            | {PACKAGE + "/bin"}
        )
        for relative in paths:
            with (
                self.subTest(path=relative),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                layout = "packageV1" if relative.startswith(PACKAGE + "/") else "flat"
                app = app_fixture(root, layout, self.metadata)
                target = app / relative
                outside = root / "outside"
                target.rename(outside)
                target.symlink_to(outside)
                with self.assertRaisesRegex(ValueError, "outside ChatGPT"):
                    resolve_runtime(app)

    def test_missing_and_nonexecutable_runtime_components_fail(self):
        for mode in ("missing", "mode"):
            for layout in LAYOUT_FILES:
                with self.subTest(mode=mode, layout=layout):
                    app = app_fixture(
                        self.root / (mode + layout), layout, self.metadata
                    )
                    host = app / LAYOUT_FILES[layout]["host"]
                    if mode == "missing":
                        host.unlink()
                    else:
                        host.chmod(0o644)
                    with self.assertRaises((ValueError, OSError)):
                        resolve_runtime(app)


if __name__ == "__main__":
    unittest.main()
