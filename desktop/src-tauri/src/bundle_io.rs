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

// Backslash parity with the Elixir host (`denied_member?` does
// `String.replace("\\", "/")` before splitting): on Unix, `Path::components`
// treats `\` as a literal filename char, so a member named `.git\hooks\x` would
// slip past a segment check that only sees ONE component. Normalize `\`→`/` and
// split on `/` ourselves so a Windows-style separator can't smuggle a control-dir
// segment past the denylist. Returns the normalized segment vector.
fn segments(rel: &Path) -> Vec<String> {
    rel.to_string_lossy()
        .replace('\\', "/")
        .split('/')
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
        .collect()
}

fn stripped(rel: &Path) -> bool {
    segments(rel).iter().any(|s| STRIP.contains(&s.as_str()))
}

/// Refuse a member on WRITE (ingress): a denylisted control dir at any segment,
/// OR any TOP-LEVEL dotfile/dir — one rule covering the whole ingress code-exec /
/// secret class (.env, .envrc, .npmrc, .ssh, .vscode, .gitlab-ci.yml, .github, .git…)
/// without a whack-a-mole list. Mirrors `Workbooks.Bundle.denied_member?` so the
/// desktop write path is as guarded as the host's (a hostile unbundle can't plant a
/// `.git/hooks/pre-commit` or `.github/workflows/*.yml` that runs on the next git/CI op).
fn denied_write(rel: &Path) -> bool {
    let segs = segments(rel);
    stripped(rel) || segs.first().map(|s| s.starts_with('.')).unwrap_or(false)
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
        // `..`-confinement on the backslash-normalized segments too: on Unix a
        // member like `a\..\..\x` is ONE component to `Path`, so check our own
        // split (matches the host) before trusting `rel`.
        let segs = segments(rel);
        if name.is_empty()
            || rel.is_absolute()
            || name.starts_with('/')
            || segs.iter().any(|s| s == "..")
            || rel.components().any(|c| c.as_os_str() == "..")
        {
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

#[cfg(test)]
mod tests {
    use super::*;

    // Backslash parity with the Elixir host (`denied_member?` normalizes `\`→`/`
    // before splitting). On Unix, `Path::components` treats `\` literally, so these
    // would slip past a naive segment check — they must NOT.
    #[test]
    fn denies_backslash_control_dir() {
        assert!(denied_write(Path::new(r".git\hooks\pre-commit")));
        assert!(denied_write(Path::new(r".github\workflows\x.yml")));
        assert!(denied_write(Path::new(r"a\b\.git\config")));
        assert!(denied_write(Path::new(r"node_modules\x")));
    }

    #[test]
    fn denies_backslash_top_level_dotfile() {
        assert!(denied_write(Path::new(r".env")));
        // a backslash-joined top-level dotfile
        assert!(denied_write(Path::new(r".ssh\id_rsa")));
    }

    #[test]
    fn denies_forward_slash_control_dir_unchanged() {
        assert!(denied_write(Path::new(".git/hooks/pre-commit")));
        assert!(denied_write(Path::new(".github/workflows/x.yml")));
        assert!(denied_write(Path::new(".env")));
    }

    #[test]
    fn allows_ordinary_members() {
        assert!(!denied_write(Path::new("index.html")));
        assert!(!denied_write(Path::new("src/main.rs")));
        assert!(!denied_write(Path::new("data/db.sqlite")));
        // a non-top-level dotfile dir is allowed (only TOP-LEVEL dotfiles refused)
        assert!(!denied_write(Path::new("src/.keep")));
    }

    #[test]
    fn segments_normalizes_separators() {
        assert_eq!(segments(Path::new(r"a\b\c")), vec!["a", "b", "c"]);
        assert_eq!(segments(Path::new("a/b/c")), vec!["a", "b", "c"]);
        assert_eq!(segments(Path::new(r"a\b/c")), vec!["a", "b", "c"]);
    }

    // write-path confinement: a backslash-smuggled `..` must be rejected.
    #[test]
    fn write_rejects_backslash_dotdot_escape() {
        let tmp = std::env::temp_dir().join(format!("wb_bundle_test_{}", std::process::id()));
        let dir = tmp.to_string_lossy().to_string();
        let mut files = BTreeMap::new();
        files.insert(r"a\..\..\escape".to_string(), B64.encode(b"x"));
        let res = bundle_write_tree(files, dir);
        assert!(res.is_err(), "backslash .. escape must be refused: {res:?}");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn write_rejects_backslash_control_dir() {
        let tmp = std::env::temp_dir().join(format!("wb_bundle_test_cd_{}", std::process::id()));
        let dir = tmp.to_string_lossy().to_string();
        let mut files = BTreeMap::new();
        files.insert(r".git\hooks\pre-commit".to_string(), B64.encode(b"#!/bin/sh"));
        let res = bundle_write_tree(files, dir);
        assert!(res.is_err(), "backslash control dir must be refused: {res:?}");
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
