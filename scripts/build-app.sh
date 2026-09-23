#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 3 && "$#" -ne 4 ]]; then
  echo "usage: $0 /output/directory 'Signing Identity' /official/ChatGPT.app [--ci]" >&2
  exit 64
fi
output_directory="$1"
signing_identity="$2"
official_app="$3"
ci_args=()
if [[ "$#" -eq 4 ]]; then
  if [[ "$4" != --ci || ! -v GITHUB_ACTIONS || "$GITHUB_ACTIONS" != true ]]; then
    echo "--ci requires a GitHub Actions runner." >&2
    exit 64
  fi
  ci_args=(--ci)
fi
script_directory="${0:A:h}"
repository_root="${script_directory:h}"
app_directory="$repository_root/app"
app_name="Codex Turnrail.app"
output_app="$output_directory/$app_name"
if [[ "$output_directory" != /* || "$official_app" != /* ]]; then
  echo "Output and official app paths must be absolute." >&2
  exit 64
fi
if [[ -e "$output_app" ]]; then
  echo "Output already exists: $output_app" >&2
  exit 73
fi
python3 - "$output_directory" "$repository_root" <<'PY'
from pathlib import Path
import sys
output, root = (Path(value).resolve() for value in sys.argv[1:])
for generated in (root / "engine/codex-rs/target", root / "app/.build"):
    if output.is_relative_to(generated.resolve()):
        raise SystemExit(f"Output must be outside generated build directories: {generated}")
PY
python3 "$script_directory/project_metadata.py"
python3 "$script_directory/official_app.py" verify "$official_app"
python3 "$script_directory/dev.py" "${ci_args[@]}" swift build -c release --jobs 2

staging_root="$(mktemp -d /tmp/codex-turnrail-app.XXXXXX)"
trap 'rm -rf "$staging_root"' EXIT
staging_app="$staging_root/$app_name"
contents="$staging_app/Contents"
mkdir -p "$contents/MacOS" "$contents/Resources"
for binary in CodexTurnrailApp CodexTurnrailRouter; do
  /usr/bin/ditto "$app_directory/.build/release/$binary" "$contents/MacOS/$binary"
  /usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" "$contents/MacOS/$binary"
done
/usr/bin/ditto "$repository_root/packaging/Info.plist" "$contents/Info.plist"
/usr/bin/ditto "$repository_root/packaging/resources/AppIcon.icns" "$contents/Resources/AppIcon.icns"
python3 "$script_directory/build_notices.py" "$contents/Resources/Licenses"
/usr/bin/codesign --force --options runtime --timestamp --sign "$signing_identity" "$staging_app"
/usr/bin/codesign --verify --deep --strict "$staging_app"
mkdir -p "$output_directory"
/usr/bin/ditto "$staging_app" "$output_app"
/usr/bin/codesign --verify --deep --strict "$output_app"
python3 "$script_directory/verify_official_runtime.py" "$official_app" \
  "$output_app/Contents/MacOS/CodexTurnrailRouter" "$output_directory/runtime-verification.json" "${ci_args[@]}"
python3 "$script_directory/release.py" record "$output_directory"
if [[ ${#ci_args} -eq 0 ]]; then
  just --justfile "$repository_root/justfile" finish
fi
echo "$output_app"
