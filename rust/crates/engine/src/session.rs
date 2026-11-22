use anyhow::{anyhow, Result};
use rand::RngCore;
use secrecy::{ExposeSecret, SecretString};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use zeroize::Zeroizing;

// ---------------------------------------------------------------------------
// Session-based payments — CipherPay prepaid credit model
//
// Flow:
// 1. Agent sends shielded ZEC with memo to merchant's address
// 2. Agent calls CipherPay POST /api/sessions/open with {txid, merchant_id}
// 3. CipherPay verifies payment, issues bearer token + credit balance
// 4. Agent uses Authorization: Bearer {token} for subsequent requests (instant)
// 5. Merchant validates token with CipherPay (cacheable, sub-ms)
// 6. When balance depletes or session expires, agent gets 402 again
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub session_id: String,
    pub bearer_token: String,
    pub server_url: String,
    pub deposit_txid: String,
    pub balance_remaining: u64,
    pub expires_at: String,
    pub created_at: String,
    pub cost_per_request: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionSummary {
    pub session_id: String,
    pub requests_made: u64,
    pub balance_used: u64,
    pub balance_remaining: u64,
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionStore {
    pub sessions: Vec<Session>,
}

impl SessionStore {
    pub fn new() -> Self {
        Self {
            sessions: Vec::new(),
        }
    }

    pub fn add(&mut self, session: Session) {
        self.sessions.retain(|s| s.session_id != session.session_id);
        self.sessions.push(session);
    }

    pub fn remove(&mut self, session_id: &str) {
        self.sessions.retain(|s| s.session_id != session_id);
    }

    pub fn find_for_server(&self, server_url: &str) -> Option<&Session> {
        self.sessions
            .iter()
            .find(|s| s.server_url == server_url && s.balance_remaining > 0)
    }

    pub fn find_by_id(&self, session_id: &str) -> Option<&Session> {
        self.sessions.iter().find(|s| s.session_id == session_id)
    }
}

impl Default for SessionStore {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

fn sessions_path(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join("sessions.json")
}

fn sessions_enc_path(data_dir: &str) -> PathBuf {
    Path::new(data_dir).join("sessions.enc")
}

/// Select the existing vault credential without changing its bytes. A blank
/// configured primary credential is an error, rather than a fallback trigger.
fn passphrase_from_values(
    primary: Option<String>,
    fallback: Option<String>,
) -> Result<SecretString> {
    let passphrase =
        SecretString::new(primary.or(fallback).ok_or_else(|| {
            anyhow!("Session storage requires ZIPHER_VAULT_PASS or OWS_PASSPHRASE")
        })?);
    validate_passphrase(passphrase.expose_secret())?;
    Ok(passphrase)
}

fn validate_passphrase(passphrase: &str) -> Result<()> {
    if passphrase.trim().is_empty() {
        return Err(anyhow!("Session storage credential must not be blank"));
    }
    Ok(())
}

fn session_encryption_passphrase() -> Result<SecretString> {
    fn read(name: &str) -> Result<Option<String>> {
        match std::env::var(name) {
            Ok(value) => Ok(Some(value)),
            Err(std::env::VarError::NotPresent) => Ok(None),
            Err(std::env::VarError::NotUnicode(_)) => {
                Err(anyhow!("Session storage credential must be valid Unicode"))
            }
        }
    }

    let primary = read("ZIPHER_VAULT_PASS")?;
    let fallback = if primary.is_none() {
        read("OWS_PASSPHRASE")?
    } else {
        None
    };
    passphrase_from_values(primary, fallback)
}

/// Never import, remove, or overwrite a legacy plaintext store implicitly.
/// symlink_metadata also catches dangling symlinks and unreadable paths.
fn encrypted_session_bytes(data_dir: &str) -> Result<Option<Vec<u8>>> {
    let directory = std::fs::metadata(data_dir)
        .map_err(|_| anyhow!("Session storage directory is unavailable"))?;
    if !directory.is_dir() {
        return Err(anyhow!("Session storage path must be a directory"));
    }

    match std::fs::symlink_metadata(sessions_path(data_dir)) {
        Ok(_) => {
            return Err(anyhow!(
                "Legacy plaintext sessions.json is retained; session changes are blocked \
                 until an explicit secure migration is completed"
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err(anyhow!("Cannot inspect legacy session storage")),
    }

    let path = sessions_enc_path(data_dir);
    match std::fs::symlink_metadata(&path) {
        Ok(metadata) if metadata.file_type().is_file() => std::fs::read(path)
            .map(Some)
            .map_err(|_| anyhow!("Cannot read encrypted session storage")),
        Ok(_) => Err(anyhow!("Encrypted session storage must be a regular file")),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err(anyhow!("Cannot inspect encrypted session storage")),
    }
}

fn decrypt_sessions(bytes: &[u8], passphrase: &str) -> Result<SessionStore> {
    let plaintext =
        Zeroizing::new(crate::vault::decrypt_blob(bytes, passphrase).map_err(|_| {
            anyhow!(
                "Cannot decrypt sessions.enc; restore the original credential or repair \
                 the store from a secure backup. Existing data has been retained"
            )
        })?);
    serde_json::from_slice(&plaintext).map_err(|_| {
        anyhow!("Encrypted session storage is invalid; existing data has been retained")
    })
}

struct LoadedSessions {
    store: SessionStore,
    encrypted: Option<Vec<u8>>,
}

fn load_sessions_with_passphrase(data_dir: &str, passphrase: &str) -> Result<LoadedSessions> {
    // Validate before any filesystem access, including for a new empty store.
    validate_passphrase(passphrase)?;
    let encrypted = encrypted_session_bytes(data_dir)?;
    let store = match encrypted.as_deref() {
        Some(bytes) => decrypt_sessions(bytes, passphrase)?,
        None => SessionStore::new(),
    };
    Ok(LoadedSessions { store, encrypted })
}

/// Check credentials and existing session storage before a deposit or remote
/// mutation. This does not create a store or migrate legacy plaintext files.
pub fn validate_session_storage(data_dir: &str) -> Result<()> {
    let passphrase = session_encryption_passphrase()?;
    load_sessions_with_passphrase(data_dir, passphrase.expose_secret())?;
    Ok(())
}

pub fn load_sessions(data_dir: &str) -> SessionStore {
    let result = (|| -> Result<SessionStore> {
        // An empty read-only listing does not require a credential.
        let Some(bytes) = encrypted_session_bytes(data_dir)? else {
            return Ok(SessionStore::new());
        };
        let passphrase = session_encryption_passphrase()?;
        decrypt_sessions(&bytes, passphrase.expose_secret())
    })();
    match result {
        Ok(store) => store,
        Err(error) => {
            tracing::warn!("Session store is locked; no sessions returned: {}", error);
            SessionStore::new()
        }
    }
}

struct PendingSessionFile(PathBuf);

impl Drop for PendingSessionFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn create_session_temp(data_dir: &str) -> Result<(std::fs::File, PendingSessionFile)> {
    for _ in 0..8 {
        let mut random = [0u8; 16];
        rand::rngs::OsRng.fill_bytes(&mut random);
        let path = Path::new(data_dir).join(format!(".sessions-{}.tmp", hex::encode(random)));
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&path) {
            Ok(file) => return Ok((file, PendingSessionFile(path))),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(_) => return Err(anyhow!("Cannot create private encrypted session storage")),
        }
    }
    Err(anyhow!("Cannot allocate private encrypted session storage"))
}

fn persist_sessions(
    data_dir: &str,
    store: &SessionStore,
    passphrase: &str,
    expected: Option<&[u8]>,
) -> Result<()> {
    validate_passphrase(passphrase)?;
    let json = Zeroizing::new(
        serde_json::to_vec(store).map_err(|_| anyhow!("Cannot serialize session storage"))?,
    );
    let encrypted = crate::vault::encrypt_blob(&json, passphrase)
        .map_err(|_| anyhow!("Cannot encrypt session storage"))?;
    persist_encrypted_sessions(data_dir, &encrypted, expected)
}

fn persist_encrypted_sessions(
    data_dir: &str,
    encrypted: &[u8],
    expected: Option<&[u8]>,
) -> Result<()> {
    let (mut file, temporary) = create_session_temp(data_dir)?;
    file.write_all(encrypted)
        .and_then(|_| file.sync_all())
        .map_err(|_| anyhow!("Cannot persist encrypted session storage"))?;
    drop(file);

    // Refuse to replace a store changed since it was successfully decrypted,
    // including a newly introduced legacy file or corrupt encrypted contents.
    if encrypted_session_bytes(data_dir)?.as_deref() != expected {
        return Err(anyhow!(
            "Session storage changed during this operation; existing data has been retained. Retry"
        ));
    }
    std::fs::rename(&temporary.0, sessions_enc_path(data_dir))
        .map_err(|_| anyhow!("Cannot atomically replace encrypted session storage"))?;
    Ok(())
}

fn save_sessions_with_passphrase(
    data_dir: &str,
    store: &SessionStore,
    passphrase: &str,
) -> Result<()> {
    let loaded = load_sessions_with_passphrase(data_dir, passphrase)?;
    persist_sessions(data_dir, store, passphrase, loaded.encrypted.as_deref())
}

pub fn save_sessions(data_dir: &str, store: &SessionStore) -> Result<()> {
    let passphrase = session_encryption_passphrase()?;
    save_sessions_with_passphrase(data_dir, store, passphrase.expose_secret())
}

// ---------------------------------------------------------------------------
// CipherPay session API client
// ---------------------------------------------------------------------------

const CIPHERPAY_SESSION_BASE: &str = "https://api.cipherpay.app";

fn resolve_cipherpay_url(override_url: Option<&str>) -> String {
    if let Some(url) = override_url {
        return url.to_string();
    }
    std::env::var("CIPHERPAY_URL").unwrap_or_else(|_| CIPHERPAY_SESSION_BASE.to_string())
}

fn client() -> reqwest::Client {
    reqwest::Client::new()
}

/// Open a new session by notifying CipherPay of a deposit transaction.
///
/// The agent must have already sent ZEC to the merchant's address with
/// a memo containing `zipher:session:{merchant_id}`.
pub async fn open_session(
    cipherpay_url: Option<&str>,
    txid: &str,
    merchant_id: &str,
    server_url: &str,
    data_dir: &str,
) -> Result<Session> {
    let passphrase = session_encryption_passphrase()?;
    load_sessions_with_passphrase(data_dir, passphrase.expose_secret())?;
    let base = resolve_cipherpay_url(cipherpay_url);

    let resp = client()
        .post(format!("{base}/api/sessions/open"))
        .json(&serde_json::json!({
            "txid": txid,
            "merchant_id": merchant_id,
        }))
        .send()
        .await
        .map_err(|e| anyhow!("Session open request failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Session open failed ({}): {}", status, body));
    }

    let json: serde_json::Value = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse session response: {e}"))?;

    let session = Session {
        session_id: json["session_id"].as_str().unwrap_or("").to_string(),
        bearer_token: json["bearer_token"].as_str().unwrap_or("").to_string(),
        server_url: server_url.to_string(),
        deposit_txid: txid.to_string(),
        balance_remaining: json["balance"]
            .as_u64()
            .or_else(|| json["balance_remaining"].as_u64())
            .unwrap_or(0),
        expires_at: json["expires_at"].as_str().unwrap_or("").to_string(),
        created_at: now_iso(),
        cost_per_request: json["cost_per_request"].as_u64().unwrap_or(0),
    };

    if session.session_id.is_empty() || session.bearer_token.is_empty() {
        return Err(anyhow!(
            "Invalid session response: missing session_id or bearer_token"
        ));
    }

    let mut loaded = load_sessions_with_passphrase(data_dir, passphrase.expose_secret())?;
    loaded.store.add(session.clone());
    persist_sessions(
        data_dir,
        &loaded.store,
        passphrase.expose_secret(),
        loaded.encrypted.as_deref(),
    )?;

    Ok(session)
}

/// Make an authenticated request using a session's bearer token.
pub async fn session_request(
    session: &Session,
    url: &str,
    method: &str,
) -> Result<(u16, String, Option<u64>)> {
    let client = client();
    let builder = match method.to_uppercase().as_str() {
        "POST" => client.post(url),
        "PUT" => client.put(url),
        "DELETE" => client.delete(url),
        _ => client.get(url),
    };

    let resp = builder
        .header("Authorization", format!("Bearer {}", session.bearer_token))
        .send()
        .await
        .map_err(|e| anyhow!("Session request failed: {e}"))?;

    let status = resp.status().as_u16();
    let remaining = resp
        .headers()
        .get("x-session-balance")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse::<u64>().ok());
    let body = resp.text().await.unwrap_or_default();

    Ok((status, body, remaining))
}

/// Check session balance with CipherPay.
pub async fn check_session(
    cipherpay_url: Option<&str>,
    session_id: &str,
) -> Result<SessionSummary> {
    let base = resolve_cipherpay_url(cipherpay_url);

    let resp = client()
        .get(format!("{base}/api/sessions/{session_id}"))
        .send()
        .await
        .map_err(|e| anyhow!("Session check failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Session check failed ({}): {}", status, body));
    }

    let summary: SessionSummary = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse session status: {e}"))?;
    Ok(summary)
}

/// Close a session and get final summary.
pub async fn close_session(
    cipherpay_url: Option<&str>,
    session_id: &str,
    data_dir: &str,
) -> Result<SessionSummary> {
    let passphrase = session_encryption_passphrase()?;
    load_sessions_with_passphrase(data_dir, passphrase.expose_secret())?;
    let base = resolve_cipherpay_url(cipherpay_url);

    let resp = client()
        .post(format!("{base}/api/sessions/{session_id}/close"))
        .send()
        .await
        .map_err(|e| anyhow!("Session close failed: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("Session close failed ({}): {}", status, body));
    }

    let summary: SessionSummary = resp
        .json()
        .await
        .map_err(|e| anyhow!("Failed to parse close response: {e}"))?;

    let mut loaded = load_sessions_with_passphrase(data_dir, passphrase.expose_secret())?;
    loaded.store.remove(session_id);
    persist_sessions(
        data_dir,
        &loaded.store,
        passphrase.expose_secret(),
        loaded.encrypted.as_deref(),
    )?;

    Ok(summary)
}

/// List all active sessions.
pub fn list_sessions(data_dir: &str) -> Vec<Session> {
    let store = load_sessions(data_dir);
    store.sessions
}

/// Find an active session for a given server URL.
pub fn find_session(data_dir: &str, server_url: &str) -> Option<Session> {
    let store = load_sessions(data_dir);
    store.find_for_server(server_url).cloned()
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;

    let (year, month, day) = days_to_ymd(days);

    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        year, month, day, hours, minutes, seconds
    )
}

fn days_to_ymd(mut days: u64) -> (u64, u64, u64) {
    days += 719468;
    let era = days / 146097;
    let doe = days - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture_store() -> SessionStore {
        SessionStore {
            sessions: vec![Session {
                session_id: "fixture-session".into(),
                bearer_token: "fixture-payment-credential".into(),
                server_url: "https://api.example.com".into(),
                deposit_txid: "fixture-txid".into(),
                balance_remaining: 50000,
                expires_at: "2026-04-01T00:00:00Z".into(),
                created_at: "2026-03-16T00:00:00Z".into(),
                cost_per_request: 500,
            }],
        }
    }

    #[test]
    fn missing_and_blank_credentials_fail_before_filesystem_work() {
        let directory = tempfile::tempdir().unwrap();
        let missing = directory.path().join("must-not-be-created");
        let data_dir = missing.to_str().unwrap();
        let store = fixture_store();
        for (primary, fallback) in [
            (None, None),
            (Some(""), None),
            (Some(" \t\n"), None),
            (None, Some(" \t\n")),
            (Some(""), Some("valid-fallback")),
        ] {
            let result =
                passphrase_from_values(primary.map(str::to_owned), fallback.map(str::to_owned))
                    .and_then(|passphrase| {
                        save_sessions_with_passphrase(data_dir, &store, passphrase.expose_secret())
                    });
            let error = result.unwrap_err().to_string();
            assert!(error.contains("credential") || error.contains("requires"));
            assert!(!missing.exists());
            assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
        }
        let error = load_sessions_with_passphrase(data_dir, " \n")
            .err()
            .unwrap()
            .to_string();
        assert!(error.contains("must not be blank"));
        assert!(!missing.exists());
    }

    #[test]
    fn credential_selection_preserves_bytes_and_primary_precedence() {
        let primary = passphrase_from_values(
            Some(" primary with spaces ".into()),
            Some("different fallback".into()),
        )
        .unwrap();
        assert_eq!(primary.expose_secret(), " primary with spaces ");
        let fallback = passphrase_from_values(None, Some("fallback".into())).unwrap();
        assert_eq!(fallback.expose_secret(), "fallback");
    }

    #[test]
    fn empty_read_only_store_needs_no_credential_and_creates_nothing() {
        let directory = tempfile::tempdir().unwrap();
        assert!(load_sessions(directory.path().to_str().unwrap())
            .sessions
            .is_empty());
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
    }

    #[test]
    fn legacy_plaintext_is_retained_and_blocks_reads_and_writes() {
        let directory = tempfile::tempdir().unwrap();
        let data_dir = directory.path().to_str().unwrap();
        let legacy = serde_json::to_vec(&fixture_store()).unwrap();
        std::fs::write(sessions_path(data_dir), &legacy).unwrap();
        // A second encrypted file must not make a legacy credential disappear.
        let existing_encrypted = b"retained encrypted fixture";
        std::fs::write(sessions_enc_path(data_dir), existing_encrypted).unwrap();

        assert!(load_sessions(data_dir).sessions.is_empty());
        let error = save_sessions_with_passphrase(data_dir, &SessionStore::new(), "fixture-pass")
            .unwrap_err()
            .to_string();
        assert!(error.contains("explicit secure migration"));
        assert!(!error.contains("fixture-payment-credential"));
        assert_eq!(std::fs::read(sessions_path(data_dir)).unwrap(), legacy);
        assert_eq!(
            std::fs::read(sessions_enc_path(data_dir)).unwrap(),
            existing_encrypted
        );
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 2);
    }

    #[test]
    fn corrupt_store_cannot_be_replaced_with_an_empty_store() {
        let directory = tempfile::tempdir().unwrap();
        let data_dir = directory.path().to_str().unwrap();
        let corrupt = b"invalid encrypted session data";
        std::fs::write(sessions_enc_path(data_dir), corrupt).unwrap();
        assert!(
            save_sessions_with_passphrase(data_dir, &SessionStore::new(), "fixture-pass").is_err()
        );
        assert!(load_sessions(data_dir).sessions.is_empty());
        assert_eq!(std::fs::read(sessions_enc_path(data_dir)).unwrap(), corrupt);
        assert!(!sessions_path(data_dir).exists());
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[test]
    fn encrypted_roundtrip_and_wrong_credential_preserve_store() {
        let directory = tempfile::tempdir().unwrap();
        let data_dir = directory.path().to_str().unwrap();
        let store = fixture_store();
        save_sessions_with_passphrase(data_dir, &store, "fixture-correct-pass").unwrap();
        let original = std::fs::read(sessions_enc_path(data_dir)).unwrap();
        assert!(!original
            .windows(b"fixture-payment-credential".len())
            .any(|window| window == b"fixture-payment-credential"));
        let loaded = load_sessions_with_passphrase(data_dir, "fixture-correct-pass").unwrap();
        assert_eq!(loaded.store.sessions.len(), 1);
        assert_eq!(
            loaded.store.sessions[0].bearer_token,
            "fixture-payment-credential"
        );

        assert!(save_sessions_with_passphrase(
            data_dir,
            &SessionStore::new(),
            "fixture-wrong-pass"
        )
        .is_err());
        assert_eq!(
            std::fs::read(sessions_enc_path(data_dir)).unwrap(),
            original
        );
        assert!(!sessions_path(data_dir).exists());
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                std::fs::metadata(sessions_enc_path(data_dir))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }

    #[test]
    fn atomic_persist_retains_changed_store_and_cleans_temporary_file() {
        let directory = tempfile::tempdir().unwrap();
        let data_dir = directory.path().to_str().unwrap();
        let changed = b"concurrently changed encrypted fixture";
        std::fs::write(sessions_enc_path(data_dir), changed).unwrap();
        assert!(
            persist_encrypted_sessions(data_dir, b"replacement", Some(b"stale snapshot")).is_err()
        );
        assert_eq!(std::fs::read(sessions_enc_path(data_dir)).unwrap(), changed);
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);

        persist_encrypted_sessions(data_dir, b"replacement", Some(changed)).unwrap();
        assert_eq!(
            std::fs::read(sessions_enc_path(data_dir)).unwrap(),
            b"replacement"
        );
        assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 1);
    }

    #[cfg(unix)]
    #[test]
    fn encrypted_store_symlink_is_not_followed_or_replaced() {
        let directory = tempfile::tempdir().unwrap();
        let data_dir = directory.path().to_str().unwrap();
        let target = directory.path().join("outside-store");
        std::fs::write(&target, b"retain this fixture").unwrap();
        std::os::unix::fs::symlink(&target, sessions_enc_path(data_dir)).unwrap();
        assert!(save_sessions_with_passphrase(data_dir, &fixture_store(), "fixture-pass").is_err());
        assert_eq!(std::fs::read(&target).unwrap(), b"retain this fixture");
        assert!(std::fs::symlink_metadata(sessions_enc_path(data_dir))
            .unwrap()
            .file_type()
            .is_symlink());
    }

    #[test]
    fn session_store_operations() {
        let mut store = SessionStore::new();
        assert_eq!(store.sessions.len(), 0);

        let session = Session {
            session_id: "s1".into(),
            bearer_token: "tok1".into(),
            server_url: "https://api.example.com".into(),
            deposit_txid: "txid1".into(),
            balance_remaining: 100000,
            expires_at: "2026-04-01T00:00:00Z".into(),
            created_at: "2026-03-16T00:00:00Z".into(),
            cost_per_request: 1000,
        };

        store.add(session.clone());
        assert_eq!(store.sessions.len(), 1);
        assert!(store.find_for_server("https://api.example.com").is_some());
        assert!(store.find_for_server("https://other.com").is_none());
        assert!(store.find_by_id("s1").is_some());

        store.remove("s1");
        assert_eq!(store.sessions.len(), 0);
    }

    #[test]
    fn session_store_dedup() {
        let mut store = SessionStore::new();

        let s1 = Session {
            session_id: "s1".into(),
            bearer_token: "tok1".into(),
            server_url: "https://api.example.com".into(),
            deposit_txid: "txid1".into(),
            balance_remaining: 100000,
            expires_at: "2026-04-01T00:00:00Z".into(),
            created_at: "2026-03-16T00:00:00Z".into(),
            cost_per_request: 1000,
        };

        store.add(s1.clone());
        store.add(Session {
            bearer_token: "tok2".into(),
            ..s1
        });

        assert_eq!(store.sessions.len(), 1);
        assert_eq!(store.sessions[0].bearer_token, "tok2");
    }

    #[test]
    fn serialization_roundtrip() {
        let store = SessionStore {
            sessions: vec![Session {
                session_id: "s1".into(),
                bearer_token: "tok1".into(),
                server_url: "https://api.example.com".into(),
                deposit_txid: "txid1".into(),
                balance_remaining: 50000,
                expires_at: "2026-04-01T00:00:00Z".into(),
                created_at: "2026-03-16T00:00:00Z".into(),
                cost_per_request: 500,
            }],
        };

        let json = serde_json::to_string(&store).unwrap();
        let parsed: SessionStore = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.sessions.len(), 1);
        assert_eq!(parsed.sessions[0].session_id, "s1");
    }
}
