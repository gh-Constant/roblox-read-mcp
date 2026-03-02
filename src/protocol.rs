use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use crate::{
    config::{
        AppConfig, HARD_MAX_DEPTH, HARD_MAX_INCLUDE_LIST_ITEMS, HARD_MAX_INCLUDE_PROPS,
        HARD_MAX_NODES, HARD_MAX_TIMEOUT_MS, PROTOCOL_VERSION,
    },
    errors::{BridgeError, Result},
    session::now_ms,
};

pub const ALLOWED_BRIDGE_COMMANDS: &[&str] = &["search", "tree", "selected", "inspect", "ping"];
pub const TOOL_SEARCH_INSTANCES: &str = "search_instances";
pub const TOOL_GET_INSTANCE_TREE: &str = "get_instance_tree";
pub const TOOL_GET_SELECTED: &str = "get_selected";
pub const TOOL_INSPECT_INSTANCE: &str = "inspect_instance";

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BridgeEnvelope {
    pub protocol_version: u8,
    #[serde(rename = "type")]
    pub message_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub timestamp_ms: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_token: Option<String>,
    #[serde(default)]
    pub payload: Value,
}

impl BridgeEnvelope {
    pub fn new(
        message_type: impl Into<String>,
        request_id: Option<String>,
        payload: Value,
    ) -> Self {
        Self {
            protocol_version: PROTOCOL_VERSION,
            message_type: message_type.into(),
            request_id,
            timestamp_ms: now_ms(),
            session_token: None,
            payload,
        }
    }

    pub fn with_token(mut self, token: impl Into<String>) -> Self {
        self.session_token = Some(token.into());
        self
    }

    pub fn parse_json(raw: &str, max_payload_bytes: usize) -> Result<Self> {
        if raw.len() > max_payload_bytes {
            return Err(BridgeError::Protocol(
                "incoming websocket payload too large".to_string(),
            ));
        }

        let envelope: Self = serde_json::from_str(raw).map_err(|error| {
            BridgeError::Protocol(format!("failed to decode envelope: {error}"))
        })?;

        if envelope.protocol_version != PROTOCOL_VERSION {
            return Err(BridgeError::Protocol(format!(
                "protocol version mismatch (expected {PROTOCOL_VERSION}, got {})",
                envelope.protocol_version
            )));
        }

        if envelope.message_type.trim().is_empty() {
            return Err(BridgeError::Protocol(
                "message type cannot be empty".to_string(),
            ));
        }

        Ok(envelope)
    }

    pub fn to_text(&self) -> Result<String> {
        serde_json::to_string(self).map_err(|error| {
            BridgeError::Internal(format!("failed to serialize envelope: {error}"))
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorPayload {
    pub code: String,
    pub message: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

impl ErrorPayload {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            details: None,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloChallengePayload {
    pub nonce: String,
    pub server_time_ms: u64,
    pub token_ttl_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthResponsePayload {
    pub client_id: String,
    pub client_timestamp_ms: u64,
    pub signature: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthOkPayload {
    pub session_token: String,
    pub expires_at_ms: u64,
    pub heartbeat_interval_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandResultPayload {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorPayload>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub telemetry: Option<Value>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueryOptions {
    #[serde(default)]
    pub profile: Option<String>,
    #[serde(default)]
    pub roots: Vec<String>,
    #[serde(default)]
    pub include_attributes: Option<bool>,
    #[serde(default)]
    pub include_tags: Option<bool>,
    #[serde(default)]
    pub include_props: Vec<String>,
    #[serde(default)]
    pub exclude_classes: Vec<String>,
    #[serde(default)]
    pub max_depth: Option<u32>,
    #[serde(default)]
    pub max_nodes: Option<u32>,
    #[serde(default)]
    pub timeout_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NormalizedOptions {
    pub profile: String,
    pub roots: Vec<String>,
    pub include_attributes: bool,
    pub include_tags: bool,
    pub include_props: Vec<String>,
    pub exclude_classes: Vec<String>,
    pub max_depth: u32,
    pub max_nodes: u32,
    pub timeout_ms: u64,
}

impl QueryOptions {
    pub fn normalize(&self, config: &AppConfig) -> NormalizedOptions {
        let profile = self.profile.clone().map_or_else(
            || "minimal".to_string(),
            |value| value.trim().to_lowercase(),
        );

        let roots = normalize_strings(
            if self.roots.is_empty() {
                vec![
                    "StarterGui".to_string(),
                    "Players".to_string(),
                    "ReplicatedStorage".to_string(),
                    "Workspace".to_string(),
                ]
            } else {
                self.roots.clone()
            },
            HARD_MAX_INCLUDE_LIST_ITEMS,
        );

        let include_props = normalize_strings(self.include_props.clone(), HARD_MAX_INCLUDE_PROPS);
        let exclude_classes =
            normalize_strings(self.exclude_classes.clone(), HARD_MAX_INCLUDE_LIST_ITEMS);

        let max_depth = self.max_depth.unwrap_or(5).clamp(1, HARD_MAX_DEPTH);
        let max_nodes = self.max_nodes.unwrap_or(100).clamp(1, HARD_MAX_NODES);
        let timeout_ms = self
            .timeout_ms
            .unwrap_or(config.default_tool_timeout.as_millis() as u64)
            .clamp(500, HARD_MAX_TIMEOUT_MS);

        NormalizedOptions {
            profile,
            roots,
            include_attributes: self.include_attributes.unwrap_or(true),
            include_tags: self.include_tags.unwrap_or(true),
            include_props,
            exclude_classes,
            max_depth,
            max_nodes,
            timeout_ms,
        }
    }
}

fn normalize_strings(items: Vec<String>, max_items: usize) -> Vec<String> {
    let mut unique = Vec::<String>::new();

    for raw in items {
        let value = raw.trim();
        if value.is_empty() {
            continue;
        }

        if unique
            .iter()
            .any(|existing| existing.eq_ignore_ascii_case(value))
        {
            continue;
        }

        unique.push(value.to_string());
        if unique.len() >= max_items {
            break;
        }
    }

    unique
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchInstancesArgs {
    #[serde(default)]
    pub query: String,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub options: QueryOptions,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GetInstanceTreeArgs {
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub options: QueryOptions,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GetSelectedArgs {
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub options: QueryOptions,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InspectInstanceArgs {
    pub path: String,
    #[serde(default)]
    pub options: QueryOptions,
}

pub fn ensure_allowed_command(command: &str) -> Result<()> {
    if ALLOWED_BRIDGE_COMMANDS
        .iter()
        .any(|allowed| *allowed == command)
    {
        return Ok(());
    }

    Err(BridgeError::BadRequest(format!(
        "command `{command}` is not allowed on read-only bridge"
    )))
}

pub fn mcp_tool_list() -> Value {
    json!({
        "tools": [
            {
                "name": TOOL_SEARCH_INSTANCES,
                "description": "Searches Roblox instances by name/class/text/tag/attribute with pagination",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "cursor": { "type": ["string", "null"] },
                        "options": common_options_schema()
                    }
                }
            },
            {
                "name": TOOL_GET_INSTANCE_TREE,
                "description": "Returns a bounded hierarchy view for a path",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "path": { "type": ["string", "null"] },
                        "cursor": { "type": ["string", "null"] },
                        "options": common_options_schema()
                    }
                }
            },
            {
                "name": TOOL_GET_SELECTED,
                "description": "Returns selected instances from Roblox Studio",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "cursor": { "type": ["string", "null"] },
                        "options": common_options_schema()
                    }
                }
            },
            {
                "name": TOOL_INSPECT_INSTANCE,
                "description": "Returns detailed inspection data for one instance path",
                "inputSchema": {
                    "type": "object",
                    "required": ["path"],
                    "properties": {
                        "path": { "type": "string" },
                        "options": common_options_schema()
                    }
                }
            }
        ]
    })
}

fn common_options_schema() -> Value {
    json!({
        "type": "object",
        "properties": {
            "profile": { "type": "string", "enum": ["ui", "gameplay", "minimal"] },
            "roots": { "type": "array", "items": { "type": "string" } },
            "includeAttributes": { "type": "boolean" },
            "includeTags": { "type": "boolean" },
            "includeProps": { "type": "array", "items": { "type": "string" } },
            "excludeClasses": { "type": "array", "items": { "type": "string" } },
            "maxDepth": { "type": "integer", "minimum": 1, "maximum": HARD_MAX_DEPTH },
            "maxNodes": { "type": "integer", "minimum": 1, "maximum": HARD_MAX_NODES },
            "timeoutMs": { "type": "integer", "minimum": 500, "maximum": HARD_MAX_TIMEOUT_MS }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_whitelist_blocks_mutation_commands() {
        assert!(ensure_allowed_command("search").is_ok());
        assert!(ensure_allowed_command("tree").is_ok());
        assert!(ensure_allowed_command("selected").is_ok());
        assert!(ensure_allowed_command("inspect").is_ok());
        assert!(ensure_allowed_command("set_property").is_err());
        assert!(ensure_allowed_command("destroy").is_err());
        assert!(ensure_allowed_command("create_instance").is_err());
    }

    #[test]
    fn options_are_normalized_with_caps() {
        let config = AppConfig {
            bind_host: "127.0.0.1".to_string(),
            ws_port: 3812,
            ws_port_range: None,
            shared_secret: "abcdefghijklmnopqrstuvwxyz".to_string(),
            token_ttl: std::time::Duration::from_secs(60),
            cursor_ttl: std::time::Duration::from_secs(60),
            heartbeat_interval: std::time::Duration::from_secs(20),
            default_tool_timeout: std::time::Duration::from_millis(4_000),
            max_ws_message_bytes: 128 * 1024,
            max_messages_per_second: 100,
            max_inflight_requests: 16,
        };

        let options = QueryOptions {
            profile: Some("UI".to_string()),
            roots: vec![
                "StarterGui".to_string(),
                "Players".to_string(),
                "StarterGui".to_string(),
                "Workspace".to_string(),
            ],
            include_attributes: Some(true),
            include_tags: Some(false),
            include_props: (0..80).map(|index| format!("Prop{index}")).collect(),
            exclude_classes: (0..80).map(|index| format!("Class{index}")).collect(),
            max_depth: Some(999),
            max_nodes: Some(999),
            timeout_ms: Some(99_000),
        };

        let normalized = options.normalize(&config);
        assert_eq!(normalized.profile, "ui");
        assert!(normalized.roots.len() <= HARD_MAX_INCLUDE_LIST_ITEMS);
        assert!(normalized.include_props.len() <= HARD_MAX_INCLUDE_PROPS);
        assert!(normalized.exclude_classes.len() <= HARD_MAX_INCLUDE_LIST_ITEMS);
        assert_eq!(normalized.max_depth, HARD_MAX_DEPTH);
        assert_eq!(normalized.max_nodes, HARD_MAX_NODES);
        assert_eq!(normalized.timeout_ms, HARD_MAX_TIMEOUT_MS);
    }
}
