# Official Engine and reference sources

Turnrail uses the unmodified Engine and Code Mode Host included in the installed ChatGPT app. Its Swift router selects accounts outside those binaries. The app-server protocol, Code Mode runtime, browser integration, Shell, and approval implementation come from the official installation.

## Provenance and compatibility

[`upstream.toml`](../upstream.toml) records the exact official app bundle identifier, version/build, and bundled CLI version, separately from the reference source pin. It is the canonical reference; do not copy version numbers into this guide. The generated Swift contract must match that record.

The reference source tree in `engine/` retains its upstream layout, license, NOTICE, lockfiles, and product modifications for source inspection. It is not compiled or bundled by product CI or release packaging. Updating the reference tree still uses the [upstream preparation procedure](development.md#upstream-updates), including explicit conflict handling.

Every product routing fixture verifies OpenAI's signing team, exact app identity, CLI version, and the hashes of the official Engine and Host before recording success. Version equality alone is not sufficient. Changes to hooks, title tasks, request metadata, model discovery, or browser integration require renewed validation.

## Product implementation

Account selection, Keychain inspection, turn bindings, model catalog intersection, title registration, and WebSocket history recovery live in `app/Sources/CodexTurnrailCore/Router*.swift` and `OfficialEngine*.swift`. `CodexTurnrailRouter` is the small executable that starts the verified official Engine and relays app-server stdio.

The official app remains signed in to its original account. Model inference is routed separately; connected Apps and account-owned file services retain the original sign-in. The [architecture guide](architecture.md) defines this boundary and its effect on server-side file IDs.

## Validation

`just test-app` exercises routing and storage contracts with local fixtures. `just test-integration` runs the real official Engine and Host against a synthetic model through the native router. Product CI and packaging use this same official-runtime fixture. Real-service and desktop UI checks remain separate.

Reference Engine development commands and manual build benchmarks are retained for source investigations. They follow `engine/AGENTS.md`, the shared storage lock, and the 30 GiB local reserve. Results from those reference binaries do not establish compatibility of the distributed Swift router.

See [Development](development.md), [Verification](verification.md), and [Releases](releases.md).
