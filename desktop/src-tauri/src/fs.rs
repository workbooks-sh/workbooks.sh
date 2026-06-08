// Filesystem reads behind the file-tree sidebar + editor. The shell is the
// capability boundary (no scope plugin): plain std::fs + walkdir.
//
//   fs_tree_walk  — bounded recursive walk for the whole tree (one shot)
//   fs_dir_read   — immediate children only (lazy per-folder expand)
//   fs_read_file / fs_write_file — editor I/O
//
// Both listings skip dotfiles and the heavy build/vendor dirs, sort
// directories-first then case-insensitive alphabetical.

use serde::Serialize;

/// Dirs we never descend into (size + noise). Matched on the directory name.
const SKIP_DIRS: &[&str] = &[".git", "node_modules", "target"];

const WALK_CAP: usize = 5000;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeEntry {
    pub path: String,
    pub rel: String,
    pub name: String,
    pub is_dir: bool,
    pub depth: usize,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TreeWalkResult {
    pub root: String,
    pub entries: Vec<TreeEntry>,
    pub truncated: bool,
}

fn skip_name(name: &str) -> bool {
    name.starts_with('.') || SKIP_DIRS.contains(&name)
}

/// Bounded recursive walk. Hidden + vendor dirs are pruned; capped at
/// WALK_CAP entries (truncated=true past that). Directories sort before files,
/// each level case-insensitive alphabetical.
#[tauri::command]
pub fn fs_tree_walk(root: String) -> Result<TreeWalkResult, String> {
    let root_path = std::path::Path::new(&root);
    if !root_path.exists() {
        return Err(format!("{root}: no such path"));
    }
    let mut entries: Vec<TreeEntry> = Vec::new();
    let mut truncated = false;

    let walker = walkdir::WalkDir::new(&root)
        .min_depth(1)
        .sort_by(|a, b| {
            let ad = a.file_type().is_dir();
            let bd = b.file_type().is_dir();
            bd.cmp(&ad).then_with(|| {
                a.file_name()
                    .to_string_lossy()
                    .to_lowercase()
                    .cmp(&b.file_name().to_string_lossy().to_lowercase())
            })
        })
        .into_iter()
        .filter_entry(|e| {
            let name = e.file_name().to_string_lossy();
            !skip_name(&name)
        });

    for entry in walker.flatten() {
        if entries.len() >= WALK_CAP {
            truncated = true;
            break;
        }
        let name = entry.file_name().to_string_lossy().to_string();
        let path = entry.path().to_string_lossy().to_string();
        let rel = entry
            .path()
            .strip_prefix(root_path)
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|_| name.clone());
        entries.push(TreeEntry {
            path,
            rel,
            name,
            is_dir: entry.file_type().is_dir(),
            depth: entry.depth(),
        });
    }

    Ok(TreeWalkResult {
        root,
        entries,
        truncated,
    })
}

/// Immediate children of `path`, dirs-first then case-insensitive alpha.
/// Hidden dotfiles skipped. (Was `read_dir`.)
#[tauri::command]
pub fn fs_dir_read(path: String) -> Result<Vec<DirEntry>, String> {
    let mut out: Vec<DirEntry> = Vec::new();
    let rd = std::fs::read_dir(&path).map_err(|e| format!("{path}: {e}"))?;
    for entry in rd.flatten() {
        let name = entry.file_name().to_string_lossy().to_string();
        if name.starts_with('.') {
            continue;
        }
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        out.push(DirEntry {
            name,
            path: entry.path().to_string_lossy().to_string(),
            is_dir,
        });
    }
    out.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    });
    Ok(out)
}

/// Read a file to a String (UTF-8). (Was `read_file`.)
#[tauri::command]
pub fn fs_read_file(path: String) -> Result<String, String> {
    std::fs::read_to_string(&path).map_err(|e| format!("{path}: {e}"))
}

/// Write `content` to `path`, creating parent dirs. (Was `write_file`.)
#[tauri::command]
pub fn fs_write_file(path: String, content: String) -> Result<(), String> {
    if let Some(parent) = std::path::Path::new(&path).parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&path, content).map_err(|e| format!("{path}: {e}"))
}
