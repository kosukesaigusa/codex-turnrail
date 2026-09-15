# Architecture

## Product contract

Codex Turnrail combines a macOS menu bar app in `app/` with a dedicated Codex Engine in `engine/`. The companion launches the unmodified official ChatGPT macOS app (`ChatGPT.app`) in Turnrail mode for Codex tasks. Normal launches retain official behavior. Closing Settings does not stop an Engine already serving ChatGPT.

Folder rules define both permitted accounts and their priority. Changes apply to the next top-level turn in every conversation matching that rule. Active turns, child agents, reviews, and compaction retain the authentication already bound to their task.

## Directory routing

The registry uses `state.json` schema version `3`. Both `routing.defaultAccountIDs` and `routing.directoryRules` are required. Each directory rule contains an `id`, an absolute `directory`, and ordered `accountIDs`. The same array expresses permission and priority; there is no separate global selection. Registering an account does not expand its permissions.

Settings stores resolved directory paths. The Engine resolves the execution directory and selects the deepest matching rule by path component. For a linked Git worktree, the existing Git trust resolver verifies ownership before mapping the relative directory to the original checkout. If ownership cannot be established, routing uses the actual worktree directory.

Execution-directory precedence follows the normal turn contract: `turn/start` cwd, local-environment cwd, then saved thread settings. No organization, profile, email, or plan receives special routing. Missing settings, invalid account IDs, and duplicate rules produce explicit errors. The runtime accepts schema 3 only.

## Task runtime and history

One Engine process owns one canonical task store. Each loaded task runtime is bound to an `AuthManager` when it is created.

Before a new top-level turn, the Engine compares the selected account with the task's current account. If they differ, the task must be idle. The Engine then reconstructs its runtime with the same thread ID and history and the selected `AuthManager`. Persisted tasks retain saved history; ephemeral tasks retain their in-memory history and context. The new turn is submitted after reconstruction.

A `thread/revert` reload retains the authentication bound to that task. Forks and child agents inherit their parent's authentication, including when residency reloads evict an idle parent. Different tasks can execute concurrently under different accounts without switching an active task's credentials.

## Model discovery

The official `model/list` input has pagination and hidden-model options but no folder or thread ID. `TurnrailCoordinator` therefore collects accounts assigned to any rule and fetches their remote catalogs with their own authentication.

The returned list contains shared models and the common reasoning efforts, input formats, and service tiers. One visible model is marked as the default. Unassigned accounts are not queried. Assignment changes affect the next request. Each request fetches the remote catalogs; failures become RPC errors.

Before an idle turn starts, the Engine resolves the requested model from the normal model or collaboration-mode input and saved settings. It verifies availability in the selected account's current catalog before stopping the idle runtime. An invalid request does not reach inference or history, and the original runtime remains available for a corrected request.

The official app's model picker remains global and refreshes when that app requests the list. The Engine independently rechecks availability before each new idle turn.

## Account status

Settings owns the lifetime of periodic refresh tasks. Quota and identity refresh approximately every 60 seconds, plus activation, wake, and manual refresh. Full-account refreshes do not overlap. Existing values remain visible during a request; a confirmed failure replaces them with an error.

Each asynchronous account operation has an identifier. Starting reauthentication or removal invalidates older identity and quota results. Accounts being authenticated or removed are excluded from automatic refresh.

The Engine records a known account's `TurnStarted` event in `<root>/accounts/<account-id>/last-used.json`, with schema 1, the account ID, and Unix seconds. File locking and atomic replacement prevent concurrent turns from replacing a newer timestamp with an older one. Authentication and quota checks do not update this timestamp.

An independent task reads this metadata every 5 seconds and displays local time in **Last used**. Missing history displays `-`; read failures expose diagnostic details. Removing an account deletes its account directory and usage timestamp.

## Failure behavior

- Account selection stays within the matching rule. An empty rule rejects the request; it does not select another rule.
- Only missing login, permanent authentication-refresh failure, and exhausted general Codex quota permit advancing to the next assigned account before a turn.
- General Codex quota is unavailable when `rate_limit.allowed` is false, `rate_limit.limit_reached` is true, or either usage window is fully consumed. A reached spending cap alone does not exclude an account whose general quota is available.
- Quota transport failures, missing general quota buckets, invalid percentages, and registered-email mismatches fail immediately.
- Model lookup failures, invalid catalogs, and models unavailable to the selected account are explicit errors. They do not advance account priority.
- An expired authentication label requires the specific `token_expired` error. Other failures are not guessed to be expiration. Reauthentication is an explicit user action.
- Turns are not automatically replayed after starting, executing a tool, or reaching an uncertain side-effect boundary.
- Failure to write **Last used** produces a thread warning without repeating the turn.

## Authentication and storage

Each account is added through a fresh ChatGPT browser login. The companion validates email and plan through the dedicated Engine's `account/read`; neither is entered manually.

Reauthentication passes the registered email to the Engine. Credentials are replaced only if the OAuth callback's ID token contains the matching email. A mismatch, missing email, or invalid token fails while preserving the previous credentials. Before quota checks and task creation, the Engine also compares stored authentication with the registry email.

The canonical task store uses the normal `~/.codex`. Each account has a separate authentication home under `~/Library/Application Support/Codex Turnrail/accounts/<account-id>/auth-home`. Keychain entry keys derive from the authentication-home path, keeping credentials separate from other accounts and task history.

Credential storage explicitly uses `Keyring`. Keychain failures fail login instead of writing credential files. The registry stores internal IDs, verified identities, and routing rules. It does not store tokens or quota responses.

Conversation history is shared across accounts in the canonical task store. Switching an idle task to another account carries its existing context into the next inference request under that account's authentication. This includes earlier messages and tool results retained in the context.

Folder rules control which account may execute the next turn. They do not partition or redact conversation history. Assign only accounts authorized to receive the folder's code and conversation context, and keep work folders restricted to accounts approved for that work.

Quota comes from the account-specific `account/rateLimits/read` response. When `rateLimitsByLimitId` is present, the UI selects the general `codex` bucket and excludes model-specific buckets. Otherwise, it displays the required `rateLimits` snapshot from the same response, as defined by the upstream protocol. Invalid `usedPercent` values are rejected rather than clamped.

The same response provides the optional `rateLimitResetCredits` summary. A missing summary means availability is unknown, not zero. Its `availableCount` is authoritative; `credits: null` means details were not obtained, and a shorter detail list can reflect the server's cap. The detail view reports unavailable or partial details explicitly. Available credits are ordered by expiration, with non-expiring credits last. A null expiry means no expiration; a missing or malformed expiry is an error. Backend titles are used when present; the protocol's `codexRateLimits` type is labeled **Full reset** when its optional title is absent. Unknown reset types are never labeled as full resets. Reset credits are display-only; Turnrail does not consume them.

Account removal first logs out its credentials. Only after logout succeeds does it remove the registry entry, authentication home, timestamp, and assignments. Other accounts retain their order. Shared conversation history in `~/.codex` remains.

## Management UI

**Switch** compares quota and changes priority for a folder. **Folders** edits assignments. **Accounts** adds, reauthenticates, and removes global accounts. Launch status, **Open Codex**, and **Check Compatibility** sit below the sidebar. **Open Codex** launches ChatGPT with the dedicated Engine. A running ChatGPT app disables duplicate launch.

Both account lists share **Account**, **Usage**, and **Last used** columns. Each usage window groups its name, next reset, remaining percentage, and a thin bar. A positive available-reset count opens the detail sheet; a zero count contributes no row or spacing. Individual credit expirations appear only in that sheet. Authentication status, reauthentication, and removal remain in **Accounts**. Five-hour and weekly windows remain separate within the shared usage column.

The interface is English. Normal screens show the quota, reset times, timestamps, and errors needed for decisions. Detailed errors expose the complete diagnostic JSON without persisting it. Internal paths and nonessential helper text are not shown.

Initial launch and macOS reopen events invoke SwiftUI's `OpenSettingsAction` through the persistent menu-bar label, creating or focusing Settings regardless of the launcher.

## Runtime package and compatibility

The Engine and Code Mode Host are built together from the same pinned upstream source. Custom authentication and routing live in the Engine; the Host and V8 runtime retain their upstream implementation. The Host executes JavaScript and requests tools from the Engine. The Engine owns approval and actual Shell or MCP execution.

The product builder verifies the upstream V8 library and Rust binding checksums selected by `Cargo.lock`, builds with `--locked`, and invokes the upstream package builder. The package includes verified zsh and rg distributions:

```text
Contents/Resources/engine/
├── codex-package.json
├── bin/
│   ├── codex
│   └── codex-code-mode-host
├── codex-path/rg
└── codex-resources/zsh/bin/zsh
```

The companion launches `engine/bin/codex`. Runtime discovery uses this manifest and layout. The official app supplies the UI and version reference; runtime binaries are built from this repository.

Packaging compares stable and experimental app-server schemas with the official CLI. Launch checks the exact official app version, build, CLI version, and Engine version. A mismatch prevents Turnrail mode. `CODEX_CLI_PATH` and `CODEX_APP_SERVER_FORCE_CLI` are validated against the supported app version; their long-term availability is not treated as a stable public extension contract.

## Signing

Development packages use an explicit Apple Development identity. The Engine, Host, rg, zsh, and app bundle are signed. The Host receives `allow-jit` and `allow-unsigned-executable-memory` entitlements for V8.

The finished app is checked with strict signature verification and a local mock-model probe covering JavaScript, parallel tools, packaged binaries, and approval decisions. Its report is saved next to the app. Build artifacts are cleaned after verification. Installation must preserve any runtime path still used by a running official app or Engine.

See [Development](development.md) for build commands, [Releases](releases.md) for Developer ID distribution and notarization, and [Verification](verification.md) for observed evidence.
