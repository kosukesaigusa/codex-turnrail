# Releases and upstream maintenance

## Versioning

Turnrail uses one product version for the app and its bundled Engine. `packaging/Info.plist` is the canonical product version and monotonically increasing build number. The initial product release is planned as `v0.1.0`.

During `0.x` development, a patch release fixes bugs within the same supported Codex combination. A minor release adds features or changes the supported Codex version. `1.0.0` will mark an explicitly stable product contract. Released tags and assets are never moved or replaced.

`upstream.toml` records the official app bundle identifier, version, and build together with the Engine source repository, release tag, and commit. The required CLI version is derived from the source release tag. Generate the Swift compatibility contract with `just metadata-write`; `just metadata-check` rejects drift between this contract and the Engine version.

Prepare a version change as ordinary reviewed source:

```sh
just version 0.1.1
just metadata-check
```

The version command increments the build number and rejects malformed, equal, or lower versions. It does not commit, push, or tag.

## Draft release workflow

After merging a verified revision into `main`, run:

```sh
just release-tag --dry-run
just release-tag
```

Tagging requires a clean `main` worktree that matches the remote and a successful latest `main` CI run for that exact commit. The tag must match the product version. Existing tags are rejected.

The command pushes the immutable tag and dispatches `.github/workflows/release.yml` from `main`, with that tag as its explicit input. The workflow rejects other branch refs, then verifies the tag, source ancestry, metadata, and CI before checking out the tagged commit and using the protected `release` environment. It then:

1. Downloads the matching official CLI release and verifies its source commit, archive SHA-256, size, and executable version.
2. Builds the Engine and Code Mode Host with the optimized upstream `release` profile, and builds the Swift app in release mode.
3. Compares stable and experimental app-server schemas, includes component notices, signs every executable and the app, and verifies the signatures.
4. Runs all three runtime scenarios against the finished app.
5. Submits a signed ZIP to Apple's notary service, requires `Accepted`, attaches the ticket to the app, and verifies the ticket and Gatekeeper assessment.
6. Creates the final ZIP from the stapled app, with SHA-256 checksums, source and build metadata, runtime evidence, and a notarization report.
7. Uploads all artifacts to a Draft Release with notes generated from merged PRs.

The build manifest records the product and upstream versions, source commit, build profile, compiler versions, signer, binary hashes, and notarization report hash. Archive creation rejects uncommitted source, another source revision, changed binaries or app resources, failed or incomplete reports, unnotarized apps, and version mismatches. It verifies the attached ticket and Gatekeeper assessment again before creating the ZIP.

An existing tag whose workflow failed before creating a release can be retried with the workflow's manual `tag` input, selecting `main` as the workflow ref. If tagging succeeded but dispatch failed, start the same workflow manually; keep the tag. If a Draft Release already exists, inspect it and retain its assets; the workflow does not overwrite it.

## Build cache and measurements

Release runs execute from `main` so that successive tags can share its GitHub Actions cache. The checkout remains pinned to the validated release commit. Cache keys separate compiler, Xcode, SDK, release-profile and build-flag changes, then identify the exact source revision. An older cache within the same compiler contract can supply dependencies; Cargo still validates its fingerprints and builds the selected source with `--locked`. A cache miss performs the ordinary build.

The cache contains Cargo downloads and the Rust target directory. It excludes the signing keychain, app bundle, account data and credential files. The workflow saves it only after the app passes build, signature and runtime verification, and before generated-file cleanup. Signing, protocol comparison, runtime probes and notarization run for every release.

Every distribution build enables Cargo `--timings`. The `turnrail-release-build-report` Actions artifact retains fresh HTML timing reports, elapsed time, `/usr/bin/time -l` resource measurements, runner hardware and memory/swap snapshots for 14 days. Failure reports cannot reuse HTML from a restored cache. BSD time's maximum resident size is not an aggregate peak for all concurrent compiler processes; inspect the Cargo concurrency graph and paging snapshots alongside it.

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
python3 scripts/release.py notarize /absolute/output/directory v0.1.0
python3 scripts/release.py archive /absolute/output/directory v0.1.0
```

The notarization command resumes a matching saved submission without uploading again. It rejects changed app contents and uncertain uploads that have no saved submission ID. An `Invalid` or `Rejected` result must be resolved from Apple's log; it never produces a release archive. The final distribution ZIP is created only after successful ticket attachment and validation.

Source publication does not require a signing certificate or notarization credentials.

## Publish the verified artifact

Before publishing a draft:

- Confirm the Apache-2.0 product license and component notices for the distributed binary.
- Download the Draft Release assets, check `SHA256SUMS`, and extract the ZIP.
- Verify Gatekeeper behavior and launch on a Mac without development tools.
- Verify official UI turns, Shell, JavaScript, approvals, account setup, reauthentication, next-turn account switching, and folder rules.
- Record these results and any limitations in the release notes.

Publish the same downloaded and verified artifacts using GitHub's release editor. Do not rebuild or replace them after testing. Users install and update manually from GitHub Releases. An updater, a separate distribution site, and Windows support are outside the current scope.

## Upstream automation

`.github/workflows/upstream.yml` runs every six hours, at minute 17, and can also be started manually. GitHub schedules may be delayed; the workflow is not a time guarantee.

The monitor reads the official app's configured production appcast and the latest stable `openai/codex` GitHub Release independently. It maintains one tracking issue when an update or monitoring error exists. An unchanged observation does not rewrite the issue. Recovery closes the issue when no update remains. HTTP failures and malformed responses are reported as failures rather than as an absence of updates.

A newer CLI alone does not update the Engine. For a newer app build, the macOS job downloads the official archive, validates paths, verifies the Apple signature against OpenAI's signing team and bundle identifier, and checks the exact app version and build. Only then does it read the bundled CLI version and require its corresponding public stable source release.

The existing three-way merge script prepares the Engine update. App metadata and the generated Swift contract are updated in the same Draft PR. A conflict or missing source release stops preparation and is linked from the tracking issue. A build number identifies each candidate: existing PRs, closed PRs, and branches with human changes are never overwritten. Inspect an orphaned candidate branch manually after an interrupted publication.

The automation explicitly dispatches `ci.yml` for the candidate branch after creating its PR. This allows validation with the repository's `GITHUB_TOKEN`; no additional GitHub App or personal token is required. GitHub may also display an approval request for the automatic `pull_request` run. Review the candidate's dispatched CI run and exact commit before merging.

Enable **Allow GitHub Actions to create and approve pull requests** in repository Actions settings. Default token permissions remain read-only; write permissions are scoped to the jobs that maintain the tracking issue or prepare an update PR. No automation merges an upstream PR or publishes a binary release.

After CI passes, review the launch contract and complete official UI verification. A supported Codex change needs a Turnrail minor version and build-number increment before release. V8 or zsh changes also require reviewing their pinned component notices under `packaging/licenses/`.

## References

- [Semantic Versioning](https://semver.org/).
- [GitHub token workflow triggering](https://docs.github.com/en/actions/concepts/security/github_token).
- [GitHub signing certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).
- [Official Codex app update feed](https://persistent.oaistatic.com/codex-app-prod/appcast.xml).
- [Official Codex source releases](https://github.com/openai/codex/releases).
