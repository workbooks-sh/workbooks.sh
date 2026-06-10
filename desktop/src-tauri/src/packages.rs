// Packages — the mid-tier of User → Workspace → Package. Each Package is a
// `<name>.org` descriptor under ~/Workbooks/monorepo/workspaces/ holding a flat
// property drawer (:folders: :icon: :view-mode: :layout: :subtree-*:). The
// active package is pointed to by state.json. Mutations that change the active
// scope emit `workspace-scope-change` so the agent's tool sandbox follows.

use crate::{orgprops, paths};
use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tauri::{AppHandle, Emitter};

const DEFAULT_ICON: &str = "📦";

fn descriptor_path(name: &str) -> PathBuf {
    paths::workspaces_dir().join(format!("{name}.org"))
}
fn state_path() -> PathBuf {
    paths::workspaces_dir().join("state.json")
}

#[derive(Serialize, Deserialize, Default)]
struct ActiveState {
    active: Option<String>,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct Subtree {
    pub remote_url: String,
    pub branch: String,
}

#[derive(Serialize)]
pub struct Package {
    pub name: String,
    /// "app" (a workbook opened as a window) or "folder" (a container
    /// listed with inline workbooks). Stored as the `:kind:` orgprop;
    /// absent on older descriptors → "folder".
    pub kind: String,
    pub folders: Vec<String>,
    pub icon: String,
    pub view_mode: String,
    pub layout: String,
    pub subtree: Option<Subtree>,
}

fn read_body(name: &str) -> Result<String, String> {
    std::fs::read_to_string(descriptor_path(name))
        .map_err(|e| format!("package {name}: {e}"))
}

fn write_body(name: &str, body: &str) -> Result<(), String> {
    let path = descriptor_path(name);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&path, body).map_err(|e| e.to_string())
}

fn parse_package(name: &str, body: &str) -> Package {
    let remote = orgprops::get(body, "subtree-remote");
    let branch = orgprops::get(body, "subtree-branch");
    let subtree = match (remote, branch) {
        (Some(r), Some(b)) if !r.is_empty() => Some(Subtree {
            remote_url: r,
            branch: b,
        }),
        _ => None,
    };
    Package {
        name: name.to_string(),
        kind: orgprops::get(body, "kind").unwrap_or_else(|| "folder".into()),
        folders: orgprops::get_list(body, "folders"),
        icon: orgprops::get(body, "icon").unwrap_or_else(|| DEFAULT_ICON.to_string()),
        view_mode: orgprops::get(body, "view-mode").unwrap_or_else(|| "source".into()),
        layout: orgprops::get(body, "layout").unwrap_or_else(|| "grid".into()),
        subtree,
    }
}

fn load_package(name: &str) -> Result<Package, String> {
    Ok(parse_package(name, &read_body(name)?))
}

fn load_active_state() -> ActiveState {
    paths::read_json(&state_path())
}

/// Emit the current authoritative scope (active package + its folders).
fn emit_scope(app: &AppHandle) {
    let st = load_active_state();
    let (workspace, folders) = match st.active.as_deref() {
        Some(name) => match load_package(name) {
            Ok(pkg) => (Some(pkg.name), pkg.folders),
            Err(_) => (None, Vec::new()),
        },
        None => (None, Vec::new()),
    };
    #[derive(Serialize, Clone)]
    struct ScopeChange {
        workspace: Option<String>,
        folders: Vec<String>,
    }
    let _ = app.emit("workspace-scope-change", ScopeChange { workspace, folders });
}

fn emit_tree_changed(app: &AppHandle) {
    #[derive(Serialize, Clone)]
    struct TreeChanged {
        root: String,
    }
    let _ = app.emit(
        "fs-tree-changed",
        TreeChanged {
            root: paths::workspaces_dir().to_string_lossy().to_string(),
        },
    );
}

#[tauri::command]
pub fn package_list() -> Vec<String> {
    let dir = paths::workspaces_dir();
    let mut names: Vec<String> = std::fs::read_dir(&dir)
        .map(|rd| {
            rd.flatten()
                .filter_map(|e| {
                    let p = e.path();
                    if p.extension().and_then(|x| x.to_str()) == Some("org") {
                        p.file_stem().map(|s| s.to_string_lossy().to_string())
                    } else {
                        None
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    names
}

#[tauri::command]
pub fn package_get_active() -> Option<Package> {
    let st = load_active_state();
    st.active.and_then(|n| load_package(&n).ok())
}

#[tauri::command]
pub fn package_load(name: String) -> Result<Package, String> {
    load_package(&name)
}

#[tauri::command]
pub fn package_create(
    app: AppHandle,
    name: String,
    icon: Option<String>,
    kind: Option<String>,
) -> Result<Package, String> {
    let mut body = String::new();
    body = orgprops::set(&body, "folders", "");
    body = orgprops::set(&body, "icon", &icon.unwrap_or_else(|| DEFAULT_ICON.to_string()));
    if let Some(k) = kind {
        body = orgprops::set(&body, "kind", &k);
    }
    write_body(&name, &body)?;
    emit_tree_changed(&app);
    load_package(&name)
}

#[tauri::command]
pub fn package_import_folder(
    app: AppHandle,
    workspace_name: String,
    package_name: String,
    source_path: String,
    icon: Option<String>,
) -> Result<Package, String> {
    let dest = paths::workspaces_dir()
        .join(&workspace_name)
        .join(&package_name);
    copy_dir(std::path::Path::new(&source_path), &dest)?;
    let dest_str = dest.to_string_lossy().to_string();
    let mut body = read_body(&package_name).unwrap_or_default();
    let mut folders = orgprops::get_list(&body, "folders");
    if !folders.contains(&dest_str) {
        folders.push(dest_str);
    }
    body = orgprops::set_list(&body, "folders", &folders);
    if let Some(ic) = icon {
        body = orgprops::set(&body, "icon", &ic);
    } else if orgprops::get(&body, "icon").is_none() {
        body = orgprops::set(&body, "icon", DEFAULT_ICON);
    }
    write_body(&package_name, &body)?;
    emit_tree_changed(&app);
    load_package(&package_name)
}

fn copy_dir(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(dst).map_err(|e| e.to_string())?;
    for entry in std::fs::read_dir(src).map_err(|e| e.to_string())? {
        let entry = entry.map_err(|e| e.to_string())?;
        let ty = entry.file_type().map_err(|e| e.to_string())?;
        let target = dst.join(entry.file_name());
        if ty.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), &target).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
pub fn package_set_icon(name: String, icon: String) -> Result<Package, String> {
    let body = orgprops::set(&read_body(&name)?, "icon", &icon);
    write_body(&name, &body)?;
    load_package(&name)
}

#[tauri::command]
pub fn package_delete(app: AppHandle, name: String) -> Result<(), String> {
    std::fs::remove_file(descriptor_path(&name)).map_err(|e| e.to_string())?;
    let mut st = load_active_state();
    if st.active.as_deref() == Some(&name) {
        st.active = None;
        paths::write_json(&state_path(), &st)?;
        emit_scope(&app);
    }
    emit_tree_changed(&app);
    Ok(())
}

#[tauri::command]
pub fn package_add_folder(name: String, path: String) -> Result<Package, String> {
    let body = read_body(&name)?;
    let mut folders = orgprops::get_list(&body, "folders");
    if !folders.contains(&path) {
        folders.push(path);
    }
    write_body(&name, &orgprops::set_list(&body, "folders", &folders))?;
    load_package(&name)
}

#[tauri::command]
pub fn package_remove_folder(name: String, path: String) -> Result<Package, String> {
    let body = read_body(&name)?;
    let mut folders = orgprops::get_list(&body, "folders");
    folders.retain(|f| f != &path);
    write_body(&name, &orgprops::set_list(&body, "folders", &folders))?;
    load_package(&name)
}

#[tauri::command]
pub fn package_set_active(app: AppHandle, name: Option<String>) -> Result<(), String> {
    paths::write_json(&state_path(), &ActiveState { active: name })?;
    emit_scope(&app);
    Ok(())
}

#[tauri::command]
pub fn package_refresh_active(app: AppHandle) -> Result<(), String> {
    emit_scope(&app);
    Ok(())
}

#[tauri::command]
pub fn package_set_layout(name: String, layout: String) -> Result<Package, String> {
    write_body(&name, &orgprops::set(&read_body(&name)?, "layout", &layout))?;
    load_package(&name)
}

#[tauri::command]
pub fn package_set_view_mode(name: String, view_mode: String) -> Result<Package, String> {
    write_body(
        &name,
        &orgprops::set(&read_body(&name)?, "view-mode", &view_mode),
    )?;
    load_package(&name)
}

#[tauri::command]
pub fn package_set_subtree(name: String, subtree: Option<Subtree>) -> Result<Package, String> {
    let mut body = read_body(&name)?;
    match subtree {
        Some(st) => {
            body = orgprops::set(&body, "subtree-remote", &st.remote_url);
            body = orgprops::set(&body, "subtree-branch", &st.branch);
        }
        None => {
            body = orgprops::remove(&body, "subtree-remote");
            body = orgprops::remove(&body, "subtree-branch");
        }
    }
    write_body(&name, &body)?;
    load_package(&name)
}

#[derive(Serialize)]
pub struct WorkbookEntry {
    pub path: String,
    pub title: String,
}

/// Walk the package's folders for *.html/*.htm files carrying the
/// workbook-spec marker; parse a title from the spec (parallel scan).
#[tauri::command]
pub fn package_workbooks(name: String) -> Result<Vec<WorkbookEntry>, String> {
    let pkg = load_package(&name)?;
    let mut html: Vec<String> = Vec::new();
    for folder in &pkg.folders {
        for entry in walkdir::WalkDir::new(folder).into_iter().flatten() {
            let ext = entry
                .path()
                .extension()
                .and_then(|e| e.to_str())
                .map(|e| e.to_lowercase());
            if matches!(ext.as_deref(), Some("html") | Some("htm")) {
                html.push(entry.path().to_string_lossy().to_string());
            }
        }
    }
    let mut entries: Vec<WorkbookEntry> = html
        .par_iter()
        .filter_map(|path| {
            let spec = crate::workbooks::read_spec(path)?;
            let title = spec
                .get("title")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string())
                .unwrap_or_else(|| {
                    std::path::Path::new(path)
                        .file_name()
                        .map(|n| n.to_string_lossy().to_string())
                        .unwrap_or_default()
                });
            Some(WorkbookEntry {
                path: path.clone(),
                title,
            })
        })
        .collect();
    entries.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()));
    Ok(entries)
}

/// First workbook reachable from the package's folders — the file an
/// `app` package opens as its window (wb-5fl.12; the webHost mock's
/// package_app_workbook contract, now real).
#[tauri::command]
pub fn package_app_workbook(name: String) -> Result<String, String> {
    let entries = package_workbooks(name.clone())?;
    entries
        .first()
        .map(|e| e.path.clone())
        .ok_or_else(|| format!("package {name} has no workbook"))
}

/// Move an item INTO a folder package (wb-5fl.12; drag-into-folder).
///   kind "workbook" → `item` is a file path; move it into the folder's
///                     first bound directory.
///   kind "app"      → `item` is a package name; move its workbooks into
///                     the folder, then delete the app package descriptor
///                     (the workspace binding self-heals frontend-side via
///                     the exists-filter).
#[tauri::command]
pub fn package_move_into(
    app: AppHandle,
    item: String,
    kind: String,
    folder: String,
) -> Result<(), String> {
    let dest_pkg = load_package(&folder)?;
    if dest_pkg.kind == "app" {
        return Err(format!("{folder} is an app, not a folder"));
    }
    let dest_dir = dest_pkg
        .folders
        .first()
        .cloned()
        .ok_or_else(|| format!("folder {folder} has no bound directory"))?;
    std::fs::create_dir_all(&dest_dir).map_err(|e| e.to_string())?;

    let move_file = |src: &str| -> Result<(), String> {
        let file = std::path::Path::new(src)
            .file_name()
            .ok_or_else(|| format!("bad path {src}"))?;
        let dst = std::path::Path::new(&dest_dir).join(file);
        // rename first (same volume); fall back to copy+remove across volumes.
        if std::fs::rename(src, &dst).is_err() {
            std::fs::copy(src, &dst).map_err(|e| e.to_string())?;
            std::fs::remove_file(src).map_err(|e| e.to_string())?;
        }
        Ok(())
    };

    match kind.as_str() {
        "workbook" => move_file(&item)?,
        "app" => {
            for wb in package_workbooks(item.clone())? {
                move_file(&wb.path)?;
            }
            // Drop the app's descriptor; clear active if it pointed here.
            let _ = std::fs::remove_file(descriptor_path(&item));
            let mut st = load_active_state();
            if st.active.as_deref() == Some(item.as_str()) {
                st.active = None;
                paths::write_json(&state_path(), &st)?;
                emit_scope(&app);
            }
        }
        other => return Err(format!("unknown move kind: {other}")),
    }
    emit_tree_changed(&app);
    Ok(())
}
