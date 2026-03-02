use thiserror::Error;

pub type Result<T> = std::result::Result<T, BridgeError>;

#[derive(Debug, Error)]
pub enum BridgeError {
    #[error("configuration error: {0}")]
    Config(String),

    #[error("protocol error: {0}")]
    Protocol(String),

    #[error("authentication failed: {0}")]
    Auth(String),

    #[error("cursor is invalid: {0}")]
    InvalidCursor(String),

    #[error("bad request: {0}")]
    BadRequest(String),

    #[error("tool timeout after {0} ms")]
    Timeout(u64),

    #[error("plugin bridge unavailable")]
    Unavailable,

    #[error("internal error: {0}")]
    Internal(String),
}

impl From<serde_json::Error> for BridgeError {
    fn from(error: serde_json::Error) -> Self {
        Self::Protocol(error.to_string())
    }
}

impl From<std::io::Error> for BridgeError {
    fn from(error: std::io::Error) -> Self {
        Self::Internal(error.to_string())
    }
}

impl From<tokio::time::error::Elapsed> for BridgeError {
    fn from(_: tokio::time::error::Elapsed) -> Self {
        Self::Timeout(0)
    }
}
