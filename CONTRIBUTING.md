# Contributing

Open an issue describing the behavior before proposing a large change. Keep product documentation and code comments in English.

Read [Development](docs/development.md), use the root `justfile`, and follow `AGENTS.md`. Changes to the reference source tree must also follow `engine/AGENTS.md`. Preserve upstream provenance, component licenses, and the exact official app and Engine version contract.

Run the checks relevant to your change and include their results in the pull request. Tooling changes need `just test-tools`; app changes need `just test-app`. Routing changes also need the official Engine fixture described in the development guide. Run formatting checks for the affected source trees, `just lint-docs`, and `just metadata-check` before requesting review.

Use fixture accounts in tests. Do not submit credentials, `auth.json`, routing registries, signing keys, personal screenshots, or diagnostic archives containing account data. Report security vulnerabilities through the private process in [Security](SECURITY.md).

Changes to account handling require evidence that active turns retain their account and that shared conversation history behaves as documented. Mock runtime tests and real-account UI verification are separate checks.
