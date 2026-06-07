// `wb-publish auth bearer` — mint/cache the workbooks.sh broker
// bearer used by `workbook publish`. Folds the browser OAuth loopback
// flow that previously lived in build-kit's publish.mjs (wb-lcfa.22);
// the Node side shells out here for the interactive path only.
//
// Contract: stdout carries ONLY the token; progress goes to stderr.
// Cache file + shape are publish.mjs-compatible:
// ~/.config/workbooks/auth.json {bearer, expires_at(ms), sub, email}.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::time::Duration;

use crate::cli::AuthCmd;

const DEFAULT_BROKER: &str = "https://auth.workbooks.sh";
const AUTH_TIMEOUT: Duration = Duration::from_secs(300);

pub async fn run(cmd: AuthCmd) -> Result<()> {
    match cmd {
        AuthCmd::Bearer { broker, force } => bearer(broker.as_deref(), force).await,
    }
}

#[derive(Serialize, Deserialize, Debug)]
struct Cached {
    bearer: String,
    /// Epoch ms; legacy second-precision caches normalized on read.
    expires_at: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    sub: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    email: Option<String>,
}

async fn bearer(broker: Option<&str>, force: bool) -> Result<()> {
    if let Ok(b) = std::env::var("WORKBOOKS_BEARER") {
        if !b.is_empty() {
            println!("{b}");
            return Ok(());
        }
    }
    if !force {
        if let Some(c) = read_cache() {
            if c.expires_at > now_ms() + 60_000.0 {
                println!("{}", c.bearer);
                return Ok(());
            }
        }
    }
    let broker = broker
        .map(str::to_string)
        .or_else(|| std::env::var("WORKBOOKS_BROKER").ok().filter(|s| !s.is_empty()))
        .unwrap_or_else(|| DEFAULT_BROKER.to_string());

    let fresh = loopback_auth(&broker).await?;
    write_cache(&fresh)?;
    println!("{}", fresh.bearer);
    Ok(())
}

async fn loopback_auth(broker: &str) -> Result<Cached> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").context("bind loopback")?;
    let port = listener.local_addr()?.port();
    let server = tiny_http::Server::from_listener(listener, None)
        .map_err(|e| anyhow!("loopback listener: {e}"))?;

    let mut start = reqwest::Url::parse(broker)
        .and_then(|u| u.join("/v1/auth/start"))
        .with_context(|| format!("broker URL {broker}"))?;
    start
        .query_pairs_mut()
        .append_pair("return_to", &format!("http://127.0.0.1:{port}/cb"));

    eprintln!("Opening browser to sign in...\n  {start}");
    open_in_browser(start.as_str());

    let code = tokio::task::spawn_blocking(move || wait_for_code(server))
        .await
        .context("loopback wait task")??;

    let exchanged: serde_json::Value = reqwest::Client::new()
        .post(format!("{broker}/v1/auth/exchange"))
        .json(&serde_json::json!({ "broker_code": code }))
        .send()
        .await
        .context("POST /v1/auth/exchange")?
        .error_for_status()
        .context("broker exchange")?
        .json()
        .await
        .context("parse exchange response")?;

    let bearer = exchanged
        .get("bearer")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow!("broker exchange returned no bearer: {exchanged}"))?;
    let expires_at = exchanged
        .get("expires_at")
        .and_then(|v| v.as_f64())
        .ok_or_else(|| anyhow!("broker exchange returned no expires_at: {exchanged}"))?;

    Ok(Cached {
        bearer: bearer.to_string(),
        expires_at: expires_at * 1000.0,
        sub: exchanged.get("sub").and_then(|v| v.as_str()).map(String::from),
        email: exchanged.get("email").and_then(|v| v.as_str()).map(String::from),
    })
}

/// Block until the broker redirects to `/cb?broker_code=...` (or
/// `?error=...`). Other paths get 404 and we keep listening. The
/// browser tab always gets an answer before we return.
fn wait_for_code(server: tiny_http::Server) -> Result<String> {
    let deadline = std::time::Instant::now() + AUTH_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        if remaining.is_zero() {
            return Err(anyhow!("auth timed out after 5m"));
        }
        let req = match server.recv_timeout(remaining) {
            Ok(Some(r)) => r,
            Ok(None) => continue,
            Err(e) => return Err(anyhow!("loopback accept error: {e}")),
        };

        let url = req.url().to_string();
        let (path, query) = url.split_once('?').unwrap_or((url.as_str(), ""));
        if path.trim_end_matches('/') != "/cb" {
            let _ = req.respond(tiny_http::Response::from_string("not found").with_status_code(404));
            continue;
        }

        let params = super::bluesky_oauth::server::parse_query(query);
        if let Some(err) = params.get("error") {
            respond_html(req, 400, "Sign-in failed", err);
            return Err(anyhow!("broker error: {err}"));
        }
        match params.get("broker_code") {
            Some(code) if !code.is_empty() => {
                respond_html(req, 200, "You're signed in", "The Workbooks CLI is authenticated. You can close this tab.");
                return Ok(code.clone());
            }
            _ => respond_html(req, 400, "Sign-in incomplete", "This callback did not include a sign-in code. Return to your terminal and retry."),
        }
    }
}

fn respond_html(req: tiny_http::Request, status: u16, title: &str, detail: &str) {
    let body = format!(
        r#"<!doctype html><html lang="en"><head><meta charset="utf-8" /><title>Workbooks — {title}</title>
<style>body{{font:15px/1.5 -apple-system,system-ui,sans-serif;color:#111;background:#fafafa;margin:0;display:flex;align-items:center;justify-content:center;min-height:100vh}}
.card{{background:white;padding:32px 40px;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,0.08);max-width:380px}}
h1{{font-size:18px;margin:0 0 8px}}p{{margin:0;color:#555}}small{{color:#999;display:block;margin-top:16px}}</style>
</head><body><div class="card"><h1>{title}.</h1><p>{detail}</p><small>workbooks.sh</small></div></body></html>"#
    );
    let header = tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"text/html; charset=utf-8"[..])
        .expect("static header");
    let _ = req.respond(
        tiny_http::Response::from_string(body)
            .with_status_code(status)
            .with_header(header),
    );
}

fn open_in_browser(url: &str) {
    let (cmd, args): (&str, Vec<&str>) = if cfg!(target_os = "macos") {
        ("open", vec![url])
    } else if cfg!(target_os = "windows") {
        ("cmd", vec!["/c", "start", "", url])
    } else {
        ("xdg-open", vec![url])
    };
    let _ = std::process::Command::new(cmd)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

fn cache_path() -> Result<PathBuf> {
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home directory"))?;
    Ok(home.join(".config").join("workbooks").join("auth.json"))
}

fn read_cache() -> Option<Cached> {
    let bytes = std::fs::read(cache_path().ok()?).ok()?;
    let mut c: Cached = serde_json::from_slice(&bytes).ok()?;
    if c.expires_at < 2_000_000_000.0 {
        c.expires_at *= 1000.0;
    }
    Some(c)
}

fn write_cache(c: &Cached) -> Result<()> {
    let path = cache_path()?;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("mkdir {}", dir.display()))?;
    }
    std::fs::write(&path, serde_json::to_string_pretty(c)? + "\n")
        .with_context(|| format!("write {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&path)?.permissions();
        perms.set_mode(0o600);
        let _ = std::fs::set_permissions(&path, perms);
    }
    Ok(())
}

fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as f64)
        .unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn loopback() -> (tiny_http::Server, u16) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        (tiny_http::Server::from_listener(listener, None).unwrap(), port)
    }

    fn hit(port: u16, qs: &str) -> std::thread::JoinHandle<u16> {
        let url = format!("http://127.0.0.1:{port}/cb?{qs}");
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            reqwest::blocking::Client::new()
                .get(&url)
                .timeout(Duration::from_secs(2))
                .send()
                .unwrap()
                .status()
                .as_u16()
        })
    }

    #[test]
    fn callback_loopback_receives_broker_code() {
        let (server, port) = loopback();
        let client = hit(port, "broker_code=THE_CODE");
        let code = wait_for_code(server).unwrap();
        assert_eq!(client.join().unwrap(), 200);
        assert_eq!(code, "THE_CODE");
    }

    #[test]
    fn callback_loopback_surfaces_broker_error() {
        let (server, port) = loopback();
        let client = hit(port, "error=access_denied");
        let err = wait_for_code(server).unwrap_err().to_string();
        assert_eq!(client.join().unwrap(), 400);
        assert!(err.contains("access_denied"), "unexpected: {err}");
    }
}
