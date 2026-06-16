// Canonical on-disk locations the native shell owns — ONE root, `~/.workbooks`
// (override `WB_HOME`). Config, workspaces, and app-data all live under a single
// directory instead of three scattered roots. Centralised so every module agrees
// and tests can sandbox every write by pointing `WB_HOME` at a temp dir.
//
//   ~/.workbooks/config/      — local config: keys.json, env-vars.json, themes,
//                               mcp-servers.json, plugins.json, setup.json, …
//   ~/.workbooks/workspaces/  — package descriptors + state.json
//   ~/.workbooks/data/        — identity.json, packages/<ws>.html, session.json

use std::path::PathBuf;

/// The single Workbooks home: `~/.workbooks` (override `WB_HOME`). Everything the
/// shell persists lives under here — one directory, not three.
pub fn home() -> PathBuf {
    if let Ok(p) = std::env::var("WB_HOME") {
        return PathBuf::from(p);
    }
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".workbooks")
}

/// `~/.workbooks/config` — local config (keys, env-vars, themes, mcp, plugins,
/// setup, connections). Created on demand.
pub fn config_dir() -> PathBuf {
    home().join("config")
}

/// `~/.workbooks/workspaces` — package descriptors + state.json.
pub fn workspaces_dir() -> PathBuf {
    home().join("workspaces")
}

/// `~/.workbooks/data` — identity, packages, session.
pub fn app_data_dir() -> PathBuf {
    home().join("data")
}

/// Ensure a directory exists, returning it for chaining.
pub fn ensure_dir(p: PathBuf) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(&p)?;
    Ok(p)
}

/// Read a JSON document from `dir/name`, returning the serde default when the
/// file is absent or unparseable (so first-run never errors).
pub fn read_json<T: serde::de::DeserializeOwned + Default>(path: &std::path::Path) -> T {
    std::fs::read_to_string(path)
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

/// Atomically write a JSON document (temp file + rename) so a crash mid-write
/// can't truncate the index.
pub fn write_json<T: serde::Serialize>(path: &std::path::Path, value: &T) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let body = serde_json::to_string_pretty(value).map_err(|e| e.to_string())?;
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, body).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, path).map_err(|e| e.to_string())
}

/// Millis since the Unix epoch — the `created_at` stamp every record uses.
pub fn now_ms() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
