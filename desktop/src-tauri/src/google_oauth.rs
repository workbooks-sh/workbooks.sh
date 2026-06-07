// Workbooks-managed Google OAuth — the "click Connect, sign in, done"
// path the user expects from a polished integration.
//
// ## Why this exists instead of `gws auth setup`
//
// `gws auth setup` punts the OAuth dance to Google Cloud Console:
// the user has to create their own GCP project, configure a consent
// screen, create an OAuth client, paste credentials. Fine for a
// power-user CLI; terrible for an app. End users should not be
// touching console.cloud.google.com.
//
// Instead, this module owns the OAuth flow:
//
//   1. App generates a PKCE pair (code_verifier + code_challenge).
//   2. App opens the user's browser to Google's auth URL with the
//      Workbooks client_id + challenge + a loopback redirect_uri
//      pointing at a one-shot localhost listener we just bound.
//   3. User signs in with their Google account in the browser.
//   4. Google redirects to http://127.0.0.1:<random_port>/?code=...
//   5. Our listener captures the code, exchanges it (code + verifier
//      + client_id + client_secret) for an access_token + refresh_token.
//   6. Tokens are persisted on the Rust side. The sidecar gets
//      `GOOGLE_WORKSPACE_CLI_TOKEN=<access_token>` via the existing
//      secret-refresh push, which `gws` reads to skip its own auth flow.
//
// ## Embedded credentials
//
// The OAuth client_id + client_secret are baked into the binary.
// This is the standard pattern for distributed desktop apps — see
// any Notion/Slack/Cursor desktop binary; the secret is technically
// extractable but not actionable beyond rate-limited token requests
// against Google's endpoint. PKCE is what makes the flow secure: the
// code_verifier never leaves the client process, so even a stolen
// secret can't complete the exchange without the matching verifier.
//
// **For v1 testing** these point at a developer GCP project owned by
// the user. Before any wider release we'll:
//   1. Create a Workbooks-owned GCP project + OAuth client
//   2. Submit for Google verification (multi-week review)
//   3. Swap the constants below
//
// ## Test users + the 100-user cap
//
// While the Workbooks OAuth client is "unverified", Google caps it
// at 100 test users — every user has to be added to the consent
// screen's test-users list in the GCP console first. Past 100 (or
// before that, for polish) we go through verification + the security
// audit and remove the cap entirely.

#![allow(clippy::module_name_repetitions)]

use std::time::{SystemTime, UNIX_EPOCH};

use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64URL, Engine};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

// ── Embedded OAuth client ─────────────────────────────────────────
//
// TODO(wb): swap these to a Workbooks-owned + Google-verified client
// before public launch. Until then this is the user's personal GCP
// project (shinybjectz). Rotating the secret on Google's side
// invalidates this version; the file should be the only place
// reading it.
const CLIENT_ID: &str =
    "857764164631-gpj1mikmbolgtv6tlsc3au4v5kfvt9v3.apps.googleusercontent.com";
const CLIENT_SECRET: &str = "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";

const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";

/// Google Workspace scopes. We ask for the read+write surface across
/// the major Workspace APIs — gmail, calendar, drive, docs, sheets —
/// so the agent can do everything a user would expect. Each of these
/// is a "sensitive" or "restricted" scope; verification is required
/// past the 100-test-user cap.
const SCOPES: &[&str] = &[
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "openid",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/spreadsheets",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GoogleTokenSet {
    pub access_token: String,
    pub refresh_token: Option<String>,
    /// Unix-millis epoch when the access_token expires.
    pub expires_at_ms: i64,
    /// `email` claim from the id_token, if Google returned one.
    /// Surfaced on the connection card as the account label.
    pub account_email: Option<String>,
}

/// Run the full Google OAuth + PKCE dance and return the token set.
///
/// Errors:
///   - port-binding failures (we use a random free port)
///   - browser-open failures (Tauri shell)
///   - Google returning a non-2xx on the token exchange
///   - timeout if user never completes the browser flow (default 5min)
#[tauri::command]
pub async fn google_oauth_sign_in(app: AppHandle) -> Result<GoogleTokenSet, String> {
    // PKCE: 32 random bytes → verifier (base64url, no pad) →
    // challenge = SHA256(verifier) → base64url, no pad. Google
    // requires `code_challenge_method=S256`.
    let mut verifier_bytes = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut verifier_bytes);
    let code_verifier = B64URL.encode(verifier_bytes);

    let challenge_bytes = {
        let mut hasher = Sha256::new();
        hasher.update(code_verifier.as_bytes());
        hasher.finalize()
    };
    let code_challenge = B64URL.encode(challenge_bytes);

    // CSRF state — random hex token sent in the auth URL and echoed
    // back in the redirect. We compare to reject hijacked redirects.
    let mut state_bytes = [0u8; 16];
    rand::rngs::OsRng.fill_bytes(&mut state_bytes);
    let state = state_bytes
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect::<String>();

    // Bind a loopback listener on a random port. Google requires the
    // redirect_uri to match what's registered on the OAuth client; we
    // register `http://127.0.0.1` with no path (Google accepts any
    // port for that base) and use the actual port the kernel hands
    // us. The user adds this URI in their GCP project once.
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|e| format!("bind loopback: {e}"))?;
    let local_addr = listener
        .local_addr()
        .map_err(|e| format!("local_addr: {e}"))?;
    let redirect_uri = format!("http://127.0.0.1:{}", local_addr.port());

    // Build the auth URL.
    let scope_str = SCOPES.join(" ");
    let auth_url = format!(
        "{AUTH_URL}?\
         client_id={cid}\
         &redirect_uri={redirect}\
         &response_type=code\
         &scope={scope}\
         &code_challenge={challenge}\
         &code_challenge_method=S256\
         &state={state}\
         &access_type=offline\
         &prompt=consent",
        cid = urlencoding::encode(CLIENT_ID),
        redirect = urlencoding::encode(&redirect_uri),
        scope = urlencoding::encode(&scope_str),
        challenge = urlencoding::encode(&code_challenge),
        state = urlencoding::encode(&state),
    );

    // Surface progress to the renderer so it can show "browser open,
    // waiting for sign-in" without blocking the invoke.
    let _ = app.emit("google-oauth-progress", "browser_opening");
    open_browser(&auth_url).map_err(|e| format!("open browser: {e}"))?;

    // Wait for ONE incoming connection — that's the browser's redirect.
    // 5-minute cap; if the user wanders off we don't keep the port
    // bound forever.
    let accept_timeout = tokio::time::Duration::from_secs(5 * 60);
    let (mut socket, _peer) = tokio::time::timeout(accept_timeout, listener.accept())
        .await
        .map_err(|_| "OAuth timed out — no sign-in within 5 minutes".to_string())?
        .map_err(|e| format!("accept: {e}"))?;

    // Read the request line to extract the query string. We don't
    // actually need to parse HTTP fully — we just need the path +
    // query from the first line (`GET /?code=...&state=... HTTP/1.1`).
    let (reader, mut writer) = socket.split();
    let mut buf_reader = BufReader::new(reader);
    let mut req_line = String::new();
    buf_reader
        .read_line(&mut req_line)
        .await
        .map_err(|e| format!("read request line: {e}"))?;

    // Reply with a tiny HTML page so the browser doesn't dangle.
    // Telling the user to return to Workbooks is friendlier than an
    // empty tab.
    let body = success_page();
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\
         Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = writer.write_all(response.as_bytes()).await;
    let _ = writer.shutdown().await;

    // Parse `GET /?code=...&state=... HTTP/1.1`.
    let query = extract_query(&req_line).ok_or("no query string in redirect")?;
    let params = parse_query(query);

    if let Some(err) = params.get("error") {
        return Err(format!("Google returned error: {err}"));
    }
    let returned_state = params
        .get("state")
        .ok_or("missing state in redirect")?
        .as_str();
    if returned_state != state {
        return Err("state mismatch — possible CSRF attempt".into());
    }
    let code = params.get("code").ok_or("missing code in redirect")?;

    let _ = app.emit("google-oauth-progress", "exchanging_code");

    // Exchange code → tokens.
    let client = reqwest::Client::builder()
        .timeout(tokio::time::Duration::from_secs(15))
        .build()
        .map_err(|e| format!("client build: {e}"))?;

    #[derive(Deserialize)]
    struct TokenResponse {
        access_token: String,
        refresh_token: Option<String>,
        expires_in: Option<i64>,
        id_token: Option<String>,
    }

    let form = [
        ("client_id", CLIENT_ID),
        ("client_secret", CLIENT_SECRET),
        ("code", code.as_str()),
        ("code_verifier", code_verifier.as_str()),
        ("grant_type", "authorization_code"),
        ("redirect_uri", redirect_uri.as_str()),
    ];

    let resp = client
        .post(TOKEN_URL)
        .form(&form)
        .send()
        .await
        .map_err(|e| format!("token POST: {e}"))?;

    let status = resp.status();
    let body_text = resp.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(format!(
            "token exchange returned {status}: {body_text}"
        ));
    }
    let token: TokenResponse = serde_json::from_str(&body_text)
        .map_err(|e| format!("parse token response: {e} — body was: {body_text}"))?;

    let now_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    let expires_at_ms = now_ms + token.expires_in.unwrap_or(3600) * 1000;

    let account_email = token
        .id_token
        .as_deref()
        .and_then(parse_email_from_id_token);

    Ok(GoogleTokenSet {
        access_token: token.access_token,
        refresh_token: token.refresh_token,
        expires_at_ms,
        account_email,
    })
}

// ── Helpers ───────────────────────────────────────────────────────

fn open_browser(url: &str) -> Result<(), String> {
    // Use the OS handler. Tauri's shell plugin has `open` but that
    // requires the renderer permission system; we're in a backend
    // command, so go through plain Command.
    #[cfg(target_os = "macos")]
    let prog = "open";
    #[cfg(target_os = "linux")]
    let prog = "xdg-open";
    #[cfg(target_os = "windows")]
    let prog = "cmd";

    #[cfg(target_os = "windows")]
    let args = vec!["/C", "start", "", url];
    #[cfg(not(target_os = "windows"))]
    let args = vec![url];

    std::process::Command::new(prog)
        .args(args)
        .spawn()
        .map_err(|e| format!("{prog} {url}: {e}"))?;
    Ok(())
}

fn extract_query(req_line: &str) -> Option<&str> {
    // `GET /?foo=bar HTTP/1.1\r\n` → `foo=bar`
    let parts: Vec<&str> = req_line.split_whitespace().collect();
    if parts.len() < 2 {
        return None;
    }
    let path = parts[1];
    let q = path.find('?')?;
    Some(&path[q + 1..])
}

fn parse_query(q: &str) -> std::collections::HashMap<String, String> {
    let mut out = std::collections::HashMap::new();
    for pair in q.split('&') {
        let mut kv = pair.splitn(2, '=');
        if let (Some(k), Some(v)) = (kv.next(), kv.next()) {
            let key = urlencoding::decode(k)
                .map(|c| c.into_owned())
                .unwrap_or_else(|_| k.to_string());
            let val = urlencoding::decode(v)
                .map(|c| c.into_owned())
                .unwrap_or_else(|_| v.to_string());
            out.insert(key, val);
        }
    }
    out
}

/// Pull the `email` claim out of a JWT id_token without verifying the
/// signature. The token already came from Google over HTTPS via our
/// token exchange — we're using it for display purposes only, not as
/// an auth assertion, so the unverified decode is fine.
fn parse_email_from_id_token(jwt: &str) -> Option<String> {
    let parts: Vec<&str> = jwt.split('.').collect();
    if parts.len() != 3 {
        return None;
    }
    let payload_bytes = B64URL.decode(parts[1].as_bytes()).ok()?;
    let payload: serde_json::Value = serde_json::from_slice(&payload_bytes).ok()?;
    payload
        .get("email")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string())
}

fn success_page() -> &'static str {
    // Plain inline HTML so we don't need to ship an asset. The user
    // closes this tab + returns to Workbooks; the desktop already
    // captured the redirect.
    r#"<!doctype html>
<html><head><meta charset="utf-8"><title>Signed in to Workbooks</title>
<style>
  body { font-family: -apple-system, system-ui, sans-serif; background: #0a0a0a;
         color: #e6e6e6; display: flex; align-items: center; justify-content: center;
         min-height: 100vh; margin: 0; }
  .card { text-align: center; max-width: 360px; padding: 2rem; }
  h1 { font-size: 1.1rem; margin: 0 0 0.5rem; }
  p { color: #888; font-size: 0.85rem; margin: 0; }
</style></head>
<body><div class="card">
  <h1>Signed in to Workbooks</h1>
  <p>You can close this tab and return to the app.</p>
</div></body></html>"#
}
