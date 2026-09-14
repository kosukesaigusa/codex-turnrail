"""Keep compiler-incompatible artifacts outside the release restore scope."""

import tempfile
import unittest
from pathlib import Path

from release_cache import cache_keys


class ReleaseCacheTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.rust = self.root / "engine/codex-rs"
        (self.rust / ".cargo").mkdir(parents=True)
        (self.rust / ".cargo/config.toml").write_text("[build]\nincremental = false\n")
        (self.rust / "Cargo.toml").write_text('[profile.release]\nlto = "thin"\n')
        self.compiler = {"rustc": "compiler-a", "sdk": "sdk-a", "xcode": "xcode-a"}

    def test_new_sources_get_a_new_key_in_the_same_compiler_scope(self):
        first = cache_keys(self.root, "a" * 40, self.compiler, {})
        second = cache_keys(self.root, "b" * 40, self.compiler, {})
        self.assertNotEqual(first["key"], second["key"])
        self.assertEqual(first["prefix"], second["prefix"])
        self.assertTrue(first["key"].startswith(second["prefix"]))

    def test_compiler_sdk_profile_and_flags_change_the_restore_scope(self):
        original = cache_keys(self.root, "a" * 40, self.compiler, {})
        for field in self.compiler:
            with self.subTest(field=field):
                changed = cache_keys(
                    self.root, "a" * 40, {**self.compiler, field: "new-version"}, {}
                )
                self.assertNotEqual(original["prefix"], changed["prefix"])
        for variable in ("RUSTFLAGS", "CARGO_PROFILE_RELEASE_LTO", "SDKROOT"):
            with self.subTest(variable=variable):
                changed = cache_keys(
                    self.root, "a" * 40, self.compiler, {variable: "changed"}
                )
                self.assertNotEqual(original["prefix"], changed["prefix"])
        (self.rust / "Cargo.toml").write_text('[profile.release]\nlto = "off"\n')
        changed = cache_keys(self.root, "a" * 40, self.compiler, {})
        self.assertNotEqual(original["prefix"], changed["prefix"])

    def test_worker_count_and_authentication_do_not_change_compiler_identity(self):
        first = cache_keys(
            self.root,
            "a" * 40,
            self.compiler,
            {"CARGO_BUILD_JOBS": "2", "GH_TOKEN": "fixture-a"},
        )
        second = cache_keys(
            self.root,
            "a" * 40,
            self.compiler,
            {"CARGO_BUILD_JOBS": "3", "GH_TOKEN": "fixture-b"},
        )
        self.assertEqual(first, second)

    def test_missing_profile_or_invalid_revision_is_rejected(self):
        with self.assertRaises(ValueError):
            cache_keys(self.root, "main", self.compiler, {})
        (self.rust / "Cargo.toml").write_text('[package]\nname = "fixture"\n')
        with self.assertRaises(KeyError):
            cache_keys(self.root, "a" * 40, self.compiler, {})


if __name__ == "__main__":
    unittest.main()
