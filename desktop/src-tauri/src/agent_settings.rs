// Agent defaults — the model + agent-slug the agent uses when no per-task
// override is set. Persisted in ~/.workbooks/config/agent-settings.org as a flat
// property drawer (:DEFAULT_MODEL: / :DEFAULT_AGENT_SLUG:). On set we
// best-effort nudge a live daemon to re-read WB_AGENT_MODEL.

use crate::{orgprops, paths};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

fn settings_path() -> PathBuf {
    paths::config_dir().join("agent-settings.org")
}

#[derive(Serialize, Default)]
pub struct AgentSettings {
    pub default_model: String,
    pub default_agent_slug: String,
}

fn read_body() -> String {
    std::fs::read_to_string(settings_path()).unwrap_or_default()
}

#[tauri::command]
pub fn agent_settings_get() -> AgentSettings {
    let body = read_body();
    AgentSettings {
        default_model: orgprops::get(&body, "default_model").unwrap_or_default(),
        default_agent_slug: orgprops::get(&body, "default_agent_slug").unwrap_or_default(),
    }
}

#[derive(Deserialize)]
pub struct AgentSettingsUpdate {
    pub default_model: Option<String>,
    pub default_agent_slug: Option<String>,
}

#[tauri::command]
pub fn agent_settings_set(req: AgentSettingsUpdate) -> Result<AgentSettings, String> {
    let mut body = read_body();
    if let Some(m) = req.default_model {
        body = orgprops::set(&body, "default_model", &m);
    }
    if let Some(s) = req.default_agent_slug {
        body = orgprops::set(&body, "default_agent_slug", &s);
    }
    let path = settings_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&path, &body).map_err(|e| e.to_string())?;
    crate::keychain::refresh_runtime_secrets();
    Ok(agent_settings_get())
}
