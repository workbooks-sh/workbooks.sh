// wb-i38o.8 — tab state owned by the Tauri host.
//
// Tabs are app state, not URL routes. We keep the canonical list
// here so the agent (wb-i38o.11) and the UI both talk to the same
// authoritative tab list via Tauri commands:
//
//   tab_open(path)   -> opens (or focuses if already open) and returns Tab
//   tab_close(id)    -> closes by id, returns updated list
//   tab_focus(id)    -> sets active tab, returns updated list
//   tab_list()       -> snapshot
//
// State changes also emit `tabs-state` events so the frontend can
// stay in sync regardless of which side initiated the change. This
// is the foundation for D11 (agent-controlled tabs).
//
// File content reading lives in `read_file_text` here too — the
// tabbed viewer needs to slurp .org / .html / code-file bytes. We
// keep it text-only for v1 (no binary reads). Workspace-permission
// gating (D3) is intentionally not enforced here yet; D7's file
// tree is the next surface that will need it, and gating both
// against the workspace model lands together.

use std::path::Path;
use std::sync::{Mutex, OnceLock};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Runtime, State};

use crate::fs_tree::{active_folders, path_in_any_root};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Tab {
    pub id: String,
    pub path: String,
    pub title: String,
    pub kind: TabKind,
    pub dirty: bool,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum TabKind {
    Workbook,
    Org,
    Code,
    Text,
}

impl TabKind {
    /// Extension-only classifier. Treats `.html` / `.htm` as the
    /// *candidate* workbook kind — call `detect` if you need the
    /// authoritative answer (wb-i38o.37).
    fn from_path(path: &str) -> Self {
        let ext = std::path::Path::new(path)
            .extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase())
            .unwrap_or_default();
        match ext.as_str() {
            "html" | "htm" => TabKind::Workbook,
            "org" => TabKind::Org,
            "ts" | "tsx" | "js" | "jsx" | "mjs" | "cjs" | "lua" | "ex" | "exs" | "rs"
            | "json" | "md" | "toml" | "yaml" | "yml" | "css" | "scss" | "svelte" | "html.j2"
            | "py" | "go" | "sh" | "bash" | "zsh" | "fish" => TabKind::Code,
            _ => TabKind::Text,
        }
    }

    /// Authoritative kind classifier (wb-i38o.37). For `.html` /
    /// `.htm` candidates, verifies the file actually contains the
    /// `workbook-spec` marker via `workbook_marker::scan`; if the
    /// marker is absent the file is reclassified as `Code` so it
    /// opens in the source editor instead of the workbook iframe.
    pub async fn detect(path: &str) -> Self {
        let kind = Self::from_path(path);
        if kind == TabKind::Workbook
            && !crate::workbook_marker::scan(std::path::Path::new(path)).await
        {
            return TabKind::Code;
        }
        kind
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TabsSnapshot {
    pub tabs: Vec<Tab>,
    pub active: Option<String>,
}

#[derive(Default)]
struct TabsInner {
    tabs: Vec<Tab>,
    active: Option<String>,
    next_id: u64,
}

pub struct TabsState(Mutex<TabsInner>);

impl Default for TabsState {
    fn default() -> Self {
        TabsState(Mutex::new(TabsInner::default()))
    }
}

impl TabsState {
    fn snapshot(&self) -> TabsSnapshot {
        let inner = self.0.lock().expect("tabs mutex poisoned");
        TabsSnapshot {
            tabs: inner.tabs.clone(),
            active: inner.active.clone(),
        }
    }
}

fn emit_state<R: Runtime>(app: &AppHandle<R>, snap: &TabsSnapshot) {
    let _ = app.emit("tabs-state", snap);
}

fn next_id(inner: &mut TabsInner) -> String {
    inner.next_id += 1;
    format!("tab-{}", inner.next_id)
}

fn title_from_path(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(path)
        .to_string()
}

#[tauri::command]
pub fn tab_list(state: State<'_, TabsState>) -> TabsSnapshot {
    state.snapshot()
}

#[tauri::command]
pub async fn tab_open<R: Runtime>(
    app: AppHandle<R>,
    state: State<'_, TabsState>,
    path: String,
) -> Result<TabsSnapshot, String> {
    // User-facing reads are scoped to the data root (~/Workbooks/),
    // not to the active package. The user owns their whole monorepo
    // and should be able to open any file inside it; the active-
    // package scope is for agent tools (engine WorkspaceScope) where
    // it actually matters that the agent stays in its lane. Keeping
    // both layers had the user staring at "workspace_scope_violation"
    // when they tried to open a Liquid Death file while UGC Pro
    // wasn't the active package — exactly the wrong default for a
    // human user.
    ensure_in_data_root(&path)?;
    // Resolve the kind *before* taking the mutex — `detect` does an
    // async head-read on `.html` candidates and we don't want to hold
    // the std `Mutex` across that await.
    let kind = TabKind::detect(&path).await;
    {
        let mut inner = state.0.lock().expect("tabs mutex poisoned");
        // Re-focus existing tab if path already open.
        if let Some(existing) = inner.tabs.iter().find(|t| t.path == path).cloned() {
            inner.active = Some(existing.id.clone());
        } else {
            let id = next_id(&mut inner);
            let tab = Tab {
                id: id.clone(),
                title: title_from_path(&path),
                kind,
                path,
                dirty: false,
            };
            inner.tabs.push(tab);
            inner.active = Some(id);
        }
    }
    let snap = state.snapshot();
    emit_state(&app, &snap);
    Ok(snap)
}

#[tauri::command]
pub fn tab_close<R: Runtime>(
    app: AppHandle<R>,
    state: State<'_, TabsState>,
    id: String,
) -> TabsSnapshot {
    {
        let mut inner = state.0.lock().expect("tabs mutex poisoned");
        let pos = inner.tabs.iter().position(|t| t.id == id);
        if let Some(pos) = pos {
            inner.tabs.remove(pos);
            if inner.active.as_deref() == Some(id.as_str()) {
                // Activate the neighbor — prefer the previous index, fall
                // back to the next, else none.
                let new_active = if pos > 0 {
                    inner.tabs.get(pos - 1).map(|t| t.id.clone())
                } else {
                    inner.tabs.first().map(|t| t.id.clone())
                };
                inner.active = new_active;
            }
        }
    }
    let snap = state.snapshot();
    emit_state(&app, &snap);
    snap
}

#[tauri::command]
pub fn tab_set_dirty<R: Runtime>(
    app: AppHandle<R>,
    state: State<'_, TabsState>,
    id: String,
    dirty: bool,
) -> TabsSnapshot {
    {
        let mut inner = state.0.lock().expect("tabs mutex poisoned");
        if let Some(tab) = inner.tabs.iter_mut().find(|t| t.id == id) {
            tab.dirty = dirty;
        }
    }
    let snap = state.snapshot();
    emit_state(&app, &snap);
    snap
}

#[tauri::command]
pub fn tab_focus<R: Runtime>(
    app: AppHandle<R>,
    state: State<'_, TabsState>,
    id: String,
) -> TabsSnapshot {
    {
        let mut inner = state.0.lock().expect("tabs mutex poisoned");
        if inner.tabs.iter().any(|t| t.id == id) {
            inner.active = Some(id);
        }
    }
    let snap = state.snapshot();
    emit_state(&app, &snap);
    snap
}

/// Scope guard for renderer-callable file reads (wb-u2o0.7.3).
///
/// Both `read_file_text` and `read_file_bytes_base64` are reachable from
/// the (now CSP-locked) renderer. Pre-this-fix they accepted any
/// absolute path — any XSS regression turned them into
/// "exfiltrate ~/.ssh/id_ed25519, ~/Library/Cookies, the Workhorse
/// Postgres dir". Now they require the canonicalised path to live
/// inside the documented data root (`~/Workbooks/`).
pub(crate) fn ensure_in_data_root<P: AsRef<std::path::Path>>(
    path: P,
) -> Result<std::path::PathBuf, String> {
    let p = path.as_ref();
    let canonical = p
        .canonicalize()
        .map_err(|e| format!("path resolve: {e}"))?;
    // One data-root definition, shared with config_paths + the Elixir
    // DataRoot (honors OQL_DATA_ROOT). The IPC guard must agree with
    // the rest of the app on where the boundary is.
    let data_root = crate::config_paths::data_root();
    let data_root_canon = data_root
        .canonicalize()
        .map_err(|e| format!("data root not found at {}: {e}", data_root.display()))?;
    if !canonical.starts_with(&data_root_canon) {
        return Err(format!(
            "path {} is outside the Workbooks data root",
            canonical.display()
        ));
    }
    Ok(canonical)
}

#[tauri::command]
pub fn read_file_text(path: String) -> Result<String, String> {
    let canonical = ensure_in_data_root(&path)?;
    std::fs::read_to_string(&canonical)
        .map_err(|e| format!("read_file_text({}): {e}", canonical.display()))
}

#[tauri::command]
pub fn read_file_bytes_base64(path: String) -> Result<String, String> {
    use base64::Engine as _;
    let canonical = ensure_in_data_root(&path)?;
    let bytes = std::fs::read(&canonical)
        .map_err(|e| format!("read_file_bytes_base64({}): {e}", canonical.display()))?;
    Ok(base64::engine::general_purpose::STANDARD.encode(bytes))
}

#[cfg(test)]
mod scope_tests {
    use super::ensure_in_data_root;

    #[test]
    fn rejects_etc_passwd() {
        // canonicalize() fails on a nonexistent path too, but /etc/passwd
        // exists on macOS+Linux; that's the real attack target.
        let r = ensure_in_data_root("/etc/passwd");
        assert!(r.is_err(), "expected reject, got {r:?}");
    }

    #[test]
    fn rejects_dot_dot_escape() {
        let r = ensure_in_data_root("/tmp/../etc/passwd");
        assert!(r.is_err(), "expected reject, got {r:?}");
    }
}

/// Resolve the absolute path of the bundled `kitchen-sink.org` example
/// shipped by the oql-container spike. The demo "Open kitchen-sink"
/// button uses this so the user doesn't have to know the on-disk
/// layout. In dev, this is just walked relative to the Tauri exe; in
/// the bundled app we'll need to copy the example in as a resource —
/// tracked as a TODO once D16 packaging lands.
#[tauri::command]
pub fn demo_kitchen_sink_path<R: Runtime>(app: AppHandle<R>) -> Result<String, String> {
    let _ = app; // currently unused — kept for future resource-dir resolution
    // Walk up from the workbooks-desktop bin to the monorepo root and
    // append the spike path. This works because in dev the binary
    // lives under desktop/src-tauri/target/debug/ and in `tauri
    // build` it lives under target/release.
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut cursor = exe.as_path();
    static SUFFIX: OnceLock<&str> = OnceLock::new();
    let suffix = SUFFIX
        .get_or_init(|| "packages/workbooks/spikes/oql-container/examples/kitchen-sink.org");
    while let Some(parent) = cursor.parent() {
        let candidate = parent.join(suffix);
        if candidate.exists() {
            return candidate
                .to_str()
                .map(|s| s.to_string())
                .ok_or_else(|| "non-utf8 path".to_string());
        }
        cursor = parent;
    }
    Err(format!(
        "could not locate {suffix} above {}",
        exe.display()
    ))
}
