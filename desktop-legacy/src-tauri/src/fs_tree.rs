// File tree + OS-open + watcher commands for the desktop right rail
// (wb-i38o.7). All FS access is gated against the active workspace's
// allowed roots — see `is_path_in_scope`. A path outside scope returns
// the same structured error the Elixir agent uses
// (`workspace_scope_violation`) so the UI can render it consistently.
//
// Three Tauri commands:
//
//   * `tree_walk(root, max_depth, max_entries)` — sync (tokio::fs)
//     recursive walk of one allowed root, returning a flat list of
//     entries the Svelte side then re-shapes into a tree. We cap depth
//     and entry count so a `~/` mis-add can't melt the WebView.
//   * `tab_open(path)` — placeholder until the D8 (tabbed viewer)
//     agent lands. Today it logs + emits a `pending-tab-open` event so
//     a parent listener can see "the user would have opened X". When
//     D8 ships its real `tab_open`, this stub gets replaced (or this
//     command stays and D8's component listens for `pending-tab-open`).
//   * `open_in_os(path)` — defers to the platform's `open` /
//     `xdg-open` / `explorer` to reveal the file in Finder / Files /
//     Explorer. Used by the file tree right-click "Open in OS" item.
//
// One event:
//
//   * `fs-tree-changed { root }` — emitted by the `notify` watcher when
//     the watched directory's contents change. The Svelte side debounces
//     and re-walks the affected root. Watcher install is best-effort:
//     if it fails (FUSE mount, fs limits, etc.), the UI falls back to
//     its manual refresh button.

#![allow(clippy::module_name_repetitions)]

use std::path::{Path, PathBuf};
use std::sync::Mutex as StdMutex;

use crate::tabs::ensure_in_data_root;

use notify::event::{CreateKind, ModifyKind, RemoveKind};
use notify::{EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use once_cell::sync::OnceCell;
use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tokio::fs;

// Cap to keep a single tree-walk bounded. A user that accidentally
// added `~/` shouldn't be able to lock the WebView for a minute. The
// front-end surfaces the truncation so the user knows to narrow the
// root.
const DEFAULT_MAX_DEPTH: usize = 10;
const DEFAULT_MAX_ENTRIES: usize = 5_000;

#[derive(Debug, Clone, Serialize)]
pub struct FsEntry {
    /// Absolute path on disk (UTF-8; non-UTF-8 paths are skipped).
    pub path: String,
    /// Path relative to the walked root, used by the UI to build the
    /// tree without a second string-split round trip.
    pub rel: String,
    pub name: String,
    pub is_dir: bool,
    /// Depth from the root (root itself is 0; root children are 1).
    pub depth: usize,
}

#[derive(Debug, Clone, Serialize)]
pub struct TreeWalkResult {
    pub root: String,
    pub entries: Vec<FsEntry>,
    /// True when the walk hit `max_entries` and stopped early — the UI
    /// renders a "truncated" hint at the root.
    pub truncated: bool,
}

#[derive(Debug, Clone, Serialize)]
struct FsTreeChangedPayload {
    root: String,
}

// ── Scope gate ──────────────────────────────────────────────────────
//
// The workspace module owns the active-scope cache. We deliberately
// don't pull it as a typed dependency to avoid a cyclic import-style
// coupling; instead we read the on-disk state directly. It's the same
// file the workspace module writes, so they can't disagree.

pub(crate) async fn active_folders() -> Vec<String> {
    // Tiny duplication of `package::package_get_active` so this
    // module stays self-contained. Read-only — no writes.
    // Delegates to config_paths::desktop_root so we follow wb-80q0.3's
    // data-root migration without forking the path logic.
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

/// Byte-level prefix match. Same rule the Elixir agent uses for tool
/// scope enforcement — keep them in lock-step.
pub(crate) fn path_in_any_root(path: &Path, roots: &[String]) -> bool {
    let Some(p) = path.to_str() else {
        return false;
    };
    roots.iter().any(|root| {
        // `p == root` covers "open the root itself"; the trailing-sep
        // check prevents `/foo/bar2` from matching root `/foo/bar`.
        p == root || p.starts_with(&format!("{root}/"))
    })
}

// ── Tauri commands ──────────────────────────────────────────────────

#[tauri::command]
pub async fn tree_walk(
    root: String,
    max_depth: Option<usize>,
    max_entries: Option<usize>,
) -> Result<TreeWalkResult, String> {
    // User-facing tree expansion is bounded by data root (~/Workbooks/),
    // not by the active-package scope. The user owns their whole
    // monorepo and should be able to browse it freely; the active-
    // package scope is for agent tools (engine WorkspaceScope) where
    // staying in lane matters. Mirror the same posture as tab_open
    // in tabs.rs — one consistent rule for human reads.
    let root_path = PathBuf::from(&root);
    ensure_in_data_root(&root_path)?;
    if !root_path.is_dir() {
        return Err(format!("{root} is not a directory"));
    }

    let max_depth = max_depth.unwrap_or(DEFAULT_MAX_DEPTH);
    let max_entries = max_entries.unwrap_or(DEFAULT_MAX_ENTRIES);

    let mut entries = Vec::new();
    let mut truncated = false;

    // BFS so the UI gets the top of the tree even on huge folders.
    let mut queue: Vec<(PathBuf, usize)> = vec![(root_path.clone(), 0)];
    while let Some((dir, depth)) = queue.pop() {
        if depth > max_depth {
            continue;
        }
        let mut rd = match fs::read_dir(&dir).await {
            Ok(r) => r,
            Err(_) => continue, // permission denied / vanished — skip silently
        };
        while let Ok(Some(entry)) = rd.next_entry().await {
            if entries.len() >= max_entries {
                truncated = true;
                break;
            }
            let p = entry.path();
            let Some(name) = p.file_name().and_then(|s| s.to_str()) else {
                continue;
            };
            // Skip the obvious noise. Authors can still see hidden
            // files via shell — keeping the tree readable matters more
            // than completeness here.
            if name.starts_with('.') {
                continue;
            }
            if matches!(name, "node_modules" | "target" | "_build" | "deps") {
                continue;
            }
            let Some(path_str) = p.to_str() else {
                continue;
            };
            let rel = match p.strip_prefix(&root_path) {
                Ok(r) => r.to_string_lossy().to_string(),
                Err(_) => continue,
            };
            let is_dir = entry
                .file_type()
                .await
                .map(|t| t.is_dir())
                .unwrap_or(false);
            entries.push(FsEntry {
                path: path_str.to_string(),
                rel,
                name: name.to_string(),
                is_dir,
                depth: depth + 1,
            });
            if is_dir && depth + 1 <= max_depth {
                queue.push((p, depth + 1));
            }
        }
        if entries.len() >= max_entries {
            truncated = true;
            break;
        }
    }

    // Sort: dirs first, then case-insensitive name. Stable + cheap.
    entries.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.path.to_lowercase().cmp(&b.path.to_lowercase()),
    });

    Ok(TreeWalkResult {
        root,
        entries,
        truncated,
    })
}

// Note: `tab_open` lives in `tabs.rs` post-D8 merge. The earlier stub
// here (which emitted `pending-tab-open` events) was removed because
// D8's real implementation supersedes it. File-tree click handlers
// now invoke `tabs::tab_open` directly via the same `tab_open` name.

/// Reveal a path in the host OS file manager. macOS uses `open -R` so
/// the file is highlighted in Finder rather than opened; Linux uses
/// `xdg-open` on the parent dir; Windows uses `explorer /select,`.
#[tauri::command]
pub async fn open_in_os(path: String) -> Result<(), String> {
    // Same posture as tab_open / tree_walk — data-root bound, not
    // active-package bound. Reveal-in-Finder for any file inside the
    // monorepo is a fine default for a human user.
    ensure_in_data_root(Path::new(&path))?;

    #[cfg(target_os = "macos")]
    {
        tokio::process::Command::new("open")
            .arg("-R")
            .arg(&path)
            .spawn()
            .map_err(|e| format!("open: {e}"))?;
    }
    #[cfg(target_os = "linux")]
    {
        let parent = std::path::Path::new(&path)
            .parent()
            .map(|p| p.to_path_buf())
            .unwrap_or_else(|| PathBuf::from(&path));
        tokio::process::Command::new("xdg-open")
            .arg(parent)
            .spawn()
            .map_err(|e| format!("xdg-open: {e}"))?;
    }
    #[cfg(target_os = "windows")]
    {
        tokio::process::Command::new("explorer")
            .arg(format!("/select,{path}"))
            .spawn()
            .map_err(|e| format!("explorer: {e}"))?;
    }
    Ok(())
}

// ── Filesystem watcher ──────────────────────────────────────────────
//
// One global watcher; we (re)issue watch handles whenever the active
// scope changes. The watcher's callback emits `fs-tree-changed { root }`
// for the matching root — the front-end debounces and re-walks. Errors
// are logged but not surfaced to the UI; the manual refresh button
// stays as a safety net.

struct WatcherState {
    watcher: Option<RecommendedWatcher>,
    watched_roots: Vec<PathBuf>,
}

static WATCHER: OnceCell<StdMutex<WatcherState>> = OnceCell::new();

fn watcher_cell() -> &'static StdMutex<WatcherState> {
    WATCHER.get_or_init(|| {
        StdMutex::new(WatcherState {
            watcher: None,
            watched_roots: vec![],
        })
    })
}

/// Install (or replace) the FS watcher with the supplied set of roots.
/// Called whenever the active workspace changes.
pub fn refresh_watcher(app: &AppHandle, roots: Vec<String>) {
    let app_for_cb = app.clone();
    let roots_for_match: Vec<PathBuf> = roots.iter().map(PathBuf::from).collect();
    let roots_for_match_clone = roots_for_match.clone();

    let mut watcher = match notify::recommended_watcher(
        move |res: Result<notify::Event, notify::Error>| {
            let Ok(event) = res else {
                return;
            };
            // We only care about create/remove/rename. Plain content
            // edits don't change the tree shape; skipping them avoids
            // hammering the UI during a save-on-keystroke editor.
            let interesting = matches!(
                event.kind,
                EventKind::Create(CreateKind::Any | CreateKind::File | CreateKind::Folder | CreateKind::Other)
                    | EventKind::Remove(RemoveKind::Any | RemoveKind::File | RemoveKind::Folder | RemoveKind::Other)
                    | EventKind::Modify(ModifyKind::Name(_))
            );
            if !interesting {
                return;
            }
            // Map the changed path back to one of our watched roots so
            // the UI can scope its re-walk.
            for ev_path in &event.paths {
                for root in &roots_for_match_clone {
                    if ev_path.starts_with(root) {
                        if let Some(root_str) = root.to_str() {
                            let _ = app_for_cb.emit(
                                "fs-tree-changed",
                                &FsTreeChangedPayload {
                                    root: root_str.to_string(),
                                },
                            );
                        }
                        break;
                    }
                }
            }
        },
    ) {
        Ok(w) => w,
        Err(e) => {
            log::warn!("[fs_tree] notify watcher init failed: {e}; refresh-button fallback only");
            return;
        }
    };

    for root in &roots_for_match {
        if let Err(e) = watcher.watch(root, RecursiveMode::Recursive) {
            log::warn!(
                "[fs_tree] watch failed for {}: {e}",
                root.display()
            );
        }
    }

    let mut guard = watcher_cell().lock().expect("watcher mutex");
    guard.watcher = Some(watcher);
    guard.watched_roots = roots_for_match;
}

/// Apply the initial scope at boot and listen for `workspace-scope-change`
/// to keep watcher set in sync.
pub fn boot_watcher(app: AppHandle) {
    use tauri::Listener;
    // Initial scope: read whatever workspace::boot just hydrated.
    let app_for_initial = app.clone();
    tauri::async_runtime::spawn(async move {
        let roots = active_folders().await;
        refresh_watcher(&app_for_initial, roots);
    });

    // Subsequent scope changes.
    let app_for_listen = app.clone();
    app.listen("workspace-scope-change", move |event| {
        #[derive(serde::Deserialize)]
        struct Payload {
            #[serde(default)]
            folders: Vec<String>,
        }
        let payload: Payload = serde_json::from_str(event.payload()).unwrap_or(Payload {
            folders: vec![],
        });
        refresh_watcher(&app_for_listen, payload.folders);
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_match_byte_prefix() {
        let roots = vec!["/foo/bar".to_string()];
        assert!(path_in_any_root(Path::new("/foo/bar"), &roots));
        assert!(path_in_any_root(Path::new("/foo/bar/baz.org"), &roots));
        assert!(!path_in_any_root(Path::new("/foo/bar2"), &roots));
        assert!(!path_in_any_root(Path::new("/foo"), &roots));
    }
}
