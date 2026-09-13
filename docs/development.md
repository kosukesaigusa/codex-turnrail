# Development

Run product commands from the repository root. Both `app/` and `engine/` are part of this checkout; no external Engine path or nested Git repository is required.

## Prerequisites

- Apple Silicon macOS 14 or newer with Xcode command line tools and Swift 6.
- The official Codex app at `/Applications/ChatGPT.app`, matching the versions declared in `app/Sources/CodexTurnrailCore/Compatibility.swift`, for packaging and launch verification.
- Rust and components specified by `engine/codex-rs/rust-toolchain.toml`.
- Python 3.12 or newer, uv 0.11.3, just 1.51.0, cargo-nextest 0.9.103, and DotSlash.
- Node.js 22 and pnpm 10.34.5, as used by CI.
- Git with `merge-tree --merge-base` support and a configured identity for upstream updates; verified with Git 2.51.0.
- An Apple Development signing identity for a signed app.

Install the locked JavaScript dependencies before formatting:

```sh
pnpm --dir engine install --frozen-lockfile
```

The pinned upstream Python SDK requires a uv version that supports its workspace configuration. Python dependencies are resolved from the committed lockfiles.

## Commands

| Command                                                        | Purpose                                                                              |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `just build-app --jobs 2`                                      | Build the Swift app executable in release mode.                                      |
| `just test-app --jobs 2`                                       | Run Swift core and app tests.                                                        |
| `just build-engine --locked -p codex-cli --bin codex`          | Build a selected Engine target.                                                      |
| `just check-engine --locked -p codex-app-server`               | Check a selected Rust package.                                                       |
| `just test-engine --locked -p codex-app-server`                | Run selected Engine tests with nextest.                                              |
| `just lint-engine --locked -p codex-app-server -- -D warnings` | Run Clippy under the development storage policy.                                     |
| `just fix-engine -p codex-app-server`                          | Apply Clippy fixes for a selected package.                                           |
| `just test-tools`                                              | Test product tooling and upstream packaging, installation, and notarization helpers. |
| `just fmt` / `just fmt-check`                                  | Format or check Swift, Python, Rust, Just, Markdown, and upstream source formats.    |
| `just lint-docs`                                               | Lint product Markdown.                                                               |
| `just storage`                                                 | Check the development free-space reserve.                                            |
| `just finish`                                                  | Clean generated Rust and Swift build artifacts.                                      |

Select tests according to the changed behavior and `engine/AGENTS.md`. A filtered example does not replace required coverage. Tests remove an inherited `CODEX_TURNRAIL_ROOT` from the child environment so that fixtures cannot accidentally read the user's routing registry. The invoking shell retains its environment.

## Storage policy

Heavy local commands share a repository lock, require at least 30 GiB of available space before starting, and use the canonical build directories. Engine commands select `dev-small`, disable incremental compilation, and reject conflicting profile or target-directory options. Swift commands use `app/` and reject package or scratch-path redirection.

The reserve is a preflight threshold, not a compiler disk-usage limit. Check space between commands. Let running Rust commands finish; do not kill a compiler to recover disk space.

Keep logs and packages under `dist/` or another directory outside `engine/codex-rs/target` and `app/.build`. After development processes end, run:

```sh
just finish
```

Cleanup uses `cargo clean` and `swift package clean`. It works below the reserve threshold and preserves source, account data, and packaged apps. If a command was interrupted and left a lock directory, verify that its process has stopped before removing the lock.

## Runtime package

Build an Engine and Code Mode Host from the same source tree:

```sh
just build-runtime "$PWD/dist/runtime"
just test-integration "$PWD/dist/runtime" "$PWD/dist/runtime-verification.json"
```

The output path must be absolute and must not already exist. `scripts/build-runtime.py` uses the upstream V8 resolver to verify the SHA-256 of the library and Rust bindings selected by `Cargo.lock`. External V8 overrides are rejected. It builds both binaries with `--locked`, then uses the upstream package builder to include the manifest, dedicated zsh, and rg.

The integration probe uses this Engine's Python SDK and a local mock model. Its temporary `CODEX_HOME` and working directory are isolated from real accounts. It verifies JavaScript, parallel tool calls, packaged zsh and rg paths, and approval acceptance and rejection. A failed probe makes the command fail.

To run the development app, first build it and supply the explicit Engine path:

```sh
just build-app --jobs 2
CODEX_TURNRAIL_ENGINE_PATH="$PWD/dist/runtime/bin/codex" \
  app/.build/release/CodexTurnrailApp
```

Use a signed Engine for authentication operations. A missing Engine path or incompatible version is an error.

## Signed app

```sh
just package "$PWD/dist/app" "Apple Development: Your Name (TEAMID)"
```

The package command:

1. Builds the complete Engine runtime from `engine/`.
2. Compares stable and experimental app-server schemas with the installed official CLI.
3. Builds the Swift app from `app/` and adds the packaging resources.
4. Signs the Engine, Code Mode Host, zsh, rg, and app bundle. The Host receives the two V8 memory entitlements from `packaging/entitlements/`.
5. Verifies the signatures and executes the integration probe against the finished app.
6. Saves the app and `runtime-verification.json`, then cleans generated build artifacts.

Success requires every step. An output created before a failure is not a verified app. Existing output apps are never overwritten. This command produces a development-signed build; Developer ID signing and notarization are not implemented.

Replace an installed app only after the official Codex app and its Engine have exited. A running Engine may still load resources from its existing bundle path.

## Upstream updates

[`upstream.toml`](../upstream.toml) records the canonical Codex repository, base release tag, and exact commit. Preserve the full upstream-shaped tree under `engine/`, including its licenses and dependency lockfiles.

Start from a clean committed product worktree:

```sh
just sync-upstream rust-vX.Y.Z
```

Replace `rust-vX.Y.Z` with the intended Codex release tag. The command fetches the complete objects for the recorded base and requested release without adding a remote or changing local tag refs. It constructs a three-way merge between the upstream base, local Engine changes, and the new release. Product files outside `engine/` remain intact; `upstream.toml` is updated with the new tag and commit.

A clean merge is applied as uncommitted working-tree changes. The command does not stage files, create a branch commit, push, or publish. It creates temporary Git objects for merge computation. If there are conflicts, it reports the affected paths and leaves source files unchanged; resolve the overlapping Engine changes deliberately before preparing the update again. Dirty worktrees, invalid provenance, and malformed release tags fail explicitly.

After an update, review the Engine diff and dependency locks, update the app's exact compatibility requirements where appropriate, run the affected tests and source checks, then rebuild and verify the complete package. Protocol equality alone does not prove official UI compatibility. Record the selected official app version and observed UI behavior in [Verification](verification.md).

## Continuous integration

The root `.github/workflows/ci.yml` is the entrypoint for pull requests and pushes to `main`. All jobs use the same repository revision.

| Workflow              | Checks                                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Source and app checks | Formatting, Markdown, Engine source policies, Python tooling, Swift release build and tests, shell syntax, and plist metadata. |
| Dependency policy     | Cargo dependency license and advisory policy.                                                                                  |
| Spelling              | Codespell across product and Engine sources.                                                                                   |
| File size policy      | Changed file sizes with an explicit allowlist.                                                                                 |
| Engine and runtime    | Engine builds, selected tests, Clippy, package assembly, and runtime scenarios on `macos-15`.                                  |

The required check succeeds only when every dependency succeeds; failed, skipped, or cancelled jobs do not pass. The Engine job begins after the lighter checks succeed. Test and runtime reports are retained for seven days.

CI uses an ephemeral runner with `dev-small`, disabled incremental compilation, and two workers. It runs app-server, login, model-provider, Code Mode, and Host package tests; core library tests; and account-isolation and zsh-approval core integration suites. Local commands retain the 30 GiB reserve. Signing certificates and real-account credentials are not required by CI.

Upstream workflow definitions remain under `engine/.github/` as vendored source. GitHub discovers only root workflows; the upstream Bazel, cross-platform, SDK, and V8 canary matrices are not automatic product checks. Official UI turns, real-account operations, signing, notarization, Intel macOS, and Windows/Linux packaging require separate validation.
