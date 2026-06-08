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
    DaemonStatus {
        state: if healthy { "running" } else { "unhealthy" }.into(),
        url,
        pid: d.pid,
        token: d.token,
    }
}

#[tauri::command]
pub fn daemon_status() -> DaemonStatus {
    status()
}

#[tauri::command]
pub fn daemon_up() -> DaemonStatus {
    let _ = wb(&["deploy", "local", "--json"]);
    status()
}

#[tauri::command]
pub fn daemon_down() -> DaemonStatus {
    let _ = wb(&["deploy", "down", "--json"]);
    status()
}

#[tauri::command]
pub fn daemon_restart() -> Result<DaemonStatus, String> {
    let _ = wb(&["deploy", "down", "--json"]);
    let _ = wb(&["deploy", "local", "--json"]);
    // Give the runtime a moment to write its discovery file.
    for _ in 0..40 {
        if Discovery::read().is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    Ok(status())
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
