// Agent defaults — global "what model should the agent use when no
// per-task override is set" config.
//
// The sidecar's `Workbooks.Engine.LLM` resolves model in this order:
//   1. Explicit call-site opts
//   2. `WB_AGENT_MODEL` env var
//   3. Hard-coded fallback ("xiaomi/mimo-v2.5-pro" per CLAUDE.md)
//
// We persist the user-chosen model + push it into the sidecar as
// `WB_AGENT_MODEL` via the same /internal/secrets/refresh path that
// keys.rs and connections.rs use. No restart required — the next
// agent call picks up the new model.
//
// Storage: `~/.oql/desktop/agent-settings.org`. One entry, schema
// `agent-settings.v1`. Org-kv-backed like everything else so an
// agent can hand-edit it via oql-parse if they need to.
//
// Future fields land here: default temperature, system-prompt prelude,
// per-provider preferences, etc. v1 ships just the model.

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::org_kv::{self, OrgEntry};

const SETTINGS_FILE: &str = "agent-settings.org";
const SCHEMA: &str = "agent-settings.v1";
const ENTRY_ID: &str = "defaults";

/// CLAUDE.md project default — used when nothing's been persisted yet.
const DEFAULT_MODEL: &str = "xiaomi/mimo-v2.5-pro";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct AgentSettings {
    /// OpenRouter-style "provider/model" slug. Free-form string — we
    /// don't validate against a model list since model availability
    /// shifts faster than we ship updates. The sidecar surfaces
    /// upstream errors if the model name is wrong.
    pub default_model: String,
    /// Slug of the agent the chat panel opens to when no per-window
    /// selection has been persisted. Optional — empty/None means
    /// "fall back to whatever the bridge picks" (currently the
    /// catalog's `workhorse` entry, else first listed). Wired by the
    /// "Default agent" picker in Settings → Agents.
    #[serde(default)]
    pub default_agent_slug: String,
}

impl Default for AgentSettings {
    fn default() -> Self {
        Self {
            default_model: DEFAULT_MODEL.to_string(),
            default_agent_slug: String::new(),
        }
    }
}

fn settings_path() -> PathBuf {
    desktop_root().join(SETTINGS_FILE)
}

impl AgentSettings {
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        Some(Self {
            default_model: e.get("MODEL")?.to_string(),
            default_agent_slug: e.get("AGENT_SLUG").unwrap_or("").to_string(),
        })
    }

    fn to_entry(&self) -> OrgEntry {
        let mut entry = OrgEntry::new("Default agent settings".to_string())
            .with("ID", ENTRY_ID.to_string())
            .with("MODEL", self.default_model.clone());
        if !self.default_agent_slug.is_empty() {
            entry = entry.with("AGENT_SLUG", self.default_agent_slug.clone());
        }
        entry
    }
}

async fn read_settings() -> AgentSettings {
    match org_kv::read_entries(&settings_path(), SCHEMA).await {
        Ok(entries) => entries
            .iter()
            .filter_map(AgentSettings::from_entry)
            .next()
            .unwrap_or_default(),
        Err(_) => AgentSettings::default(),
    }
}

async fn write_settings(s: &AgentSettings) -> Result<(), String> {
    let entries = vec![s.to_entry()];
    org_kv::write_entries(&settings_path(), SCHEMA, &entries).await?;
    Ok(())
}

/// Env-var contribution for the sidecar spawn + /internal/secrets/refresh
/// push. Returns the model env var when set.
pub async fn env_vars_for_sidecar() -> Vec<(String, String)> {
    let s = read_settings().await;
    vec![("WB_AGENT_MODEL".to_string(), s.default_model)]
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn agent_settings_get() -> AgentSettings {
    read_settings().await
}

#[derive(Deserialize)]
pub struct AgentSettingsUpdate {
    /// Optional — when present, replaces the stored default model.
    /// Empty / absent leaves the current value untouched.
    #[serde(default)]
    pub default_model: Option<String>,
    /// Optional — when present (even as an empty string, which clears
    /// the pin), replaces the stored default agent slug.
    #[serde(default)]
    pub default_agent_slug: Option<String>,
}

#[tauri::command]
pub async fn agent_settings_set(req: AgentSettingsUpdate) -> Result<AgentSettings, String> {
    // Read-modify-write so callers can update either field in
    // isolation without clobbering the other.
    let mut s = read_settings().await;
    let mut model_changed = false;

    if let Some(m) = req.default_model {
        let m = m.trim();
        if m.is_empty() {
            return Err("default_model cannot be empty".into());
        }
        if m.len() > 128 {
            return Err("default_model too long (max 128 chars)".into());
        }
        s.default_model = m.to_string();
        model_changed = true;
    }

    if let Some(slug) = req.default_agent_slug {
        let slug = slug.trim();
        // Same shape as the slug regex in agents_io.rs. Empty is
        // allowed and clears the pin.
        if !slug.is_empty() {
            if slug.len() > 64 {
                return Err("default_agent_slug too long (max 64 chars)".into());
            }
            let first = slug.chars().next().unwrap();
            if !first.is_ascii_lowercase() {
                return Err("default_agent_slug must start with a lowercase letter".into());
            }
            for c in slug.chars() {
                if !(c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-') {
                    return Err(format!(
                        "default_agent_slug contains invalid character '{c}' — use [a-z0-9-]"
                    ));
                }
            }
        }
        s.default_agent_slug = slug.to_string();
    }

    write_settings(&s).await?;
    // Only push to the sidecar when the model env-var changed —
    // agent-slug routing is a renderer-side concern.
    if model_changed {
        crate::sidecar::push_secrets_async();
    }
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // All tests in this module manipulate `OQL_DESKTOP_HOME` (process-
    // global) — serialize them so the env var doesn't race between
    // threads. Without this, cargo test runs cases in parallel and one
    // test's setup clobbers another's path mid-write.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn tempdir_str() -> String {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "oql-desktop-agent-settings-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        p.to_string_lossy().into_owned()
    }

    #[tokio::test(flavor = "current_thread")]
    async fn defaults_when_missing() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let s = agent_settings_get().await;
        assert_eq!(s.default_model, DEFAULT_MODEL);

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn set_persists_and_returns_via_env_fanout() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let updated = agent_settings_set(AgentSettingsUpdate {
            default_model: Some("anthropic/claude-sonnet-4-6".into()),
            default_agent_slug: None,
        })
        .await
        .unwrap();
        assert_eq!(updated.default_model, "anthropic/claude-sonnet-4-6");

        let reread = agent_settings_get().await;
        assert_eq!(reread.default_model, "anthropic/claude-sonnet-4-6");

        let envs = env_vars_for_sidecar().await;
        let (k, v) = envs.first().unwrap();
        assert_eq!(k, "WB_AGENT_MODEL");
        assert_eq!(v, "anthropic/claude-sonnet-4-6");

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn empty_model_rejected() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let err = agent_settings_set(AgentSettingsUpdate {
            default_model: Some("   ".into()),
            default_agent_slug: None,
        })
        .await;
        assert!(err.is_err());

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn agent_slug_round_trips_and_validates() {
        let _guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        // Set an agent slug without touching the model.
        let updated = agent_settings_set(AgentSettingsUpdate {
            default_model: None,
            default_agent_slug: Some("my-custom-agent".into()),
        })
        .await
        .unwrap();
        assert_eq!(updated.default_agent_slug, "my-custom-agent");
        // Model untouched — still the seeded default.
        assert_eq!(updated.default_model, DEFAULT_MODEL);

        let reread = agent_settings_get().await;
        assert_eq!(reread.default_agent_slug, "my-custom-agent");

        // Clear the pin with an empty string.
        let cleared = agent_settings_set(AgentSettingsUpdate {
            default_model: None,
            default_agent_slug: Some("".into()),
        })
        .await
        .unwrap();
        assert_eq!(cleared.default_agent_slug, "");

        // Reject invalid slugs (matches agents_io::validate_slug).
        let bad = agent_settings_set(AgentSettingsUpdate {
            default_model: None,
            default_agent_slug: Some("Bad-Slug".into()),
        })
        .await;
        assert!(bad.is_err());

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
