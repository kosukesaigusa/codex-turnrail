#!/bin/zsh

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "usage: $0 /path/to/official/codex /path/to/turnrail/codex" >&2
  exit 64
fi

official_cli="$1"
turnrail_engine="$2"

if [[ ! -x "$official_cli" ]]; then
  echo "official Codex CLI is not executable: $official_cli" >&2
  exit 66
fi

if [[ ! -x "$turnrail_engine" ]]; then
  echo "Turnrail Engine is not executable: $turnrail_engine" >&2
  exit 66
fi

probe_root="$(mktemp -d /tmp/codex-turnrail-protocol.XXXXXX)"
trap 'rm -rf "$probe_root"' EXIT

for api_mode in stable experimental; do
  official_schema="$probe_root/$api_mode/official"
  turnrail_schema="$probe_root/$api_mode/turnrail"
  schema_options=()
  if [[ "$api_mode" == experimental ]]; then
    schema_options=(--experimental)
  fi

  "$official_cli" app-server generate-json-schema --out "$official_schema" "${schema_options[@]}"
  "$turnrail_engine" app-server generate-json-schema --out "$turnrail_schema" "${schema_options[@]}"

  if ! diff -qr "$official_schema" "$turnrail_schema"; then
    echo "app-server $api_mode protocol schema mismatch" >&2
    exit 65
  fi
done

echo "app-server stable and experimental protocol schemas match"
