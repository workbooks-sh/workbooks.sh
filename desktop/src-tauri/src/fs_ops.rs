// Filesystem mutations + live watchers. Every mutation emits `fs-tree-changed`
// so the tree refreshes without a manual reload; `fs_watch_start` installs a
// recursive notify watcher per root that emits the same event on any change.
// `config_watch_start` watches ~/.oql/desktop for config edits and emits
// `config-changed`.

use notify::{RecommendedWatcher, RecursiveMode, Watcher};
use serde::Serialize;
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, State};

/// Live watchers keyed by the root path they watch. Holding the `Watcher` keeps
/// it alive; dropping it (remove) stops the watch.
#[derive(Default)]
pub struct Watchers {
    inner: Mutex<HashMap<String, RecommendedWatcher>>,
    /// The single config watcher (only one, on ~/.oql/desktop).
    config: Mutex<Option<RecommendedWatcher>>,
}

#[derive(Serialize, Clone)]
struct TreeChanged {
    root: String,
}

/// Nearest existing ancestor directory of `p` — the natural refresh root for a
/// mutation. Walks up until a dir that exists (handles delete: the path itself
/// is gone, so we report its parent).
fn refresh_root(p: &str) -> String {
    let mut cur = Path::new(p);
    loop {
        if cur.is_dir() {
            return cur.to_string_lossy().to_string();
        }
        match cur.parent() {
            Some(parent) => cur = parent,
            None => return p.to_string(),
        }
    }
}

fn emit_changed(app: &AppHandle, root: String) {
    let _ = app.emit("fs-tree-changed", TreeChanged { root });
}

#[tauri::command]
pub fn fs_reveal(path: String) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let status = std::process::Command::new("open")
        .args(["-R", &path])
        .status();
    #[cfg(target_os = "linux")]
    let status = {
        let dir = Path::new(&path)
            .parent()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| path.clone());
        std::process::Command::new("xdg-open").arg(dir).status()
    };
    #[cfg(target_os = "windows")]
    let status = std::process::Command::new("explorer")
        .arg(format!("/select,{path}"))
        .status();
    status.map_err(|e| e.to_string()).map(|_| ())
}

#[tauri::command]
pub fn fs_rename(app: AppHandle, from: String, to: String) -> Result<(), String> {
    if Path::new(&to).exists() {
        return Err(format!("destination exists: {to}"));
    }
    std::fs::rename(&from, &to).map_err(|e| e.to_string())?;
    // Common ancestor of from+to is the natural refresh root; parent of `to`
    // covers both for the typical same-dir / move case.
    emit_changed(&app, refresh_root(&to));
    Ok(())
}

#[tauri::command]
pub fn fs_delete(app: AppHandle, path: String) -> Result<(), String> {
    let parent = Path::new(&path)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| path.clone());
    let meta = std::fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
    if meta.is_dir() {
        std::fs::remove_dir_all(&path).map_err(|e| e.to_string())?;
    } else {
        std::fs::remove_file(&path).map_err(|e| e.to_string())?;
    }
    emit_changed(&app, parent);
    Ok(())
}

#[tauri::command]
pub fn fs_mkdir(app: AppHandle, path: String) -> Result<(), String> {
    std::fs::create_dir_all(&path).map_err(|e| e.to_string())?;
    emit_changed(&app, refresh_root(&path));
    Ok(())
}

#[tauri::command]
pub fn fs_create_file(app: AppHandle, path: String) -> Result<(), String> {
    if Path::new(&path).exists() {
        return Err(format!("file exists: {path}"));
    }
    if let Some(parent) = Path::new(&path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::File::create(&path).map_err(|e| e.to_string())?;
    emit_changed(&app, refresh_root(&path));
    Ok(())
}

fn make_watcher(
    app: AppHandle,
    on_event: impl Fn(&AppHandle) + Send + 'static,
) -> Result<RecommendedWatcher, String> {
    notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if res.is_ok() {
            on_event(&app);
        }
    })
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn fs_watch_start(
    app: AppHandle,
    watchers: State<Watchers>,
    root: String,
) -> Result<(), String> {
    let root_for_emit = root.clone();
    let mut watcher = make_watcher(app, move |app| {
        let _ = app.emit(
            "fs-tree-changed",
            TreeChanged {
                root: root_for_emit.clone(),
            },
        );
    })?;
    watcher
        .watch(Path::new(&root), RecursiveMode::Recursive)
        .map_err(|e| e.to_string())?;
    watchers.inner.lock().unwrap().insert(root, watcher);
    Ok(())
}

#[tauri::command]
pub fn fs_watch_stop(watchers: State<Watchers>, root: String) -> Result<(), String> {
    watchers.inner.lock().unwrap().remove(&root);
    Ok(())
}

#[derive(Serialize, Clone)]
struct ConfigChanged {
    file: String,
}

/// Watch ~/.oql/desktop for config edits; emit `config-changed` with the
/// changed file's basename. Replaces the WS-bridge `onMonorepoChange` for
/// local config so settings stores live-refresh offline.
#[tauri::command]
pub fn config_watch_start(app: AppHandle, watchers: State<Watchers>) -> Result<(), String> {
    let dir = crate::paths::oql_desktop_dir();
    let _ = std::fs::create_dir_all(&dir);
    let mut watcher = notify::recommended_watcher(move |res: notify::Result<notify::Event>| {
        if let Ok(ev) = res {
            for p in ev.paths {
                let base = p
                    .file_name()
                    .map(|n| n.to_string_lossy().to_string())
                    .unwrap_or_default();
                if !base.is_empty() {
                    let _ = app.emit("config-changed", ConfigChanged { file: base });
                }
            }
        }
    })
    .map_err(|e| e.to_string())?;
    watcher
        .watch(&dir, RecursiveMode::NonRecursive)
        .map_err(|e| e.to_string())?;
    *watchers.config.lock().unwrap() = Some(watcher);
    Ok(())
}
