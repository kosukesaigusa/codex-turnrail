# Verification

## Official Engine integration status

The September 22-23, 2026 integration moves account routing into the Swift product and uses the unmodified, OpenAI-signed Engine and Host in the supported ChatGPT app. The installed app bundles have not been replaced. Hosted CI, notarization, and distribution of this integration remain pending.

All 122 Swift tests and 193 product Python tooling tests passed locally. The Swift run includes the real official Engine and Host, the router core linked into the tests, a built hook executable, synthetic accounts, and a local mock model. Ten required scenarios cover Code Mode, same-task account changes, titles, compaction, accepted and declined approvals, uncertain delivery without replay, new-turn recovery, native HTTP web search, and recovery from an expired idle connection. Existing user hooks still run without changes to their configuration files. Service rejection, response failure, and incomplete-output fixtures additionally confirm visible diagnostic reasons and exactly one upstream request per failed turn.

Boundary tests cover linked worktrees, empty assignments, parent-turn inheritance, model capability intersection, quoted configuration paths, persisted-history corruption, HTTP redirect and response-size rejection, and owned-process cleanup. Terminal routing errors use a non-retryable protocol error: a prior retryable response caused the official Engine to disable WebSockets for later turns. A fresh user turn can continue without replaying the failed inference.

Developer ID packages from this integration passed strict signature verification and manifest/runtime-report hash checks. An isolated real-service probe through a complete packaged router and official Engine passed Code Mode calculation, next-turn conversation recall, and an explicit title task with a Pro account. Normal configuration, hooks, and registry contents remained unchanged. Prototype results are not attributed to subsequent product packages without separate checks.

In the signed product desktop trial, the observed process chain was ChatGPT, the Swift router, the official Engine, and the official Code Mode Host. An existing task resumed and executed Code Mode. After the generated Computer Use plugin correction, the in-app browser opened a local fixture and clicked its reveal button. The displayed random marker matched the fixture hash, and the server recorded the click. This proves browser operation through that package; it does not prove native app control.

Native Computer Use still failed during policy initialization. Its OpenAI-signed service inherited the desktop router path and launched a second router, which cannot acquire the active routing ledger. The correction verifies the native parent's signature and delegates that helper process directly to the verified official Engine, retaining its arguments, stdio, home, and policy environment. The running official service passed the code-identity check. After the user restarted the signed correction, Computer Use successfully opened Calculator, clicked the number and operator buttons, and read the resulting `29×17` expression and `493` result. Native helper initialization and app interaction are verified for that package.

Native web search uses a separate HTTP endpoint under the configured model provider. The router now requires its existing thread/turn binding, forwards only approved headers using that account's authentication, and records delivery without replay. The official Engine fixture invokes the actual web tool through Code Mode and verifies the local search response, account, and metadata. After the corrected desktop restart, the native web tool returned real search results and opened the official Hooks documentation. A separate in-app-browser check opened the same page and read its title, heading, and body. The temporary tab was closed.

The signed local package containing native-helper delegation, web search, and service-error diagnostics passed all nine runtime scenarios. Independent checks verified both executable signatures and hashes, the app's deep signature, and the runtime-report hash. The user relaunched that package, and process inspection confirmed the exact packaged Settings/router paths and official Engine. It remains unnotarized. Generated build directories were cleaned after packaging.

Repeated Keychain prompts were traced to copied inspection credentials and access-control changes caused by updating them. The inspection-item lifecycle has been removed. The official Engine reads its own existing account home and exports the access token over a private protocol pipe; it owns the bounded refresh operation. Routine inspection does not write credentials or change Keychain access controls. Six protocol regressions and three isolated official Engine launches verify the read path with synthetic file-backed credentials. The user relaunched the signed correction and reported no dialogs; the task continued beyond the 60-second inspection cache. Expiry-triggered refresh and longer-term recurrence remain unverified. Access-control probes are not part of automated tests.

A separate desktop task failed twice with the previous generic account-rejection message, including after a new user turn. Both turns were bound to the same Pro account. The task had successfully compacted and completed several subsequent model calls before the first rejection. The previous implementation discarded upstream error details, so those two failures cannot be attributed to quota, authentication, or compaction from the retained evidence. The correction exposes only recognized protocol error identifiers and HTTP status; free-form server text and account data are not forwarded. A later attempt in the resumed task returned `misalignment_policy_violation`, confirmed in the saved rollout at 2026-09-23T05:14:52.531Z. This establishes a model-service safety stop for that attempt; it does not recover the discarded reasons for the earlier failures or identify the specific action flagged by the monitor. The router had also converted this structured code to a generic routing error. A regression reproduced the official Engine reporting `other`; the correction preserves `misalignmentPolicyViolation` for both standalone errors and failed responses. Synthetic official Engine tests verify exactly one upstream request and no account change. Free-form server details remain private. The correction is included in the subsequent signed connection-recovery package, which the user has relaunched. It preserves the safety stop and does not restore the stopped task. See [OpenAI misalignment monitoring](https://developers.openai.com/api/docs/guides/safety-checks/misalignment-monitoring).

Eight September 23 task logs contained the same generic connection-interruption error. Each followed several minutes or more without a user turn and occurred within approximately 0.2-2.7 seconds of the next submission. This supports an expired idle connection hypothesis; the previous diagnostics did not retain the underlying OS error or close code. An official Engine regression reproduced failure on the next turn after fixture connection expiry. The correction checks the connection before sending and replaces an unavailable transport once, retaining the same account and reconstructing conversation history. It stops before inference if the replacement is also unavailable. Real Foundation WebSocket tests exposed a pong timeout after consuming a response; retaining one bounded pending receive resolves it and also detects idle closure. Tests verify no inference during probes, continued history after reconnection, and exactly one request when the connection fails after transmission. A signed local connection-recovery package passed all ten runtime scenarios, independent executable/app signature checks, and manifest/report hash checks. The local launcher now selects this package, which also includes the structured safety-stop correction. It remains unnotarized and the installed app was not replaced. The user restarted it at approximately 17:42 JST on September 23. Process inspection confirmed the packaged Settings/router and official Engine/Host, and executable hashes matched the manifest. The current task resumed and executed tools without a new error event through 17:44:44 JST. A subsequent submission after a longer idle interval and longer-term recurrence remain unverified.

Remaining desktop checks include automatic desktop title creation, real-account switching, and Settings quit behavior. The classified safety stop still requires review of the affected task; correcting its protocol classification is not evidence that the original task can resume. Local Swift builds previously used the user's explicit exception to the 30 GiB free-space requirement; the repository's default requirement remains unchanged.

The sections below retain historical validation of the custom Engine architecture. Their counts, package layouts, and supported versions describe those revisions. Current versions are defined in `packaging/Info.plist` and `upstream.toml`.

## Release preparation for 0.1.0

The September 13, 2026 release-preparation checks used product version `0.1.0 (26)` and the pinned Codex `0.153.4` source. The optimized app and archive were built from committed source `95f9edd1a747d0e841aecb4f7fd086322d134c3d`. Subsequent documentation and spelling-configuration changes do not change the runtime source.

| Check                    | Observed result                                                                                                                                                                                                           |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Product versions         | Metadata validation and generated Swift compatibility checks passed. Version tests reject malformed, equal, and older releases while retaining unrelated plist fields.                                                    |
| Swift and Python         | All 40 Swift tests and 86 Python tooling tests passed.                                                                                                                                                                    |
| Optimized package        | The Engine and Code Mode Host built with the upstream `release` profile. Stable and experimental app-server schemas matched the checksum-verified official CLI.                                                           |
| Signed app               | Apple Development signing and deep/strict signature verification passed. The finished app passed JavaScript/parallel tools, approval acceptance, and approval rejection.                                                  |
| Archive                  | ZIP creation, SHA-256 verification, extracted app signatures, and binary hashes passed. A second archive attempt preserved the existing artifacts.                                                                        |
| Rejected artifacts       | Six checks rejected dirty-source provenance, another source revision, a changed binary, failed runtime results, an incomplete report, and a mismatched app version. Rejected inputs produced no ZIP or checksum manifest. |
| Upstream inspection      | The candidate extractor checked safe paths, the OpenAI signature, app metadata, and bundled CLI on a ZIP of the installed official app. The network download was substituted with that local archive for this check.      |
| Component notices        | The app includes 11 license and notice files, including a source index for 1,381 Rust packages and 13 MPL-licensed package records.                                                                                       |
| Source publication audit | All 16 source and history scan findings matched the pinned public upstream. Modified upstream files carry notices, and the product has an Apache-2.0 license.                                                             |
| Cleanup                  | The package command removed 6.7 GiB of generated Rust and Swift artifacts while retaining the signed app, reports, and logs.                                                                                              |

The live upstream observation preserved an HTTP 403 app-feed failure separately from the successful CLI release query. A new remote app download and automatic update PR have not been verified on GitHub. The local app is development-signed and not notarized; no binary release was published. Official UI and real-account checks remain separate work. Review was performed by the implementing agent, without an independent reviewer.

## Initial product identity validation

The September 13, 2026 validation used this repository's product identity, Swift module names, and `CODEX_TURNRAIL_*` environment variables. The signed app has bundle identifier `com.kosukesaigusa.codex-turnrail` and uses `~/Library/Application Support/Codex Turnrail` for its account registry and authentication homes.

| Check                      | Observed result                                                                                                                                                                                                                                            |
| -------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Engine build               | CLI, app-server, Code Mode Host, and integration helpers built from the same source tree with the verified upstream V8 pair.                                                                                                                               |
| Engine tests               | All 1,881 selected app-server and CLI tests passed with two workers and retries disabled; one additional test was skipped. JUnit reports zero failures and errors. The selection includes routing, account switching, model catalogs, and Last used tests. |
| Swift and Python           | All 40 Swift tests and 65 Python tooling tests passed.                                                                                                                                                                                                     |
| Clippy and source policies | App-server and CLI checks passed with tests included and warnings treated as errors. Cargo manifest, TUI/core boundary, and Bazel Clippy policy checks passed.                                                                                             |
| Initial push workflow      | Five real Git fixtures verified first-push size checks, ordinary push rejection of oversized files, the explicit allowlist, and rejection of a missing base revision.                                                                                      |
| Signed app and protocol    | Apple Development signing and strict signature checks passed. Stable and experimental schemas matched the official CLI. The Host retained both required V8 entitlements.                                                                                   |
| Packaged runtime           | JavaScript and parallel tools, approval acceptance, and approval rejection all passed with the finished app and isolated mock-model requests.                                                                                                              |
| Management UI              | The packaged app opened as **Codex Turnrail Settings**. Switch, Folders, and Accounts showed the initial empty state. **Running** reflected the existing official app and **Open Codex** was disabled.                                                     |
| Cleanup                    | Packaging removed 10.5 GiB of generated Rust and Swift build artifacts. The signed app, runtime report, logs, and JUnit report remained available.                                                                                                         |

The UI check did not connect an account or launch the official app. Connecting accounts and verifying official UI turns remain separate work. The sections below retain earlier evidence for the implementation; those earlier results alone do not verify the current product identity.

## Repository restructuring

The September 12-13, 2026 restructuring brings the Swift package into `app/` and the complete Engine source into `engine/`. Before copying, inventories recorded 46 app-repository files and 6,967 Engine files. The Engine import was checked against file contents and modes. Runtime source behavior is unchanged by the directory move.

The root commands derive both source paths from the repository. Product CI, packaging, integration verification, upstream metadata, and development storage control use the same layout. Project documentation is English; multilingual upstream fixtures retain the data needed by their tests.

| Check                      | Observed result                                                                                                                                                                                                                                                                                                   |
| -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Runtime build              | Engine and Code Mode Host built together from the nested source tree with the verified upstream V8 pair. The upstream builder assembled the complete runtime.                                                                                                                                                     |
| Runtime execution          | JavaScript and parallel tools, approval acceptance, and approval rejection all passed against the restructured package using the shared probe.                                                                                                                                                                    |
| Engine tests               | All 4,333 selected tests passed with CI's filter, default nextest profile, two workers, and retries disabled. Another 1,657 tests were excluded or ignored. JUnit reports zero failures and errors.                                                                                                               |
| Swift tests                | All 40 tests passed from `app/`.                                                                                                                                                                                                                                                                                  |
| Python tooling             | All 65 tests passed: 28 product tooling, 15 package builder, 17 installer, and 5 notarization helper tests.                                                                                                                                                                                                       |
| Upstream update tool       | Real Git fixtures verified preservation of product edits, additions, deletions, binary changes, and executable modes. Conflicts and dirty worktrees leave source unchanged. A filter-capable Git server fixture also verifies complete object retrieval without adding remotes or tag refs.                       |
| Engine source policies     | Cargo manifest, TUI/core boundary, and Bazel Clippy policy checks passed from the nested layout.                                                                                                                                                                                                                  |
| Clippy                     | Core and app-server checks passed with tests included and warnings treated as errors.                                                                                                                                                                                                                             |
| Packaging metadata         | Shell syntax and plist checks passed with the new paths.                                                                                                                                                                                                                                                          |
| Dependency policy          | The same cargo-deny 0.19.0 used by CI passed advisories, bans, licenses, and sources with all features enabled.                                                                                                                                                                                                   |
| Workflow and documentation | Actionlint, Codespell, Markdown lint, local links, and the source file-size allowlist passed.                                                                                                                                                                                                                     |
| Signed app                 | The root package command produced `0.9.0 (25)` with Apple Development signing. Stable and experimental schemas matched the official CLI; strict signatures and all three finished-app runtime scenarios passed. The Host had both V8 entitlements, and the four bundled binaries linked only to system libraries. |
| Cleanup and preservation   | Packaging cleaned 10.5 GiB of generated Rust and Swift artifacts. The signed app, standalone runtime, logs, and JUnit report remained available. The installed app version, protected process identities, account registry hash, and original Engine repository were unchanged.                                   |

The following sections retain earlier runtime and test evidence for the same implementation.

## Runtime and signing evidence before restructuring

A complete Apple Development-signed app was built with Engine and Host from the same checkout using `--locked`, `dev-small`, disabled incremental compilation, and the `aarch64-apple-darwin` target.

| Requirement             | Observed result                                                                                                                                        |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| V8 artifacts            | The upstream resolver verified SHA-256 checksums for the V8 150.4.0 library and Rust bindings selected by `Cargo.lock`.                                |
| Package layout          | The upstream builder included `codex-package.json`, `bin/codex`, Code Mode Host, dedicated zsh, and rg.                                                |
| Signatures              | Strict verification passed for all four bundled executables; deep/strict verification passed for the app. The Host's two V8 entitlements were present. |
| Dynamic dependencies    | The four bundled executables linked only to macOS system libraries.                                                                                    |
| Protocol                | Stable and experimental JSON schemas matched the official CLI.                                                                                         |
| JavaScript and tools    | A local mock Responses API drove app-server and Host execution. Two parallel commands used the packaged zsh and rg and exited with code 0.             |
| Approval outcomes       | Each scenario emitted one approval request. Acceptance wrote an isolated marker; rejection did not create it.                                          |
| Probe failure detection | A disposable package with a Host that exited immediately was rejected rather than recorded as successful.                                              |
| Model discovery         | The finished app's Engine retrieved five shared models from assigned accounts, with one default. No real-account inference was run.                    |
| Cleanup                 | Generated Rust and Swift artifacts were cleaned while the saved app remained executable.                                                               |

The common probe uses the Engine's Python SDK and upstream mock server. `CODEX_HOME` and the working directory are temporary, inherited routing is removed, and model traffic targets the local mock API. Homebrew is excluded from the probe PATH. Execution events and command output establish which zsh and rg were used.

The report is `runtime-verification.json` beside the output. All three scenarios passed, with two mock-model requests per scenario.

## Engine fix validation before restructuring

A targeted run of six packages completed with **5,965 passed, 0 failed**, and 25 separately skipped tests. It used `just test --locked --retries 0 --test-threads 4`; retries did not replace failures with success.

| Package                | Passed |
| ---------------------- | -----: |
| `codex-core`           |  4,089 |
| `codex-app-server`     |  1,460 |
| `codex-login`          |    202 |
| `codex-model-provider` |     74 |
| `codex-code-mode`      |     69 |
| `codex-code-mode-host` |     71 |

The zsh fix propagates rejected or cancelled subcommand decisions to the parent command's final `Declined` status. Five regression cases cover rejection, cancellation, ordinary execution failure, success, output, exit codes, and filesystem effects.

The parent-runtime fix preserves authentication captured before a residency reload can evict the parent. Its regression test verifies the same authentication manager and retained execution permissions, environments, and MCP extensions.

Test fixtures were corrected for unregistered parents, shared temporary-file races, duplicate completion waits, and unhandled subcommand approvals. A protected-file test verifies that approving both parent and subcommand does not bypass filesystem restrictions. App-server startup uses a 30-second bound while retaining required status and completion assertions.

The development test launcher removes inherited account routing only from the test process environment. Tests verify child isolation, preservation of the caller's environment, and unchanged routing for ordinary Codex launches.

Core and app-server Clippy passed with `-D warnings`. Swift, Python, Rust, Prettier, Codespell, shell, and Markdown checks also passed at that revision.

After those fixes, the CLI and Host were rebuilt together and assembled with the upstream package builder. The runtime passed JavaScript/parallel tools, approval acceptance, and approval rejection scenarios. Stable and experimental schemas matched the official CLI.

## Full Rust workspace result

The complete pre-restructuring run used `just test --locked --workspace --retries 0 --test-threads 4`. Of 17,006 executed tests, **16,960 passed and 46 failed**; 44 additional tests were skipped. One successful TUI test also reported nextest `LEAK` for a remaining output stream.

| Package                  | Failures | Observed condition                                                                                                                     |
| ------------------------ | -------: | -------------------------------------------------------------------------------------------------------------------------------------- |
| `codex-app-server`       |        1 | A legacy-executor MCP connection test timed out. An isolated rerun from the same source and workspace selection passed in 5.9 seconds. |
| `codex-install-context`  |        1 | The test discovered the actual package layout at `/opt/homebrew/bin/codex`, contrary to its absent-layout expectation.                 |
| `codex-mcp-server`       |        4 | Initialization returned version `0.153.4`; tests expected the fixed value `0.0.0`.                                                     |
| `codex-skills-extension` |        2 | Local user skills were loaded alongside fixtures, changing the expected result.                                                        |
| `codex-tui`              |       37 | 29 version or display-width expectation failures, 4 ANSI output mismatches with inherited `NO_COLOR=1`, and 4 stack overflows.         |
| `codex-v8-poc`           |        1 | The linked V8 enabled its sandbox while the POC crate's `sandbox` feature was disabled.                                                |

A successful full-workspace run has not been established. The isolated MCP success is retained separately from the failed full run. These conditions need classification and resolution; not every failure has been proven to predate the earlier Engine changes. The restructuring does not change those runtime sources.

## Hosted CI

The product now has one root CI entrypoint for app and Engine checks. The required job accepts only explicit success from every dependency. Engine CI builds the CLI, Host, and helpers; runs selected package and core tests; checks Clippy; assembles a runtime; and executes the shared probe. No signing identity or real-account token is needed.

Public-repository CI starts successfully on GitHub's standard runners. Earlier private-repository attempts stopped before runner startup because GitHub reported an account payment or spending-limit restriction. Current results are recorded per commit in [GitHub Actions](https://github.com/kosukesaigusa/codex-turnrail/actions/workflows/ci.yml). A release tag requires successful hosted CI for that exact main revision; local validation does not replace this check.

Hosted validation exposed an incorrect assertion in the zsh subcommand cancellation test: a parent `item/completed` event is not guaranteed when cancellation interrupts shell startup. The test requires the terminal `Interrupted` turn, distinct subcommand approval IDs, execution of the accepted first command, and no execution of the cancelled second command. Direct parent rejection and cancellation tests retain their command completion and `Declined` status assertions.

## Management UI and preservation

The signed output app was inspected on all three Settings screens. Quota, reset times, Last used, account connections, and folder assignments were visible. **Running** disabled duplicate official-app launch. See [Settings QA](design-qa.md).

Before and after that inspection, the registry remained schema 3 with the same revision, accounts, and SHA-256. The official app, Engine, and Host retained their process identities and start times. The output app was then closed and the installed `0.8.0 (24)` Settings was restored.

## Unverified scope

- Installation of the updated package in place of `0.8.0 (24)`.
- Codex UI turns in the official ChatGPT app and account switching with the updated runtime.
- Real browser login, reauthentication, logout, and removal.
- A hosted Draft Release build with Developer ID credentials.
- A successful full Rust workspace run and resolution of its remaining failures.
- Independent review.
- Developer ID signing, notarization, and external distribution.

An earlier preflight established that the unmodified official UI could launch and initialize the packaged Engine. Automated UI access was then rejected by the tool's safety review, so no official UI turn was established. Existing official sessions were preserved during later work.
