// Bundle / unbundle Tauri commands (wb-i38o.13, wb-i38o.16, wb-i38o.24).
//
// Two commands wired to the file-tree right-click context menu:
//
//   * `workbook_bundle(dir, output)` — shell out to the existing
//     packages/workbooks/spikes/oql-container/src/build.mjs script,
//     which walks a directory of `.org` files and emits a single
//     self-contained `.html` workbook. The script's runtime deps
//     (OQL WASM bundle, prismjs) live alongside it; we run `node`
//     against the script path as-is.
//
//   * `workbook_unbundle(html_path, output_dir)` — read the workbook's
//     embedded `SOURCE_GZ_B64` blob (base64 → gzip → JSON map of
//     `{path: source}`) and write each file out to a sibling
//     `<name>-unbundled/` directory.
//
// Both commands enforce workspace scope: paths outside the active
// workspace's allowed roots return `workspace_scope_violation`. Scope
// is read via the same on-disk state file the workspace + fs_tree
// modules share — see fs_tree.rs for the rationale.
//
// Path resolution for build.mjs (wb-i38o.24 resolution):
//
//   1. Prod (bundled): the script + the oql-wasm pkg/ directory ship
//      as Tauri resources (declared in `tauri.conf.json`, staged at
//      compile time by `build.rs`). Resolved via
//      `app.path().resolve("workbook-bundler/build.mjs",
//      BaseDirectory::Resource)`.
//   2. Dev: walk up from the Tauri binary's CWD (or CARGO_MANIFEST_DIR
//      at compile time) looking for the canonical monorepo path.
//
// Node module deps for build.mjs (`prismjs`): NOT bundled. On first
// invocation the command runs `npm install --omit=dev=false` inside
// the resolved bundler dir, then caches the result for subsequent
// runs. Rationale (vs vendoring node_modules into the installer):
// keeps the installer ~1MB smaller, avoids checking in a binary
// tarball, and `npm` is already a hard runtime requirement for users
// who edit workbooks. Documented in desktop/RELEASE.md.

#![allow(clippy::module_name_repetitions)]

use std::path::{Path, PathBuf};
use std::process::Stdio;

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use flate2::read::GzDecoder;
use regex::Regex;
use serde::Serialize;
use tauri::path::BaseDirectory;
use tauri::{AppHandle, Emitter, Manager};
use tokio::fs;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

#[derive(Debug, Clone, Serialize)]
pub struct BundleResult {
    pub output: String,
    pub stdout: String,
    pub stderr: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct UnbundleResult {
    pub output_dir: String,
    pub files: Vec<String>,
}

// ── Scope gate (mirrors fs_tree.rs) ─────────────────────────────────

async fn active_folders() -> Vec<String> {
    // Resolve via config_paths so this stays aligned with the canonical
    // data root (~/Workbooks/monorepo/) — no separate fork of the path
    // logic that drifts.
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

fn path_in_any_root(path: &Path, roots: &[String]) -> bool {
    let Some(p) = path.to_str() else {
        return false;
    };
    roots.iter().any(|root| {
        p == root || p.starts_with(&format!("{root}/"))
    })
}

// ── build.mjs path resolution ───────────────────────────────────────

/// Resolve `build.mjs` for production (Tauri resource) first, then
/// fall back to the dev walk-up. Returning the bundler *directory* —
/// callers run `node build.mjs <args>` from inside it so relative
/// imports (`../node_modules/prismjs`, `../../oql-wasm/`) resolve.
fn build_script_dir(app: &AppHandle) -> Option<PathBuf> {
    // Prod: tauri-bundled resource. The `tauri.conf.json` maps
    // `resources/workbook-bundler/build.mjs` → `workbook-bundler/build.mjs`
    // inside the app's $RESOURCE dir.
    if let Ok(resolved) = app
        .path()
        .resolve("workbook-bundler/build.mjs", BaseDirectory::Resource)
    {
        if resolved.exists() {
            return resolved.parent().map(Path::to_path_buf);
        }
    }

    // Dev: walk up from CARGO_MANIFEST_DIR / CWD looking for the
    // canonical monorepo path.
    let candidates: Vec<PathBuf> = {
        let mut out: Vec<PathBuf> = vec![];
        if let Some(manifest) = option_env!("CARGO_MANIFEST_DIR") {
            out.push(PathBuf::from(manifest));
        }
        if let Ok(cwd) = std::env::current_dir() {
            out.push(cwd);
        }
        out
    };

    for start in candidates {
        let mut cur: &Path = &start;
        for _ in 0..10 {
            let probe = cur.join("packages/workbooks/spikes/oql-container/src/build.mjs");
            if probe.exists() {
                return probe.parent().map(Path::to_path_buf);
            }
            match cur.parent() {
                Some(p) => cur = p,
                None => break,
            }
        }
    }
    None
}

/// Ensure `node_modules` exists inside the bundler dir. On first run
/// of a fresh installer we invoke `npm install` (against the bundled
/// `package.json`) so the script's runtime deps (`prismjs`) resolve.
/// Subsequent runs no-op. Failure surfaces as a clear error so the UI
/// can prompt the user to install Node if it's missing.
async fn ensure_bundler_deps(script_dir: &Path) -> Result<(), String> {
    let node_modules = script_dir.join("node_modules");
    if node_modules.exists() {
        return Ok(());
    }
    // We need a package.json next to (or one level up from) build.mjs.
    // Build.rs stages build.mjs directly into workbook-bundler/ along
    // with package.json, so the resolved layout in prod is:
    //   <Resource>/workbook-bundler/build.mjs
    //   <Resource>/workbook-bundler/package.json
    // For dev we walked up to ".../oql-container/src/" — package.json
    // lives one level up at ".../oql-container/package.json".
    let pkg_dir = if script_dir.join("package.json").exists() {
        script_dir.to_path_buf()
    } else if script_dir
        .parent()
        .map(|p| p.join("package.json").exists())
        .unwrap_or(false)
    {
        script_dir.parent().expect("checked above").to_path_buf()
    } else {
        return Err(format!(
            "no package.json adjacent to build.mjs at {}",
            script_dir.display()
        ));
    };

    log::info!(
        "[workbook_bundle] running `npm install` in {} (first-run setup)",
        pkg_dir.display()
    );
    let out = Command::new("npm")
        .arg("install")
        .arg("--no-audit")
        .arg("--no-fund")
        .arg("--omit=dev=false")
        .current_dir(&pkg_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| {
            format!(
                "first-run `npm install` failed to spawn in {}: {e} \
                 (is Node + npm installed and on PATH?)",
                pkg_dir.display()
            )
        })?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(format!(
            "first-run `npm install` in {} exited {}:\n{stderr}",
            pkg_dir.display(),
            out.status.code().unwrap_or(-1)
        ));
    }
    Ok(())
}

// ── Commands ────────────────────────────────────────────────────────

/// Bundle a directory of `.org` files into a single `.html` workbook
/// by shelling out to the build.mjs spike. `dir` must be inside the
/// active workspace scope; `output` must be inside scope too (we write
/// there). On success returns the output path + captured stdout/stderr
/// so the UI can surface progress.
#[tauri::command]
pub async fn workbook_bundle(
    app: AppHandle,
    dir: String,
    output: String,
) -> Result<BundleResult, String> {
    let roots = active_folders().await;
    let dir_path = PathBuf::from(&dir);
    let out_path = PathBuf::from(&output);

    if !path_in_any_root(&dir_path, &roots) {
        return Err(format!("workspace_scope_violation: {dir}"));
    }
    // The output's parent must be in scope — the file itself may not
    // exist yet, so we check the parent.
    let out_parent = out_path
        .parent()
        .ok_or_else(|| format!("output has no parent: {output}"))?;
    if !path_in_any_root(out_parent, &roots) && !path_in_any_root(&out_path, &roots) {
        return Err(format!("workspace_scope_violation: {output}"));
    }
    if !dir_path.is_dir() {
        return Err(format!("{dir} is not a directory"));
    }

    let script_dir = build_script_dir(&app).ok_or_else(|| {
        "could not locate workbook-bundler resources (bundled) \
         or packages/workbooks/spikes/oql-container/src/build.mjs (dev)"
            .to_string()
    })?;
    let script = script_dir.join("build.mjs");

    ensure_bundler_deps(&script_dir).await?;

    let _ = app.emit(
        "workbook-bundle-start",
        &serde_json::json!({ "dir": dir, "output": output }),
    );

    let out = Command::new("node")
        .arg(&script)
        .arg(&dir)
        .arg(&output)
        .current_dir(&script_dir)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| format!("node spawn failed: {e}"))?;

    let stdout = String::from_utf8_lossy(&out.stdout).to_string();
    let stderr = String::from_utf8_lossy(&out.stderr).to_string();

    if !out.status.success() {
        let code = out.status.code().unwrap_or(-1);
        return Err(format!(
            "build.mjs exited {code}\n--- stderr ---\n{stderr}"
        ));
    }

    Ok(BundleResult {
        output,
        stdout,
        stderr,
    })
}

/// Unbundle a `.html` workbook back into its constituent `.org` files
/// by extracting + ungzipping the `SOURCE_GZ_B64` blob.
#[tauri::command]
pub async fn workbook_unbundle(
    html_path: String,
    output_dir: String,
) -> Result<UnbundleResult, String> {
    let roots = active_folders().await;
    let html = PathBuf::from(&html_path);
    let out_dir = PathBuf::from(&output_dir);

    if !path_in_any_root(&html, &roots) {
        return Err(format!("workspace_scope_violation: {html_path}"));
    }
    // The output dir might not exist yet — check parent.
    let out_parent = out_dir
        .parent()
        .ok_or_else(|| format!("output_dir has no parent: {output_dir}"))?;
    if !path_in_any_root(&out_dir, &roots) && !path_in_any_root(out_parent, &roots) {
        return Err(format!("workspace_scope_violation: {output_dir}"));
    }

    // Stream-read the HTML; we only need the SOURCE_GZ_B64 line. Workbook
    // files can be megabytes — slurp it all anyway since we're going to
    // process it in-process.
    let mut f = fs::File::open(&html)
        .await
        .map_err(|e| format!("open {html_path}: {e}"))?;
    let mut buf = String::new();
    f.read_to_string(&mut buf)
        .await
        .map_err(|e| format!("read {html_path}: {e}"))?;

    // The build.mjs template emits a line like:
    //   const SOURCE_GZ_B64 = "....base64....";
    // We match the JSON-encoded string (build.mjs uses
    // `JSON.stringify(gzipped)` so the contents are safely quoted —
    // no embedded raw `"`).
    let re = Regex::new(r#"SOURCE_GZ_B64\s*=\s*"([A-Za-z0-9+/=]+)""#)
        .map_err(|e| format!("regex: {e}"))?;
    let cap = re
        .captures(&buf)
        .ok_or_else(|| "no SOURCE_GZ_B64 found — not a workbook?".to_string())?;
    let b64 = cap.get(1).expect("regex group 1").as_str();

    let gz = B64
        .decode(b64.as_bytes())
        .map_err(|e| format!("base64 decode: {e}"))?;

    let mut dec = GzDecoder::new(&gz[..]);
    let mut json = String::new();
    std::io::Read::read_to_string(&mut dec, &mut json)
        .map_err(|e| format!("gunzip: {e}"))?;

    let map: serde_json::Map<String, serde_json::Value> = serde_json::from_str(&json)
        .map_err(|e| format!("source bundle JSON: {e}"))?;

    fs::create_dir_all(&out_dir)
        .await
        .map_err(|e| format!("mkdir {output_dir}: {e}"))?;

    let mut written = Vec::with_capacity(map.len());
    for (rel, value) in &map {
        let src = value
            .as_str()
            .ok_or_else(|| format!("non-string source for {rel}"))?;
        // Reject any path that would escape the output dir.
        let rel_path = PathBuf::from(rel);
        if rel_path.is_absolute() || rel_path.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
            return Err(format!("bundle path tried to escape: {rel}"));
        }
        let dest = out_dir.join(&rel_path);
        if let Some(parent) = dest.parent() {
            fs::create_dir_all(parent)
                .await
                .map_err(|e| format!("mkdir {}: {e}", parent.display()))?;
        }
        fs::write(&dest, src)
            .await
            .map_err(|e| format!("write {}: {e}", dest.display()))?;
        written.push(dest.to_string_lossy().to_string());
    }

    Ok(UnbundleResult {
        output_dir,
        files: written,
    })
}

// ── Portability check (wb-unzn.25 P3) ───────────────────────────────

/// Shape returned to the renderer. Mirrors the JSON the `wb check
/// --portability --json` verb emits. We re-serialize verbatim — when
/// the `wb` CLI hasn't shipped the verb yet (or the binary isn't on
/// PATH), return `None` so the UI can render a "classification
/// unavailable" state instead of failing the whole tab.
#[derive(Debug, Clone, Serialize)]
pub struct PortabilityReport {
    pub cells: Vec<serde_json::Value>,
    pub workbook_tier: String,
    pub declared_tier: Option<String>,
}

/// Run `wb check --portability <workdir> --json` and return the
/// parsed JSON. The wb-cli currently doesn't ship this verb (paired
/// rust-agent work under wb-unzn.25); until it does, this command
/// returns a `classification_unavailable` error string that the
/// renderer treats as a non-fatal "no data yet" signal.
#[tauri::command]
pub async fn workbook_check_portability(
    workdir: String,
) -> Result<PortabilityReport, String> {
    let roots = active_folders().await;
    let dir = PathBuf::from(&workdir);
    if !path_in_any_root(&dir, &roots) {
        return Err(format!("workspace_scope_violation: {workdir}"));
    }
    if !dir.is_dir() {
        return Err(format!("{workdir} is not a directory"));
    }

    // Use `wb` from PATH. The agent's bash tool already augments PATH
    // with $WORKBOOKS_WORKBOX/bin so the same binary the agent sees is
    // what we exec here; for dev the developer's shell PATH provides it.
    let out = match Command::new("wb")
        .arg("check")
        .arg("--portability")
        .arg(&workdir)
        .arg("--json")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await
    {
        Ok(o) => o,
        Err(e) => {
            return Err(format!("classification_unavailable: wb spawn failed ({e})"));
        }
    };

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).to_string();
        // Distinguish "verb not implemented" from real errors so the UI
        // can show the right empty state. clap usually exits 2 on
        // unknown subcommand/arg.
        if out.status.code() == Some(2)
            || stderr.contains("unrecognized")
            || stderr.contains("unexpected argument")
            || stderr.contains("found argument")
        {
            return Err("classification_unavailable: wb check --portability not yet implemented".to_string());
        }
        return Err(format!(
            "wb check exited {}\n--- stderr ---\n{stderr}",
            out.status.code().unwrap_or(-1)
        ));
    }

    let stdout = String::from_utf8_lossy(&out.stdout);
    let v: serde_json::Value = serde_json::from_str(&stdout)
        .map_err(|e| format!("wb check JSON parse failed: {e}"))?;

    let cells = v
        .get("cells")
        .and_then(|x| x.as_array())
        .cloned()
        .unwrap_or_default();
    // `wb check --portability --json` emits `inferred_tier`; older
    // pre-fold drafts called it `workbook_tier`. Read either so this
    // bridge is resilient across renames.
    let workbook_tier = v
        .get("inferred_tier")
        .or_else(|| v.get("workbook_tier"))
        .and_then(|x| x.as_str())
        .unwrap_or("browser")
        .to_string();
    let declared_tier = v
        .get("declared_tier")
        .and_then(|x| x.as_str())
        .map(str::to_string);

    Ok(PortabilityReport {
        cells,
        workbook_tier,
        declared_tier,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scope_check_matches_byte_prefix() {
        let roots = vec!["/foo/bar".to_string()];
        assert!(path_in_any_root(Path::new("/foo/bar"), &roots));
        assert!(path_in_any_root(Path::new("/foo/bar/x.org"), &roots));
        assert!(!path_in_any_root(Path::new("/foo/bar2"), &roots));
    }

    // `build_script_dir` requires an AppHandle for the prod resource
    // lookup, so we can't easily unit-test it in isolation. The dev
    // walk-up branch is covered by a manual `pnpm tauri dev` smoke
    // and by the same logic in sidecar.rs::dev_mix_dir which has
    // identical semantics.
}
