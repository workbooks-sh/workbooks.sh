// Tauri build hook + resource staging (wb-i38o.16).
//
// At compile time, copy these monorepo paths into `src-tauri/resources/`
// so that `tauri.conf.json`'s `bundle.resources` declaration can find
// them and Tauri's bundler can include them in the packaged app:
//
//   packages/workbooks/spikes/oql-container/src/build.mjs
//     → resources/workbook-bundler/build.mjs
//   packages/workbooks/spikes/oql-container/package.json
//     → resources/workbook-bundler/package.json
//   packages/oql/crates/oql-wasm/pkg/
//     → resources/oql-wasm/                  (nodejs target, for build.mjs)
//   packages/oql/crates/oql-wasm/pkg-web/
//     → resources/oql-wasm-web/              (web target, for in-app WASM)
//
// CI is responsible for building both wasm-pack targets (nodejs + web)
// before invoking `pnpm tauri build`. In dev (`tauri dev`) a missing
// `pkg/` or `pkg-web/` is logged-and-skipped — bundling is a prod
// concern and the in-app web target may be vendored elsewhere by D9.
//
// First-run npm install: build.mjs needs `prismjs` from node_modules.
// We do NOT vendor or pre-install it here — the desktop app's first
// invocation of `workbook_bundle` runs `npm install --omit=dev=false`
// inside the resolved resources/workbook-bundler/ directory (see
// `workbook_io::ensure_bundler_deps`). Rationale: prismjs is ~1MB
// uncompressed and changes rarely; running npm once on first use keeps
// the installer slim and avoids committing a node_modules tarball.
// Documented in desktop/RELEASE.md.

use std::fs;
use std::path::{Path, PathBuf};

fn main() {
    if let Err(e) = stage_resources() {
        // Don't fail the build — just log. The bundler will still try
        // to include whatever exists under resources/. Production CI
        // explicitly verifies these paths after wasm-pack runs.
        println!("cargo:warning=resource staging skipped: {e}");
    }
    if let Err(e) = ensure_externalbin_stub() {
        println!("cargo:warning=externalBin stub staging skipped: {e}");
    }
    if let Err(e) = ensure_resource_stubs() {
        println!("cargo:warning=resource stub staging skipped: {e}");
    }
    bake_git_sha();
    tauri_build::build();
}

/// Bake the monorepo's current short git SHA into the sidecar binary
/// at compile time. `sidecar::log_about` compares this against the
/// daemon's self-reported `/api/about.git_sha` on connect and logs a
/// drift warning if they differ. When git isn't available (e.g.
/// release tarball build), set `WB_GIT_SHA=unknown` — the comparison
/// is then skipped at runtime.
fn bake_git_sha() {
    let sha = std::process::Command::new("git")
        .args(["rev-parse", "--short", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|| "unknown".to_string());
    println!("cargo:rustc-env=WB_GIT_SHA={sha}");
    // Rerun whenever HEAD moves.
    println!("cargo:rerun-if-changed=../../.git/HEAD");
    println!("cargo:rerun-if-changed=../../.git/refs/heads");
}

/// Ensure the externalBin path `binaries/workbooks-runtime-<triple>[.exe]`
/// exists so `tauri-build` doesn't fail validation in dev. `mix runtime.stage`
/// (in runtime/engine/) overwrites this stub with the real Burrito-packaged
/// binary before `tauri build`. The stub itself is harmless — the sidecar
/// rejects any binary smaller than 1MB and falls through to dev mode
/// (`mix run --no-halt` in runtime/engine/).
fn ensure_externalbin_stub() -> std::io::Result<()> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let binaries_dir = manifest_dir.join("binaries");
    fs::create_dir_all(&binaries_dir)?;

    let triple = std::env::var("TARGET").unwrap_or_else(|_| {
        std::env::var("HOST").unwrap_or_else(|_| "unknown-triple".into())
    });
    let is_windows = triple.contains("windows");
    let stub_name = if is_windows {
        format!("workbooks-runtime-{triple}.exe")
    } else {
        format!("workbooks-runtime-{triple}")
    };
    let stub_path = binaries_dir.join(&stub_name);
    if stub_path.exists() {
        return Ok(());
    }
    // Minimal stub: a shell/batch script that exits 1 with a clear
    // message. Tauri only checks the file exists; it doesn't validate
    // the format until launch.
    if is_windows {
        fs::write(
            &stub_path,
            b"@echo off\r\necho [workbooks-runtime stub] run `mix runtime.stage` in runtime/engine/\r\nexit /b 1\r\n",
        )?;
    } else {
        fs::write(
            &stub_path,
            b"#!/bin/sh\necho '[workbooks-runtime stub] run `mix runtime.stage` in runtime/engine/' >&2\nexit 1\n",
        )?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = fs::metadata(&stub_path)?.permissions();
            perms.set_mode(0o755);
            fs::set_permissions(&stub_path, perms)?;
        }
    }
    println!(
        "cargo:warning=staged workbooks-runtime stub at {} — `mix runtime.stage` replaces this with the Burrito binary",
        stub_path.display()
    );
    Ok(())
}

/// Ensure the resource paths declared in `tauri.conf.json` exist so
/// the bundler doesn't fail when wasm-pack hasn't run yet. We create
/// empty stub directories — the bundler will package them as empty
/// resources, which is acceptable for dev. CI runs wasm-pack before
/// `tauri build` so prod bundles ship the real artifacts.
fn ensure_resource_stubs() -> std::io::Result<()> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let resources = manifest_dir.join("resources");
    for sub in ["oql-wasm", "oql-wasm-web"] {
        let d = resources.join(sub);
        fs::create_dir_all(&d)?;
        let stub = d.join(".stub");
        if !stub.exists() {
            fs::write(&stub, b"placeholder - real wasm-pack output is staged here by CI\n")?;
        }
    }
    let bundler = resources.join("workbook-bundler");
    fs::create_dir_all(&bundler)?;
    let stub_mjs = bundler.join("build.mjs");
    if !stub_mjs.exists() {
        fs::write(
            &stub_mjs,
            b"// placeholder - real build.mjs is staged from packages/workbooks/spikes/oql-container/\n",
        )?;
    }
    let stub_pkg = bundler.join("package.json");
    if !stub_pkg.exists() {
        fs::write(&stub_pkg, b"{}\n")?;
    }
    Ok(())
}

fn stage_resources() -> std::io::Result<()> {
    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let monorepo_root = manifest_dir
        .ancestors()
        .nth(3)
        .ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::NotFound,
                "could not locate monorepo root from CARGO_MANIFEST_DIR",
            )
        })?
        .to_path_buf();

    let bundler_src = monorepo_root.join("packages/workbooks/spikes/oql-container");
    let wasm_node_src = monorepo_root.join("packages/oql/crates/oql-wasm/pkg");
    let wasm_web_src = monorepo_root.join("packages/oql/crates/oql-wasm/pkg-web");

    let resources_dir = manifest_dir.join("resources");
    let bundler_dst = resources_dir.join("workbook-bundler");
    let wasm_node_dst = resources_dir.join("oql-wasm");
    let wasm_web_dst = resources_dir.join("oql-wasm-web");

    fs::create_dir_all(&bundler_dst)?;

    // build.mjs + package.json — required for the bundler.
    copy_if_exists(
        &bundler_src.join("src/build.mjs"),
        &bundler_dst.join("build.mjs"),
    )?;
    copy_if_exists(
        &bundler_src.join("package.json"),
        &bundler_dst.join("package.json"),
    )?;

    // wasm pkg directories — best-effort. CI runs wasm-pack before
    // `tauri build`; dev builds may not have them and that's fine.
    copy_dir_if_exists(&wasm_node_src, &wasm_node_dst)?;
    copy_dir_if_exists(&wasm_web_src, &wasm_web_dst)?;

    // Rerun the build if any of these source paths change.
    println!(
        "cargo:rerun-if-changed={}",
        bundler_src.join("src/build.mjs").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        bundler_src.join("package.json").display()
    );
    println!("cargo:rerun-if-changed={}", wasm_node_src.display());
    println!("cargo:rerun-if-changed={}", wasm_web_src.display());

    Ok(())
}

fn copy_if_exists(src: &Path, dst: &Path) -> std::io::Result<()> {
    if !src.exists() {
        println!(
            "cargo:warning=resource source missing (skipped): {}",
            src.display()
        );
        return Ok(());
    }
    if let Some(parent) = dst.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(src, dst)?;
    Ok(())
}

fn copy_dir_if_exists(src: &Path, dst: &Path) -> std::io::Result<()> {
    if !src.exists() {
        println!(
            "cargo:warning=resource dir missing (skipped): {}",
            src.display()
        );
        return Ok(());
    }
    // Clean the dst so removals propagate.
    if dst.exists() {
        fs::remove_dir_all(dst)?;
    }
    fs::create_dir_all(dst)?;
    copy_dir_recursive(src, dst)
}

fn copy_dir_recursive(src: &Path, dst: &Path) -> std::io::Result<()> {
    for entry in fs::read_dir(src)? {
        let entry = entry?;
        let ty = entry.file_type()?;
        let src_path = entry.path();
        let dst_path = dst.join(entry.file_name());
        if ty.is_dir() {
            fs::create_dir_all(&dst_path)?;
            copy_dir_recursive(&src_path, &dst_path)?;
        } else if ty.is_file() {
            fs::copy(&src_path, &dst_path)?;
        }
        // Skip symlinks for portability.
    }
    Ok(())
}
