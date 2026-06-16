// The OAuth dance — public entry point.
//
// `login(...)` orchestrates: discover → mint keys → PAR → browser →
// callback → token-exchange → POST to engine. Each substep lives in
// its own module; this file is the glue + the side-effects (opens a
// browser, prints to stdout, blocks on the loopback server).
//
// wb-8fhk.22.

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use rand::RngCore;
use reqwest::Client as HttpClient;
use serde::Deserialize;
use serde_json::{json, Value};
use std::time::Duration;

use super::{
    discover::{self, AsMetadata},
    dpop::DpopKey,
    pkce::Pkce,
    server::LoopbackServer,
};
use crate::daemon::Client as DaemonClient;

const SCOPE: &str = "atproto transition:generic";
const CALLBACK_TIMEOUT: Duration = Duration::from_secs(5 * 60);

/// Caller-side knobs for the OAuth flow. Default `LoginOpts::default()`
/// is the human-CLI path (auto-open browser, human-prose output).
/// Set `no_open` + `json` when an agent (Claude Code, a CI runner) is
/// driving — see the `--no-open` and `--json` clap flags on the
/// `IdentityCmd::BlueskyOauthLogin` variant.
#[derive(Debug, Clone, Copy, Default)]
pub struct LoginOpts {
    /// Skip `webbrowser::open`; just print the auth URL to stdout and
    /// wait for the callback. Lets the agent show the URL with its own
    /// framing, or run on a machine without a graphical browser.
    pub no_open: bool,
    /// Emit progress events as JSON lines (one object per line) to
    /// stdout. Stderr stays for diagnostics. Final event has `"event":
    /// "bound"` on success or `"event": "error"` with `"reason"`.
    pub json: bool,
    /// Persist directly to the canonical on-disk location instead of
    /// POSTing to a running engine. The file format matches what the
    /// engine writes, so this is zero-migration if an engine starts
    /// up later. Lets the OAuth path work in "I just want to post
    /// publicly" scenarios where the runtime engine isn't running
    /// (or isn't installed). wb-8fhk.29.
    pub standalone: bool,
}

/// Run the full OAuth dance. Blocks until the user finishes (or
/// cancels) the consent flow in their browser, then posts the
/// resulting bundle to the engine.
pub async fn login(
    handle: Option<&str>,
    pds_url: Option<&str>,
    requested_port: Option<u16>,
    opts: LoginOpts,
) -> Result<()> {
    // 1. Resolve the PDS URL. Explicit --pds-url wins; otherwise
    //    try to resolve via the handle; otherwise fall back to
    //    bsky.social.
    let pds = match (pds_url, handle) {
        (Some(u), _) => u.to_string(),
        (None, Some(h)) => discover::resolve_pds(h)
            .await
            .with_context(|| format!("resolve PDS for @{h}"))?,
        (None, None) => discover::default_pds().to_string(),
    };
    eprintln!("→ PDS: {pds}");

    // 2. Fetch AS metadata.
    let meta = discover::fetch_as_metadata(&pds)
        .await
        .with_context(|| format!("fetch OAuth metadata from {pds}"))?;

    // 3. Bind the loopback server FIRST — we need its port for the
    //    client_id / redirect_uri.
    let server = LoopbackServer::bind(requested_port)
        .context("bind loopback callback server")?;
    let redirect_uri = server.redirect_uri();
    let client_id = build_client_id(&redirect_uri, SCOPE);
    eprintln!("→ Loopback callback: {redirect_uri}");

    // 4. Mint DPoP keypair + PKCE pair + state.
    let dpop = DpopKey::generate();
    let pkce = Pkce::generate();
    let state = random_state();

    // 5. PAR — push the authorization request to the AS.
    let http = HttpClient::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .context("build oauth http client")?;
    let par_result = push_authorization_request(
        &http,
        &meta,
        &dpop,
        &client_id,
        &redirect_uri,
        &pkce,
        &state,
        handle,
    )
    .await?;

    // 6. Browser open. We do this AFTER PAR — failing fast on PAR
    //    means the user doesn't get a hung browser tab when their
    //    PDS is misconfigured.
    let auth_url = format!(
        "{}?client_id={}&request_uri={}",
        meta.authorization_endpoint,
        url_encode(&client_id),
        url_encode(&par_result.request_uri),
    );
    if opts.json {
        emit_json_event(&serde_json::json!({
            "event": "auth_url",
            "url": auth_url,
            "redirect_uri": redirect_uri,
            "auto_open": !opts.no_open,
        }));
    } else {
        eprintln!();
        if opts.no_open {
            eprintln!("→ Open this URL in your browser to sign in to Bluesky:");
            eprintln!("    {auth_url}");
        } else {
            eprintln!("→ Opening browser for Bluesky sign-in…");
            eprintln!("  If it doesn't open, visit: {auth_url}");
        }
        eprintln!();
    }

    if !opts.no_open {
        if let Err(e) = webbrowser::open(&auth_url) {
            // Don't error — the URL is printed above; the user can paste
            // it. But surface the open() failure for diagnostics.
            if opts.json {
                emit_json_event(&serde_json::json!({
                    "event": "browser_open_failed",
                    "error": e.to_string(),
                }));
            } else {
                eprintln!("  (browser-open failed: {e}; please open the URL manually)");
            }
        }
    }

    if opts.json {
        emit_json_event(&serde_json::json!({
            "event": "awaiting_callback",
            "timeout_secs": CALLBACK_TIMEOUT.as_secs(),
        }));
    }

    // 7. Wait for the callback.
    let cb_result = tokio::task::spawn_blocking(move || {
        server.wait_for_callback(CALLBACK_TIMEOUT)
    })
    .await
    .context("loopback server task panicked")??;

    let cb = match cb_result {
        Ok(p) => p,
        Err(err) => {
            return Err(anyhow!(
                "Bluesky returned an OAuth error: {} ({})",
                err.error,
                err.description.unwrap_or_else(|| "no detail".into())
            ));
        }
    };

    if cb.state != state {
        return Err(anyhow!(
            "callback state mismatch — possible CSRF; refusing to proceed. \
             expected {state:?}, got {:?}",
            cb.state
        ));
    }

    if opts.json {
        emit_json_event(&serde_json::json!({"event": "code_received"}));
    }

    // 8. Exchange the code for tokens.
    if !opts.json {
        eprintln!("→ Exchanging code for tokens…");
    }
    let tokens = exchange_code(
        &http,
        &meta,
        &dpop,
        &client_id,
        &redirect_uri,
        &pkce,
        &cb.code,
        par_result.dpop_nonce.as_deref(),
    )
    .await?;

    // 9. Persist the bundle. Two paths:
    //
    //    a. Engine mode (default) — POST to /api/network/atproto/oauth-bind.
    //       The engine persists, and from then on DPoP-wraps every
    //       atproto request via Network.Atproto.
    //
    //    b. Standalone mode (--standalone, wb-8fhk.29) — write directly
    //       to <data_root>/Engine/network/identity/{binding,bluesky_session}.json
    //       using the same shape Network.Identity.bind_bluesky writes.
    //       For users who just want to publish public atproto records and
    //       don't have/want the runtime engine running. Zero migration —
    //       if the engine later starts up, it reads the same files.
    let dpop_pem = dpop.to_pkcs8_pem()?;

    // wb-8fhk.22.1: backfill the canonical handle if token-exchange
    // didn't carry one. describeRepo is a public read, no auth needed.
    // Use the resolved data PDS (not the AS host), since the OAuth
    // `pds` value may be the AS-only `bsky.social`.
    let handle = match tokens.handle.clone() {
        Some(h) if !h.is_empty() => h,
        _ => {
            let data_pds = if pds.contains("bsky.social") {
                crate::cmd::bluesky_oauth::discover::resolve_pds_from_did(&tokens.sub)
                    .await
                    .unwrap_or_else(|_| pds.clone())
            } else {
                pds.clone()
            };
            crate::cmd::atproto::publish::describe_repo_handle(&data_pds, &tokens.sub)
                .await
                .unwrap_or_default()
        }
    };

    if opts.standalone {
        if !opts.json {
            eprintln!("→ Persisting to local identity store (standalone — no engine)…");
        }
        persist_standalone(
            tokens.sub.as_str(),
            &handle,
            &tokens.access_token,
            tokens.refresh_token.as_deref().unwrap_or(""),
            &dpop_pem,
            &pds,
            &meta.token_endpoint,
            &client_id,
        )?;
    } else {
        if !opts.json {
            eprintln!("→ Binding to engine…");
        }
        let daemon = DaemonClient::connect()?;
        let body = json!({
            "handle": handle,
            "did": tokens.sub,
            "access_jwt": tokens.access_token,
            "refresh_jwt": tokens.refresh_token,
            "dpop_key_pem": dpop_pem,
            "pds_url": pds,
        });
        let resp: Value = daemon
            .post_json("/api/network/atproto/oauth-bind", &body)
            .await?;
        if resp.get("ok").and_then(Value::as_bool) != Some(true) {
            return Err(anyhow!(
                "engine rejected the OAuth bind: {}",
                resp.get("detail").and_then(Value::as_str).unwrap_or("(no detail)")
            ));
        }
    }

    let did = tokens.sub.as_str();
    let handle_display = if handle.is_empty() { "?" } else { handle.as_str() };

    if opts.json {
        emit_json_event(&serde_json::json!({
            "event": "bound",
            "did": did,
            "handle": handle_display,
            "auth_kind": "oauth",
            "pds_url": pds,
        }));
    } else {
        println!();
        println!("✓ bound to Bluesky via OAuth");
        println!("  handle:    @{handle_display}");
        println!("  did:       {did}");
        println!("  auth kind: oauth (DPoP-bound)");
        println!();
        println!("The engine will now DPoP-wrap every atproto request.");
        println!("Forget the binding any time with: wb identity bluesky-logout");
    }

    Ok(())
}

// Print one JSON event on its own line to stdout. Newline-delimited so
// agent callers can read line-by-line and parse each as a complete
// object. Stderr stays for non-JSON diagnostics that don't fit the
// event stream.
fn emit_json_event(value: &serde_json::Value) {
    println!("{value}");
    use std::io::Write;
    let _ = std::io::stdout().flush();
}

// wb-8fhk.29 — write the OAuth bundle directly to the canonical engine
// storage location. Same files Network.Identity.bind_bluesky writes,
// same field names — zero migration when an engine later starts up.
//
// binding.json — public surface, holds DID + handle (no JWTs).
// bluesky_session.json — mode 0600, holds the access/refresh JWTs +
//                        DPoP private-key PEM + auth_kind + pds_url.
fn persist_standalone(
    did: &str,
    handle: &str,
    access_jwt: &str,
    refresh_jwt: &str,
    dpop_key_pem: &str,
    pds_url: &str,
    token_endpoint: &str,
    client_id: &str,
) -> Result<()> {
    let id_dir = identity_dir()?;
    std::fs::create_dir_all(&id_dir)
        .with_context(|| format!("creating {}", id_dir.display()))?;

    // binding.json — MERGE with existing (don't clobber other keys like
    // the engine's did:key or WorkOS binding if they're already there).
    let binding_path = id_dir.join("binding.json");
    let mut binding: serde_json::Map<String, Value> = if binding_path.exists() {
        let bytes = std::fs::read(&binding_path)
            .with_context(|| format!("reading {}", binding_path.display()))?;
        serde_json::from_slice(&bytes).unwrap_or_default()
    } else {
        serde_json::Map::new()
    };
    binding.insert("bluesky_did".into(), Value::String(did.into()));
    binding.insert("bluesky_handle".into(), Value::String(handle.into()));
    std::fs::write(
        &binding_path,
        serde_json::to_string(&Value::Object(binding))? + "\n",
    )
    .with_context(|| format!("writing {}", binding_path.display()))?;

    // bluesky_session.json — mode 0600 (it holds the keypair + JWTs).
    let session_path = id_dir.join("bluesky_session.json");
    let session = json!({
        "did": did,
        "handle": handle,
        "access_jwt": access_jwt,
        "refresh_jwt": refresh_jwt,
        "auth_kind": "oauth",
        "dpop_key_pem": dpop_key_pem,
        "pds_url": pds_url,
        "token_endpoint": token_endpoint,
        "client_id": client_id,
    });
    std::fs::write(&session_path, serde_json::to_string(&session)?)
        .with_context(|| format!("writing {}", session_path.display()))?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&session_path)?.permissions();
        perms.set_mode(0o600);
        let _ = std::fs::set_permissions(&session_path, perms);
    }

    Ok(())
}

fn identity_dir() -> Result<std::path::PathBuf> {
    let root = match std::env::var("WB_DATA_ROOT") {
        Ok(p) if !p.is_empty() => std::path::PathBuf::from(p),
        _ => {
            let home = dirs::home_dir().ok_or_else(|| anyhow!("no home directory"))?;
            home.join("Workbooks")
        }
    };
    Ok(root.join("Engine").join("network").join("identity"))
}

// ── PAR ──────────────────────────────────────────────────────────

#[derive(Debug)]
struct ParResult {
    request_uri: String,
    /// Atproto AS issues a per-client nonce in the PAR response that
    /// MUST be echoed in subsequent DPoP proofs (token-exchange).
    /// `None` for AS impls that don't use rolling nonces.
    dpop_nonce: Option<String>,
}

async fn push_authorization_request(
    http: &HttpClient,
    meta: &AsMetadata,
    dpop: &DpopKey,
    client_id: &str,
    redirect_uri: &str,
    pkce: &Pkce,
    state: &str,
    login_hint: Option<&str>,
) -> Result<ParResult> {
    // PAR uses form-encoded body, not JSON. The AS's nonce challenge
    // means we might have to retry once with the new nonce.
    let mut nonce: Option<String> = None;
    for _attempt in 0..2 {
        let proof = dpop
            .proof("POST", &meta.pushed_authorization_request_endpoint, None, nonce.as_deref())
            .context("mint DPoP proof for PAR")?;

        let mut form: Vec<(&str, String)> = vec![
            ("client_id", client_id.to_string()),
            ("redirect_uri", redirect_uri.to_string()),
            ("response_type", "code".to_string()),
            ("scope", SCOPE.to_string()),
            ("state", state.to_string()),
            ("code_challenge", pkce.challenge.clone()),
            ("code_challenge_method", Pkce::method().to_string()),
        ];
        if let Some(h) = login_hint {
            form.push(("login_hint", h.trim_start_matches('@').to_string()));
        }

        let resp = http
            .post(&meta.pushed_authorization_request_endpoint)
            .header("DPoP", proof)
            .form(&form)
            .send()
            .await
            .context("POST PAR")?;

        // The AS may answer 4xx with a `DPoP-Nonce` header; we retry
        // exactly once with the new nonce.
        if !resp.status().is_success() {
            if let Some(new_nonce) = resp.headers().get("dpop-nonce").and_then(|v| v.to_str().ok()) {
                if nonce.as_deref() != Some(new_nonce) {
                    nonce = Some(new_nonce.to_string());
                    continue;
                }
            }
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!("PAR failed ({status}): {text}"));
        }

        // Stash the nonce (if any) for the token-exchange step.
        let returned_nonce = resp
            .headers()
            .get("dpop-nonce")
            .and_then(|v| v.to_str().ok())
            .map(String::from);

        #[derive(Deserialize)]
        struct ParResp {
            request_uri: String,
        }
        let body: ParResp = resp.json().await.context("parse PAR response")?;
        return Ok(ParResult {
            request_uri: body.request_uri,
            dpop_nonce: returned_nonce.or(nonce),
        });
    }
    Err(anyhow!("PAR retried twice with nonce challenges; giving up"))
}

// ── Token exchange ───────────────────────────────────────────────

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    refresh_token: Option<String>,
    /// `sub` is the DID — atproto AS always returns it.
    sub: String,
    /// `handle` isn't standard OAuth but atproto's AS includes it as
    /// a convenience so the CLI doesn't have to do a second
    /// resolveHandle round trip.
    #[serde(default)]
    handle: Option<String>,
}

async fn exchange_code(
    http: &HttpClient,
    meta: &AsMetadata,
    dpop: &DpopKey,
    client_id: &str,
    redirect_uri: &str,
    pkce: &Pkce,
    code: &str,
    nonce_from_par: Option<&str>,
) -> Result<TokenResponse> {
    let mut nonce: Option<String> = nonce_from_par.map(String::from);
    for _attempt in 0..2 {
        let proof = dpop
            .proof("POST", &meta.token_endpoint, None, nonce.as_deref())
            .context("mint DPoP proof for token exchange")?;

        let form = vec![
            ("grant_type", "authorization_code".to_string()),
            ("code", code.to_string()),
            ("redirect_uri", redirect_uri.to_string()),
            ("client_id", client_id.to_string()),
            ("code_verifier", pkce.verifier.clone()),
        ];

        let resp = http
            .post(&meta.token_endpoint)
            .header("DPoP", proof)
            .form(&form)
            .send()
            .await
            .context("POST token endpoint")?;

        if !resp.status().is_success() {
            if let Some(new_nonce) = resp.headers().get("dpop-nonce").and_then(|v| v.to_str().ok()) {
                if nonce.as_deref() != Some(new_nonce) {
                    nonce = Some(new_nonce.to_string());
                    continue;
                }
            }
            let status = resp.status();
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!("token exchange failed ({status}): {text}"));
        }

        let body: TokenResponse = resp.json().await.context("parse token response")?;
        if body.refresh_token.is_none() {
            // Atproto always issues refresh tokens for OAuth grants;
            // an absent one means a misconfigured AS. Warn but accept.
            eprintln!(
                "  (warning: AS did not issue a refresh_token; \
                 sessions will not auto-refresh)"
            );
        }
        return Ok(body);
    }
    Err(anyhow!("token exchange retried twice with nonce challenges; giving up"))
}

// ── Helpers ──────────────────────────────────────────────────────

/// Atproto loopback profile (https://atproto.com/specs/oauth §8.5):
/// `client_id` is `http://localhost/?redirect_uri=...&scope=...`. The
/// AS parses the query params back out and treats them as the
/// effective client metadata. No publicly-resolvable client document
/// required for dev.
pub fn build_client_id(redirect_uri: &str, scope: &str) -> String {
    format!(
        "http://localhost/?redirect_uri={}&scope={}",
        url_encode(redirect_uri),
        url_encode(scope),
    )
}

/// Cryptographically-random `state` parameter — 32 bytes of entropy
/// rendered as unpadded base64url.
fn random_state() -> String {
    let mut buf = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut buf);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(buf)
}

fn url_encode(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn build_client_id_uses_atproto_loopback_form() {
        let id = build_client_id("http://127.0.0.1:54321/callback", "atproto transition:generic");
        // The exact bytes the AS will hash + compare against the
        // redirect we send at PAR time. If this drifts, every login
        // 400s.
        assert!(id.starts_with("http://localhost/?redirect_uri="));
        assert!(id.contains("redirect_uri=http%3A%2F%2F127%2E0%2E0%2E1%3A54321%2Fcallback"));
        assert!(id.contains("&scope=atproto%20transition%3Ageneric"));
    }

    #[test]
    fn random_state_is_unique_and_url_safe() {
        let a = random_state();
        let b = random_state();
        assert_ne!(a, b);
        assert!(a.len() >= 40, "32-byte entropy → at least 40 url-safe chars");
        for c in a.chars() {
            assert!(
                c.is_ascii_alphanumeric() || c == '-' || c == '_',
                "non url-safe char in state: {c:?}"
            );
        }
    }

    #[test]
    fn scope_is_atproto_transition_generic() {
        // This scope is what gives the OAuth token the right to call
        // every `com.atproto.*` endpoint. Narrower scopes are an
        // atproto roadmap item; for now it's all-or-nothing.
        assert_eq!(SCOPE, "atproto transition:generic");
    }
}
