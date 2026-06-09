//! The capability seam. The ONLY place native and wasm targets differ.
//!
//! Everything above this (arg parsing, kernel calls, command logic) is
//! target-agnostic. Below it, native uses std/reqwest; wasm uses host imports
//! brokered by the runtime Dock (capabilities granted, not assumed).

use anyhow::Result;

/// An RCP request to the runtime engine.
pub struct HttpReq<'a> {
    pub method: &'a str,
    pub path: &'a str,
    pub body: Option<&'a str>,
}

/// Host capabilities the CLI needs. Implemented once per target.
pub trait Io {
    /// Talk to the discovered runtime engine over RCP. Used by engine verbs.
    fn http(&self, req: HttpReq) -> Result<String>;
    /// Plain HTTP to an arbitrary URL (publish self-hosted targets etc.).
    fn http_url(&self, method: &str, url: &str, body: Option<&[u8]>, bearer: Option<&str>) -> Result<String>;
    /// Read a local file (e.g. deployment.org, a workbook source).
    fn read(&self, path: &str) -> Result<Vec<u8>>;
    /// Write a local file (e.g. scaffold deployment.org, a bundled workbook).
    fn write(&self, path: &str, bytes: &[u8]) -> Result<()>;
    /// Spawn an external tool — docker / krunvm / fly / wrangler / git.
    fn spawn(&self, program: &str, args: &[&str]) -> Result<String>;
}

/// Pick the impl at compile time.
pub fn platform() -> Box<dyn Io> {
    #[cfg(not(target_arch = "wasm32"))]
    {
        Box::new(native::Native)
    }
    #[cfg(target_arch = "wasm32")]
    {
        Box::new(wasm::Wasm)
    }
}

// ── native edge ─────────────────────────────────────────────────────────────
#[cfg(not(target_arch = "wasm32"))]
mod native {
    use super::*;
    use anyhow::{bail, Context};
    use std::path::PathBuf;

    pub struct Native;

    /// The running runtime, located via its discovery file.
    struct Disco {
        scheme: String,
        port: u64,
        token: String,
    }

    /// Mirror of `Workbooks.Desktop.discovery_path/0`: WB_DESKTOP_DIR override,
    /// else the per-OS app-data `sh.workbooks/disco/runtime.json`.
    fn discovery_path() -> PathBuf {
        if let Ok(d) = std::env::var("WB_DESKTOP_DIR") {
            return PathBuf::from(d).join("runtime.json");
        }
        crate::util::app_dir().join("disco").join("runtime.json")
    }

    fn discovery() -> Result<Disco> {
        let path = discovery_path();
        let raw = std::fs::read_to_string(&path).with_context(|| {
            format!(
                "no runtime discovery at {} — is the runtime running? (try `wb deploy local`)",
                path.display()
            )
        })?;
        let v: serde_json::Value = serde_json::from_str(&raw).context("parse runtime.json")?;
        Ok(Disco {
            scheme: v["scheme"].as_str().unwrap_or("http").to_string(),
            port: v["port"].as_u64().context("discovery: missing port")?,
            token: v["token"].as_str().unwrap_or_default().to_string(),
        })
    }

    fn request(method: &str, url: &str, body: Option<&[u8]>, bearer: Option<&str>) -> Result<String> {
        let client = reqwest::blocking::Client::new();
        let mut rb = match method {
            "GET" => client.get(url),
            "POST" => client.post(url),
            "PUT" => client.put(url),
            "DELETE" => client.delete(url),
            m => bail!("unsupported method {m}"),
        };
        if let Some(t) = bearer {
            if !t.is_empty() {
                rb = rb.bearer_auth(t);
            }
        }
        if let Some(b) = body {
            rb = rb.header("content-type", "application/json").body(b.to_vec());
        }
        let resp = rb.send().with_context(|| format!("{method} {url}"))?;
        let status = resp.status();
        let text = resp.text().unwrap_or_default();
        if !status.is_success() {
            bail!("{status}: {text}");
        }
        Ok(text)
    }

    impl Io for Native {
        fn http(&self, req: HttpReq) -> Result<String> {
            let d = discovery()?;
            let url = format!("{}://127.0.0.1:{}{}", d.scheme, d.port, req.path);
            request(req.method, &url, req.body.map(str::as_bytes), Some(&d.token))
        }
        fn http_url(&self, method: &str, url: &str, body: Option<&[u8]>, bearer: Option<&str>) -> Result<String> {
            request(method, url, body, bearer)
        }
        fn read(&self, path: &str) -> Result<Vec<u8>> {
            std::fs::read(path).with_context(|| format!("read {path}"))
        }
        fn write(&self, path: &str, bytes: &[u8]) -> Result<()> {
            if let Some(parent) = std::path::Path::new(path).parent() {
                if !parent.as_os_str().is_empty() {
                    std::fs::create_dir_all(parent)?;
                }
            }
            std::fs::write(path, bytes).with_context(|| format!("write {path}"))
        }
        fn spawn(&self, program: &str, args: &[&str]) -> Result<String> {
            let out = std::process::Command::new(program)
                .args(args)
                .output()
                .with_context(|| format!("spawn {program}"))?;
            if !out.status.success() {
                bail!("{program} failed: {}", String::from_utf8_lossy(&out.stderr));
            }
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        }
    }
}

// ── wasm edge (in-sandbox; host capabilities via WASI + the Dock) ────────────
#[cfg(target_arch = "wasm32")]
mod wasm {
    use super::*;
    use anyhow::{bail, Context};

    pub struct Wasm;

    impl Io for Wasm {
        // In-sandbox HTTP is brokered by the runtime: the Dock maps the CLI's
        // RCP calls onto the engine it runs inside (loopback, not a socket).
        // Until the Dock export lands, engine verbs report the limitation
        // instead of pretending.
        fn http(&self, _req: HttpReq) -> Result<String> {
            bail!("engine verbs aren't available in the wasm sandbox yet — the Dock HTTP broker is pending; run the native wb")
        }
        fn http_url(&self, _m: &str, _u: &str, _b: Option<&[u8]>, _t: Option<&str>) -> Result<String> {
            bail!("network egress isn't available in the wasm sandbox — run the native wb")
        }
        // WASI preopens give the sandboxed CLI real (capability-scoped) file IO:
        // kernel + assembly verbs work fully in-sandbox.
        fn read(&self, path: &str) -> Result<Vec<u8>> {
            std::fs::read(path).with_context(|| format!("read {path} (is the dir preopened?)"))
        }
        fn write(&self, path: &str, bytes: &[u8]) -> Result<()> {
            if let Some(parent) = std::path::Path::new(path).parent() {
                if !parent.as_os_str().is_empty() {
                    std::fs::create_dir_all(parent)?;
                }
            }
            std::fs::write(path, bytes).with_context(|| format!("write {path} (is the dir preopened?)"))
        }
        fn spawn(&self, _program: &str, _args: &[&str]) -> Result<String> {
            bail!("process spawn is unavailable in the wasm sandbox (deploy/publish orchestration is native-only)")
        }
    }
}
