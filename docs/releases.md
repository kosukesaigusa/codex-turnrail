# Releases and upstream maintenance

## Versioning

Turnrail uses one product version for the Swift app and router. `packaging/Info.plist` is the canonical product version and monotonically increasing build number.

The Settings sidebar displays this product version. `just metadata-write` generates `TurnrailVersion.generated.swift` from the plist, and `just metadata-check` rejects a stale display version. `just version` updates both the plist and the generated display version.

During `0.x` development, a patch release fixes bugs with the same ChatGPT app and Codex CLI release reference. A minor release adds features or changes that reference. `1.0.0` will mark an explicitly stable product contract. Released tags and assets are never moved or replaced.

`upstream.toml` records the reference ChatGPT app bundle identifier, version, build, and bundled CLI version in `[app]`. Release notes publish that reference automatically; they do not require users to install that exact version. Installed version differences are informational in Settings and do not block launch. CI and packaging still use the exact reference runtime to identify their test inputs. `[codex]` separately pins the retained reference source repository, tag, and commit. App compatibility does not depend on that source revision. Generate the Swift compatibility contract with `just metadata-write`; `just metadata-check` validates both records and rejects generated-contract drift.

Prepare a version change as ordinary reviewed source:

```sh
just version 0.2.1
just metadata-check
```

The version command increments the build number and rejects malformed, equal, or lower versions. It does not commit, push, or tag.

## Draft release workflow

Merge a PR that increases the product version. When that exact revision's main CI succeeds (a push or an explicit dispatch), `[🚀CD] Prepare release after CI` automatically creates its immutable version tag and starts `[🚀CD] Draft release` from `main`. The release stays a draft until a maintainer completes the manual checks and publishes it.

The preparation workflow runs trusted main code and verifies the originating workflow, repository, branch, commit ancestry, and latest exact-revision CI result. It compares the product version with the commit's first parent. Documentation changes and other commits without a version increase do not create a release. A newer version already on main supersedes an older candidate; a repeated completion event cannot recreate or move an existing tag.

For a version merged before automation was enabled, or an explicitly initiated release, the manual command remains available:

```sh
just release-tag --dry-run
just release-tag
```

Tagging requires a clean `main` worktree that matches the remote and a successful latest `main` CI run for that exact commit. The tag must match the product version. Existing tags are rejected.

Both entry points dispatch `.github/workflows/release.yml` from `main`, with an existing tag as its explicit input. The workflow rejects other branch refs, then verifies the tag, source ancestry, metadata, and CI before checking out the tagged commit and using the protected `release` environment. It then:

1. Downloads the pinned official ChatGPT app and verifies archive paths, OpenAI signatures, the exact app version/build, and its bundled CLI version.
2. Builds the Swift app and router from the tagged source. It does not build or bundle a Rust Engine.
3. Includes product notices, signs both Swift executables and the app, and verifies their signatures.
4. Runs the router-core fixture with the finished hook helper and official Engine, requiring Code Mode, account switching, titles, compaction, accepted and declined approvals, no replay after uncertain delivery, new-turn recovery, idle-connection recovery, native HTTP web search, a response after 181 seconds of silence, cancellation while waiting, the Engine's own idle timeout, and Engine-owned connection-limit recovery to pass.
5. Submits a signed ZIP to Apple's notary service, requires `Accepted`, attaches the ticket to the app, and verifies the ticket and Gatekeeper assessment.
6. Creates the final app ZIP from the stapled app and records its original checksum alongside the build, runtime, and notarization reports.
7. Uploads only the app ZIP to a Draft Release with a direct download link and notes generated from merged PRs.
8. Downloads that uploaded asset by its GitHub asset ID and checks its SHA-256 and size against the original archive. The GitHub digest must also match. A mismatch fails the job and leaves the release as a draft with pending verification.
9. Records successful download verification in the draft notes and retains the detailed verification files as an Actions artifact for 90 days. Publishing remains a separate maintainer action.

The build manifest records the product and upstream versions, tagged app source commit, Swift compiler, signer, app/router hashes, and notarization report hash. Its official Engine record contains the reference app identity, OpenAI signing team, resolved layout, and hashes of the separately installed actual CLI executable and Host used during verification. Packaged runtimes also record the launcher and package manifest hashes; a launcher-script hash cannot substitute for the executable hash. Upstream monitoring, CI, and packaging use the same runtime resolver and signature checks. Archive creation rejects uncommitted source, another source revision, changed binaries or resources, failed or incomplete reports, unnotarized apps, and version mismatches. It verifies the attached ticket and Gatekeeper assessment again before creating the ZIP.

An existing tag whose workflow failed before creating a release can be retried with the workflow's manual `tag` input, selecting `main` as the workflow ref. If tagging succeeded but dispatch failed, start the same workflow manually; keep the tag. If a Draft Release already exists, inspect it and retain its assets; the workflow does not overwrite it.

## CI impact and official runtime verification

CI selects checks by affected inputs, not by a special README rule. It compares the PR base with its tested merge commit, or the previous main commit with the pushed commit. All changes receive formatting, Markdown, workflow, spelling, and file-size checks. Additional checks are combined:

| Changed inputs                                                                                   | Additional validation                                                 |
| ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| Product documentation, screenshots, and root Markdown                                            | Static checks only                                                    |
| Monitoring, release automation, release notes, and CI selection                                  | Python tooling tests                                                  |
| Swift source/tests, app resources, versions, compatibility metadata, or official-runtime helpers | Swift build/tests, official Engine routing fixture, and tooling tests |
| Reference Engine source or its build/evidence helpers                                            | Source policies, dependency checks, and tooling tests                 |
| Shared development build helper                                                                  | App, tooling, and reference-source policy checks                      |

`scripts/ci_changes.py` defines impact. Renames include old and new paths; deletions preserve their impact. Unknown paths or missing comparison data stop classification with an explicit error. Manual dispatch uses the same rules, with `scope: full` available explicitly. Bot branches and authors receive no exemption.

No automatic product CI or release job compiles the reference Rust Engine. The signed official app supplies the runtime used by the isolated fixture. CI downloads the exact pinned installation, verifies its identity before execution, and drives it through the native Swift router using synthetic credentials and a mock model. Packaging repeats this verification with the signed distribution helper. Real-account and desktop UI results remain separate evidence.

The required CI gate rejects failures and skips not authorized by the computed plan. Runtime reports are uploaded for inspection. PR and manual CI dispatches share a branch concurrency group with cancellation disabled; review the latest result for the exact candidate revision.

The reusable Engine workflows and manually dispatched `release-benchmarks.yml` remain reference-source tools. Their Cargo caches and runtime artifacts are not inputs to the Turnrail release package.

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

Notarization uses the explicitly configured App Store Connect Team API key. All distributed executables are signed with hardened runtime and a secure timestamp. The separately installed official Code Mode Host retains OpenAI's signature and entitlements; Turnrail does not re-sign it.

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
- Verify official UI turns, the in-app browser, automatic titles, Shell, JavaScript, approvals, account setup, reauthentication, next-turn account switching, and folder rules.
- Record these results and any limitations in the release notes.
- After publishing, the README download-link PR is created, checked, and merged automatically. Inspect a failed automation run if it stops.

Publish the same downloaded and verified artifacts using GitHub's release editor. Do not rebuild or replace them after testing. Users install and update manually from GitHub Releases. An updater, a separate distribution site, and Windows support are outside the current scope.

### Published-release README update

`[📝Docs] Update release download` responds to `release.published`. It checks that the release is the latest published stable release and has the expected uploaded app ZIP, size, and GitHub SHA-256 metadata. It creates a `docs/release-vX.Y.Z` branch changing only the existing README download URL and opens a PR. Older releases cannot downgrade the link; drafts and prereleases cannot become download targets. Existing PRs and human edits are preserved.

The workflow explicitly dispatches `ci.yml` with `scope: auto` for its branch, so validation does not wait for the bot-created PR event to be approved. GitHub can still show an approval banner for the separate `pull_request` run; both runs use the same impact rules. A download-link change needs only static checks; additional code changes automatically receive their corresponding tests. After its dispatched CI succeeds, `[🔧Util] Merge verified automation PRs` validates the exact published download URL change and merges the bot PR automatically. A draft PR or a commit authored by a human pauses automatic merging.

Use the workflow's manual `tag` input on `main` to process a release whose tag predates this workflow, a release published before it existed, or to retry a failed update. Inspect an orphaned branch after a push succeeded without a PR. Publication performed with the repository's `GITHUB_TOKEN` does not trigger another workflow; if a future publication tool uses that token, it must explicitly dispatch this workflow. Normal publication through GitHub's release editor triggers it automatically for tags containing the workflow.

### Verification records

Users only download the app ZIP; no Terminal commands are required. Release notes retain the Turnrail and reference ChatGPT app versions, source commit, archive SHA-256 and size, and the signature, notarization, runtime, and uploaded-file verification results. GitHub also exposes the app asset's SHA-256.

The `turnrail-release-verification` Actions artifact retains `build-manifest.json`, `runtime-verification.json`, `notarization-report.json`, `SHA256SUMS`, and, after successful delivery verification, `upload-verification.json` for 90 days. These files are not public Release assets. The original checksum list covers the app ZIP and all three build reports. Delivery verification checks those local records before comparing both GitHub's asset metadata and the downloaded bytes against the original app ZIP.

If verification fails, the job retains the available records and leaves the draft unpublished. Inspect the failure before taking any publication action; do not replace verified assets or treat a failed run as ready. The workflow never publishes a release automatically. Detailed Actions artifacts expire, while the verification summary remains in the Release notes.

## Upstream automation

`.github/workflows/upstream.yml` runs every hour, at minute 17, and can also be started manually. GitHub schedules may be delayed; the workflow is not a time guarantee.

The monitor reads the ChatGPT app's configured production appcast and the latest stable `openai/codex` CLI release independently. The appcast and official app archive use curl with explicit time and size limits; redirects, HTTP failures and malformed responses stop inspection. It maintains one tracking issue only for a pending ChatGPT release-reference update or a monitoring error, including a failed CLI lookup. The latest standalone CLI release is reference information in the Actions step summary and observation artifact; its version does not open or keep open the issue, prepare an update PR, or change the Engine. CLI-only changes do not rewrite the tracking issue. Once the ChatGPT release reference catches up and monitoring succeeds, the next observation closes the issue regardless of the standalone CLI version. A later ChatGPT update or monitoring failure reopens the same issue.

A newer standalone CLI alone does not change app compatibility. For a newer app build, the macOS job downloads the official archive, validates its paths and size, verifies the app and both runtime executables against OpenAI's signing team, and checks the exact app version and build. Only then does it read the bundled CLI version. A public CLI source release is not required; the signed app supplies the runtime being tested.

The candidate changes exactly four files: app metadata in `upstream.toml`, the generated Swift compatibility contract, `packaging/Info.plist`, and the generated Turnrail version. It leaves reference sources and their pin unchanged. Versioning follows the `0.x` policy (for example, `0.7.3 (34)` becomes `0.8.0 (35)`); a future stable-version policy must be chosen explicitly. Signature, identity, or runtime verification failures stop automation and require investigation. A build number identifies each candidate: existing PRs, closed PRs, and branches with human changes are never overwritten. Inspect an orphaned candidate branch manually after an interrupted publication.

The automation explicitly dispatches `ci.yml` for the candidate branch after creating its PR. This allows validation with the repository's `GITHUB_TOKEN`; no additional GitHub App or personal token is required. GitHub may also display an approval request for the automatic `pull_request` run. Both triggers share a branch concurrency group and use the same affected-input checks; neither compiles the reference Engine. The automation consumes the successful dispatched CI run for automatic merging; clicking the separate approval banner is unnecessary. The banner is a GitHub requirement for `GITHUB_TOKEN`-created PR event runs, not a gate on the dispatched workflow. Removing the banner itself requires creating PRs with a separate GitHub App token or PAT; this pipeline needs neither.

Enable **Allow GitHub Actions to create and approve pull requests** in repository Actions settings. Default token permissions remain read-only; write permissions are scoped to jobs that maintain the tracking issue, prepare PRs, create release tags, or dispatch validation/release workflows. Automation merges only its verified upstream and README PRs. Binary publication remains manual after real-device verification.

After CI passes, the merge workflow runs trusted main code, validates the bot author, same-repository branch, exact head SHA, latest CI attempt, complete commit/file lists, and the generated version/compatibility changes. It never executes candidate code with its write token. Upstream PRs may change only the four app/version metadata files; the reference source pin must remain unchanged. Merge commits preserve the candidate history. README PRs may change only the verified published download URL. Human-authored commits, draft PRs, unexpected files, conflicts, version collisions, or failed checks stop automatic merging. If main advanced without invalidating the candidate, the workflow updates the branch and requires fresh CI before merging.

Because a `GITHUB_TOKEN` merge does not trigger push CI, the merge workflow explicitly dispatches main CI. A successful main run then creates the immutable tag and Draft Release. The maintainer installs that draft and verifies the launch contract, Codex UI turns, approvals, and account switching before publishing the same verified ZIP. Routine monitoring, versioning, CI startup, merging, packaging, and README updates require no manual approval. Review changes to the official runtime against routing metadata, hooks, model capabilities, and the account-service boundary described in the architecture guide.

## References

- [Semantic Versioning](https://semver.org/).
- [GitHub token workflow triggering](https://docs.github.com/en/actions/concepts/security/github_token).
- [GitHub signing certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
- [Official ChatGPT app update feed](https://persistent.oaistatic.com/codex-app-prod/appcast.xml).
- [Official Codex source releases](https://github.com/openai/codex/releases).
