# Development

Run product commands from the repository root. Both `app/` and `engine/` are part of this checkout; no external Engine path or nested Git repository is required.

## Prerequisites

- Apple Silicon macOS 14 or newer with Xcode command line tools and Swift 6.
- The official ChatGPT macOS app at `/Applications/ChatGPT.app`, matching `upstream.toml`, for launch verification. Packaging takes an explicit Codex CLI path with the matching version.
- Rust and components specified by `engine/codex-rs/rust-toolchain.toml`.
- Python 3.12 or newer, uv 0.11.3, just 1.51.0, cargo-nextest 0.9.103, and DotSlash.
- Node.js 22 and pnpm 10.34.5, as used by CI.
- Git with `merge-tree --merge-base` support and a configured identity for upstream updates; verified with Git 2.51.0.
- An Apple Development signing identity for a signed app.
- cargo-about 0.9.2 for bundled dependency notices, actionlint 1.7.11 for workflow validation, and GitHub CLI for release automation.

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
| `just lint-workflows`                                          | Validate root GitHub Actions workflows, expressions, and reusable workflow calls.    |
| `just lint-docs`                                               | Lint product Markdown.                                                               |
| `just storage`                                                 | Check the development free-space reserve.                                            |
| `just finish`                                                  | Clean generated Rust and Swift build artifacts.                                      |

Select tests according to the changed behavior and `engine/AGENTS.md`. A filtered example does not replace required coverage. Tests remove an inherited `CODEX_TURNRAIL_ROOT` from the child environment so that fixtures cannot accidentally read the user's routing registry. The invoking shell retains its environment.

## UI screenshots

Render the production SwiftUI views with isolated demo accounts:

```sh
TURNRAIL_SCREENSHOT_DIRECTORY=/absolute/review-directory \
  just test-app --filter SettingsScreenshots
```

The opt-in renderer writes `switch.png`, `accounts.png`, and `available-resets.png` at double resolution. It uses a temporary registry and injected readers, without accessing real credentials or making network calls. Inspect these images, then replace `docs/images/switch.png` with the verified Switch image. The renderer is skipped in ordinary test runs.

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
just build-runtime "$PWD/dist/runtime" dev-small
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
just package "$PWD/dist/app" "Apple Development: Your Name (TEAMID)" \
  /Applications/ChatGPT.app/Contents/Resources/codex release
```

The package command:

1. Builds the complete Engine runtime from `engine/` using the explicitly selected profile. Distribution packages use the optimized upstream `release` profile; development packages use `dev-small`.
2. Checks the selected official CLI version and compares stable and experimental app-server schemas.
3. Builds the Swift app from `app/` and adds packaging resources and component notices.
4. Signs the Engine, Code Mode Host, zsh, rg, and app bundle. The Host receives the two V8 memory entitlements from `packaging/entitlements/`.
5. Verifies the signatures and executes the integration probe against the finished app.
6. Saves the app, runtime report, and build manifest, then cleans generated build artifacts.

Success requires every step. An output created before a failure is not a verified app. Existing output apps are never overwritten. The signer is explicit. See [Releases](releases.md) for tagging, signed and notarized Draft Releases, and manual publication checks.

The GitHub release job calls the same packaging script with explicit `--ci --engine-evidence /absolute/verified-engine`. It restores and verifies the selected artifact before importing signing credentials, then installs that unsigned runtime instead of compiling Rust. The final build manifest preserves its original Engine source and evidence independently of the tagged app source. Developer packaging without this option builds the Engine as shown above.

The `--ci` mode requires `GITHUB_ACTIONS=true`, retains the shared lock and disabled incremental compilation, and uses a 5 GiB reserve on an ephemeral runner. It leaves generated build files for the workflow's final cleanup step. The separate optimized Engine job saves timing reports and its compilation cache before cleaning. Local packaging retains automatic cleanup and the 30 GiB reserve. The reserve is not a guarantee that compilation will fit the available disk.

Replace an installed app only after the official ChatGPT app and its Codex Engine have exited. A running Engine may still load resources from its existing bundle path.

## Upstream updates

[`upstream.toml`](../upstream.toml) records the canonical Codex repository, base release tag, exact commit, and supported official app. Preserve the full upstream-shaped tree under `engine/`, including its licenses and dependency lockfiles.

Start from a clean committed product worktree:

```sh
just sync-upstream rust-vX.Y.Z
```

Replace `rust-vX.Y.Z` with the intended Codex release tag. The command fetches the complete objects for the recorded base and requested release without adding a remote or changing local tag refs. It constructs a three-way merge between the upstream base, local Engine changes, and the new release. Product files outside `engine/` remain intact; `upstream.toml` is updated with the new tag and commit.

A clean merge is applied as uncommitted working-tree changes. The command does not stage files, create a branch commit, push, or publish. It creates temporary Git objects for merge computation. If there are conflicts, it reports the affected paths and leaves source files unchanged; resolve the overlapping Engine changes deliberately before preparing the update again. Dirty worktrees, invalid provenance, and malformed release tags fail explicitly.

After the merge, Cargo updates workspace package versions in `Cargo.lock` while retaining existing external dependency pins, then validates the resolved graph with `cargo metadata --locked`. A missing lockfile or a resolution failure stops preparation before a candidate PR can be published; the uncommitted update remains available for inspection. The automatic candidate workflow uses this same path. CI checks dependencies with `--locked` so it reports stale lockfiles without rewriting them.

After an update, review the Engine diff and dependency locks, update the supported app metadata, run `just metadata-write`, run the affected checks, then rebuild and verify the complete package. Protocol equality alone does not prove official UI compatibility. Record the selected official app version and observed UI behavior in [Verification](verification.md). [Releases](releases.md) describes automatic candidate detection and Draft PR preparation.

## Continuous integration

The Actions list groups workflows by the prefix in their display names:

| Prefix         | Purpose                                                 | Entrypoints                                                                                  |
| -------------- | ------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `[🔍CI]`       | Validate changes.                                       | `Checks` runs on pull requests, pushes to `main`, and manual requests.                       |
| `[🚀CD]`       | Prepare the signed, notarized app for publication.      | `Draft release` runs manually for an existing release tag.                                   |
| `[🔧Util]`     | Monitor upstream releases or measure build performance. | `Monitor ChatGPT updates` runs hourly and manually; `Benchmark Engine builds` runs manually. |
| `[♻️Reusable]` | Shared jobs called by other workflows.                  | These have only `workflow_call` triggers and are not independent entrypoints.                |

Use these prefixes for new workflows. Workflow filenames identify automation calls; job names identify CI checks. Changing a display name does not change either identifier.

The root `.github/workflows/ci.yml` (`[🔍CI] Checks`) is the entrypoint for pull requests and pushes to `main`. All jobs use the same repository revision.

| Job                   | Checks                                                                                                                         |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Source and app checks | Formatting, Markdown, Engine source policies, Python tooling, Swift release build and tests, shell syntax, and plist metadata. |
| Dependency policy     | Cargo dependency license and advisory policy.                                                                                  |
| Spelling              | Codespell across product and Engine sources.                                                                                   |
| File size policy      | Changed file sizes with an explicit allowlist.                                                                                 |
| Engine and runtime    | Verified artifact reuse, or parallel CI and optimized builds with selected tests, Clippy, and runtime scenarios on `macos-15`. |

The required check succeeds only when every direct dependency succeeds; failed, skipped, or cancelled dependencies do not pass. After the lighter checks, Engine planning chooses either a new parallel CI/optimized build or verified reuse. The Engine gate explicitly requires both build jobs to succeed in build mode, or both to be skipped and a matching artifact to pass verification in reuse mode. A bare skipped Engine job cannot pass CI.

Candidate reports are retained for seven days; the combined verified Engine and evidence are retained for 90 days. See [verified Engine reuse](releases.md#verified-engine-reuse) for input scopes, provenance checks, concurrency, and expiry behavior.

Engine checks use an ephemeral runner with `dev-small`, disabled incremental compilation, and two workers. The parallel optimized build uses a separate runner and the upstream `release` profile. It runs app-server, login, model-provider, Code Mode, and Host package tests; core library tests; and account-isolation and zsh-approval core integration suites. Local commands retain the 30 GiB reserve. Signing certificates and real-account credentials are not required by CI.

Upstream workflow definitions remain under `engine/.github/` as vendored source. GitHub discovers only root workflows; the upstream Bazel, cross-platform, SDK, and V8 canary matrices are not automatic product checks. Official UI turns, real-account operations, signing, notarization, Intel macOS, and Windows/Linux packaging require separate validation.
