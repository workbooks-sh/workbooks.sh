// The engine bridge. Boots the runtime the SAME way `wb deploy local` does — a
// libkrun microVM driven by krunvm — but NATIVELY from Rust (see machine.rs), so
// a freshly-downloaded desktop needs ONLY the krunvm backend on the host: no
// Erlang, no `wb` escript. We read the discovery file the runtime writes inside
// the VM and fold it with a /health probe into one status the titlebar trusts.

use crate::machine;
use serde::{Deserialize, Serialize};
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
    /// Host to reach the runtime on. Local microVMs omit it (→ 127.0.0.1, since
    /// the host maps the port to loopback); a cloud config writes the real host.
    #[serde(default = "default_host")]
    pub host: String,
    #[serde(default)]
    #[allow(dead_code)]
    pub pid: u32,
    /// Who manages this runtime: "container" (we booted the microVM, so we own
    /// its lifecycle and may restart it), "raw" (a dev runtime launched by hand —
    /// the tray must never kill it), or "cloud" (a remote engine — never torn
    /// down locally). Absent on legacy runtimes → treated as "container".
    #[serde(default)]
    pub mode: String,
}

fn default_scheme() -> String {
    "http".into()
}

fn default_host() -> String {
    "127.0.0.1".into()
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
    /// "container" | "raw" | "cloud" | "" (no discovery). Lets the UI label an
    /// externally managed runtime the tray won't restart (raw dev or cloud).
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
    let url = format!("{}://{}:{}", d.scheme, d.host, d.port);
    // 200ms for a loopback microVM; a touch longer so a cloud host across the
    // network doesn't flap to "unhealthy" on a slow round-trip.
    let timeout = if d.host == "127.0.0.1" { 200 } else { 800 };
    let healthy = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_millis(timeout))
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

/// Bring the runtime up — IDEMPOTENT. If one is already healthy (container, raw
/// dev, or cloud) we leave it alone. Otherwise boot a local microVM natively
/// (machine::boot). The wizard uses `engine_boot_local` for a richer, longer
/// boot with progress; this is the tray's quick path.
#[tauri::command]
pub fn daemon_up(app: AppHandle) -> DaemonStatus {
    let cur = status();
    if cur.state == "running" {
        return cur;
    }
    let _ = machine::boot(&app);
    wait_for_discovery(40);
    status()
}

#[tauri::command]
pub fn daemon_down() -> DaemonStatus {
    // Never tear down an externally managed runtime — a raw dev runtime isn't
    // ours to kill, and a cloud engine isn't local. Just stop ours.
    let m = status().manager;
    if m == "raw" || m == "cloud" {
        return status();
    }
    let _ = machine::down();
    status()
}

/// Recover a wedged runtime. Only valid for a runtime WE manage (a container);
/// a `raw` dev runtime is left untouched with an explanatory error so the tray
/// never kills the user's `iex` session out from under them.
#[tauri::command]
pub fn daemon_restart(app: AppHandle) -> Result<DaemonStatus, String> {
    let cur = status();
    if cur.manager == "raw" {
        return Err(
            "Runtime is running in raw dev mode (e.g. `WB_DESKTOP=1 iex -S mix`) — \
             the tray doesn't manage it. Restart it where you launched it."
                .into(),
        );
    }
    if cur.manager == "cloud" {
        return Err("Connected to a cloud engine — nothing local to restart.".into());
    }
    let _ = machine::down();
    machine::boot(&app)?;
    wait_for_discovery(40);
    Ok(status())
}

/// Poll for the runtime to write its discovery file after a boot. `ticks` ×
/// 250ms — callers size it to the expected wait (a warm boot is seconds; a
/// first image pull is minutes, so the wizard polls far longer).
fn wait_for_discovery(ticks: u32) {
    for _ in 0..ticks {
        if Discovery::read().is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
}

/// The tray's single "Start / restart engine" action, made safe:
///   • nothing live          → start a local microVM (machine::boot)
///   • live & container-ours → restart it (down + boot)
///   • live & raw (dev)      → no-op; we don't own it
///   • live & cloud          → no-op; it isn't local
/// Returns a short human note for logging.
pub fn tray_engine_action(app: &AppHandle) -> String {
    let cur = status();
    match (cur.state.as_str(), cur.manager.as_str()) {
        ("running", "raw") => "engine: raw dev runtime is healthy — left untouched".into(),
        ("running", "cloud") => "engine: connected to a cloud engine — nothing local to restart".into(),
        ("running", _) => {
            let _ = machine::down();
            let _ = machine::boot(app);
            wait_for_discovery(40);
            "engine: restarted container".into()
        }
        _ => {
            let _ = machine::boot(app);
            wait_for_discovery(40);
            "engine: started container".into()
        }
    }
}

// ---- install wizard surface -------------------------------------------------

/// What the wizard shows on the local path: OS support + which backend pieces
/// are present. Drives "install krunvm" vs "boot now".
#[tauri::command]
pub fn engine_detect() -> machine::BackendStatus {
    machine::detect()
}

/// Install the local VM backend (krunvm via Homebrew). Streams `engine-setup`
/// progress lines to the frontend. Surfaces the real error on failure.
#[tauri::command]
pub fn engine_install_backend(app: AppHandle) -> Result<machine::BackendStatus, String> {
    machine::install_krunvm(&app)?;
    Ok(machine::detect())
}

/// Boot the local engine and wait — through a first-run image pull — for it to
/// come up. Emits `engine-setup` progress; polls discovery up to ~6 min, then
/// returns whatever status we have (the caller decides on a non-running result).
#[tauri::command]
pub fn engine_boot_local(app: AppHandle) -> Result<DaemonStatus, String> {
    machine::boot(&app)?;
    // First boot pulls the multi-hundred-MB image — poll patiently, nudging the
    // wizard every few seconds so it never looks hung.
    for i in 0..720 {
        if Discovery::read().is_some() {
            break;
        }
        if i > 0 && i % 16 == 0 {
            let _ = app.emit("engine-setup", "still pulling the engine image…");
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    Ok(status())
}

/// Probe an arbitrary engine URL + token (cloud path) WITHOUT persisting it, so
/// the wizard can validate before committing. Returns true on /health 200.
#[tauri::command]
pub fn engine_probe(url: String, token: String) -> Result<bool, String> {
    let (scheme, host, port) = machine::parse_url(&url)?;
    let probe = format!("{scheme}://{host}:{port}/health");
    let resp = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .map_err(|e| e.to_string())?
        .get(&probe)
        .bearer_auth(&token)
        .send()
        .map_err(|e| format!("could not reach {probe}: {e}"))?;
    Ok(resp.status().as_u16() == 200)
}

/// Connect to a cloud engine: probe it, and only on a healthy 200 persist the
/// cloud discovery so the rest of the app targets it. Returns the folded status.
#[tauri::command]
pub fn engine_connect_cloud(url: String, token: String) -> Result<DaemonStatus, String> {
    if !engine_probe(url.clone(), token.clone())? {
        return Err("Engine reached but /health did not return 200 — check the URL and token.".into());
    }
    machine::write_cloud(&url, &token)?;
    Ok(status())
}

/// Disconnect from a cloud engine (removes the cloud discovery). No-op if the
/// current runtime is a local one — that's `daemon_down`'s job.
#[tauri::command]
pub fn engine_disconnect_cloud() -> DaemonStatus {
    if status().manager == "cloud" {
        let _ = machine::clear_cloud();
    }
    status()
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
