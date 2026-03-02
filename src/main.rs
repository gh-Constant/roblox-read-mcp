mod config;
mod errors;
mod mcp;
mod protocol;
mod session;
mod ws_bridge;

use config::AppConfig;
use errors::Result;
use mcp::McpServer;
use tracing::info;
use tracing_subscriber::{fmt, EnvFilter};
use ws_bridge::WsBridge;

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("[roblox-read-mcp] fatal error: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<()> {
    init_tracing();

    let config = AppConfig::load()?;
    info!(
        "starting roblox-read-mcp (ws={} tool_timeout_ms={})",
        config.ws_bind_hint(),
        config.default_tool_timeout.as_millis()
    );

    let bridge = WsBridge::bind(config.clone()).await?;
    let server = McpServer::new(config, bridge);
    server.run().await
}

fn init_tracing() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = fmt()
        .with_env_filter(filter)
        .with_target(false)
        .with_writer(std::io::stderr)
        .try_init();
}
