// Model-provider API key store (wb-i38o.6 §1).
//
// On-disk layout — sibling to workspaces, so a single `~/.oql/desktop/`
// directory carries all user-scoped desktop config:
//
//   ~/.oql/desktop/
//   ├── state.json          (workspaces — see workspace.rs)
//   ├── workspaces/         (workspaces — see workspace.rs)
//   ├── keys.json           ← THIS FILE — array of ApiKey records
//   ├── mcp-servers.json    (see mcp_servers.rs)
//   └── plugins.json        (see plugins.rs)
//
// `keys.json` schema (array):
//
//   [
//     {
//       "id":         "<uuid-ish>",
//       "name":       "personal-openrouter",
//       "provider":   "openrouter" | "anthropic" | "openai" | ... | "custom",
//       "custom_provider": "MyCo"   // only when provider == "custom"
//       "value":      "<secret>",
//       "created_at": <unix-millis>
//     },
//     ...
//   ]
//
// File is chmod 600 on unix (best-effort) AND every secret value is
// AES-256-GCM encrypted at rest with a key in the OS keychain — see
// `crypto.rs`. Legacy plaintext values from pre-encryption installs
// are detected on read and silently re-encrypted on the next write.
//
// Most-recently-created key per provider wins when the sidecar boots
// (`env_vars_for_sidecar` returns one env var per provider). The UI
// surfaces this rule to the user so they don't get surprised.

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::crypto;
use crate::org_kv::{self, OrgEntry};
use tauri::AppHandle;
use tauri_plugin_clipboard_manager::ClipboardExt;

const KEYS_FILE: &str = "keys.org";
const SCHEMA: &str = "keys.v1";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct ApiKey {
    pub id: String,
    pub name: String,
    /// Canonical provider id — see `provider_env_var` for the mapping.
    pub provider: String,
    /// User-supplied provider name when `provider == "custom"`. Used to
    /// derive the env var name (`<UPPERCASED>_API_KEY`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_provider: Option<String>,
    pub value: String,
    pub created_at: i64,
}

/// A redacted view of an `ApiKey` — never includes the secret value.
/// What we hand to the UI by default. There is no path to return the
/// raw value to the renderer; `keys_copy_to_clipboard` decrypts inside
/// Rust and writes straight to the OS clipboard, so the plaintext
/// never crosses the Tauri IPC boundary into JS.
#[derive(Clone, Debug, Serialize)]
pub struct ApiKeyRedacted {
    pub id: String,
    pub name: String,
    pub provider: String,
    pub custom_provider: Option<String>,
    pub created_at: i64,
    /// `••••` of length 8 — UI shows this. There is no in-place reveal;
    /// `keys_copy_to_clipboard` is the only path that exposes the value
    /// to the user, and it writes to the OS clipboard from Rust without
    /// returning the plaintext via IPC.
    pub masked: String,
    /// Char count of the underlying secret — useful for "looks valid"
    /// affordances without leaking content.
    pub length: usize,
}

impl ApiKey {
    fn redact(&self) -> ApiKeyRedacted {
        ApiKeyRedacted {
            id: self.id.clone(),
            name: self.name.clone(),
            provider: self.provider.clone(),
            custom_provider: self.custom_provider.clone(),
            created_at: self.created_at,
            masked: "•".repeat(8),
            length: self.value.chars().count(),
        }
    }
}

fn keys_path() -> PathBuf {
    desktop_root().join(KEYS_FILE)
}

fn validate_name(name: &str) -> Result<(), String> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err("key name cannot be empty".into());
    }
    if trimmed.len() > 64 {
        return Err("key name must be <= 64 chars".into());
    }
    Ok(())
}

fn validate_provider(provider: &str, custom_provider: Option<&str>) -> Result<(), String> {
    if provider.is_empty() {
        return Err("provider required".into());
    }
    if provider == "custom" {
        let cp = custom_provider.unwrap_or("").trim();
        if cp.is_empty() {
            return Err("custom provider name required when provider == custom".into());
        }
        if !cp
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
        {
            return Err("custom provider name may only contain [A-Za-z0-9_-]".into());
        }
        if cp.len() > 32 {
            return Err("custom provider name must be <= 32 chars".into());
        }
    } else if !is_known_provider(provider) {
        return Err(format!("unknown provider: {provider}"));
    }
    Ok(())
}

/// Known provider ids — UI mirrors this list in the dropdown. Order is
/// preserved as-shipped in the desktop UI (most common first).
const KNOWN_PROVIDERS: &[&str] = &[
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
];

fn is_known_provider(p: &str) -> bool {
    KNOWN_PROVIDERS.iter().any(|k| *k == p)
}

/// Map provider id → conventional `<X>_API_KEY` env var name. The
/// sidecar reads these at boot via `env_vars_for_sidecar`.
pub fn provider_env_var(provider: &str, custom_provider: Option<&str>) -> Option<String> {
    let upper = match provider {
        "openrouter" => "OPENROUTER",
        "anthropic" => "ANTHROPIC",
        "openai" => "OPENAI",
        "google" => "GOOGLE",
        "mistral" => "MISTRAL",
        "together" => "TOGETHER",
        "groq" => "GROQ",
        "cerebras" => "CEREBRAS",
        "xai" => "XAI",
        "sambanova" => "SAMBANOVA",
        "fireworks" => "FIREWORKS",
        "custom" => return custom_provider.map(|cp| format!("{}_API_KEY", cp.to_uppercase())),
        _ => return None,
    };
    Some(format!("{upper}_API_KEY"))
}

impl ApiKey {
    /// Parse an entry, decrypting the value. Returns `None` if the
    /// entry is missing required fields OR the value is encrypted with
    /// a key we can't load (logged + dropped — we don't want to crash
    /// the whole list because one record is unreadable).
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        let stored_value = e.get("VALUE")?;
        let value = match crypto::decrypt_value(stored_value) {
            Ok(v) => v,
            Err(err) => {
                log::warn!(
                    "[keys] dropping entry {:?}: decrypt failed: {err}",
                    e.get("ID")
                );
                return None;
            }
        };
        Some(ApiKey {
            id: e.get("ID")?.to_string(),
            name: e.title.clone(),
            provider: e.get("PROVIDER")?.to_string(),
            custom_provider: e.get("CUSTOM_PROVIDER").map(|s| s.to_string()),
            value,
            created_at: e.get_i64("CREATED_AT").unwrap_or(0),
        })
    }

    /// Serialise an entry, encrypting the value. Bubbles encryption
    /// errors up so the calling write path can refuse to persist a
    /// secret it can't protect — we never want to silently fall back
    /// to plaintext.
    fn to_entry(&self) -> Result<OrgEntry, String> {
        let encrypted = crypto::encrypt_value(&self.value)?;
        let mut e = OrgEntry::new(self.name.clone())
            .with("ID", self.id.clone())
            .with("PROVIDER", self.provider.clone())
            .with("VALUE", encrypted)
            .with("CREATED_AT", self.created_at.to_string());
        if let Some(cp) = &self.custom_provider {
            e = e.with("CUSTOM_PROVIDER", cp.clone());
        }
        Ok(e)
    }
}

async fn read_all() -> Result<Vec<ApiKey>, String> {
    let entries = org_kv::read_entries(&keys_path(), SCHEMA).await?;
    Ok(entries.iter().filter_map(ApiKey::from_entry).collect())
}

async fn write_all(keys: &[ApiKey]) -> Result<(), String> {
    let entries: Vec<OrgEntry> = keys
        .iter()
        .map(ApiKey::to_entry)
        .collect::<Result<Vec<_>, _>>()?;
    org_kv::write_entries(&keys_path(), SCHEMA, &entries).await?;
    set_owner_only(&keys_path())?;
    Ok(())
}

/// Best-effort `chmod 600` on the keys file (unix). Windows is left as
/// the inherited ACL — the file lives under the user's profile dir.
fn set_owner_only(path: &std::path::Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        std::fs::set_permissions(path, perms).map_err(|e| format!("chmod 600 keys.json: {e}"))?;
    }
    #[cfg(not(unix))]
    {
        let _ = path; // silence unused on non-unix
    }
    Ok(())
}

/// Build the `{ENV_VAR -> secret_value}` map that should be passed to
/// the sidecar when it spawns. Most-recently-created key per provider
/// wins. Async because it reads the keys.json file.
pub async fn env_vars_for_sidecar() -> Vec<(String, String)> {
    let keys = match read_all().await {
        Ok(k) => k,
        Err(e) => {
            log::warn!("[keys] env_vars_for_sidecar read failed: {e}");
            return vec![];
        }
    };
    // Most-recently-created wins per (provider, custom_provider) bucket.
    use std::collections::HashMap;
    let mut latest: HashMap<String, &ApiKey> = HashMap::new();
    for k in &keys {
        let bucket = match k.custom_provider.as_deref() {
            Some(cp) => format!("{}::{cp}", k.provider),
            None => k.provider.clone(),
        };
        match latest.get(&bucket) {
            Some(prev) if prev.created_at >= k.created_at => {}
            _ => {
                latest.insert(bucket, k);
            }
        }
    }
    latest
        .into_values()
        .filter_map(|k| {
            provider_env_var(&k.provider, k.custom_provider.as_deref())
                .map(|var| (var, k.value.clone()))
        })
        .collect()
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("k_{:x}", nanos)
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn keys_list() -> Result<Vec<ApiKeyRedacted>, String> {
    let mut all = read_all().await?;
    all.sort_by_key(|k| std::cmp::Reverse(k.created_at));
    Ok(all.iter().map(ApiKey::redact).collect())
}

#[derive(Deserialize)]
pub struct KeyCreate {
    pub name: String,
    pub provider: String,
    #[serde(default)]
    pub custom_provider: Option<String>,
    pub value: String,
}

#[tauri::command]
pub async fn keys_create(req: KeyCreate) -> Result<ApiKeyRedacted, String> {
    validate_name(&req.name)?;
    validate_provider(&req.provider, req.custom_provider.as_deref())?;
    if req.value.trim().is_empty() {
        return Err("key value cannot be empty".into());
    }
    let mut all = read_all().await?;
    let key = ApiKey {
        id: new_id(),
        name: req.name.trim().to_string(),
        provider: req.provider,
        custom_provider: req.custom_provider.map(|s| s.trim().to_string()),
        value: req.value,
        created_at: now_ms(),
    };
    all.push(key.clone());
    write_all(&all).await?;
    crate::sidecar::push_secrets_async();
    Ok(key.redact())
}

#[derive(Deserialize)]
pub struct KeyRename {
    pub id: String,
    pub name: String,
}

#[tauri::command]
pub async fn keys_rename(req: KeyRename) -> Result<(), String> {
    validate_name(&req.name)?;
    let mut all = read_all().await?;
    let k = all
        .iter_mut()
        .find(|k| k.id == req.id)
        .ok_or_else(|| format!("no key with id {}", req.id))?;
    k.name = req.name.trim().to_string();
    write_all(&all).await
    // No push here — rename doesn't change the secret value or its
    // env var name. The sidecar already has the right key.
}

#[tauri::command]
pub async fn keys_delete(id: String) -> Result<(), String> {
    let mut all = read_all().await?;
    let before = all.len();
    all.retain(|k| k.id != id);
    if all.len() == before {
        return Err(format!("no key with id {id}"));
    }
    write_all(&all).await?;
    crate::sidecar::push_secrets_async();
    Ok(())
}

/// Decrypt a key inside Rust and write the plaintext directly to the
/// OS clipboard via the clipboard plugin. The plaintext NEVER crosses
/// the Tauri IPC boundary into JS — that's the whole point of this
/// command existing in place of the old `keys_reveal`.
#[tauri::command]
pub async fn keys_copy_to_clipboard(app: AppHandle, id: String) -> Result<(), String> {
    let all = read_all().await?;
    let k = all
        .into_iter()
        .find(|k| k.id == id)
        .ok_or_else(|| format!("no key with id {id}"))?;
    app.clipboard()
        .write_text(k.value)
        .map_err(|e| format!("clipboard write: {e}"))
}

/// Surface the canonical provider list to the UI so the dropdown is a
/// single source of truth.
#[tauri::command]
pub fn keys_known_providers() -> Vec<String> {
    let mut v: Vec<String> = KNOWN_PROVIDERS.iter().map(|s| (*s).to_string()).collect();
    v.push("custom".into());
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir_str() -> String {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "oql-desktop-keys-test-{}-{}",
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

    #[test]
    fn provider_env_var_known_providers() {
        assert_eq!(
            provider_env_var("openrouter", None).as_deref(),
            Some("OPENROUTER_API_KEY")
        );
        assert_eq!(
            provider_env_var("anthropic", None).as_deref(),
            Some("ANTHROPIC_API_KEY")
        );
        assert_eq!(
            provider_env_var("xai", None).as_deref(),
            Some("XAI_API_KEY")
        );
        assert_eq!(provider_env_var("never-heard-of-it", None), None);
    }

    #[test]
    fn provider_env_var_custom() {
        assert_eq!(
            provider_env_var("custom", Some("myco")).as_deref(),
            Some("MYCO_API_KEY")
        );
        assert_eq!(provider_env_var("custom", None), None);
    }

    #[test]
    fn validate_provider_rules() {
        assert!(validate_provider("openrouter", None).is_ok());
        assert!(validate_provider("custom", Some("Foo_Bar")).is_ok());
        assert!(validate_provider("custom", None).is_err());
        assert!(validate_provider("custom", Some("has space")).is_err());
        assert!(validate_provider("nope", None).is_err());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn create_list_delete_roundtrip() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let k1 = keys_create(KeyCreate {
            name: "primary".into(),
            provider: "openrouter".into(),
            custom_provider: None,
            value: "sk-test-1".into(),
        })
        .await
        .unwrap();

        let listed = keys_list().await.unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, k1.id);
        assert_eq!(listed[0].masked, "••••••••");

        // Encrypt-on-write + decrypt-on-read should round-trip through
        // the env-var fan-out. We can't directly call the clipboard
        // command without an AppHandle, so use the sidecar fan-out as
        // the canonical "Rust gets the plaintext back" probe.
        let envs = env_vars_for_sidecar().await;
        let or = envs.iter().find(|(k, _)| k == "OPENROUTER_API_KEY").unwrap();
        assert_eq!(or.1, "sk-test-1");

        // And on disk, the VALUE property must be the encrypted blob.
        let raw = std::fs::read_to_string(keys_path()).unwrap();
        assert!(
            raw.contains("wbenc1:"),
            "expected encrypted blob in keys.org, got:\n{raw}"
        );
        assert!(
            !raw.contains("sk-test-1"),
            "plaintext leaked into keys.org:\n{raw}"
        );

        keys_delete(k1.id.clone()).await.unwrap();
        assert!(keys_list().await.unwrap().is_empty());

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn env_vars_most_recent_wins() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let _ = keys_create(KeyCreate {
            name: "old".into(),
            provider: "openrouter".into(),
            custom_provider: None,
            value: "old-value".into(),
        })
        .await
        .unwrap();
        // Sleep 2ms to make timestamps distinct.
        std::thread::sleep(std::time::Duration::from_millis(2));
        let _ = keys_create(KeyCreate {
            name: "new".into(),
            provider: "openrouter".into(),
            custom_provider: None,
            value: "new-value".into(),
        })
        .await
        .unwrap();

        let envs = env_vars_for_sidecar().await;
        let or = envs
            .iter()
            .find(|(k, _)| k == "OPENROUTER_API_KEY")
            .unwrap();
        assert_eq!(or.1, "new-value");

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
