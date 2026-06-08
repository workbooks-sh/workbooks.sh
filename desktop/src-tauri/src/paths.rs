// Canonical on-disk locations the native shell owns. Centralised so every
// module agrees on where config / descriptors / app-data live and so tests can
// override the roots via env.
//
//   ~/.oql/desktop/            — local config: keys.json, env-vars.json,
//                                themes, mcp-servers.json, plugins.json,
//                                agent-settings.org, setup.json, connections.json
//   ~/Workbooks/monorepo/workspaces/  — package descriptors (<name>.org) + state.json
//   <app_data>/sh.workbooks/   — identity.json, packages/<ws>.html
//
// All overridable with WB_OQL_DIR / WB_MONOREPO_DIR / WB_DESKTOP_DIR so the
// suite (and headless CI) can sandbox writes.

use std::path::PathBuf;

/// `~/.oql/desktop` — the local-config root. Created on demand.
pub fn oql_desktop_dir() -> PathBuf {
    if let Ok(p) = std::env::var("WB_OQL_DIR") {
        return PathBuf::from(p);
    }
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join(".oql").join("desktop")
}

/// `~/Workbooks/monorepo/workspaces` — package descriptors + state.json.
pub fn workspaces_dir() -> PathBuf {
    if let Ok(p) = std::env::var("WB_MONOREPO_DIR") {
        return PathBuf::from(p).join("workspaces");
    }
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    home.join("Workbooks")
        .join("monorepo")
        .join("workspaces")
}

/// Application-support data root (`<app_data>/sh.workbooks`).
pub fn app_data_dir() -> PathBuf {
    if let Ok(p) = std::env::var("WB_APP_DATA_DIR") {
        return PathBuf::from(p);
    }
    let base = dirs::data_dir().unwrap_or_else(|| PathBuf::from("."));
    base.join("sh.workbooks")
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
