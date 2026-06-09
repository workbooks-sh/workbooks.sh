//! `wb deploy` — the bootstrap verb.
//!
//! Special because it must run with NO runtime up: it's what *brings the runtime
//! up*. It reads `deployment.org` and converges via `io.spawn`. Native-only.
//!
//! PROVIDER-AGNOSTIC by construction:
//!   * `local`  — container-engine seam (docker | podman | krunvm), built in.
//!   * anything else — a RECIPE: `providers/<place>/bootstrap.sh` filling the
//!     neutral spine's hooks (`_recipe.sh`). fly is just the recipe we bundle
//!     (personal preference, not privileged). Adding a provider = dropping a
//!     bootstrap.sh — no recompile.
//!
//! Recipes resolve from: $WB_PROVIDERS_DIR → ./cli/deploy-kit/providers (repo
//! dev, walking up) → recipes EMBEDDED in this binary, materialized under the
//! app dir (standalone installs).
//!
//! SECRETS are kit-abstracted: declared by NAME in deployment.org
//! (`#+DEPLOY_SECRETS: KEY …`), values managed via `wb deploy secrets`, stored
//! 0600 under the app dir, delivered per provider (env-file locally; staged
//! through the recipe's `provider_set_secrets` hook in the cloud). Values never
//! enter deployment.org or images.

use crate::io::Io;
use crate::util::{self, org_keywords};
use anyhow::{bail, Context, Result};
use clap::Subcommand;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Subcommand)]
pub enum DeployVerb {
    /// Scaffold ./deployment.org (local | cloud)
    Init {
        #[arg(default_value = "local")]
        preset: String,
    },
    /// Coherence check on deployment.org (incl. declared secrets)
    Validate,
    /// Converge to the declared state (local container or provider recipe)
    Apply,
    /// Inspect the live deployment
    Status,
    /// Tail the live deployment's logs
    Logs,
    /// Tear it down
    Down,
    /// Shorthand: scaffold local config if absent, then apply
    Local,
    /// Engines, recipes, and declared secrets — what's present, what's missing
    Doctor,
    /// Manage deployment secrets (kit-abstracted, provider-delivered)
    Secrets {
        #[command(subcommand)]
        verb: SecretsVerb,
    },
}

#[derive(Subcommand)]
pub enum SecretsVerb {
    /// Set KEY=VALUE pairs (or --from-env <file>)
    Set {
        pairs: Vec<String>,
        #[arg(long)]
        from_env: Option<String>,
    },
    /// List secret NAMES (never values)
    List,
    /// Remove a secret by name
    Unset { key: String },
    /// Push staged secrets to the configured provider without a deploy
    Push,
}

const FILE: &str = "deployment.org";
const DEFAULT_IMAGE: &str = "ghcr.io/workbooks-sh/runtime:latest";

// Bundled recipes — the binary is self-contained outside the repo.
const RECIPE_SPINE: &str = include_str!("../../deploy-kit/providers/_recipe.sh");
const RECIPE_FLY: &str = include_str!("../../deploy-kit/providers/fly/bootstrap.sh");

pub fn run(io: &dyn Io, verb: DeployVerb) -> Result<String> {
    match verb {
        DeployVerb::Init { preset } => init(io, &preset),
        DeployVerb::Validate => {
            let cfg = validate(io)?;
            let missing = missing_secrets(io, &cfg);
            let mut out = format!("ok — {} ({})", FILE, cfg.summary());
            if !missing.is_empty() {
                out += &format!(
                    "\nwarn — declared secrets unset: {} (wb deploy secrets set …)",
                    missing.join(", ")
                );
            }
            Ok(out)
        }
        DeployVerb::Apply => apply(io),
        DeployVerb::Status => lifecycle(io, "status"),
        DeployVerb::Logs => lifecycle(io, "logs"),
        DeployVerb::Down => lifecycle(io, "down"),
        DeployVerb::Local => {
            if io.read(FILE).is_err() {
                init(io, "local")?;
            }
            apply(io)
        }
        DeployVerb::Doctor => doctor(io),
        DeployVerb::Secrets { verb } => secrets(io, verb),
    }
}

// ── config ──────────────────────────────────────────────────────────────────

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
    /// Secret NAMES the deployment declares it needs (values live elsewhere).
    fn declared_secrets(&self) -> Vec<String> {
        self.0
            .get("DEPLOY_SECRETS")
            .map(|s| s.split_whitespace().map(str::to_string).collect())
            .unwrap_or_default()
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
    let t = cfg.target();
    if t != "local" && resolve_recipe(io, t).is_none() {
        bail!("no provider recipe for `{t}` — expected providers/{t}/bootstrap.sh (WB_PROVIDERS_DIR, repo, or bundled)");
    }
    Ok(cfg)
}

fn init(io: &dyn Io, preset: &str) -> Result<String> {
    let body = match preset {
        "cloud" | "fly" => TEMPLATE_FLY,
        _ => TEMPLATE_LOCAL,
    };
    io.write(FILE, body.as_bytes())?;
    Ok(format!("wrote {FILE} ({preset}) — edit it, then `wb deploy apply`"))
}

// ── secrets (kit-abstracted) ─────────────────────────────────────────────────

fn secrets_path() -> PathBuf {
    util::app_dir().join("secrets.env")
}

fn secrets_load(io: &dyn Io) -> BTreeMap<String, String> {
    io.read(&secrets_path().to_string_lossy())
        .ok()
        .map(|b| {
            String::from_utf8_lossy(&b)
                .lines()
                .filter_map(|l| l.split_once('=').map(|(k, v)| (k.trim().to_string(), v.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

fn secrets_save(io: &dyn Io, map: &BTreeMap<String, String>) -> Result<()> {
    let body: String = map.iter().map(|(k, v)| format!("{k}={v}\n")).collect();
    let path = secrets_path();
    io.write(&path.to_string_lossy(), body.as_bytes())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
    }
    Ok(())
}

fn missing_secrets(io: &dyn Io, cfg: &Config) -> Vec<String> {
    let have = secrets_load(io);
    cfg.declared_secrets()
        .into_iter()
        .filter(|k| !have.contains_key(k) && std::env::var(k).is_err())
        .collect()
}

fn secrets(io: &dyn Io, verb: SecretsVerb) -> Result<String> {
    match verb {
        SecretsVerb::Set { pairs, from_env } => {
            let mut map = secrets_load(io);
            let mut n = 0;
            if let Some(f) = from_env {
                for line in String::from_utf8(io.read(&f)?)?.lines() {
                    let l = line.trim();
                    if l.is_empty() || l.starts_with('#') {
                        continue;
                    }
                    if let Some((k, v)) = l.split_once('=') {
                        map.insert(k.trim().to_string(), v.to_string());
                        n += 1;
                    }
                }
            }
            for p in &pairs {
                let (k, v) = p.split_once('=').with_context(|| format!("expected KEY=VALUE, got {p}"))?;
                map.insert(k.to_string(), v.to_string());
                n += 1;
            }
            if n == 0 {
                bail!("usage: wb deploy secrets set KEY=VALUE … | --from-env <file>");
            }
            secrets_save(io, &map)?;
            Ok(format!("staged {n} secret(s) ({}) — applied on next `wb deploy apply` (or `secrets push`)", secrets_path().display()))
        }
        SecretsVerb::List => {
            let map = secrets_load(io);
            if map.is_empty() {
                return Ok("(no secrets staged)".into());
            }
            Ok(map.keys().cloned().collect::<Vec<_>>().join("\n"))
        }
        SecretsVerb::Unset { key } => {
            let mut map = secrets_load(io);
            if map.remove(&key).is_none() {
                bail!("no such secret: {key}");
            }
            secrets_save(io, &map)?;
            Ok(format!("unset {key}"))
        }
        SecretsVerb::Push => {
            let cfg = validate(io)?;
            match cfg.target() {
                "local" => Ok("local secrets apply at container start — run `wb deploy apply`".into()),
                place => recipe_action(io, &cfg, place, "secrets"),
            }
        }
    }
}

// ── recipes (the provider seam) ──────────────────────────────────────────────

/// Resolve the providers dir: explicit env → repo (walk up) → bundled.
fn resolve_providers_dir(io: &dyn Io) -> PathBuf {
    if let Ok(d) = std::env::var("WB_PROVIDERS_DIR") {
        return PathBuf::from(d);
    }
    let mut dir = std::env::current_dir().unwrap_or_default();
    loop {
        let cand = dir.join("cli/deploy-kit/providers");
        if cand.join("_recipe.sh").is_file() {
            return cand;
        }
        if !dir.pop() {
            break;
        }
    }
    // standalone install: materialize the bundled recipes (kept fresh each run)
    let dest = util::app_dir().join("providers");
    let _ = io.write(&dest.join("_recipe.sh").to_string_lossy(), RECIPE_SPINE.as_bytes());
    let _ = io.write(&dest.join("fly/bootstrap.sh").to_string_lossy(), RECIPE_FLY.as_bytes());
    dest
}

fn resolve_recipe(io: &dyn Io, place: &str) -> Option<PathBuf> {
    let p = resolve_providers_dir(io).join(place).join("bootstrap.sh");
    p.is_file().then_some(p)
}

/// Spawn a provider recipe with the assembled env. The env is passed via
/// `env -i`-style explicit KEY=VAL args to `env`, so staged secrets reach the
/// hook without touching this process's environment.
fn recipe_action(io: &dyn Io, cfg: &Config, place: &str, action: &str) -> Result<String> {
    let recipe = resolve_recipe(io, place)
        .with_context(|| format!("no recipe for provider `{place}`"))?;
    let providers = resolve_providers_dir(io);

    let secrets = secrets_load(io);
    let secret_keys: Vec<String> = {
        let mut ks: Vec<String> = cfg.declared_secrets();
        for k in secrets.keys() {
            if !ks.contains(k) {
                ks.push(k.clone());
            }
        }
        ks
    };

    let mut envs: Vec<String> = vec![
        format!("PATH={}", std::env::var("PATH").unwrap_or_default()),
        format!("HOME={}", std::env::var("HOME").unwrap_or_default()),
        format!("WB_RECIPE_ACTION={action}"),
        format!("WB_PROVIDERS_DIR={}", providers.to_string_lossy()),
        format!("WB_IMAGE={}", cfg.image()),
        format!("WB_APP_NAME={}", cfg.app()),
        format!("WB_PORT={}", cfg.port()),
        format!("WB_REGION={}", cfg.region()),
        format!("WB_SECRET_KEYS={}", secret_keys.join(" ")),
    ];
    // forward credential VALUES: staged store first, deployer env as fallback
    for k in &secret_keys {
        if let Some(v) = secrets.get(k).cloned().or_else(|| std::env::var(k).ok()) {
            envs.push(format!("{k}={v}"));
        }
    }
    // passthrough overrides (our app-build path etc.)
    for k in ["WB_FLY_APP", "WB_FLY_CONFIG", "WB_FLY_DOCKERFILE", "WB_INCLUDE_CLIP", "WB_EMBED"] {
        if let Ok(v) = std::env::var(k) {
            envs.push(format!("{k}={v}"));
        }
    }

    let mut args: Vec<&str> = vec!["-i"];
    args.extend(envs.iter().map(String::as_str));
    args.push("bash");
    let recipe_s = recipe.to_string_lossy().to_string();
    args.push(&recipe_s);
    io.spawn("env", &args)
}

// ── converge ─────────────────────────────────────────────────────────────────

/// Container engines, in automation-friendliness order.
fn engine(io: &dyn Io) -> Option<&'static str> {
    ["docker", "podman", "krunvm"].into_iter().find(|t| io.spawn(t, &["--version"]).is_ok())
}

fn apply(io: &dyn Io) -> Result<String> {
    let cfg = validate(io)?;
    let missing = missing_secrets(io, &cfg);
    if !missing.is_empty() {
        bail!(
            "declared secrets unset: {} — `wb deploy secrets set KEY=VALUE` (or export them) first",
            missing.join(", ")
        );
    }
    match cfg.target() {
        "local" => apply_local(io, &cfg),
        place => {
            let out = recipe_action(io, &cfg, place, "up")?;
            // deployment.org: `#+DEPLOY_TOOLKITS: id:dir id:dir …` — the kit
            // ships the engine AND its toolkits. Write a toolkit, apply, done.
            let mut extra = String::new();
            if let Some(spec) = cfg.0.get("DEPLOY_TOOLKITS") {
                let url = recipe_action(io, &cfg, place, "url")?.trim().to_string();
                std::env::set_var("WB_ENGINE_URL", &url);
                for entry in spec.split_whitespace() {
                    if let Some((id, dir)) = entry.split_once(':') {
                        match crate::commands::toolkit_push(io, id, dir) {
                            Ok(msg) => extra.push_str(&format!("\ntoolkit {id}: {}", msg.trim())),
                            Err(e) => extra.push_str(&format!("\ntoolkit {id}: push FAILED — {e}")),
                        }
                    }
                }
                std::env::remove_var("WB_ENGINE_URL");
            }
            Ok(out + &extra)
        }
    }
}

fn apply_local(io: &dyn Io, cfg: &Config) -> Result<String> {
    let (app, image, port) = (cfg.app(), cfg.image(), cfg.port());
    let disco = util::app_dir().join("disco");
    let data = util::app_dir().join("data");
    std::fs::create_dir_all(&disco).ok();
    std::fs::create_dir_all(&data).ok();
    let disco_mount = format!("{}:/disco", disco.to_string_lossy());
    let data_mount = format!("{}:/data", data.to_string_lossy());
    let port_map = format!("{port}:{port}");
    let port_env = format!("PORT={port}");
    let secrets_file = secrets_path();
    let have_secrets = secrets_file.is_file();

    match engine(io) {
        Some(eng @ ("docker" | "podman")) => {
            io.spawn(eng, &["pull", &image]).context("image pull failed (is it published? override with WB_IMAGE)")?;
            let _ = io.spawn(eng, &["rm", "-f", app]); // idempotent re-apply
            let mut args: Vec<String> = vec![
                "run".into(), "-d".into(), "--name".into(), app.into(),
                "-p".into(), port_map,
                "-e".into(), "WB_WEB=1".into(), "-e".into(), "WB_DESKTOP=1".into(),
                "-e".into(), port_env, "-e".into(), "WB_DESKTOP_DIR=/disco".into(), "-e".into(), "WB_DATA=/data".into(),
                "-v".into(), disco_mount, "-v".into(), data_mount,
            ];
            if have_secrets {
                // kit-managed secrets delivered as the container's env, never baked
                args.push("--env-file".into());
                args.push(secrets_file.to_string_lossy().to_string());
            }
            args.push(image.clone());
            let argrefs: Vec<&str> = args.iter().map(String::as_str).collect();
            io.spawn(eng, &argrefs)?;
            Ok(format!(
                "engine up — {eng} container `{app}` on port {port} ({image}{})\ndiscovery → {}/runtime.json · try `wb rt status`",
                if have_secrets { ", secrets: env-file" } else { "" },
                disco.to_string_lossy()
            ))
        }
        Some("krunvm") => {
            if have_secrets {
                bail!("krunvm can't deliver the kit's secrets env yet — use docker/podman locally, or a cloud provider");
            }
            let _ = io.spawn("krunvm", &["delete", app]);
            io.spawn("krunvm", &[
                "create", &image, "--name", app,
                "--cpus", "2", "--mem", "2048",
                "--port", &port_map,
                "--volume", &disco_mount,
                "--volume", &data_mount,
            ])?;
            // krunvm start is foreground — detach it ourselves so apply converges
            let log = util::app_dir().join(format!("krunvm-{app}.log"));
            io.spawn("sh", &["-c", &format!("nohup krunvm start {app} > '{}' 2>&1 &", log.display())])?;
            Ok(format!(
                "microVM `{app}` started from {image} (log: {})\ntry `wb rt status` in a few seconds",
                log.display()
            ))
        }
        _ => bail!("no container engine (docker/podman/krunvm) — install one, or use `wb deploy init cloud`"),
    }
}

fn lifecycle(io: &dyn Io, action: &str) -> Result<String> {
    let cfg = load(io)?;
    match cfg.target() {
        "local" => match engine(io) {
            Some(eng @ ("docker" | "podman")) => match action {
                "status" => {
                    let filter = format!("name={}", cfg.app());
                    io.spawn(eng, &["ps", "-a", "--filter", &filter, "--format", "{{.Names}}\t{{.Status}}\t{{.Ports}}"])
                }
                "logs" => io.spawn(eng, &["logs", "--tail", "200", cfg.app()]),
                "down" => {
                    io.spawn(eng, &["rm", "-f", cfg.app()])?;
                    Ok(format!("removed container `{}`", cfg.app()))
                }
                _ => unreachable!(),
            },
            Some("krunvm") => match action {
                "status" => io.spawn("krunvm", &["list"]),
                "logs" => {
                    let log = util::app_dir().join(format!("krunvm-{}.log", cfg.app()));
                    Ok(String::from_utf8_lossy(&io.read(&log.to_string_lossy())?).into_owned())
                }
                "down" => {
                    io.spawn("krunvm", &["delete", cfg.app()])?;
                    Ok(format!("deleted microVM `{}`", cfg.app()))
                }
                _ => unreachable!(),
            },
            _ => bail!("no container engine found"),
        },
        place => recipe_action(io, &cfg, place, action),
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
    let providers = resolve_providers_dir(io);
    let recipes: Vec<String> = std::fs::read_dir(&providers)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter(|e| e.path().join("bootstrap.sh").is_file())
                .map(|e| e.file_name().to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default();
    lines.push(format!("  providers: {} ({})", recipes.join(", "), providers.display()));
    if let Ok(cfg) = load(io) {
        let missing = missing_secrets(io, &cfg);
        let declared = cfg.declared_secrets();
        lines.push(match (declared.is_empty(), missing.is_empty()) {
            (true, _) => "  secrets: none declared".into(),
            (false, true) => format!("  secrets: ✓ all declared present ({})", declared.join(", ")),
            (false, false) => format!("  secrets: ✗ missing {}", missing.join(", ")),
        });
    }
    Ok(lines.join("\n"))
}

const TEMPLATE_LOCAL: &str = "\
#+TITLE: Workbooks deployment
#+DEPLOY_TARGET: local
#+DEPLOY_APP: workbooks
#+DEPLOY_PORT: 4000
# Secret NAMES this deployment needs (values: `wb deploy secrets set KEY=VAL`):
#+DEPLOY_SECRETS: OPENROUTER_API_KEY
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
# Secret NAMES this deployment needs (values: `wb deploy secrets set KEY=VAL`):
#+DEPLOY_SECRETS: OPENROUTER_API_KEY
# DEPLOY_TARGET names a provider RECIPE (providers/<place>/bootstrap.sh) — fly is
# the bundled one; add your own place the same way. DEPLOY_IMAGE defaults to
# ghcr.io/workbooks-sh/runtime:latest (env WB_IMAGE overrides).
";
