# Development

Run product commands from the repository root. The Swift package in `app/` builds the settings app and account router. The separately installed ChatGPT app supplies its signed official Engine and Code Mode Host.

## Prerequisites

- Apple silicon macOS 14 or newer with Xcode command line tools and Swift 6.
- The official ChatGPT app at `/Applications/ChatGPT.app`, matching `upstream.toml`, for routing verification and account operations.
- Python 3.12 or newer, uv 0.11.3, and just 1.51.0.
- Node.js 22, pnpm 10.34.5, and actionlint 1.7.11 for formatting and workflow checks.
- GitHub CLI for release automation and an Apple Development identity for signed local packages.
- The Rust toolchain specified in `engine/codex-rs/rust-toolchain.toml` for reference-source dependency checks and upstream preparation. Product builds do not compile Rust.

Install the locked formatting dependencies:

```sh
pnpm --dir engine install --frozen-lockfile
```

## Commands

| Command                                             | Purpose                                                     |
| --------------------------------------------------- | ----------------------------------------------------------- |
| `just build-app --jobs 2`                           | Build both Swift executables in release mode.               |
| `just test-app --jobs 2`                            | Run core and app tests with isolated fixtures.              |
| `just test-tools`                                   | Test product tooling and retained upstream tooling.         |
| `python3 scripts/format.py --scope app --check`     | Check Swift formatting.                                     |
| `python3 scripts/format.py --scope tooling --check` | Check Python, Just, Markdown, and workflow formatting.      |
| `just lint-workflows`                               | Validate GitHub Actions definitions and calls.              |
| `just lint-docs`                                    | Lint product Markdown.                                      |
| `just metadata-check`                               | Validate versions and the generated compatibility contract. |
| `just storage`                                      | Check the development free-space reserve.                   |
| `just finish`                                       | Clean generated Rust and Swift build artifacts.             |

Tests remove inherited `CODEX_TURNRAIL_ROOT` from the child environment. The invoking shell retains its environment. Tests use synthetic credentials and local fixtures; a skipped optional runtime fixture is not integration evidence.

Authentication tests inject protocol responses to verify repeated reads, bounded refresh, and identity, workspace, and expiry checks. The official Engine protocol fixture uses a synthetic credential file in an isolated home and verifies that repeated process launches do not rewrite it. Automated tests do not modify Keychain access permissions. Disabling interactive Keychain operations does not reliably suppress access-control modification dialogs; do not use such modifications as an unattended test fixture.

## Official Engine routing fixture

Build the helper, then run the opt-in fixture with the supported official installation:

```sh
just build-app --jobs 2
just test-integration /Applications/ChatGPT.app "/absolute/repository/app/.build/release/CodexTurnrailRouter" /absolute/review/runtime-verification.json
```

Use the actual repository path and a new report path. The fixture verifies OpenAI signatures and pinned app/CLI identities before execution. It uses an isolated `CODEX_HOME`, synthetic credentials, the native router, and a mock model. The real official Engine and Host execute Code Mode and approval decisions. The report requires thirteen passing scenarios: Code Mode, account switching, automatic titles, compaction, approval acceptance, approval rejection, stopping uncertain requests without replay, recovery on a new turn, native HTTP web search, recovery from an expired idle connection, a model response after 181 seconds of silence, cancellation during that wait, and the Engine's own idle timeout. Waiting tests use real loopback WebSockets and require exactly one upstream inference, including when the Engine times out. The fixture takes at least three minutes. Existing user hooks must also run without changes to their files. It also binds those results to the tested official binaries and router hash.

This command does not restart the desktop app or send real-account inference. Official UI browser behavior, account refresh, and real-service response handling require separate checks.

## Development app and signed package

To run Settings from the build directory:

```sh
CODEX_TURNRAIL_ROUTER_PATH="$PWD/app/.build/release/CodexTurnrailRouter" app/.build/release/CodexTurnrailApp
```

A missing helper, invalid official installation, or invalid signature is an error. App and Engine version differences from the release reference do not block launch. Account operations use the official Engine. **Open Codex** starts its router and Engine only after the existing ChatGPT app has exited.

Build a signed app in a new output directory:

```sh
just package /absolute/output/directory 'Apple Development: Your Name (TEAMID)' /Applications/ChatGPT.app
```

The command builds `CodexTurnrailApp` and `CodexTurnrailRouter`, adds the app resources and license notices, signs both executables and the app, verifies routing against the finished helper, and saves a build manifest and runtime report. It never copies or re-signs official executables. Success requires every step; a partial output is not a verified package. Existing apps are never overwritten.

The release workflow calls the same packaging script with `--ci`, which requires an actual GitHub Actions runner and uses a 5 GiB preflight reserve. It downloads and verifies the pinned official app for its isolated fixture. Signing, notarization, and uploaded-ZIP integrity checks still run for every release. See [Releases](releases.md).

Do not replace an installed Turnrail package while its router is serving ChatGPT. Restarting the official app is a user-coordinated step. Account assignments and shared conversation history remain in their existing stores.

## UI screenshots

Render production SwiftUI views using isolated demo accounts:

```sh
TURNRAIL_SCREENSHOT_DIRECTORY=/absolute/review-directory just test-app --filter SettingsScreenshots
```

The opt-in renderer writes `switch.png`, `accounts.png`, and `available-resets.png` at double resolution. It uses a temporary registry and injected readers without real credentials or network requests. Inspect the results before replacing documentation images.

## Storage policy

Heavy local commands share a repository lock, require at least 30 GiB of available space before starting, and use canonical build directories. Swift commands reject package and scratch-path redirection. Reference Engine commands select `dev-small`, disable incremental compilation, and reject conflicting profiles and output paths.

The reserve is a preflight threshold, not a disk-usage limit. Save logs and packages outside `app/.build` and `engine/codex-rs/target`. After all development processes end, run `just finish`, including after failures. Cleanup removes generated Swift artifacts and uses `cargo clean` only when a Rust target directory exists. It works below the reserve and preserves source, credentials, diagnostic archives, and packaged apps. Verify that an interrupted process has stopped before removing its stale lock.

## Upstream updates

`upstream.toml` records the reference official app and its exact bundled CLI version. The reference source pin is independent. Hourly app monitoring prepares release-reference PRs, and CI verifies the Swift router with the new signed official app. It does not update or compile the reference tree in `engine/`.

From a clean committed worktree, `just sync-upstream rust-vX.Y.Z` fetches the recorded base and requested release, prepares uncommitted source changes, updates provenance and lockfiles, and reports conflicts without publishing. It does not stage, commit, push, or move branch/tag refs. Review the reference-source diff and run the affected reference checks. Reference-source updates do not change the app release reference. For an official app update, change `[app]`, run `just metadata-write`, and validate the official runtime and affected product checks. A source tag or version match alone does not prove official UI compatibility.

The retained `build-engine`, `check-engine`, `test-engine`, `lint-engine`, `fix-engine`, and `build-runtime` commands are reference-source development tools. Follow `engine/AGENTS.md` when using them. They are not prerequisites for building or distributing Turnrail.

## Continuous integration

Workflow display names use `[🔍CI]` for validation, `[🚀CD]` for releases, `[🔧Util]` for monitoring or manual utilities, and `[♻️Reusable]` for shared jobs. Filenames identify automation calls; changing display names does not rename those identifiers.

CI classifies changed inputs using `scripts/ci_changes.py`. All changes receive static checks. Tooling changes add Python tests. App, router, packaging, or compatibility changes add Swift tests and the official Engine fixture. Reference-source changes add source and dependency policies. Product CI does not compile the reference Rust Engine. Manual benchmark workflows remain separate and can still compile it when explicitly dispatched.

The required gate accepts only successful checks or skips explicitly authorized by the change plan. Candidate runtime reports are retained as Actions artifacts. Real credentials, signing certificates, and desktop restarts are not needed for PR tests. Official UI, real-account behavior, signing, notarization, and installation remain separate validation stages.
