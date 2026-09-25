# Codex Turnrail

A macOS menu bar app for using multiple ChatGPT accounts with Codex in the official ChatGPT app.

Keep your Codex conversations as you switch accounts, with automatic account selection for each folder.

![Codex Turnrail's Folders screen showing account priority, remaining usage, reset times, and last-used times using demo data](docs/images/folders.png)

This is an independent project with no affiliation with or endorsement from OpenAI.

## Install

Requires an Apple silicon Mac running macOS 14 or later and the official ChatGPT macOS app installed at `/Applications/ChatGPT.app`. Use the latest versions of ChatGPT and Turnrail available to you. Each Turnrail release lists its reference ChatGPT version; other versions can also be used, without a guarantee that every feature will work.

The indicator at the bottom of Settings is green when your ChatGPT version matches the release reference and yellow when it differs. Click it for version details and **See releases**. A version difference does not prevent launch.

1. [Download Codex Turnrail for macOS (Apple silicon)](https://github.com/kosukesaigusa/codex-turnrail/releases/download/v0.12.0/Codex-Turnrail-v0.12.0-macos-arm64.zip).
2. Double-click the ZIP, then drag `Codex Turnrail.app` into **Applications**.
3. Quit ChatGPT if it is running, open **Codex Turnrail**, and click the version indicator near the bottom of the sidebar for details.

Only the app ZIP is needed. No Terminal commands are required.

> **Usage notice:** Do not use Codex Turnrail to circumvent OpenAI's rate limits or usage limits. You are responsible for complying with the terms that apply to your accounts and your organization's policies. Use at your own risk.
>
> OpenAI prohibits "circumvent any rate limits or restrictions" in its [Terms of Use](https://openai.com/policies/row-terms-of-use/) and "violate or circumvent Usage Limits" in its business [Services Agreement, Section 3.3(i)](https://openai.com/policies/services-agreement/) (excerpts).

## Set up

1. In **Accounts**, select **Add Account** and sign in to your ChatGPT accounts.
2. In **Folders**, add a folder and assign its permitted accounts.
3. Review quota in **Folders**. Use an account's **…** menu to **Move Up**, **Move Down**, or **Prioritize** it. Numbers show the order in which accounts are selected. Then select **Open Codex** to launch ChatGPT with Turnrail's account routing.

Folder rules apply to subfolders. Turnrail selects an available account from the matching rule before each turn. Active turns keep their account; changes apply to the next turn.

**Folders** and **Accounts** show remaining usage, reset times, and last-used times. Select **available resets** to view each saved reset and its expiration date. Reset counts appear only when at least one is available. Reauthentication and account removal are in the **Accounts** menu.

## Conversation data

Account credentials are stored separately in macOS Keychain. Conversation history uses the shared `~/.codex` store. Turnrail also keeps private routing and model-request history under its Application Support directory so conversations can continue across account changes and connection interruptions.

Switching accounts carries the existing conversation context into the next request under the selected account. Assign only accounts that may receive that folder's code and conversation history. Keep work folders restricted to accounts approved for that work.

ChatGPT stays signed in to its original account. Turnrail routes model requests; connected Apps, their uploads, and other account services still use ChatGPT's sign-in. Files referenced by a server-side file ID may be inaccessible to the routed account. Only combine accounts allowed to handle the same data.

Removing an account deletes its Turnrail credentials and account settings. Shared conversation and routing history remain.

## Development

The Swift app and local account router live in `app/`. Turnrail runs the signed Engine and Code Mode Host already included in the installed ChatGPT app, without modifying or redistributing those executables. The source tree in `engine/` is retained for protocol reference and provenance. Use the root `justfile` for builds and checks.

See [Development](docs/development.md) to build from source and [Verification](docs/verification.md) for validation results and remaining checks.

See [Architecture](docs/architecture.md) for routing and storage details, [Engine](docs/engine.md) for upstream provenance, [Releases](docs/releases.md) for versioning and upstream automation, and [Roadmap](docs/roadmap.md) for remaining work. Read [Contributing](CONTRIBUTING.md) before proposing changes and [Security](SECURITY.md) to report a vulnerability privately.

## License

Codex Turnrail is licensed under [Apache-2.0](LICENSE). The reference source tree retains its upstream [license](engine/LICENSE), [NOTICE](engine/NOTICE), and component-specific licenses. Packaged apps include Turnrail's license and notices; the official ChatGPT app is installed separately.
