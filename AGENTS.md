# Product development

- Use the root `justfile` for app and Engine work. `app/` is the Swift package; `engine/` contains the Codex source tree. Keep authored documentation and code comments in English.
- Follow `engine/AGENTS.md` for Engine changes. Put product documentation in the root `docs/` directory.
- Use `just build-app`, `just test-app`, `just build-engine`, `just check-engine`, `just test-engine`, `just lint-engine`, and `just fix-engine`. Heavy local commands share a lock and require at least 30 GiB of free space. Engine commands select `dev-small` and disable incremental compilation.
- `just package /absolute/output/directory 'Apple Development: Name (TEAMID)'` builds, signs, and verifies the complete app, then cleans generated build artifacts. Both source paths are derived from this repository.
- At task completion, including failed tasks, save logs and required app outputs outside generated directories, wait for development processes to end, then run `just finish`. This cleanup is authorized by the user; do not request approval again.
- Cleanup removes only `engine/codex-rs/target` and generated Swift build artifacts in `app/.build`. Preserve source, account data, diagnostic archives, and packaged apps. Never clean while a development command is active.
- Keep `engine/` and `upstream.toml` in sync. `just sync-upstream rust-vX.Y.Z` requires a clean committed worktree and prepares uncommitted changes for review; it does not publish or move branch refs.
