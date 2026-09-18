# Releases and upstream maintenance

## Versioning

Turnrail uses one product version for the app and its bundled Engine. `packaging/Info.plist` is the canonical product version and monotonically increasing build number.

The Settings sidebar displays this product version. `just metadata-write` generates `TurnrailVersion.generated.swift` from the plist, and `just metadata-check` rejects a stale display version. `just version` updates both the plist and the generated display version.

During `0.x` development, a patch release fixes bugs within the same supported ChatGPT app and Codex CLI combination. A minor release adds features or changes that supported combination. `1.0.0` will mark an explicitly stable product contract. Released tags and assets are never moved or replaced.

`upstream.toml` records the ChatGPT app bundle identifier, version, and build together with the Codex Engine source repository, release tag, and commit. The required CLI version is derived from the source release tag. Generate the Swift compatibility contract with `just metadata-write`; `just metadata-check` rejects drift between this contract and the Engine version.

Prepare a version change as ordinary reviewed source:

```sh
just version 0.2.1
just metadata-check
```

The version command increments the build number and rejects malformed, equal, or lower versions. It does not commit, push, or tag.

## Draft release workflow

Merge a PR that increases the product version. When that exact revision's main push CI succeeds, `[🚀CD] Prepare release after CI` automatically creates its immutable version tag and starts `[🚀CD] Draft release` from `main`. The release stays a draft until a maintainer completes the manual checks and publishes it.

The preparation workflow runs trusted main code and verifies the originating workflow, repository, branch, commit ancestry, and latest exact-revision CI result. It compares the product version with the commit's first parent. Documentation changes and other commits without a version increase do not create a release. A newer version already on main supersedes an older candidate; a repeated completion event cannot recreate or move an existing tag.

For a version merged before automation was enabled, or an explicitly initiated release, the manual command remains available:

```sh
just release-tag --dry-run
just release-tag
```

Tagging requires a clean `main` worktree that matches the remote and a successful latest `main` CI run for that exact commit. The tag must match the product version. Existing tags are rejected.

Both entry points dispatch `.github/workflows/release.yml` from `main`, with an existing tag as its explicit input. The workflow rejects other branch refs, then verifies the tag, source ancestry, metadata, and CI before checking out the tagged commit and using the protected `release` environment. It then:

1. Downloads the matching official CLI release and verifies its source commit, archive SHA-256, size, and executable version.
2. Resolves a verified optimized Engine artifact with matching source, tooling, and runner inputs. If none remains, it explicitly builds and verifies a new Engine using the parallel CI pipeline. It then builds the Swift app from the tagged source.
3. Compares stable and experimental app-server schemas, includes component notices, signs every executable and the app, and verifies the signatures.
4. Runs all three runtime scenarios against the finished app.
5. Submits a signed ZIP to Apple's notary service, requires `Accepted`, attaches the ticket to the app, and verifies the ticket and Gatekeeper assessment.
6. Creates the final app ZIP from the stapled app and records its original checksum alongside the build, runtime, and notarization reports.
7. Uploads only the app ZIP to a Draft Release with a direct download link and notes generated from merged PRs.
8. Downloads that uploaded asset by its GitHub asset ID and checks its SHA-256 and size against the original archive. The GitHub digest must also match. A mismatch fails the job and leaves the release as a draft with pending verification.
9. Records successful download verification in the draft notes and retains the detailed verification files as an Actions artifact for 90 days. Publishing remains a separate maintainer action.

The build manifest records the product and upstream versions, app source commit, build profile, compiler versions, signer, binary hashes, and notarization report hash. For a reused Engine, it also embeds the original Engine source/workflow commits, input identity, producer run and attempt, and hashes of the unsigned runtime and its CI/runtime evidence. The app source commit must still match the exact tagged commit. Archive creation rejects uncommitted source, another source revision, changed binaries or app resources, failed or incomplete reports, unnotarized apps, and version mismatches. It verifies the attached ticket and Gatekeeper assessment again before creating the ZIP.

An existing tag whose workflow failed before creating a release can be retried with the workflow's manual `tag` input, selecting `main` as the workflow ref. If tagging succeeded but dispatch failed, start the same workflow manually; keep the tag. If a Draft Release already exists, inspect it and retain its assets; the workflow does not overwrite it.

## Verified Engine reuse

CI selects checks by affected inputs, not by a special README rule. It compares the PR base with its tested merge commit, or the previous main commit with the pushed commit. All changes receive formatting, Markdown, workflow, spelling, and file-size checks. Additional checks are combined when a change affects multiple areas:

| Changed inputs                                                            | Additional validation                                                                                  |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| Product documentation, screenshots, and root Markdown                     | None; static checks only                                                                               |
| Monitoring, release automation, release notes, and CI selection           | Product Python tooling tests                                                                           |
| Swift source/tests, app resources, versions, or compatibility metadata    | Swift formatting, app build/tests, and tooling tests                                                   |
| Rust dependency policy workflow                                           | Dependency checks and tooling tests                                                                    |
| Engine source, build commands, runtime verification, or evidence contract | Engine formatting/source policies, dependency checks, tooling tests, and both Engine verification jobs |
| Shared development build helper                                           | Both app and Engine checks                                                                             |

`scripts/ci_changes.py` defines these impact rules. Renames include both the old and new paths, and deletions keep their original impact. Unknown paths or missing comparison data fail with an explicit error; classify new build helpers and workflows before adding them. In particular, a new helper used by the Engine must also be included in its input scopes.

Manual CI dispatch defaults to `scope: auto` and uses the same rules. A branch is compared with its merge base on main; a dispatch on the current main commit compares its first parent. `scope: full` explicitly requests every check. Automated upstream and README PRs use this same selection; their branch names or author identities do not grant an exemption. The required CI gate rejects failed checks and any skip not authorized by the computed plan.

The Engine input scopes in `scripts/engine_artifacts.py` cover `engine/`, the actual runtime build and measurement helpers, shared GitHub/evidence helpers, runtime integration probes, and Engine producer workflows. They do not include the whole `scripts/` directory, general CI orchestration, release automation, or app/documentation inputs. The same scopes determine both Engine CI selection and the reusable artifact identity. Markdown inside `engine/` remains an Engine input because prompts can be compiled into binaries.

When Engine verification is required, its SHA-256 artifact key combines these Git objects with the target, two build profiles, actual Rust compiler, Xcode, SDK, Clang, macOS build, and hosted runner image. External compiler overrides are rejected. Changes to any of these inputs require a matching verified artifact or a new Engine build. The same input scopes govern release artifact reuse, so a monitor-only change does not invalidate an otherwise matching Engine.

When no retained successful result matches, two jobs run on separate macOS runners in parallel:

- `engine-checks.yml` builds `dev-small`, runs the existing nextest suites and Clippy, assembles the runtime, and verifies execution and both approval decisions.
- `engine-release.yml` builds the optimized `release` Engine and Code Mode Host, then verifies that runtime with the same three scenarios. It has no signing credentials.

Only after both jobs succeed does `engine.yml` seal a `turnrail-engine-<input-key>-<run-attempt>` artifact containing the unsigned runtime and its checksummed CI/runtime evidence. It is retained for 90 days. This means two major Engine build stages for new inputs, including additional test-binary compilation and Clippy work within CI. No rebuild is needed in main CI or release packaging while matching evidence remains available. Parallelization reduces elapsed waiting time; it does not reduce the runner minutes used by those two jobs.

Reuse checks GitHub's artifact ID, archive size and SHA-256, run/attempt and workflow provenance, source Git objects, internal checksums, successful test counts, and all runtime scenarios. Only completed successful runs from this repository's CI or release workflow may provide cross-run evidence. Fork PRs can run CI but cannot supply an Engine to another run or a signed release. A release may consume its own newly built Engine only after its Engine gate succeeds. The trust boundary includes contributors with write access to this repository; this is not a mechanism for accepting arbitrary contributor binaries.

Expired, absent, failed-run, and superseded-attempt artifacts explicitly select a new build. API failures, changed inputs within a selected artifact, malformed evidence, and checksum mismatches stop verification; they do not authorize reuse or silently switch to another artifact. Deleted or expired artifacts selected earlier in a run fail that run; rerun CI to plan again.

Use **Re-run all jobs** when retrying a failed Engine pipeline. CI and optimized candidates must come from the same run attempt; **Re-run failed jobs** cannot combine an earlier successful candidate with a later attempt. Candidate artifacts and diagnostic reports include their attempt number, so full retries never overwrite evidence.

Identical Engine keys share a concurrency group with cancellation disabled, so a second producer waits and then looks for the first result. PR and manual CI dispatches for the same branch also share a CI group. GitHub concurrency keeps at most one running and one pending member; a newer pending run can replace an older pending run. Review the latest exact-revision CI result. This does not remove GitHub's approval prompt for a bot-created PR.

The first run after introducing this pipeline builds both profiles because older reports do not satisfy the new evidence contract. Runner image updates and the 90-day retention limit can also require rebuilding unchanged source. The artifact reference and build/reuse reason appear in the Actions logs and plan summary.

## Build cache and measurements

The optimized Engine job uses a separate Cargo compilation cache. Its keys separate compiler, Xcode, SDK, release-profile and build-flag changes, then identify the source revision. An older cache within the same compiler contract can supply intermediate compilation outputs; Cargo still validates its fingerprints and builds the selected source with `--locked`. This cache never substitutes for the verified Engine artifact.

The cache contains Cargo downloads and the Rust target directory. It excludes the signing keychain, app bundle, account data, and credential files. The optimized job saves it only after its runtime passes verification, before generated-file cleanup. Signing, protocol comparison, final-app runtime probes, notarization, and uploaded-ZIP verification run for every release, including when the Engine is reused.

Every optimized Engine build enables Cargo `--timings`. Reusing an Engine does not run Cargo or fabricate a new timing report; follow its recorded producer run for the original measurements. The `turnrail-release-build-report-<run-attempt>` Actions artifact retains fresh HTML timing reports, elapsed time, `/usr/bin/time -l` resource measurements, runner hardware and memory/swap snapshots for 14 days. Failure reports cannot reuse HTML from a restored cache. BSD time's maximum resident size is not an aggregate peak for all concurrent compiler processes; inspect the Cargo concurrency graph and paging snapshots alongside it.

To compare compiler concurrency and verify a warm restore on the same source revision:

```sh
gh workflow run release-benchmarks.yml --repo kosukesaigusa/codex-turnrail --ref main
```

This explicitly runs cold builds with two and three workers, plus a two-worker build on a fresh runner that must restore the exact cache saved by the cold two-worker build. Each case builds the Engine and Host with the same optimized release profile and verifies the packaged runtime. Cold means the Rust target directory is absent before compilation. The two-worker cold build also prepares the main release cache. Each case uploads a separate report before cleanup.

Compare the timing reports and resource measurements before changing `CARGO_BUILD_JOBS` or release optimization settings. Runner variability and cache transfer time are part of the result; one comparison does not establish a universal speedup. Cargo build caches do not skip runtime validation.

## Signing setup

Configure the GitHub environment named `release`:

| Setting                      | Kind     | Value                                                                               |
| ---------------------------- | -------- | ----------------------------------------------------------------------------------- |
| `MACOS_CERTIFICATE_BASE64`   | Secret   | Base64-encoded signing certificate and private key exported as an encrypted `.p12`. |
| `MACOS_CERTIFICATE_PASSWORD` | Secret   | Password for that `.p12` export.                                                    |
| `MACOS_SIGNING_IDENTITY`     | Variable | Exact `Developer ID Application: ...` identity, including its team identifier.      |
| `MACOS_NOTARY_KEY_ID`        | Secret   | App Store Connect Team API Key ID for notarization.                                 |
| `MACOS_NOTARY_ISSUER_ID`     | Secret   | Issuer ID for that API key.                                                         |
| `MACOS_NOTARY_KEY_BASE64`    | Secret   | Base64-encoded `.p8` private key for that API key.                                  |

The environment permits `main` and version tags. The workflow fails before compilation if any required setting is absent or notarization authentication fails. It imports the certificate into an ephemeral runner keychain and deletes the keychain afterward. Notarization uses a private temporary `.p8` file that is removed when the operation exits. Never commit signing files or print secret values. Credential registration is a maintainer operation; source publication does not require it.

To prepare these settings:

1. Use an Apple Developer Program team whose Account Holder can issue a Developer ID Application certificate. An Apple Distribution certificate is a different certificate type.
2. Create the certificate in Xcode or Certificates, Identifiers & Profiles, then install it in the keychain that contains its private key.
3. Export the certificate and its private key together as a password-protected `.p12` from Keychain Access. A `.cer` file alone does not contain the private key needed by the runner.
4. Register the encrypted `.p12` as `MACOS_CERTIFICATE_BASE64`, its export password as `MACOS_CERTIFICATE_PASSWORD`, and the exact signing identity as `MACOS_SIGNING_IDENTITY`. Use the `release` environment settings; never paste these values into issues, logs, or source files.

Apple Development signing remains available for local development packages. The GitHub distribution workflow requires Developer ID Application signing. ZIP distribution does not need a Developer ID Installer certificate.

Notarization uses the explicitly configured App Store Connect Team API key. All distributed executables are signed with hardened runtime and a secure timestamp. The Code Mode Host retains its required V8 entitlements.

If Apple's processing is still pending after the 45-minute wait, the workflow stops and retains the submission ID, original upload ZIP, build manifest, and runtime report in the `turnrail-notarization-recovery` Actions artifact for seven days. Completed submissions also include Apple's diagnostic log. Restore these files and extract the original app into one output directory at the same tagged source revision, then run:

```sh
python3 scripts/release.py notarize /absolute/output/directory v0.2.0
python3 scripts/release.py archive /absolute/output/directory v0.2.0
```

The notarization command resumes a matching saved submission without uploading again. It rejects changed app contents and uncertain uploads that have no saved submission ID. An `Invalid` or `Rejected` result must be resolved from Apple's log; it never produces a release archive. The final distribution ZIP is created only after successful ticket attachment and validation.

Source publication does not require a signing certificate or notarization credentials.

## Publish the verified artifact

Before publishing a draft:

- Confirm the Apache-2.0 product license and component notices for the distributed binary.
- Require a successful release workflow with completed uploaded-ZIP verification in the draft notes.
- Download the app ZIP from the Draft Release and extract it for the manual checks below.
- Verify Gatekeeper behavior and launch on a Mac without development tools.
- Verify official UI turns, Shell, JavaScript, approvals, account setup, reauthentication, next-turn account switching, and folder rules.
- Record these results and any limitations in the release notes.
- After publishing, review and merge the automatically created README download-link PR.

Publish the same downloaded and verified artifacts using GitHub's release editor. Do not rebuild or replace them after testing. Users install and update manually from GitHub Releases. An updater, a separate distribution site, and Windows support are outside the current scope.

### Published-release README update

`[📝Docs] Update release download` responds to `release.published`. It checks that the release is the latest published stable release and has the expected uploaded app ZIP, size, and GitHub SHA-256 metadata. It creates a `docs/release-vX.Y.Z` branch changing only the existing README download URL and opens a PR. Older releases cannot downgrade the link; drafts and prereleases cannot become download targets. Existing PRs and human edits are preserved.

The workflow explicitly dispatches `ci.yml` with `scope: auto` for its branch, so validation does not wait for the bot-created PR event to be approved. GitHub can still show an approval banner for the separate `pull_request` run; both runs use the same impact rules. A download-link change needs only static checks; additional code changes automatically receive their corresponding tests. The PR remains for a maintainer to merge.

Use the workflow's manual `tag` input on `main` to process a release whose tag predates this workflow, a release published before it existed, or to retry a failed update. Inspect an orphaned branch after a push succeeded without a PR. Publication performed with the repository's `GITHUB_TOKEN` does not trigger another workflow; if a future publication tool uses that token, it must explicitly dispatch this workflow. Normal publication through GitHub's release editor triggers it automatically for tags containing the workflow.

### Verification records

Users only download the app ZIP; no Terminal commands are required. Release notes retain the Turnrail and supported ChatGPT app versions, source commit, archive SHA-256 and size, and the signature, notarization, runtime, and uploaded-file verification results. GitHub also exposes the app asset's SHA-256.

The `turnrail-release-verification` Actions artifact retains `build-manifest.json`, `runtime-verification.json`, `notarization-report.json`, `SHA256SUMS`, and, after successful delivery verification, `upload-verification.json` for 90 days. These files are not public Release assets. The original checksum list covers the app ZIP and all three build reports. Delivery verification checks those local records before comparing both GitHub's asset metadata and the downloaded bytes against the original app ZIP.

If verification fails, the job retains the available records and leaves the draft unpublished. Inspect the failure before taking any publication action; do not replace verified assets or treat a failed run as ready. The workflow never publishes a release automatically. Detailed Actions artifacts expire, while the verification summary remains in the Release notes.

## Upstream automation

`.github/workflows/upstream.yml` runs every hour, at minute 17, and can also be started manually. GitHub schedules may be delayed; the workflow is not a time guarantee.

The monitor reads the ChatGPT app's configured production appcast and the latest stable `openai/codex` CLI release independently. The appcast and official app archive use curl with explicit time and size limits; redirects, HTTP failures and malformed responses stop inspection. It maintains one tracking issue only for an unsupported ChatGPT app update or a monitoring error, including a failed CLI lookup. The latest standalone CLI release is reference information in the Actions step summary and observation artifact; its version does not open or keep open the issue, prepare an update PR, or change the Engine. CLI-only changes do not rewrite the tracking issue. Once the supported ChatGPT app catches up and monitoring succeeds, the next observation closes the issue regardless of the standalone CLI version. A later ChatGPT update or monitoring failure reopens the same issue.

A newer CLI alone does not update the Engine. For a newer app build, the macOS job downloads the official archive, validates paths, verifies the Apple signature against OpenAI's signing team and bundle identifier, and checks the exact app version and build. Only then does it read the bundled CLI version and require its corresponding public source release. This can be a prerelease when the signed official app bundles that exact version. The source tag, commit, Engine version and bundled CLI must still match exactly; no nearest-version selection is allowed.

The existing three-way merge script prepares the Engine update. App metadata and the generated Swift contract are updated in the same Draft PR. A conflict or missing source release stops preparation and is linked from the tracking issue. A build number identifies each candidate: existing PRs, closed PRs, and branches with human changes are never overwritten. Inspect an orphaned candidate branch manually after an interrupted publication.

The automation explicitly dispatches `ci.yml` for the candidate branch after creating its PR. This allows validation with the repository's `GITHUB_TOKEN`; no additional GitHub App or personal token is required. GitHub may also display an approval request for the automatic `pull_request` run. Both triggers share a branch concurrency group and the verified Engine result, so approving the second run does not require another successful build for identical inputs. Review the candidate's dispatched CI run and exact commit before merging.

Enable **Allow GitHub Actions to create and approve pull requests** in repository Actions settings. Default token permissions remain read-only; write permissions are scoped to jobs that maintain the tracking issue, prepare PRs, create release tags, or dispatch validation/release workflows. No automation merges a PR or publishes a binary release.

After CI passes, review the launch contract and complete Codex UI verification in ChatGPT. A change to the supported ChatGPT app or Codex CLI version needs a Turnrail minor version and build-number increment before release. V8 or zsh changes also require reviewing their pinned component notices under `packaging/licenses/`.

## References

- [Semantic Versioning](https://semver.org/).
- [GitHub token workflow triggering](https://docs.github.com/en/actions/concepts/security/github_token).
- [GitHub signing certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
- [Official ChatGPT app update feed](https://persistent.oaistatic.com/codex-app-prod/appcast.xml).
- [Official Codex source releases](https://github.com/openai/codex/releases).
