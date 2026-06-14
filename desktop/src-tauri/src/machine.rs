//! Native local MACHINE — boots the ONE runtime image locally, preferring
//! vfkit → docker → podman → krunvm (`WB_ENGINE` overrides).
//!
//! vfkit (wb-hhf.2, spike at desktop/scripts/engine-spike/): direct-kernel
//! boots a raw ext4 disk cut from the runtime OCI image — 0-2s cold boot, no
//! daemon, no brew, fully bundleable. It only wins the election when its
//! engine bundle (binary + kernel + initramfs + disk) is already present.
//!
//! Why docker → podman → krunvm after that (wb-ryw, 2026-06-10): the full
//! runtime is I/O-heavy at boot (BEAM module loads, wasmtime NIFs, sqlite, a
//! ~30MB embedding model). Docker and podman machines give the guest a real
//! virtual DISK (block device + overlayfs) — the same image goes discovery +
//! /health 200 in ~5s. krunvm's libkrun shares host folders via virtio-fs and
//! impersonates sockets via TSI; under our app that floor measured
//! 8-minutes-to-never, plus a day of TSI bugs (accept-serialization,
//! startup_log deadlock, a 1.19 host-bind regression). krunvm stays as the
//! no-daemon fallback path.
//!
//! All engines speak the SAME contract: host 4000 → guest 4000 (the guest
//! writes the GUEST port into the bind-mounted /disco discovery file and
//! cannot know a remapped host port), data dir → /data, disco dir → /disco.
//! The vfkit guest only has a NAT ip, so a tiny in-process loopback proxy
//! keeps 127.0.0.1:4000 true for the rest of the app.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::{AppHandle, Emitter};

const VM: &str = "workbooks-runtime";
const GUEST_PORT: u16 = 4000;
const HOST_PORT: u16 = 4000;
const DEFAULT_IMAGE: &str = "ghcr.io/workbooks-sh/runtime:latest";

/// ghcr OCI artifact holding the vfkit boot assets (built by
/// .github/workflows/engine-disk.yml after every runtime publish).
const DEFAULT_ENGINE_DISK: &str = "ghcr.io/workbooks-sh/engine-disk:latest";
/// No leading-zero octets — /var/db/dhcpd_leases strips them per octet; the
/// matcher normalizes anyway, but a clean MAC keeps eyeball-debugging sane.
const VFKIT_MAC: &str = "5a:94:ef:e4:1c:ee";
/// Spike-proven cmdline: ext4 root on the first virtio-blk, our PID-1 wrapper.
const VFKIT_CMDLINE: &str =
    "console=hvc0 root=/dev/vda rw rootfstype=ext4 modules=ext4 init=/sbin/wb-init";
/// The official crc-org vfkit release we fetch when no vfkit is bundled or on
/// PATH. It's a SIGNED + NOTARIZED universal (x86_64+arm64) binary carrying the
/// `com.apple.security.virtualization` entitlement, so it runs standalone — no
/// app-bundle codesign and no Homebrew needed. This is what lets a fresh mac
/// boot a local runtime from the installer alone (sidesteps the signed-bundle
/// path in wb-2s09.17). Override the URL with WB_VFKIT_URL.
const VFKIT_VERSION: &str = "v0.6.3";
const VFKIT_URL: &str = "https://github.com/crc-org/vfkit/releases/download/v0.6.3/vfkit";
/// Layer titles in the engine-disk artifact = file names in the bundle dir.
const ASSET_KERNEL: &str = "kernel-image";
const ASSET_INITRD: &str = "initramfs-wb";
const ASSET_DISK: &str = "disk.img";
const ASSET_DISK_ZST: &str = "disk.img.zst";

/// The release `start` command blocks on a TTY under krunvm's no-TTY guest, so
/// we boot the app with `eval` (no console) and park the node alive so the VM
/// stays up. krunvm execs this expr as a single argv element (no shell).
const BOOT_EXPR: &str = "case Application.ensure_all_started(:workbooks) do {:ok, _} -> Process.sleep(:infinity); err -> IO.inspect(err); System.halt(1) end";

/// The runtime image reference — overridable via `WB_IMAGE` for local pins.
fn image() -> String {
    std::env::var("WB_IMAGE").unwrap_or_else(|_| DEFAULT_IMAGE.into())
}

// ---- engine selection ---------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Engine {
    Vfkit,
    Docker,
    Podman,
    Krunvm,
}

impl Engine {
    fn cli(self) -> &'static str {
        match self {
            Engine::Vfkit => "vfkit",
            Engine::Docker => "docker",
            Engine::Podman => "podman",
            Engine::Krunvm => "krunvm",
        }
    }
}

/// A container engine is "ready" only if its daemon/machine answers — a docker
/// binary with Docker Desktop stopped must not win the election.
fn docker_ready() -> bool {
    sh("docker", &["info", "--format", "{{.ServerVersion}}"]).is_ok()
}

fn podman_ready() -> bool {
    sh("podman", &["info", "--format", "{{.version.Version}}"]).is_ok()
}

/// vfkit is "ready" only with a COMPLETE bundle on disk: the binary (bundled
/// or PATH) plus every boot asset. A dev machine with a stray brew vfkit must
/// not be yanked off its docker lane into a multi-hundred-MB asset download —
/// `WB_ENGINE=vfkit` forces the lane and lets boot_vfkit fetch what's missing.
fn vfkit_ready() -> bool {
    vfkit_bin().is_some()
        && [ASSET_KERNEL, ASSET_INITRD, ASSET_DISK]
            .iter()
            .all(|a| find_asset(a).is_some())
}

/// Pick the boot engine: `WB_ENGINE=vfkit|docker|podman|krunvm` overrides,
/// else the first READY engine in preference order, else krunvm if merely
/// installed (it has no daemon to be "ready").
pub fn engine() -> Option<Engine> {
    match std::env::var("WB_ENGINE").ok().as_deref() {
        Some("vfkit") => return Some(Engine::Vfkit),
        Some("docker") => return Some(Engine::Docker),
        Some("podman") => return Some(Engine::Podman),
        Some("krunvm") => return Some(Engine::Krunvm),
        _ => {}
    }
    if vfkit_ready() {
        Some(Engine::Vfkit)
    } else if docker_ready() {
        Some(Engine::Docker)
    } else if podman_ready() {
        Some(Engine::Podman)
    } else if vfkit_available() {
        // No ready daemon, but vfkit is available — present (bundled/PATH) OR
        // downloadable on macOS: prefer it and fetch the binary + engine-disk on
        // demand. vfkit is the reliable lane (0-2s, direct-kernel boot, /health
        // 200 proven) — strictly better than krunvm, whose libkrun TSI
        // networking measured 8-min-to-never. A dev machine actively using
        // docker/podman still wins above; this only beats the krunvm fallback.
        // This is what makes a FRESH mac (nothing installed) able to boot a
        // local runtime from the installer alone. `WB_ENGINE` overrides either way.
        Some(Engine::Vfkit)
    } else if command_exists("krunvm") {
        Some(Engine::Krunvm)
    } else {
        None
    }
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

fn vfkit_pidfile() -> Option<std::path::PathBuf> {
    Some(support_dir()?.join("vfkit.pid"))
}

// ---- vfkit bundle resolution --------------------------------------------------

/// Engine-bundle dirs, in preference order: explicit `WB_ENGINE_DIR` override,
/// the .app's Contents/Resources/engine (signed bundled builds), the
/// app-support engine dir (dev drops + the download target). Pure so tests
/// can drive it without an .app or env mutation.
fn bundle_candidates(
    env_override: Option<&str>,
    exe: Option<&Path>,
    support: Option<&Path>,
) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(d) = env_override {
        dirs.push(PathBuf::from(d));
    }
    // exe lives at <name>.app/Contents/MacOS/<bin> → Contents/Resources/engine.
    if let Some(contents) = exe.and_then(|e| e.parent()).and_then(|d| d.parent()) {
        dirs.push(contents.join("Resources").join("engine"));
    }
    if let Some(s) = support {
        dirs.push(s.join("engine"));
    }
    dirs
}

fn bundle_dirs() -> Vec<PathBuf> {
    let exe = std::env::current_exe().ok();
    let support = support_dir();
    bundle_candidates(
        std::env::var("WB_ENGINE_DIR").ok().as_deref(),
        exe.as_deref(),
        support.as_deref(),
    )
}

/// The writable engine dir (download target + the disk's home — the Resources
/// copy is sealed by the code signature, so a guest-writable disk.img must
/// live here).
fn engine_dir() -> Option<PathBuf> {
    Some(support_dir()?.join("engine"))
}

fn find_in(dirs: &[PathBuf], name: &str) -> Option<PathBuf> {
    dirs.iter().map(|d| d.join(name)).find(|p| p.is_file())
}

fn find_asset(name: &str) -> Option<PathBuf> {
    find_in(&bundle_dirs(), name)
}

/// Where a downloaded vfkit binary lives (writable engine dir, alongside the
/// disk). Distinct from the sealed Resources bundle copy.
fn vfkit_download_path() -> Option<PathBuf> {
    Some(engine_dir()?.join("vfkit"))
}

/// The vfkit binary: bundled copy first, PATH fallback (dev: brew vfkit), then a
/// previously-downloaded copy in the engine dir.
fn vfkit_bin() -> Option<String> {
    if let Some(p) = find_asset("vfkit") {
        return Some(p.display().to_string());
    }
    if command_exists("vfkit") {
        return Some("vfkit".into());
    }
    vfkit_download_path()
        .filter(|p| p.is_file())
        .map(|p| p.display().to_string())
}

/// Whether vfkit can be used at all — present now, OR fetchable. On macOS the
/// official signed binary is always downloadable, so a fresh mac (no vfkit,
/// docker, podman) can still elect vfkit and boot a local runtime.
fn vfkit_available() -> bool {
    vfkit_bin().is_some() || cfg!(target_os = "macos")
}

/// Return a usable vfkit path, downloading the official signed+notarized binary
/// into the engine dir if none is bundled or on PATH. The crc-org binary ships
/// the virtualization entitlement in its OWN signature, so it runs standalone.
fn ensure_vfkit_bin(app: &AppHandle) -> Result<String, String> {
    if let Some(b) = vfkit_bin() {
        return Ok(b);
    }
    let dest = vfkit_download_path().ok_or("no engine dir for vfkit")?;
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let url = std::env::var("WB_VFKIT_URL").unwrap_or_else(|_| VFKIT_URL.into());
    emit_setup(app, &format!("Downloading the vfkit engine launcher ({VFKIT_VERSION})…"));
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(None)
        .build()
        .map_err(|e| e.to_string())?;
    let mut resp = client
        .get(&url)
        .send()
        .map_err(|e| format!("vfkit download: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("vfkit download {url}: HTTP {}", resp.status()));
    }
    let part = dest.with_extension("part");
    {
        let mut out = std::fs::File::create(&part).map_err(|e| e.to_string())?;
        std::io::copy(&mut resp, &mut out).map_err(|e| e.to_string())?;
    }
    // chmod +x — a release asset arrives without the exec bit.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perm = std::fs::metadata(&part).map_err(|e| e.to_string())?.permissions();
        perm.set_mode(0o755);
        std::fs::set_permissions(&part, perm).map_err(|e| e.to_string())?;
    }
    std::fs::rename(&part, &dest).map_err(|e| e.to_string())?;
    Ok(dest.display().to_string())
}

/// The engine-disk artifact reference — overridable via `WB_ENGINE_DISK`.
fn engine_disk_ref() -> String {
    std::env::var("WB_ENGINE_DISK").unwrap_or_else(|_| DEFAULT_ENGINE_DISK.into())
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
    /// The engine a boot would use right now ("vfkit"|"docker"|"podman"|"krunvm").
    pub engine: Option<String>,
    /// Complete vfkit bundle present (binary + kernel + initramfs + disk).
    pub vfkit: bool,
    pub docker: bool,
    pub podman: bool,
    pub krunvm: bool,
    pub apfs_volume: bool,
    pub brew: bool,
}

pub fn detect() -> BackendStatus {
    let os = std::env::consts::OS.to_string();
    let vfkit = vfkit_ready();
    let docker = docker_ready();
    let podman = podman_ready();
    let krunvm = command_exists("krunvm");
    // A live container daemon supports local boot on ANY os; vfkit + krunvm
    // are the mac-only no-daemon paths.
    let supported = docker || podman || os == "macos";
    BackendStatus {
        engine: engine().map(|e| e.cli().to_string()),
        vfkit,
        docker,
        podman,
        krunvm,
        apfs_volume: os == "macos" && apfs_volume_present(),
        brew: command_exists("brew"),
        os,
        supported,
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
/// name first so port/volume changes actually take. While the create runs (the
/// image pull lives inside it), a sampler thread emits real `engine-pull`
/// progress: bytes landed in the buildah store vs the manifest's layer total.
fn create(app: &AppHandle) -> Result<(), String> {
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

    // Pull-progress sampler: best-effort manifest size from the registry +
    // 1s du of the buildah store. Extracted layers outgrow the compressed
    // manifest total, so the percent is clamped frontend-side.
    let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    {
        let stop = stop.clone();
        let app = app.clone();
        std::thread::spawn(move || {
            let total = registry_total_size();
            let base = storage_bytes();
            loop {
                if stop.load(std::sync::atomic::Ordering::Relaxed) {
                    break;
                }
                let done = storage_bytes().saturating_sub(base);
                let _ = app.emit(
                    "engine-pull",
                    serde_json::json!({ "done": done, "total": total }),
                );
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
            // Terminal event so the bar can complete/clear.
            let _ = app.emit("engine-pull", serde_json::json!({ "done": 0, "total": null }));
        });
    }
    let res = sh_ok("krunvm", &args).map(|_| ()).map_err(|e| format!("krunvm create failed: {e}"));
    stop.store(true, std::sync::atomic::Ordering::Relaxed);
    res
}

/// Bytes currently in the krunvm/buildah image store. `du -sk` over the
/// storage root — cheap at 1Hz and tracks the pull as layers land.
fn storage_bytes() -> u64 {
    sh("du", &["-sk", "/Volumes/krunvm/root"])
        .ok()
        .and_then(|out| {
            out.split_whitespace()
                .next()
                .and_then(|kb| kb.parse::<u64>().ok())
        })
        .map(|kb| kb * 1024)
        .unwrap_or(0)
}

/// Total compressed size of the runtime image from the registry manifest
/// (anonymous ghcr token → manifest/index → sum of layer sizes for this
/// machine's linux arch). Best-effort: None on any hiccup.
fn registry_total_size() -> Option<u64> {
    let img = image();
    let rest = img.strip_prefix("ghcr.io/")?;
    let (repo, tag) = rest.rsplit_once(':').unwrap_or((rest, "latest"));
    let client = reqwest::blocking::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .ok()?;
    let tok: serde_json::Value = client
        .get(format!("https://ghcr.io/token?scope=repository:{repo}:pull"))
        .send()
        .ok()?
        .json()
        .ok()?;
    let tok = tok["token"].as_str()?;
    let accept = "application/vnd.oci.image.manifest.v1+json, \
                  application/vnd.docker.distribution.manifest.v2+json, \
                  application/vnd.oci.image.index.v1+json, \
                  application/vnd.docker.distribution.manifest.list.v2+json";
    let mut man: serde_json::Value = client
        .get(format!("https://ghcr.io/v2/{repo}/manifests/{tag}"))
        .bearer_auth(tok)
        .header("Accept", accept)
        .send()
        .ok()?
        .json()
        .ok()?;
    // Multi-arch index → resolve the linux manifest for this CPU.
    if let Some(list) = man["manifests"].as_array() {
        let want_arch = if cfg!(target_arch = "aarch64") { "arm64" } else { "amd64" };
        let digest = list
            .iter()
            .find(|m| {
                m["platform"]["os"] == "linux" && m["platform"]["architecture"] == want_arch
            })
            .and_then(|m| m["digest"].as_str())?
            .to_string();
        man = client
            .get(format!("https://ghcr.io/v2/{repo}/manifests/{digest}"))
            .bearer_auth(tok)
            .header("Accept", accept)
            .send()
            .ok()?
            .json()
            .ok()?;
    }
    let total: u64 = man["layers"]
        .as_array()?
        .iter()
        .filter_map(|l| l["size"].as_u64())
        .sum();
    (total > 0).then_some(total)
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

/// The full local boot, on the elected engine. Emits `engine-setup` progress
/// at each step. The caller waits for discovery + /health.
pub fn boot(app: &AppHandle) -> Result<(), String> {
    match engine() {
        Some(Engine::Vfkit) => boot_vfkit(app),
        Some(Engine::Krunvm) | None => boot_krunvm(app),
        Some(eng) => boot_container(app, eng),
    }
}

/// docker/podman boot: pull (streamed), replace any previous container, run
/// detached with the standard port/volume/env contract. The image entrypoint
/// is the release start — no eval dance needed under a real container engine.
fn boot_container(app: &AppHandle, eng: Engine) -> Result<(), String> {
    let cli = eng.cli();
    let data = data_dir().ok_or("no data dir")?;
    let disco = disco_dir().ok_or("no disco dir")?;
    std::fs::create_dir_all(&data).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&disco).map_err(|e| e.to_string())?;

    let img = image();
    emit_setup(app, &format!("Pulling the engine image with {cli} (first run is slow once)…"));
    stream(cli, &["pull", &img], app)?;

    emit_setup(app, "Stopping any previous engine instance…");
    let _ = sh(cli, &["rm", "-f", VM]);
    // A stale host-port squatter (an old krunvm zombie, our own vfkit proxy)
    // blocks the bind.
    stop_proxy();
    kill_port_squatters();

    emit_setup(app, "Booting the engine…");
    let port_map = format!("{HOST_PORT}:{GUEST_PORT}");
    let data_vol = format!("{}:/data", data.display());
    let disco_vol = format!("{}:/disco", disco.display());
    sh_ok(
        cli,
        &[
            "run", "-d",
            "--name", VM,
            "--restart", "unless-stopped",
            "-p", &port_map,
            "-v", &data_vol,
            "-v", &disco_vol,
            "-e", "WB_DESKTOP=1",
            "-e", "WB_DESKTOP_DIR=/disco",
            "-e", "WB_DATA=/data",
            "-e", "WB_EMBED=local",
            &img,
        ],
    )
    .map(|_| ())
    .map_err(|e| format!("{cli} run failed: {e}"))
}

/// krunvm boot (fallback path): ensure the APFS volume, tear down any previous
/// instance, (re)create the VM, spawn it detached.
fn boot_krunvm(app: &AppHandle) -> Result<(), String> {
    emit_setup(app, "Preparing the krunvm volume…");
    ensure_apfs_volume()?;
    // A previous instance still holding the VM lock makes `krunvm start`
    // fail with "Couldn't acquire lock file" — and retries used to strand
    // one zombie process per attempt (pidfile only knew the latest). Kill
    // by pattern, then by pidfile, then delete the VM definition.
    emit_setup(app, "Stopping any previous engine instance…");
    let _ = sh("pkill", &["-f", &format!("krunvm start {VM}")]);
    let _ = down();
    std::thread::sleep(std::time::Duration::from_millis(300));
    emit_setup(app, "Creating the microVM (first run pulls the engine image — this is slow once)…");
    create(app)?;
    emit_setup(app, "Booting the engine…");
    spawn()?;
    Ok(())
}

// ---- vfkit lane ---------------------------------------------------------------

struct VfkitAssets {
    kernel: PathBuf,
    initrd: PathBuf,
    disk: PathBuf,
}

/// Locate or materialize the boot assets. kernel/initramfs are read-only and
/// usable from any bundle dir; the disk must be WRITABLE, so it always ends
/// up in the app-support engine dir — copied out of a sealed Resources bundle
/// or downloaded (zstd) from the engine-disk artifact.
fn ensure_bundle(app: &AppHandle) -> Result<VfkitAssets, String> {
    let dl = engine_dir().ok_or("no engine dir")?;
    std::fs::create_dir_all(&dl).map_err(|e| e.to_string())?;

    let ro = |name: &str| -> Result<PathBuf, String> {
        if let Some(p) = find_asset(name) {
            return Ok(p);
        }
        let dest = dl.join(name);
        emit_setup(app, &format!("Downloading engine {name}…"));
        fetch_artifact_file(app, name, &dest)?;
        Ok(dest)
    };
    let kernel = ro(ASSET_KERNEL)?;
    let initrd = ro(ASSET_INITRD)?;

    let disk = dl.join(ASSET_DISK);
    if !disk.is_file() {
        // A bundled (read-only) disk seeds the writable copy; else download.
        if let Some(seed) = find_asset(ASSET_DISK).filter(|p| p != &disk) {
            emit_setup(app, "Copying the bundled engine disk…");
            std::fs::copy(&seed, &disk).map_err(|e| e.to_string())?;
        } else {
            let zst = dl.join(ASSET_DISK_ZST);
            emit_setup(app, "Downloading the engine disk (first run is slow once)…");
            fetch_artifact_file(app, ASSET_DISK_ZST, &zst)?;
            emit_setup(app, "Unpacking the engine disk…");
            unzstd(&zst, &disk)?;
            let _ = std::fs::remove_file(&zst);
        }
    }
    // Terminal pull event so the progress bar can complete/clear.
    let _ = app.emit("engine-pull", serde_json::json!({ "done": 0, "total": null }));
    Ok(VfkitAssets { kernel, initrd, disk })
}

/// Pull one named file (layer title) out of the ghcr engine-disk OCI artifact,
/// streaming `engine-pull` progress. Anonymous pull — the artifact is public.
fn fetch_artifact_file(app: &AppHandle, title: &str, dest: &Path) -> Result<(), String> {
    let img = engine_disk_ref();
    let rest = img
        .strip_prefix("ghcr.io/")
        .ok_or("engine-disk artifact must live on ghcr.io")?;
    let (repo, tag) = rest.rsplit_once(':').unwrap_or((rest, "latest"));
    // No total timeout — the disk is hundreds of MB on slow links.
    let client = reqwest::blocking::Client::builder()
        .connect_timeout(std::time::Duration::from_secs(10))
        .timeout(None)
        .build()
        .map_err(|e| e.to_string())?;
    let tok: serde_json::Value = client
        .get(format!("https://ghcr.io/token?scope=repository:{repo}:pull"))
        .send()
        .map_err(|e| format!("ghcr token: {e}"))?
        .json()
        .map_err(|e| e.to_string())?;
    let tok = tok["token"].as_str().ok_or("no ghcr token")?;
    let man: serde_json::Value = client
        .get(format!("https://ghcr.io/v2/{repo}/manifests/{tag}"))
        .bearer_auth(tok)
        .header("Accept", "application/vnd.oci.image.manifest.v1+json")
        .send()
        .map_err(|e| format!("ghcr manifest: {e}"))?
        .json()
        .map_err(|e| e.to_string())?;
    let layer = man["layers"]
        .as_array()
        .and_then(|ls| {
            ls.iter()
                .find(|l| l["annotations"]["org.opencontainers.image.title"] == title)
        })
        .ok_or(format!("no `{title}` layer in {img}"))?;
    let digest = layer["digest"].as_str().ok_or("layer without digest")?;
    let total = layer["size"].as_u64();

    let mut resp = client
        .get(format!("https://ghcr.io/v2/{repo}/blobs/{digest}"))
        .bearer_auth(tok)
        .send()
        .map_err(|e| format!("ghcr blob: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("ghcr blob {digest}: HTTP {}", resp.status()));
    }
    let part = dest.with_extension("part");
    let mut out = std::fs::File::create(&part).map_err(|e| e.to_string())?;
    let mut buf = vec![0u8; 1 << 20];
    let (mut done, mut last) = (0u64, 0u64);
    loop {
        let n = resp.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
        done += n as u64;
        if done - last >= (8 << 20) {
            last = done;
            let _ = app.emit("engine-pull", serde_json::json!({ "done": done, "total": total }));
        }
    }
    std::fs::rename(&part, dest).map_err(|e| e.to_string())
}

fn unzstd(src: &Path, dst: &Path) -> Result<(), String> {
    let f = std::fs::File::open(src).map_err(|e| e.to_string())?;
    let mut dec = zstd::stream::read::Decoder::new(f).map_err(|e| e.to_string())?;
    let part = dst.with_extension("part");
    let mut out = std::fs::File::create(&part).map_err(|e| e.to_string())?;
    std::io::copy(&mut dec, &mut out).map_err(|e| e.to_string())?;
    std::fs::rename(&part, dst).map_err(|e| e.to_string())
}

/// vfkit boot: ensure the bundle, launch the VM with the spike's exact device
/// set (virtio-blk root, NAT net, rng, the disco dir as the ONLY virtio-fs
/// share, console to a log), resolve the guest IP from the macOS DHCP lease
/// db, then keep the app's localhost contract via the loopback proxy. The
/// guest's wb-init (baked into the disk) does the env + discovery writing.
fn boot_vfkit(app: &AppHandle) -> Result<(), String> {
    // Download the official signed vfkit if it's neither bundled nor on PATH —
    // so a fresh mac boots without Homebrew or a codesigned app bundle.
    let bin = ensure_vfkit_bin(app)?;
    emit_setup(app, "Preparing the engine bundle…");
    let assets = ensure_bundle(app)?;

    emit_setup(app, "Stopping any previous engine instance…");
    vfkit_down();

    let disco = disco_dir().ok_or("no disco dir")?;
    let logs = log_dir().ok_or("no log dir")?;
    std::fs::create_dir_all(&disco).map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&logs).map_err(|e| e.to_string())?;
    // /data lives on the rootfs disk in phase 1 — see wb-hhf.2 for the
    // second-disk plan that makes engine updates a disk.img swap.

    emit_setup(app, "Booting the engine VM…");
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(logs.join("vfkit.log"))
        .map_err(|e| e.to_string())?;
    let console = logs.join("vfkit-console.log");
    let child = Command::new(&bin)
        .args([
            "--cpus", "2",
            "--memory", "2048",
            "--kernel", &assets.kernel.display().to_string(),
            "--initrd", &assets.initrd.display().to_string(),
            "--kernel-cmdline", VFKIT_CMDLINE,
            "--device", &format!("virtio-blk,path={}", assets.disk.display()),
            "--device", &format!("virtio-net,nat,mac={VFKIT_MAC}"),
            "--device", "virtio-rng",
            "--device", &format!("virtio-fs,sharedDir={},mountTag=disco", disco.display()),
            "--device", &format!("virtio-serial,logFilePath={}", console.display()),
        ])
        .stdin(Stdio::null())
        .stdout(log.try_clone().map_err(|e| e.to_string())?)
        .stderr(log)
        .spawn()
        .map_err(|e| format!("could not launch vfkit: {e}"))?;
    let pid = child.id();
    if let Some(p) = vfkit_pidfile() {
        let _ = std::fs::write(p, pid.to_string());
    }

    emit_setup(app, "Waiting for the VM's network lease…");
    let ip = wait_guest_ip(pid, 60)?;
    emit_setup(app, &format!("Engine VM up at {ip} — proxying 127.0.0.1:{HOST_PORT}"));
    spawn_proxy(&ip)
}

/// Poll /var/db/dhcpd_leases (macOS bootpd, world-readable) for our MAC; the
/// lease lands within ~1s of VM launch. Errs early if vfkit itself died.
fn wait_guest_ip(pid: u32, secs: u32) -> Result<String, String> {
    for _ in 0..(secs * 2) {
        if !pid_alive(pid) {
            return Err("vfkit exited during boot — see logs/vfkit.log + vfkit-console.log".into());
        }
        if let Ok(leases) = std::fs::read_to_string("/var/db/dhcpd_leases") {
            if let Some(ip) = lease_ip(&leases, VFKIT_MAC) {
                return Ok(ip);
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(500));
    }
    Err(format!("no DHCP lease for the engine VM after {secs}s"))
}

fn pid_alive(pid: u32) -> bool {
    sh("kill", &["-0", &pid.to_string()]).is_ok()
}

/// Find the IP leased to `mac` in dhcpd_leases. Blocks look like
/// `{\n\tname=…\n\tip_address=…\n\thw_address=1,<mac>\n…}` — field order is
/// not guaranteed, and bootpd STRIPS LEADING ZEROS from each MAC octet, so
/// both sides are normalized before comparing.
fn lease_ip(leases: &str, mac: &str) -> Option<String> {
    let want = normalize_mac(mac);
    let (mut ip, mut hit) = (None::<String>, false);
    for raw in leases.lines() {
        let line = raw.trim();
        if line.starts_with('{') {
            ip = None;
            hit = false;
        } else if line.starts_with('}') {
            if hit && ip.is_some() {
                return ip;
            }
        } else if let Some(v) = line.strip_prefix("ip_address=") {
            ip = Some(v.trim().to_string());
        } else if let Some(v) = line.strip_prefix("hw_address=") {
            // value carries a type prefix: "1,5a:94:ef:e4:1c:ee"
            let hw = v.split_once(',').map_or(v, |(_, m)| m);
            hit = normalize_mac(hw) == want;
        }
    }
    if hit { ip } else { None }
}

/// Lowercase, strip leading zeros per octet ("0a" → "a", "00" → "0").
fn normalize_mac(mac: &str) -> String {
    mac.trim()
        .to_ascii_lowercase()
        .split(':')
        .map(|o| {
            let t = o.trim_start_matches('0');
            if t.is_empty() { "0" } else { t }.to_string()
        })
        .collect::<Vec<_>>()
        .join(":")
}

// ---- loopback proxy -----------------------------------------------------------

/// Stop handle for the live proxy accept-loop (one VM at a time).
static PROXY: Mutex<Option<Arc<AtomicBool>>> = Mutex::new(None);

/// 127.0.0.1:4000 → guest:4000. The vfkit guest only has a NAT ip, but
/// discovery defaults to 127.0.0.1 and the whole app trusts it — so the
/// localhost contract is kept here instead of leaking guest IPs upward.
/// Plain threads + io::copy: one VM, a handful of concurrent connections.
fn spawn_proxy(guest_ip: &str) -> Result<(), String> {
    stop_proxy();
    let guest: std::net::SocketAddr = format!("{guest_ip}:{GUEST_PORT}")
        .parse()
        .map_err(|e| format!("bad guest address: {e}"))?;
    // Loopback ONLY — never expose the engine on external interfaces.
    let listener = std::net::TcpListener::bind(("127.0.0.1", HOST_PORT))
        .map_err(|e| format!("proxy bind 127.0.0.1:{HOST_PORT}: {e}"))?;
    let stop = Arc::new(AtomicBool::new(false));
    *PROXY.lock().unwrap() = Some(stop.clone());
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let Ok(client) = conn else { continue };
            std::thread::spawn(move || proxy_conn(client, guest));
        }
    });
    Ok(())
}

fn proxy_conn(client: std::net::TcpStream, guest: std::net::SocketAddr) {
    let Ok(server) = std::net::TcpStream::connect_timeout(&guest, std::time::Duration::from_secs(3))
    else {
        return;
    };
    let (Ok(mut c_rd), Ok(mut s_rd)) = (client.try_clone(), server.try_clone()) else {
        return;
    };
    let (mut c_wr, mut s_wr) = (client, server);
    let up = std::thread::spawn(move || {
        let _ = std::io::copy(&mut c_rd, &mut s_wr);
        let _ = s_wr.shutdown(std::net::Shutdown::Write);
    });
    let _ = std::io::copy(&mut s_rd, &mut c_wr);
    let _ = c_wr.shutdown(std::net::Shutdown::Write);
    let _ = up.join();
}

/// Set the stop flag, then poke the listener so the blocking accept() returns
/// and the loop drops it (freeing the port).
fn stop_proxy() {
    let flag = PROXY.lock().unwrap().take();
    if let Some(flag) = flag {
        flag.store(true, Ordering::Relaxed);
        let _ = std::net::TcpStream::connect_timeout(
            &std::net::SocketAddr::from(([127, 0, 0, 1], HOST_PORT)),
            std::time::Duration::from_millis(200),
        );
    }
}

/// Kill the vfkit VM (pidfile pattern) + the loopback proxy. SIGTERM tears
/// the VM down cleanly (spike-verified).
fn vfkit_down() {
    stop_proxy();
    if let Some(p) = vfkit_pidfile() {
        if let Some(pid) = std::fs::read_to_string(&p)
            .ok()
            .and_then(|s| s.trim().parse::<u32>().ok())
        {
            let _ = sh("kill", &[&pid.to_string()]);
        }
        let _ = std::fs::remove_file(p);
    }
}

/// Free the host port from stale squatters — but NEVER kill ourselves: the
/// vfkit lane's loopback proxy (and its client sockets to guest:4000) live in
/// THIS process, and a blanket `lsof | xargs kill` would shoot the app.
fn kill_port_squatters() {
    let me = std::process::id().to_string();
    if let Ok(out) = sh("lsof", &["-ti", &format!(":{HOST_PORT}")]) {
        for pid in out.split_whitespace().filter(|p| *p != me) {
            let _ = sh("kill", &[pid]);
        }
    }
}

/// Tear down the local runtime on EVERY engine (cheap no-ops where absent):
/// remove the named container, kill any spawned microVM or vfkit VM, delete
/// the VM definition, and free the host port. Image stores stay intact.
pub fn down() -> Result<(), String> {
    for cli in ["docker", "podman"] {
        let _ = sh(cli, &["rm", "-f", VM]);
    }
    if let Some(pid) = read_pidfile() {
        let _ = sh("kill", &[&pid.to_string()]);
    }
    if let Some(p) = pidfile() {
        let _ = std::fs::remove_file(p);
    }
    vfkit_down();
    let _ = sh("krunvm", &["delete", VM]);
    kill_port_squatters();
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

    const LEASES: &str = "{\n\tname=other\n\tip_address=192.168.64.7\n\thw_address=1,aa:bb:cc:dd:ee:ff\n\tlease=0x12345\n}\n{\n\tname=workbooks\n\thw_address=1,5a:94:ef:e4:1c:ee\n\tip_address=192.168.64.2\n\tlease=0x99999\n}\n";

    #[test]
    fn lease_ip_matches_regardless_of_field_order() {
        // Second block lists hw_address BEFORE ip_address.
        assert_eq!(
            lease_ip(LEASES, "5a:94:ef:e4:1c:ee").as_deref(),
            Some("192.168.64.2")
        );
        assert_eq!(
            lease_ip(LEASES, "aa:bb:cc:dd:ee:ff").as_deref(),
            Some("192.168.64.7")
        );
    }

    #[test]
    fn lease_ip_none_when_absent() {
        assert_eq!(lease_ip(LEASES, "12:34:56:78:9a:bc"), None);
        assert_eq!(lease_ip("", "5a:94:ef:e4:1c:ee"), None);
    }

    #[test]
    fn lease_ip_normalizes_leading_zero_octets() {
        // bootpd writes "a:1e:5:0:1c:ee" for MAC 0a:1e:05:00:1c:ee.
        let leases = "{\n\tip_address=192.168.64.9\n\thw_address=1,a:1e:5:0:1c:ee\n}\n";
        assert_eq!(
            lease_ip(leases, "0a:1e:05:00:1c:ee").as_deref(),
            Some("192.168.64.9")
        );
    }

    #[test]
    fn normalize_mac_strips_per_octet_zeros() {
        assert_eq!(normalize_mac("0A:1E:05:00:1C:EE"), "a:1e:5:0:1c:ee");
        assert_eq!(normalize_mac("5a:94:ef:e4:1c:ee"), "5a:94:ef:e4:1c:ee");
    }

    #[test]
    fn bundle_candidates_orders_override_resources_support() {
        let dirs = bundle_candidates(
            Some("/custom/engine"),
            Some(Path::new("/Applications/Workbooks.app/Contents/MacOS/workbooks-desktop")),
            Some(Path::new("/Users/u/Library/Application Support/sh.workbooks")),
        );
        assert_eq!(
            dirs,
            vec![
                PathBuf::from("/custom/engine"),
                PathBuf::from("/Applications/Workbooks.app/Contents/Resources/engine"),
                PathBuf::from("/Users/u/Library/Application Support/sh.workbooks/engine"),
            ]
        );
    }

    #[test]
    fn bundle_candidates_tolerates_missing_parts() {
        assert!(bundle_candidates(None, None, None).is_empty());
        let dirs = bundle_candidates(None, None, Some(Path::new("/sup")));
        assert_eq!(dirs, vec![PathBuf::from("/sup/engine")]);
    }

    #[test]
    fn find_in_resolves_first_dir_with_the_file() {
        let tmp = std::env::temp_dir().join(format!("wb-machine-test-{}", std::process::id()));
        let (a, b) = (tmp.join("a"), tmp.join("b"));
        std::fs::create_dir_all(&a).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        std::fs::write(b.join(ASSET_KERNEL), b"k").unwrap();
        let dirs = vec![a.clone(), b.clone()];
        assert_eq!(find_in(&dirs, ASSET_KERNEL), Some(b.join(ASSET_KERNEL)));
        assert_eq!(find_in(&dirs, ASSET_DISK), None);
        // First dir wins once it has the file too.
        std::fs::write(a.join(ASSET_KERNEL), b"k").unwrap();
        assert_eq!(find_in(&dirs, ASSET_KERNEL), Some(a.join(ASSET_KERNEL)));
        let _ = std::fs::remove_dir_all(&tmp);
    }
}
