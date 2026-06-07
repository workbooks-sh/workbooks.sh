// The deploy-kit bridge. The shell never reimplements deploy logic — it runs the
// SAME `wb deploy` verbs we ship to users (dogfood) and reads the discovery file
// the runtime writes. The agent-grade `--json` + exit codes are exactly what a
// supervisor needs.

use serde::Deserialize;
use std::process::Command;

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
