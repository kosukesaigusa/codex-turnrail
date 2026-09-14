"""Exercise storage failures, command forwarding, and cleanup boundaries."""

import io
import subprocess
import sys
import tempfile
import unittest
from contextlib import ExitStack, redirect_stderr, redirect_stdout
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import dev as policy


class StoragePolicyTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch.dict(policy.os.environ, {}, clear=True))
        temporary = self.stack.enter_context(tempfile.TemporaryDirectory())
        self.repo = Path(temporary).resolve() / "product"
        self.engine = self.repo / "engine"
        self.rust = self.engine / "codex-rs"
        self.rust.mkdir(parents=True)
        self.companion = self.repo / "app"
        (self.companion / "Sources/CodexTurnrailApp").mkdir(parents=True)
        (self.companion / "Package.swift").write_text("fixture")
        self.target = self.rust / "target"
        self.lock = self.repo / ".cache/turnrail-dev.lock"
        self.stack.enter_context(patch.object(policy, "REPO_ROOT", self.repo))
        self.stack.enter_context(patch.object(policy, "ENGINE_ROOT", self.engine))
        self.stack.enter_context(patch.object(policy, "APP_ROOT", self.companion))
        self.stack.enter_context(patch.object(policy, "RUST_ROOT", self.rust))
        self.stack.enter_context(patch.object(policy, "TARGET", self.target))
        self.space = self.stack.enter_context(
            patch.object(
                policy.shutil,
                "disk_usage",
                return_value=SimpleNamespace(free=60 * 1024**3),
            )
        )
        self.process = self.stack.enter_context(patch.object(policy.subprocess, "run"))
        self.output = self.stack.enter_context(redirect_stdout(io.StringIO()))
        self.error = self.stack.enter_context(redirect_stderr(io.StringIO()))

    def invoke(self, *arguments):
        with patch.object(sys, "argv", ["dev.py", *arguments]):
            return policy.main()

    def test_low_space_prevents_build_and_releases_lock(self):
        self.space.return_value.free = policy.MIN_FREE_BYTES - 1
        self.assertEqual(self.invoke("cargo", "build", "-p", "codex-cli"), 1)
        self.process.assert_not_called()
        self.assertFalse(self.lock.exists())
        self.assertIn("At least 30 GiB", self.error.getvalue())

    def test_threshold_allows_build_with_policy_environment(self):
        self.space.return_value.free = policy.MIN_FREE_BYTES
        self.assertEqual(
            self.invoke("cargo", "build", "--locked", "-p", "codex-cli"), 0
        )
        call = self.process.call_args
        self.assertEqual(
            call.args[0],
            ["cargo", "build", "--profile", "dev-small", "--locked", "-p", "codex-cli"],
        )
        self.assertEqual(call.kwargs["cwd"], self.rust)
        self.assertEqual(call.kwargs["env"]["CARGO_INCREMENTAL"], "0")
        self.assertEqual(call.kwargs["env"]["CARGO_TARGET_DIR"], str(self.target))
        self.assertEqual(call.kwargs["env"]["CODEX_REPO_ROOT"], str(self.engine))

    def test_nextest_preserves_filter_and_selects_cargo_profile(self):
        expression = "test(turnrail) | test(thread_revert)"
        self.assertEqual(
            self.invoke("cargo", "nextest", "run", "--no-fail-fast", "-E", expression),
            0,
        )
        self.assertEqual(
            self.process.call_args.args[0],
            [
                "cargo",
                "nextest",
                "run",
                "--cargo-profile",
                "dev-small",
                "--no-fail-fast",
                "-E",
                expression,
            ],
        )

    def test_cargo_failure_is_reported_and_releases_lock(self):
        self.process.side_effect = subprocess.CalledProcessError(
            101, ["cargo", "build"]
        )
        self.assertEqual(self.invoke("cargo", "build"), 1)
        self.assertFalse(self.lock.exists())

    def test_nextest_does_not_inherit_the_host_account_registry(self):
        with patch.dict(
            policy.os.environ,
            {"CODEX_TURNRAIL_ROOT": "/fixture/account-registry"},
        ):
            self.assertEqual(self.invoke("cargo", "nextest", "run"), 0)
            self.assertNotIn(
                "CODEX_TURNRAIL_ROOT", self.process.call_args.kwargs["env"]
            )
            self.assertEqual(
                policy.os.environ["CODEX_TURNRAIL_ROOT"],
                "/fixture/account-registry",
            )
        self.assertIn("removed inherited account routing", self.output.getvalue())

    def test_running_codex_preserves_explicit_account_routing(self):
        with patch.dict(
            policy.os.environ,
            {"CODEX_TURNRAIL_ROOT": "/fixture/account-registry"},
        ):
            self.assertEqual(self.invoke("cargo", "run", "--bin", "codex"), 0)
        self.assertEqual(
            self.process.call_args.kwargs["env"]["CODEX_TURNRAIL_ROOT"],
            "/fixture/account-registry",
        )

    def test_nextest_runner_profile_does_not_change_cargo_profile(self):
        arguments = ["nextest", "run", "--profile", "local"]
        self.assertEqual(
            policy.cargo_command(arguments),
            [
                "cargo",
                "nextest",
                "run",
                "--cargo-profile",
                "dev-small",
                "--profile",
                "local",
            ],
        )

    def test_conflicting_cargo_flags_never_start_a_process(self):
        for arguments in [
            ["--profile", "dev"],
            ["--cargo-profile=dev"],
            ["--release"],
            ["--target-dir", "/elsewhere"],
            ["--config", "build.incremental=true"],
        ]:
            with self.subTest(arguments=arguments):
                self.assertEqual(self.invoke("cargo", "build", *arguments), 1)
        self.process.assert_not_called()

    def test_distribution_build_uses_an_explicit_fixed_release_profile(self):
        self.assertEqual(self.invoke("release-build"), 0)
        command = self.process.call_args.args[0]
        self.assertEqual(command[command.index("--profile") + 1], "release")
        self.assertIn("--timings", command)
        self.assertEqual(command[command.index("--target") + 1], "aarch64-apple-darwin")
        self.assertEqual(self.process.call_args.kwargs["env"]["CARGO_INCREMENTAL"], "0")
        self.assertFalse(self.lock.exists())

    def test_distribution_profile_overrides_cannot_start_a_build(self):
        with self.assertRaises(SystemExit) as error:
            self.invoke("release-build", "--release")
        self.assertEqual(error.exception.code, 2)
        self.process.assert_not_called()

    def test_ci_storage_policy_cannot_be_selected_outside_actions(self):
        self.assertEqual(self.invoke("--ci", "release-build"), 1)
        self.process.assert_not_called()

    def test_ci_uses_its_explicit_reserve_and_retains_the_lock(self):
        self.space.return_value.free = 6 * 1024**3
        with patch.dict(policy.os.environ, {"GITHUB_ACTIONS": "true"}):
            self.assertEqual(self.invoke("--ci", "release-build"), 0)
        self.assertFalse(self.lock.exists())
        self.assertEqual(self.process.call_args.kwargs["env"]["CARGO_INCREMENTAL"], "0")

    def test_application_flags_are_forwarded_after_separator(self):
        arguments = ["run", "--bin", "codex", "--", "--profile", "my-settings"]
        self.assertEqual(
            policy.cargo_command(arguments),
            ["cargo", "run", "--profile", "dev-small", *arguments[1:]],
        )

    def test_incremental_is_disabled_without_mutating_inherited_environment(self):
        original = {"CARGO_INCREMENTAL": "1", "PATH": "/fixture/bin"}
        result = policy.cargo_environment(original)
        self.assertEqual(original, {"CARGO_INCREMENTAL": "1", "PATH": "/fixture/bin"})
        self.assertEqual(result["CARGO_INCREMENTAL"], "0")
        self.assertEqual(result["PATH"], "/fixture/bin")

    def test_external_target_environment_is_rejected(self):
        for variable in [
            "CARGO_TARGET_DIR",
            "CARGO_BUILD_TARGET_DIR",
            "CARGO_BUILD_BUILD_DIR",
        ]:
            with (
                self.subTest(variable=variable),
                self.assertRaises(policy.StoragePolicyError),
            ):
                policy.cargo_environment({variable: "/elsewhere"})

    def test_finish_cannot_race_an_active_command(self):
        with policy.workspace_lock():
            self.assertEqual(self.invoke("finish"), 1)
            self.assertTrue(self.lock.exists())
        self.process.assert_not_called()

    def test_finish_is_not_blocked_by_low_space(self):
        self.space.return_value.free = 0
        self.assertEqual(self.invoke("finish"), 0)
        self.assertEqual(
            [call.args[0] for call in self.process.call_args_list],
            [
                ["cargo", "clean", "--target-dir", str(self.target)],
                ["swift", "package", "--package-path", str(self.companion), "clean"],
            ],
        )

    def test_missing_app_is_rejected_before_rust_cleanup(self):
        with patch.object(policy, "APP_ROOT", self.repo):
            self.assertEqual(self.invoke("finish"), 1)
        self.process.assert_not_called()

    def test_symlinked_build_directories_are_not_cleaned(self):
        for generated in [self.target, self.companion / ".build"]:
            with self.subTest(generated=generated):
                generated.symlink_to(self.repo, target_is_directory=True)
                self.assertEqual(self.invoke("finish"), 1)
                generated.unlink()
        self.process.assert_not_called()

    def test_app_inside_target_is_not_cleaned(self):
        nested = self.target / "app"
        (nested / "Sources/CodexTurnrailApp").mkdir(parents=True)
        (nested / "Package.swift").write_text("fixture")
        with patch.object(policy, "APP_ROOT", nested):
            self.assertEqual(self.invoke("finish"), 1)
        self.process.assert_not_called()

    def test_swift_build_uses_the_app_directory(self):
        self.assertEqual(self.invoke("swift", "build", "-c", "release"), 0)
        self.assertEqual(
            self.process.call_args.args[0],
            [
                "swift",
                "build",
                "--package-path",
                str(self.companion),
                "-c",
                "release",
            ],
        )
        self.assertEqual(self.process.call_args.kwargs["cwd"], self.companion)

    def test_swift_tests_do_not_inherit_the_host_account_registry(self):
        with patch.dict(
            policy.os.environ,
            {"CODEX_TURNRAIL_ROOT": "/fixture/account-registry"},
        ):
            self.assertEqual(self.invoke("swift", "test"), 0)
            self.assertNotIn(
                "CODEX_TURNRAIL_ROOT", self.process.call_args.kwargs["env"]
            )
            self.assertEqual(
                policy.os.environ["CODEX_TURNRAIL_ROOT"],
                "/fixture/account-registry",
            )

    def test_swift_cannot_redirect_build_outputs(self):
        for option in ("--package-path", "--scratch-path=/outside"):
            with self.subTest(option=option):
                self.assertEqual(self.invoke("swift", "build", option), 1)
        self.process.assert_not_called()

    def test_low_space_prevents_a_swift_build(self):
        self.space.return_value.free = policy.MIN_FREE_BYTES - 1
        self.assertEqual(self.invoke("swift", "build"), 1)
        self.process.assert_not_called()


if __name__ == "__main__":
    unittest.main()
