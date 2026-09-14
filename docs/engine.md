# Codex Turnrail Engine

`engine/` contains the Codex source tree used by Codex Turnrail. It is an ordinary directory in the product repository, with the upstream layout retained for updates and source review.

## Provenance

[`upstream.toml`](../upstream.toml) is the canonical record:

- Repository: <https://github.com/openai/codex>.
- Base release: `rust-v0.154.0-alpha.6.2`.
- Base commit: `b5bffd3ec4db487e7e3dec59663875b0ef7b72ca`.
- Matching CLI: `codex-cli 0.154.0-alpha.6.2`.

The base matches the CLI bundled with the supported official app. An official app update requires renewed compatibility validation. The upstream [LICENSE](../engine/LICENSE), [NOTICE](../engine/NOTICE), component licenses, and lockfiles remain in the source tree.

Use the root `just sync-upstream` command to prepare an upstream update. The [update procedure](development.md#upstream-updates) explains its clean-worktree requirement, three-way merge, and conflict behavior.

## Customization boundary

The Engine changes:

- Bind each loaded root task runtime to an explicit `AuthManager` and preserve authentication for active work.
- Select permitted accounts from ordered directory rules at each top-level turn.
- Reconstruct idle persisted or ephemeral task runtimes with the selected account while preserving identity and history.
- Preserve authentication through history reverts, forks, child agents, and residency reloads.
- Verify registered email before reauthentication credentials are saved and before account routing.
- Record the last top-level turn start separately from the routing registry.
- Advertise shared models for assigned accounts and validate the selected account's model before a turn.
- Preserve a parent command's declined status in completion events when an intercepted zsh command is rejected or cancelled.

The public app-server protocol remains identical to the matching upstream version. Code Mode Host and V8 runtime source remain upstream implementations.

Cancelling an intercepted command can interrupt shell startup before the parent command emits a completion event. The turn still completes with `Interrupted`; an accepted earlier subcommand may have run, while the cancelled subcommand must not run.

Product build, cleanup, upstream update, and integration entrypoints live at the repository root. Engine policy adjustments remain beside the relevant upstream tooling. The runtime probe is [`tests/integration/verify_runtime.py`](../tests/integration/verify_runtime.py); packaging and CI invoke the same probe.

## Development and validation

Use the root commands documented in [Development](development.md). Heavy local commands enforce the 30 GiB reserve, `dev-small`, disabled incremental compilation, and a shared lock. Tests do not inherit the user's routing root.

Product CI lives in the root `.github/workflows/`. It checks both source trees and builds the Engine, Host, and runtime from one candidate revision. Vendored definitions beneath `engine/.github/` are not automatically discovered by GitHub Actions.

[Architecture](architecture.md) defines the runtime contract. [Verification](verification.md) records successful checks, full-workspace failures, and unverified UI and account scenarios. [Roadmap](roadmap.md) tracks remaining delivery work.
