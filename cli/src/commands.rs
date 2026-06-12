//! Engine-backed verbs. Each is a thin RCP call into a running runtime — the
//! runtime owns the compilers, wasmtime, and the tenant library, so the CLI
//! never reimplements them. If no runtime is reachable, `io.http` returns a
//! clear "no runtime — try `wbx deploy local`" error (see io.rs).

use crate::io::Io;
use crate::rcp;
use crate::util::urlenc;
use anyhow::{bail, Context, Result};
use base64::Engine as _;

/// Local/trusted runtimes scope to tenant "local"; override with WB_TENANT.
fn tenant() -> String {
    std::env::var("WB_TENANT").unwrap_or_else(|_| "local".into())
}

// ── build / run (need the in-sandbox compiler toolchain → the engine) ──
pub fn build(io: &dyn Io, src: &str) -> Result<String> {
    rcp::call(io, "POST", &format!("/rcp/build?src={}", urlenc(src)), None)
}

/// `wb run <file.org> [input…]` — execute the workbook's workflow DAG on the
/// engine (`Workbooks.Workflow.run/2`).
pub fn run(io: &dyn Io, file: &str, input: &[String]) -> Result<String> {
    let org = String::from_utf8(io.read(file)?)?;
    let body = serde_json::json!({ "org": org, "input": input.join(" ") });
    rcp::call(io, "POST", "/api/workflow", Some(&body.to_string()))
}

// ── library (the tenant's many workbooks) ──
pub fn library(io: &dyn Io) -> Result<String> {
    rcp::call(io, "GET", &format!("/api/library/{}", urlenc(&tenant())), None)
}
/// `wb checkout` — the engine zips the member's tree back to us (the engine
/// usually runs in a container; its filesystem is not ours). We unzip locally.
pub fn checkout(io: &dyn Io, member: &str, dir: &str) -> Result<String> {
    let resp = rcp::call(io, "POST", &format!("/rcp/library/checkout?member={}", urlenc(member)), None)?;
    let v: serde_json::Value = serde_json::from_str(&resp).context("bad checkout response")?;
    if let Some(err) = v["error"].as_str() {
        bail!("{err}");
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(v["b64"].as_str().context("checkout response missing bytes")?)?;
    let files = crate::local::unzip_bytes_to(io, &bytes, dir)?;
    Ok(format!("checked out {member} → {dir}/ ({files} files)"))
}

/// `wb checkin` — zip the local working dir, upload; the engine writes it back.
pub fn checkin(io: &dyn Io, member: &str, dir: &str) -> Result<String> {
    let zip = crate::local::zip_dir(io, dir)?;
    let body = serde_json::json!({ "b64": base64::engine::general_purpose::STANDARD.encode(&zip) });
    rcp::call(io, "POST", &format!("/rcp/library/checkin?member={}", urlenc(member)), Some(&body.to_string()))
}

pub fn store(io: &dyn Io, slug: &str, list: bool, build: bool) -> Result<String> {
    if list {
        rcp::call(io, "GET", "/rcp/store", None)
    } else if slug.is_empty() {
        bail!("usage: wbx store <slug> [--build] | wb store --list")
    } else {
        let b = if build { "&build=1" } else { "" };
        rcp::call(io, "POST", &format!("/rcp/store?slug={}{b}", urlenc(slug)), None)
    }
}

/// `wb fetch <key> [out]` — bytes come back base64-wrapped in JSON; write them.
pub fn fetch(io: &dyn Io, key: &str, out: &str) -> Result<String> {
    let resp = rcp::call(io, "GET", &format!("/rcp/fetch?key={}", urlenc(key)), None)?;
    let v: serde_json::Value = serde_json::from_str(&resp).context("bad fetch response")?;
    if let Some(err) = v["error"].as_str() {
        bail!("{err}");
    }
    let b64 = v["b64"].as_str().context("fetch response missing bytes")?;
    let bytes = base64::engine::general_purpose::STANDARD.decode(b64)?;
    let out_path = if out == "./" || out.is_empty() {
        std::path::Path::new(key).file_name().unwrap_or_default().to_string_lossy().to_string()
    } else {
        out.to_string()
    };
    io.write(&out_path, &bytes)?;
    Ok(format!("fetched {key} → {out_path} ({} bytes)", bytes.len()))
}

pub fn search(io: &dyn Io, query: &str, mode: &str) -> Result<String> {
    // --sql is the cross-workbook OQL query-through — a DIFFERENT engine surface
    // than ranked search (Library.search only knows hybrid/semantic/literal).
    if mode == "sql" {
        let body = serde_json::json!({ "sql": query });
        return rcp::call(io, "POST", &format!("/api/library/{}/query", urlenc(&tenant())), Some(&body.to_string()));
    }
    let body = serde_json::json!({ "query": query, "mode": mode });
    rcp::call(io, "POST", &format!("/api/search/{}", urlenc(&tenant())), Some(&body.to_string()))
}

// ── workflow / agent / workbook ──
pub fn workflow(io: &dyn Io, plan: bool, file: &str, input: &str) -> Result<String> {
    let org = String::from_utf8(io.read(file)?)?;
    let body = serde_json::json!({ "org": org, "input": input });
    let path = if plan { "/api/workflow?plan=1" } else { "/api/workflow" };
    rcp::call(io, "POST", path, Some(&body.to_string()))
}

pub fn agent_run(io: &dyn Io, task: &str, system: &str, model: Option<&str>) -> Result<String> {
    let mut body = serde_json::json!({ "system": system, "task": task });
    if let Some(m) = model {
        body["model"] = serde_json::Value::String(m.to_string());
    }
    rcp::call(io, "POST", "/api/run", Some(&body.to_string()))
}
pub fn agent_status(io: &dyn Io, id: &str) -> Result<String> {
    rcp::call(io, "GET", &format!("/api/run/{}", urlenc(id)), None)
}

pub fn workbook_list(io: &dyn Io) -> Result<String> {
    rcp::call(io, "GET", "/api/workbooks", None)
}
pub fn workbook_show(io: &dyn Io, id: &str) -> Result<String> {
    rcp::call(io, "GET", &format!("/api/w/{}/org", urlenc(id)), None)
}
pub fn workbook_deploy(io: &dyn Io, id: &str, file: &str) -> Result<String> {
    let org = String::from_utf8(io.read(file)?)?;
    rcp::call(io, "PUT", &format!("/w/{}", urlenc(id)), Some(&org))?;
    Ok(format!("deployed {file} → /w/{id}"))
}

// ── federation (the tenant repo lives engine-side) ──
pub fn mirror(io: &dyn Io, target: &str) -> Result<String> {
    let body = if target.contains("://") || target.starts_with("git@") {
        serde_json::json!({ "url": target })
    } else {
        // bare word = forge name (github|gitlab|gitea) → auto-provision
        serde_json::json!({ "forge": target })
    };
    rcp::call(io, "POST", &format!("/api/mirror/{}", urlenc(&tenant())), Some(&body.to_string()))
}
pub fn federate(io: &dyn Io) -> Result<String> {
    rcp::call(io, "POST", &format!("/api/radicle/{}/publish", urlenc(&tenant())), Some("{}"))
}

// ── toolkit (the agent-extensibility surface; engine-backed) ──
pub fn toolkit_list(io: &dyn Io) -> Result<String> {
    rcp::call(io, "GET", "/rcp/toolkit", None)
}
pub fn toolkit_show(io: &dyn Io, id: &str, skill: Option<&str>) -> Result<String> {
    let path = match skill {
        Some(s) => format!("/rcp/toolkit/show?id={}&skill={}", urlenc(id), urlenc(s)),
        None => format!("/rcp/toolkit/show?id={}", urlenc(id)),
    };
    rcp::call(io, "GET", &path, None)
}
pub fn toolkit_search(io: &dyn Io, q: &str) -> Result<String> {
    rcp::call(io, "GET", &format!("/rcp/toolkit/search?q={}", urlenc(q)), None)
}
pub fn toolkit_verify(io: &dyn Io, id: &str) -> Result<String> {
    rcp::call(io, "POST", &format!("/rcp/toolkit/verify?id={}", urlenc(id)), None)
}
pub fn toolkit_sign(io: &dyn Io, id: &str) -> Result<String> {
    rcp::call(io, "POST", &format!("/rcp/toolkit/sign?id={}", urlenc(id)), None)
}
/// `wbx toolkit push <id> <dir>` — ship a toolkit DIRECTORY onto the engine
/// (zip over RCP; the engine unpacks it under its toolkits root). This is the
/// deploy-the-toolkit verb: write a toolkit, push it, the runtime has it.
pub fn toolkit_push(io: &dyn Io, id: &str, dir: &str) -> Result<String> {
    let zip = crate::local::zip_dir(io, dir)?;
    let body = serde_json::json!({ "b64": base64::engine::general_purpose::STANDARD.encode(&zip) });
    rcp::call(io, "POST", &format!("/rcp/toolkit/install?id={}", urlenc(id)), Some(&body.to_string()))
}

pub fn toolkit_build(io: &dyn Io, id: &str, which: Option<&str>) -> Result<String> {
    let path = match which {
        Some(w) => format!("/rcp/toolkit/build?id={}&which={}", urlenc(id), urlenc(w)),
        None => format!("/rcp/toolkit/build?id={}", urlenc(id)),
    };
    rcp::call(io, "POST", &path, None)
}
pub fn toolkit_run(io: &dyn Io, id: &str, task: &str, args: &[String]) -> Result<String> {
    let body = serde_json::json!({ "args": args });
    rcp::call(
        io,
        "POST",
        &format!("/rcp/toolkit/run?id={}&task={}", urlenc(id), urlenc(task)),
        Some(&body.to_string()),
    )
}

// ── observability ──
pub fn telemetry(io: &dyn Io, slug: Option<&str>) -> Result<String> {
    match slug {
        Some(s) => rcp::call(io, "GET", &format!("/api/telemetry/{}", urlenc(s)), None),
        None => rcp::call(io, "GET", "/api/telemetry", None),
    }
}
pub fn ledger(io: &dyn Io, slug: &str) -> Result<String> {
    rcp::call(io, "GET", &format!("/api/ledger/{}", urlenc(slug)), None)
}

// ── raw RCP escape hatch ──
pub fn rt(io: &dyn Io, args: &[String]) -> Result<String> {
    match args.first().map(String::as_str) {
        Some("status") => rcp::call(io, "GET", "/.well-known/workbooks-runtime", None),
        Some("get") => rcp::call(io, "GET", args.get(1).map(String::as_str).unwrap_or("/"), None),
        Some("post") => rcp::call(io, "POST", args.get(1).map(String::as_str).unwrap_or("/"), args.get(2).map(String::as_str)),
        _ => bail!("usage: wbx rt status | get <path> | post <path> [body]"),
    }
}
