use std::time::Duration;

use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Stdin, Stdout};
use tracing::debug;

use crate::{
    config::AppConfig,
    errors::{BridgeError, Result},
    protocol::{
        mcp_tool_list, GetInstanceTreeArgs, GetSelectedArgs, InspectInstanceArgs,
        SearchInstancesArgs, TOOL_GET_INSTANCE_TREE, TOOL_GET_SELECTED, TOOL_INSPECT_INSTANCE,
        TOOL_SEARCH_INSTANCES,
    },
    session::CursorCodec,
    ws_bridge::WsBridge,
};

pub struct McpServer {
    config: AppConfig,
    bridge: WsBridge,
    cursor_codec: CursorCodec,
}

#[derive(Debug, Clone, Copy)]
enum MessageFraming {
    JsonLine,
    ContentLength,
}

struct IncomingMessage {
    value: Value,
    framing: MessageFraming,
}

#[derive(Debug, Deserialize)]
struct JsonRpcRequest {
    jsonrpc: String,
    id: Option<Value>,
    method: String,
    #[serde(default)]
    params: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ToolCallParams {
    name: String,
    #[serde(default)]
    arguments: Value,
}

impl McpServer {
    pub fn new(config: AppConfig, bridge: WsBridge) -> Self {
        let cursor_codec = CursorCodec::new(&config.shared_secret, config.cursor_ttl);
        Self {
            config,
            bridge,
            cursor_codec,
        }
    }

    pub async fn run(self) -> Result<()> {
        let stdin = tokio::io::stdin();
        let mut reader = BufReader::new(stdin);
        let mut stdout = tokio::io::stdout();

        loop {
            let Some(incoming) = read_json_rpc_message(&mut reader).await? else {
                break;
            };

            let request: JsonRpcRequest = match serde_json::from_value(incoming.value) {
                Ok(request) => request,
                Err(error) => {
                    let response =
                        json_rpc_error(Value::Null, -32700, &format!("invalid request: {error}"));
                    write_json_rpc_message(&mut stdout, &response, incoming.framing).await?;
                    continue;
                }
            };

            if request.jsonrpc != "2.0" {
                let response = json_rpc_error(
                    request.id.unwrap_or(Value::Null),
                    -32600,
                    "jsonrpc version must be 2.0",
                );
                write_json_rpc_message(&mut stdout, &response, incoming.framing).await?;
                continue;
            }

            if request.id.is_none() {
                if request.method == "notifications/initialized" {
                    debug!("received initialized notification");
                    continue;
                }
                debug!("dropping notification: {}", request.method);
                continue;
            }

            let id = request.id.clone().unwrap_or(Value::Null);
            let response = match self.handle_request(request).await {
                Ok(result) => json_rpc_result(id, result),
                Err(error) => {
                    let code = match error {
                        BridgeError::BadRequest(_) | BridgeError::InvalidCursor(_) => -32602,
                        BridgeError::Unavailable | BridgeError::Timeout(_) => -32001,
                        BridgeError::Protocol(_) | BridgeError::Auth(_) => -32002,
                        BridgeError::Config(_) | BridgeError::Internal(_) => -32000,
                    };
                    json_rpc_error(id, code, &error.to_string())
                }
            };

            write_json_rpc_message(&mut stdout, &response, incoming.framing).await?;
        }

        Ok(())
    }

    async fn handle_request(&self, request: JsonRpcRequest) -> Result<Value> {
        match request.method.as_str() {
            "initialize" => Ok(json!({
                "protocolVersion": "2025-03-26",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "roblox-read-mcp",
                    "version": env!("CARGO_PKG_VERSION")
                }
            })),
            "tools/list" => Ok(mcp_tool_list()),
            "tools/call" => {
                let params: ToolCallParams =
                    serde_json::from_value(request.params).map_err(|error| {
                        BridgeError::BadRequest(format!("invalid tools/call params: {error}"))
                    })?;
                self.handle_tool_call(params).await
            }
            method => Err(BridgeError::BadRequest(format!(
                "unsupported method `{method}`"
            ))),
        }
    }

    async fn handle_tool_call(&self, params: ToolCallParams) -> Result<Value> {
        let tool_result = match params.name.as_str() {
            TOOL_SEARCH_INSTANCES => {
                let args: SearchInstancesArgs =
                    serde_json::from_value(params.arguments).map_err(|error| {
                        BridgeError::BadRequest(format!(
                            "invalid search_instances arguments: {error}"
                        ))
                    })?;
                let options = args.options.normalize(&self.config);
                let fingerprint = fingerprint_of(json!({
                    "tool": TOOL_SEARCH_INSTANCES,
                    "query": args.query,
                    "options": options,
                }))?;
                let offset = self.decode_cursor(
                    args.cursor.as_deref(),
                    TOOL_SEARCH_INSTANCES,
                    &fingerprint,
                )?;

                let payload = json!({
                    "query": args.query,
                    "cursorOffset": offset,
                    "options": options,
                });

                let response = self
                    .bridge
                    .call_plugin("search", payload, Duration::from_millis(options.timeout_ms))
                    .await?;
                self.decorate_pagination(response, TOOL_SEARCH_INSTANCES, &fingerprint)?
            }
            TOOL_GET_INSTANCE_TREE => {
                let args: GetInstanceTreeArgs =
                    serde_json::from_value(params.arguments).map_err(|error| {
                        BridgeError::BadRequest(format!(
                            "invalid get_instance_tree arguments: {error}"
                        ))
                    })?;
                let options = args.options.normalize(&self.config);
                let fingerprint = fingerprint_of(json!({
                    "tool": TOOL_GET_INSTANCE_TREE,
                    "path": args.path,
                    "options": options,
                }))?;
                let offset = self.decode_cursor(
                    args.cursor.as_deref(),
                    TOOL_GET_INSTANCE_TREE,
                    &fingerprint,
                )?;

                let payload = json!({
                    "path": args.path,
                    "cursorOffset": offset,
                    "options": options,
                });

                let response = self
                    .bridge
                    .call_plugin("tree", payload, Duration::from_millis(options.timeout_ms))
                    .await?;
                self.decorate_pagination(response, TOOL_GET_INSTANCE_TREE, &fingerprint)?
            }
            TOOL_GET_SELECTED => {
                let args: GetSelectedArgs =
                    serde_json::from_value(params.arguments).map_err(|error| {
                        BridgeError::BadRequest(format!("invalid get_selected arguments: {error}"))
                    })?;
                let options = args.options.normalize(&self.config);
                let fingerprint = fingerprint_of(json!({
                    "tool": TOOL_GET_SELECTED,
                    "options": options,
                }))?;
                let offset =
                    self.decode_cursor(args.cursor.as_deref(), TOOL_GET_SELECTED, &fingerprint)?;

                let payload = json!({
                    "cursorOffset": offset,
                    "options": options,
                });

                let response = self
                    .bridge
                    .call_plugin(
                        "selected",
                        payload,
                        Duration::from_millis(options.timeout_ms),
                    )
                    .await?;
                self.decorate_pagination(response, TOOL_GET_SELECTED, &fingerprint)?
            }
            TOOL_INSPECT_INSTANCE => {
                let args: InspectInstanceArgs =
                    serde_json::from_value(params.arguments).map_err(|error| {
                        BridgeError::BadRequest(format!(
                            "invalid inspect_instance arguments: {error}"
                        ))
                    })?;

                if args.path.trim().is_empty() {
                    return Err(BridgeError::BadRequest(
                        "inspect_instance.path must not be empty".to_string(),
                    ));
                }

                let options = args.options.normalize(&self.config);
                let payload = json!({
                    "path": args.path,
                    "options": options,
                });

                self.bridge
                    .call_plugin(
                        "inspect",
                        payload,
                        Duration::from_millis(options.timeout_ms),
                    )
                    .await?
            }
            other => return Err(BridgeError::BadRequest(format!("unknown tool `{other}`"))),
        };

        Ok(tool_success(tool_result))
    }

    fn decode_cursor(
        &self,
        cursor: Option<&str>,
        operation: &str,
        fingerprint: &str,
    ) -> Result<u64> {
        match cursor {
            Some(cursor) if !cursor.trim().is_empty() => {
                self.cursor_codec.decode(cursor, operation, fingerprint)
            }
            _ => Ok(0),
        }
    }

    fn decorate_pagination(
        &self,
        response: Value,
        operation: &str,
        fingerprint: &str,
    ) -> Result<Value> {
        let mut object = response.as_object().cloned().ok_or_else(|| {
            BridgeError::Protocol("plugin response is not a JSON object".to_string())
        })?;

        let next_offset = object.remove("nextOffset").and_then(|value| value.as_u64());

        let cursor = if let Some(next_offset) = next_offset {
            Some(
                self.cursor_codec
                    .encode(operation, fingerprint, next_offset)?,
            )
        } else {
            None
        };

        object.insert(
            "nextCursor".to_string(),
            cursor.map_or(Value::Null, Value::String),
        );

        Ok(Value::Object(object))
    }
}

fn tool_success(payload: Value) -> Value {
    let text = serde_json::to_string_pretty(&payload)
        .unwrap_or_else(|_| "{\"error\":\"failed to encode tool payload\"}".to_string());

    json!({
        "content": [
            {
                "type": "text",
                "text": text
            }
        ],
        "structuredContent": payload,
        "isError": false
    })
}

fn json_rpc_result(id: Value, result: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result,
    })
}

fn json_rpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message,
        }
    })
}

fn fingerprint_of(value: Value) -> Result<String> {
    let canonical = serde_json::to_vec(&value).map_err(|error| {
        BridgeError::Internal(format!("failed to serialize fingerprint payload: {error}"))
    })?;

    let mut hasher = Sha256::new();
    hasher.update(canonical);
    let digest = hasher.finalize();

    Ok(digest.iter().map(|byte| format!("{byte:02x}")).collect())
}

async fn read_json_rpc_message(reader: &mut BufReader<Stdin>) -> Result<Option<IncomingMessage>> {
    let mut first_line = String::new();
    let bytes = reader.read_line(&mut first_line).await?;
    if bytes == 0 {
        return Ok(None);
    }

    if first_line.trim_start().starts_with('{') {
        let value: Value = serde_json::from_str(first_line.trim()).map_err(|error| {
            BridgeError::Protocol(format!("invalid newline-delimited json request: {error}"))
        })?;
        return Ok(Some(IncomingMessage {
            value,
            framing: MessageFraming::JsonLine,
        }));
    }

    let mut content_length = parse_content_length(&first_line)?;

    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line).await?;
        if read == 0 {
            return Err(BridgeError::Protocol(
                "unexpected EOF while reading stdio headers".to_string(),
            ));
        }

        if line == "\r\n" || line == "\n" {
            break;
        }

        if content_length.is_none() {
            content_length = parse_content_length(&line)?;
        }
    }

    let Some(content_length) = content_length else {
        return Err(BridgeError::Protocol(
            "missing Content-Length header".to_string(),
        ));
    };

    let mut payload = vec![0_u8; content_length];
    reader.read_exact(&mut payload).await?;

    let value: Value = serde_json::from_slice(&payload)
        .map_err(|error| BridgeError::Protocol(format!("invalid json payload: {error}")))?;

    Ok(Some(IncomingMessage {
        value,
        framing: MessageFraming::ContentLength,
    }))
}

fn parse_content_length(line: &str) -> Result<Option<usize>> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }

    let Some((key, value)) = trimmed.split_once(':') else {
        return Ok(None);
    };

    if !key.eq_ignore_ascii_case("Content-Length") {
        return Ok(None);
    }

    let parsed = value.trim().parse::<usize>().map_err(|error| {
        BridgeError::Protocol(format!("invalid Content-Length header: {error}"))
    })?;

    Ok(Some(parsed))
}

async fn write_json_rpc_message(
    writer: &mut Stdout,
    value: &Value,
    framing: MessageFraming,
) -> Result<()> {
    let body = serde_json::to_vec(value).map_err(|error| {
        BridgeError::Internal(format!("failed to serialize json-rpc response: {error}"))
    })?;

    match framing {
        MessageFraming::ContentLength => {
            let header = format!("Content-Length: {}\r\n\r\n", body.len());
            writer.write_all(header.as_bytes()).await?;
            writer.write_all(&body).await?;
        }
        MessageFraming::JsonLine => {
            writer.write_all(&body).await?;
            writer.write_all(b"\n").await?;
        }
    }
    writer.flush().await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_is_stable() {
        let first = fingerprint_of(json!({"a": 1, "b": [true, false]}));
        let second = fingerprint_of(json!({"a": 1, "b": [true, false]}));
        assert!(first.is_ok());
        assert!(second.is_ok());
        let first = first.unwrap_or_default();
        let second = second.unwrap_or_default();
        assert_eq!(first, second);
    }

    #[test]
    fn parse_content_length_accepts_valid_header() {
        let length = parse_content_length("Content-Length: 123\r\n");
        assert!(length.is_ok());
        let length = length.unwrap_or_default();
        assert_eq!(length, Some(123));
    }

    #[test]
    fn parse_content_length_ignores_other_headers() {
        let length = parse_content_length("Content-Type: application/json\r\n");
        assert!(length.is_ok());
        let length = length.unwrap_or_default();
        assert_eq!(length, None);
    }
}
