// The deploy-kit bridge. The shell never reimplements deploy logic — it runs the
// SAME `wb deploy` verbs we ship to users (dogfood) and reads the discovery file
// the runtime writes. The agent-grade `--json` + exit codes are exactly what a
// supervisor needs.

use serde::{Deserialize, Serialize};
use std::process::Command;
use tauri::{AppHandle, Emitter};

/// The runtime's discovery file (written by `Workbooks.Desktop` inside the
/// container, bind-mounted out to the host). Matches `Workbooks.Deploy.Krunvm`'s
/// disco dir: ~/Library/Application Support/sh.workbooks/disco/runtime.json.
#[derive(Deserialize)]
pub struct Discovery {
    pub port: u16,
    pub token: String,
    #[serde(default = "default_scheme")]
    pub scheme: String,
    #[serde(default)]
    #[allow(dead_code)]
    pub pid: u32,
    /// Who manages this runtime: "container" (we booted it via `wb deploy local`,
    /// so we own its lifecycle and may restart it) or "raw" (launched by hand in
    /// dev — the tray must never kill it). Absent on legacy runtimes → treated as
    /// "container" so the old restart behaviour is preserved.
    #[serde(default)]
    pub mode: String,
}

fn default_scheme() -> String {
    "http".into()
}

impl Discovery {
    pub fn read() -> Option<Discovery> {
        let path = discovery_path()?;
        let body = std::fs::read_to_string(path).ok()?;
        serde_json::from_str(&body).ok()
    }
}

fn discovery_path() -> Option<std::path::PathBuf> {
    // WB_DESKTOP_DIR overrides; else the macOS Application Support dir.
    if let Ok(dir) = std::env::var("WB_DESKTOP_DIR") {
        return Some(std::path::PathBuf::from(dir).join("runtime.json"));
    }
    let base = dirs::data_dir()?; // ~/Library/Application Support on macOS
    Some(base.join("sh.workbooks").join("disco").join("runtime.json"))
}

/// Run a `wb` subcommand, returning combined stdout/stderr. The `wb` binary is
/// resolved from `WB_BIN` (so the bundled binary can be pinned) or PATH.
pub fn wb(args: &[&str]) -> Result<String, String> {
    let bin = std::env::var("WB_BIN").unwrap_or_else(|_| "wb".into());
    match Command::new(&bin).args(args).output() {
        Ok(out) => {
            let mut s = String::from_utf8_lossy(&out.stdout).to_string();
            s.push_str(&String::from_utf8_lossy(&out.stderr));
            Ok(s.trim().to_string())
        }
        Err(e) => Err(format!("could not run `{} {}`: {e}", bin, args.join(" "))),
    }
}

/// The daemon's folded health view: discovery + a /health probe. The `chip`
/// works offline because every branch resolves to a concrete state without the
/// probe being able to hang (200ms timeout).
#[derive(Serialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DaemonStatus {
    /// "stopped" | "running" | "unhealthy"
    pub state: String,
    pub url: String,
    pub pid: u32,
    pub token: String,
    /// "container" | "raw" | "" (no discovery). Lets the UI label an externally
    /// managed (raw, dev) runtime the tray won't restart.
    pub manager: String,
}

/// Probe the daemon: no discovery → stopped; discovery + /health 200 → running;
/// otherwise unhealthy. Short blocking timeout so the status chip never stalls.
pub fn status() -> DaemonStatus {
    let Some(d) = Discovery::read() else {
        return DaemonStatus {
            state: "stopped".into(),
            url: String::new(),
            pid: 0,
            token: String::new(),
            manager: String::new(),
        };
    };
    let url = format!("{}://127.0.0.1:{}", d.scheme, d.port);
    let healthy = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_millis(200))
        .build()
        .ok()
        .and_then(|c| {
            c.get(format!("{url}/health"))
                .bearer_auth(&d.token)
                .send()
                .ok()
        })
        .map(|r| r.status().as_u16() == 200)
        .unwrap_or(false);
    let manager = if d.mode.is_empty() { "container".into() } else { d.mode };
    DaemonStatus {
        state: if healthy { "running" } else { "unhealthy" }.into(),
        url,
        pid: d.pid,
        token: d.token,
        manager,
    }
}

#[tauri::command]
pub fn daemon_status() -> DaemonStatus {
    status()
}

/// Bring the runtime up — IDEMPOTENT. If one is already healthy (container OR a
/// raw dev runtime) we leave it alone and never boot a container over it, so the
/// two dev modes coexist. Only `wb deploy local` when nothing is live.
#[tauri::command]
pub fn daemon_up() -> DaemonStatus {
    let cur = status();
    if cur.state == "running" {
        return cur;
    }
    let _ = wb(&["deploy", "local", "--json"]);
    wait_for_discovery();
    status()
}

#[tauri::command]
pub fn daemon_down() -> DaemonStatus {
    // Never tear down a raw (externally managed) runtime — it isn't ours to kill.
    if status().manager == "raw" {
        return status();
    }
    let _ = wb(&["deploy", "down", "--json"]);
    status()
}

/// Recover a wedged runtime. Only valid for a runtime WE manage (a container);
/// a `raw` dev runtime is left untouched with an explanatory error so the tray
/// never kills the user's `iex` session out from under them.
#[tauri::command]
pub fn daemon_restart() -> Result<DaemonStatus, String> {
    let cur = status();
    if cur.manager == "raw" {
        return Err(
            "Runtime is running in raw dev mode (e.g. `WB_DESKTOP=1 iex -S mix`) — \
             the tray doesn't manage it. Restart it where you launched it."
                .into(),
        );
    }
    let _ = wb(&["deploy", "down", "--json"]);
    let _ = wb(&["deploy", "local", "--json"]);
    wait_for_discovery();
    Ok(status())
}

/// Poll up to ~10s for the runtime to write its discovery file after a boot.
fn wait_for_discovery() {
    for _ in 0..40 {
        if Discovery::read().is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
}

/// The tray's single "Start / restart engine" action, made safe:
///   • nothing live          → start a container (`wb deploy local`)
///   • live & container-ours → restart it (down + up)
///   • live & raw (dev)      → no-op; we don't own it
/// Returns a short human note for logging.
pub fn tray_engine_action() -> String {
    let cur = status();
    match (cur.state.as_str(), cur.manager.as_str()) {
        ("running", "raw") => "engine: raw dev runtime is healthy — left untouched".into(),
        ("running", _) => {
            let _ = wb(&["deploy", "down", "--json"]);
            let _ = wb(&["deploy", "local", "--json"]);
            wait_for_discovery();
            "engine: restarted container".into()
        }
        _ => {
            let _ = wb(&["deploy", "local", "--json"]);
            wait_for_discovery();
            "engine: started container".into()
        }
    }
}

/// Background poll: every ~3s re-read discovery + /health and emit
/// `daemon-state` only when the status actually changes (so the UI isn't
/// spammed). Spawned once from setup().
pub fn spawn_state_poll(app: AppHandle) {
    std::thread::spawn(move || {
        let mut last: Option<DaemonStatus> = None;
        loop {
            let cur = status();
            if last.as_ref() != Some(&cur) {
                let _ = app.emit("daemon-state", &cur);
                last = Some(cur);
            }
            std::thread::sleep(std::time::Duration::from_secs(3));
        }
    });
}
