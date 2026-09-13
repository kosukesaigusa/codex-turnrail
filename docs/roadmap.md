# Roadmap

Codex Turnrail is a macOS-only product. The app is at `0.9.0 (25)` with Engine `0.153.4`. Current evidence and its limits are recorded in [Verification](verification.md).

Initial releases will use GitHub Releases. Users download the app archive and install updates manually. Windows support, an automatic updater, and a dedicated distribution site are outside the current scope.

## Remaining validation

| Work                | Completion criteria                                                                                                                                                                                                    |
| ------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Hosted CI           | Root product workflows complete successfully on GitHub. The required check rejects failed, skipped, and cancelled dependencies. The previously observed account restriction must be resolved before runners can start. |
| Full Rust workspace | Classify and resolve the remaining failures, unify required environment conditions, and complete a successful full run. Retain the failed-run record separately from successful isolated reruns.                       |
| Installed package   | Exit the official app and Engine, install the verified app, and confirm normal launch from the installation path. Preserve account data and conversation history.                                                      |
| Official UI         | Launch through Turnrail and verify an ordinary turn, JavaScript, Shell, and approval acceptance and rejection with the packaged runtime.                                                                               |
| Account operations  | Verify history-preserving switching on the next turn, unchanged authentication during active turns, directory rules, login, reauthentication, rejection of a mismatched email, and removal.                            |

The zsh declined-status and parent-authentication reload fixes already pass their targeted tests. Remaining workspace failures and official UI validation have separate completion criteria.

## Source publication

- Select the license for the app and product tooling; retain the Engine's Apache-2.0 license, NOTICE, and component licenses.
- Review the source, assets, and Git history intended for publication.
- Publish a reviewed revision with its upstream provenance and exact supported official app version.

## GitHub Releases

- Define an explicit distribution build profile and verify its finished output. Current packages use the development `dev-small` profile.
- Include required component license notices in the app.
- Publish the arm64 app archive, checksum, source revision, upstream revision, build conditions, and runtime verification report together.
- Document the package's signing status and installation steps, and verify download, extraction, Gatekeeper behavior, first launch, account setup, and official Codex integration on a Mac without development tools.

The official Codex app is installed separately. Compatibility must be revalidated per supported version; the external Engine launch variables are not assumed to remain available indefinitely.

Developer ID signing, notarization, and stapling can be added for broader app distribution later. They are not required to publish the initial source repository or to establish the manual GitHub Releases workflow.

## Ongoing maintenance

Keep upstream updates coordinated with the official CLI version, protocol schema, toolchain, V8 pair, and package behavior. Review automated dependency updates against that constraint rather than independently moving the Engine away from its selected base.

After the first verified release and download test, automate only the repeatable GitHub release steps. Official UI turns and real-account operations remain outside the current PR checks.
