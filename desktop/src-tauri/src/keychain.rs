// Secrets live in a local owner-only (0600) file (secrets.json under
// ~/.oql/desktop); only redacted metadata indices live alongside it (keys.json
// / env-vars.json / connections.json). The raw value crosses the IPC boundary
// only on an explicit user reveal / copy. This module owns: API keys, scoped
// env-vars, and third-party connections.
//
// Secret store keys ("service\x01account"):
//   sh.workbooks.keys  / <id>        — provider API keys
//   sh.workbooks.env   / <id>        — user env-vars
//   sh.workbooks.conn  / <service>   — one connection per service
//
// SECURITY (wb-2s09): plaintext-at-rest behind 0600 + FileVault for now — the OS
// keychain was dropped because it prompted on every read (unusable, and broke
// credential forwarding). A future pass encrypts secrets.json at rest with a
// non-prompting key (machine-derived / the local did:key) — see wb-2s09 backlog.
//
// On save the desktop forwards the full secret set to the runtime's
// /internal/secrets/refresh so the engine's env-based loaders (OPENROUTER_API_KEY
// etc) see them; offline it's silently skipped.

use crate::paths;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::AppHandle;

const SVC_KEYS: &str = "sh.workbooks.keys";
const SVC_ENV: &str = "sh.workbooks.env";
const SVC_CONN: &str = "sh.workbooks.conn";

// Secrets live in a local, owner-only (0600) file under the app dir — NOT the
// OS keychain. The keychain made macOS prompt for a passkey on every read, and
// an unsigned/dev build isn't trusted so it nagged constantly AND failed to read
// (so forwarded creds came back empty). A 0600 file is the right local-first
// trade: single-user desktop, no prompts ever, reliable reads. No keychain at
// all — keys saved before this change must be re-entered once (they then live
// in the file and are forwarded to the runtime without a single prompt).

fn secrets_path() -> PathBuf {
    paths::oql_desktop_dir().join("secrets.json")
}

fn secrets_load() -> serde_json::Map<String, serde_json::Value> {
    std::fs::read_to_string(secrets_path())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn secrets_save(map: &serde_json::Map<String, serde_json::Value>) -> Result<(), String> {
    let path = secrets_path();
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    std::fs::write(&path, serde_json::to_string_pretty(map).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

fn sk(service: &str, account: &str) -> String {
    format!("{service}\u{1}{account}")
}

fn kc_set(service: &str, account: &str, value: &str) -> Result<(), String> {
    let mut m = secrets_load();
    m.insert(sk(service, account), serde_json::Value::String(value.to_string()));
    secrets_save(&m)
}

fn kc_get(service: &str, account: &str) -> Result<String, String> {
    match secrets_load().get(&sk(service, account)) {
        Some(serde_json::Value::String(v)) => Ok(v.clone()),
        _ => Err("no matching secret".to_string()),
    }
}

fn kc_delete(service: &str, account: &str) -> Result<(), String> {
    let mut m = secrets_load();
    m.remove(&sk(service, account));
    secrets_save(&m)
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
    // local_cli rows have no secret of ours; instead they advertise an ACP
    // agent to the runtime via WB_ACP_AGENTS.
    let conns: ConnIndex = paths::read_json(&conn_path());
    let mut acp_agents: Vec<&str> = Vec::new();
    for c in &conns.connections {
        if is_local_cli(c) {
            if let Some(agent) = acp_agent_name(&c.service) {
                if !acp_agents.contains(&agent) {
                    acp_agents.push(agent);
                }
            }
            continue;
        }
        if let Ok(v) = kc_get(SVC_CONN, &c.service) {
            env.insert(conn_env_var(&c.service), serde_json::Value::String(v));
        }
    }
    if !acp_agents.is_empty() {
        env.insert(
            "WB_ACP_AGENTS".into(),
            serde_json::Value::String(acp_agents.join(" ")),
        );
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

/// Frontend-triggered secret push — forward the user's keys into the live
/// runtime. Called when the runtime becomes healthy at app launch so Waldo
/// chat + voice work without the user re-saving a key or reconnecting.
#[tauri::command]
pub fn secrets_push() {
    refresh_runtime_secrets();
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
    // Backward-compatible local-CLI fields (existing connections.json predates
    // these and must still deserialize). `kind: Some("local_cli")` marks a row
    // whose auth lives in the CLI's own store — no keychain secret of ours.
    #[serde(default)]
    kind: Option<String>,
    #[serde(default)]
    path: Option<String>,
    #[serde(default)]
    version: Option<String>,
}

fn is_local_cli(row: &ConnRow) -> bool {
    row.kind.as_deref() == Some("local_cli")
}

/// Coding-agent service id → ACP agent name. Drives the runtime's `WB_ACP_AGENTS`.
fn acp_agent_name(service: &str) -> Option<&'static str> {
    match service {
        "codex" => Some("codex"),
        "claude_code" => Some("claude"),
        _ => None,
    }
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
    // local_cli rows store no secret of ours — auth lives in the CLI's own
    // store — so there's no key to measure and no env var name to surface.
    let (key_length, env_var_name) = if is_local_cli(row) {
        (0, "—".to_string())
    } else {
        (
            kc_get(SVC_CONN, &row.service).map(|v| v.len()).unwrap_or(0),
            conn_env_var(&row.service),
        )
    };
    ConnectionRedacted {
        id: row.id.clone(),
        service: row.service.clone(),
        account_label: row.account_label.clone(),
        dashboard_url: conn_dashboard_url(&row.service),
        env_var_name,
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
        kind: None,
        path: None,
        version: None,
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
        // local_cli rows have no stored secret — nothing to delete from the store.
        if !is_local_cli(row) {
            let svc = row.service.clone();
            kc_delete(SVC_CONN, &svc)?;
        }
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

// ── Local-CLI connections (ACP coding agents) ─────────────────────
//
// Some "connections" aren't a pasted API key — they're a CLI already installed
// on the user's machine (claude, codex). The connect flow detects the binary on
// PATH and persists its resolved path; auth stays in the CLI's own store
// (~/.codex, ~/.claude, OS keychain). No secret of ours is stored.

/// Result of probing for a local CLI. Field names mirror the frontend `Probe`
/// type exactly (found/path/version/error) — do NOT rename_all.
#[derive(Serialize)]
pub struct CliProbe {
    found: bool,
    path: Option<String>,
    version: Option<String>,
    error: Option<String>,
}

/// Extra dirs a GUI app's minimal PATH commonly misses. A Tauri app inherits a
/// sparse PATH (no shell rc), so codex (/opt/homebrew/bin) and claude
/// (~/.local/bin) won't be found by $PATH alone.
fn extra_cli_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(&home).join(".local/bin"));
    }
    for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
        dirs.push(PathBuf::from(d));
    }
    dirs
}

/// Resolve `name` to an executable: scan $PATH first, then the extra GUI-missed dirs.
fn resolve_cli(name: &str) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            candidates.push(dir.join(name));
        }
    }
    for dir in extra_cli_dirs() {
        candidates.push(dir.join(name));
    }
    candidates.into_iter().find(|p| is_executable(p))
}

fn is_executable(p: &std::path::Path) -> bool {
    let Ok(meta) = std::fs::metadata(p) else {
        return false;
    };
    if !meta.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        return meta.permissions().mode() & 0o111 != 0;
    }
    #[cfg(not(unix))]
    {
        true
    }
}

/// Detect a local CLI on PATH (+ common GUI-missed dirs) and read its version.
#[tauri::command]
pub fn connections_detect_local_cli(name: String) -> CliProbe {
    let Some(path) = resolve_cli(&name) else {
        return CliProbe {
            found: false,
            path: None,
            version: None,
            error: Some(format!(
                "`{name}` not found on PATH or in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin, /usr/bin, /bin"
            )),
        };
    };
    let path_str = path.to_string_lossy().to_string();
    // Run `<path> --version` with a ~3s budget; a missing version doesn't
    // un-find the binary — found stays true.
    let version = cli_version(&path);
    CliProbe {
        found: true,
        path: Some(path_str),
        version,
        error: None,
    }
}

/// Run `<path> --version` with a ~3s timeout; trimmed stdout, or None on any failure.
fn cli_version(path: &std::path::Path) -> Option<String> {
    use std::process::{Command, Stdio};
    use std::sync::mpsc;

    let path = path.to_path_buf();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let out = Command::new(&path)
            .arg("--version")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output();
        let _ = tx.send(out);
    });
    match rx.recv_timeout(std::time::Duration::from_secs(3)) {
        Ok(Ok(out)) if out.status.success() => {
            let v = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if v.is_empty() {
                None
            } else {
                Some(v)
            }
        }
        _ => None,
    }
}

#[derive(Deserialize)]
pub struct LocalCliCreate {
    pub service: String,
    pub path: Option<String>,
    pub version: Option<String>,
}

/// Persist a local-CLI connection. No keychain secret — auth is the CLI's own.
/// One per service; surfaces the version as the account label.
#[tauri::command]
pub fn connections_create_local_cli(req: LocalCliCreate) -> Result<ConnectionRedacted, String> {
    let mut idx: ConnIndex = paths::read_json(&conn_path());
    idx.connections.retain(|c| c.service != req.service);
    let row = ConnRow {
        id: uuid::Uuid::new_v4().to_string(),
        service: req.service,
        account_label: req.version.clone(),
        created_at: paths::now_ms(),
        kind: Some("local_cli".to_string()),
        path: req.path,
        version: req.version,
    };
    idx.connections.push(row.clone());
    paths::write_json(&conn_path(), &idx)?;
    refresh_runtime_secrets();
    Ok(redact_conn(&row))
}

// ── Harness subscription-creds store (SLICE 3, wb-b9xv.7) ──────────────────────────────────────
//
// The host half of `dock.creds.{get,put}` for the in-wasm harness. The harness owns its OWN OAuth
// state machine and writes an opaque creds bundle (e.g. ~/.claude/.credentials.json contents); the SM
// node-shim intercepts that store read/write and maps it onto these commands, so the harness's own store
// hits the desktop credential store instead of the KV-VFS.
//
// DESKTOP-FIRST + BYO + NO-POOL: the value is the USER'S subscription token. It is stored verbatim
// (never parsed), scoped per-(user, provider), and lives ONLY in the user's trust domain. It is never
// pooled/proxied and never registered as one of our platform secrets (that is the separate API-key path).
// Per-provider service names (`sh.workbooks.harness.<provider>`) parallel SVC_CONN and reduce repeat
// keychain prompts (risk #6). Backed by the SAME kc_set/kc_get/kc_delete as connections (the 0600 file
// store today, wb-2s09; a future pass swaps in the OS keychain once it stops prompting on every read).
const SVC_HARNESS_PREFIX: &str = "sh.workbooks.harness.";

fn harness_service(provider: &str) -> String {
    format!("{SVC_HARNESS_PREFIX}{provider}")
}

/// Read the opaque creds blob for (user, provider). Returns the blob string, or
/// `None` when nothing is stored yet (first sign-in). The runtime calls this over
/// the desktop bridge; account = the user id so one user's blob is never another's.
#[tauri::command]
pub fn harness_creds_get(user: String, provider: String) -> Result<Option<String>, String> {
    match kc_get(&harness_service(&provider), &user) {
        Ok(v) => Ok(Some(v)),
        Err(_) => Ok(None),
    }
}

/// Store the opaque creds blob for (user, provider), overwriting any prior. The
/// blob is written verbatim — never parsed/decoded; it is the user's subscription token.
#[tauri::command]
pub fn harness_creds_put(user: String, provider: String, blob: String) -> Result<(), String> {
    kc_set(&harness_service(&provider), &user, &blob)
}

/// Delete the blob for (user, provider) (sign-out).
#[tauri::command]
pub fn harness_creds_delete(user: String, provider: String) -> Result<(), String> {
    kc_delete(&harness_service(&provider), &user)
}
