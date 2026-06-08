// Filesystem explorer — the host capability behind the file-tree sidebar. Lists a
// directory's immediate children (lazy expand: the tree calls this per folder as
// it opens), so a workbook/package is an EXPLORABLE interface — you see what's in
// it. Plain `std::fs`; no scope plugin (the shell is the capability boundary).

use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirEntry {
    pub name: String,
    pub path: String,
    pub is_dir: bool,
}

/// List the immediate children of `path`, directories first then files, each
/// alphabetical (case-insensitive). Hidden dotfiles are skipped. Errors (missing
/// dir, no permission) surface as a string the UI can show.
#[tauri::command]
pub fn read_dir(path: String) -> Result<Vec<DirEntry>, String> {
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
