// Plugin registry (wb-i38o.6 §3).
//
// Persists the user's plugin entries at `~/.oql/desktop/plugins.json`.
// v1 is registry-only — the agent-side loader is OUT OF SCOPE for this
// ticket. Future runtime work can read the file as-is.
//
// Schema (array):
//   [
//     {
//       "id":           "<uuid-ish>",
//       "name":         "wraith",
//       "source":       "https://..." | "/abs/path" | "registry-name",
//       "version":      "0.1.2" | "",
//       "enabled":      true,
//       "installed_at": <unix-millis>
//     },
//     ...
//   ]

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::org_kv::{self, OrgEntry};

const PLUGINS_FILE: &str = "plugins.org";
const SCHEMA: &str = "plugins.v1";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Plugin {
    pub id: String,
    pub name: String,
    pub source: String,
    #[serde(default)]
    pub version: String,
    pub enabled: bool,
    pub installed_at: i64,
}

fn plugins_path() -> PathBuf {
    desktop_root().join(PLUGINS_FILE)
}

fn validate(p: &Plugin) -> Result<(), String> {
    if p.name.trim().is_empty() {
        return Err("plugin name cannot be empty".into());
    }
    if p.name.len() > 64 {
        return Err("plugin name must be <= 64 chars".into());
    }
    if p.source.trim().is_empty() {
        return Err("plugin source cannot be empty".into());
    }
    Ok(())
}

impl Plugin {
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        Some(Plugin {
            id: e.get("ID")?.to_string(),
            name: e.title.clone(),
            source: e.get("SOURCE")?.to_string(),
            version: e.get("VERSION").unwrap_or("").to_string(),
            enabled: e.get("ENABLED").map(|v| v == "true").unwrap_or(true),
            installed_at: e.get_i64("INSTALLED_AT").unwrap_or(0),
        })
    }

    fn to_entry(&self) -> OrgEntry {
        let mut e = OrgEntry::new(self.name.clone())
            .with("ID", self.id.clone())
            .with("SOURCE", self.source.clone())
            .with("ENABLED", if self.enabled { "true" } else { "false" })
            .with("INSTALLED_AT", self.installed_at.to_string());
        if !self.version.is_empty() {
            e = e.with("VERSION", self.version.clone());
        }
        e
    }
}

async fn read_all() -> Result<Vec<Plugin>, String> {
    let entries = org_kv::read_entries(&plugins_path(), SCHEMA).await?;
    Ok(entries.iter().filter_map(Plugin::from_entry).collect())
}

async fn write_all(all: &[Plugin]) -> Result<(), String> {
    let entries: Vec<OrgEntry> = all.iter().map(Plugin::to_entry).collect();
    org_kv::write_entries(&plugins_path(), SCHEMA, &entries).await
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("p_{:x}", nanos)
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
pub async fn plugins_list() -> Result<Vec<Plugin>, String> {
    let mut all = read_all().await?;
    all.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(all)
}

#[derive(Deserialize)]
pub struct PluginCreate {
    pub name: String,
    pub source: String,
    #[serde(default)]
    pub version: String,
    #[serde(default = "default_enabled")]
    pub enabled: bool,
}

fn default_enabled() -> bool {
    true
}

#[tauri::command]
pub async fn plugins_install(req: PluginCreate) -> Result<Plugin, String> {
    let p = Plugin {
        id: new_id(),
        name: req.name.trim().to_string(),
        source: req.source.trim().to_string(),
        version: req.version.trim().to_string(),
        enabled: req.enabled,
        installed_at: now_ms(),
    };
    validate(&p)?;
    let mut all = read_all().await?;
    all.push(p.clone());
    write_all(&all).await?;
    Ok(p)
}

#[derive(Deserialize)]
pub struct PluginToggle {
    pub id: String,
    pub enabled: bool,
}

#[tauri::command]
pub async fn plugins_set_enabled(req: PluginToggle) -> Result<(), String> {
    let mut all = read_all().await?;
    let p = all
        .iter_mut()
        .find(|p| p.id == req.id)
        .ok_or_else(|| format!("no plugin with id {}", req.id))?;
    p.enabled = req.enabled;
    write_all(&all).await
}

#[tauri::command]
pub async fn plugins_remove(id: String) -> Result<(), String> {
    let mut all = read_all().await?;
    let before = all.len();
    all.retain(|p| p.id != id);
    if all.len() == before {
        return Err(format!("no plugin with id {id}"));
    }
    write_all(&all).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir_str() -> String {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "oql-desktop-plugins-test-{}-{}",
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
    async fn install_toggle_remove_roundtrip() {
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);
        std::fs::create_dir_all(&tmp).unwrap();

        let p = plugins_install(PluginCreate {
            name: "wraith".into(),
            source: "https://github.com/workbooks-sh/wraith".into(),
            version: "0.1.0".into(),
            enabled: true,
        })
        .await
        .unwrap();
        assert_eq!(plugins_list().await.unwrap().len(), 1);

        plugins_set_enabled(PluginToggle {
            id: p.id.clone(),
            enabled: false,
        })
        .await
        .unwrap();
        assert!(!plugins_list().await.unwrap()[0].enabled);

        plugins_remove(p.id).await.unwrap();
        assert!(plugins_list().await.unwrap().is_empty());

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
