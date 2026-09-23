# Product development

- Use the root `justfile` for product work. `app/` contains the Swift settings app and account router; `engine/` contains reference Codex sources. Keep authored documentation and code comments in English.
- Follow `engine/AGENTS.md` for Engine changes. Put product documentation in the root `docs/` directory.
- Use `just build-app`, `just test-app`, `just build-engine`, `just check-engine`, `just test-engine`, `just lint-engine`, and `just fix-engine`. Heavy local commands share a lock and require at least 30 GiB of free space. Engine commands select `dev-small` and disable incremental compilation.
- `just package /absolute/output/directory 'Signing Identity' /Applications/ChatGPT.app` builds and signs the Swift executables, verifies routing with the pinned official Engine, and cleans generated build artifacts. Output must be outside generated build directories.
- Product CI and packaging do not compile or bundle the reference Engine. Official Engine and Code Mode Host executables remain inside the separately installed, OpenAI-signed ChatGPT app. Verify their signatures and pinned identities before execution. Reference Engine development commands retain `dev-small`.
- Run `just metadata-check` after changing product versions or upstream metadata. Generate the Swift compatibility contract with `just metadata-write`; do not edit the generated file by hand.
- At task completion, including failed tasks, save logs and required app outputs outside generated directories, wait for development processes to end, then run `just finish`. This cleanup is authorized by the user; do not request approval again.
- Cleanup removes only `engine/codex-rs/target` and generated Swift build artifacts in `app/.build`. Preserve source, account data, diagnostic archives, and packaged apps. Never clean while a development command is active.
- Keep `engine/` and the `[codex]` reference pin in `upstream.toml` in sync; `[app]` independently pins the official runtime. App update PRs must not update reference sources. `just sync-upstream rust-vX.Y.Z` requires a clean committed worktree and prepares uncommitted changes for review; it does not publish or move branch refs.
