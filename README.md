# Codex Turnrail

A macOS menu bar app for using multiple ChatGPT accounts in Codex, with account rules for each folder.

This is an independent project with no affiliation with or endorsement from OpenAI. It launches the official Codex app with a dedicated Engine, preserving the official app's bundle and signature.

## Getting started

The project is in initial development, for Apple silicon Macs running macOS 14 or later. It requires the exact official app and Engine versions recorded in [upstream.toml](upstream.toml), with the official app installed at `/Applications/ChatGPT.app`. Other versions are rejected.

See [Development](docs/development.md) to build a signed app. Verified archives will appear in [GitHub Releases](https://github.com/kosukesaigusa/codex-turnrail/releases), with manual installation and updates. No verified public binary release is available yet. Official UI end-to-end validation remains pending; see [Verification](docs/verification.md).

1. Connect your ChatGPT accounts in **Accounts**.
2. Assign permitted accounts to each folder in **Folders**.
3. Review quota and set account priority in **Switch**, then select **Open Codex**.

Folder rules apply to subfolders. The Engine selects an available account from the matching rule before each turn. Active turns keep their account; changes apply to the next turn.

## Conversation data

Account credentials are stored separately in macOS Keychain. Conversation history uses the shared `~/.codex` store.

Switching accounts carries the existing conversation context into the next request under the selected account. Assign only accounts that may receive that folder's code and conversation history. Keep work folders restricted to accounts approved for that work.

Removing an account deletes its Turnrail credentials and account settings. Shared conversation history remains.

## Development

The Swift app lives in `app/` and the Codex Engine in `engine/`. Use the root `justfile` for builds and checks.

See [Architecture](docs/architecture.md) for routing and storage details, [Engine](docs/engine.md) for upstream provenance, [Releases](docs/releases.md) for versioning and upstream automation, and [Roadmap](docs/roadmap.md) for remaining work. Read [Contributing](CONTRIBUTING.md) before proposing changes and [Security](SECURITY.md) to report a vulnerability privately.

## License

Codex Turnrail is licensed under [Apache-2.0](LICENSE). The Engine retains its upstream [license](engine/LICENSE), [NOTICE](engine/NOTICE), and component-specific licenses. Packaged apps include the applicable license texts and notices.
