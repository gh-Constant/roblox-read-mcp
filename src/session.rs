use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use hmac::{Hmac, Mac};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

use crate::errors::{BridgeError, Result};

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone)]
pub struct SessionToken {
    pub value: String,
    pub expires_at_ms: u64,
}

#[derive(Debug)]
pub struct AuthManager {
    key: Vec<u8>,
    token_ttl: Duration,
    nonces: Mutex<HashMap<String, u64>>,
}

impl AuthManager {
    pub fn new(secret: &str, token_ttl: Duration) -> Self {
        Self {
            key: secret.as_bytes().to_vec(),
            token_ttl,
            nonces: Mutex::new(HashMap::new()),
        }
    }

    pub fn issue_nonce(&self) -> String {
        let mut bytes = [0_u8; 24];
        rand::thread_rng().fill_bytes(&mut bytes);
        let nonce = URL_SAFE_NO_PAD.encode(bytes);
        let expires_at = now_ms().saturating_add(120_000);

        if let Ok(mut nonces) = self.nonces.lock() {
            nonces.retain(|_, exp| *exp > now_ms());
            nonces.insert(nonce.clone(), expires_at);
        }

        nonce
    }

    pub fn signature_for_challenge(
        &self,
        nonce: &str,
        client_id: &str,
        timestamp_ms: u64,
    ) -> Result<String> {
        let material = format!("{nonce}:{client_id}:{timestamp_ms}");
        hmac_hex(&self.key, material.as_bytes())
    }

    pub fn verify_challenge_signature(
        &self,
        nonce: &str,
        client_id: &str,
        timestamp_ms: u64,
        received_signature: &str,
    ) -> Result<()> {
        self.consume_nonce(nonce)?;
        let expected = self.signature_for_challenge(nonce, client_id, timestamp_ms)?;

        if !constant_time_eq(expected.as_bytes(), received_signature.as_bytes()) {
            return Err(BridgeError::Auth(
                "challenge signature mismatch".to_string(),
            ));
        }

        Ok(())
    }

    pub fn mint_session_token(&self) -> SessionToken {
        let mut bytes = [0_u8; 32];
        rand::thread_rng().fill_bytes(&mut bytes);

        SessionToken {
            value: URL_SAFE_NO_PAD.encode(bytes),
            expires_at_ms: now_ms().saturating_add(self.token_ttl.as_millis() as u64),
        }
    }

    pub fn validate_session_token(&self, current: &SessionToken, provided: &str) -> Result<()> {
        if now_ms() > current.expires_at_ms {
            return Err(BridgeError::Auth("session token expired".to_string()));
        }

        if !constant_time_eq(current.value.as_bytes(), provided.as_bytes()) {
            return Err(BridgeError::Auth("invalid session token".to_string()));
        }

        Ok(())
    }

    fn consume_nonce(&self, nonce: &str) -> Result<()> {
        let mut guard = self
            .nonces
            .lock()
            .map_err(|_| BridgeError::Internal("nonce mutex poisoned".to_string()))?;

        let Some(expires_at) = guard.remove(nonce) else {
            return Err(BridgeError::Auth(
                "nonce is unknown or already consumed".to_string(),
            ));
        };

        if expires_at <= now_ms() {
            return Err(BridgeError::Auth("nonce expired".to_string()));
        }

        Ok(())
    }
}

#[derive(Debug)]
pub struct CursorCodec {
    key: Vec<u8>,
    ttl: Duration,
}

#[derive(Debug, Serialize, Deserialize)]
struct CursorClaims {
    v: u8,
    op: String,
    fp: String,
    offset: u64,
    exp: u64,
}

impl CursorCodec {
    pub fn new(secret: &str, ttl: Duration) -> Self {
        let mut key = Vec::with_capacity(secret.len() + 8);
        key.extend_from_slice(secret.as_bytes());
        key.extend_from_slice(b":cursor");
        Self { key, ttl }
    }

    pub fn encode(&self, operation: &str, fingerprint: &str, offset: u64) -> Result<String> {
        let claims = CursorClaims {
            v: 1,
            op: operation.to_string(),
            fp: fingerprint.to_string(),
            offset,
            exp: now_ms().saturating_add(self.ttl.as_millis() as u64),
        };

        let payload_json = serde_json::to_vec(&claims).map_err(|error| {
            BridgeError::Internal(format!("failed to encode cursor claims: {error}"))
        })?;
        let payload = URL_SAFE_NO_PAD.encode(payload_json);
        let signature = hmac_bytes(&self.key, payload.as_bytes())?;
        let signature_encoded = URL_SAFE_NO_PAD.encode(signature);

        Ok(format!("v1.{payload}.{signature_encoded}"))
    }

    pub fn decode(&self, cursor: &str, operation: &str, fingerprint: &str) -> Result<u64> {
        let parts: Vec<&str> = cursor.split('.').collect();
        if parts.len() != 3 || parts[0] != "v1" {
            return Err(BridgeError::InvalidCursor(
                "invalid cursor format".to_string(),
            ));
        }

        let payload = parts[1];
        let signature = parts[2];

        let expected_signature = URL_SAFE_NO_PAD.encode(hmac_bytes(&self.key, payload.as_bytes())?);
        if !constant_time_eq(expected_signature.as_bytes(), signature.as_bytes()) {
            return Err(BridgeError::InvalidCursor(
                "cursor signature mismatch".to_string(),
            ));
        }

        let decoded_payload = URL_SAFE_NO_PAD.decode(payload).map_err(|error| {
            BridgeError::InvalidCursor(format!("cursor payload decode failed: {error}"))
        })?;

        let claims: CursorClaims = serde_json::from_slice(&decoded_payload).map_err(|error| {
            BridgeError::InvalidCursor(format!("cursor payload invalid: {error}"))
        })?;

        if claims.v != 1 {
            return Err(BridgeError::InvalidCursor(
                "unsupported cursor version".to_string(),
            ));
        }

        if claims.op != operation {
            return Err(BridgeError::InvalidCursor(
                "cursor operation mismatch".to_string(),
            ));
        }

        if claims.fp != fingerprint {
            return Err(BridgeError::InvalidCursor(
                "cursor fingerprint mismatch".to_string(),
            ));
        }

        if now_ms() > claims.exp {
            return Err(BridgeError::InvalidCursor("cursor expired".to_string()));
        }

        Ok(claims.offset)
    }
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_millis() as u64)
}

fn hmac_hex(key: &[u8], data: &[u8]) -> Result<String> {
    let bytes = hmac_bytes(key, data)?;
    Ok(hex_encode(&bytes))
}

fn hmac_bytes(key: &[u8], data: &[u8]) -> Result<Vec<u8>> {
    let mut mac = HmacSha256::new_from_slice(key)
        .map_err(|error| BridgeError::Internal(format!("hmac init failed: {error}")))?;
    mac.update(data);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
    out
}

fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }

    let mut diff = 0_u8;
    for (&a, &b) in left.iter().zip(right) {
        diff |= a ^ b;
    }

    diff == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn challenge_nonce_is_single_use() {
        let auth = AuthManager::new("super-secret-key", Duration::from_secs(60));
        let nonce = auth.issue_nonce();
        let signature = auth.signature_for_challenge(&nonce, "studio-client", 123_000);
        assert!(signature.is_ok());
        let signature = signature.unwrap_or_default();

        assert!(auth
            .verify_challenge_signature(&nonce, "studio-client", 123_000, &signature)
            .is_ok());

        assert!(auth
            .verify_challenge_signature(&nonce, "studio-client", 123_000, &signature)
            .is_err());
    }

    #[test]
    fn cursor_rejects_tampered_payload() {
        let codec = CursorCodec::new("another-secret-key", Duration::from_secs(300));
        let cursor = codec.encode("search_instances", "fp_hash", 15);
        assert!(cursor.is_ok());
        let cursor = cursor.unwrap_or_default();

        let mut tampered = cursor
            .split('.')
            .map(str::to_string)
            .collect::<Vec<String>>();
        tampered[1].push('a');
        let tampered_cursor = tampered.join(".");

        assert!(codec
            .decode(&tampered_cursor, "search_instances", "fp_hash")
            .is_err());
    }

    #[test]
    fn cursor_round_trip() {
        let codec = CursorCodec::new("cursor-secret", Duration::from_secs(300));
        let cursor = codec.encode("get_selected", "stable-fingerprint", 42);
        assert!(cursor.is_ok());
        let cursor = cursor.unwrap_or_default();

        let decoded = codec.decode(&cursor, "get_selected", "stable-fingerprint");
        assert!(decoded.is_ok());
        let decoded = decoded.unwrap_or_default();

        assert_eq!(decoded, 42);
    }

    #[test]
    fn challenge_rejects_wrong_signature() {
        let auth = AuthManager::new("super-secret-key", Duration::from_secs(60));
        let nonce = auth.issue_nonce();

        let result = auth.verify_challenge_signature(
            &nonce,
            "studio-client",
            123_000,
            "not-a-valid-signature",
        );

        assert!(result.is_err());
    }
}
