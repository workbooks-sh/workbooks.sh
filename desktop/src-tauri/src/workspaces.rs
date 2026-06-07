// Top-level Workspaces (per the canonical model — User → Workspace → Package).
//
// A Workspace is an organisational namespace inside the desktop app:
// "day job", "startup", "personal", etc. Each workspace owns a list of
// packages (the FS-scope holders that live in `workspace.rs` for now —
// to be renamed `packages.rs`). Switching workspaces filters which
// packages show in the rail.
//
// See docs/canonical-model.md.
//
// On-disk layout — single file under the desktop config root:
//
//   ~/.oql/desktop/
//   ├── workspaces-top.json     ← THIS FILE (top-level workspaces)
//   ├── state.json              (active package — workspace.rs legacy name)
//   ├── workspaces/             (package definitions — workspace.rs)
//   ├── keys.json
//   ├── mcp-servers.json
//   └── plugins.json
//
// Filename is `workspaces-top.json` so it can't collide with the older
// `workspaces/` directory used by the package layer. Migration to the
// preferred name (`workspaces.json` + rename of the legacy dir to
// `packages/`) lands when that rename ships.
//
// Schema:
//
//   {
//     "active_id": "<id-or-null>",
//     "workspaces": [
//       {
//         "id":         "<short id>",
//         "name":       "Day job",
//         "icon":       "💼",           // emoji or single char; empty = use initials
//         "package_names": ["acme-web", "acme-api"],
//         "created_at": <unix-millis>
//       },
//       ...
//     ]
//   }
//
// The `package_names` field references package (Rust workspace) names
// by id — they live separately in `workspace.rs`. Empty list is fine;
// a workspace can exist with zero packages.

#![allow(clippy::module_name_repetitions)]

use std::path::PathBuf;

use tokio::fs;
use serde::{Deserialize, Serialize};

use crate::config_paths::desktop_root;
use crate::org_kv::{self, OrgEntry};

const WORKSPACES_FILE: &str = "workspaces.org";
const SCHEMA: &str = "workspaces.v1";
/// First-class header keyword carrying the active workspace id; lives
/// in the file's header alongside `#+SCHEMA:`. Falls back to `None`
/// when the user hasn't picked one yet.
const ACTIVE_KEYWORD: &str = "#+ACTIVE:";

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    /// Emoji or single-char icon. Empty string = render initials in UI.
    #[serde(default)]
    pub icon: String,
    #[serde(default)]
    pub package_names: Vec<String>,
    /// Names the user has explicitly detached from the rail via the
    /// "Remove from workspace" action. `merge_disk_packages` skips
    /// these so a folder that still exists on disk doesn't get
    /// auto-re-added on the next refresh. Re-attaching (or the agent
    /// re-creating the folder under a new name) clears the entry.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed_packages: Vec<String>,
    pub created_at: i64,
    /// Optional git-subtree config — when set, this workspace's
    /// directory inside the user-install monorepo is treated as a
    /// subtree against `remote_url`/`branch`. None means "lives
    /// directly in the monorepo, no separate remote." See
    /// docs/canonical-model.md and the GitHub integration panel.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subtree: Option<SubtreeConfig>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct SubtreeConfig {
    /// Remote git URL — `git@github.com:org/repo.git` or `https://…`.
    pub remote_url: String,
    /// Branch on the remote, defaults to `main` when set via the UI.
    pub branch: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default)]
struct WorkspacesFile {
    #[serde(default)]
    active_id: Option<String>,
    #[serde(default)]
    workspaces: Vec<Workspace>,
}

fn workspaces_path() -> PathBuf {
    desktop_root().join(WORKSPACES_FILE)
}

impl Workspace {
    fn from_entry(e: &OrgEntry) -> Option<Self> {
        let package_names: Vec<String> = e
            .get("PACKAGE_NAMES")
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default();
        let subtree = match (e.get("SUBTREE_REMOTE"), e.get("SUBTREE_BRANCH")) {
            (Some(r), Some(b)) => Some(SubtreeConfig {
                remote_url: r.to_string(),
                branch: b.to_string(),
            }),
            _ => None,
        };
        let removed_packages: Vec<String> = e
            .get("REMOVED_PACKAGES")
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_default();
        Some(Workspace {
            id: e.get("ID")?.to_string(),
            name: e.title.clone(),
            icon: e.get("ICON").unwrap_or("").to_string(),
            package_names,
            removed_packages,
            created_at: e.get_i64("CREATED_AT").unwrap_or(0),
            subtree,
        })
    }

    fn to_entry(&self) -> OrgEntry {
        let mut e = OrgEntry::new(self.name.clone())
            .with("ID", self.id.clone())
            .with("CREATED_AT", self.created_at.to_string());
        if !self.icon.is_empty() {
            e = e.with("ICON", self.icon.clone());
        }
        if !self.package_names.is_empty() {
            e = e.with(
                "PACKAGE_NAMES",
                serde_json::to_string(&self.package_names).unwrap_or_default(),
            );
        }
        if !self.removed_packages.is_empty() {
            e = e.with(
                "REMOVED_PACKAGES",
                serde_json::to_string(&self.removed_packages).unwrap_or_default(),
            );
        }
        if let Some(s) = &self.subtree {
            e = e
                .with("SUBTREE_REMOTE", s.remote_url.clone())
                .with("SUBTREE_BRANCH", s.branch.clone());
        }
        e
    }
}

async fn read_file() -> Result<WorkspacesFile, String> {
    let path = workspaces_path();
    let raw = match tokio::fs::read_to_string(&path).await {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(WorkspacesFile::default())
        }
        Err(e) => return Err(format!("read {WORKSPACES_FILE}: {e}")),
    };
    let active_id = parse_active(&raw);
    let entries = org_kv::read_entries(&path, SCHEMA).await?;
    let workspaces: Vec<Workspace> = entries
        .iter()
        .filter_map(Workspace::from_entry)
        .collect();
    Ok(WorkspacesFile {
        active_id,
        workspaces,
    })
}

async fn write_file(file: &WorkspacesFile) -> Result<(), String> {
    // Build the org body via the helper, then prepend the `#+ACTIVE:`
    // keyword line by way of a tiny manual splice — keeping the
    // helper's contract pure (it owns headings + properties; we own
    // file-level metadata).
    let entries: Vec<OrgEntry> = file.workspaces.iter().map(Workspace::to_entry).collect();
    let body = render_workspaces_file(&file.active_id, &entries);
    if let Some(parent) = workspaces_path().parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
    }
    let tmp = workspaces_path().with_extension("org.tmp");
    tokio::fs::write(&tmp, body)
        .await
        .map_err(|e| format!("write tmp {}: {e}", tmp.display()))?;
    tokio::fs::rename(&tmp, workspaces_path())
        .await
        .map_err(|e| format!("rename: {e}"))?;
    Ok(())
}

fn parse_active(src: &str) -> Option<String> {
    for line in src.lines().take(20) {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix(ACTIVE_KEYWORD) {
            let v = rest.trim();
            return if v.is_empty() {
                None
            } else {
                Some(v.to_string())
            };
        }
        if t.starts_with("* ") {
            break;
        }
    }
    None
}

fn render_workspaces_file(active_id: &Option<String>, entries: &[OrgEntry]) -> String {
    let mut out = String::new();
    out.push_str("#+SCHEMA: ");
    out.push_str(SCHEMA);
    out.push('\n');
    out.push_str(ACTIVE_KEYWORD);
    out.push(' ');
    if let Some(a) = active_id {
        out.push_str(a);
    }
    out.push_str("\n\n");
    for e in entries {
        out.push_str("* ");
        out.push_str(&e.title);
        out.push('\n');
        if !e.properties.is_empty() {
            out.push_str(":PROPERTIES:\n");
            for (k, v) in &e.properties {
                out.push(':');
                out.push_str(&k.to_lowercase());
                out.push_str(": ");
                out.push_str(v);
                out.push('\n');
            }
            out.push_str(":END:\n");
        }
        out.push('\n');
    }
    out
}

fn new_id() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("w_{:x}", nanos)
}

fn now_ms() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn validate_name(name: &str) -> Result<(), String> {
    let n = name.trim();
    if n.is_empty() {
        return Err("name is required".to_string());
    }
    if n.len() > 80 {
        return Err("name too long (max 80 chars)".to_string());
    }
    Ok(())
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn workspaces_list() -> Result<Vec<Workspace>, String> {
    let mut f = read_file().await?;
    f.workspaces.sort_by_key(|w| w.created_at);
    for ws in f.workspaces.iter_mut() {
        merge_disk_packages(ws).await;
    }
    Ok(f.workspaces)
}

#[tauri::command]
pub async fn workspaces_get_active() -> Result<Option<Workspace>, String> {
    let f = read_file().await?;
    let mut maybe = match f.active_id {
        Some(id) => f.workspaces.into_iter().find(|w| w.id == id),
        None => None,
    };
    if let Some(ref mut ws) = maybe {
        merge_disk_packages(ws).await;
    }
    Ok(maybe)
}

/// Augment a workspace's `package_names` with whatever folders exist
/// on disk under `~/Workbooks/monorepo/workspaces/<workspace>/`. The
/// .org file's package_names was the legacy source of truth; on-disk
/// reality now wins, with the .org list treated as ordering hint /
/// metadata enrichment. Without this merge the rail filters out any
/// package the voice agent's `mkdir` produced because workspaces.org
/// hasn't been touched.
async fn merge_disk_packages(ws: &mut Workspace) {
    use std::collections::BTreeSet;
    let workspace_dir = crate::config_paths::desktop_root()
        .join("workspaces")
        .join(&ws.name);
    if !workspace_dir.is_dir() {
        return;
    }
    let mut rd = match fs::read_dir(&workspace_dir).await {
        Ok(r) => r,
        Err(_) => return,
    };
    let mut seen: BTreeSet<String> = ws.package_names.iter().cloned().collect();
    let removed: BTreeSet<String> = ws.removed_packages.iter().cloned().collect();
    let original: Vec<String> = ws.package_names.clone();
    let mut additions: Vec<String> = Vec::new();
    while let Ok(Some(entry)) = rd.next_entry().await {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let Some(name) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        if removed.contains(name) {
            // User detached this name via "Remove from workspace".
            // Don't auto-re-add even though the folder still exists.
            continue;
        }
        if seen.insert(name.to_string()) {
            additions.push(name.to_string());
        }
    }
    additions.sort();
    // Preserve the .org file's declared order, then append disk-only
    // discoveries at the end so the rail's existing layout is stable.
    ws.package_names = original.into_iter().chain(additions.into_iter()).collect();
}

#[derive(Deserialize)]
pub struct WorkspaceCreate {
    pub name: String,
    #[serde(default)]
    pub icon: String,
}

#[tauri::command]
pub async fn workspaces_create(req: WorkspaceCreate) -> Result<Workspace, String> {
    validate_name(&req.name)?;
    let ws = Workspace {
        id: new_id(),
        name: req.name.trim().to_string(),
        icon: req.icon,
        package_names: vec![],
        removed_packages: vec![],
        created_at: now_ms(),
        subtree: None,
    };
    let mut f = read_file().await?;
    f.workspaces.push(ws.clone());
    // First workspace auto-activates so the user isn't stranded.
    if f.active_id.is_none() {
        f.active_id = Some(ws.id.clone());
    }
    write_file(&f).await?;
    Ok(ws)
}

#[tauri::command]
pub async fn workspaces_set_active(id: Option<String>) -> Result<(), String> {
    let mut f = read_file().await?;
    if let Some(ref id) = id {
        if !f.workspaces.iter().any(|w| &w.id == id) {
            return Err(format!("no workspace with id {id}"));
        }
    }
    f.active_id = id;
    write_file(&f).await?;
    Ok(())
}

#[derive(Deserialize)]
pub struct WorkspaceRename {
    pub id: String,
    pub name: String,
}

#[tauri::command]
pub async fn workspaces_rename(req: WorkspaceRename) -> Result<(), String> {
    validate_name(&req.name)?;
    let mut f = read_file().await?;
    let ws = f
        .workspaces
        .iter_mut()
        .find(|w| w.id == req.id)
        .ok_or_else(|| format!("no workspace with id {}", req.id))?;
    ws.name = req.name.trim().to_string();
    write_file(&f).await?;
    Ok(())
}

#[derive(Deserialize)]
pub struct WorkspaceSetIcon {
    pub id: String,
    pub icon: String,
}

#[tauri::command]
pub async fn workspaces_set_icon(req: WorkspaceSetIcon) -> Result<(), String> {
    let mut f = read_file().await?;
    let ws = f
        .workspaces
        .iter_mut()
        .find(|w| w.id == req.id)
        .ok_or_else(|| format!("no workspace with id {}", req.id))?;
    ws.icon = req.icon;
    write_file(&f).await?;
    Ok(())
}

#[tauri::command]
pub async fn workspaces_delete(id: String) -> Result<(), String> {
    let mut f = read_file().await?;
    f.workspaces.retain(|w| w.id != id);
    if f.active_id.as_deref() == Some(id.as_str()) {
        // Fall back to the most-recently-created remaining workspace, if any.
        f.active_id = f.workspaces.last().map(|w| w.id.clone());
    }
    write_file(&f).await?;
    Ok(())
}

#[derive(Deserialize)]
pub struct WorkspaceAddPackage {
    pub workspace_id: String,
    pub package_name: String,
}

/// Tag a package as belonging to a workspace. Idempotent — duplicate
/// adds are no-ops.
#[tauri::command]
pub async fn workspaces_add_package(req: WorkspaceAddPackage) -> Result<(), String> {
    let mut f = read_file().await?;
    let ws = f
        .workspaces
        .iter_mut()
        .find(|w| w.id == req.workspace_id)
        .ok_or_else(|| format!("no workspace with id {}", req.workspace_id))?;
    if !ws.package_names.contains(&req.package_name) {
        ws.package_names.push(req.package_name);
    }
    write_file(&f).await?;
    Ok(())
}

#[derive(Deserialize)]
pub struct WorkspaceRemovePackage {
    pub workspace_id: String,
    pub package_name: String,
}

#[derive(Deserialize)]
pub struct WorkspaceSetSubtree {
    pub id: String,
    /// None clears the subtree config (workspace falls back to "lives
    /// in the monorepo directly").
    #[serde(default)]
    pub subtree: Option<SubtreeConfig>,
}

#[tauri::command]
pub async fn workspaces_set_subtree(req: WorkspaceSetSubtree) -> Result<(), String> {
    let mut f = read_file().await?;
    let ws = f
        .workspaces
        .iter_mut()
        .find(|w| w.id == req.id)
        .ok_or_else(|| format!("no workspace with id {}", req.id))?;
    ws.subtree = req.subtree;
    write_file(&f).await?;
    Ok(())
}

#[tauri::command]
pub async fn workspaces_remove_package(req: WorkspaceRemovePackage) -> Result<(), String> {
    let mut f = read_file().await?;
    let ws = f
        .workspaces
        .iter_mut()
        .find(|w| w.id == req.workspace_id)
        .ok_or_else(|| format!("no workspace with id {}", req.workspace_id))?;
    ws.package_names.retain(|n| n != &req.package_name);
    // Mark the name as user-detached so merge_disk_packages doesn't
    // auto-re-add it on the next refresh just because the folder
    // still exists on disk.
    if !ws.removed_packages.iter().any(|n| n == &req.package_name) {
        ws.removed_packages.push(req.package_name.clone());
    }
    write_file(&f).await?;
    Ok(())
}

/// Path of the on-disk `workspaces.org` file. Exposed so the frontend
/// bridge can subscribe to the matching `oql:document:<path>` channel
/// and live-refresh when the file changes — whether the mutation came
/// from the desktop's own command, from the engine, or from an
/// external edit (Claude, another editor) the OS file watcher picks up.
#[tauri::command]
pub fn workspaces_file_path() -> String {
    workspaces_path().to_string_lossy().to_string()
}
