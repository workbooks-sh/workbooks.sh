//! Native-desktop OAuth flow for Workbooks via the Broker's daemon
//! return-to surface (RFC 8252 loopback).
//!
//! Why broker-mediated instead of direct-to-WorkOS PKCE:
//!   The broker is already a confidential OAuth client registered
//!   with the WorkOS environment (its `https://auth.workbooks.sh
//!   /v1/auth/callback` redirect URI is the only one we need to
//!   keep in sync). The broker also already implements a "daemon
//!   flow" — `safeReturnTo` (packages/broker/worker/src/routes/auth.ts
//!   §76–126) accepts `http://localhost:<port>/...` return_to URLs,
//!   the callback mints a single-use `broker_code` and bounces the
//!   browser to that return_to, and `/v1/auth/exchange` swaps the
//!   code for a session bearer.
//!
//!   So the desktop's job is just to (1) spawn a loopback, (2) open
//!   the system browser to `/v1/auth/start?return_to=...`, (3) read
//!   the `broker_code` from the callback, (4) POST it to /exchange,
//!   (5) stash the bearer in the OS keychain. No WorkOS dashboard
//!   round-trip per loopback port, no PKCE to manage, and the broker
//!   keeps owning session/identity logic.
//!
//! This replaces the embedded-webview/cookie-based flow that was
//! unworkable cross-origin (SameSite issues, stale WebKit cookie
//! stores, etc.).

use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::time::timeout;

/// What the JS layer gets back when sign-in succeeds. Mirrors the
/// shape `POST /v1/auth/exchange` returns (session metadata + bearer
/// token), which is everything the UI needs to render a signed-in
/// state immediately.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoopbackSignInResult {
    pub bearer: String,
    pub expires_at: i64,
    pub sub: String,
    pub email: String,
    pub email_verified: bool,
    pub organization_id: Option<String>,
    /// WorkOS display name, when the broker has it. Renders as the
    /// primary identity line in the desktop's General settings card.
    #[serde(default)]
    pub display_name: Option<String>,
    /// URL to the user's profile picture (either a WorkOS hosted
    /// avatar or a Broker-relative `/v1/users/me/picture` when the
    /// user uploaded a custom one). null when neither is set.
    #[serde(default)]
    pub picture_url: Option<String>,
}

/// Drive the full broker-mediated loopback flow:
///   1. Bind a loopback TcpListener (OS picks the port)
///   2. Open system browser to `{broker_url}/v1/auth/start?return_to=
///      http://localhost:<port>/callback&app=workbooks-desktop`
///   3. Capture redirect with `broker_code`
///   4. POST to `{broker_url}/v1/auth/exchange` to swap for a bearer
///   5. Return the exchange response
///
/// `total_timeout` caps the wait between opening the browser and
/// receiving the redirect. 5 minutes is a generous default.
pub async fn run_loopback_signin(
    broker_url: &str,
    total_timeout: Duration,
) -> Result<LoopbackSignInResult, String> {
    let broker = broker_url.trim_end_matches('/');

    // Bind first so we know what port to put in the return_to URL.
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| format!("bind loopback listener: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("local_addr: {e}"))?
        .port();
    let return_to = format!("http://localhost:{port}/callback");

    let start_url = format!(
        "{broker}/v1/auth/start?app=workbooks-desktop&return_to={return_enc}",
        return_enc = urlencoding::encode(&return_to),
    );

    log::info!(
        "[auth_loopback] loopback bound port={port} return_to={return_to}"
    );
    log::info!("[auth_loopback] opening system browser → {start_url}");

    open_in_system_browser(&start_url)?;

    let broker_code = match timeout(total_timeout, await_callback(&listener)).await {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => return Err(format!("callback: {e}")),
        Err(_) => return Err("sign-in timed out — no callback within 5 minutes".into()),
    };

    exchange_broker_code(broker, &broker_code).await
}

// ── System browser ─────────────────────────────────────────────────

fn open_in_system_browser(url: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let (cmd, args): (&str, Vec<&str>) = ("open", vec![url]);
    #[cfg(target_os = "linux")]
    let (cmd, args): (&str, Vec<&str>) = ("xdg-open", vec![url]);
    #[cfg(target_os = "windows")]
    let (cmd, args): (&str, Vec<&str>) = ("cmd", vec!["/C", "start", "", url]);

    std::process::Command::new(cmd)
        .args(&args)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("open browser: {e}"))
}

// ── Loopback HTTP server (one-shot) ────────────────────────────────

/// Accept exactly one HTTP request on the listener, parse the
/// `/callback?broker_code=...` query, respond with a friendly "you
/// can close this" page, and return the captured broker_code.
///
/// Hand-rolled minimal HTTP/1.1 reader: we only ever speak to a
/// single localhost client (a browser making one GET) so we don't
/// need a full HTTP stack — that'd pull in 50KLOC of dependencies
/// for one route.
async fn await_callback(listener: &TcpListener) -> Result<String, String> {
    let (mut socket, _) = listener
        .accept()
        .await
        .map_err(|e| format!("accept: {e}"))?;

    let mut buf = [0u8; 8192];
    let n = socket
        .read(&mut buf)
        .await
        .map_err(|e| format!("read: {e}"))?;
    if n == 0 {
        return Err("empty request".into());
    }
    let req = std::str::from_utf8(&buf[..n]).unwrap_or("");

    let request_line = req.lines().next().unwrap_or("");
    let path_and_query = request_line
        .split_whitespace()
        .nth(1)
        .ok_or("malformed request line")?;

    let (broker_code, error) = parse_callback_query(path_and_query);

    let body = match &error {
        Some(e) => render_error_html(e),
        None => render_success_html(),
    };
    let response = format!(
        "HTTP/1.1 200 OK\r\n\
         Content-Type: text/html; charset=utf-8\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n\
         {}",
        body.len(),
        body
    );
    let _ = socket.write_all(response.as_bytes()).await;
    let _ = socket.flush().await;

    if let Some(e) = error {
        return Err(format!("broker returned error: {e}"));
    }
    if broker_code.is_empty() {
        return Err("callback missing broker_code".into());
    }
    Ok(broker_code)
}

fn parse_callback_query(path_and_query: &str) -> (String, Option<String>) {
    let q = path_and_query.split_once('?').map(|(_, q)| q).unwrap_or("");
    let mut broker_code = String::new();
    let mut error: Option<String> = None;

    for pair in q.split('&') {
        let Some((k, v)) = pair.split_once('=') else { continue };
        let val = urlencoding::decode(v).map(|s| s.into_owned()).unwrap_or_default();
        match k {
            "broker_code" => broker_code = val,
            "error" | "error_description" => {
                let existing = error.unwrap_or_default();
                error = Some(if existing.is_empty() {
                    val
                } else {
                    format!("{existing}: {val}")
                });
            }
            _ => {}
        }
    }
    (broker_code, error)
}

fn render_success_html() -> String {
    r#"<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Signed in</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; background: #0f1115; color: #e8e8ec;
         display: grid; place-items: center; min-height: 100vh; margin: 0; }
  .card { text-align: center; padding: 32px 28px; }
  .check { width: 56px; height: 56px; border-radius: 50%; margin: 0 auto 14px;
           background: rgba(34,160,105,0.18); color: #5fd49c; display: grid; place-items: center;
           font-size: 28px; font-weight: 700; }
  h1 { margin: 0 0 6px; font-size: 1.05rem; font-weight: 600; }
  p { margin: 0; color: #9aa1ad; font-size: 0.86rem; }
</style></head>
<body>
  <div class="card">
    <div class="check">✓</div>
    <h1>You're signed in to Workbooks</h1>
    <p>You can close this tab and return to the app.</p>
  </div>
  <script>setTimeout(() => window.close(), 800);</script>
</body></html>"#
        .to_string()
}

fn render_error_html(err: &str) -> String {
    format!(
        r#"<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>Sign-in failed</title>
<style>
  body {{ font-family: -apple-system, system-ui, sans-serif; background: #0f1115; color: #e8e8ec;
         display: grid; place-items: center; min-height: 100vh; margin: 0; }}
  .card {{ text-align: center; padding: 32px 28px; max-width: 420px; }}
  .x {{ width: 56px; height: 56px; border-radius: 50%; margin: 0 auto 14px;
         background: rgba(220,60,60,0.18); color: #ff8c8c; display: grid; place-items: center;
         font-size: 28px; font-weight: 700; }}
  h1 {{ margin: 0 0 6px; font-size: 1.05rem; font-weight: 600; }}
  p {{ margin: 0; color: #9aa1ad; font-size: 0.86rem; word-break: break-word; }}
</style></head>
<body>
  <div class="card">
    <div class="x">✗</div>
    <h1>Sign-in didn't complete</h1>
    <p>{}</p>
  </div>
</body></html>"#,
        html_escape(err)
    )
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

// ── Broker code exchange ──────────────────────────────────────────

async fn exchange_broker_code(
    broker_url: &str,
    broker_code: &str,
) -> Result<LoopbackSignInResult, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(15))
        .build()
        .map_err(|e| format!("http client: {e}"))?;

    let resp = client
        .post(format!("{broker_url}/v1/auth/exchange"))
        .json(&serde_json::json!({ "broker_code": broker_code }))
        .send()
        .await
        .map_err(|e| format!("exchange request: {e}"))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("exchange read body: {e}"))?;

    if !status.is_success() {
        return Err(format!("broker /exchange {}: {}", status.as_u16(), text));
    }

    serde_json::from_str(&text)
        .map_err(|e| format!("exchange parse ({e}): {text}"))
}
