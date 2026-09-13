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

A `v*` tag push starts `.github/workflows/release.yml`. The workflow verifies the tag, source ancestry, metadata, and CI before using the protected `release` environment. It then:

1. Downloads the matching official CLI release and verifies its source commit, archive SHA-256, size, and executable version.
2. Builds the Engine and Code Mode Host with the optimized upstream `release` profile, and builds the Swift app in release mode.
3. Compares stable and experimental app-server schemas, includes component notices, signs every executable and the app, and verifies the signatures.
4. Runs all three runtime scenarios against the finished app.
5. Creates a ZIP, SHA-256 manifest, source and build metadata, and runtime verification report.
6. Uploads all artifacts to a Draft Release with notes generated from merged PRs.

The build manifest records the product and upstream versions, source commit, build profile, compiler versions, signer, and binary hashes. Archive creation rejects uncommitted source, another source revision, changed binaries, failed or incomplete runtime reports, and version mismatches.

An existing tag whose workflow failed before creating a release can be retried with the workflow's manual `tag` input. Do not move the tag. If a Draft Release already exists, inspect it and retain its assets; the workflow does not overwrite it.

## Signing setup

Configure the GitHub environment named `release`:

| Setting                      | Kind     | Value                                                                               |
| ---------------------------- | -------- | ----------------------------------------------------------------------------------- |
| `MACOS_CERTIFICATE_BASE64`   | Secret   | Base64-encoded signing certificate and private key exported as an encrypted `.p12`. |
| `MACOS_CERTIFICATE_PASSWORD` | Secret   | Password for that `.p12` export.                                                    |
| `MACOS_SIGNING_IDENTITY`     | Variable | Exact `Developer ID Application: ...` identity, including its team identifier.      |

The workflow fails before compilation if any required setting is absent. It imports the certificate into an ephemeral runner keychain and deletes the keychain afterward. Never commit signing files or print secret values. Certificate export and secret registration are maintainer operations; source publication does not require them.

To prepare these settings:

1. Use an Apple Developer Program team whose Account Holder can issue a Developer ID Application certificate. An Apple Distribution certificate is a different certificate type.
2. Create the certificate in Xcode or Certificates, Identifiers & Profiles, then install it in the keychain that contains its private key.
3. Export the certificate and its private key together as a password-protected `.p12` from Keychain Access. A `.cer` file alone does not contain the private key needed by the runner.
4. Register the encrypted `.p12` as `MACOS_CERTIFICATE_BASE64`, its export password as `MACOS_CERTIFICATE_PASSWORD`, and the exact signing identity as `MACOS_SIGNING_IDENTITY`. Use the `release` environment settings; never paste these values into issues, logs, or source files.

Apple Development signing remains available for local development packages. The GitHub distribution workflow requires Developer ID Application signing. ZIP distribution does not need a Developer ID Installer certificate.

The current workflow does not notarize apps and states that fact in the release notes and build manifest. Before general binary publication, add notarization with `notarytool`, staple the ticket to the signed app, and create the final ZIP from that app. Notarization also needs Apple authentication: an Apple Account, an app-specific password, and the matching Team ID, or an appropriate App Store Connect API key. These credentials are separate from the signing certificate and are not consumed by the current workflow.

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
