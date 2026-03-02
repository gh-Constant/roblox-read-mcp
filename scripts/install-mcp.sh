#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_NAME="roblox-read-mcp"
BIN_SOURCE="$ROOT_DIR/target/release/$BIN_NAME"
INSTALL_DIR="${MCP_INSTALL_DIR:-$HOME/.local/bin}"
INSTALL_PATH="$INSTALL_DIR/$BIN_NAME"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo is required. Install Rust from https://rustup.rs/ first." >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

echo "[1/2] Building $BIN_NAME (release)..."
cargo build --release --manifest-path "$ROOT_DIR/Cargo.toml"

echo "[2/2] Installing to $INSTALL_PATH ..."
cp "$BIN_SOURCE" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"

if command -v "$BIN_NAME" >/dev/null 2>&1; then
  FOUND_PATH="$(command -v "$BIN_NAME")"
  echo "Installed. '$BIN_NAME' resolves to: $FOUND_PATH"
else
  echo "Installed, but '$INSTALL_DIR' is not in PATH for this shell."
  echo "Add this to your shell profile (~/.zshrc or ~/.bashrc):"
  echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
fi

cat <<'EOF'

Use this MCP server config (no absolute binary path):
{
  "mcpServers": {
    "roblox-read-mcp": {
      "command": "roblox-read-mcp",
      "args": ["--stdio", "--bind-host", "127.0.0.1", "--ws-port", "3812", "--ws-port-range", "3812-3830"]
    }
  }
}
EOF
