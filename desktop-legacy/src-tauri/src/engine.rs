// Tauri commands for managing the launchd-installed Engine
// daemon. Shells out to the workbooks-runtime binary's `install`,
// `uninstall`, and `status` subcommands (wb-g2yf — see
// docs/desktop/agent-lifecycle.md).
//
// wb-7z8r.3: retargeted from the legacy `workbooks-engine` binary at
// engine/ to `workbooks-runtime` at runtime/engine/.
//
// The desktop is the ONLY supported install path. We never
// document terminal-installing the daemon for end users; the
// "Install Workbooks engine" button in the splash is the
// canonical UX.

use std::path::PathBuf;
use std::process::Command;

use serde::Serialize;
use tauri::{AppHandle, command};

use crate::sidecar::{bundled_binary_path, dev_mix_dir};

#[derive(Clone, Debug, Serialize)]
pub struct EngineStatus {
    /// One of "running", "stopped", "stale", "unknown". Matches the
    /// workbooks-runtime CLI's `status` exit shape.
    pub state: String,
    /// Listen URL of the running daemon, when state == "running".
    pub url: Option<String>,
    /// PID of the running daemon, when state == "running" or "stale".
    pub pid: Option<u32>,
    /// True iff a launchd plist exists at the canonical user path.
    /// Distinct from "running" — install + daemon running are
    /// independent; user can install but never have it boot, or
    /// the plist could exist but launchd hasn't loaded it.
    pub installed: bool,
}

fn user_plist_path() -> Option<PathBuf> {
    let home = std::env::var_os("HOME")?;
    Some(
        PathBuf::from(home)
            .join("Library")
            .join("LaunchAgents")
            .join("sh.workbooks.engine.plist"),
    )
}

/// Locate the workbooks-runtime binary we should invoke for CLI subcommands.
/// Prefer the bundled Burrito binary that ships with this app; in
/// dev (where externalBin isn't staged) fall through to a shell that
/// runs `mix run` against the source tree.
///
/// Returns `(program, prefix_args)` — `Command::new(program).args(prefix_args)`
/// is the base; callers append their own subcommand args.
fn resolve_agent_invocation(app: &AppHandle) -> Result<(PathBuf, Vec<String>), String> {
    if let Some(bin) = bundled_binary_path(app) {
        if let Ok(meta) = std::fs::metadata(&bin) {
            if meta.len() >= 1_000_000 {
                return Ok((bin, vec![]));
            }
        }
    }

    // Dev fallback: `mix run --no-halt -e ":ok" -- <subcommand> <args>`.
    // We use `--eval ":ok"` so mix doesn't try to read script files
    // from the rest of argv; everything after `--` becomes
    // System.argv() inside the BEAM, which the runtime CLI dispatcher
    // sees.
    let mix_dir = dev_mix_dir().ok_or_else(|| {
        "could not locate runtime/engine/mix.exs for dev fallback".to_string()
    })?;
    let mix = PathBuf::from("mix");
    let prefix = vec![
        "run".to_string(),
        "--no-halt".to_string(),
        "-e".to_string(),
        ":ok".to_string(),
        "--".to_string(),
    ];

    // Caller needs to set CWD to mix_dir — encode that into the
    // first prefix arg as a marker. Cleaner alternative: return cwd
    // separately. Let's do the cleaner thing.
    let _ = mix_dir;
    Ok((mix, prefix))
}

/// Same as resolve_agent_invocation but also returns the CWD to use.
/// In bundled mode, the CWD is irrelevant; in dev mode, mix needs to
/// run in the workbooks_runtime mix dir.
fn resolve_agent_with_cwd(
    app: &AppHandle,
) -> Result<(PathBuf, Vec<String>, Option<PathBuf>), String> {
    let (program, prefix) = resolve_agent_invocation(app)?;
    let cwd = if program == PathBuf::from("mix") {
        dev_mix_dir()
    } else {
        None
    };
    Ok((program, prefix, cwd))
}

#[command]
pub async fn engine_status(app: AppHandle) -> Result<EngineStatus, String> {
    let installed = user_plist_path()
        .map(|p| p.exists())
        .unwrap_or(false);

    // Always probe the discovery file directly first — fast, no
    // subprocess. The CLI's `status` subcommand does the same plus
    // a kill -0 liveness check, so it remains the source of truth
    // when we need accuracy.
    let discovery = read_discovery_file();
    if let Some((url, pid)) = discovery {
        if pid_alive(pid) {
            return Ok(EngineStatus {
                state: "running".to_string(),
                url: Some(url),
                pid: Some(pid),
                installed,
            });
        } else {
            return Ok(EngineStatus {
                state: "stale".to_string(),
                url: Some(url),
                pid: Some(pid),
                installed,
            });
        }
    }

    let (program, prefix, cwd) = resolve_agent_with_cwd(&app)?;
    let mut cmd = Command::new(&program);
    cmd.args(&prefix);
    cmd.arg("status");
    if let Some(d) = cwd {
        cmd.current_dir(d);
    }
    let out = cmd
        .output()
        .map_err(|e| format!("engine status: spawn failed: {e}"))?;

    // CLI exits 0 = running, 1 = stopped, 3 = stale; we already
    // handled the running case via discovery file so this branch
    // covers stopped.
    let state = match out.status.code() {
        Some(0) => "running",
        Some(1) => "stopped",
        Some(3) => "stale",
        _ => "unknown",
    }
    .to_string();

    Ok(EngineStatus {
        state,
        url: None,
        pid: None,
        installed,
    })
}

#[command]
pub async fn engine_install(app: AppHandle) -> Result<(), String> {
    let (program, prefix, cwd) = resolve_agent_with_cwd(&app)?;
    let mut cmd = Command::new(&program);
    cmd.args(&prefix);
    cmd.arg("install").arg("--user");
    if let Some(d) = cwd {
        cmd.current_dir(d);
    }

    let out = cmd
        .output()
        .map_err(|e| format!("engine install: spawn failed: {e}"))?;

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        let stdout = String::from_utf8_lossy(&out.stdout);
        return Err(format!(
            "engine install failed ({}): {stderr}{stdout}",
            out.status.code().unwrap_or(-1),
        ));
    }
    Ok(())
}

#[command]
pub async fn engine_uninstall(app: AppHandle) -> Result<(), String> {
    let (program, prefix, cwd) = resolve_agent_with_cwd(&app)?;
    let mut cmd = Command::new(&program);
    cmd.args(&prefix);
    cmd.arg("uninstall");
    if let Some(d) = cwd {
        cmd.current_dir(d);
    }

    let out = cmd
        .output()
        .map_err(|e| format!("engine uninstall: spawn failed: {e}"))?;

    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        return Err(format!(
            "engine uninstall failed ({}): {stderr}",
            out.status.code().unwrap_or(-1),
        ));
    }
    Ok(())
}

// ── helpers ─────────────────────────────────────────────────────────

fn read_discovery_file() -> Option<(String, u32)> {
    let home = std::env::var_os("HOME")?;
    let path = PathBuf::from(home)
        .join("Workbooks")
        .join("Engine")
        .join("listen.json");
    let body = std::fs::read_to_string(&path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    let url = v.get("url")?.as_str()?.to_string();
    let pid = v.get("pid")?.as_u64()? as u32;
    Some((url, pid))
}

fn pid_alive(pid: u32) -> bool {
    // kill -0 is the canonical "does pid exist" probe on POSIX.
    Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}
