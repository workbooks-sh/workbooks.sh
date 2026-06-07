// Tauri command surface for memory-source management (wb-i38o.12).
//
// The actual work happens inside the Elixir sidecar — it owns the
// `~/.oql/memory/` store and the `Memory.WorkbookLoader` that
// extracts a workbook's source bundle and indexes its .org files.
// The desktop side is a thin façade:
//
//   1. Pre-flight scope check (same `active_folders` pattern as
//      fs_tree.rs / workbook_io.rs) so we return a clean error
//      without touching the agent for obvious workspace violations.
//   2. Push the request over the Phoenix WS bridge channel
//      `memory:control` and surface the reply.
//
// Step 2 happens in the JS bridge (workbook_io / ws.svelte.ts) —
// these Rust commands only do step 1 and then emit an event the JS
// side listens to. Keeping the channel push in JS means we don't
// duplicate the Phoenix client in Rust, and the bridge gets reused.
//
// The actual return values come from the WS round-trip; the Tauri
// command returns whatever the JS-side bridge resolves with by
// echoing the result through `app.emit` and `app.listen`. We keep
// this simple — the desktop UI calls the JS bridge directly for
// the round-trip and only uses these Tauri commands for the scope
// pre-flight + path canonicalisation.

#![allow(clippy::module_name_repetitions)]

use std::path::{Path, PathBuf};

use serde::Serialize;
use tokio::fs;

#[derive(Debug, Clone, Serialize)]
pub struct LoadResolution {
    /// Canonical absolute path the JS side should pass to the channel.
    pub canonical_path: String,
}

// ── Scope gate (mirrors workbook_io.rs / fs_tree.rs) ────────────────

async fn active_folders() -> Vec<String> {
    // wb-80q0.3 migration: delegate to config_paths::desktop_root
    // which resolves to ~/Workbooks/monorepo/ (overridable via
    // OQL_DATA_ROOT or OQL_DESKTOP_HOME for tests).
    let home = crate::config_paths::desktop_root();
    let state_path = home.join("state.json");
    let bytes = match fs::read(&state_path).await {
        Ok(b) => b,
        Err(_) => return vec![],
    };
    #[derive(serde::Deserialize)]
    struct State {
        #[serde(default)]
        active: Option<String>,
    }
    let state: State = match serde_json::from_slice(&bytes) {
        Ok(s) => s,
        Err(_) => return vec![],
    };
    let Some(name) = state.active else {
        return vec![];
    };
    let ws_path = home.join("workspaces").join(format!("{name}.json"));
    let bytes = match fs::read(&ws_path).await {
        Ok(b) => b,
        Err(_) => return vec![],
    };
    #[derive(serde::Deserialize)]
    struct Ws {
        #[serde(default)]
        folders: Vec<String>,
    }
    serde_json::from_slice::<Ws>(&bytes)
        .map(|w| w.folders)
        .unwrap_or_default()
}

fn path_in_any_root(path: &Path, roots: &[String]) -> bool {
    let Some(p) = path.to_str() else {
        return false;
    };
    roots.iter().any(|root| {
        p == root || p.starts_with(&format!("{root}/"))
    })
}

/// Pre-flight a workbook path before the JS bridge pushes it over the
/// `memory:control` channel. Returns the canonical absolute path the
/// JS side should send (matches how `Workbooks.Engine.WorkspaceScope.guard`
/// canonicalises on the Elixir side). Fails fast on:
///   * non-.html/.htm file
///   * path outside the active workspace
///   * unreadable file
///
/// Doesn't actually load the workbook — that's the Elixir side's job.
#[tauri::command]
pub async fn workbook_load_as_memory(html_path: String) -> Result<LoadResolution, String> {
    let raw = PathBuf::from(&html_path);
    let lower = html_path.to_lowercase();
    if !(lower.ends_with(".html") || lower.ends_with(".htm")) {
        return Err(format!("not an .html file: {html_path}"));
    }

    let roots = active_folders().await;
    if !path_in_any_root(&raw, &roots) {
        return Err(format!("workspace_scope_violation: {html_path}"));
    }

    // Canonicalise so the JS side and the Elixir side see the same
    // string (workspace-scope check on the Elixir side uses
    // Path.expand, which doesn't resolve symlinks — but desktop
    // already canonicalises every folder path before persisting, so
    // canonical→canonical matches.)
    let canonical = match fs::canonicalize(&raw).await {
        Ok(p) => p,
        Err(e) => return Err(format!("canonicalize {html_path}: {e}")),
    };
    let canonical_str = canonical
        .to_str()
        .ok_or_else(|| format!("non-utf8 path: {html_path}"))?
        .to_string();

    // Re-check scope against the canonical form to defeat symlink
    // games — if the symlink resolved outside the scope, reject.
    if !path_in_any_root(Path::new(&canonical_str), &roots) {
        return Err(format!("workspace_scope_violation: {canonical_str}"));
    }

    Ok(LoadResolution {
        canonical_path: canonical_str,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extension_check_rejects_non_html() {
        // Sanity — the public command is async so we just exercise
        // the predicate inline. The branch in workbook_load_as_memory
        // returns Err immediately.
        let lower = "/foo/bar.txt".to_lowercase();
        assert!(!(lower.ends_with(".html") || lower.ends_with(".htm")));
    }

    #[test]
    fn scope_matches_byte_prefix() {
        let roots = vec!["/foo/bar".to_string()];
        assert!(path_in_any_root(Path::new("/foo/bar/kb.html"), &roots));
        assert!(!path_in_any_root(Path::new("/foo/bar2/kb.html"), &roots));
    }
}
