"""Keep exact upstream prerelease identities and SemVer precedence."""

import unittest

from project_metadata import codex_version, codex_version_key, version_tuple


class CodexVersionTests(unittest.TestCase):
    def test_prerelease_tag_preserves_the_exact_bundled_cli_version(self):
        self.assertEqual(codex_version("rust-v0.154.0-alpha.6.2"), "0.154.0-alpha.6.2")
        self.assertEqual(codex_version("rust-v0.154.0"), "0.154.0")

    def test_semver_precedence_compares_numeric_identifiers_numerically(self):
        ordered = [
            "0.154.0-alpha",
            "0.154.0-alpha.1",
            "0.154.0-alpha.6.2",
            "0.154.0-alpha.6.10",
            "0.154.0-alpha.beta",
            "0.154.0-beta",
            "0.154.0-rc.1",
            "0.154.0",
            "0.155.0-alpha.1",
        ]
        tags = ["rust-v" + version for version in ordered]
        self.assertEqual(sorted(reversed(tags), key=codex_version_key), tags)

    def test_malformed_or_ambiguous_source_tags_are_rejected(self):
        for tag in (
            None,
            "0.154.0",
            "rust-v0.154",
            "rust-v00.154.0",
            "rust-v0.154.0-alpha.01",
            "rust-v0.154.0-alpha..2",
            "rust-v0.154.0-",
            "rust-v0.154.0+local",
            "rust-v0.154.0-alpha_1",
        ):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                codex_version(tag)

    def test_product_versions_still_require_stable_releases(self):
        with self.assertRaises(ValueError):
            version_tuple("0.2.0-alpha.1")


if __name__ == "__main__":
    unittest.main()
