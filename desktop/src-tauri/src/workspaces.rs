// Top-level Workspaces — the outer tier of User → Workspace → Package. Stored
// as a single JSON index (workspaces.json under ~/.workbooks/config) plus an
// active-id pointer. A Workspace groups package names + an optional git-subtree.

use crate::paths;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

fn ws_path() -> PathBuf {
    paths::config_dir().join("workspaces.json")
}

#[derive(Serialize, Deserialize, Clone)]
pub struct SubtreeConfig {
    pub remote_url: String,
    pub branch: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub package_names: Vec<String>,
    pub created_at: u64,
    #[serde(default)]
    pub subtree: Option<SubtreeConfig>,
}

#[derive(Serialize, Deserialize, Default)]
struct WsIndex {
    workspaces: Vec<Workspace>,
    active_id: Option<String>,
}

fn load() -> WsIndex {
    paths::read_json(&ws_path())
}
fn save(idx: &WsIndex) -> Result<(), String> {
    paths::write_json(&ws_path(), idx)
}

fn mutate(id: &str, f: impl FnOnce(&mut Workspace)) -> Result<(), String> {
    let mut idx = load();
    if let Some(w) = idx.workspaces.iter_mut().find(|w| w.id == id) {
        f(w);
    }
    save(&idx)
}

#[tauri::command]
pub fn workspace_list() -> Vec<Workspace> {
    let mut idx = load();
    idx.workspaces.sort_by_key(|w| w.created_at);
    idx.workspaces
}

#[tauri::command]
pub fn workspace_get_active() -> Option<Workspace> {
    let idx = load();
    idx.active_id
        .and_then(|id| idx.workspaces.into_iter().find(|w| w.id == id))
}

#[derive(Deserialize)]
pub struct WorkspaceCreate {
    pub name: String,
    #[serde(default)]
    pub icon: String,
}

#[tauri::command]
pub fn workspace_create(req: WorkspaceCreate) -> Result<Workspace, String> {
    let mut idx = load();
    let w = Workspace {
        id: uuid::Uuid::new_v4().to_string(),
        name: req.name,
        icon: req.icon,
        package_names: Vec::new(),
        created_at: paths::now_ms(),
        subtree: None,
    };
    idx.workspaces.push(w.clone());
    save(&idx)?;
    Ok(w)
}

#[tauri::command]
pub fn workspace_set_active(id: Option<String>) -> Result<(), String> {
    let mut idx = load();
    idx.active_id = id;
    save(&idx)
}

#[derive(Deserialize)]
pub struct WorkspaceRename {
    pub id: String,
    pub name: String,
}

#[tauri::command]
pub fn workspace_rename(req: WorkspaceRename) -> Result<(), String> {
    mutate(&req.id, |w| w.name = req.name)
}

#[derive(Deserialize)]
pub struct WorkspaceSetIcon {
    pub id: String,
    pub icon: String,
}

#[tauri::command]
pub fn workspace_set_icon(req: WorkspaceSetIcon) -> Result<(), String> {
    mutate(&req.id, |w| w.icon = req.icon)
}

#[tauri::command]
pub fn workspace_delete(id: String) -> Result<(), String> {
    let mut idx = load();
    idx.workspaces.retain(|w| w.id != id);
    if idx.active_id.as_deref() == Some(&id) {
        idx.active_id = None;
    }
    save(&idx)
}

#[derive(Deserialize)]
pub struct WorkspacePackage {
    pub workspace_id: String,
    pub package_name: String,
}

#[tauri::command]
pub fn workspace_add_package(req: WorkspacePackage) -> Result<(), String> {
    mutate(&req.workspace_id, |w| {
        if !w.package_names.contains(&req.package_name) {
            w.package_names.push(req.package_name);
        }
    })
}

#[tauri::command]
pub fn workspace_remove_package(req: WorkspacePackage) -> Result<(), String> {
    mutate(&req.workspace_id, |w| {
        w.package_names.retain(|p| p != &req.package_name)
    })
}

#[derive(Deserialize)]
pub struct WorkspaceSetSubtree {
    pub id: String,
    pub subtree: Option<SubtreeConfig>,
}

#[tauri::command]
pub fn workspace_set_subtree(req: WorkspaceSetSubtree) -> Result<(), String> {
    mutate(&req.id, |w| w.subtree = req.subtree)
}
