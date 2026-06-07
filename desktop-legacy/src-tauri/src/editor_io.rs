// wb-i38o.10 — editor write-back commands for the org-file viewer +
// minimal editor. Two commands + one event:
//
//   * `file_save(path, contents)` — UTF-8 write, gated against the
//     active workspace scope (D3). On success, emits `file-saved
//     { path, mtime_ms }` so the bridge can forward it to the
//     oql-agent (memory reindex, etc. — optional consumer for v1).
//   * `file_mtime(path)` — returns the file's modified-time in
//     milliseconds since epoch. The Svelte side uses this for the
//     "external change detected" banner when the OS file watcher
//     isn't enough (or when polling on focus).
//
// Workspace-scope check is identical to fs_tree::tab_open / tree_walk
// so the agent + UI + editor can't bypass the active scope.

use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Runtime};

use crate::fs_tree::{active_folders, path_in_any_root};

#[derive(Debug, Clone, Serialize)]
struct FileSavedPayload {
    path: String,
    mtime_ms: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct SaveResult {
    pub mtime_ms: u64,
}

async fn check_scope(path: &str) -> Result<(), String> {
    let roots = active_folders().await;
    if roots.is_empty() || path_in_any_root(Path::new(path), &roots) {
        return Ok(());
    }
    Err(format!("workspace_scope_violation: {path}"))
}

fn mtime_ms_of(path: &Path) -> Result<u64, String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("stat({}): {e}", path.display()))?;
    let mt = meta
        .modified()
        .map_err(|e| format!("mtime({}): {e}", path.display()))?;
    let dur = mt
        .duration_since(UNIX_EPOCH)
        .unwrap_or_else(|_| SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default());
    Ok(dur.as_millis() as u64)
}

#[tauri::command]
pub async fn file_save<R: Runtime>(
    app: AppHandle<R>,
    path: String,
    contents: String,
) -> Result<SaveResult, String> {
    check_scope(&path).await?;
    std::fs::write(&path, contents.as_bytes())
        .map_err(|e| format!("file_save({path}): {e}"))?;
    let mtime_ms = mtime_ms_of(Path::new(&path))?;
    let _ = app.emit(
        "file-saved",
        &FileSavedPayload {
            path: path.clone(),
            mtime_ms,
        },
    );
    log::info!("[editor_io] file_save: {path} mtime_ms={mtime_ms}");
    Ok(SaveResult { mtime_ms })
}

#[tauri::command]
pub async fn file_mtime(path: String) -> Result<u64, String> {
    check_scope(&path).await?;
    mtime_ms_of(Path::new(&path))
}
