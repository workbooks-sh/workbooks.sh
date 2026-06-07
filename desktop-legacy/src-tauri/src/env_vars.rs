// User-managed environment variables (per docs/canonical-model.md).
//
// Distinct from `keys.rs`:
//   - keys.rs: provider API keys (OpenRouter, Anthropic, …). The
//     sidecar reads one env var per provider at boot.
//   - env_vars.rs: arbitrary user-defined env vars, scoped to User /
//     Workspace / Package. Surfaced to the agent + workbooks at run
//     time (the runtime hookup is a separate epic; this module just
//     stores + manages).
//
// On-disk layout — sibling to the other `.oql/desktop/*.json` files:
//
//   ~/.oql/desktop/env-vars.json
//
// Schema (array):
//
//   [
//     {
//       "id":           "ev_<hex>",
//       "name":         "OPENAI_KEY",
//       "value":        "<secret>",
//       "scope":        "user" | "workspace" | "package",
//       "workspace_id": "<id>"   // only when scope == "workspace" or "package"
//       "package_name": "<name>" // only when scope == "package"
//       "created_at":   <unix-millis>
//     },
//     ...
//   ]
//
// Secrets are stored AES-256-GCM encrypted with a key in the OS
// keychain — see `crypto.rs`. The file is also chmod 600 on unix as
// defence-in-depth. Legacy plaintext values from pre-encryption
// installs are detected on read and silently re-encrypted on the
// next write.

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::crypto;
use crate::org_kv::{self, OrgEntry};
use tauri::AppHandle;
use tauri_plugin_clipboard_manager::ClipboardExt;

const ENV_VARS_FILE: &str = "env-vars.org";
const SCHEMA: &str = "env-vars.v1";

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum EnvScope {
    User,
    Workspace,
    Package,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct EnvVar {
    pub id: String,
    pub name: String,
    pub value: String,
    pub scope: EnvScope,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package_name: Option<String>,
    pub created_at: i64,
}

/// Redacted view (no raw value). The list endpoint returns these by
/// default so a devtools console.log doesn't leak the secret.
#[derive(Clone, Debug, Serialize)]
pub struct EnvVarRedacted {
    pub id: String,
    pub name: String,
    pub scope: EnvScope,
    pub workspace_id: Option<String>,
    pub package_name: Option<String>,
    pub created_at: i64,
    pub masked: String,
    pub length: usize,
}

impl EnvVar {
    fn redact(&self) -> EnvVarRedacted {
        EnvVarRedacted {
            id: self.id.clone(),
            name: self.name.clone(),
            scope: self.scope,
            workspace_id: self.workspace_id.clone(),
            package_name: self.package_name.clone(),
            created_at: self.created_at,
            masked: "•".repeat(8),
            length: self.value.chars().count(),
        }
    }
}

fn env_vars_path() -> PathBuf {
    desktop_root().join(ENV_VARS_FILE)
}

impl EnvVar {
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        let scope = match e.get("SCOPE")? {
            "user" => EnvScope::User,
            "workspace" => EnvScope::Workspace,
            "package" => EnvScope::Package,
            _ => return None,
        };
        let stored_value = e.get("VALUE")?;
        let value = match crypto::decrypt_value(stored_value) {
            Ok(v) => v,
            Err(err) => {
                log::warn!(
                    "[env_vars] dropping entry {:?}: decrypt failed: {err}",
                    e.get("ID")
                );
                return None;
            }
        };
        Some(EnvVar {
            id: e.get("ID")?.to_string(),
            name: e.title.clone(),
            value,
            scope,
            workspace_id: e.get("WORKSPACE_ID").map(|s| s.to_string()),
            package_name: e.get("PACKAGE_NAME").map(|s| s.to_string()),
            created_at: e.get_i64("CREATED_AT").unwrap_or(0),
        })
    }

    fn to_entry(&self) -> Result<OrgEntry, String> {
        let scope_str = match self.scope {
            EnvScope::User => "user",
            EnvScope::Workspace => "workspace",
            EnvScope::Package => "package",
        };
        let encrypted = crypto::encrypt_value(&self.value)?;
        let mut e = OrgEntry::new(self.name.clone())
            .with("ID", self.id.clone())
            .with("VALUE", encrypted)
            .with("SCOPE", scope_str)
            .with("CREATED_AT", self.created_at.to_string());
        if let Some(w) = &self.workspace_id {
            e = e.with("WORKSPACE_ID", w.clone());
        }
        if let Some(p) = &self.package_name {
            e = e.with("PACKAGE_NAME", p.clone());
        }
        Ok(e)
    }
}

async fn read_all() -> Result<Vec<EnvVar>, String> {
    let entries = org_kv::read_entries(&env_vars_path(), SCHEMA).await?;
    Ok(entries.iter().filter_map(EnvVar::from_entry).collect())
}

async fn write_all(vars: &[EnvVar]) -> Result<(), String> {
    let entries: Vec<OrgEntry> = vars
        .iter()
        .map(EnvVar::to_entry)
        .collect::<Result<Vec<_>, _>>()?;
    org_kv::write_entries(&env_vars_path(), SCHEMA, &entries).await?;
    set_owner_only(&env_vars_path())?;
    Ok(())
}

fn set_owner_only(path: &std::path::Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, perms)
            .map_err(|e| format!("chmod 600 env-vars.json: {e}"))?;
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
    format!("ev_{:x}", nanos)
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn validate_name(name: &str) -> Result<(), String> {
    let n = name.trim();
    if n.is_empty() {
        return Err("name is required".to_string());
    }
    if !n.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err("name must be ASCII letters, digits, or _".to_string());
    }
    if n.chars().next().is_some_and(|c| c.is_ascii_digit()) {
        return Err("name must not start with a digit".to_string());
    }
    Ok(())
}

fn validate_scope(
    scope: EnvScope,
    workspace_id: &Option<String>,
    package_name: &Option<String>,
) -> Result<(), String> {
    match scope {
        EnvScope::User => Ok(()),
        EnvScope::Workspace => {
            if workspace_id.is_none() {
                return Err("workspace_id is required for workspace-scoped vars".into());
            }
            Ok(())
        }
        EnvScope::Package => {
            if workspace_id.is_none() {
                return Err("workspace_id is required for package-scoped vars".into());
            }
            if package_name.is_none() {
                return Err("package_name is required for package-scoped vars".into());
            }
            Ok(())
        }
    }
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn env_vars_list() -> Result<Vec<EnvVarRedacted>, String> {
    let mut all = read_all().await?;
    all.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    Ok(all.iter().map(EnvVar::redact).collect())
}

#[derive(Deserialize)]
pub struct EnvVarCreate {
    pub name: String,
    pub value: String,
    pub scope: EnvScope,
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default)]
    pub package_name: Option<String>,
}

#[tauri::command]
pub async fn env_vars_create(req: EnvVarCreate) -> Result<EnvVarRedacted, String> {
    validate_name(&req.name)?;
    validate_scope(req.scope, &req.workspace_id, &req.package_name)?;
    let mut all = read_all().await?;
    // Same (scope, target, name) replaces the existing value silently
    // — the "I just re-pasted my .env" flow shouldn't require a
    // separate update path.
    all.retain(|v| {
        !(v.name == req.name
            && v.scope == req.scope
            && v.workspace_id == req.workspace_id
            && v.package_name == req.package_name)
    });
    let v = EnvVar {
        id: new_id(),
        name: req.name.trim().to_string(),
        value: req.value,
        scope: req.scope,
        workspace_id: req.workspace_id,
        package_name: req.package_name,
        created_at: now_ms(),
    };
    let redacted = v.redact();
    all.push(v);
    write_all(&all).await?;
    Ok(redacted)
}

#[derive(Deserialize)]
pub struct EnvVarUpdate {
    pub id: String,
    pub value: String,
}

#[tauri::command]
pub async fn env_vars_update(req: EnvVarUpdate) -> Result<(), String> {
    let mut all = read_all().await?;
    let v = all
        .iter_mut()
        .find(|v| v.id == req.id)
        .ok_or_else(|| format!("no env var with id {}", req.id))?;
    v.value = req.value;
    write_all(&all).await?;
    Ok(())
}

#[tauri::command]
pub async fn env_vars_delete(id: String) -> Result<(), String> {
    let mut all = read_all().await?;
    let before = all.len();
    all.retain(|v| v.id != id);
    if all.len() == before {
        return Err(format!("no env var with id {id}"));
    }
    write_all(&all).await?;
    Ok(())
}

/// Decrypt an env var inside Rust and write the plaintext directly to
/// the OS clipboard. Counterpart to `keys_copy_to_clipboard` — the
/// plaintext never crosses the IPC boundary into JS, replacing the
/// old `env_vars_reveal` path.
#[tauri::command]
pub async fn env_vars_copy_to_clipboard(app: AppHandle, id: String) -> Result<(), String> {
    let all = read_all().await?;
    let v = all
        .into_iter()
        .find(|v| v.id == id)
        .ok_or_else(|| format!("no env var with id {id}"))?;
    app.clipboard()
        .write_text(v.value)
        .map_err(|e| format!("clipboard write: {e}"))
}

#[derive(Deserialize)]
pub struct EnvVarBulkImport {
    /// Raw `.env`-style text (one `KEY=VALUE` per line; `#` comments
    /// and blank lines ignored). Quoted values are unquoted.
    pub text: String,
    pub scope: EnvScope,
    #[serde(default)]
    pub workspace_id: Option<String>,
    #[serde(default)]
    pub package_name: Option<String>,
}

#[derive(Serialize)]
pub struct BulkImportResult {
    pub imported: Vec<EnvVarRedacted>,
    pub skipped: Vec<String>,
}

#[tauri::command]
pub async fn env_vars_bulk_import(
    req: EnvVarBulkImport,
) -> Result<BulkImportResult, String> {
    validate_scope(req.scope, &req.workspace_id, &req.package_name)?;
    let mut imported: Vec<EnvVarRedacted> = vec![];
    let mut skipped: Vec<String> = vec![];
    let mut all = read_all().await?;

    for raw_line in req.text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // Strip an optional leading `export `.
        let body = line.strip_prefix("export ").unwrap_or(line);
        let Some(eq_idx) = body.find('=') else {
            skipped.push(format!("missing `=`: {raw_line}"));
            continue;
        };
        let name = body[..eq_idx].trim();
        let raw_value = body[eq_idx + 1..].trim();
        let value = if (raw_value.starts_with('"') && raw_value.ends_with('"'))
            || (raw_value.starts_with('\'') && raw_value.ends_with('\''))
        {
            raw_value[1..raw_value.len() - 1].to_string()
        } else {
            raw_value.to_string()
        };
        if validate_name(name).is_err() {
            skipped.push(format!("invalid name: {raw_line}"));
            continue;
        }
        all.retain(|v| {
            !(v.name == name
                && v.scope == req.scope
                && v.workspace_id == req.workspace_id
                && v.package_name == req.package_name)
        });
        let v = EnvVar {
            id: new_id(),
            name: name.to_string(),
            value,
            scope: req.scope,
            workspace_id: req.workspace_id.clone(),
            package_name: req.package_name.clone(),
            created_at: now_ms(),
        };
        imported.push(v.redact());
        all.push(v);
    }

    write_all(&all).await?;
    Ok(BulkImportResult { imported, skipped })
}
