use std::{
    collections::HashMap,
    io,
    net::{IpAddr, SocketAddr},
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use futures_util::{SinkExt, StreamExt};
use rand::RngCore;
use serde_json::{json, Value};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{mpsc, oneshot, Mutex, RwLock, Semaphore},
    time,
};
use tokio_tungstenite::{
    accept_async_with_config,
    tungstenite::{
        protocol::{frame::coding::CloseCode, CloseFrame, Message, WebSocketConfig},
        Error as WsError,
    },
};
use tracing::{debug, info, warn};

use crate::{
    config::AppConfig,
    errors::{BridgeError, Result},
    protocol::{
        ensure_allowed_command, AuthOkPayload, AuthResponsePayload, BridgeEnvelope,
        CommandResultPayload, ErrorPayload, HelloChallengePayload,
    },
    session::{now_ms, AuthManager, SessionToken},
};

#[derive(Clone)]
pub struct WsBridge {
    state: Arc<BridgeState>,
}

struct BridgeState {
    config: AppConfig,
    auth: AuthManager,
    active_session: RwLock<Option<ActiveSession>>,
    pending_requests: Mutex<HashMap<String, oneshot::Sender<Result<Value>>>>,
    inflight_guard: Arc<Semaphore>,
    request_counter: AtomicU64,
}

#[derive(Clone)]
struct ActiveSession {
    connection_id: String,
    session_token: SessionToken,
    writer: mpsc::UnboundedSender<Message>,
}

impl WsBridge {
    pub async fn bind(config: AppConfig) -> Result<Self> {
        let (listener, bound_port) = bind_listener(&config).await?;
        let mut config = config;
        config.ws_port = bound_port;

        let state = Arc::new(BridgeState {
            auth: AuthManager::new(&config.shared_secret, config.token_ttl),
            inflight_guard: Arc::new(Semaphore::new(config.max_inflight_requests)),
            pending_requests: Mutex::new(HashMap::new()),
            active_session: RwLock::new(None),
            request_counter: AtomicU64::new(1),
            config,
        });

        let server_state = Arc::clone(&state);
        tokio::spawn(async move {
            if let Err(error) = run_accept_loop(listener, server_state).await {
                warn!("websocket accept loop exited: {error}");
            }
        });

        Ok(Self { state })
    }

    pub async fn call_plugin(
        &self,
        command: &str,
        args: Value,
        timeout: Duration,
    ) -> Result<Value> {
        ensure_allowed_command(command)?;
        let permit = Arc::clone(&self.state.inflight_guard)
            .acquire_owned()
            .await
            .map_err(|_| BridgeError::Unavailable)?;

        let session = self
            .state
            .active_session
            .read()
            .await
            .clone()
            .ok_or(BridgeError::Unavailable)?;

        if now_ms() > session.session_token.expires_at_ms {
            return Err(BridgeError::Auth(
                "plugin session token expired".to_string(),
            ));
        }

        let request_id = format!(
            "req-{}-{}",
            now_ms(),
            self.state.request_counter.fetch_add(1, Ordering::SeqCst)
        );

        let (reply_tx, reply_rx) = oneshot::channel::<Result<Value>>();
        {
            let mut pending = self.state.pending_requests.lock().await;
            pending.insert(request_id.clone(), reply_tx);
        }

        let envelope = BridgeEnvelope::new(
            "command",
            Some(request_id.clone()),
            json!({
                "command": command,
                "args": args,
            }),
        )
        .with_token(session.session_token.value.clone());

        let serialized = envelope.to_text()?;
        session
            .writer
            .send(Message::Text(serialized))
            .map_err(|_| BridgeError::Unavailable)?;

        let reply = time::timeout(timeout, reply_rx).await;
        drop(permit);

        match reply {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(BridgeError::Unavailable),
            Err(_) => {
                let mut pending = self.state.pending_requests.lock().await;
                pending.remove(&request_id);
                Err(BridgeError::Timeout(timeout.as_millis() as u64))
            }
        }
    }
}

async fn bind_listener(config: &AppConfig) -> Result<(TcpListener, u16)> {
    let mut last_error: Option<(u16, io::Error)> = None;

    for port in config.ws_candidate_ports() {
        let bind_addr = format!("{}:{}", config.bind_host, port);
        match TcpListener::bind(&bind_addr).await {
            Ok(listener) => {
                if config.ws_port_range.is_some() {
                    info!("websocket bridge selected port {}", bind_addr);
                }
                return Ok((listener, port));
            }
            Err(error) => {
                debug!(
                    "failed to bind websocket listener on {}: {}",
                    bind_addr, error
                );
                last_error = Some((port, error));
            }
        }
    }

    if let Some((start, end)) = config.ws_port_range {
        let detail = last_error
            .as_ref()
            .map(|(port, error)| format!("last error on {}:{}: {}", config.bind_host, port, error))
            .unwrap_or_else(|| "no bind attempts were made".to_string());
        return Err(BridgeError::Config(format!(
            "failed to bind websocket listener in range {}:{}-{} ({})",
            config.bind_host, start, end, detail
        )));
    }

    let detail = last_error
        .as_ref()
        .map(|(_, error)| error.to_string())
        .unwrap_or_else(|| "no bind attempts were made".to_string());
    Err(BridgeError::Config(format!(
        "failed to bind websocket listener: {}",
        detail
    )))
}

async fn run_accept_loop(listener: TcpListener, state: Arc<BridgeState>) -> Result<()> {
    info!(
        "websocket bridge listening on {}",
        state.config.ws_bind_addr()
    );

    loop {
        let (stream, address) = listener
            .accept()
            .await
            .map_err(|error| BridgeError::Internal(format!("accept failed: {error}")))?;

        if !is_loopback(address.ip()) {
            warn!("rejecting non-loopback websocket connection from {address}");
            continue;
        }

        let connection_state = Arc::clone(&state);
        tokio::spawn(async move {
            if let Err(error) = handle_socket(stream, address, connection_state).await {
                warn!("socket {address} ended with error: {error}");
            }
        });
    }
}

fn is_loopback(ip: IpAddr) -> bool {
    ip.is_loopback()
}

async fn handle_socket(
    stream: TcpStream,
    address: SocketAddr,
    state: Arc<BridgeState>,
) -> Result<()> {
    let ws_config = WebSocketConfig {
        max_message_size: Some(state.config.max_ws_message_bytes),
        max_frame_size: Some(state.config.max_ws_message_bytes),
        ..WebSocketConfig::default()
    };

    let socket = accept_async_with_config(stream, Some(ws_config))
        .await
        .map_err(|error| BridgeError::Protocol(format!("websocket handshake failed: {error}")))?;

    {
        let session_guard = state.active_session.read().await;
        if session_guard.is_some() {
            let (mut sink, _) = socket.split();
            let _ = sink
                .send(Message::Close(Some(CloseFrame {
                    code: CloseCode::Policy,
                    reason: "only one plugin session is allowed".into(),
                })))
                .await;
            return Ok(());
        }
    }

    let connection_id = random_id();
    let (mut sink, mut stream) = socket.split();
    let (write_tx, mut write_rx) = mpsc::unbounded_channel::<Message>();

    let write_task = tokio::spawn(async move {
        while let Some(message) = write_rx.recv().await {
            if sink.send(message).await.is_err() {
                break;
            }
        }
    });

    let nonce = state.auth.issue_nonce();
    let challenge = HelloChallengePayload {
        nonce: nonce.clone(),
        server_time_ms: now_ms(),
        token_ttl_ms: state.config.token_ttl.as_millis() as u64,
    };

    send_envelope(
        &write_tx,
        BridgeEnvelope::new(
            "hello_challenge",
            Some(format!("auth-{connection_id}")),
            serde_json::to_value(challenge).map_err(|error| {
                BridgeError::Internal(format!("challenge serialization failed: {error}"))
            })?,
        ),
    )?;

    let mut rate_window = RateWindow::new();
    let mut authenticated = false;
    let mut active_token: Option<SessionToken> = None;

    while let Some(next_message) = stream.next().await {
        let message = match next_message {
            Ok(message) => message,
            Err(WsError::ConnectionClosed) => break,
            Err(error) => {
                warn!("websocket receive error from {address}: {error}");
                break;
            }
        };

        let raw = match message {
            Message::Text(text) => text,
            Message::Binary(binary) => match String::from_utf8(binary) {
                Ok(text) => text,
                Err(_) => {
                    let _ = send_error(
                        &write_tx,
                        Some("invalid-binary".to_string()),
                        "invalid_payload",
                        "binary payload must be UTF-8 encoded JSON",
                    );
                    continue;
                }
            },
            Message::Ping(payload) => {
                let _ = write_tx.send(Message::Pong(payload));
                continue;
            }
            Message::Pong(_) => continue,
            Message::Close(_) => break,
            Message::Frame(_) => continue,
        };

        if !rate_window.allow(state.config.max_messages_per_second) {
            warn!("rate limit exceeded for websocket client {address}");
            let _ = write_tx.send(Message::Close(Some(CloseFrame {
                code: CloseCode::Policy,
                reason: "rate limit exceeded".into(),
            })));
            break;
        }

        let envelope = match BridgeEnvelope::parse_json(&raw, state.config.max_ws_message_bytes) {
            Ok(envelope) => envelope,
            Err(error) => {
                let _ = send_error(
                    &write_tx,
                    Some("invalid-envelope".to_string()),
                    "invalid_envelope",
                    &error.to_string(),
                );
                continue;
            }
        };

        match envelope.message_type.as_str() {
            "auth_response" => {
                if authenticated {
                    let _ = send_error(
                        &write_tx,
                        envelope.request_id.clone(),
                        "already_authenticated",
                        "session is already authenticated",
                    );
                    continue;
                }

                let payload: AuthResponsePayload =
                    match serde_json::from_value(envelope.payload.clone()) {
                        Ok(payload) => payload,
                        Err(error) => {
                            let _ = send_error(
                                &write_tx,
                                envelope.request_id.clone(),
                                "invalid_auth_payload",
                                &format!("auth payload validation failed: {error}"),
                            );
                            continue;
                        }
                    };

                if payload.client_id.trim().is_empty() {
                    let _ = send_error(
                        &write_tx,
                        envelope.request_id.clone(),
                        "invalid_auth_payload",
                        "clientId must not be empty",
                    );
                    continue;
                }

                match state.auth.verify_challenge_signature(
                    &nonce,
                    &payload.client_id,
                    payload.client_timestamp_ms,
                    &payload.signature,
                ) {
                    Ok(()) => {
                        let session_token = state.auth.mint_session_token();
                        authenticated = true;
                        active_token = Some(session_token.clone());

                        let session = ActiveSession {
                            connection_id: connection_id.clone(),
                            session_token: session_token.clone(),
                            writer: write_tx.clone(),
                        };

                        {
                            let mut guard = state.active_session.write().await;
                            *guard = Some(session);
                        }

                        let auth_ok = AuthOkPayload {
                            session_token: session_token.value,
                            expires_at_ms: session_token.expires_at_ms,
                            heartbeat_interval_ms: state.config.heartbeat_interval.as_millis()
                                as u64,
                        };

                        send_envelope(
                            &write_tx,
                            BridgeEnvelope::new(
                                "auth_ok",
                                envelope.request_id.clone(),
                                serde_json::to_value(auth_ok).map_err(|error| {
                                    BridgeError::Internal(format!(
                                        "auth_ok serialization failed: {error}"
                                    ))
                                })?,
                            ),
                        )?;
                    }
                    Err(error) => {
                        let _ = send_error(
                            &write_tx,
                            envelope.request_id.clone(),
                            "auth_failed",
                            &error.to_string(),
                        );
                        break;
                    }
                }
            }
            "command_result" => {
                if !authenticated {
                    let _ = send_error(
                        &write_tx,
                        envelope.request_id.clone(),
                        "unauthenticated",
                        "must complete auth handshake before command responses",
                    );
                    continue;
                }

                let Some(expected_token) = active_token.as_ref() else {
                    let _ = send_error(
                        &write_tx,
                        envelope.request_id.clone(),
                        "unauthenticated",
                        "missing active session token",
                    );
                    continue;
                };

                let Some(provided_token) = envelope.session_token.as_ref() else {
                    let _ = send_error(
                        &write_tx,
                        envelope.request_id.clone(),
                        "unauthorized",
                        "sessionToken is required for command_result",
                    );
                    continue;
                };

                if let Err(error) = state
                    .auth
                    .validate_session_token(expected_token, provided_token)
                {
                    let _ = send_error(
                        &write_tx,
                        envelope.request_id.clone(),
                        "unauthorized",
                        &error.to_string(),
                    );
                    continue;
                }

                let Some(request_id) = envelope.request_id.clone() else {
                    let _ = send_error(
                        &write_tx,
                        None,
                        "invalid_response",
                        "command_result is missing requestId",
                    );
                    continue;
                };

                let payload: CommandResultPayload =
                    match serde_json::from_value(envelope.payload.clone()) {
                        Ok(payload) => payload,
                        Err(error) => {
                            let _ = send_error(
                                &write_tx,
                                Some(request_id.clone()),
                                "invalid_response",
                                &format!("command_result payload is invalid: {error}"),
                            );
                            continue;
                        }
                    };

                let pending = {
                    let mut pending_map = state.pending_requests.lock().await;
                    pending_map.remove(&request_id)
                };

                if let Some(reply) = pending {
                    if payload.ok {
                        let _ = reply.send(Ok(payload.data.unwrap_or_else(|| json!({}))));
                    } else {
                        let message = payload.error.map_or_else(
                            || "plugin reported unknown error".to_string(),
                            |error| error.message,
                        );
                        let _ = reply.send(Err(BridgeError::Internal(message)));
                    }
                } else {
                    debug!("dropping response for unknown request id: {request_id}");
                }
            }
            "pong" | "status" => {
                // no-op: useful for telemetry if needed later
            }
            "ping" => {
                send_envelope(
                    &write_tx,
                    BridgeEnvelope::new("pong", envelope.request_id.clone(), json!({})),
                )?;
            }
            other => {
                let _ = send_error(
                    &write_tx,
                    envelope.request_id.clone(),
                    "unknown_message_type",
                    &format!("message type `{other}` is not supported"),
                );
            }
        }
    }

    {
        let mut session = state.active_session.write().await;
        if session
            .as_ref()
            .is_some_and(|active| active.connection_id == connection_id)
        {
            *session = None;
        }
    }

    fail_all_pending(&state, "plugin websocket disconnected").await;
    drop(write_tx);
    let _ = write_task.await;

    Ok(())
}

async fn fail_all_pending(state: &Arc<BridgeState>, message: &str) {
    let mut pending = state.pending_requests.lock().await;
    for (_, reply) in pending.drain() {
        let _ = reply.send(Err(BridgeError::Unavailable));
    }
    debug!("cleared pending requests after disconnect: {message}");
}

fn send_envelope(writer: &mpsc::UnboundedSender<Message>, envelope: BridgeEnvelope) -> Result<()> {
    let text = envelope.to_text()?;
    writer
        .send(Message::Text(text))
        .map_err(|_| BridgeError::Unavailable)
}

fn send_error(
    writer: &mpsc::UnboundedSender<Message>,
    request_id: Option<String>,
    code: &str,
    message: &str,
) -> Result<()> {
    let payload = ErrorPayload::new(code, message);
    send_envelope(
        writer,
        BridgeEnvelope::new(
            "error",
            request_id,
            serde_json::to_value(payload).map_err(|error| {
                BridgeError::Internal(format!("error payload serialization failed: {error}"))
            })?,
        ),
    )
}

#[derive(Debug)]
struct RateWindow {
    started_at_ms: u64,
    count: u32,
}

impl RateWindow {
    fn new() -> Self {
        Self {
            started_at_ms: now_ms(),
            count: 0,
        }
    }

    fn allow(&mut self, limit_per_second: u32) -> bool {
        let now = now_ms();
        if now.saturating_sub(self.started_at_ms) >= 1_000 {
            self.started_at_ms = now;
            self.count = 0;
        }

        self.count = self.count.saturating_add(1);
        self.count <= limit_per_second
    }
}

fn random_id() -> String {
    let mut bytes = [0_u8; 12];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}
