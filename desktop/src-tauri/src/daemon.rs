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
/// Probe the discovered engine's `/health` with a caller-chosen timeout. The
/// titlebar chip uses a short one (snappy, won't flap). The COLD-BOOT wait uses
/// a far more patient one: a microVM under first-boot load (image pull, BEAM
/// start, initial compile) can take well over 200ms to answer /health even
/// though it IS coming up healthy — a too-short probe is exactly what produced
/// "the engine booted but never reported healthy" (wb-gozb / wb-iq4n).
fn discovered_health_ok(d: &Discovery, timeout_ms: u64) -> bool {
    let url = format!("{}://{}:{}", d.scheme, d.host, d.port);
    reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_millis(timeout_ms))
        .build()
        .ok()
        .and_then(|c| c.get(format!("{url}/health")).bearer_auth(&d.token).send().ok())
        .map(|r| r.status().as_u16() == 200)
        .unwrap_or(false)
}

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
    // network doesn't flap to "unhealthy" on a slow round-trip. (The cold-boot
    // wait uses a far more patient timeout — see discovered_health_ok.)
    let timeout = if d.host == "127.0.0.1" { 200 } else { 800 };
    let healthy = discovered_health_ok(&d, timeout);
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
/// Bring the runtime up — IDEMPOTENT, ASYNC (the boot can take seconds to
/// minutes; a sync command would run on the main thread and freeze the UI).
#[tauri::command]
pub async fn daemon_up(app: AppHandle) -> Result<DaemonStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let cur = status();
        if cur.state == "running" {
            return cur;
        }
        let _ = machine::boot(&app);
        wait_for_discovery(40);
        let s = status();
        // A freshly-booted runtime starts with no secrets in its env — forward
        // the user's keys (OpenRouter/Gemini/…) so Waldo chat + voice work
        // without waiting for the next key-save (wb-2s09).
        if s.state == "running" {
            crate::keychain::refresh_runtime_secrets();
        }
        s
    })
    .await
    .map_err(|e| e.to_string())
}

#[tauri::command]
pub async fn daemon_down() -> Result<DaemonStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        // Never tear down an externally managed runtime — a raw dev runtime
        // isn't ours to kill, and a cloud engine isn't local. Just stop ours.
        let m = status().manager;
        if m == "raw" || m == "cloud" {
            return status();
        }
        let _ = machine::down();
        status()
    })
    .await
    .map_err(|e| e.to_string())
}

/// Recover a wedged runtime. Only valid for a runtime WE manage (a container);
/// a `raw` dev runtime is left untouched with an explanatory error so the tray
/// never kills the user's `iex` session out from under them.
#[tauri::command]
pub async fn daemon_restart(app: AppHandle) -> Result<DaemonStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
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
    })
    .await
    .map_err(|e| e.to_string())?
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
/// progress lines to the frontend. ASYNC — a brew install takes minutes and
/// must never run on the main thread.
#[tauri::command]
pub async fn engine_install_backend(app: AppHandle) -> Result<machine::BackendStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        machine::install_krunvm(&app)?;
        Ok(machine::detect())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Boot the local engine and wait — through a first-run image pull — for it to
/// come up HEALTHY. Two old bugs fixed here:
///   • sync command → the up-to-6-minute wait ran ON THE MAIN THREAD and froze
///     the entire app. Now async + spawn_blocking.
///   • the wait broke on the discovery FILE existing — a stale runtime.json
///     from a previous run satisfied it instantly while nothing was running
///     ("set up" with no engine). Stale non-cloud discovery is purged before
///     boot, and the wait now requires a passing /health, not a file.
#[tauri::command]
pub async fn engine_boot_local(app: AppHandle) -> Result<DaemonStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        // Idempotent retry: a healthy-but-SLOW engine (cold microVM answering
        // /health in >200ms) must NOT be judged stale and purged — that strands
        // the running engine and boots a second one. Use the patient probe so a
        // re-run reuses the live engine.
        if let Some(d) = Discovery::read() {
            let stale = d.mode != "cloud" && !discovered_health_ok(&d, 2000);
            if stale {
                if let Some(p) = discovery_path() {
                    let _ = std::fs::remove_file(p);
                    let _ = app.emit("engine-setup", "cleared stale runtime discovery");
                }
            }
        }
        machine::boot(&app)?;
        // First boot pulls the multi-hundred-MB image AND a cold microVM answers
        // /health slowly under load — poll PATIENTLY (a 2s probe, not the chip's
        // 200ms, which falsely read "never healthy") on a wall-clock deadline so
        // a slow probe can't blow past it. Nudge the UI so it never looks hung.
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(360);
        let mut healthy = false;
        let mut i: u32 = 0;
        while std::time::Instant::now() < deadline {
            if let Some(d) = Discovery::read() {
                if d.mode == "cloud" || discovered_health_ok(&d, 2000) {
                    healthy = true;
                    break;
                }
            }
            if i > 0 && i % 16 == 0 {
                let _ = app.emit("engine-setup", "still pulling the engine image…");
            }
            i += 1;
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        if !healthy {
            return Err(
                "The engine booted but never reported healthy. Check the tray → engine logs, then retry.".into(),
            );
        }
        Ok(status())
    })
    .await
    .map_err(|e| e.to_string())?
}

/// Blocking /health probe shared by engine_probe + engine_connect_cloud.
fn probe_health(url: &str, token: &str) -> Result<bool, String> {
    let (scheme, host, port) = machine::parse_url(url)?;
    let probe = format!("{scheme}://{host}:{port}/health");
    let resp = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .map_err(|e| e.to_string())?
        .get(&probe)
        .bearer_auth(token)
        .send()
        .map_err(|e| format!("could not reach {probe}: {e}"))?;
    Ok(resp.status().as_u16() == 200)
}

/// Probe an arbitrary engine URL + token (cloud path) WITHOUT persisting it, so
/// the wizard can validate before committing. Returns true on /health 200.
#[tauri::command]
pub async fn engine_probe(url: String, token: String) -> Result<bool, String> {
    tauri::async_runtime::spawn_blocking(move || probe_health(&url, &token))
        .await
        .map_err(|e| e.to_string())?
}

/// Connect to a cloud engine: probe it, and only on a healthy 200 persist the
/// cloud discovery so the rest of the app targets it. Returns the folded status.
#[tauri::command]
pub async fn engine_connect_cloud(url: String, token: String) -> Result<DaemonStatus, String> {
    tauri::async_runtime::spawn_blocking(move || {
        if !probe_health(&url, &token)? {
            return Err(
                "Engine reached but /health did not return 200 — check the URL and token.".into(),
            );
        }
        machine::write_cloud(&url, &token)?;
        Ok(status())
    })
    .await
    .map_err(|e| e.to_string())?
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
        let mut ticks: u32 = 0;
        loop {
            let cur = status();
            // Emit on every CHANGE, and also a periodic heartbeat (every ~5th
            // tick ≈ 15s) even when unchanged. A webview that reloads (HMR, or a
            // navigation) sets up a fresh `daemon-state` listener and would
            // otherwise wait indefinitely for the next change — the heartbeat
            // guarantees it converges to the live status, and with it the bridge
            // (re)connects to a runtime that restarted under the same url.
            ticks += 1;
            if last.as_ref() != Some(&cur) || ticks % 5 == 0 {
                let _ = app.emit("daemon-state", &cur);
                last = Some(cur);
            }
            std::thread::sleep(std::time::Duration::from_secs(3));
        }
    });
}
