//! `wb deploy` — the bootstrap verb.
//!
//! Special because it must run with NO runtime up: it's what *brings the runtime
//! up*. It reads `deployment.org`, picks a target (`local` container engine, or
//! `fly`), and converges via `io.spawn`. Native-only — process spawn isn't
//! available in the wasm sandbox.
//!
//! Local convergence runs the published runtime image (the ONE image, see
//! deploy/Dockerfile.runtime) with the discovery dir mounted, so `wb rt` and the
//! desktop app find + authenticate to it immediately.

use crate::io::Io;
use crate::util::{self, org_keywords};
use anyhow::{bail, Context, Result};
use clap::Subcommand;
use std::collections::BTreeMap;

#[derive(Subcommand)]
pub enum DeployVerb {
    /// Scaffold ./deployment.org (local | cloud)
    Init {
        #[arg(default_value = "local")]
        preset: String,
    },
    /// Coherence check on deployment.org
    Validate,
    /// Converge to the declared state (local container or cloud provider)
    Apply,
    /// Inspect the live deployment
    Status,
    /// Tear it down
    Down,
    /// Shorthand: scaffold local config if absent, then apply
    Local,
    /// Local container engine doctor (krunvm | podman | docker present?)
    Doctor,
}

const FILE: &str = "deployment.org";
const DEFAULT_IMAGE: &str = "ghcr.io/workbooks-sh/runtime:latest";

pub fn run(io: &dyn Io, verb: DeployVerb) -> Result<String> {
    match verb {
        DeployVerb::Init { preset } => init(io, &preset),
        DeployVerb::Validate => validate(io).map(|c| format!("ok — {} ({})", FILE, c.summary())),
        DeployVerb::Apply => apply(io),
        DeployVerb::Status => status(io),
        DeployVerb::Down => down(io),
        DeployVerb::Local => {
            if io.read(FILE).is_err() {
                init(io, "local")?;
            }
            apply(io)
        }
        DeployVerb::Doctor => doctor(io),
    }
}

struct Config(BTreeMap<String, String>);

impl Config {
    fn target(&self) -> &str {
        self.0.get("DEPLOY_TARGET").or_else(|| self.0.get("PLACE")).map(String::as_str).unwrap_or("local")
    }
    fn app(&self) -> &str {
        self.0.get("DEPLOY_APP").or_else(|| self.0.get("APP")).map(String::as_str).unwrap_or("workbooks")
    }
    fn region(&self) -> &str {
        self.0.get("DEPLOY_REGION").map(String::as_str).unwrap_or("sjc")
    }
    fn image(&self) -> String {
        std::env::var("WB_IMAGE")
            .ok()
            .or_else(|| self.0.get("DEPLOY_IMAGE").cloned())
            .unwrap_or_else(|| DEFAULT_IMAGE.into())
    }
    fn port(&self) -> String {
        self.0.get("DEPLOY_PORT").cloned().unwrap_or_else(|| "4000".into())
    }
    fn summary(&self) -> String {
        format!("target={} app={} image={} port={}", self.target(), self.app(), self.image(), self.port())
    }
}

fn load(io: &dyn Io) -> Result<Config> {
    let raw = io.read(FILE).with_context(|| format!("no {FILE} here — run `wb deploy init` first"))?;
    Ok(Config(org_keywords(&String::from_utf8(raw)?)))
}

fn validate(io: &dyn Io) -> Result<Config> {
    let cfg = load(io)?;
    match cfg.target() {
        "local" | "fly" | "cloud" => Ok(cfg),
        other => bail!("unknown DEPLOY_TARGET `{other}` (want: local | fly)"),
    }
}

fn init(io: &dyn Io, preset: &str) -> Result<String> {
    let body = match preset {
        "cloud" | "fly" => TEMPLATE_FLY,
        _ => TEMPLATE_LOCAL,
    };
    io.write(FILE, body.as_bytes())?;
    Ok(format!("wrote {FILE} ({preset}) — edit it, then `wb deploy apply`"))
}

/// Container engines, in automation-friendliness order. krunvm is the mac-first
/// microVM seam but its `start` is foreground; docker/podman detach cleanly.
fn engine(io: &dyn Io) -> Option<&'static str> {
    ["docker", "podman", "krunvm"].into_iter().find(|t| io.spawn(t, &["--version"]).is_ok())
}

fn apply(io: &dyn Io) -> Result<String> {
    let cfg = validate(io)?;
    match cfg.target() {
        "local" => {
            let (app, image, port) = (cfg.app(), cfg.image(), cfg.port());
            let disco = util::app_dir().join("disco");
            std::fs::create_dir_all(&disco).ok();
            let disco_mount = format!("{}:/disco", disco.to_string_lossy());
            let port_map = format!("{port}:{port}");
            let port_env = format!("PORT={port}");

            match engine(io) {
                Some(eng @ ("docker" | "podman")) => {
                    io.spawn(eng, &["pull", &image]).context("image pull failed (is it published? override with WB_IMAGE)")?;
                    let _ = io.spawn(eng, &["rm", "-f", app]); // idempotent re-apply
                    io.spawn(eng, &[
                        "run", "-d", "--name", app,
                        "-p", &port_map,
                        "-e", "WB_WEB=1", "-e", "WB_DESKTOP=1",
                        "-e", &port_env, "-e", "WB_DESKTOP_DIR=/disco",
                        "-v", &disco_mount,
                        &image,
                    ])?;
                    Ok(format!(
                        "engine up — {eng} container `{app}` on port {port} ({image})\ndiscovery → {}/runtime.json · try `wb rt status`",
                        disco.to_string_lossy()
                    ))
                }
                Some("krunvm") => {
                    let vcpus = "2";
                    let _ = io.spawn("krunvm", &["delete", app]);
                    io.spawn("krunvm", &[
                        "create", &image, "--name", app,
                        "--cpus", vcpus, "--mem", "2048",
                        "--port", &port_map,
                        "--volume", &disco_mount,
                    ])?;
                    Ok(format!(
                        "microVM `{app}` created from {image}.\nkrunvm runs foreground — start it with:  krunvm start {app}\n(then `wb rt status` from another shell)"
                    ))
                }
                _ => bail!("no container engine (docker/podman/krunvm) — install one, or use `wb deploy init cloud`"),
            }
        }
        "fly" | "cloud" => {
            io.spawn("fly", &["version"]).context("fly CLI not found — `brew install flyctl`")?;
            let (app, image, region) = (cfg.app(), cfg.image(), cfg.region());
            // ensure the app exists (tolerate already-exists), then deploy the image
            let _ = io.spawn("fly", &["apps", "create", app]);
            io.spawn("fly", &["deploy", "-a", app, "--image", &image, "--regions", region, "--yes"])?;
            Ok(format!("engine up — https://{app}.fly.dev ({image}, {region})"))
        }
        other => bail!("unknown target {other}"),
    }
}

fn status(io: &dyn Io) -> Result<String> {
    let cfg = load(io)?;
    match cfg.target() {
        "fly" | "cloud" => io.spawn("fly", &["status", "-a", cfg.app()]),
        _ => match engine(io) {
            Some(eng @ ("docker" | "podman")) => {
                let filter = format!("name={}", cfg.app());
                io.spawn(eng, &["ps", "-a", "--filter", &filter, "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"])
            }
            Some("krunvm") => io.spawn("krunvm", &["list"]),
            _ => bail!("no container engine found"),
        },
    }
}

fn down(io: &dyn Io) -> Result<String> {
    let cfg = load(io)?;
    match cfg.target() {
        "fly" | "cloud" => io.spawn("fly", &["apps", "destroy", cfg.app(), "-y"]),
        _ => match engine(io) {
            Some(eng @ ("docker" | "podman")) => {
                io.spawn(eng, &["rm", "-f", cfg.app()])?;
                Ok(format!("removed container `{}`", cfg.app()))
            }
            Some("krunvm") => {
                io.spawn("krunvm", &["delete", cfg.app()])?;
                Ok(format!("deleted microVM `{}`", cfg.app()))
            }
            _ => bail!("no container engine found"),
        },
    }
}

fn doctor(io: &dyn Io) -> Result<String> {
    let mut lines = vec!["deploy doctor:".to_string()];
    for tool in ["krunvm", "podman", "docker", "fly"] {
        let ok = io.spawn(tool, &["--version"]).map(|v| v.lines().next().unwrap_or("").to_string());
        lines.push(match ok {
            Ok(v) => format!("  ✓ {tool}: {}", v.trim()),
            Err(_) => format!("  ✗ {tool}: not found"),
        });
    }
    Ok(lines.join("\n"))
}

const TEMPLATE_LOCAL: &str = "\
#+TITLE: Workbooks deployment
#+DEPLOY_TARGET: local
#+DEPLOY_APP: workbooks
#+DEPLOY_PORT: 4000
# DEPLOY_IMAGE defaults to ghcr.io/workbooks-sh/runtime:latest (env WB_IMAGE overrides).
# Local = the runtime image in a docker/podman container (or krunvm microVM).
# `wb deploy apply` converges it; `wb rt status` talks to it.
";

const TEMPLATE_FLY: &str = "\
#+TITLE: Workbooks deployment
#+DEPLOY_TARGET: fly
#+DEPLOY_APP: my-workbooks-engine
#+DEPLOY_REGION: sjc
#+DEPLOY_PORT: 4000
# DEPLOY_IMAGE defaults to ghcr.io/workbooks-sh/runtime:latest (env WB_IMAGE overrides).
# Cloud = the same runtime image deployed to Fly.
# Set provider secrets with `fly secrets set ...` (see deploy/storage.env.example).
";
