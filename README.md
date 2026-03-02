# Roblox Read MCP (Rust + Studio Plugin)

Secure, read-only bridge between Roblox Studio and any MCP client (Codex, Claude Code, AntiGravity, etc.).

## Architecture

```text
MCP Client
   |
 stdio
   |
roblox-read-mcp (Rust)
   |
ws://127.0.0.1:3812
   |
Roblox Studio Local Plugin
```

## Quick install (recommended)

From this folder:

```bash
cd /Users/constantsuchet/Documents/Travail/Roblox/EscapeObbyForBrainrots/repo/tools/roblox-read-mcp
./scripts/install-mcp.sh
```

What this does:

- builds release binary
- installs `roblox-read-mcp` to `~/.local/bin` (or `MCP_INSTALL_DIR` if set)
- prints a ready-to-paste MCP config using `"command": "roblox-read-mcp"`

If `~/.local/bin` is not in your PATH, add this to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

## Universal MCP config (no absolute path)

Use this server block in your MCP client config:

```json
{
  "mcpServers": {
    "roblox-read-mcp": {
      "command": "roblox-read-mcp",
      "args": ["--stdio", "--bind-host", "127.0.0.1", "--ws-port", "3812", "--ws-port-range", "3812-3830"]
    }
  }
}
```

This works for any MCP client that supports stdio transport.

## Client notes

- Codex: add the block to your MCP servers config.
- Claude Code: add the same block to its MCP servers config.
- AntiGravity: `Manage MCP Servers` -> raw config -> paste the same block.

## Build and install plugin

```bash
cd /Users/constantsuchet/Documents/Travail/Roblox/EscapeObbyForBrainrots/repo/tools/roblox-read-mcp
./scripts/build-plugin.sh
```

Then in Roblox Studio:

1. Import `dist/roblox-read-mcp-plugin.rbxmx`
2. Save it as a Local Plugin
3. Open plugin UI and set:
   - Host: `127.0.0.1`
   - Port: `3812`
   - Port Range Scan: `3812-3830`
4. Click `Save + Reconnect`
5. Wait for `READY`

## Tools exposed

- `search_instances`
- `get_instance_tree`
- `get_selected`
- `inspect_instance`

## Troubleshooting

- `Address already in use (os error 48)`:
  - another process is already using `--ws-port`
  - use `--ws-port-range` so the bridge auto-selects the first available port
  - set the same scan range in the plugin UI (`Port Range Scan`) so it can auto-find the selected port

- `calling initialize: invalid character 'C'`:
  - fixed in current codebase
  - update/reinstall the binary and restart your MCP client

- Plugin never reaches `READY`:
  - ensure Studio has `Allow HTTP Requests`
  - confirm host/port match server args

## Optional: run as always-on daemon (macOS)

If you want a login-start daemon, use a LaunchAgent. Avoid running both daemon and MCP-client-managed process on the same port at the same time.

## Testing

```bash
cd /Users/constantsuchet/Documents/Travail/Roblox/EscapeObbyForBrainrots/repo/tools/roblox-read-mcp
cargo test
./scripts/check-luau-contracts.sh
./scripts/build-plugin.sh
```
