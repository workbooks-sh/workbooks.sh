// The open-document list. The HOST owns the canonical tabs so the agent (and any
// window) can mutate it; the frontend reads via `tab_list` then applies the
// snapshot every mutation returns. Mutations also emit `tabs-state` so other
// listeners (and the future agent surface) stay synced. In-memory only — tab
// persistence across restarts lands with the plugin-store work (wb-jay.16).

use serde::Serialize;
use std::sync::Mutex;
use tauri::{Emitter, State};

#[derive(Serialize, Clone)]
pub struct Tab {
    pub id: String,
    pub title: String,
    pub path: String,
    pub kind: String,
    pub dirty: bool,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct TabsSnapshot {
    pub tabs: Vec<Tab>,
    pub active_id: Option<String>,
}

#[derive(Default)]
pub struct TabManager {
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    tabs: Vec<Tab>,
    active_id: Option<String>,
    seq: u64,
}

impl Inner {
    fn snapshot(&self) -> TabsSnapshot {
        TabsSnapshot {
            tabs: self.tabs.clone(),
            active_id: self.active_id.clone(),
        }
    }
}

fn kind_for(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_lowercase();
    match ext.as_str() {
        "org" => "org",
        "rs" | "ts" | "js" | "py" | "go" | "ex" | "exs" | "c" | "zig" | "toml" | "json" => "code",
        _ => "text",
    }
}

fn title_for(path: &str) -> String {
    path.rsplit(['/', '\\']).next().unwrap_or(path).to_string()
}

/// Apply a mutation, then emit + return the fresh snapshot. Every command routes
/// through here so the event + return value never drift.
fn commit(app: &tauri::AppHandle, inner: &Inner) -> TabsSnapshot {
    let snap = inner.snapshot();
    let _ = app.emit("tabs-state", &snap);
    snap
}

#[tauri::command]
pub fn tab_list(mgr: State<TabManager>) -> TabsSnapshot {
    mgr.inner.lock().unwrap().snapshot()
}

#[tauri::command]
pub fn tab_open(app: tauri::AppHandle, mgr: State<TabManager>, path: String) -> TabsSnapshot {
    let mut inner = mgr.inner.lock().unwrap();
    // Re-focus if already open (path is the identity).
    if let Some(existing) = inner.tabs.iter().find(|t| t.path == path) {
        inner.active_id = Some(existing.id.clone());
        return commit(&app, &inner);
    }
    inner.seq += 1;
    let id = format!("tab-{}", inner.seq);
    inner.tabs.push(Tab {
        id: id.clone(),
        title: title_for(&path),
        kind: kind_for(&path).to_string(),
        path,
        dirty: false,
    });
    inner.active_id = Some(id);
    commit(&app, &inner)
}

#[tauri::command]
pub fn tab_focus(app: tauri::AppHandle, mgr: State<TabManager>, id: String) -> TabsSnapshot {
    let mut inner = mgr.inner.lock().unwrap();
    if inner.tabs.iter().any(|t| t.id == id) {
        inner.active_id = Some(id);
    }
    commit(&app, &inner)
}

#[tauri::command]
pub fn tab_close(app: tauri::AppHandle, mgr: State<TabManager>, id: String) -> TabsSnapshot {
    let mut inner = mgr.inner.lock().unwrap();
    let idx = inner.tabs.iter().position(|t| t.id == id);
    if let Some(idx) = idx {
        inner.tabs.remove(idx);
        if inner.active_id.as_deref() == Some(&id) {
            // Focus the neighbour that slid into this slot, else the last tab.
            inner.active_id = inner
                .tabs
                .get(idx)
                .or_else(|| inner.tabs.last())
                .map(|t| t.id.clone());
        }
    }
    commit(&app, &inner)
}

#[tauri::command]
pub fn tab_set_dirty(app: tauri::AppHandle, mgr: State<TabManager>, id: String, dirty: bool) {
    let mut inner = mgr.inner.lock().unwrap();
    if let Some(t) = inner.tabs.iter_mut().find(|t| t.id == id) {
        t.dirty = dirty;
    }
    let _ = commit(&app, &inner);
}
