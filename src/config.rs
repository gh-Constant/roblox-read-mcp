use std::time::Duration;

use clap::{ArgAction, Parser};

use crate::errors::{BridgeError, Result};

pub const PROTOCOL_VERSION: u8 = 1;
pub const HARD_MAX_DEPTH: u32 = 12;
pub const HARD_MAX_NODES: u32 = 500;
pub const HARD_MAX_TIMEOUT_MS: u64 = 15_000;
pub const HARD_MAX_INCLUDE_PROPS: usize = 32;
pub const HARD_MAX_INCLUDE_LIST_ITEMS: usize = 32;
pub const HARDCODED_SHARED_SECRET: &str = "roblox-read-mcp-global-shared-secret-v1";

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub bind_host: String,
    pub ws_port: u16,
    pub shared_secret: String,
    pub token_ttl: Duration,
    pub cursor_ttl: Duration,
    pub heartbeat_interval: Duration,
    pub default_tool_timeout: Duration,
    pub max_ws_message_bytes: usize,
    pub max_messages_per_second: u32,
    pub max_inflight_requests: usize,
}

#[derive(Debug, Parser)]
#[command(
    name = "roblox-read-mcp",
    version,
    about = "Secure read-only Roblox bridge for MCP clients"
)]
struct Cli {
    #[arg(long, action = ArgAction::SetTrue, hide = true)]
    stdio: bool,

    #[arg(long, default_value = "stdio", hide = true)]
    transport: String,

    #[arg(long, default_value = "127.0.0.1")]
    bind_host: String,

    #[arg(long, default_value_t = 3812)]
    ws_port: u16,

    #[arg(long, default_value_t = 5 * 60 * 1_000)]
    token_ttl_ms: u64,

    #[arg(long, default_value_t = 15 * 60 * 1_000)]
    cursor_ttl_ms: u64,

    #[arg(long, default_value_t = 20_000)]
    heartbeat_interval_ms: u64,

    #[arg(long, default_value_t = 6_000)]
    default_tool_timeout_ms: u64,

    #[arg(long, default_value_t = 128 * 1024)]
    max_ws_message_bytes: usize,

    #[arg(long, default_value_t = 120)]
    max_messages_per_second: u32,

    #[arg(long, default_value_t = 16)]
    max_inflight_requests: usize,
}

impl AppConfig {
    pub fn load() -> Result<Self> {
        let cli = Cli::parse();
        let secret = HARDCODED_SHARED_SECRET.to_string();

        if secret.len() < 16 {
            return Err(BridgeError::Config(
                "shared secret must be at least 16 characters".to_string(),
            ));
        }

        if cli.ws_port == 0 {
            return Err(BridgeError::Config(
                "ws port must be greater than zero".to_string(),
            ));
        }

        if cli.max_ws_message_bytes < 2048 {
            return Err(BridgeError::Config(
                "max ws message bytes must be at least 2048".to_string(),
            ));
        }

        Ok(Self {
            bind_host: cli.bind_host,
            ws_port: cli.ws_port,
            shared_secret: secret,
            token_ttl: Duration::from_millis(cli.token_ttl_ms.max(5_000)),
            cursor_ttl: Duration::from_millis(cli.cursor_ttl_ms.max(60_000)),
            heartbeat_interval: Duration::from_millis(
                cli.heartbeat_interval_ms.clamp(3_000, 60_000),
            ),
            default_tool_timeout: Duration::from_millis(
                cli.default_tool_timeout_ms
                    .clamp(1_000, HARD_MAX_TIMEOUT_MS),
            ),
            max_ws_message_bytes: cli.max_ws_message_bytes,
            max_messages_per_second: cli.max_messages_per_second.clamp(10, 500),
            max_inflight_requests: cli.max_inflight_requests.clamp(1, 64),
        })
    }

    pub fn ws_bind_addr(&self) -> String {
        format!("{}:{}", self.bind_host, self.ws_port)
    }
}

#[cfg(test)]
mod tests {
    use super::Cli;
    use clap::Parser;

    #[test]
    fn cli_accepts_stdio_flag() {
        let parsed = Cli::try_parse_from(["roblox-read-mcp", "--stdio"]);
        assert!(parsed.is_ok());
    }

    #[test]
    fn cli_accepts_transport_flag() {
        let parsed = Cli::try_parse_from(["roblox-read-mcp", "--transport", "stdio"]);
        assert!(parsed.is_ok());
    }
}
