// Secrets live in the OS keychain; only redacted metadata indices live on disk
// (keys.json / env-vars.json / connections.json under ~/.oql/desktop). The raw
// value crosses the IPC boundary only on an explicit user reveal / copy. This
// module owns: API keys, scoped env-vars, and third-party connections.
//
// Keychain services (Entry(service, account)):
//   sh.workbooks.keys  / <id>        — provider API keys
//   sh.workbooks.env   / <id>        — user env-vars
//   sh.workbooks.conn  / <service>   — one connection per service
//
// A best-effort POST to the runtime's /internal/secrets/refresh nudges a live
// daemon to re-read env without a restart; offline it's silently skipped.

use crate::paths;
use keyring::Entry;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::AppHandle;

const SVC_KEYS: &str = "sh.workbooks.keys";
const SVC_ENV: &str = "sh.workbooks.env";
const SVC_CONN: &str = "sh.workbooks.conn";

fn entry(service: &str, account: &str) -> Result<Entry, String> {
    Entry::new(service, account).map_err(|e| e.to_string())
}

fn kc_set(service: &str, account: &str, value: &str) -> Result<(), String> {
    entry(service, account)?
        .set_password(value)
        .map_err(|e| e.to_string())
}

fn kc_get(service: &str, account: &str) -> Result<String, String> {
    entry(service, account)?
        .get_password()
        .map_err(|e| e.to_string())
}

fn kc_delete(service: &str, account: &str) -> Result<(), String> {
    match entry(service, account)?.delete_credential() {
        Ok(_) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

fn mask() -> String {
    "•".repeat(8)
}

/// Forward the user's secrets into the live runtime's process ENV. The runtime
/// — especially containerized — can't read the host keychain, but its host-side
/// loaders pull creds from ENV (e.g. llm.ex reads OPENROUTER_API_KEY). So we
/// gather every model key, connection, and env-var, resolve its env-var name,
/// and POST the values to /internal/secrets/refresh (token-auth'd). Best-effort:
/// offline / no daemon → silent no-op; never fails the calling command.
pub fn refresh_runtime_secrets() {
    let Some(d) = crate::daemon::Discovery::read() else {
        return;
    };

    let mut env = serde_json::Map::new();

    // Model keys (OpenRouter, …) — keyed by provider's env-var name.
    let keys: KeyIndex = paths::read_json(&keys_path());
    for k in &keys.keys {
        if let Some(name) = provider_env_var(&k.provider, k.custom_provider.as_deref()) {
            if let Ok(v) = kc_get(SVC_KEYS, &k.id) {
                env.insert(name, serde_json::Value::String(v));
            }
        }
    }
    // Third-party connections (Gemini, …) — keyed by service's env-var name.
    let conns: ConnIndex = paths::read_json(&conn_path());
    for c in &conns.connections {
        if let Ok(v) = kc_get(SVC_CONN, &c.service) {
            env.insert(conn_env_var(&c.service), serde_json::Value::String(v));
        }
    }
    // User-scoped env vars — forwarded verbatim by name.
    let envs: EnvIndex = paths::read_json(&env_path());
    for e in &envs.vars {
        if let Ok(v) = kc_get(SVC_ENV, &e.id) {
            env.insert(e.name.clone(), serde_json::Value::String(v));
        }
    }

    let body = serde_json::json!({ "env": env });
    let url = format!("http://127.0.0.1:{}/internal/secrets/refresh", d.port);
    let _ = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(2))
        .build()
        .and_then(|c| c.post(url).bearer_auth(&d.token).json(&body).send());
}

// ── API keys ──────────────────────────────────────────────────────

fn keys_path() -> PathBuf {
    paths::oql_desktop_dir().join("keys.json")
}

#[derive(Serialize, Deserialize, Clone)]
struct KeyRow {
    id: String,
    name: String,
    provider: String,
    custom_provider: Option<String>,
    created_at: u64,
}

#[derive(Serialize, Deserialize, Default)]
struct KeyIndex {
    keys: Vec<KeyRow>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ApiKeyRedacted {
    pub id: String,
    pub name: String,
    pub provider: String,
    pub custom_provider: Option<String>,
    pub created_at: u64,
    pub masked: String,
    pub length: usize,
}

#[derive(Deserialize)]
pub struct KeyCreate {
    pub name: String,
    pub provider: String,
    pub custom_provider: Option<String>,
    pub value: String,
}

fn redact_key(row: &KeyRow) -> ApiKeyRedacted {
    let length = kc_get(SVC_KEYS, &row.id).map(|v| v.len()).unwrap_or(0);
    ApiKeyRedacted {
        id: row.id.clone(),
        name: row.name.clone(),
        provider: row.provider.clone(),
        custom_provider: row.custom_provider.clone(),
        created_at: row.created_at,
        masked: mask(),
        length,
    }
}

/// provider id → env var name (mirror of the TS `providerEnvVar`).
pub fn provider_env_var(provider: &str, custom: Option<&str>) -> Option<String> {
    let v = match provider {
        "openrouter" => "OPENROUTER_API_KEY",
        "anthropic" => "ANTHROPIC_API_KEY",
        "openai" => "OPENAI_API_KEY",
        "google" => "GOOGLE_API_KEY",
        "mistral" => "MISTRAL_API_KEY",
        "together" => "TOGETHER_API_KEY",
        "groq" => "GROQ_API_KEY",
        "cerebras" => "CEREBRAS_API_KEY",
        "xai" => "XAI_API_KEY",
        "sambanova" => "SAMBANOVA_API_KEY",
        "fireworks" => "FIREWORKS_API_KEY",
        "custom" => {
            let c = custom?.trim();
            if c.is_empty() {
                return None;
            }
            return Some(format!("{}_API_KEY", c.to_uppercase()));
        }
        _ => return None,
    };
    Some(v.to_string())
}

#[tauri::command]
pub fn keys_list() -> Vec<ApiKeyRedacted> {
    let idx: KeyIndex = paths::read_json(&keys_path());
    idx.keys.iter().map(redact_key).collect()
}

#[tauri::command]
pub fn keys_known_providers() -> Vec<String> {
    [
        "openrouter",
        "anthropic",
        "openai",
        "google",
        "mistral",
        "together",
        "groq",
        "cerebras",
        "xai",
        "sambanova",
        "fireworks",
        "custom",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect()
}

/// Shared by keys_create + setup_save_model_key.
pub fn insert_key(req: KeyCreate) -> Result<ApiKeyRedacted, String> {
    let mut idx: KeyIndex = paths::read_json(&keys_path());
    let id = uuid::Uuid::new_v4().to_string();
    kc_set(SVC_KEYS, &id, &req.value)?;
    let row = KeyRow {
        id,
        name: req.name,
        provider: req.provider,
        custom_provider: req.custom_provider,
        created_at: paths::now_ms(),
    };
    idx.keys.push(row.clone());
    paths::write_json(&keys_path(), &idx)?;
    refresh_runtime_secrets();
    Ok(redact_key(&row))
}

#[tauri::command]
pub fn keys_create(req: KeyCreate) -> Result<ApiKeyRedacted, String> {
    insert_key(req)
}

#[derive(Deserialize)]
pub struct KeyRename {
    pub id: String,
    pub name: String,
}

#[tauri::command]
pub fn keys_rename(req: KeyRename) -> Result<(), String> {
    let mut idx: KeyIndex = paths::read_json(&keys_path());
    if let Some(k) = idx.keys.iter_mut().find(|k| k.id == req.id) {
        k.name = req.name;
    }
    paths::write_json(&keys_path(), &idx)
}

#[tauri::command]
pub fn keys_delete(id: String) -> Result<(), String> {
    let mut idx: KeyIndex = paths::read_json(&keys_path());
    idx.keys.retain(|k| k.id != id);
    kc_delete(SVC_KEYS, &id)?;
    paths::write_json(&keys_path(), &idx)?;
    refresh_runtime_secrets();
    Ok(())
}

#[tauri::command]
pub fn keys_reveal(id: String) -> Result<String, String> {
    kc_get(SVC_KEYS, &id)
}

#[tauri::command]
pub fn keys_copy_to_clipboard(app: AppHandle, id: String) -> Result<(), String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;
    let v = kc_get(SVC_KEYS, &id)?;
    app.clipboard().write_text(v).map_err(|e| e.to_string())
}

// ── Env vars ──────────────────────────────────────────────────────

fn env_path() -> PathBuf {
    paths::oql_desktop_dir().join("env-vars.json")
}

#[derive(Serialize, Deserialize, Clone)]
struct EnvRow {
    id: String,
    name: String,
    scope: String,
    workspace_id: Option<String>,
    package_name: Option<String>,
    created_at: u64,
}

#[derive(Serialize, Deserialize, Default)]
struct EnvIndex {
    vars: Vec<EnvRow>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvVarRedacted {
    pub id: String,
    pub name: String,
    pub scope: String,
    pub workspace_id: Option<String>,
    pub package_name: Option<String>,
    pub created_at: u64,
    pub masked: String,
    pub length: usize,
}

#[derive(Deserialize)]
pub struct EnvVarCreate {
    pub name: String,
    pub value: String,
    pub scope: String,
    pub workspace_id: Option<String>,
    pub package_name: Option<String>,
}

fn redact_env(row: &EnvRow) -> EnvVarRedacted {
    let length = kc_get(SVC_ENV, &row.id).map(|v| v.len()).unwrap_or(0);
    EnvVarRedacted {
        id: row.id.clone(),
        name: row.name.clone(),
        scope: row.scope.clone(),
        workspace_id: row.workspace_id.clone(),
        package_name: row.package_name.clone(),
        created_at: row.created_at,
        masked: mask(),
        length,
    }
}

#[tauri::command]
pub fn env_vars_list() -> Vec<EnvVarRedacted> {
    let idx: EnvIndex = paths::read_json(&env_path());
    idx.vars.iter().map(redact_env).collect()
}

fn insert_env(req: EnvVarCreate) -> Result<EnvVarRedacted, String> {
    let mut idx: EnvIndex = paths::read_json(&env_path());
    let id = uuid::Uuid::new_v4().to_string();
    kc_set(SVC_ENV, &id, &req.value)?;
    let row = EnvRow {
        id,
        name: req.name,
        scope: req.scope,
        workspace_id: req.workspace_id,
        package_name: req.package_name,
        created_at: paths::now_ms(),
    };
    idx.vars.push(row.clone());
    paths::write_json(&env_path(), &idx)?;
    Ok(redact_env(&row))
}

#[tauri::command]
pub fn env_vars_create(req: EnvVarCreate) -> Result<EnvVarRedacted, String> {
    let v = insert_env(req)?;
    refresh_runtime_secrets();
    Ok(v)
}

#[derive(Deserialize)]
pub struct EnvVarUpdate {
    pub id: String,
    pub value: String,
}

#[tauri::command]
pub fn env_vars_update(req: EnvVarUpdate) -> Result<(), String> {
    kc_set(SVC_ENV, &req.id, &req.value)?;
    refresh_runtime_secrets();
    Ok(())
}

#[tauri::command]
pub fn env_vars_delete(id: String) -> Result<(), String> {
    let mut idx: EnvIndex = paths::read_json(&env_path());
    idx.vars.retain(|v| v.id != id);
    kc_delete(SVC_ENV, &id)?;
    paths::write_json(&env_path(), &idx)?;
    refresh_runtime_secrets();
    Ok(())
}

#[tauri::command]
pub fn env_vars_copy_to_clipboard(app: AppHandle, id: String) -> Result<(), String> {
    use tauri_plugin_clipboard_manager::ClipboardExt;
    let v = kc_get(SVC_ENV, &id)?;
    app.clipboard().write_text(v).map_err(|e| e.to_string())
}

#[derive(Deserialize)]
pub struct BulkImportRequest {
    pub text: String,
    pub scope: String,
    pub workspace_id: Option<String>,
    pub package_name: Option<String>,
}

#[derive(Serialize)]
pub struct BulkImportResult {
    pub imported: Vec<EnvVarRedacted>,
    pub skipped: Vec<String>,
}

#[tauri::command]
pub fn env_vars_bulk_import(req: BulkImportRequest) -> Result<BulkImportResult, String> {
    let existing: EnvIndex = paths::read_json(&env_path());
    let mut seen: std::collections::HashSet<String> =
        existing.vars.iter().map(|v| v.name.clone()).collect();
    let mut imported = Vec::new();
    let mut skipped = Vec::new();
    for line in req.text.lines() {
        let t = line.trim();
        if t.is_empty() || t.starts_with('#') {
            continue;
        }
        let Some((k, v)) = t.split_once('=') else {
            continue;
        };
        let name = k.trim().to_string();
        let value = v.trim().trim_matches('"').to_string();
        if name.is_empty() || seen.contains(&name) {
            if !name.is_empty() {
                skipped.push(name);
            }
            continue;
        }
        seen.insert(name.clone());
        let red = insert_env(EnvVarCreate {
            name,
            value,
            scope: req.scope.clone(),
            workspace_id: req.workspace_id.clone(),
            package_name: req.package_name.clone(),
        })?;
        imported.push(red);
    }
    refresh_runtime_secrets();
    Ok(BulkImportResult { imported, skipped })
}

// ── Connections ───────────────────────────────────────────────────

fn conn_path() -> PathBuf {
    paths::oql_desktop_dir().join("connections.json")
}

#[derive(Serialize, Deserialize, Clone)]
struct ConnRow {
    id: String,
    service: String,
    account_label: Option<String>,
    created_at: u64,
}

#[derive(Serialize, Deserialize, Default)]
struct ConnIndex {
    connections: Vec<ConnRow>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionRedacted {
    pub id: String,
    pub service: String,
    pub account_label: Option<String>,
    pub dashboard_url: String,
    pub env_var_name: String,
    pub created_at: u64,
    pub key_length: usize,
}

#[derive(Deserialize)]
pub struct ConnectionCreate {
    pub service: String,
    pub api_key: String,
    pub account_label: Option<String>,
}

fn conn_env_var(service: &str) -> String {
    match service {
        "composio" => "COMPOSIO_API_KEY",
        "doppler" => "DOPPLER_TOKEN",
        "github" => "GITHUB_TOKEN",
        "meta" => "META_ACCESS_TOKEN",
        "open_router" => "OPENROUTER_API_KEY",
        "fal" => "FAL_KEY",
        "gemini" => "GEMINI_API_KEY",
        other => return format!("{}_API_KEY", other.to_uppercase()),
    }
    .to_string()
}

fn conn_dashboard_url(service: &str) -> String {
    match service {
        "composio" => "https://app.composio.dev",
        "doppler" => "https://dashboard.doppler.com",
        "github" => "https://github.com/settings/tokens",
        "open_router" => "https://openrouter.ai/keys",
        "fal" => "https://fal.ai/dashboard/keys",
        "gemini" => "https://aistudio.google.com/apikey",
        _ => "",
    }
    .to_string()
}

fn redact_conn(row: &ConnRow) -> ConnectionRedacted {
    let key_length = kc_get(SVC_CONN, &row.service).map(|v| v.len()).unwrap_or(0);
    ConnectionRedacted {
        id: row.id.clone(),
        service: row.service.clone(),
        account_label: row.account_label.clone(),
        dashboard_url: conn_dashboard_url(&row.service),
        env_var_name: conn_env_var(&row.service),
        created_at: row.created_at,
        key_length,
    }
}

#[tauri::command]
pub fn connections_list() -> Vec<ConnectionRedacted> {
    let idx: ConnIndex = paths::read_json(&conn_path());
    idx.connections.iter().map(redact_conn).collect()
}

#[tauri::command]
pub fn connections_create(req: ConnectionCreate) -> Result<ConnectionRedacted, String> {
    let mut idx: ConnIndex = paths::read_json(&conn_path());
    // One connection per service — replace any prior.
    idx.connections.retain(|c| c.service != req.service);
    kc_set(SVC_CONN, &req.service, &req.api_key)?;
    let row = ConnRow {
        id: uuid::Uuid::new_v4().to_string(),
        service: req.service,
        account_label: req.account_label,
        created_at: paths::now_ms(),
    };
    idx.connections.push(row.clone());
    paths::write_json(&conn_path(), &idx)?;
    refresh_runtime_secrets();
    Ok(redact_conn(&row))
}

#[tauri::command]
pub fn connections_delete(id: String) -> Result<(), String> {
    let mut idx: ConnIndex = paths::read_json(&conn_path());
    if let Some(row) = idx.connections.iter().find(|c| c.id == id) {
        let svc = row.service.clone();
        kc_delete(SVC_CONN, &svc)?;
    }
    idx.connections.retain(|c| c.id != id);
    paths::write_json(&conn_path(), &idx)
}

/// Reveal a connection's raw API key by service id. For the gemini-live
/// renderer WS — NEVER routed through the runtime.
#[tauri::command]
pub fn connections_reveal_api_key(service: String) -> Result<String, String> {
    kc_get(SVC_CONN, &service)
}
