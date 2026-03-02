#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BRIDGE_FILE="$ROOT_DIR/plugin/src/BridgeClient.luau"
ENGINE_FILE="$ROOT_DIR/plugin/src/SearchEngine.luau"

required_commands=(search tree selected inspect ping)

for cmd in "${required_commands[@]}"; do
  if ! rg -n "${cmd}\s*=\s*true" "$BRIDGE_FILE" >/dev/null; then
    echo "missing command whitelist entry in BridgeClient: $cmd" >&2
    exit 1
  fi

  if ! rg -n "command == \"${cmd}\"" "$ENGINE_FILE" >/dev/null; then
    echo "missing command handler in SearchEngine: $cmd" >&2
    exit 1
  fi

done

for forbidden in set destroy create rename; do
  if rg -n "command == \"${forbidden}" "$ENGINE_FILE" "$BRIDGE_FILE" >/dev/null; then
    echo "forbidden mutating command found in plugin code: $forbidden" >&2
    exit 1
  fi

done

for field in protocolVersion requestId timestampMs payload; do
  if ! rg -n "${field}" "$BRIDGE_FILE" >/dev/null; then
    echo "missing envelope field in BridgeClient: $field" >&2
    exit 1
  fi

done

echo "Luau contract checks passed"
