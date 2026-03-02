# Roblox Read MCP (Rust + Studio Plugin)

Secure, read-only bridge between Roblox Studio and an MCP client.

## Architecture

```text
MCP Client (Codex/Claude)
        |
      stdio
        |
Rust MCP server (tools + cursor signing + auth)
        |
  localhost websocket (127.0.0.1:3812)
        |
Roblox Studio plugin (read-only DataModel inspector)
```

## What it supports

- `search_instances`
- `get_instance_tree`
- `get_selected`
- `inspect_instance`

All responses are structured JSON, bounded, and paginated.

## Security model

- WebSocket listener binds to `127.0.0.1` by default.
- One active Studio plugin session at a time.
- Challenge-response authentication using `HMAC-SHA256`.
- Short-lived session token required on command responses.
- Strict read-only command whitelist (`search`, `tree`, `selected`, `inspect`, `ping`).
- Cursor tokens are signed and expiry-bound (tamper resistant).
- Hard caps for depth, nodes, payload size, and timeout.
- No server logs to stdout (stdio-safe for MCP).

## Plugin UI

The plugin includes:

- live connection/auth badge
- pairing panel (host/port, fixed built-in secret)
- universal runtime defaults (AI controls query options per request)
- telemetry cards (request count, latency, result count, index size)

## Build

### 1) Build plugin artifact

```bash
cd /Users/constantsuchet/Documents/Travail/Roblox/EscapeObbyForBrainrots/repo/tools/roblox-read-mcp
./scripts/build-plugin.sh
```

Output:

- `/Users/constantsuchet/Documents/Travail/Roblox/EscapeObbyForBrainrots/repo/tools/roblox-read-mcp/dist/roblox-read-mcp-plugin.rbxmx`

Import this model into Roblox Studio and save as a Local Plugin.

### 2) Start MCP server

```bash
cd /Users/constantsuchet/Documents/Travail/Roblox/EscapeObbyForBrainrots/repo/tools/roblox-read-mcp
cargo run --release
```

Optional flags:

- `--bind-host 127.0.0.1`
- `--ws-port 3812`
- `--default-tool-timeout-ms 6000`
- `--max-ws-message-bytes 131072`

### 3) Pair plugin with server

- open plugin UI in Studio
- set host/port to match server
- click `Save + Reconnect`
- wait for `READY` badge

## Tool contracts

### `search_instances`

Arguments:

- `query: string`
- `cursor: string | null`
- `options`: profile + filters + limits

Returns:

- `results: []`
- `nextCursor: string | null`
- `meta`

### `get_instance_tree`

Arguments:

- `path: string | null`
- `cursor: string | null`
- `options`

Returns paginated flattened subtree rows with `depth` and `childCount`.

### `get_selected`

Arguments:

- `cursor: string | null`
- `options`

Returns current Studio selection.

### `inspect_instance`

Arguments:

- `path: string` (required)
- `options`

Returns detailed snapshot of one instance and child preview.

## Testing

```bash
cd /Users/constantsuchet/Documents/Travail/Roblox/EscapeObbyForBrainrots/repo/tools/roblox-read-mcp
cargo test
./scripts/check-luau-contracts.sh
./scripts/build-plugin.sh
```

If your environment cannot access `crates.io`, `cargo` commands will fail until registry access is available.

## Operational limits

Defaults and hard caps are enforced in Rust and plugin logic:

- depth: max `12`
- page nodes: max `500`
- include props: max `32`
- timeout: max `15000ms`
- websocket payload: max `128KB`

## Troubleshooting

- `READY` never appears:
  - verify Studio `Allow HTTP Requests` is enabled.
  - verify host/port match server.
- Frequent disconnects:
  - check port conflicts on `3812`.
  - lower query size and maxNodes.
- `invalid cursor` errors:
  - cursor expired or was reused with different query/options.
