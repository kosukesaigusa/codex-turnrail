set working-directory := "."
set positional-arguments

root := justfile_directory()
engine_justfile := root / "engine/justfile"

default:
    @just --list

# Build the macOS app executable.
build-app *args:
    python3 "{{ root }}/scripts/dev.py" swift build -c release "$@"

# Build Engine targets with the shared development storage policy.
build-engine *args:
    just --justfile "{{ engine_justfile }}" build "$@"

check-engine *args:
    just --justfile "{{ engine_justfile }}" check "$@"

lint-engine *args:
    just --justfile "{{ engine_justfile }}" clippy "$@"

fix-engine *args:
    just --justfile "{{ engine_justfile }}" fix "$@"

# Build the complete Engine runtime into an explicit output directory.
build-runtime output:
    python3 "{{ root }}/scripts/build-runtime.py" "$1"

test-app *args:
    python3 "{{ root }}/scripts/dev.py" swift test "$@"

test-engine *args:
    just --justfile "{{ engine_justfile }}" test "$@"

test-tools:
    python3 -m unittest discover -s scripts -p 'test_*.py'
    cd "{{ root }}/engine" && CODEX_REPO_ROOT="{{ root }}/engine" python3 -m unittest discover -s scripts/codex_package -p 'test_*.py'
    cd "{{ root }}/engine" && CODEX_REPO_ROOT="{{ root }}/engine" python3 -m unittest discover -s scripts/install -p 'test_*.py'
    cd "{{ root }}/engine" && CODEX_REPO_ROOT="{{ root }}/engine" python3 -m unittest discover -s .github/scripts/macos-signing -p 'test_notarize_with_akv.py'

lint-docs:
    pnpm dlx markdownlint-cli2@0.23.2 --config .markdownlint-cli2.jsonc

# Verify an assembled runtime using a local mock model.
test-integration runtime report:
    uv run --frozen --project "{{ root }}/engine/scripts/codex_package/smoke_tests" python "{{ root }}/tests/integration/verify_runtime.py" "$1" "$2"

# Build, sign, and verify the complete app, then clean generated build artifacts.
package output identity:
    "{{ root }}/scripts/build-app.sh" "$1" "$2"

sync-upstream tag:
    python3 "{{ root }}/scripts/sync_upstream.py" "$1"

fmt:
    python3 "{{ root }}/scripts/format.py"

fmt-check:
    python3 "{{ root }}/scripts/format.py" --check

storage:
    python3 "{{ root }}/scripts/dev.py" storage

# Preserve dist and diagnostic archives while cleaning Rust and Swift outputs.
finish:
    python3 "{{ root }}/scripts/dev.py" finish
