# Architecture

## Runtime boundary

Codex Turnrail combines a Swift menu bar app with a local account router. **Open Codex** starts the installed official ChatGPT app with `CODEX_CLI_PATH` pointing to `CodexTurnrailRouter`. The router verifies the official installation and starts its unmodified `Contents/Resources/codex` executable. Code Mode uses the official Host in the same installation. Turnrail does not replace, copy, or re-sign official binaries.

The router relays the app-server stdio protocol and adds process-local routing configuration. Normal ChatGPT launches use the official configuration. Closing Turnrail Settings does not stop the router or the Engine already serving ChatGPT. The router owns its Engine process group; shutdown targets only that group and its local connections.

ChatGPT also supplies a CLI path to its per-task MCP helpers and writes a separate configuration for its bundled Computer Use plugin. The router changes only `CODEX_CLI_PATH` values pointing to its own executable to the verified official Engine path. It prepares per-task overrides on creation, resume, and fork, and synchronizes the current app version's generated plugin configuration before Engine startup and task or MCP loading. The generated file must be an owned regular file inside the current Codex home. Other CLI paths, permission settings, enabled surfaces, and policy values are preserved; policy checks remain enforced. Browser and native Computer Use helpers can then read configuration and policy through their own official app-server process.

The app version, build, and bundled CLI version in `upstream.toml` are a release reference, not a runtime allowlist. Settings shows a green version indicator for an exact reference match and yellow for a different version; either can launch. Clicking the indicator explains the difference and links to releases. The indicator is separate from the Running or Ready status and does not claim full feature compatibility.

The app, Engine, and Host must still pass strict OpenAI signature verification before execution, and the selected Engine must belong to the official installation. Browser plugin paths use the installed app version, and model catalog requests report the installed Engine version. Turnrail uses one integration path across versions, without version-specific adapters or guessed substitutions. Missing runtime requirements and invalid protocol data remain explicit errors. Product CI and packaging retain exact reference identity checks for reproducible evidence.

The native Computer Use service can also inherit the desktop's router path directly. When the calling process has the official OpenAI signature and `com.openai.sky.CUAService` identity, the router replaces that helper process with the verified official Engine before opening any account registry or routing ledger. Arguments, stdio, the original home, and policy environment are preserved. The helper does not create a second account router or receive additional Computer Use permissions.

## Directory and turn selection

The account registry uses `state.json` schema version `3`. Both `routing.defaultAccountIDs` and `routing.directoryRules` are required. Each rule contains an ID, an absolute directory, and ordered account IDs. The same list defines permission and priority; registering an account does not expand its assignments.

The `UserPromptSubmit` hook supplies the official Engine's effective working directory and task/turn IDs. The router resolves the path and selects the deepest rule by path component. Linked Git worktrees are mapped to their original checkout only after ownership, metadata, and the back-reference are verified. Invalid worktree metadata is an error. Empty matching rules reject the turn instead of selecting another rule.

Selection checks only assigned accounts in order. Missing login, permanent authentication failure, or exhausted general quota can advance to the next assigned account. Transport failures, malformed quota, workspace-policy mismatches, and identity mismatches stop selection. A spending cap alone does not exclude an account while general usage is allowed.

The selected account is bound durably to the task and turn before inference. Changing priority affects the next turn. Active turns never change accounts automatically. Child-agent and guardian requests must identify a known parent turn and inherit its binding. Compaction uses the current binding, or the task's last completed binding for an explicit idle compaction.

## Model traffic and conversation recovery

The router listens only on `127.0.0.1`, with a random endpoint secret and private endpoint metadata. It accepts bounded JSON WebSocket requests from the official Engine. Browser-origin requests, ambiguous HTTP headers, unknown routing metadata, account-specific routing hints, and inference without a binding are rejected. Prewarm requests may only use `generate=false` and receive a local empty completion.

Upstream requests use TLS to the verified ChatGPT backend and the selected account's access token and workspace ID. The router preserves the Engine's tool, model, and response protocol. Shell execution, approval, Code Mode, and browser-tool execution remain in the official runtime.

Native `web.run` uses HTTP `POST /alpha/search` under the configured provider. The router requires the thread and turn from its metadata to have an existing model-request binding, including for child agents whose search metadata omits the parent turn. The selected account supplies authentication; only the protocol's originator, version, and turn metadata headers are forwarded. Request and response sizes are bounded, redirects are rejected, and a submitted search is not replayed or moved to another account.

The private ledger stores turn bindings and completed response history. Message bodies are content-addressed; response records retain input deltas and the previous response relationship. When the account or upstream connection changes, the router reconstructs known conversation input and removes `previous_response_id`. It never assumes an unknown response ID belongs to the selected account. Corrupt or cross-task history is an error.

Before transmitting a model request, the router requires a WebSocket pong within ten seconds. If a reused connection fails this check, it establishes and checks one replacement for the same bound account before sending. A new connection generation reconstructs the known conversation input. Failure of the replacement check stops the turn without inference. One receive remains pending between responses, buffering at most one message, so that Foundation continues processing pong and close frames.

Every upstream connection also sends a keepalive ping every twenty seconds, including between requests and while awaiting model output. Foreground and periodic probes are serialized. Missing pongs terminate the connection and wake pending operations; they do not submit or replay inference. The official Engine owns model-response waiting and its idle timeout. Turnrail imposes no additional deadline on model output and does not override the Engine's timeout. When the Engine cancels or times out and closes its connection, the router closes the bound upstream connection and wakes its pending receiver. Closure, transport timeouts, and Foundation callbacks complete each waiter once, preserve the first failure, and prevent a closed connection from passing another probe.

A request is recorded before upstream transmission. Completion and history are committed before acknowledging completion to the Engine. A connection failure during transmission or an uncertain result blocks that turn; submitted requests are not automatically replayed and are not moved to another account. A new user turn is required after such a failure. Unsupported background inference purposes are rejected rather than sent using an unspecified account.

Terminal service diagnostics distinguish request rejection, failed responses, and incomplete responses. Only recognized protocol error codes, reason identifiers, and valid HTTP error status are displayed and retained by the desktop's normal task log. Transport diagnostics include the check/send/receive phase, allowlisted numeric OS error codes, and valid WebSocket close codes. Free-form server messages, unknown identifiers, response content, URLs, and credential headers are not forwarded. Missing or unrecognized reasons are stated explicitly; failures remain terminal without automatic replay.

Transport failures also receive a reference ID and an owner-only archive entry in `<Turnrail root>/router/transport-diagnostics.json`. The archive retains the last 64 failures within a 256 KiB bound. Entries record the transport cause and age, normal-turn or compaction purpose, connection reuse, request size, elapsed and silent time, received event count, and whether `response.created` was observed. They exclude account identities, task IDs, prompts, tokens, and server text. Unavailable or invalid diagnostic storage is stated in the original transport error instead of hiding that error or overwriting unrelated files.

## Automatic titles and hooks

The official app creates title tasks with ordinary prompt hooks disabled. The stdio observer recognizes `thread/start` and `thread/fork` with source `thread_title`, then registers the returned task ID and working directory before forwarding the response to ChatGPT. Title inference requires that registration and matching title metadata.

Turnrail supplies `UserPromptSubmit`, `PreCompact`, and `Stop` hooks through command-line configuration. It asks the official Engine for their exact trust hashes and trusts only those commands. Other user and project hooks retain their own definitions and trust status. Turnrail does not modify the normal `config.toml` or `hooks.json`. Task overrides and configuration writes that would bypass routing are rejected.

## Authentication and models

Each account has an authentication home under `~/Library/Application Support/Codex Turnrail/accounts/<account-id>/auth-home`. The official CLI's Keychain entry key derives from the canonical home path. Tokens are not written to the routing registry or history ledger.

Account login and account-status reads use the signed official Engine. Reauthentication signs in to a temporary home, validates the registered email and token workspace, then commits credentials to the original Keychain entry. A mismatched login preserves the previous credentials. Routine router inspection starts the official Engine in the account's existing authentication home under the same account lock as Settings operations. Its `getAuthStatus` response supplies the access token over a private protocol pipe; `account/read` supplies identity and workspace policy. Turnrail validates email, token expiry, workspace identity, and backend policy before routing. A near-expiry token is refreshed once by the official Engine and must retain the workspace identity. The router keeps only the returned access token in memory. It does not copy, clear, or rewrite Keychain entries during inspection, and it never changes access permissions.

Startup obtains a model catalog from assigned, signed-in accounts and advertises their common models, reasoning levels, modalities, and service tiers. Incompatible tool protocols are excluded. The catalog is supplied to the official Engine through process-local configuration. Restart ChatGPT through Turnrail after changing account assignments to rebuild this global catalog. Account inspection is cached for up to 60 seconds; each routed request checks its model and selected options against the selected account's catalog.

## Data ownership

ChatGPT's own sign-in remains unchanged. The router selects authentication for model requests; it does not switch the app's connected Apps, uploads, or other account services. A server-side file ID created under the app's account may be inaccessible to a model request under another account, even in a new task. Local files and image content already present in model input follow the selected request account.

The normal `~/.codex` history is shared. The router additionally retains private request history under `<Turnrail root>/router`, with owner-only permissions. Folder rules control permitted request accounts, not history partitioning or redaction. Only assign accounts authorized to receive the same code and conversation context. Removing an account removes its credentials and assignments, but not shared task or routing history.

## Settings and usage

**Switch** compares usage and changes priority. **Folders** edits assignments. **Accounts** manages sign-in and removal. Both account lists share **Account**, **Usage**, and **Last used** columns. Positive saved-reset counts open details; zero adds no row or spacing. Authentication and account actions remain in **Accounts**. The interface is English.

Settings refreshes identity and quota approximately every 60 seconds, on activation and wake, and on manual request. Full-account refreshes do not overlap. Operation IDs invalidate stale results after reauthentication or removal. Errors replace previous values explicitly.

Quota comes from `account/rateLimits/read`. When the optional `rateLimitsByLimitId` map exists, the UI selects the general `codex` bucket; otherwise it uses the protocol's `rateLimits` snapshot. Invalid percentages are rejected. Optional reset-credit data distinguishes unknown availability, zero credits, unavailable details, partial details, and non-expiring credits. Credits are display-only.

The router records **Last used** when the prompt hook successfully binds an account, before inference starts. It stores a monotonic timestamp in that account's schema-1 `last-used.json`. Failed writes stop the hook. Settings reads these records every five seconds; absent history displays `-`.

## Distribution and verification

The app bundle contains two signed Swift executables: `CodexTurnrailApp` and `CodexTurnrailRouter`. The official ChatGPT installation supplies its own Engine and Host and retains OpenAI's signatures and entitlements. No Rust runtime is built or included by the product release workflow.

The local runtime fixture uses the real official Engine and Host, the router core linked into the test process, the packaged hook executable, synthetic credentials, and a local mock model. It checks Code Mode, account changes, titles, compaction, accepted and declined command approvals, uncertain delivery without replay, recovery on a new turn, native HTTP web search, and recovery from an expired idle connection. Foundation WebSocket tests additionally verify ping/pong after a completed response, idle disconnection detection, and no replay after transmission. Packaging records official binary hashes and the router hash, then signs, notarizes, and verifies the distribution. These checks are separate from running the complete packaged router with real accounts and validating the official UI.

See [Development](development.md), [Releases](releases.md), and [Verification](verification.md) for commands, delivery rules, and observed results.
