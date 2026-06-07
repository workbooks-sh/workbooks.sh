// Sidecar lifecycle for the local Elixir `workbooks-runtime`.
//
// wb-i38o.2: spawn-on-boot + stdout port discovery + health check +
// auto-restart + graceful shutdown.
// wb-i38o.16: prod path uses the Tauri v2 shell-plugin sidecar API
// against the `externalBin` declaration in `tauri.conf.json`. The
// per-target binary is staged at `src-tauri/binaries/workbooks-runtime-<triple>`
// by `mix runtime.stage` (in runtime/engine/), which wraps the
// `workbooks_runtime` release with Burrito and copies it into place.
// The dev fallback path (`mix run --no-halt`) remains unchanged.
//
// wb-7z8r.3: retargeted from the legacy `workbooks-engine` binary at
// engine/ to the canonical `workbooks-runtime` binary at runtime/engine/.
//
// Two spawn modes:
//   1. **Bundled** (prod): `tauri-plugin-shell` resolves the per-target
//      `workbooks-runtime-<triple>` binary that Tauri's bundler placed inside
//      the app package. Selected first; if the shell plugin can't find
//      it (typical in `tauri dev` where externalBin staging is skipped)
//      we fall through to dev mode.
//   2. **Dev** (fallback): `mix run --no-halt` against
//      `runtime/engine/`. Auto-selected when the bundled binary is missing.
//
// Contract with the Burrito binary (wb-i38o.17): one line of the form
// `OQL_LISTEN=localhost:<port>` printed to stdout within 5s of
// spawn. In dev mode (where mix doesn't print that line today),
// we time out and fall back to the agent's compile-time default
// (`config/config.exs` → http port 4000).
//
// State machine emitted to the WebView via the `sidecar-state` event:
//   starting → ready → unhealthy → restarting → ready ...
//                                       ↘ crashed | stopped

#![allow(clippy::too_many_lines)]

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use once_cell::sync::OnceCell;
use regex::Regex;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{Mutex, RwLock};

// First-launch with the Burrito-packaged binary involves extracting
// ~30MB of ERTS + the release tree to ~/Library/Application Support/
// .burrito_<app>_<version>/ before Phoenix can bind a port. On a
// modern Mac that's typically 3-8s; on slower disks / cold caches it
// can stretch to 15-20s. Subsequent launches reuse the cached extract
// and boot in <1s. 30s was original; bumped to 90s in wb-80q0.10
// after observing the false-Crashed bug where the sidecar prints
// OQL_LISTEN= one log-line AFTER the deadline (key injection +
// Phoenix endpoint bind sometimes overlap with the timer). The real
// fix is the launchd-managed daemon per docs/desktop/agent-lifecycle.md;
// until that lands, the bump gives headroom on cold first-launch.
const PORT_DISCOVERY_TIMEOUT_SECS: u64 = 90;
const HEALTH_CHECK_INTERVAL_SECS: u64 = 5;
const HEALTH_CHECK_FAILS_BEFORE_RESTART: u32 = 3;
const SHUTDOWN_GRACE_SECS: u64 = 5;
// In dev mode we don't get the OQL_LISTEN line — runtime binds the
// compile-time default from `runtime/engine/config/config.exs`.
const DEV_DEFAULT_PORT: u16 = 4000;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum SidecarState {
    Starting,
    Ready,
    Unhealthy,
    Crashed,
    Restarting,
    Stopped,
}

/// One line of sidecar stdout/stderr. Emitted on the `sidecar-log`
/// Tauri event so the embedded terminal drawer can render the
/// sidecar as a pinned read-only "logs" session. The drawer keeps a
/// short in-memory ring buffer so opening the drawer after the
/// sidecar has been running for a while shows recent context.
#[derive(Clone, Debug, Serialize)]
struct SidecarLogEvent {
    /// `"stdout"` or `"stderr"` — the drawer can color stderr
    /// differently if it wants.
    stream: &'static str,
    /// The raw line, without the trailing newline (BufReader strips it).
    line: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct SidecarStatus {
    pub state: SidecarState,
    pub url: Option<String>,
    pub mode: Option<String>, // "bundled" | "dev" | "daemon"
    pub message: Option<String>,
}

#[derive(Default)]
pub struct SidecarState_ {
    pub status: RwLock<SidecarStatus>,
    pub child: Mutex<Option<Child>>,
    shutdown_requested: RwLock<bool>,
    /// Per-spawn bearer token for the sidecar's `/internal/*` routes.
    /// Generated fresh each spawn (32 random bytes, base64-urlsafe),
    /// shared with the child via `OQL_INTERNAL_TOKEN`. Never on
    /// disk; gone the moment the sidecar (and this struct) goes away.
    pub internal_token: RwLock<Option<String>>,
    /// Snapshot of the env-var map the live sidecar last accepted.
    /// Diffed against the freshly-computed map on every push so we
    /// can send `unset` for keys that have been removed since the
    /// last push (otherwise the BEAM keeps the stale value).
    /// Seeded at spawn from the env vars we injected via `cmd.env`.
    pub last_pushed_secrets: RwLock<std::collections::HashMap<String, String>>,
}

impl Default for SidecarState {
    fn default() -> Self {
        SidecarState::Stopped
    }
}

impl Default for SidecarStatus {
    fn default() -> Self {
        Self {
            state: SidecarState::Stopped,
            url: None,
            mode: None,
            message: None,
        }
    }
}

static SIDECAR: OnceCell<Arc<SidecarState_>> = OnceCell::new();

pub fn instance() -> Arc<SidecarState_> {
    SIDECAR
        .get_or_init(|| Arc::new(SidecarState_::default()))
        .clone()
}

#[derive(Clone, Copy)]
enum SpawnMode {
    Bundled,
    Dev,
}

impl SpawnMode {
    fn as_str(self) -> &'static str {
        match self {
            SpawnMode::Bundled => "bundled",
            SpawnMode::Dev => "dev",
        }
    }
}

/// Resolve the bundled sidecar binary path, or `None` if it isn't
/// present (triggering dev-mode fallback).
///
/// Tauri v2 bundles `externalBin` entries adjacent to the main
/// executable (Contents/MacOS/ on macOS, alongside the .exe on
/// Windows, and under /usr/lib/<pkg>/ on Linux). The binary is named
/// `<basename>-<target-triple>[.exe]`. We probe both the executable
/// dir and the resource dir (which differ on Linux + macOS) so the
/// resolution works for every bundle target.
pub fn bundled_binary_path(app: &AppHandle) -> Option<PathBuf> {
    let basename = "workbooks-runtime";
    let mut search_dirs: Vec<PathBuf> = vec![];
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            search_dirs.push(dir.to_path_buf());
        }
    }
    if let Ok(rd) = app.path().resource_dir() {
        search_dirs.push(rd.clone());
        // Some bundle layouts put externalBin under resources/binaries/.
        search_dirs.push(rd.join("binaries"));
    }

    let triple = target_triple();
    let names: [String; 4] = [
        format!("{basename}-{triple}"),
        format!("{basename}-{triple}.exe"),
        basename.to_string(),
        format!("{basename}.exe"),
    ];
    for dir in &search_dirs {
        for name in &names {
            let p = dir.join(name);
            if p.exists() {
                return Some(p);
            }
        }
    }
    None
}

fn target_triple() -> &'static str {
    // Mirrors Tauri's externalBin triple naming. Compiled in by
    // build.rs / std env; sufficient for the macOS path we currently
    // need.
    #[cfg(all(target_os = "macos", target_arch = "aarch64"))]
    {
        "aarch64-apple-darwin"
    }
    #[cfg(all(target_os = "macos", target_arch = "x86_64"))]
    {
        "x86_64-apple-darwin"
    }
    #[cfg(all(target_os = "linux", target_arch = "x86_64"))]
    {
        "x86_64-unknown-linux-gnu"
    }
    #[cfg(all(target_os = "linux", target_arch = "aarch64"))]
    {
        "aarch64-unknown-linux-gnu"
    }
    #[cfg(target_os = "windows")]
    {
        "x86_64-pc-windows-msvc"
    }
}

/// Resolve the dev-mode `mix run --no-halt` working directory.
///
/// Walks up from the Tauri binary's CWD looking for
/// `runtime/engine/mix.exs`. The Tauri dev process runs from
/// `desktop/src-tauri/` so we have to climb out.
pub fn dev_mix_dir() -> Option<PathBuf> {
    let start = std::env::current_dir().ok()?;
    let mut cur: &std::path::Path = &start;
    for _ in 0..8 {
        let probe = cur.join("runtime/engine/mix.exs");
        if probe.exists() {
            return Some(cur.join("runtime/engine"));
        }
        cur = cur.parent()?;
    }
    None
}

async fn set_status(app: &AppHandle, status: SidecarStatus) {
    let s = instance();
    *s.status.write().await = status.clone();
    let _ = app.emit("sidecar-state", &status);
    log::info!(
        "[sidecar] state={:?} url={:?} mode={:?} msg={:?}",
        status.state,
        status.url,
        status.mode,
        status.message
    );
}

/// Spawn the sidecar and wait for either the `OQL_LISTEN=...` line
/// or the dev-mode timeout (in which case we assume the default port).
async fn spawn_once(app: &AppHandle) -> Result<(), String> {
    set_status(
        app,
        SidecarStatus {
            state: SidecarState::Starting,
            url: None,
            mode: None,
            message: None,
        },
    )
    .await;

    // wb-7z8r.3 — `workbooks-runtime` from runtime/engine/ is the
    // canonical engine. Prefer the bundled binary; fall through to
    // `mix run --no-halt` only if no bundled binary is reachable
    // (typical when iterating on runtime source — delete the staged
    // binary or set WORKBOOKS_RUNTIME_PREFER_DEV=1 to force the mix
    // path).
    //
    // Heuristic to detect a leftover stub: the real Burrito binary is
    // 8MB+. If the file is suspiciously small (<1MB) we treat it as a
    // stub from a half-built tree and fall through.
    let prefer_dev = std::env::var("WORKBOOKS_RUNTIME_PREFER_DEV")
        .map(|v| v == "1" || v == "true")
        .unwrap_or(false);

    let bundled = if prefer_dev {
        None
    } else {
        bundled_binary_path(app).filter(|p| {
            std::fs::metadata(p)
                .map(|m| m.len() >= 1_000_000)
                .unwrap_or(false)
        })
    };
    let (mut cmd, mode) = if let Some(bin) = bundled {
        log::info!("[sidecar] spawning RUNTIME binary: {}", bin.display());
        let mut c = Command::new(bin);
        c.env("MIX_ENV", "prod");
        (c, SpawnMode::Bundled)
    } else {
        let mix_dir = dev_mix_dir().ok_or_else(|| {
            "DEV MODE: could not locate runtime/engine/mix.exs from the Tauri CWD"
                .to_string()
        })?;
        log::info!("[sidecar] DEV MODE: spawning via `mix run --no-halt` in {mix_dir:?}");
        let mut c = Command::new("mix");
        c.arg("run").arg("--no-halt");
        c.current_dir(mix_dir);
        c.env("MIX_ENV", "dev");
        (c, SpawnMode::Dev)
    };

    // wb-i38o.6 §1 — inject user-configured provider API keys into the
    // sidecar's environment. Most-recently-created key per provider
    // wins (resolved by `keys::env_vars_for_sidecar`). Changing keys
    // requires a restart — wired via the `sidecar_restart` Tauri
    // command, which the UI invokes after writing keys.json.
    let key_envs = crate::keys::env_vars_for_sidecar().await;
    if !key_envs.is_empty() {
        log::info!(
            "[sidecar] injecting {} provider key(s): {}",
            key_envs.len(),
            key_envs
                .iter()
                .map(|(k, _)| k.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    for (k, v) in &key_envs {
        cmd.env(k, v);
    }

    // Integration connections (Composio, Doppler, GitHub) — each
    // forwards its own env var (COMPOSIO_API_KEY, DOPPLER_TOKEN, etc.)
    // so the sidecar can call the service's SDK on the user's behalf.
    let conn_envs = crate::connections::env_vars_for_sidecar().await;
    if !conn_envs.is_empty() {
        log::info!(
            "[sidecar] injecting {} integration token(s): {}",
            conn_envs.len(),
            conn_envs
                .iter()
                .map(|(k, _)| k.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    for (k, v) in &conn_envs {
        cmd.env(k, v);
    }

    // Agent defaults (default model → WB_AGENT_MODEL). Read by
    // `Workbooks.Engine.LLM` at call time, so the next agent call after a
    // settings change picks up the new value automatically.
    let agent_envs = crate::agent_settings::env_vars_for_sidecar().await;
    for (k, v) in &agent_envs {
        cmd.env(k, v);
    }

    // Per-spawn token for the sidecar's `/internal/secrets/refresh`
    // route. We generate it here, hand it to the child via env, and
    // remember it on the sidecar state so future mutations can push
    // updates without restarting the sidecar.
    let token = generate_internal_token();
    cmd.env("OQL_INTERNAL_TOKEN", &token);
    *instance().internal_token.write().await = Some(token);

    // Seed the "last pushed" snapshot with the env vars we just
    // injected at spawn time. Without this, the first `unset` diff
    // after a delete-only mutation would be empty (we'd think the
    // BEAM doesn't have those vars).
    {
        let mut seed: std::collections::HashMap<String, String> =
            std::collections::HashMap::new();
        for (k, v) in &key_envs {
            seed.insert(k.clone(), v.clone());
        }
        for (k, v) in &conn_envs {
            seed.insert(k.clone(), v.clone());
        }
        for (k, v) in &agent_envs {
            seed.insert(k.clone(), v.clone());
        }
        *instance().last_pushed_secrets.write().await = seed;
    }

    cmd.stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);

    let mut child = cmd.spawn().map_err(|e| {
        format!("[sidecar] spawn failed (mode={}): {e}", mode.as_str())
    })?;

    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "[sidecar] no stdout pipe".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "[sidecar] no stderr pipe".to_string())?;

    // Forward stderr to our log unconditionally — useful for debugging.
    // Also emit each line on the `sidecar-log` Tauri event so the
    // embedded terminal drawer can render the sidecar as a pinned
    // read-only "logs" session.
    {
        let app_log = app.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                log::warn!("[sidecar:stderr] {line}");
                let _ = app_log.emit(
                    "sidecar-log",
                    &SidecarLogEvent {
                        stream: "stderr",
                        line: line.clone(),
                    },
                );
            }
        });
    }

    // Watch stdout for the discovery line, while also forwarding it to logs.
    //
    // LATENT BUG FIXED: previously this had
    //   if let (Some(tx), Some(caps)) = (port_tx.take(), re.captures(&line))
    // which constructed the tuple BEFORE the destructure check, so
    // `port_tx.take()` ran on EVERY line — and on the first non-
    // matching line (which is the first stdout line the sidecar
    // emits, before OQL_LISTEN=), port_tx was consumed and dropped
    // into the void. port_rx then resolved with Err, but the old
    // 90s timer masked it with its own "didn't print within 90s"
    // error so nobody noticed for months. The fix: only take() when
    // we KNOW the regex matched.
    let (port_tx, port_rx) = tokio::sync::oneshot::channel::<u16>();
    {
        let app_log = app.clone();
        tokio::spawn(async move {
            let re = Regex::new(r"OQL_LISTEN=localhost:(\d+)").unwrap();
            let mut reader = BufReader::new(stdout).lines();
            let mut port_tx = Some(port_tx);
            while let Ok(Some(line)) = reader.next_line().await {
                log::info!("[sidecar:stdout] {line}");
                let _ = app_log.emit(
                    "sidecar-log",
                    &SidecarLogEvent {
                        stream: "stdout",
                        line: line.clone(),
                    },
                );
                if let Some(caps) = re.captures(&line) {
                    if let Some(tx) = port_tx.take() {
                        if let Ok(port) = caps[1].parse::<u16>() {
                            let _ = tx.send(port);
                            // keep loop running to drain stdout
                        }
                    }
                }
            }
        });
    }

    // Discover the port. Mode-specific because the dev-mode `mix run`
    // path doesn't emit OQL_LISTEN= today, so we fall back to the
    // compile-time default port after a wait. The bundled binary
    // ALWAYS emits the line per the wb-i38o.17 contract, so we wait
    // indefinitely on the stdout parser there — the actual failure
    // signal is the child process exiting, NOT a wall-clock timer.
    // The previous one-shot timeout was a false-positive race: a
    // 1-second-boot sidecar would print OQL_LISTEN= one log-line
    // after the timer fired, and the desktop would permanently mark
    // it Crashed even though it was healthy on its port.
    let port = match mode {
        SpawnMode::Bundled => {
            tokio::select! {
                result = port_rx => match result {
                    Ok(p) => p,
                    Err(_) => {
                        return Err(
                            "[sidecar] stdout parser closed before OQL_LISTEN= arrived"
                                .to_string(),
                        );
                    }
                },
                exit = child.wait() => {
                    return Err(format!(
                        "[sidecar] child exited before OQL_LISTEN=: {exit:?}"
                    ));
                }
            }
        }
        SpawnMode::Dev => match tokio::time::timeout(
            Duration::from_secs(PORT_DISCOVERY_TIMEOUT_SECS),
            port_rx,
        )
        .await
        {
            Ok(Ok(p)) => p,
            _ => {
                log::info!(
                    "[sidecar] DEV MODE: no OQL_LISTEN line in {PORT_DISCOVERY_TIMEOUT_SECS}s — \
                     assuming the agent's compile-time default port {DEV_DEFAULT_PORT}"
                );
                DEV_DEFAULT_PORT
            }
        },
    };

    // Stash the child handle so shutdown can find it. Moved AFTER
    // port discovery because the bundled-mode select! above needs
    // exclusive mut access to `child` for the wait() race.
    {
        let s = instance();
        *s.child.lock().await = Some(child);
    }

    // Probe /health until the endpoint actually accepts connections —
    // mix takes a few seconds to compile + boot Phoenix on first run.
    let url = format!("http://localhost:{port}");
    let mut probes = 0u32;
    loop {
        if reqwest::get(format!("{url}/health"))
            .await
            .map(|r| r.status().is_success())
            .unwrap_or(false)
        {
            break;
        }
        probes += 1;
        if probes > 60 {
            return Err(format!("/health never came up at {url} after 60s"));
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    }

    // Log the daemon's self-reported build manifest so any sidecar/
    // desktop drift is visible in the log immediately. The expected
    // values are baked into the sidecar binary at compile-time (see
    // `build.rs` — `WB_GIT_SHA` / `WB_BUILT_AT`); the daemon bakes
    // its own at `Workbooks.Engine.Web.AboutController` module-eval time.
    log_about(&url).await;

    set_status(
        app,
        SidecarStatus {
            state: SidecarState::Ready,
            url: Some(url),
            mode: Some(mode.as_str().to_string()),
            message: None,
        },
    )
    .await;
    Ok(())
}

/// Fetch `/api/about` from the freshly-booted daemon and log a one-
/// line summary plus a drift warning if its `git_sha` doesn't match
/// the sidecar's compile-time sha. The expected sha is read from the
/// `WB_GIT_SHA` env var at compile time (set by `build.rs`); when
/// it's missing we skip the comparison (e.g., binary built outside a
/// git checkout).
async fn log_about(base_url: &str) {
    let url = format!("{base_url}/api/about");
    match reqwest::get(&url).await {
        Ok(resp) if resp.status().is_success() => match resp.text().await {
            Ok(body) => {
                log::info!("[sidecar] daemon /api/about: {body}");
                if let Some(expected) = option_env!("WB_GIT_SHA") {
                    // Cheap substring check — the daemon's body is JSON
                    // with `"git_sha":"<sha>"`. If we don't find our
                    // expected sha in the body, log a warning.
                    if !body.contains(expected) {
                        log::warn!(
                            "[sidecar] DAEMON-DESKTOP DRIFT: sidecar built at git_sha={expected}, daemon reports a different sha. \
                             Run `mix runtime.stage` in runtime/engine/ to rebuild + restage the sidecar binary, \
                             or set WORKBOOKS_RUNTIME_PREFER_DEV=1 to run the daemon from source via `mix run --no-halt`."
                        );
                    }
                }
            }
            Err(e) => log::warn!("[sidecar] /api/about body read failed: {e}"),
        },
        Ok(resp) => log::warn!("[sidecar] /api/about returned {}", resp.status()),
        Err(e) => log::warn!("[sidecar] /api/about probe failed: {e}"),
    }
}

/// Background loop: poll /health every 5s, restart on 3 consecutive failures.
async fn health_loop(app: AppHandle) {
    loop {
        tokio::time::sleep(Duration::from_secs(HEALTH_CHECK_INTERVAL_SECS)).await;

        if *instance().shutdown_requested.read().await {
            break;
        }

        let url = {
            let s = instance();
            let guard = s.status.read().await;
            guard.url.clone()
        };
        let Some(url) = url else { continue };

        let mut consecutive_fail = 0u32;
        loop {
            let ok = reqwest::get(format!("{url}/health"))
                .await
                .map(|r| r.status().is_success())
                .unwrap_or(false);
            if ok {
                break;
            }
            consecutive_fail += 1;
            if consecutive_fail == 1 {
                let current = instance().status.read().await.clone();
                if current.state == SidecarState::Ready {
                    set_status(
                        &app,
                        SidecarStatus {
                            state: SidecarState::Unhealthy,
                            url: current.url.clone(),
                            mode: current.mode.clone(),
                            message: Some("/health failing".to_string()),
                        },
                    )
                    .await;
                }
            }
            if consecutive_fail >= HEALTH_CHECK_FAILS_BEFORE_RESTART {
                log::warn!(
                    "[sidecar] {HEALTH_CHECK_FAILS_BEFORE_RESTART} consecutive /health failures — restarting"
                );
                let prev_mode = instance().status.read().await.mode.clone();
                set_status(
                    &app,
                    SidecarStatus {
                        state: SidecarState::Restarting,
                        url: None,
                        mode: prev_mode.clone(),
                        message: Some("health check failed".to_string()),
                    },
                )
                .await;
                // In daemon mode we DON'T own the process — launchd
                // restarts it via KeepAlive. We just re-attach to
                // whatever URL the new daemon publishes (port may
                // have changed). In spawn mode we own the child and
                // do the kill-and-respawn dance ourselves.
                if prev_mode.as_deref() == Some("daemon") {
                    // Retry indefinitely with exponential backoff
                    // capped at 30s. launchd will eventually bring
                    // the daemon back; we just wait. The user never
                    // has to click "restart sidecar" — recovery is
                    // fully automatic regardless of outage length
                    // (could be a slow `workbooks-runtime install` cycle,
                    // a sleep/wake, or a launchd KeepAlive trip).
                    let mut wait_secs: u64 = 1;
                    loop {
                        if *instance().shutdown_requested.read().await {
                            return;
                        }
                        tokio::time::sleep(Duration::from_secs(wait_secs)).await;
                        if try_attach_daemon(&app).await.is_ok() {
                            break;
                        }
                        // Stay informative in the UI while we wait.
                        set_status(
                            &app,
                            SidecarStatus {
                                state: SidecarState::Restarting,
                                url: None,
                                mode: Some("daemon".to_string()),
                                message: Some(format!(
                                    "waiting for daemon to come back (next try in {wait_secs}s)"
                                )),
                            },
                        )
                        .await;
                        wait_secs = (wait_secs * 2).min(30);
                    }
                } else {
                    let _ = kill_child(SHUTDOWN_GRACE_SECS).await;
                    if let Err(e) = spawn_once(&app).await {
                        set_status(
                            &app,
                            SidecarStatus {
                                state: SidecarState::Crashed,
                                url: None,
                                mode: None,
                                message: Some(e),
                            },
                        )
                        .await;
                    }
                }
                break;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        }
    }
}

async fn kill_child(grace_secs: u64) -> Result<(), String> {
    let s = instance();
    let mut guard = s.child.lock().await;
    let Some(mut child) = guard.take() else {
        return Ok(());
    };

    // SIGTERM (best effort on unix) → grace → SIGKILL.
    #[cfg(unix)]
    {
        if let Some(pid) = child.id() {
            // SAFETY: this would be `unsafe`; we go through the nix-free
            // pure-`libc` route by writing the pid file… but we can't
            // call libc::kill without unsafe. Instead: rely on
            // tokio's `start_kill` (sends SIGKILL on unix). Sending
            // a true SIGTERM requires `nix` or `unsafe libc::kill`.
            //
            // To honor the forbid_unsafe crate-root rule and still get
            // a graceful term, we shell out to /bin/kill — slower but
            // safe.
            let _ = std::process::Command::new("/bin/kill")
                .arg("-TERM")
                .arg(pid.to_string())
                .status();
        }
    }

    match tokio::time::timeout(Duration::from_secs(grace_secs), child.wait()).await {
        Ok(_) => Ok(()),
        Err(_) => {
            let _ = child.start_kill();
            let _ = child.wait().await;
            Ok(())
        }
    }
}

/// Public entry point — call from Tauri `setup`.
///
/// Lifecycle policy:
///   1. If a launchd plist (or systemd-equivalent on other OS) is
///      installed, the daemon is the **sole** owner of the engine
///      process. We attach with backoff, never spawn a competing
///      instance. This avoids the dual-owner Postgres-lock fight that
///      historically caused "Workbooks isn't running" stuck states.
///   2. If no daemon is installed AND we're in a debug build (the
///      `tauri:dev` workflow on a fresh checkout), we spawn via
///      `mix run --no-halt` for developer ergonomics.
///   3. If no daemon is installed in a release build, we surface a
///      clean "engine not installed" status. No silent fallback —
///      the only path to a working engine in prod is the installer.
pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let plist_installed = daemon_installed();

        // First attach attempt — try multiple times if a daemon should
        // be running (covers the ~5–10s window after a launchd-managed
        // restart, while pg_ctl is finishing initialisation).
        let attach_budget = if plist_installed {
            Duration::from_secs(18)
        } else {
            // No daemon expected; give it 1 quick try to cover the
            // case where the user just-installed but hasn't loaded
            // the plist yet.
            Duration::from_secs(2)
        };

        match try_attach_daemon_with_backoff(&app, attach_budget).await {
            Ok(()) => {
                log::info!("[sidecar] attached to launchd-managed daemon");
                health_loop(app).await;
                return;
            }
            Err(e) => {
                log::info!(
                    "[sidecar] daemon attach failed after {}s: {e}",
                    attach_budget.as_secs()
                );
            }
        }

        // No daemon reachable. Two cases:
        //   - Dev (debug build) with no plist installed → `mix run`
        //     so the developer doesn't have to install the daemon
        //     just to iterate on the desktop UI.
        //   - Any case where a plist IS installed but didn't come up
        //     in the attach window → surface "starting" with the
        //     hint that the user can hit "Restart engine" in the
        //     tray menu. Do NOT spawn — that would fight the daemon.
        if plist_installed {
            set_status(
                &app,
                SidecarStatus {
                    state: SidecarState::Stopped,
                    url: None,
                    mode: Some("daemon".to_string()),
                    message: Some(
                        "Workbooks engine didn't come online. \
                         Try Restart engine from the menu bar."
                            .to_string(),
                    ),
                },
            )
            .await;
            // Keep the health-loop alive so a manual restart (or a
            // delayed launchd respawn) flips us back to Ready when
            // listen.json reappears.
            health_loop(app).await;
            return;
        }

        // No daemon installed.
        #[cfg(debug_assertions)]
        {
            log::info!(
                "[sidecar] no daemon installed; dev-mode mix-run fallback"
            );
            if let Err(e) = spawn_once(&app).await {
                set_status(
                    &app,
                    SidecarStatus {
                        state: SidecarState::Crashed,
                        url: None,
                        mode: None,
                        message: Some(e),
                    },
                )
                .await;
            }
            health_loop(app).await;
        }

        #[cfg(not(debug_assertions))]
        {
            set_status(
                &app,
                SidecarStatus {
                    state: SidecarState::Stopped,
                    url: None,
                    mode: None,
                    message: Some(
                        "Workbooks engine not installed. Run the \
                         installer or reinstall from workbooks.sh."
                            .to_string(),
                    ),
                },
            )
            .await;
            health_loop(app).await;
        }
    });
}

/// True if a launchd plist (macOS) / systemd unit (Linux) /
/// scheduled task (Windows) is registered for the daemon. Only the
/// macOS check is implemented; the other platforms fall through to
/// `false` for now, which means the desktop uses the dev-mode
/// fallback in debug builds and surfaces "not installed" in release.
fn daemon_installed() -> bool {
    #[cfg(target_os = "macos")]
    {
        if let Some(home) = std::env::var_os("HOME") {
            let plist = std::path::PathBuf::from(home)
                .join("Library")
                .join("LaunchAgents")
                .join("sh.workbooks.engine.plist");
            return plist.exists();
        }
        false
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

/// Repeatedly try `try_attach_daemon` until it succeeds or the budget
/// expires. Backoff is short (250 → 500 → 1000 → 2000ms) so the
/// common-path latency on app boot stays under a second when the
/// daemon is already up.
async fn try_attach_daemon_with_backoff(
    app: &AppHandle,
    budget: Duration,
) -> Result<(), String> {
    let start = std::time::Instant::now();
    let backoffs = [250_u64, 500, 1_000, 1_500, 2_000, 2_000, 2_000];
    let mut idx: usize = 0;
    let mut last_err = String::from("not attempted");

    while start.elapsed() < budget {
        match try_attach_daemon(app).await {
            Ok(()) => return Ok(()),
            Err(e) => {
                last_err = e;
            }
        }
        let delay_ms = backoffs[idx.min(backoffs.len() - 1)];
        idx += 1;
        // Don't sleep past the budget.
        let remaining = budget.saturating_sub(start.elapsed());
        if remaining.is_zero() {
            break;
        }
        let sleep = Duration::from_millis(delay_ms).min(remaining);
        tokio::time::sleep(sleep).await;
    }
    Err(last_err)
}

/// Read the discovery file written by the daemon at boot and verify
/// the daemon answers /health. On success, populate sidecar state so
/// the rest of the desktop (WS bridge, internal-route callers) finds
/// the URL + token as if we'd spawned it ourselves.
async fn try_attach_daemon(app: &AppHandle) -> Result<(), String> {
    let (url, token, pid) = read_discovery_file().ok_or_else(|| {
        "discovery file missing or unreadable".to_string()
    })?;

    // Liveness probe — `/health` is cheap and proves the daemon is
    // actually answering, not just that listen.json is stale.
    let health = format!("{url}/health");
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .map_err(|e| format!("http client: {e}"))?;

    client
        .get(&health)
        .send()
        .await
        .map_err(|e| format!("health probe failed: {e}"))?
        .error_for_status()
        .map_err(|e| format!("health status: {e}"))?;

    *instance().internal_token.write().await = Some(token);

    set_status(
        app,
        SidecarStatus {
            state: SidecarState::Ready,
            url: Some(url),
            mode: Some("daemon".to_string()),
            message: Some(format!("attached to launchd daemon pid={pid}")),
        },
    )
    .await;

    // Launchd doesn't inherit shell env, so the daemon starts with
    // no API keys / connection tokens. Push them now via the
    // internal-routes endpoint; LLM + integration calls will work
    // on the next request. Fire-and-forget — push_secrets_async
    // logs its own failures.
    push_secrets_async();

    Ok(())
}

fn read_discovery_file() -> Option<(String, String, u32)> {
    let home = std::env::var_os("HOME")?;
    let path = std::path::PathBuf::from(home)
        .join("Workbooks")
        .join("Engine")
        .join("listen.json");
    let body = std::fs::read_to_string(&path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    let url = v.get("url")?.as_str()?.to_string();
    let token = v.get("token")?.as_str()?.to_string();
    let pid = v.get("pid")?.as_u64()? as u32;
    Some((url, token, pid))
}

/// Call on window-close / app-quit.
pub async fn shutdown(app: AppHandle) {
    *instance().shutdown_requested.write().await = true;
    let mode = instance().status.read().await.mode.clone();
    // In daemon mode we DO NOT touch the daemon process — it
    // outlives every desktop session by design. `kill_child` is a
    // no-op (we never owned a child) but skipping it makes the
    // intent explicit.
    if mode.as_deref() != Some("daemon") {
        let _ = kill_child(SHUTDOWN_GRACE_SECS).await;
    }
    set_status(
        &app,
        SidecarStatus {
            state: SidecarState::Stopped,
            url: None,
            mode,
            message: None,
        },
    )
    .await;
}

// ── Tauri commands exposed to the WebView ───────────────────────────

#[tauri::command]
pub async fn sidecar_status() -> SidecarStatus {
    instance().status.read().await.clone()
}

/// Manually restart the sidecar — exposed for the Settings UI so it can
/// re-spawn after the user changes provider API keys (the env vars are
/// only read on spawn). We deliberately don't auto-restart on every
/// keys.json write: a session in flight would be killed mid-tool-call.
/// The UI surfaces a "restart sidecar" button + a warning chip when
/// keys have changed since the last spawn.
#[tauri::command]
pub async fn sidecar_restart(app: AppHandle) -> Result<(), String> {
    log::info!("[sidecar] manual restart requested");
    let prev_mode = instance().status.read().await.mode.clone();
    set_status(
        &app,
        SidecarStatus {
            state: SidecarState::Restarting,
            url: None,
            mode: prev_mode.clone(),
            message: Some("manual restart (settings changed)".to_string()),
        },
    )
    .await;
    // Daemon mode: launchctl owns the lifecycle. `kickstart -k`
    // tells launchd to stop and immediately restart the loaded
    // job. We then re-attach by reading the new discovery file.
    // The user's "restart sidecar" intent usually means "re-pick
    // up changed env vars" — secrets actually flow through
    // /internal/secrets/refresh without restart, but the button
    // is preserved as an escape hatch for env-var bugs.
    if prev_mode.as_deref() == Some("daemon") {
        let uid = std::process::Command::new("id")
            .arg("-u")
            .output()
            .ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|| "501".to_string());
        let _ = std::process::Command::new("launchctl")
            .args(["kickstart", "-k", &format!("gui/{uid}/sh.workbooks.engine")])
            .output();
        for _ in 0..30 {
            tokio::time::sleep(Duration::from_secs(1)).await;
            if try_attach_daemon(&app).await.is_ok() {
                return Ok(());
            }
        }
        let msg = "daemon did not come back within 30s of kickstart".to_string();
        set_status(
            &app,
            SidecarStatus {
                state: SidecarState::Crashed,
                url: None,
                mode: Some("daemon".to_string()),
                message: Some(msg.clone()),
            },
        )
        .await;
        return Err(msg);
    }

    let _ = kill_child(SHUTDOWN_GRACE_SECS).await;
    if let Err(e) = spawn_once(&app).await {
        set_status(
            &app,
            SidecarStatus {
                state: SidecarState::Crashed,
                url: None,
                mode: None,
                message: Some(e.clone()),
            },
        )
        .await;
        return Err(e);
    }
    Ok(())
}

// ── Internal secret refresh ────────────────────────────────────────
//
// Push refreshed env vars to the running sidecar so secret changes
// land without a full restart. The sidecar's `/internal/secrets/refresh`
// route is gated by `OQL_INTERNAL_TOKEN`, generated per-spawn above
// — only this process knows it, so no other localhost process can
// poke the route.

fn generate_internal_token() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
    B64.encode(bytes)
}

/// Push the current full secret map to the running sidecar.
///
/// Fire-and-forget — secret writes have already been persisted to
/// disk by the calling Tauri command, so even if this push fails the
/// next sidecar (re)start will pick up the new values via env. We
/// log on failure but don't return errors to the caller.
///
/// No-op when the sidecar isn't ready (no URL, no token). The next
/// successful spawn will inject the merged secrets via env anyway.
pub fn push_secrets_async() {
    tokio::spawn(async move {
        if let Err(e) = push_secrets_inner().await {
            log::warn!("[sidecar] secret refresh push failed: {e}");
        }
    });
}

async fn push_secrets_inner() -> Result<(), String> {
    let s = instance();
    let url = s.status.read().await.url.clone();
    let token = s.internal_token.read().await.clone();

    let (Some(url), Some(token)) = (url, token) else {
        // Sidecar not ready yet — next spawn will pick up via env.
        return Ok(());
    };

    // Compute the freshly-merged map. Keys + connections + agent
    // settings (WB_AGENT_MODEL); env-vars.rs values are out-of-scope
    // until a tool runtime reads them.
    let mut current: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    for (k, v) in crate::keys::env_vars_for_sidecar().await {
        current.insert(k, v);
    }
    for (k, v) in crate::connections::env_vars_for_sidecar().await {
        current.insert(k, v);
    }
    for (k, v) in crate::agent_settings::env_vars_for_sidecar().await {
        current.insert(k, v);
    }

    // Diff against the last successfully-pushed snapshot.
    //
    //   set:   keys whose value differs (or didn't exist before)
    //   unset: keys that were in the snapshot but are gone now
    //
    // We send only the delta so the BEAM doesn't waste cycles re-
    // writing identical values, and so logs read sensibly.
    let previous = s.last_pushed_secrets.read().await.clone();
    let mut set: std::collections::HashMap<String, String> =
        std::collections::HashMap::new();
    for (k, v) in &current {
        if previous.get(k).map(|prev| prev != v).unwrap_or(true) {
            set.insert(k.clone(), v.clone());
        }
    }
    let unset: Vec<String> = previous
        .keys()
        .filter(|k| !current.contains_key(*k))
        .cloned()
        .collect();

    if set.is_empty() && unset.is_empty() {
        return Ok(());
    }

    let body = serde_json::json!({ "set": set, "unset": unset });

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(5))
        .build()
        .map_err(|e| format!("client build: {e}"))?;

    let resp = client
        .post(format!("{url}/internal/secrets/refresh"))
        .bearer_auth(&token)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("send: {e}"))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        return Err(format!("status={status} body={text}"));
    }

    // Only update the snapshot on success — a failed push leaves
    // the snapshot stale so the next push retries the same diff.
    *s.last_pushed_secrets.write().await = current;

    log::info!(
        "[sidecar] pushed secrets: +{} set, -{} unset",
        set.len(),
        unset.len()
    );
    Ok(())
}
