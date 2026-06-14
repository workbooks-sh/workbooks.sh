// Bundle file IO — the desktop's ONLY role in the bundle lifecycle: read a dir
// tree into a parts map, and write a parts map back to a dir. It owns NO
// bundler: the zip/embed/sign work is `Workbooks.Bundle` on the engine, reached
// over `/rcp/bundle` + `/rcp/unbundle` (the BYTES-over-RCP seam that
// checkout/checkin use, because the engine runs in a container and can't see
// host paths). The frontend (`workbook_io.svelte.ts`) orchestrates:
//   bundle:   bundle_read_tree(dir) → POST /rcp/bundle → write the returned html
//   unbundle: POST /rcp/unbundle(html) → bundle_write_tree(parts, dir)
//
// These mirror `Workbooks.Bundle.read_tree/1` and `write_tree/2` exactly: the
// same private-path strip set, and the same `..`/absolute path confinement so a
// hostile bundle can't escape its target dir.

use base64::Engine as _;
use std::collections::BTreeMap;
use std::path::Path;

const B64: base64::engine::general_purpose::GeneralPurpose = base64::engine::general_purpose::STANDARD;

// VCS internals + per-session private state never belong in a portable tree —
// the SAME strip set as `Workbooks.Bundle.read_tree` (host/bundle.ex).
const STRIP: &[&str] = &[
    ".git", ".github", ".githooks", ".hg", ".svn", ".beads",
    "node_modules", "_build", ".tmp", ".private",
];

fn stripped(rel: &Path) -> bool {
    rel.components()
        .any(|c| STRIP.contains(&c.as_os_str().to_string_lossy().as_ref()))
}

/// Refuse a member on WRITE (ingress): a denylisted control dir at any segment,
/// OR any TOP-LEVEL dotfile/dir — one rule covering the whole ingress code-exec /
/// secret class (.env, .envrc, .npmrc, .ssh, .vscode, .gitlab-ci.yml, .github, .git…)
/// without a whack-a-mole list. Mirrors `Workbooks.Bundle.denied_member?` so the
/// desktop write path is as guarded as the host's (a hostile unbundle can't plant a
/// `.git/hooks/pre-commit` or `.github/workflows/*.yml` that runs on the next git/CI op).
fn denied_write(rel: &Path) -> bool {
    stripped(rel)
        || matches!(rel.components().next(),
            Some(c) if c.as_os_str().to_string_lossy().starts_with('.'))
}

/// Walk `dir` into a parts map `{ "rel/path" => base64(bytes) }`, forward-slash
/// relative keys, private/VCS noise dropped. Raw bytes (base64) so binary parts
/// survive the JSON hop intact — the engine base64-decodes and packs. Shared by
/// the `bundle_read_tree` command and `workspace_package` (multi-folder gather).
pub fn read_tree_map(dir: &str) -> Result<BTreeMap<String, String>, String> {
    let root = std::fs::canonicalize(dir).map_err(|e| format!("{dir}: {e}"))?;
    let mut out = BTreeMap::new();
    for entry in walkdir::WalkDir::new(&root).into_iter().flatten() {
        if !entry.file_type().is_file() {
            continue;
        }
        let rel = match entry.path().strip_prefix(&root) {
            Ok(r) => r,
            Err(_) => continue,
        };
        if stripped(rel) {
            continue;
        }
        let bytes = std::fs::read(entry.path()).map_err(|e| e.to_string())?;
        let key = rel.to_string_lossy().replace('\\', "/");
        out.insert(key, B64.encode(bytes));
    }
    Ok(out)
}

/// Walk `dir` → parts map. Pure file IO; the engine does the bundling.
#[tauri::command]
pub fn bundle_read_tree(dir: String) -> Result<BTreeMap<String, String>, String> {
    read_tree_map(&dir)
}

/// Write `{ "rel/path" => base64(bytes) }` under `dir`, path-confined (absolute
/// or `..`-escaping members rejected — mirrors `Workbooks.Bundle.write_tree`).
/// Returns the count written.
#[tauri::command]
pub fn bundle_write_tree(files: BTreeMap<String, String>, dir: String) -> Result<usize, String> {
    let root = Path::new(&dir);
    std::fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let root = std::fs::canonicalize(root).map_err(|e| e.to_string())?;

    let mut n = 0usize;
    for (name, b64) in &files {
        let rel = Path::new(name);
        if name.is_empty() || rel.is_absolute() || rel.components().any(|c| c.as_os_str() == "..") {
            return Err(format!("unsafe bundle path: {name}"));
        }
        // Confinement (..\/absolute) is not enough: a confined-but-hostile member like
        // `.git/hooks/pre-commit` or `.github/workflows/x.yml` is code-exec on the next
        // git/CI op. Refuse the control-dir + top-level-dotfile class, mirroring the host.
        if denied_write(rel) {
            return Err(format!("refused control-dir bundle path: {name}"));
        }
        let dest = root.join(rel);
        // Confinement check on the cleaned join: the dest must stay under root.
        if !dest.starts_with(&root) {
            return Err(format!("unsafe bundle path: {name}"));
        }
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let bytes = B64.decode(b64.as_bytes()).map_err(|e| e.to_string())?;
        std::fs::write(&dest, bytes).map_err(|e| e.to_string())?;
        n += 1;
    }
    Ok(n)
}
