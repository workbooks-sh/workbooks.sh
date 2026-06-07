// Workspace model — durable per-user set of named "workspaces", each
// being a collection of absolute folder paths the user has explicitly
// granted the OQL agent FS access to. VS-Code-multi-root in spirit;
// but the security primitive (not just a UI affordance) — the Elixir
// sidecar's tool layer fail-closes on paths outside the active set.
//
// On-disk layout (lives outside any project so it survives across
// repos and across desktop reinstalls):
//
//   ~/.oql/desktop/
//   ├── state.json                        { "active": "<name>" | null }
//   └── workspaces/
//       ├── <name>.json                   { "name", "folders": [abs...],
//       │                                    "view_mode": "source"|"compiled" }
//       └── ...
//
// All Tauri commands are async because the JSON files might grow if
// the user adds many folders; we don't want to block the UI thread.
//
// Names are constrained to [A-Za-z0-9._-]+ to keep them safe as
// filenames (no path traversal via a `..` name). Folder paths are
// canonicalised before persistence so symlink games can't sneak a
// path past the agent's scope check.

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use tauri::AppHandle;
use tokio::fs;
use tokio::sync::Mutex;

use once_cell::sync::OnceCell;

const WORKSPACE_NAME_MAX: usize = 64;

/// Default icon for a Package when none is supplied. Mirrors the
/// emoji palette used by `IconPickerMenu.svelte` on the workspace
/// side; chosen because the rail avatar still falls back to initials
/// if the front-end opts out — this is just the on-disk default.
const DEFAULT_PACKAGE_ICON: &str = "📦";

/// How the file tree filters what's shown (wb-i38o.14).
///
/// - `Source` (default) — show all files.
/// - `Compiled` — show only `.html` workbook files; hide everything else.
///
/// Persisted per workspace so the user's preference survives restarts
/// independently for each workspace.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ViewMode {
    #[default]
    Source,
    Compiled,
}

/// Per-Package default for the detail-panel layout (wb-i38o.38).
///
/// - `Grid` — iOS-springboard of every file with the
///   `workbook-spec` marker. Non-workbook files are hidden.
/// - `Tree` — full file tree (the legacy view).
///
/// Stored per Package; users can flip the in-panel switcher freely
/// without rewriting this, but new sessions default to whatever the
/// Package was last created or saved with.
#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Layout {
    #[default]
    Grid,
    Tree,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Workspace {
    pub name: String,
    pub folders: Vec<String>,
    /// Display icon — single emoji or short glyph rendered next to the
    /// package name in the rail and switcher. Pre-wb-i38o.34 packages
    /// have no ICON key on disk; deserialise to `DEFAULT_PACKAGE_ICON`.
    #[serde(default = "default_package_icon")]
    pub icon: String,
    /// File-tree view filter. Optional in the on-disk JSON for
    /// backward compatibility with pre-D14 workspace files;
    /// deserialises to `Source` when absent.
    #[serde(default)]
    pub view_mode: ViewMode,
    /// Default detail-panel layout (grid vs tree). Pre-wb-i38o.38
    /// packages have no LAYOUT key on disk; deserialise to `Grid`.
    #[serde(default)]
    pub layout: Layout,
    /// Optional git-subtree config — when set, this Package's folder
    /// inside the user-install monorepo is treated as a subtree
    /// against `remote_url`/`branch`. None means "lives directly in
    /// the monorepo." See `workspaces::SubtreeConfig` for the parallel
    /// field on the top-level Workspace.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtree: Option<crate::workspaces::SubtreeConfig>,
}

fn default_package_icon() -> String {
    DEFAULT_PACKAGE_ICON.to_string()
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
struct DesktopState {
    /// Currently-active workspace name. None until the user explicitly
    /// activates one (first-launch empty state).
    #[serde(default)]
    pub active: Option<String>,
}

/// Resolves the desktop config root. Delegates to
/// `config_paths::desktop_root` so this module follows
/// wb-80q0.3's data-root migration: returns ~/Workbooks/monorepo/
/// (or whatever OQL_DATA_ROOT / OQL_DESKTOP_HOME override to).
fn desktop_root() -> PathBuf {
    crate::config_paths::desktop_root()
}

fn workspaces_dir() -> PathBuf {
    desktop_root().join("workspaces")
}

fn state_path() -> PathBuf {
    desktop_root().join("state.json")
}

fn workspace_path(name: &str) -> PathBuf {
    workspaces_dir().join(format!("{name}.org"))
}

const PACKAGE_SCHEMA: &str = "package.v1";
/// The single-entry-per-file shape uses a sentinel heading title so
/// renames change just the file name, not on-disk content. The actual
/// human-facing name comes from the file stem.
const PACKAGE_ENTRY_TITLE: &str = "package";

fn validate_name(name: &str) -> Result<(), String> {
    if name.is_empty() || name.len() > WORKSPACE_NAME_MAX {
        return Err(format!(
            "workspace name must be 1..={WORKSPACE_NAME_MAX} chars"
        ));
    }
    if !name
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '_' || c == '-')
    {
        return Err("workspace name may only contain [A-Za-z0-9._-]".into());
    }
    if name == "." || name == ".." {
        return Err("workspace name cannot be . or ..".into());
    }
    Ok(())
}

/// Canonicalise + validate a folder path supplied by the user. We
/// require the path to exist + be a directory so the agent doesn't
/// later silently fail on a typo. Symlinks are resolved to their
/// target — the scope check on the agent side is purely byte-level
/// prefix matching, so we want canonical paths going in.
fn canonicalise_folder(folder: &str) -> Result<String, String> {
    let p = PathBuf::from(folder);
    let canon = std::fs::canonicalize(&p)
        .map_err(|e| format!("cannot resolve {folder}: {e}"))?;
    if !canon.is_dir() {
        return Err(format!("{} is not a directory", canon.display()));
    }
    canon
        .to_str()
        .map(String::from)
        .ok_or_else(|| format!("path is not valid UTF-8: {}", canon.display()))
}

async fn ensure_dirs() -> Result<(), String> {
    fs::create_dir_all(workspaces_dir())
        .await
        .map_err(|e| format!("mkdir workspaces dir: {e}"))?;
    Ok(())
}

async fn read_state() -> Result<DesktopState, String> {
    match fs::read(state_path()).await {
        Ok(bytes) => serde_json::from_slice::<DesktopState>(&bytes)
            .map_err(|e| format!("parse state.json: {e}")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(DesktopState::default()),
        Err(e) => Err(format!("read state.json: {e}")),
    }
}

async fn write_state(state: &DesktopState) -> Result<(), String> {
    ensure_dirs().await?;
    let bytes = serde_json::to_vec_pretty(state).map_err(|e| format!("serialise state: {e}"))?;
    fs::write(state_path(), bytes)
        .await
        .map_err(|e| format!("write state.json: {e}"))?;
    Ok(())
}

async fn read_workspace(name: &str) -> Result<Workspace, String> {
    validate_name(name)?;
    let descriptor_path = workspace_path(name);

    // If there's no .org descriptor, the package might exist as a bare
    // folder under one of the workspace dirs (the case the voice agent
    // creates: `mkdir -p <workspace>/<package>/`). Synthesize a
    // Workspace struct from the folder so the renderer can see it
    // without a separate write step. The .org descriptor is treated as
    // *enrichment* (icon, subtree config, etc.), not the source of
    // truth for "does this package exist."
    if !descriptor_path.exists() {
        if let Some(folder) = find_bare_package_folder(name).await {
            return Ok(Workspace {
                name: name.to_string(),
                folders: vec![folder.to_string_lossy().into_owned()],
                icon: default_package_icon(),
                view_mode: ViewMode::default(),
                layout: Layout::default(),
                subtree: None,
            });
        }
    }

    let entries = crate::org_kv::read_entries(&descriptor_path, PACKAGE_SCHEMA)
        .await
        .map_err(|e| format!("read package {name}: {e}"))?;
    let entry = entries
        .first()
        .ok_or_else(|| format!("package {name} is empty"))?;
    let folders: Vec<String> = entry
        .get("FOLDERS")
        .and_then(|s| serde_json::from_str(s).ok())
        .unwrap_or_default();
    let view_mode = match entry.get("VIEW_MODE") {
        Some("compiled") => ViewMode::Compiled,
        _ => ViewMode::Source,
    };
    let layout = match entry.get("LAYOUT") {
        Some("tree") => Layout::Tree,
        _ => Layout::Grid,
    };
    let icon = entry
        .get("ICON")
        .map(str::to_string)
        .unwrap_or_else(default_package_icon);
    let subtree =
        match (entry.get("SUBTREE_REMOTE"), entry.get("SUBTREE_BRANCH")) {
            (Some(r), Some(b)) => Some(crate::workspaces::SubtreeConfig {
                remote_url: r.to_string(),
                branch: b.to_string(),
            }),
            _ => None,
        };
    Ok(Workspace {
        name: name.to_string(),
        folders,
        icon,
        view_mode,
        layout,
        subtree,
    })
}

async fn write_workspace(ws: &Workspace) -> Result<(), String> {
    validate_name(&ws.name)?;
    ensure_dirs().await?;
    let mut entry = crate::org_kv::OrgEntry::new(PACKAGE_ENTRY_TITLE)
        .with(
            "FOLDERS",
            serde_json::to_string(&ws.folders).unwrap_or_default(),
        )
        .with("ICON", ws.icon.clone())
        .with(
            "VIEW_MODE",
            match ws.view_mode {
                ViewMode::Source => "source",
                ViewMode::Compiled => "compiled",
            },
        )
        .with(
            "LAYOUT",
            match ws.layout {
                Layout::Grid => "grid",
                Layout::Tree => "tree",
            },
        );
    if let Some(s) = &ws.subtree {
        entry = entry
            .with("SUBTREE_REMOTE", s.remote_url.clone())
            .with("SUBTREE_BRANCH", s.branch.clone());
    }
    crate::org_kv::write_entries(&workspace_path(&ws.name), PACKAGE_SCHEMA, &[entry]).await
}

// ── Cached active-scope (read by the bridge when the JS asks for it).
// Held in a Mutex because workspace mutations come in concurrently
// from any number of Tauri command invocations.
static ACTIVE: OnceCell<Mutex<Option<Workspace>>> = OnceCell::new();
fn active_cell() -> &'static Mutex<Option<Workspace>> {
    ACTIVE.get_or_init(|| Mutex::new(None))
}

async fn refresh_active_cache() {
    let state = read_state().await.unwrap_or_default();
    let new_active = match state.active {
        Some(name) => read_workspace(&name).await.ok(),
        None => None,
    };
    *active_cell().lock().await = new_active;
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn package_list() -> Result<Vec<String>, String> {
    ensure_dirs().await?;
    // BTreeSet dedupes + sorts. Packages can appear as either flat
    // .org descriptors at the top of workspaces/ (the legacy shape)
    // or as bare folders nested under a workspace dir (what the
    // voice agent creates with `mkdir -p <ws>/<pkg>/`). We surface
    // both so the rail updates the moment a folder appears.
    let mut names: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();

    let mut rd = fs::read_dir(workspaces_dir())
        .await
        .map_err(|e| format!("read workspaces dir: {e}"))?;
    while let Some(entry) = rd.next_entry().await.map_err(|e| e.to_string())? {
        let path = entry.path();
        // .org descriptors at the top level
        if path.extension().and_then(|s| s.to_str()) == Some("org") {
            if let Some(stem) = path.file_stem().and_then(|s| s.to_str()) {
                if validate_name(stem).is_ok() {
                    names.insert(stem.to_string());
                }
            }
        }
        // Bare workspace folders — scan their contents for packages.
        if path.is_dir() {
            if let Some(workspace_name) = path.file_name().and_then(|s| s.to_str()) {
                if workspace_name.starts_with('_') {
                    // Skip system workspaces like `_evals`.
                    continue;
                }
                let mut sub_rd = match fs::read_dir(&path).await {
                    Ok(r) => r,
                    Err(_) => continue,
                };
                while let Some(pkg_entry) =
                    sub_rd.next_entry().await.map_err(|e| e.to_string())?
                {
                    let pkg_path = pkg_entry.path();
                    if !pkg_path.is_dir() {
                        continue;
                    }
                    if let Some(pkg_name) =
                        pkg_path.file_name().and_then(|s| s.to_str())
                    {
                        if pkg_name.starts_with('.') {
                            continue;
                        }
                        if validate_name(pkg_name).is_ok() {
                            names.insert(pkg_name.to_string());
                        }
                    }
                }
            }
        }
    }

    Ok(names.into_iter().collect())
}

/// Locate a package folder by name across all workspace dirs.
/// Returns the first matching `<workspaces>/<workspace>/<name>/` path.
async fn find_bare_package_folder(name: &str) -> Option<PathBuf> {
    let mut rd = match fs::read_dir(workspaces_dir()).await {
        Ok(r) => r,
        Err(_) => return None,
    };
    while let Ok(Some(workspace_entry)) = rd.next_entry().await {
        let workspace_path = workspace_entry.path();
        if !workspace_path.is_dir() {
            continue;
        }
        let candidate = workspace_path.join(name);
        if candidate.is_dir() {
            return Some(candidate);
        }
    }
    None
}

#[tauri::command]
pub async fn package_load(name: String) -> Result<Workspace, String> {
    read_workspace(&name).await
}

#[tauri::command]
pub async fn package_create(
    name: String,
    icon: Option<String>,
) -> Result<Workspace, String> {
    validate_name(&name)?;
    if workspace_path(&name).exists() {
        return Err(format!("workspace {name} already exists"));
    }
    let ws = Workspace {
        name: name.clone(),
        folders: vec![],
        icon: icon
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(default_package_icon),
        view_mode: ViewMode::default(),
        layout: Layout::default(),
        subtree: None,
    };
    write_workspace(&ws).await?;
    Ok(ws)
}

/// Persist the Package's display icon. Mirrors `workspaces::workspaces_set_icon`
/// on the top-level Workspace side. No scope-change event — icon is
/// purely a front-end concern.
#[tauri::command]
pub async fn package_set_icon(
    name: String,
    icon: String,
) -> Result<Workspace, String> {
    let mut ws = read_workspace(&name).await?;
    ws.icon = if icon.trim().is_empty() {
        default_package_icon()
    } else {
        icon
    };
    write_workspace(&ws).await?;
    Ok(ws)
}

/// Persist the Package's default detail-panel layout (wb-i38o.38).
/// Pure front-end concern; no scope-change event.
#[tauri::command]
pub async fn package_set_layout(
    name: String,
    layout: Layout,
) -> Result<Workspace, String> {
    let mut ws = read_workspace(&name).await?;
    ws.layout = layout;
    write_workspace(&ws).await?;
    Ok(ws)
}

/// Recursively enumerate `.html` / `.htm` files under the Package's
/// folders that pass the workbook-marker scan (wb-i38o.37). One entry
/// per workbook with its absolute path and display title. Used by the
/// grid view (wb-i38o.38). Bounded by file count, parallel marker
/// scans via JoinSet so a package with 100 candidate files doesn't
/// serialise the I/O.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkbookEntry {
    pub path: String,
    pub title: String,
}

#[tauri::command]
pub async fn package_workbooks(name: String) -> Result<Vec<WorkbookEntry>, String> {
    let ws = read_workspace(&name).await?;
    let mut candidates: Vec<std::path::PathBuf> = Vec::new();
    for folder in &ws.folders {
        let root = std::path::PathBuf::from(folder);
        collect_html_candidates(&root, &mut candidates);
    }
    if candidates.is_empty() {
        return Ok(vec![]);
    }
    let mut joins = tokio::task::JoinSet::new();
    for path in candidates {
        joins.spawn(async move {
            let is_wb = crate::workbook_marker::scan(&path).await;
            (path, is_wb)
        });
    }
    let mut out: Vec<WorkbookEntry> = Vec::new();
    while let Some(res) = joins.join_next().await {
        let (path, is_wb) = res.map_err(|e| format!("scan task: {e}"))?;
        if !is_wb {
            continue;
        }
        let title = path
            .file_name()
            .and_then(|s| s.to_str())
            .unwrap_or("workbook")
            .trim_end_matches(".html")
            .trim_end_matches(".htm")
            .to_string();
        out.push(WorkbookEntry {
            path: path.to_string_lossy().into_owned(),
            title,
        });
    }
    out.sort_by(|a, b| a.title.to_ascii_lowercase().cmp(&b.title.to_ascii_lowercase()));
    Ok(out)
}

fn collect_html_candidates(root: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let entries = match std::fs::read_dir(root) {
        Ok(e) => e,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(ft) = entry.file_type() else { continue };
        if ft.is_dir() {
            // Skip common non-source dirs to keep the scan responsive.
            let skip = matches!(
                entry.file_name().to_str(),
                Some(".git" | "node_modules" | "target" | ".svelte-kit" | "dist" | "build")
            );
            if !skip {
                collect_html_candidates(&path, out);
            }
        } else if ft.is_file() {
            let ext = path
                .extension()
                .and_then(|e| e.to_str())
                .map(|s| s.to_ascii_lowercase())
                .unwrap_or_default();
            if ext == "html" || ext == "htm" {
                out.push(path);
            }
        }
    }
}

/// Persist the file-tree view filter for a workspace (wb-i38o.14).
/// No scope-change event is emitted — `view_mode` is purely a
/// front-end concern; the agent's scope is unaffected by what the
/// user is looking at.
#[tauri::command]
pub async fn package_set_view_mode(
    name: String,
    view_mode: ViewMode,
) -> Result<Workspace, String> {
    let mut ws = read_workspace(&name).await?;
    ws.view_mode = view_mode;
    write_workspace(&ws).await?;
    Ok(ws)
}

/// Set or clear the Package's git-subtree config. None clears.
#[tauri::command]
pub async fn package_set_subtree(
    name: String,
    subtree: Option<crate::workspaces::SubtreeConfig>,
) -> Result<Workspace, String> {
    let mut ws = read_workspace(&name).await?;
    ws.subtree = subtree;
    write_workspace(&ws).await?;
    Ok(ws)
}

#[tauri::command]
pub async fn package_delete(app: AppHandle, name: String) -> Result<(), String> {
    validate_name(&name)?;
    let path = workspace_path(&name);
    if path.exists() {
        fs::remove_file(&path)
            .await
            .map_err(|e| format!("delete workspace {name}: {e}"))?;
    }
    // If the deleted workspace was active, clear the pointer.
    let mut state = read_state().await?;
    if state.active.as_deref() == Some(name.as_str()) {
        state.active = None;
        write_state(&state).await?;
        refresh_active_cache().await;
        emit_scope_change(&app).await;
    }
    Ok(())
}

#[tauri::command]
pub async fn package_add_folder(
    app: AppHandle,
    name: String,
    path: String,
) -> Result<Workspace, String> {
    let canon = canonicalise_folder(&path)?;
    let mut ws = read_workspace(&name).await?;
    if !ws.folders.iter().any(|f| f == &canon) {
        ws.folders.push(canon);
        ws.folders.sort();
    }
    write_workspace(&ws).await?;
    if is_active(&name).await {
        refresh_active_cache().await;
        emit_scope_change(&app).await;
    }
    Ok(ws)
}

#[tauri::command]
pub async fn package_remove_folder(
    app: AppHandle,
    name: String,
    path: String,
) -> Result<Workspace, String> {
    let mut ws = read_workspace(&name).await?;
    ws.folders.retain(|f| f != &path);
    write_workspace(&ws).await?;
    if is_active(&name).await {
        refresh_active_cache().await;
        emit_scope_change(&app).await;
    }
    Ok(ws)
}

#[tauri::command]
pub async fn package_set_active(
    app: AppHandle,
    name: Option<String>,
) -> Result<Option<Workspace>, String> {
    let mut state = read_state().await?;
    match name {
        Some(n) => {
            // Validate it exists.
            let ws = read_workspace(&n).await?;
            state.active = Some(n);
            write_state(&state).await?;
            refresh_active_cache().await;
            emit_scope_change(&app).await;
            Ok(Some(ws))
        }
        None => {
            state.active = None;
            write_state(&state).await?;
            refresh_active_cache().await;
            emit_scope_change(&app).await;
            Ok(None)
        }
    }
}

/// Recursively copy `src` → `dst`. Sync I/O wrapped in `spawn_blocking`
/// at the call site. Skips `.DS_Store` because macOS users hit this
/// constantly and there's no upside to carrying it across.
///
/// On a name collision at the destination root, this errors rather
/// than silently merge — protect the user from clobbering an existing
/// package folder.
fn copy_dir_recursive_sync(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    if dst.exists() {
        return Err(format!(
            "destination already exists: {}",
            dst.display()
        ));
    }
    std::fs::create_dir_all(dst).map_err(|e| format!("mkdir {}: {e}", dst.display()))?;
    let mut stack: Vec<(std::path::PathBuf, std::path::PathBuf)> =
        vec![(src.to_path_buf(), dst.to_path_buf())];
    while let Some((cur_src, cur_dst)) = stack.pop() {
        let entries = std::fs::read_dir(&cur_src)
            .map_err(|e| format!("read_dir {}: {e}", cur_src.display()))?;
        for entry in entries {
            let entry = entry.map_err(|e| format!("dir entry: {e}"))?;
            let name = entry.file_name();
            if name == ".DS_Store" {
                continue;
            }
            let src_path = entry.path();
            let dst_path = cur_dst.join(&name);
            let ft = entry
                .file_type()
                .map_err(|e| format!("file_type {}: {e}", src_path.display()))?;
            if ft.is_dir() {
                std::fs::create_dir_all(&dst_path)
                    .map_err(|e| format!("mkdir {}: {e}", dst_path.display()))?;
                stack.push((src_path, dst_path));
            } else if ft.is_file() {
                std::fs::copy(&src_path, &dst_path)
                    .map_err(|e| format!("copy {}: {e}", src_path.display()))?;
            }
            // Symlinks are intentionally skipped — they often point
            // outside the source tree and would break in the new home.
            // If the user has legitimate intra-package symlinks they
            // can recreate them after the import.
        }
    }
    Ok(())
}

/// Import an external folder as a new Package: recursively copy it
/// into `~/Workbooks/monorepo/workspaces/<workspace>/<package>/`,
/// create the Package metadata pointing at the copied location, and
/// tag it onto the named Workspace. Replaces the pre-wb-i38o.35
/// "pick a folder, store the absolute path" flow — packages now live
/// inside the monorepo so git is the cross-machine sync story
/// (wb-i38o.35).
#[tauri::command]
pub async fn package_import_folder(
    app: AppHandle,
    workspace_name: String,
    package_name: String,
    source_path: String,
    icon: Option<String>,
) -> Result<Workspace, String> {
    validate_name(&package_name)?;
    if workspace_path(&package_name).exists() {
        return Err(format!("package {package_name} already exists"));
    }
    let src_canonical = canonicalise_folder(&source_path)?;
    let src = std::path::PathBuf::from(&src_canonical);

    let dst = desktop_root()
        .join("workspaces")
        .join(&workspace_name)
        .join(&package_name);
    if dst.exists() {
        return Err(format!(
            "destination already exists in monorepo: {}",
            dst.display()
        ));
    }

    // Copy off the async runtime — large trees would otherwise block
    // every other Tauri command in the same task pool.
    let src_for_blocking = src.clone();
    let dst_for_blocking = dst.clone();
    tokio::task::spawn_blocking(move || {
        copy_dir_recursive_sync(&src_for_blocking, &dst_for_blocking)
    })
    .await
    .map_err(|e| format!("copy task: {e}"))??;

    let dst_canonical = std::fs::canonicalize(&dst)
        .map_err(|e| format!("canonicalise dest {}: {e}", dst.display()))?
        .to_string_lossy()
        .into_owned();

    let ws = Workspace {
        name: package_name.clone(),
        folders: vec![dst_canonical],
        icon: icon
            .filter(|s| !s.trim().is_empty())
            .unwrap_or_else(default_package_icon),
        view_mode: ViewMode::default(),
        layout: Layout::default(),
        subtree: None,
    };
    write_workspace(&ws).await?;
    let _ = app;
    Ok(ws)
}

#[tauri::command]
pub async fn package_get_active() -> Result<Option<Workspace>, String> {
    let state = read_state().await?;
    match state.active {
        Some(name) => Ok(read_workspace(&name).await.ok()),
        None => Ok(None),
    }
}

async fn is_active(name: &str) -> bool {
    let state = read_state().await.unwrap_or_default();
    state.active.as_deref() == Some(name)
}

// ── Scope-push to the Elixir sidecar ────────────────────────────────
//
// Approach: emit a `workspace-scope-change` event with the new
// folder list. The Svelte WS bridge listens for it and pushes the
// scope down the WS bridge to a `workspace:control` channel on the
// agent side. We do NOT respawn the sidecar — env-var injection on
// boot would force a restart on every workspace change, which is
// invasive (sessions die, port re-discovery, etc.). A WS message is
// idempotent + cheap.

#[derive(Clone, Serialize)]
struct ScopeChangePayload {
    /// Active workspace name, or null if the user has cleared it.
    pub workspace: Option<String>,
    /// Canonical absolute folder paths the agent may touch.
    pub folders: Vec<String>,
}

async fn emit_scope_change(app: &AppHandle) {
    use tauri::Emitter;
    let cache = active_cell().lock().await;
    let payload = match cache.as_ref() {
        Some(ws) => ScopeChangePayload {
            workspace: Some(ws.name.clone()),
            folders: ws.folders.clone(),
        },
        None => ScopeChangePayload {
            workspace: None,
            folders: vec![],
        },
    };
    let _ = app.emit("workspace-scope-change", &payload);
}

/// Re-read `state.json` + the active package's `.org` descriptor + emit
/// `workspace-scope-change`. Used by the frontend when the watcher
/// observes an external edit to either file — covers the case where
/// state.json was rewritten by a CLI tool, an agent, or Claude editing
/// directly, and Rust's in-memory `active_cell` is now stale.
#[tauri::command]
pub async fn package_refresh_active(app: AppHandle) -> Result<(), String> {
    refresh_active_cache().await;
    emit_scope_change(&app).await;
    Ok(())
}

/// Called from `lib.rs::setup` so the cache is hydrated before the
/// WebView starts asking. Also fires a one-time scope-change emit so
/// late listeners get the boot value.
pub async fn boot(app: AppHandle) {
    if let Err(e) = ensure_dirs().await {
        log::warn!("[workspace] boot ensure_dirs: {e}");
    }
    refresh_active_cache().await;
    emit_scope_change(&app).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir_str() -> String {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "oql-desktop-test-{}-{}",
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

    #[test]
    fn validate_name_accepts_safe_names() {
        assert!(validate_name("project").is_ok());
        assert!(validate_name("my-thing_2").is_ok());
        assert!(validate_name("a.b.c").is_ok());
    }

    #[test]
    fn validate_name_rejects_unsafe_names() {
        assert!(validate_name("").is_err());
        assert!(validate_name("..").is_err());
        assert!(validate_name("a/b").is_err());
        assert!(validate_name("with space").is_err());
        assert!(validate_name(&"x".repeat(100)).is_err());
    }

    #[test]
    fn canonicalise_folder_requires_directory() {
        let tmp = tempdir_str();
        std::fs::create_dir_all(&tmp).unwrap();
        let canon = canonicalise_folder(&tmp).unwrap();
        assert!(std::path::Path::new(&canon).is_dir());
        let _ = std::fs::remove_dir_all(&tmp);

        assert!(canonicalise_folder("/definitely/does/not/exist/xyz").is_err());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn create_load_delete_roundtrip() {
        // Mutates a process-wide env var so any concurrent workspace
        // test in this module would race; the test suite keeps async
        // mutation isolated to this single async fn.
        let tmp = tempdir_str();
        std::env::set_var("OQL_DESKTOP_HOME", &tmp);

        let ws = package_create("alpha".into(), None).await.unwrap();
        assert_eq!(ws.name, "alpha");
        assert!(ws.folders.is_empty());
        // Defaults to the package icon when none supplied.
        assert_eq!(ws.icon, DEFAULT_PACKAGE_ICON);

        let names = package_list().await.unwrap();
        assert_eq!(names, vec!["alpha"]);

        let loaded = package_load("alpha".into()).await.unwrap();
        assert_eq!(loaded, ws);
        // Defaults to Source view (wb-i38o.14).
        assert_eq!(loaded.view_mode, ViewMode::Source);

        // Toggle the view mode and reload — must persist.
        let toggled =
            package_set_view_mode("alpha".into(), ViewMode::Compiled).await.unwrap();
        assert_eq!(toggled.view_mode, ViewMode::Compiled);
        let reloaded = package_load("alpha".into()).await.unwrap();
        assert_eq!(reloaded.view_mode, ViewMode::Compiled);

        std::env::remove_var("OQL_DESKTOP_HOME");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn view_mode_defaults_when_absent_in_json() {
        // A pre-D14 workspace file has no `view_mode` field. Must
        // accept it and deserialise to ViewMode::Source.
        let json = r#"{ "name": "legacy", "folders": [] }"#;
        let ws: Workspace = serde_json::from_str(json).unwrap();
        assert_eq!(ws.view_mode, ViewMode::Source);
    }

    #[test]
    fn view_mode_round_trips_through_json_as_lowercase() {
        let ws = Workspace {
            name: "n".into(),
            folders: vec![],
            icon: "📦".into(),
            view_mode: ViewMode::Compiled,
            layout: Layout::Tree,
            subtree: None,
        };
        let json = serde_json::to_string(&ws).unwrap();
        // Persisted lowercase, matching the TS bridge contract.
        assert!(json.contains("\"view_mode\":\"compiled\""));
        assert!(json.contains("\"layout\":\"tree\""));
        let back: Workspace = serde_json::from_str(&json).unwrap();
        assert_eq!(back.view_mode, ViewMode::Compiled);
        assert_eq!(back.layout, Layout::Tree);
    }

    #[test]
    fn layout_defaults_to_grid_when_missing_from_json() {
        let json = r#"{ "name": "legacy", "folders": [], "view_mode": "source" }"#;
        let ws: Workspace = serde_json::from_str(json).unwrap();
        assert_eq!(ws.layout, Layout::Grid);
    }

    #[test]
    fn icon_defaults_when_missing_from_json() {
        // Pre-wb-i38o.34 payloads have no `icon` key; deserialise to default.
        let json = r#"{ "name": "legacy", "folders": [], "view_mode": "source" }"#;
        let ws: Workspace = serde_json::from_str(json).unwrap();
        assert_eq!(ws.icon, DEFAULT_PACKAGE_ICON);
    }
}
