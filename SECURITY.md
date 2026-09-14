# Security

Report vulnerabilities involving account credentials, unintended account selection, or access to conversation data through [GitHub private vulnerability reporting](https://github.com/kosukesaigusa/codex-turnrail/security/advisories/new).

Include the Turnrail version, ChatGPT app version and build, Codex CLI version, reproduction steps, and expected behavior. Use redacted examples and fixture accounts. Never attach access tokens, refresh tokens, Keychain exports, `auth.json`, or an unredacted routing registry to an issue or report.

The project is in initial development. Only the exact app and Engine combination recorded in `upstream.toml` is supported. Shared conversation context can be sent under the account selected for the next turn; folder rules must allow only accounts authorized to receive that content.
