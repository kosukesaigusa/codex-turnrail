# Codex Turnrail

A macOS menu bar app for using multiple accounts with Codex in the ChatGPT app, with account rules for each folder.

This is an independent project with no affiliation with or endorsement from OpenAI. It launches the official ChatGPT macOS app with a dedicated Codex Engine, preserving the official app's bundle and signature.

## Install

Requires an Apple silicon Mac running macOS 14 or later and the [supported ChatGPT macOS app](upstream.toml) installed at `/Applications/ChatGPT.app`. The ChatGPT app version and build must match exactly.

1. [Download Codex Turnrail for macOS (Apple silicon)](https://github.com/kosukesaigusa/codex-turnrail/releases/download/v0.2.1/Codex-Turnrail-v0.2.1-macos-arm64.zip).
2. Double-click the ZIP, then drag `Codex Turnrail.app` into **Applications**.
3. Quit ChatGPT if it is running, open **Codex Turnrail**, and select **Check Compatibility**.

Only the app ZIP is needed. No Terminal commands are required.

## Set up

1. In **Accounts**, select **Add Account** and sign in to your ChatGPT accounts.
2. In **Folders**, add a folder and assign its permitted accounts.
3. Review quota and set account priority in **Switch**, then select **Open Codex** to launch ChatGPT with Turnrail's account routing.

Folder rules apply to subfolders. The Engine selects an available account from the matching rule before each turn. Active turns keep their account; changes apply to the next turn.

## Conversation data

Account credentials are stored separately in macOS Keychain. Conversation history uses the shared `~/.codex` store.

Switching accounts carries the existing conversation context into the next request under the selected account. Assign only accounts that may receive that folder's code and conversation history. Keep work folders restricted to accounts approved for that work.

Removing an account deletes its Turnrail credentials and account settings. Shared conversation history remains.

## Development

The Swift app lives in `app/` and the Codex Engine in `engine/`. Use the root `justfile` for builds and checks.

See [Development](docs/development.md) to build from source and [Verification](docs/verification.md) for validation results and remaining checks.

See [Architecture](docs/architecture.md) for routing and storage details, [Engine](docs/engine.md) for upstream provenance, [Releases](docs/releases.md) for versioning and upstream automation, and [Roadmap](docs/roadmap.md) for remaining work. Read [Contributing](CONTRIBUTING.md) before proposing changes and [Security](SECURITY.md) to report a vulnerability privately.

## License

Codex Turnrail is licensed under [Apache-2.0](LICENSE). The Engine retains its upstream [license](engine/LICENSE), [NOTICE](engine/NOTICE), and component-specific licenses. Packaged apps include the applicable license texts and notices.
