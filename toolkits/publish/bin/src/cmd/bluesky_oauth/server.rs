// Loopback HTTP server for the OAuth callback.
//
// Once the browser completes the consent dance, the AS redirects
// to `http://localhost:<port>/callback?code=...&state=...`. We need a
// transient HTTP server bound to that port to receive it. `tiny_http`
// handles exactly this — single-request servers, no async runtime
// required, ~150KB of compiled code.
//
// The server serves one HTML page back to the browser ("you can close
// this tab"), then shuts down. The OAuth code + state are returned to
// the caller for the token-exchange step.
//
// Concurrency: we bind a single port and handle a single connection.
// If anything else hits the port (a stale browser tab, a port-scanner)
// before the real callback, we reject it and keep listening.
//
// wb-8fhk.22.

use anyhow::{anyhow, Context, Result};
use std::collections::HashMap;
use std::net::{SocketAddr, TcpListener};
use std::time::Duration;
use tiny_http::{Header, Response, Server};

/// The successful payload from a callback hit. `state` should match
/// the value the CLI pushed at PAR time — caller verifies.
#[derive(Debug, Clone)]
pub struct CallbackParams {
    pub code: String,
    pub state: String,
    /// The `iss` parameter the AS echoes back (atproto-specific,
    /// proves which AS just answered). Optional — not all atproto
    /// AS impls return it. Surfaced for callers that want to harden
    /// against a malicious AS substitution; the current orchestrator
    /// trusts the PDS-discovered AS metadata and treats this as
    /// informational.
    #[allow(dead_code)]
    pub iss: Option<String>,
}

/// An AS-issued error redirect — the AS returns
/// `?error=...&error_description=...` instead of `?code=...`.
#[derive(Debug)]
pub struct CallbackError {
    pub error: String,
    pub description: Option<String>,
}

/// Bind a loopback server. `requested_port` of `None` (or `Some(0)`)
/// asks the OS for an ephemeral port — the OAuth `client_id` URL
/// must then be built using the bound port (read via `port()`).
///
/// Why bind FIRST: the `client_id` for the atproto loopback profile
/// embeds the redirect URI, which embeds the port. We can't construct
/// the PAR request until we know what port we got.
pub struct LoopbackServer {
    server: Server,
    port: u16,
}

impl LoopbackServer {
    pub fn bind(requested_port: Option<u16>) -> Result<Self> {
        let port = requested_port.unwrap_or(0);
        let addr: SocketAddr = format!("127.0.0.1:{port}")
            .parse()
            .context("parse loopback bind address")?;

        // Bind via std::net first so we can read the actual port the
        // OS gave us — tiny_http's Server::http takes a string and
        // doesn't surface the bound port nicely.
        let listener = TcpListener::bind(addr).with_context(|| {
            format!("could not bind 127.0.0.1:{port} — already in use?")
        })?;
        let bound = listener
            .local_addr()
            .context("read bound loopback address")?;
        let server = Server::from_listener(listener, None)
            .map_err(|e| anyhow!("tiny_http accept loopback listener: {e}"))?;

        Ok(Self {
            server,
            port: bound.port(),
        })
    }

    /// The port the server is actually bound to. Use this when
    /// constructing the redirect URI / client_id. Public for tests +
    /// future callers that build their own redirect URI shape.
    #[allow(dead_code)]
    pub fn port(&self) -> u16 {
        self.port
    }

    /// The base redirect URI (no query string). Atproto loopback
    /// expects `http://127.0.0.1:<port>/callback`.
    pub fn redirect_uri(&self) -> String {
        format!("http://127.0.0.1:{}/callback", self.port)
    }

    /// Wait up to `timeout` for the OAuth callback. Returns the
    /// callback params (Ok) or the AS error (Err with the AS detail
    /// preserved). Any other path (favicon, port-scanner) is rejected
    /// with 404 and the server keeps listening.
    ///
    /// Blocks the calling thread — call from a tokio `spawn_blocking`
    /// context if the rest of the app must keep running.
    pub fn wait_for_callback(
        self,
        timeout: Duration,
    ) -> Result<std::result::Result<CallbackParams, CallbackError>> {
        let deadline = std::time::Instant::now() + timeout;
        loop {
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            if remaining.is_zero() {
                return Err(anyhow!(
                    "timed out waiting for the OAuth callback after {timeout:?} — \
                     did the browser tab open?"
                ));
            }

            let req = match self.server.recv_timeout(remaining) {
                Ok(Some(r)) => r,
                Ok(None) => continue,
                Err(e) => return Err(anyhow!("loopback accept error: {e}")),
            };

            let url = req.url().to_string();
            // The URL we get is path-relative; tiny_http strips the
            // scheme/host. Parse it as a relative URL.
            let parsed = parse_callback_url(&url);

            match parsed {
                CallbackPath::Callback(params) => {
                    // Always answer the browser before short-circuiting
                    // back to the CLI — leaving the tab hanging is the
                    // worst UX for a CLI auth flow.
                    let body = success_html();
                    let response = Response::from_string(body)
                        .with_header(html_header());
                    let _ = req.respond(response);

                    // Surface either the success or the AS-issued error.
                    if let Some(err) = params.error {
                        return Ok(Err(CallbackError {
                            error: err,
                            description: params.error_description,
                        }));
                    }
                    let code = params.code.ok_or_else(|| {
                        anyhow!("callback URL had neither `code` nor `error` — malformed AS response")
                    })?;
                    let state = params.state.ok_or_else(|| {
                        anyhow!("callback URL missing `state` — possible CSRF; refusing to proceed")
                    })?;
                    return Ok(Ok(CallbackParams {
                        code,
                        state,
                        iss: params.iss,
                    }));
                }
                CallbackPath::Other => {
                    // Probably /favicon.ico from the browser, or a
                    // port-scanner. Return 404 + keep listening.
                    let response = Response::from_string("not found")
                        .with_status_code(404);
                    let _ = req.respond(response);
                    continue;
                }
            }
        }
    }
}

/// Decoded form of an incoming loopback URL. Either it's the
/// `/callback` path (with OAuth params) or it's something else.
pub enum CallbackPath {
    Callback(RawCallback),
    Other,
}

#[derive(Default, Debug)]
pub struct RawCallback {
    pub code: Option<String>,
    pub state: Option<String>,
    pub iss: Option<String>,
    pub error: Option<String>,
    pub error_description: Option<String>,
}

/// Parse the relative URL tiny_http hands us. Pure for testability.
/// Atproto callbacks always come in as `/callback?...`; anything
/// else we treat as noise.
pub fn parse_callback_url(url: &str) -> CallbackPath {
    let (path, query) = match url.split_once('?') {
        Some(t) => t,
        None => (url, ""),
    };

    // Strip any leading `/` and a possible trailing one.
    let path = path.trim_end_matches('/');
    if path != "/callback" {
        return CallbackPath::Other;
    }

    let params = parse_query(query);
    let raw = RawCallback {
        code: params.get("code").cloned(),
        state: params.get("state").cloned(),
        iss: params.get("iss").cloned(),
        error: params.get("error").cloned(),
        error_description: params.get("error_description").cloned(),
    };
    CallbackPath::Callback(raw)
}

/// Decode a query string into a flat map. Standard
/// `key=value&key=value` form with `+` → space and `%XX` decoding.
/// Shared with `cmd::auth`'s broker callback.
pub(crate) fn parse_query(q: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for pair in q.split('&') {
        if pair.is_empty() {
            continue;
        }
        let (k, v) = match pair.split_once('=') {
            Some(t) => t,
            None => (pair, ""),
        };
        out.insert(percent_decode(k), percent_decode(v));
    }
    out
}

/// Minimal percent-decoding — `+` → space, `%XX` → byte. Sufficient
/// for OAuth callback params (we never receive multibyte sequences
/// in `code` / `state`).
fn percent_decode(s: &str) -> String {
    let mut out = Vec::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                let hi = hex_digit(bytes[i + 1]);
                let lo = hex_digit(bytes[i + 2]);
                if let (Some(h), Some(l)) = (hi, lo) {
                    out.push(h * 16 + l);
                    i += 3;
                } else {
                    out.push(bytes[i]);
                    i += 1;
                }
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(10 + b - b'a'),
        b'A'..=b'F' => Some(10 + b - b'A'),
        _ => None,
    }
}

fn html_header() -> Header {
    Header::from_bytes(&b"Content-Type"[..], &b"text/html; charset=utf-8"[..])
        .expect("static header bytes are always valid")
}

fn success_html() -> String {
    // Minimal — no external assets so it renders cleanly even from
    // a totally offline machine that just finished sign-in. The
    // styling is intentionally bare; we're optimising for "tab
    // shows something definitive then the user closes it."
    String::from(
        r#"<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<title>Workbooks — signed in</title>
<style>
  body { font: 15px/1.5 -apple-system, system-ui, sans-serif; color: #111;
         background: #fafafa; margin: 0; padding: 0;
         display: flex; align-items: center; justify-content: center;
         min-height: 100vh; }
  .card { background: white; padding: 32px 40px; border-radius: 8px;
          box-shadow: 0 1px 3px rgba(0,0,0,0.08); max-width: 380px; }
  h1 { font-size: 18px; margin: 0 0 8px; }
  p { margin: 0; color: #555; }
  small { color: #999; display: block; margin-top: 16px; }
</style>
</head>
<body>
  <div class="card">
    <h1>Signed in to Bluesky.</h1>
    <p>You can close this tab and return to your terminal.</p>
    <small>workbooks.sh</small>
  </div>
</body>
</html>"#,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unwrap_callback(p: CallbackPath) -> RawCallback {
        match p {
            CallbackPath::Callback(r) => r,
            CallbackPath::Other => panic!("expected /callback path"),
        }
    }

    #[test]
    fn parse_callback_url_extracts_code_and_state() {
        let raw = unwrap_callback(parse_callback_url(
            "/callback?code=abc123&state=xyz789",
        ));
        assert_eq!(raw.code.as_deref(), Some("abc123"));
        assert_eq!(raw.state.as_deref(), Some("xyz789"));
        assert!(raw.error.is_none());
    }

    #[test]
    fn parse_callback_url_extracts_iss_when_present() {
        let raw = unwrap_callback(parse_callback_url(
            "/callback?code=c&state=s&iss=https%3A%2F%2Fbsky.social",
        ));
        assert_eq!(raw.iss.as_deref(), Some("https://bsky.social"));
    }

    #[test]
    fn parse_callback_url_surfaces_error_payload() {
        let raw = unwrap_callback(parse_callback_url(
            "/callback?error=access_denied&error_description=user%20cancelled",
        ));
        assert_eq!(raw.error.as_deref(), Some("access_denied"));
        assert_eq!(raw.error_description.as_deref(), Some("user cancelled"));
        assert!(raw.code.is_none());
    }

    #[test]
    fn parse_callback_url_rejects_other_paths() {
        assert!(matches!(
            parse_callback_url("/favicon.ico"),
            CallbackPath::Other
        ));
        assert!(matches!(
            parse_callback_url("/"),
            CallbackPath::Other
        ));
        // Trailing slash on /callback is still the callback.
        assert!(matches!(
            parse_callback_url("/callback/?code=c&state=s"),
            CallbackPath::Callback(_)
        ));
    }

    #[test]
    fn percent_decode_handles_common_escapes() {
        assert_eq!(percent_decode("hello%20world"), "hello world");
        assert_eq!(percent_decode("a+b+c"), "a b c");
        assert_eq!(percent_decode("nochange"), "nochange");
        // Invalid % sequence — pass the literal byte through.
        assert_eq!(percent_decode("100%"), "100%");
    }

    #[test]
    fn bound_server_gives_ephemeral_port_when_unset() {
        let s = LoopbackServer::bind(None).expect("bind ephemeral");
        assert!(s.port() > 0);
        let uri = s.redirect_uri();
        assert!(uri.starts_with("http://127.0.0.1:"));
        assert!(uri.ends_with("/callback"));
    }

    #[test]
    fn integration_callback_is_received_and_parsed() {
        // End-to-end: bind, hit /callback in a thread, assert the
        // server returns the parsed params and answered the browser
        // with 200 + the success HTML.
        let server = LoopbackServer::bind(None).expect("bind");
        let port = server.port();

        let client = std::thread::spawn(move || {
            // Hit the loopback in a separate thread so the server can
            // recv it. Sleep briefly to ensure the server's polling
            // loop is up.
            std::thread::sleep(std::time::Duration::from_millis(50));
            let url = format!(
                "http://127.0.0.1:{port}/callback?code=THE_CODE&state=THE_STATE"
            );
            let resp = reqwest::blocking::Client::builder()
                .timeout(std::time::Duration::from_secs(2))
                .build()
                .unwrap()
                .get(&url)
                .send()
                .unwrap();
            assert_eq!(resp.status(), 200);
            let body = resp.text().unwrap();
            assert!(body.contains("Signed in to Bluesky"));
        });

        let res = server.wait_for_callback(std::time::Duration::from_secs(3));
        client.join().unwrap();

        let params = res.expect("server returned").expect("not an AS error");
        assert_eq!(params.code, "THE_CODE");
        assert_eq!(params.state, "THE_STATE");
        assert!(params.iss.is_none());
    }
}
