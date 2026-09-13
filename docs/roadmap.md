# Roadmap

Codex Turnrail is a macOS-only product preparing its initial `v0.1.0` release. Product and upstream versions are recorded in `packaging/Info.plist` and `upstream.toml`. Current evidence and its limits are recorded in [Verification](verification.md).

Initial releases will use GitHub Releases. Users download the app archive and install updates manually. Windows support, an automatic updater, and a dedicated distribution site are outside the current scope.

## Remaining validation

| Work                | Completion criteria                                                                                                                                                                              |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Hosted CI           | Root product workflows complete successfully for the candidate revision. The required check rejects failed, skipped, and cancelled dependencies.                                                 |
| Full Rust workspace | Classify and resolve the remaining failures, unify required environment conditions, and complete a successful full run. Retain the failed-run record separately from successful isolated reruns. |
| Installed package   | Exit the official app and Engine, install the verified app, and confirm normal launch from the installation path. Preserve account data and conversation history.                                |
| Official UI         | Launch through Turnrail and verify an ordinary turn, JavaScript, Shell, and approval acceptance and rejection with the packaged runtime.                                                         |
| Account operations  | Verify history-preserving switching on the next turn, unchanged authentication during active turns, directory rules, login, reauthentication, rejection of a mismatched email, and removal.      |

The zsh declined-status and parent-authentication reload fixes already pass their targeted tests. Remaining workspace failures and official UI validation have separate completion criteria.

## Source publication

- Publish the app and product tooling under Apache-2.0; retain the Engine's license, NOTICE, modification notices, and component licenses.
- Keep source, assets, Git history, upstream provenance, and exact supported versions reviewed before publication.

## GitHub Releases

- Configure the signing certificate in the GitHub `release` environment and validate the first hosted Draft Release build.
- Review bundled component notices for the binary being distributed, including native dependency subcomponents.
- Complete the manual release checklist, then publish the verified arm64 app archive and its checksum, source and build manifest, and runtime verification report.
- Document the package's signing status and installation steps, and verify download, extraction, Gatekeeper behavior, first launch, account setup, and official Codex integration on a Mac without development tools.

The official Codex app is installed separately. Compatibility must be revalidated per supported version; the external Engine launch variables are not assumed to remain available indefinitely.

The Draft Release workflow requires Developer ID Application signing. Notarization and stapling remain work for general binary distribution. Signing credentials are not required to publish the source repository.

## Ongoing maintenance

Keep upstream updates coordinated with the official CLI version, protocol schema, toolchain, V8 pair, and package behavior. Review automated dependency updates against that constraint rather than independently moving the Engine away from its selected base.

Tag-driven Draft Releases and six-hour upstream monitoring are defined in [Releases](releases.md). Official UI turns and real-account operations remain outside the current PR checks.
