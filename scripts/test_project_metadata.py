"""Keep exact upstream prerelease identities and SemVer precedence."""

import copy
import unittest

from project_metadata import (
    ROOT,
    cli_version,
    codex_version,
    codex_version_key,
    read_upstream,
    supported_swift,
    validate_upstream,
    version_tuple,
)


class CodexVersionTests(unittest.TestCase):
    def test_official_cli_identity_is_independent_of_reference_source(self):
        metadata = read_upstream(ROOT)
        metadata["app"]["cli_version"] = "codex-cli 0.999.0-alpha.7"
        validate_upstream(metadata)
        self.assertEqual(cli_version(metadata), "codex-cli 0.999.0-alpha.7")
        self.assertIn(
            'cliVersion: "codex-cli 0.999.0-alpha.7"', supported_swift(metadata)
        )

    def test_missing_or_invalid_official_cli_identity_is_not_inferred(self):
        metadata = read_upstream(ROOT)
        missing = copy.deepcopy(metadata)
        del missing["app"]["cli_version"]
        with self.assertRaisesRegex(ValueError, "fields"):
            validate_upstream(missing)
        for value in (
            None,
            "",
            "rust-v0.155.0",
            "codex-cli latest",
            "codex-cli 0.155.0-alpha.01",
        ):
            with self.subTest(value=value), self.assertRaises(ValueError):
                metadata["app"]["cli_version"] = value
                validate_upstream(metadata)

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
