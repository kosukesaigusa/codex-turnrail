#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 /output/directory 'Apple Development: Name (TEAMID)'" >&2
  exit 64
fi

output_directory="$1"
signing_identity="$2"
script_directory="${0:A:h}"
repository_root="${script_directory:h}"
engine_repository="$repository_root/engine"
app_directory="$repository_root/app"

if [[ "$output_directory" != /* ]]; then
  echo "output directory must be absolute: $output_directory" >&2
  exit 64
fi

if [[ ! -f "$engine_repository/codex-rs/Cargo.toml" || ! -f "$script_directory/dev.py" ]]; then
  echo "Turnrail Engine development workspace is missing: $engine_repository" >&2
  exit 66
fi

if [[ ! -f "$repository_root/tests/integration/verify_runtime.py" ]]; then
  echo "Turnrail runtime verifier is missing: $repository_root/tests/integration/verify_runtime.py" >&2
  exit 66
fi

app_name="Codex Turnrail.app"
output_app="$output_directory/$app_name"

if [[ -e "$output_app" ]]; then
  echo "output already exists: $output_app" >&2
  exit 73
fi

# The final app must survive the cleanup at the end of this workflow.
python3 - "$output_directory" "$engine_repository" "$app_directory" <<'PY'
from pathlib import Path
import sys

output, engine, app = (Path(value).resolve() for value in sys.argv[1:])
for generated in (engine / "codex-rs/target", app / ".build"):
    if output.is_relative_to(generated.resolve()):
        raise SystemExit(f"Output must be outside generated build directories: {generated}")
PY

app_icon="$repository_root/packaging/resources/AppIcon.icns"

if [[ ! -f "$app_icon" ]]; then
  echo "App icon is missing: $app_icon" >&2
  exit 66
fi

official_cli="/Applications/ChatGPT.app/Contents/Resources/codex"
code_mode_host_entitlements="$repository_root/packaging/entitlements/codex-code-mode-host.entitlements"

if [[ ! -x "$official_cli" ]]; then
  echo "Official Codex CLI is not executable: $official_cli" >&2
  exit 66
fi

if [[ ! -f "$code_mode_host_entitlements" ]]; then
  echo "Code Mode host entitlements are missing: $code_mode_host_entitlements" >&2
  exit 66
fi

staging_root="$(mktemp -d /tmp/codex-turnrail-app.XXXXXX)"
trap 'rm -rf "$staging_root"' EXIT

staging_app="$staging_root/$app_name"
contents="$staging_app/Contents"

mkdir -p "$contents/MacOS" "$contents/Resources"
runtime_package="$contents/Resources/engine"
python3 "$script_directory/build-runtime.py" "$runtime_package"

"$script_directory/verify-protocol-compatibility.sh" "$official_cli" "$runtime_package/bin/codex"

just --justfile "$repository_root/justfile" build-app

/usr/bin/ditto \
  "$app_directory/.build/release/CodexTurnrailApp" \
  "$contents/MacOS/CodexTurnrailApp"
/usr/bin/ditto "$repository_root/packaging/Info.plist" "$contents/Info.plist"
/usr/bin/ditto "$app_icon" "$contents/Resources/AppIcon.icns"

for runtime_binary in bin/codex codex-path/rg codex-resources/zsh/bin/zsh; do
  /usr/bin/codesign \
    --force \
    --options runtime \
    --sign "$signing_identity" \
    "$runtime_package/$runtime_binary"
done
/usr/bin/codesign \
  --force \
  --options runtime \
  --entitlements "$code_mode_host_entitlements" \
  --sign "$signing_identity" \
  "$runtime_package/bin/codex-code-mode-host"
for runtime_binary in bin/codex bin/codex-code-mode-host codex-path/rg codex-resources/zsh/bin/zsh; do
  /usr/bin/codesign --verify --strict "$runtime_package/$runtime_binary"
done
/usr/bin/codesign \
  --force \
  --options runtime \
  --sign "$signing_identity" \
  "$staging_app"
/usr/bin/codesign --verify --deep --strict "$staging_app"
mkdir -p "$output_directory"
/usr/bin/ditto "$staging_app" "$output_app"
/usr/bin/codesign --verify --deep --strict "$output_app"

UV_PROJECT_ENVIRONMENT="$staging_root/python-venv" uv sync \
  --project "$engine_repository/scripts/codex_package/smoke_tests" --frozen
"$staging_root/python-venv/bin/python" "$repository_root/tests/integration/verify_runtime.py" \
  "$output_app/Contents/Resources/engine" "$output_directory/runtime-verification.json"

just --justfile "$repository_root/justfile" finish

echo "$output_app"
