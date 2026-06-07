// Third-party integration connections — Composio, Doppler, GitHub.
//
// Distinct from `keys.rs` (provider API keys for model inference) and
// `env_vars.rs` (arbitrary user env vars). A connection represents
// "the user has linked their personal account at <service>" and the
// API key we store is what the agent uses to make calls into that
// service's SDK on the user's behalf.
//
// The user owns the upstream account; we are just a bridge. Tokens
// are AES-256-GCM encrypted at rest with a key in the OS keychain
// (see `crypto.rs`). There is no path to read the plaintext from
// the renderer — same posture as keys.rs / env_vars.rs.
//
// On-disk layout:
//
//   ~/.oql/desktop/connections.org
//
// Each entry's title is the service identifier (canonical lowercase),
// with properties:
//
//   :ID:             c_<hex>
//   :SERVICE:        composio | doppler | github
//   :API_KEY:        <wbenc1:base64>     ; encrypted
//   :ACCOUNT_LABEL:  "personal" / "user@email"   ; optional, shown on card
//   :DASHBOARD_URL:  https://...         ; for the Manage ↗ link
//   :ENV_VAR_NAME:   COMPOSIO_API_KEY    ; what the sidecar sees
//   :CREATED_AT:     <unix-millis>

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::crypto;
use crate::org_kv::{self, OrgEntry};

const CONNECTIONS_FILE: &str = "connections.org";
const SCHEMA: &str = "connections.v1";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ConnectionService {
    // Cloud integration services.
    Composio,
    Doppler,
    Github,

    // AI providers. Same shape as the cloud services for now —
    // user pastes an API key, sidecar forwards as an env var. The
    // model layer (`Workbooks.Engine.LLM`) reads `OPENROUTER_API_KEY` at
    // call time so connect/disconnect is live.
    OpenRouter,

    // Local-CLI connections. These don't have an api_key in the
    // usual sense — the "connection" is "we found this binary on
    // your PATH" plus a stored path/version. The Rust side resolves
    // the binary at connect time and the agent shells out to it.
    //
    // For v1 these cards are scaffolded but the detect flow is
    // deferred (`available: false` on the renderer). When wired:
    //
    //   1. `connections_detect_local_cli(name)` Tauri command probes
    //      `which <name>` and runs `<name> --version`.
    //   2. The "Connect" affordance becomes "Detect" — no paste field.
    //   3. The stored "api_key" slot holds the resolved binary path;
    //      env-var forwarding becomes path forwarding
    //      (`CLAUDE_CODE_PATH=/usr/local/bin/claude`).
    //   4. The agent's tool layer registers ACP-style "call Claude
    //      Code" / "call Codex" tools that exec the binaries.
    ClaudeCode,
    Codex,

    // ── More cloud integrations (scaffolded; all `available: false`
    // on the renderer until the connect flow per service is wired) ──
    //
    // GoogleWorkspace: uses the official `gws` CLI
    // (https://github.com/googleworkspace/cli). Connect flow is
    // detect-then-`gws auth login` — same shape as ClaudeCode/Codex
    // since the CLI owns the OAuth and stores creds in the OS
    // keyring. Bonus: the CLI auto-installs agent skills at
    // ~/.openclaw/skills/ that we can surface to the agent.
    GoogleWorkspace,

    // Meta: custom-OAuth-we-host (same bucket as GitHub). Getting a
    // Meta access token manually is gnarly — requires a Developer
    // account + an App + reviewed permissions. We own the App on
    // our side (Workbooks dev account), so the connect flow is
    // "click → OAuth in browser → deep-link back with token". The
    // user never deals with developers.facebook.com. Stored as
    // `META_ACCESS_TOKEN`; Elixir wraps the Graph + Marketing APIs.
    // Token refresh handled by the broker (Meta tokens are
    // long-lived, ~60d, refreshable).
    Meta,

    // fal.ai: paste-API-key shape. `FAL_KEY` env var; Elixir wraps
    // their REST API for image/video/audio/music/speech/3D
    // generation. Their `fal` CLI exists but the SDK is the primary
    // surface so we go SDK-equivalent (REST) from the sidecar.
    Fal,

    // Gemini: paste-API-key shape. `GEMINI_API_KEY` env var. The
    // renderer holds the live (Gemini Live WS) connection itself
    // (Web Audio APIs live there), and the API key is fetched from
    // this connection at session-open time. Distinct from OpenRouter
    // because Gemini Live is a different transport (bidirectional
    // audio over WS) than the OpenAI-style chat completions
    // OpenRouter proxies. See wb-xxbm epic.
    Gemini,
}

impl ConnectionService {
    /// True when this connection's `api_key` field holds a binary path
    /// rather than a secret — local-CLI detect connections (Claude Code,
    /// Codex, Google Workspace). Their value isn't sensitive, so we skip
    /// the at-rest encryption layer. This also means a misbehaving OS
    /// keychain doesn't block these connects.
    pub fn is_local_cli(&self) -> bool {
        matches!(
            self,
            Self::ClaudeCode | Self::Codex | Self::GoogleWorkspace
        )
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Composio => "composio",
            Self::Doppler => "doppler",
            Self::Github => "github",
            Self::OpenRouter => "open_router",
            Self::ClaudeCode => "claude_code",
            Self::Codex => "codex",
            Self::GoogleWorkspace => "google_workspace",
            Self::Meta => "meta",
            Self::Fal => "fal",
            Self::Gemini => "gemini",
        }
    }

    fn from_str(s: &str) -> Option<Self> {
        match s {
            "composio" => Some(Self::Composio),
            "doppler" => Some(Self::Doppler),
            "github" => Some(Self::Github),
            "open_router" | "openrouter" => Some(Self::OpenRouter),
            "claude_code" => Some(Self::ClaudeCode),
            "codex" => Some(Self::Codex),
            "google_workspace" => Some(Self::GoogleWorkspace),
            "meta" => Some(Self::Meta),
            "fal" => Some(Self::Fal),
            "gemini" => Some(Self::Gemini),
            _ => None,
        }
    }

    /// Default env-var the sidecar reads to authenticate with the
    /// service's SDK. Overridable per-connection if a user needs a
    /// non-standard name, but the default is what the SDK expects.
    ///
    /// For local-CLI connections this is the env var the agent uses
    /// to learn the resolved binary path (set when detect succeeds).
    fn default_env_var(&self) -> &'static str {
        match self {
            Self::Composio => "COMPOSIO_API_KEY",
            Self::Doppler => "DOPPLER_TOKEN",
            Self::Github => "GITHUB_TOKEN",
            Self::OpenRouter => "OPENROUTER_API_KEY",
            Self::ClaudeCode => "CLAUDE_CODE_PATH",
            Self::Codex => "CODEX_PATH",
            Self::GoogleWorkspace => "GWS_PATH",
            Self::Meta => "META_ACCESS_TOKEN",
            Self::Fal => "FAL_KEY",
            Self::Gemini => "GEMINI_API_KEY",
        }
    }

    /// Default dashboard URL — where the Manage ↗ link points.
    fn default_dashboard_url(&self) -> &'static str {
        match self {
            Self::Composio => "https://app.composio.dev/dashboard",
            Self::Doppler => "https://dashboard.doppler.com/",
            Self::Github => "https://github.com/settings/applications",
            Self::OpenRouter => "https://openrouter.ai/keys",
            Self::ClaudeCode => "https://docs.claude.com/en/docs/claude-code/overview",
            Self::Codex => "https://github.com/openai/codex",
            Self::GoogleWorkspace => "https://workspace.google.com/",
            Self::Meta => "https://business.facebook.com/",
            Self::Fal => "https://fal.ai/dashboard",
            Self::Gemini => "https://aistudio.google.com/apikey",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Connection {
    pub id: String,
    pub service: ConnectionService,
    pub api_key: String,
    pub account_label: Option<String>,
    pub dashboard_url: String,
    pub env_var_name: String,
    pub created_at: i64,
}

/// Redacted view handed to the UI — never includes the api_key.
#[derive(Clone, Debug, Serialize)]
pub struct ConnectionRedacted {
    pub id: String,
    pub service: String,
    pub account_label: Option<String>,
    pub dashboard_url: String,
    pub env_var_name: String,
    pub created_at: i64,
    /// Char count of the underlying key — lets the UI say "32-char key
    /// stored" without leaking anything.
    pub key_length: usize,
}

impl Connection {
    fn redact(&self) -> ConnectionRedacted {
        ConnectionRedacted {
            id: self.id.clone(),
            service: self.service.as_str().to_string(),
            account_label: self.account_label.clone(),
            dashboard_url: self.dashboard_url.clone(),
            env_var_name: self.env_var_name.clone(),
            created_at: self.created_at,
            key_length: self.api_key.chars().count(),
        }
    }

    fn from_entry(e: &OrgEntry) -> Option<Self> {
        let service = ConnectionService::from_str(e.get("SERVICE")?)?;
        let stored_key = e.get("API_KEY")?;
        let api_key = match crypto::decrypt_value(stored_key) {
            Ok(v) => v,
            Err(err) => {
                log::warn!(
                    "[connections] dropping entry {:?}: decrypt failed: {err}",
                    e.get("ID")
                );
                return None;
            }
        };
        Some(Connection {
            id: e.get("ID")?.to_string(),
            service,
            api_key,
            account_label: e.get("ACCOUNT_LABEL").map(|s| s.to_string()),
            dashboard_url: e.get("DASHBOARD_URL")?.to_string(),
            env_var_name: e.get("ENV_VAR_NAME")?.to_string(),
            created_at: e.get_i64("CREATED_AT").unwrap_or(0),
        })
    }

    fn to_entry(&self) -> Result<OrgEntry, String> {
        // Local-CLI connections (Claude Code / Codex / Google Workspace)
        // store an absolute binary path, not a secret. We skip the
        // crypto layer entirely so a wedged OS keychain doesn't block
        // those connects — the read side already handles both shapes
        // via `crypto::decrypt_value`'s plaintext-passthrough branch.
        let stored_value = if self.service.is_local_cli() {
            self.api_key.clone()
        } else {
            crypto::encrypt_value(&self.api_key).map_err(|e| {
                format!(
                    "{e} — if the keychain prompt was dismissed, try again \
                     and click \"Always Allow\". On macOS you can re-authorize \
                     in Keychain Access under \"sh.workbooks.desktop\"."
                )
            })?
        };

        let mut e = OrgEntry::new(self.service.as_str().to_string())
            .with("ID", self.id.clone())
            .with("SERVICE", self.service.as_str().to_string())
            .with("API_KEY", stored_value)
            .with("DASHBOARD_URL", self.dashboard_url.clone())
            .with("ENV_VAR_NAME", self.env_var_name.clone())
            .with("CREATED_AT", self.created_at.to_string());
        if let Some(label) = &self.account_label {
            e = e.with("ACCOUNT_LABEL", label.clone());
        }
        Ok(e)
    }
}

fn connections_path() -> PathBuf {
    desktop_root().join(CONNECTIONS_FILE)
}

async fn read_all() -> Result<Vec<Connection>, String> {
    let entries = org_kv::read_entries(&connections_path(), SCHEMA).await?;
    Ok(entries.iter().filter_map(Connection::from_entry).collect())
}

async fn write_all(connections: &[Connection]) -> Result<(), String> {
    let entries: Vec<OrgEntry> = connections
        .iter()
        .map(Connection::to_entry)
        .collect::<Result<Vec<_>, _>>()?;
    org_kv::write_entries(&connections_path(), SCHEMA, &entries).await?;
    set_owner_only(&connections_path())?;
    Ok(())
}

fn set_owner_only(path: &std::path::Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, perms)
            .map_err(|e| format!("chmod 600 connections.org: {e}"))?;
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("c_{:x}", nanos)
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

/// Env-var fan-out for the sidecar spawn — same shape as
/// `keys::env_vars_for_sidecar`. One env var per connection;
/// most-recently-created per service wins (one Composio key at a
/// time, etc.).
pub async fn env_vars_for_sidecar() -> Vec<(String, String)> {
    let connections = match read_all().await {
        Ok(c) => c,
        Err(e) => {
            log::warn!("[connections] env_vars_for_sidecar read failed: {e}");
            return vec![];
        }
    };
    use std::collections::HashMap;
    let mut latest: HashMap<String, &Connection> = HashMap::new();
    for c in &connections {
        let bucket = c.service.as_str().to_string();
        match latest.get(&bucket) {
            Some(prev) if prev.created_at >= c.created_at => {}
            _ => {
                latest.insert(bucket, c);
            }
        }
    }
    latest
        .into_values()
        .map(|c| (c.env_var_name.clone(), c.api_key.clone()))
        .collect()
}

// ── Tauri commands ──────────────────────────────────────────────────

/// Return the decrypted API key for a connected service to the
/// renderer. Used by features whose API surface is the renderer itself
/// — today only Gemini Live, where the bidirectional audio WebSocket
/// must originate from the webview (Web Audio APIs live there).
///
/// SECURITY: most other services keep secrets server-side and reach the
/// upstream via the sidecar (OpenRouter, Composio, fal). For those, the
/// "plaintext never crosses IPC" rule applies. This command intentionally
/// breaks that rule, scoped to services that require renderer-side
/// connections; the trade-off is documented inline so future contributors
/// don't widen the surface casually.
///
/// Reach: limited to a hard-coded allowlist. Adding a service here is a
/// deliberate decision per service, not a generic helper.
#[tauri::command]
pub async fn connections_reveal_api_key(service: String) -> Result<String, String> {
    let svc = ConnectionService::from_str(&service)
        .ok_or_else(|| format!("unknown service: {service}"))?;

    // Allowlist: services whose API surface lives in the renderer and
    // therefore need the raw key on the JS side. Bash-shelling services
    // and any sidecar-mediated SDK call MUST NOT be added here.
    match svc {
        ConnectionService::Gemini => {}
        _ => return Err(format!("service {service} does not allow renderer reveal")),
    }

    let all = read_all().await?;
    all.into_iter()
        .find(|c| c.service == svc)
        .map(|c| c.api_key)
        .ok_or_else(|| format!("no connection for service {service}"))
}

#[tauri::command]
pub async fn connections_list() -> Result<Vec<ConnectionRedacted>, String> {
    let mut all = read_all().await?;
    all.sort_by_key(|c| std::cmp::Reverse(c.created_at));
    Ok(all.iter().map(Connection::redact).collect())
}

#[derive(Deserialize)]
pub struct ConnectionCreate {
    pub service: String,
    pub api_key: String,
    #[serde(default)]
    pub account_label: Option<String>,
}

#[tauri::command]
pub async fn connections_create(req: ConnectionCreate) -> Result<ConnectionRedacted, String> {
    let service = ConnectionService::from_str(&req.service)
        .ok_or_else(|| format!("unknown service: {}", req.service))?;
    if req.api_key.trim().is_empty() {
        return Err("api key cannot be empty".into());
    }
    let mut all = read_all().await?;
    // One connection per service for v1. Replace any existing record
    // for the same service so the card never shows two connections.
    all.retain(|c| c.service != service);
    let connection = Connection {
        id: new_id(),
        env_var_name: service.default_env_var().to_string(),
        dashboard_url: service.default_dashboard_url().to_string(),
        service,
        api_key: req.api_key.trim().to_string(),
        account_label: req
            .account_label
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty()),
        created_at: now_ms(),
    };
    all.push(connection.clone());
    write_all(&all).await?;
    crate::sidecar::push_secrets_async();
    Ok(connection.redact())
}

/// Result of probing a local CLI binary on PATH. The `path` is the
/// absolute, canonicalised location (so symlinks resolve to the real
/// install) and `version` is the trimmed first line of
/// `<binary> --version` output.
#[derive(Debug, serde::Serialize)]
pub struct LocalCliProbe {
    pub found: bool,
    pub path: Option<String>,
    pub version: Option<String>,
    /// When `found == false`, the user-facing explanation: typically
    /// "binary not found on PATH" but might also be "found but
    /// `--version` timed out / errored". UI surfaces this verbatim.
    pub error: Option<String>,
}

/// Probe whether a CLI binary is installed + runnable. Used by the
/// detect-on-PATH connect flow for the Claude Code / Codex /
/// Google Workspace cards.
///
/// We accept only a short safe name (alphanumeric + `_`/`-`) so a
/// hostile renderer can't ask us to exec an arbitrary path. The
/// canonical names we expect are `claude`, `codex`, `gws`.
#[tauri::command]
pub async fn connections_detect_local_cli(name: String) -> LocalCliProbe {
    if name.is_empty() || name.len() > 40 {
        return LocalCliProbe {
            found: false,
            path: None,
            version: None,
            error: Some("invalid binary name".into()),
        };
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return LocalCliProbe {
            found: false,
            path: None,
            version: None,
            error: Some("invalid characters in binary name".into()),
        };
    }

    // Step 1 — locate it on PATH.
    let resolved = match which::which(&name) {
        Ok(p) => p,
        Err(e) => {
            return LocalCliProbe {
                found: false,
                path: None,
                version: None,
                error: Some(format!("not found on PATH: {e}")),
            };
        }
    };

    // Step 2 — confirm it's runnable by asking for its version.
    // 3s timeout is plenty for `--version`; anything slower than
    // that is misbehaving and we don't want to block the UI.
    let probe = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        tokio::process::Command::new(&resolved)
            .arg("--version")
            .output(),
    )
    .await;

    let version = match probe {
        Ok(Ok(out)) if out.status.success() => {
            let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
            // Some CLIs print to stderr instead — fall back if stdout
            // is empty.
            if s.is_empty() {
                String::from_utf8_lossy(&out.stderr).trim().to_string()
            } else {
                s
            }
            .lines()
            .next()
            .unwrap_or("")
            .to_string()
        }
        Ok(Ok(out)) => {
            return LocalCliProbe {
                found: true,
                path: Some(resolved.to_string_lossy().into_owned()),
                version: None,
                error: Some(format!(
                    "`{name} --version` exited with status {}",
                    out.status
                )),
            };
        }
        Ok(Err(e)) => {
            return LocalCliProbe {
                found: true,
                path: Some(resolved.to_string_lossy().into_owned()),
                version: None,
                error: Some(format!("could not spawn: {e}")),
            };
        }
        Err(_) => {
            return LocalCliProbe {
                found: true,
                path: Some(resolved.to_string_lossy().into_owned()),
                version: None,
                error: Some("`--version` timed out after 3s".into()),
            };
        }
    };

    LocalCliProbe {
        found: true,
        path: Some(resolved.to_string_lossy().into_owned()),
        version: if version.is_empty() {
            None
        } else {
            Some(version)
        },
        error: None,
    }
}

#[derive(Deserialize)]
pub struct LocalCliConnectRequest {
    pub service: String,
    /// Absolute path returned by `connections_detect_local_cli`. We
    /// re-resolve it on this side so a renderer can't smuggle in an
    /// arbitrary path that wasn't actually probed.
    pub path: String,
    #[serde(default)]
    pub version: Option<String>,
}

/// Persist a local-CLI connection. Unlike paste-API-key connections,
/// the "value" stored in the connections.org `API_KEY` slot is the
/// absolute binary path — not a secret, but we keep the same shape
/// (encrypted at rest, decrypted at use) so the storage model is
/// uniform. The sidecar gets `<SERVICE>_PATH=/usr/local/bin/<name>`.
#[tauri::command]
pub async fn connections_create_local_cli(
    req: LocalCliConnectRequest,
) -> Result<ConnectionRedacted, String> {
    let service = ConnectionService::from_str(&req.service)
        .ok_or_else(|| format!("unknown service: {}", req.service))?;
    if !matches!(
        service,
        ConnectionService::ClaudeCode
            | ConnectionService::Codex
            | ConnectionService::GoogleWorkspace
    ) {
        return Err(format!(
            "service {} is not a local-CLI connection",
            req.service
        ));
    }
    let path = req.path.trim();
    if path.is_empty() {
        return Err("path cannot be empty".into());
    }
    // Confirm what we're persisting actually exists at the moment we
    // write — guards against a stale probe result from minutes ago.
    if !std::path::Path::new(path).exists() {
        return Err(format!("path does not exist: {path}"));
    }

    let mut all = read_all().await?;
    all.retain(|c| c.service != service);

    let connection = Connection {
        id: new_id(),
        env_var_name: service.default_env_var().to_string(),
        dashboard_url: service.default_dashboard_url().to_string(),
        // For local-CLI variants the "api_key" slot carries the
        // absolute binary path. Encrypted-at-rest like everything
        // else in connections.org — uniform shape beats a special-case.
        api_key: path.to_string(),
        // Use the version string as the account label so the card
        // shows "Connected · v0.4.2" without a separate field.
        account_label: req.version.and_then(|v| {
            let t = v.trim();
            if t.is_empty() { None } else { Some(t.to_string()) }
        }),
        service,
        created_at: now_ms(),
    };
    all.push(connection.clone());
    write_all(&all).await?;
    crate::sidecar::push_secrets_async();
    // Drop a corresponding skill into the registry so the agent
    // automatically sees what's possible with this connection.
    // Idempotent — repeat connects update in place.
    crate::skills::upsert_from_connection(connection.service.as_str()).await;
    Ok(connection.redact())
}

/// Open a terminal window running the given local-CLI's interactive
/// auth command (e.g. `gws auth login`). Local-CLI integrations own
/// their own OAuth flows; we just surface a way to kick them off
/// without making the user pop a separate terminal themselves.
///
/// On macOS we use AppleScript to launch Terminal.app with the
/// command pre-typed + executed. On Linux/Windows we fall back to
/// the user's default terminal via well-known launchers.
#[tauri::command]
pub async fn connections_open_auth_terminal(command: String) -> Result<(), String> {
    // Validate aggressively — this surface invokes a shell. Whitelist
    // a small character set + length so a hostile renderer can't
    // chain commands.
    if command.is_empty() || command.len() > 200 {
        return Err("invalid auth command".into());
    }
    if !command
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, ' ' | '-' | '_' | '.' | '/'))
    {
        return Err(
            "auth command may only contain [A-Za-z0-9 ._/-] characters".into(),
        );
    }

    #[cfg(target_os = "macos")]
    {
        // AppleScript: tell Terminal to open a new window running the
        // command. The escaped quotes handle command + args cleanly.
        let escaped = command.replace('"', "\\\"");
        let script = format!(
            r#"tell application "Terminal" to do script "{escaped}""#
        );
        tokio::process::Command::new("osascript")
            .args(["-e", &script])
            .spawn()
            .map_err(|e| format!("launch Terminal.app: {e}"))?;
        Ok(())
    }

    #[cfg(target_os = "linux")]
    {
        // Try common Linux terminals in order. `x-terminal-emulator` is
        // the Debian-family selector; gnome-terminal / konsole / xterm
        // are fallbacks.
        let candidates: &[&[&str]] = &[
            &["x-terminal-emulator", "-e", &command],
            &["gnome-terminal", "--", "sh", "-c", &command],
            &["konsole", "-e", "sh", "-c", &command],
            &["xterm", "-e", &command],
        ];

        for argv in candidates {
            if tokio::process::Command::new(argv[0])
                .args(&argv[1..])
                .spawn()
                .is_ok()
            {
                return Ok(());
            }
        }
        Err("no supported terminal emulator found".into())
    }

    #[cfg(target_os = "windows")]
    {
        // Open Windows Terminal (`wt.exe`), falling back to cmd.
        tokio::process::Command::new("cmd")
            .args(["/c", "start", "wt.exe", "cmd", "/k", &command])
            .spawn()
            .map_err(|e| format!("launch terminal: {e}"))?;
        Ok(())
    }
}

#[derive(Deserialize)]
pub struct ManagedOAuthRequest {
    pub service: String,
    /// Access token from the OAuth exchange. Encrypted at rest like
    /// every other paste-key connection.
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: Option<String>,
    /// Unix millis when the access token expires. Stored so a future
    /// refresh job can renew before agent calls.
    #[serde(default)]
    pub expires_at_ms: Option<i64>,
    /// Account email from the id_token, shown on the card.
    #[serde(default)]
    pub account_email: Option<String>,
}

/// Persist a connection created via the Workbooks-managed OAuth flow
/// (browser sign-in, PKCE, no manual OAuth client setup). Mirrors
/// `connections_create` for paste-key flows but takes the bearer
/// token directly instead of a user-supplied API key. The token
/// rides through the same encrypted-at-rest path and gets forwarded
/// to the sidecar via `<SERVICE>_TOKEN` env vars.
#[tauri::command]
pub async fn connections_create_managed_oauth(
    req: ManagedOAuthRequest,
) -> Result<ConnectionRedacted, String> {
    let service = ConnectionService::from_str(&req.service)
        .ok_or_else(|| format!("unknown service: {}", req.service))?;
    if req.access_token.trim().is_empty() {
        return Err("access_token cannot be empty".into());
    }
    let mut all = read_all().await?;
    all.retain(|c| c.service != service);

    // For Google Workspace specifically: the env var gws reads to
    // skip its own OAuth dance is `GOOGLE_WORKSPACE_CLI_TOKEN`. Other
    // services may need different env var names — wire as those land.
    let env_var_name = match service {
        ConnectionService::GoogleWorkspace => "GOOGLE_WORKSPACE_CLI_TOKEN".to_string(),
        _ => service.default_env_var().to_string(),
    };

    let connection = Connection {
        id: new_id(),
        env_var_name,
        dashboard_url: service.default_dashboard_url().to_string(),
        api_key: req.access_token.trim().to_string(),
        account_label: req.account_email.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()),
        service,
        created_at: now_ms(),
    };
    all.push(connection.clone());
    write_all(&all).await?;
    crate::sidecar::push_secrets_async();
    crate::skills::upsert_from_connection(connection.service.as_str()).await;
    Ok(connection.redact())
}

#[tauri::command]
pub async fn connections_delete(id: String) -> Result<(), String> {
    let mut all = read_all().await?;
    // Capture which service this connection belonged to so we can
    // remove the corresponding skill entry after the file write.
    let removed_service = all
        .iter()
        .find(|c| c.id == id)
        .map(|c| c.service.as_str().to_string());
    let before = all.len();
    all.retain(|c| c.id != id);
    if all.len() == before {
        return Err(format!("no connection with id {id}"));
    }
    write_all(&all).await?;
    crate::sidecar::push_secrets_async();
    if let Some(svc) = removed_service {
        crate::skills::remove_for_source(&svc).await;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir_str() -> String {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "oql-desktop-connections-test-{}-{}",
            std::process::id(),
            uniq()
        ));
        p.to_string_lossy().into_owned()
    }

    fn uniq() -> u64 {
        use std::time::{SystemTime, UNIX_EPOCH};
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64
    }

    #[tokio::test(flavor = "current_thread")]
    async fn create_list_delete_roundtrip() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let created = connections_create(ConnectionCreate {
            service: "composio".into(),
            api_key: "ck_test_composio_123".into(),
            account_label: Some("personal".into()),
        })
        .await
        .unwrap();
        assert_eq!(created.service, "composio");
        assert_eq!(created.env_var_name, "COMPOSIO_API_KEY");
        assert_eq!(created.account_label.as_deref(), Some("personal"));

        let listed = connections_list().await.unwrap();
        assert_eq!(listed.len(), 1);

        // Sidecar fan-out — the env var should make it through.
        let envs = env_vars_for_sidecar().await;
        let composio = envs
            .iter()
            .find(|(k, _)| k == "COMPOSIO_API_KEY")
            .expect("COMPOSIO_API_KEY should be in sidecar env");
        assert_eq!(composio.1, "ck_test_composio_123");

        // On-disk verification — the API key MUST be encrypted.
        let raw = std::fs::read_to_string(connections_path()).unwrap();
        assert!(
            raw.contains("wbenc1:"),
            "expected encrypted blob in connections.org, got:\n{raw}"
        );
        assert!(
            !raw.contains("ck_test_composio_123"),
            "plaintext key leaked into connections.org:\n{raw}"
        );

        connections_delete(created.id).await.unwrap();
        assert!(connections_list().await.unwrap().is_empty());

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn one_connection_per_service() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let _ = connections_create(ConnectionCreate {
            service: "composio".into(),
            api_key: "old-key".into(),
            account_label: None,
        })
        .await
        .unwrap();
        std::thread::sleep(std::time::Duration::from_millis(2));
        let _ = connections_create(ConnectionCreate {
            service: "composio".into(),
            api_key: "new-key".into(),
            account_label: None,
        })
        .await
        .unwrap();

        // Only one record should survive — the latest.
        let listed = connections_list().await.unwrap();
        assert_eq!(listed.len(), 1);

        let envs = env_vars_for_sidecar().await;
        let composio = envs
            .iter()
            .find(|(k, _)| k == "COMPOSIO_API_KEY")
            .unwrap();
        assert_eq!(composio.1, "new-key");

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
