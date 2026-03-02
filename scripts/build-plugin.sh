#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$ROOT_DIR/plugin/default.project.json"
OUT_DIR="$ROOT_DIR/dist"
OUT_FILE="$OUT_DIR/roblox-read-mcp-plugin.rbxmx"

mkdir -p "$OUT_DIR"

if ! command -v rojo >/dev/null 2>&1; then
  echo "rojo is required to build the plugin" >&2
  exit 1
fi

rojo build "$PROJECT_FILE" -o "$OUT_FILE"

echo "Built plugin artifact: $OUT_FILE"

echo "Import this .rbxmx into Roblox Studio and save it as a Local Plugin."
