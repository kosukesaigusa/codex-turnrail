# Roadmap

Codex Turnrail is a macOS-only product distributed through signed and notarized GitHub Release drafts. The settings app and router have one product version. The official ChatGPT app is installed separately and supplies its unmodified Engine and Code Mode Host.

## Official Engine integration

| Work                     | Completion criteria                                                                                                                 |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- |
| Swift runtime            | Routing, account isolation, title registration, history recovery, cancellation, and process ownership pass local tests.             |
| Official runtime fixture | The pinned, signed Engine and Host pass Code Mode, switching, titles, and both approval decisions through the native router.        |
| Account operations       | Real sign-in, credential refresh, matching-email reauthentication, removal, and quota-based selection behave as documented.         |
| Desktop UI               | The packaged router supports ordinary turns, the in-app browser, automatic titles, and history-preserving account switching.        |
| Distribution             | Hosted CI, Developer ID signing, notarization, uploaded-ZIP verification, and a clean installation pass for the candidate revision. |

[Verification](verification.md) distinguishes completed checks, historical custom-Engine evidence, and remaining product validation. The Python feasibility prototype alone does not verify the Swift product integration.

## Maintenance and distribution

- Keep exact official app/CLI metadata and signatures verified. Review hooks, metadata, model capabilities, and account-service behavior when the official app changes.
- Preserve the source repository's Apache-2.0 license and upstream reference-source notices. The distributed app contains only Turnrail's Swift executables and resources.
- Keep monitoring, candidate preparation, CI, merge, draft creation, and published-download updates automated. Publication follows real-device verification of the same app ZIP.
- Retain explicit failure behavior for unbound requests, incompatible model catalogs, uncertain inference, and malformed private history.
- Review private router-history retention as usage grows. Account removal does not remove shared conversation history.

Users install updates manually. An automatic updater, a distribution website, and Windows support remain outside the current scope. The launch environment and request metadata are checked per supported release rather than assumed to remain stable indefinitely.
