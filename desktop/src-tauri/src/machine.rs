//! Native local MACHINE — boots the ONE runtime OCI image inside a libkrun
//! microVM via the `krunvm` CLI, with NO host Erlang and NO `wb` escript. This
//! is route B of the install-wizard plan: on a fresh Mac the ONLY host
//! dependency is the krunvm backend, so the wizard installs that and we drive
//! the create → spawn → discovery dance directly from Rust.
//!
//! Ported from `runtime/host/deploy/machine.ex` — keep the krunvm contract in
//! sync with that module (the Elixir `wb deploy local` path is the same dance):
//!   * a case-sensitive APFS volume named `krunvm` (one-time, no sudo)
//!   * `krunvm create <image> --name N --port H:G --volume H:G`
//!   * `krunvm start N -- <cmd>` runs the microVM in the FOREGROUND
//!
//! The runtime inside binds 0.0.0.0:4000 and writes the discovery file into the
//! bind-mounted /disco dir; the host maps 4000→4000 so the discovered port is
//! reachable on localhost. We pin the host port to the guest port (4000) because
//! the guest writes the GUEST port into discovery and cannot know a remapped
//! host port.

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use tauri::{AppHandle, Emitter};

const VM: &str = "workbooks-runtime";
const GUEST_PORT: u16 = 4000;
const HOST_PORT: u16 = 4000;
const DEFAULT_IMAGE: &str = "ghcr.io/workbooks-sh/runtime:latest";

/// The release `start` command blocks on a TTY under krunvm's no-TTY guest, so
/// we boot the app with `eval` (no console) and park the node alive so the VM
/// stays up. krunvm execs this expr as a single argv element (no shell).
const BOOT_EXPR: &str = "case Application.ensure_all_started(:workbooks) do {:ok, _} -> Process.sleep(:infinity); err -> IO.inspect(err); System.halt(1) end";

/// The runtime image reference — overridable via `WB_IMAGE` for local pins.
fn image() -> String {
    std::env::var("WB_IMAGE").unwrap_or_else(|_| DEFAULT_IMAGE.into())
}

// ---- host paths (mirror daemon::discovery_path + machine.ex defaults) -------

fn support_dir() -> Option<std::path::PathBuf> {
    Some(dirs::data_dir()?.join("sh.workbooks"))
}

/// Where the runtime writes its discovery file (bind-mounted into the guest as
/// /disco). `WB_DESKTOP_DIR` overrides — and daemon::discovery_path reads the
/// same override, so the two always agree.
fn disco_dir() -> Option<std::path::PathBuf> {
    if let Ok(dir) = std::env::var("WB_DESKTOP_DIR") {
        return Some(std::path::PathBuf::from(dir));
    }
    Some(support_dir()?.join("disco"))
}

fn data_dir() -> Option<std::path::PathBuf> {
    Some(support_dir()?.join("data"))
}

fn log_dir() -> Option<std::path::PathBuf> {
    Some(support_dir()?.join("logs"))
}

fn pidfile() -> Option<std::path::PathBuf> {
    Some(support_dir()?.join("runtime.pid"))
}

// ---- detection --------------------------------------------------------------

/// What the wizard needs to know before it can offer a local boot: the host OS,
/// whether the krunvm backend (and its one-time APFS volume) are present, and
/// whether Homebrew is available to install krunvm. `supported` is false on any
/// non-mac OS — the wizard routes those to the cloud path for v1.
#[derive(serde::Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct BackendStatus {
    pub os: String,
    pub supported: bool,
    pub krunvm: bool,
    pub apfs_volume: bool,
    pub brew: bool,
}

pub fn detect() -> BackendStatus {
    let os = std::env::consts::OS.to_string();
    let supported = os == "macos";
    if !supported {
        return BackendStatus { os, supported, krunvm: false, apfs_volume: false, brew: false };
    }
    BackendStatus {
        os,
        supported,
        krunvm: command_exists("krunvm"),
        apfs_volume: apfs_volume_present(),
        brew: command_exists("brew"),
    }
}

fn command_exists(name: &str) -> bool {
    Command::new("command")
        .args(["-v", name])
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
        // `command` is a shell builtin — not always exec'able directly. Fall
        // back to `which`, then to a PATH scan, so detection is robust.
        || Command::new("which").arg(name).output().map(|o| o.status.success()).unwrap_or(false)
}

fn apfs_volume_present() -> bool {
    if std::path::Path::new("/Volumes/krunvm").is_dir() {
        return true;
    }
    sh("diskutil", &["list"]).map(|o| o.contains("krunvm")).unwrap_or(false)
}

// ---- one-time prerequisites -------------------------------------------------

/// Create the case-sensitive APFS volume krunvm needs for its OCI store
/// (idempotent, no sudo, non-destructive).
pub fn ensure_apfs_volume() -> Result<(), String> {
    if apfs_volume_present() {
        return Ok(());
    }
    let container = apfs_container();
    sh_ok("diskutil", &["apfs", "addVolume", &container, "Case-sensitive APFS", "krunvm"])
        .map(|_| ())
        .map_err(|e| format!("could not create APFS volume on {container}: {e}"))
}

/// The APFS container backing `/` (e.g. `disk3`), parsed from `diskutil info /`.
fn apfs_container() -> String {
    sh("diskutil", &["info", "/"])
        .ok()
        .and_then(|out| {
            out.lines().find_map(|line| {
                line.split_once("APFS Container:")
                    .and_then(|(_, rest)| rest.split_whitespace().next().map(str::to_string))
            })
        })
        .unwrap_or_else(|| "disk3".into())
}

/// Install krunvm via Homebrew, streaming each output line to the frontend as an
/// `engine-setup` event so the wizard can show live progress. Requires `brew`.
pub fn install_krunvm(app: &AppHandle) -> Result<(), String> {
    if !command_exists("brew") {
        return Err(
            "Homebrew not found. Install it from https://brew.sh, then retry — \
             or run `brew tap slp/krun && brew install krunvm` yourself."
                .into(),
        );
    }
    emit_setup(app, "Tapping slp/krun…");
    stream("brew", &["tap", "slp/krun"], app)?;
    emit_setup(app, "Installing krunvm (this can take a few minutes)…");
    stream("brew", &["install", "krunvm"], app)?;
    if !command_exists("krunvm") {
        return Err("brew reported success but `krunvm` is still not on PATH.".into());
    }
    emit_setup(app, "krunvm installed.");
    Ok(())
}

// ---- boot / teardown --------------------------------------------------------

/// (Re)create the microVM, mapping host 4000 → guest 4000, the data dir → /data,
/// and the disco dir → /disco. Idempotent: deletes any existing VM of the same
/// name first so port/volume changes actually take.
fn create() -> Result<(), String> {
    let data = data_dir().ok_or("no data dir")?;
    let disco = disco_dir().ok_or("no disco dir")?;
    std::fs::create_dir_all(&data).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&disco).map_err(|e| e.to_string())?;

    let _ = sh("krunvm", &["delete", VM]);

    let port_map = format!("{HOST_PORT}:{GUEST_PORT}");
    let data_vol = format!("{}:/data", data.display());
    let disco_vol = format!("{}:/disco", disco.display());
    let img = image();
    let args = vec![
        "create", img.as_str(),
        "--name", VM,
        "--cpus", "2",
        "--mem", "2048",
        // The image's WORKDIR isn't inherited by krunvm — set it or a relative
        // entrypoint runs from `/` and fails.
        "--workdir", "/app",
        "--port", &port_map,
        "--volume", &data_vol,
        "--volume", &disco_vol,
    ];
    sh_ok("krunvm", &args).map(|_| ()).map_err(|e| format!("krunvm create failed: {e}"))
}

/// Spawn the microVM DETACHED in the caller's GUI/Aqua session (libkrun
/// virtualization fails under a background LaunchAgent — EX_CONFIG/78). The app
/// lives in the Aqua session, so the krunvm we background here boots cleanly and
/// survives the app quitting (reparented via nohup). Writes the pid for `down`.
fn spawn() -> Result<(), String> {
    let logs = log_dir().ok_or("no log dir")?;
    std::fs::create_dir_all(&logs).map_err(|e| e.to_string())?;
    let out = logs.join("runtime.out.log");
    let err = logs.join("runtime.err.log");
    let pid = pidfile().ok_or("no pidfile path")?;

    // Build the krunvm argv: env injected via --env, the app booted via `eval`.
    let mut argv: Vec<String> = vec!["krunvm".into(), "start".into(), VM.into()];
    for (k, v) in [
        ("WB_DESKTOP", "1"),
        ("WB_DESKTOP_DIR", "/disco"),
        ("WB_DATA", "/data"),
        ("WB_EMBED", "local"),
    ] {
        argv.push("--env".into());
        argv.push(format!("{k}={v}"));
    }
    argv.push("--".into());
    argv.push("/app/bin/workbooks".into());
    argv.push("eval".into());
    argv.push(BOOT_EXPR.into());

    let cmd = argv.iter().map(|a| shquote(a)).collect::<Vec<_>>().join(" ");
    let script = format!(
        "nohup {cmd} >> {out} 2>> {err} & echo $! > {pid}",
        out = shquote(&out.display().to_string()),
        err = shquote(&err.display().to_string()),
        pid = shquote(&pid.display().to_string()),
    );

    sh_ok("sh", &["-c", &script]).map(|_| ()).map_err(|e| format!("could not spawn krunvm: {e}"))
}

/// The full local boot: ensure the APFS volume, (re)create the VM, spawn it.
/// Emits `engine-setup` progress at each step. The caller waits for discovery.
pub fn boot(app: &AppHandle) -> Result<(), String> {
    emit_setup(app, "Preparing the krunvm volume…");
    ensure_apfs_volume()?;
    emit_setup(app, "Creating the microVM (first run pulls the engine image — this is slow once)…");
    create()?;
    emit_setup(app, "Booting the engine…");
    spawn()?;
    Ok(())
}

/// Kill the directly-spawned microVM (if any) and delete the VM definition.
/// Leaves the APFS volume + image store intact so the next boot is fast.
pub fn down() -> Result<(), String> {
    if let Some(pid) = read_pidfile() {
        let _ = sh("kill", &[&pid.to_string()]);
    }
    if let Some(p) = pidfile() {
        let _ = std::fs::remove_file(p);
    }
    let _ = sh("krunvm", &["delete", VM]);
    Ok(())
}

fn read_pidfile() -> Option<u32> {
    let p = pidfile()?;
    std::fs::read_to_string(p).ok()?.trim().parse().ok()
}

// ---- cloud config -----------------------------------------------------------

/// Point the desktop at a remote engine by writing a discovery file with the
/// cloud host + token and `mode: "cloud"`. The rest of the app reads discovery
/// uniformly, so once this is written the titlebar/transport target the cloud
/// engine. The wizard probes /health first (see `engine_probe`) before calling
/// this, so a written cloud config is always one that just answered.
pub fn write_cloud(url: &str, token: &str) -> Result<(), String> {
    let (scheme, host, port) = parse_url(url)?;
    let disco = disco_dir().ok_or("no disco dir")?;
    std::fs::create_dir_all(&disco).map_err(|e| e.to_string())?;
    let body = serde_json::json!({
        "scheme": scheme,
        "host": host,
        "port": port,
        "token": token,
        "pid": 0,
        "mode": "cloud",
    });
    std::fs::write(disco.join("runtime.json"), body.to_string()).map_err(|e| e.to_string())
}

/// Remove a cloud discovery file (disconnect). No-op if absent.
pub fn clear_cloud() -> Result<(), String> {
    if let Some(disco) = disco_dir() {
        let _ = std::fs::remove_file(disco.join("runtime.json"));
    }
    Ok(())
}

/// Split a URL into (scheme, host, port). Defaults: https→443, http→80; an
/// explicit `:port` wins. Used for both cloud config and the health probe.
pub fn parse_url(url: &str) -> Result<(String, String, u16), String> {
    let url = url.trim();
    let (scheme, rest) = url.split_once("://").unwrap_or(("https", url));
    let scheme = if scheme.is_empty() { "https" } else { scheme };
    // Strip any path/query.
    let authority = rest.split(['/', '?']).next().unwrap_or(rest);
    if authority.is_empty() {
        return Err("empty host".into());
    }
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) => {
            let port: u16 = p.parse().map_err(|_| format!("invalid port in `{url}`"))?;
            (h.to_string(), port)
        }
        None => {
            let port = if scheme == "https" { 443 } else { 80 };
            (authority.to_string(), port)
        }
    };
    Ok((scheme.to_string(), host, port))
}

// ---- shell helpers ----------------------------------------------------------

/// Run a command, returning combined stdout on success or the combined output
/// on failure. `Err` also covers a missing binary.
fn sh(cmd: &str, args: &[&str]) -> Result<String, String> {
    match Command::new(cmd).args(args).output() {
        Ok(out) => {
            let mut s = String::from_utf8_lossy(&out.stdout).to_string();
            s.push_str(&String::from_utf8_lossy(&out.stderr));
            if out.status.success() { Ok(s) } else { Err(s.trim().to_string()) }
        }
        Err(e) => Err(format!("could not run `{cmd}`: {e}")),
    }
}

/// Like `sh` but treats a non-empty stderr-with-success as still-ok; used where
/// we only care that the exit code was zero.
fn sh_ok(cmd: &str, args: &[&str]) -> Result<String, String> {
    sh(cmd, args)
}

/// Run a command, streaming each combined stdout/stderr line to the frontend as
/// an `engine-setup` event. Errors if the command exits non-zero.
fn stream(cmd: &str, args: &[&str], app: &AppHandle) -> Result<(), String> {
    let mut child = Command::new(cmd)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("could not run `{cmd}`: {e}"))?;

    if let Some(out) = child.stdout.take() {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            emit_setup(app, &line);
        }
    }
    if let Some(err) = child.stderr.take() {
        for line in BufReader::new(err).lines().map_while(Result::ok) {
            emit_setup(app, &line);
        }
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("`{} {}` failed (exit {:?})", cmd, args.join(" "), status.code()))
    }
}

fn emit_setup(app: &AppHandle, line: &str) {
    let _ = app.emit("engine-setup", line);
}

/// POSIX single-quote: wrap in '…' and escape embedded quotes as '\''.
fn shquote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_url_defaults_https() {
        assert_eq!(
            parse_url("engine.example.com").unwrap(),
            ("https".into(), "engine.example.com".into(), 443)
        );
    }

    #[test]
    fn parse_url_explicit_scheme_and_port() {
        assert_eq!(
            parse_url("http://localhost:4000").unwrap(),
            ("http".into(), "localhost".into(), 4000)
        );
        assert_eq!(
            parse_url("https://e.example.com:8443/").unwrap(),
            ("https".into(), "e.example.com".into(), 8443)
        );
    }

    #[test]
    fn parse_url_strips_path_and_query() {
        assert_eq!(
            parse_url("https://e.example.com/health?x=1").unwrap(),
            ("https".into(), "e.example.com".into(), 443)
        );
    }

    #[test]
    fn parse_url_http_default_port_80() {
        assert_eq!(parse_url("http://box").unwrap().2, 80);
    }

    #[test]
    fn parse_url_rejects_garbage_port() {
        assert!(parse_url("http://h:notaport").is_err());
    }

    #[test]
    fn parse_url_rejects_empty() {
        assert!(parse_url("https://").is_err());
    }

    #[test]
    fn shquote_escapes_single_quotes() {
        assert_eq!(shquote("a'b"), "'a'\\''b'");
        assert_eq!(shquote("plain"), "'plain'");
    }
}
