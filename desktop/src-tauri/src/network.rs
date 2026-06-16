// Workbooks Network — local identity + WorkOS sign-in + workspace packaging.
// All local-first: the ed25519 signing key lives in the OS keychain, only the
// public material + metadata hit identity.json. WorkOS sign-in is the RFC-8252
// loopback + PKCE flow; the resulting session bearer is stashed in the keychain.

use base64::Engine as _;
use ed25519_dalek::SigningKey;
use keyring::Entry;
use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::PathBuf;

const KC_SERVICE: &str = "sh.workbooks.identity";
const KC_IDENTITY_SK: &str = "identity_sk";
const KC_WORKOS_SESSION: &str = "workos_session";

fn identity_path() -> PathBuf {
    crate::paths::app_data_dir().join("identity.json")
}

#[derive(Serialize, Deserialize, Clone)]
pub struct IdentityView {
    pub did: String,
    pub handle: Option<String>,
    pub workos_user_id: Option<String>,
    pub public_key_b64: String,
}

fn load_identity_file() -> Option<IdentityView> {
    let body = std::fs::read_to_string(identity_path()).ok()?;
    serde_json::from_str(&body).ok()
}

fn write_identity_file(id: &IdentityView) -> Result<(), String> {
    crate::paths::write_json(&identity_path(), id)
}

/// did:key for an ed25519 public key: multicodec 0xED 0x01 prefix, base58btc
/// multibase ('z' prefix).
fn did_key(pubkey: &[u8]) -> String {
    let mut bytes = vec![0xed, 0x01];
    bytes.extend_from_slice(pubkey);
    format!("did:key:z{}", bs58::encode(bytes).into_string())
}

#[tauri::command]
pub fn identity_load() -> Option<IdentityView> {
    load_identity_file()
}

#[tauri::command]
pub fn identity_generate(
    handle: Option<String>,
    workos_user_id: Option<String>,
) -> Result<IdentityView, String> {
    // Idempotent: an existing identity is returned untouched.
    if let Some(existing) = load_identity_file() {
        return Ok(existing);
    }
    let mut csprng = rand_core::OsRng;
    let signing = SigningKey::generate(&mut csprng);
    let verifying = signing.verifying_key();
    let pubkey = verifying.to_bytes();

    // Private key → keychain; public material + meta → identity.json.
    let sk_b64 = base64::engine::general_purpose::STANDARD.encode(signing.to_bytes());
    Entry::new(KC_SERVICE, KC_IDENTITY_SK)
        .map_err(|e| e.to_string())?
        .set_password(&sk_b64)
        .map_err(|e| e.to_string())?;

    let view = IdentityView {
        did: did_key(&pubkey),
        handle,
        workos_user_id,
        public_key_b64: base64::engine::general_purpose::STANDARD.encode(pubkey),
    };
    write_identity_file(&view)?;
    Ok(view)
}

#[tauri::command]
pub fn identity_set_handle(handle: String) -> Result<IdentityView, String> {
    let mut id = load_identity_file().ok_or("no identity minted yet")?;
    id.handle = Some(handle);
    write_identity_file(&id)?;
    Ok(id)
}

#[tauri::command]
pub fn identity_set_workos(workos_user_id: Option<String>) -> Result<IdentityView, String> {
    let mut id = load_identity_file().ok_or("no identity minted yet")?;
    id.workos_user_id = workos_user_id;
    write_identity_file(&id)?;
    Ok(id)
}

/// Load the ed25519 signing key from the keychain. Retained for the identity
/// key lifecycle; workspace packaging now signs tenant-side on the engine
/// (C2PA manifest), so this no longer participates in egress.
#[allow(dead_code)]
fn load_signing_key() -> Result<SigningKey, String> {
    let b64 = Entry::new(KC_SERVICE, KC_IDENTITY_SK)
        .map_err(|e| e.to_string())?
        .get_password()
        .map_err(|e| e.to_string())?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(b64.as_bytes())
        .map_err(|e| e.to_string())?;
    let arr: [u8; 32] = bytes
        .try_into()
        .map_err(|_| "identity key wrong length".to_string())?;
    Ok(SigningKey::from_bytes(&arr))
}

/// Package a workspace into a single self-contained, tenant-signed `.html` and
/// write it under app_data/packages/<ws>.html.
///
/// De-Tauri'd (WORKBOOK-BUNDLE.md): this used to render the org locally and
/// append a bespoke `<!-- wb-signature -->` comment, producing a `.html` with NO
/// embedded filesystem and a signature format nothing else understood — drift
/// from the CLI/runtime egress. Now the desktop is a pure caller: it gathers the
/// workspace tree (file IO only) and ships it to the engine's `/rcp/bundle`
/// (`sign=1`), which does the canonical `Workbooks.Bundle.pack` + `embed` +
/// `embed_loader` + `Workbooks.Manifest.sign`. The result is byte-identical to
/// what `wb bundle` + a tenant sign produce — ONE egress format, ONE bundler,
/// ONE signature scheme (C2PA manifest, not an ad-hoc comment). The host
/// keychain ed25519 key is no longer used here; provenance is tenant-signed by
/// the engine via `Workbooks.Git`.
#[tauri::command]
pub fn workspace_package(workspace_name: String) -> Result<String, String> {
    let pkg = crate::packages::package_load(workspace_name.clone())?;

    // Gather every workspace folder's tree into one parts map (file IO only —
    // no bundling here). Later folders win on a key collision.
    let mut files = std::collections::BTreeMap::new();
    for folder in &pkg.folders {
        for (k, v) in crate::bundle_io::read_tree_map(folder)? {
            files.insert(k, v);
        }
    }

    // The engine bundles + signs (the canonical path). Requires a running
    // runtime: signing is tenant-scoped on the engine, so there's no offline
    // equivalent — same as publish().
    let html = bundle_via_runtime(&files, true)?;

    let out_dir = crate::paths::ensure_dir(crate::paths::app_data_dir().join("packages"))
        .map_err(|e| e.to_string())?;
    let out = out_dir.join(format!("{workspace_name}.html"));
    std::fs::write(&out, html).map_err(|e| e.to_string())?;
    Ok(out.to_string_lossy().to_string())
}

/// POST a parts map to the engine's `/rcp/bundle` and return the self-contained
/// `.html`. The desktop owns NO bundler — `Workbooks.Bundle` on the engine does
/// the zip/embed/loader/sign. `sign=1` ⇒ the engine tenant-signs via
/// `Workbooks.Manifest`. Errors when no runtime is discovered (no offline path
/// for a tenant-signed egress, mirroring publish()).
fn bundle_via_runtime(
    files: &std::collections::BTreeMap<String, String>,
    sign: bool,
) -> Result<String, String> {
    let d = crate::daemon::Discovery::read()
        .ok_or("The agent server isn't running — start it to package a workspace.")?;
    let url = format!(
        "{}://{}:{}/rcp/bundle{}",
        d.scheme,
        d.host,
        d.port,
        if sign { "?sign=1" } else { "" }
    );
    let resp = reqwest::blocking::Client::new()
        .post(&url)
        .bearer_auth(&d.token)
        .json(&serde_json::json!({ "files": files }))
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("engine bundle failed: {}", resp.status()));
    }
    let body: serde_json::Value = resp.json().map_err(|e| e.to_string())?;
    if let Some(err) = body.get("error").and_then(|v| v.as_str()) {
        return Err(err.to_string());
    }
    let html_b64 = body
        .get("html_b64")
        .and_then(|v| v.as_str())
        .ok_or("engine bundle: no html in response")?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(html_b64.as_bytes())
        .map_err(|e| e.to_string())?;
    String::from_utf8(bytes).map_err(|e| e.to_string())
}

// ── WorkOS sign-in (RFC 8252 loopback + PKCE) ─────────────────────

#[derive(Serialize, Deserialize, Clone)]
pub struct StoredSession {
    pub bearer: String,
    pub expires_at: u64,
    pub sub: String,
    pub email: String,
    pub email_verified: bool,
    pub organization_id: Option<String>,
    pub display_name: Option<String>,
    pub picture_url: Option<String>,
}

fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// Generate a PKCE verifier + its S256 challenge.
fn pkce() -> (String, String) {
    use rand_core::RngCore;
    let mut raw = [0u8; 32];
    rand_core::OsRng.fill_bytes(&mut raw);
    let verifier = b64url(&raw);
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(verifier.as_bytes());
    let challenge = b64url(&digest);
    (verifier, challenge)
}

/// Drive the loopback sign-in: open the browser to the broker's authorize URL
/// (redirecting to our ephemeral localhost server), capture the `code`, then
/// exchange it for a session bearer. The session is stashed in the keychain.
// The branded page shown in the browser tab once the loopback catches the code — on
// brand (paper, logo, pastel DNA edge) and self-closing, instead of a bare line of text.
const SIGNED_IN_HTML: &str = r##"<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Signed in · Workbooks</title>
<style>html,body{margin:0;height:100%}body{display:grid;place-items:center;background:#faf8f1;color:#121316;
font-family:ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;overflow:hidden}
.card{text-align:center;padding:40px;animation:rise .5s cubic-bezier(.22,1,.36,1) both}
.mark{width:64px;height:64px;margin:0 auto 22px;border-radius:16px;box-shadow:0 1px 2px rgba(18,19,22,.06),0 14px 34px rgba(18,19,22,.16)}
h1{font-size:1.6rem;font-weight:600;letter-spacing:-.02em;margin:0 0 8px}
p{margin:0;color:rgba(18,19,22,.6);font-size:.95rem}
.dna{position:fixed;left:0;right:0;bottom:0;height:12px;display:flex}.dna i{flex:1}
@keyframes rise{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}</style></head>
<body><div class="card"><svg class="mark" viewBox="0 0 320 320" xmlns="http://www.w3.org/2000/svg">
<rect width="320" height="320" rx="72" fill="#121316"/><path transform="translate(70 108) scale(1.586)" fill="#f7f6f1"
d="M48.271 0.137041C54.0348 -0.0424459 59.4862 -0.100239 65.2392 0.307556C65.5299 10.0796 65.1746 19.9621 65.4617 29.7381C65.4868 30.5677 65.8708 31.142 66.3912 31.7433C72.1083 33.4642 84.7519 13.8452 90.9211 11.7402C93.9071 12.344 100.087 19.9987 102.273 22.457C98.7305 28.4167 83.2732 40.6907 81.3819 45.0034C81.3999 46.2868 81.4501 46.3256 82.1571 47.442C83.7075 48.637 108.252 47.9876 113.133 48.4643C113.57 53.985 113.431 59.865 113.391 65.4284C101.67 65.4485 86.6791 66.781 76.4724 61.6904C68.0493 57.5274 61.6503 50.1601 58.7039 41.2382C57.9394 38.5857 57.3868 36.1501 56.7802 33.4675C55.5995 38.7002 54.6772 42.9878 51.9209 47.7051C39.8045 68.4416 20.2283 65.4557 0.0653694 65.3889C-0.0584465 59.646 -0.00641725 53.9006 0.221835 48.1606C5.51182 48.1355 28.4253 48.7415 31.6987 47.27C31.862 46.8967 31.9051 46.8482 31.9866 46.4038C32.6717 42.6809 14.5579 27.3487 11.6183 22.8379L11.3728 22.4563C13.1769 19.9072 19.3469 13.0734 22.063 11.7735C25.7911 11.2107 40.0016 29.8303 44.4561 31.6887C45.845 32.2681 46.0675 32.2311 47.2913 31.7505C48.6658 29.7977 48.2064 22.821 48.2172 20.1527L48.271 0.137041Z"/></svg>
<h1>You're signed in</h1><p>You can close this tab and head back to Workbooks.</p></div>
<div class="dna" aria-hidden="true"><i style="background:#f3c5a3"></i><i style="background:#aee5c2"></i><i style="background:#a8d4f0"></i><i style="background:#f2ddb0"></i><i style="background:#aee5c2"></i><i style="background:#a8d4f0"></i><i style="background:#f3c5a3"></i><i style="background:#d4c9f0"></i></div>
<script>setTimeout(function(){window.close()},2000)</script></body></html>"##;

#[tauri::command]
pub fn workos_sign_in(
    app: tauri::AppHandle,
    broker_url: String,
    organization_id: Option<String>,
) -> Result<StoredSession, String> {
    let server = tiny_http::Server::http("127.0.0.1:0").map_err(|e| e.to_string())?;
    let port = match server.server_addr() {
        tiny_http::ListenAddr::IP(addr) => addr.port(),
        _ => return Err("could not bind loopback".into()),
    };
    let redirect = format!("http://127.0.0.1:{port}/cb");
    let (verifier, challenge) = pkce();

    let mut authorize = format!(
        "{}/v1/auth/authorize?response_type=code&redirect_uri={}&code_challenge={}&code_challenge_method=S256",
        broker_url.trim_end_matches('/'),
        urlencode(&redirect),
        challenge,
    );
    // Scope the sign-in to a specific org (the org switcher); omitted for personal.
    if let Some(org) = organization_id.as_deref().filter(|o| !o.is_empty()) {
        authorize.push_str(&format!("&organization_id={}", urlencode(org)));
    }
    open::that(&authorize).map_err(|e| e.to_string())?;

    // Block for the redirect carrying ?code=… (single request).
    let request = server.recv().map_err(|e| e.to_string())?;
    let url = request.url().to_string();
    let code = parse_query(&url, "code").ok_or("no authorization code in callback")?;
    let _ = request.respond(
        tiny_http::Response::from_string(SIGNED_IN_HTML).with_header(
            tiny_http::Header::from_bytes(&b"Content-Type"[..], &b"text/html; charset=utf-8"[..])
                .unwrap(),
        ),
    );

    // Exchange the code for a session.
    let client = reqwest::blocking::Client::new();
    let resp = client
        .post(format!(
            "{}/v1/auth/exchange",
            broker_url.trim_end_matches('/')
        ))
        .json(&serde_json::json!({
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirect,
        }))
        .send()
        .map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("broker exchange failed: {}", resp.status()));
    }
    let session: StoredSession = resp.json().map_err(|e| e.to_string())?;

    let body = serde_json::to_string(&session).map_err(|e| e.to_string())?;
    Entry::new(KC_SERVICE, KC_WORKOS_SESSION)
        .map_err(|e| e.to_string())?
        .set_password(&body)
        .map_err(|e| e.to_string())?;

    // Bring the app back to the front — the user just finished signing in the browser.
    {
        use tauri::Manager;
        if let Some(w) = app.webview_windows().values().next() {
            let _ = w.set_focus();
        }
    }
    Ok(session)
}

#[tauri::command]
pub fn workos_load_session() -> Option<StoredSession> {
    let body = Entry::new(KC_SERVICE, KC_WORKOS_SESSION)
        .ok()?
        .get_password()
        .ok()?;
    let session: StoredSession = serde_json::from_str(&body).ok()?;
    // Treat an expired session as signed-out.
    if session.expires_at != 0 && session.expires_at < crate::paths::now_ms() / 1000 {
        return None;
    }
    Some(session)
}

#[tauri::command]
pub fn workos_clear_session() -> Result<(), String> {
    match Entry::new(KC_SERVICE, KC_WORKOS_SESSION)
        .map_err(|e| e.to_string())?
        .delete_credential()
    {
        Ok(_) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}

// ── tiny URL helpers (avoid a url crate dep) ──────────────────────

fn urlencode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

fn parse_query(url: &str, key: &str) -> Option<String> {
    let q = url.split_once('?')?.1;
    for pair in q.split('&') {
        if let Some((k, v)) = pair.split_once('=') {
            if k == key {
                return Some(urldecode(v));
            }
        }
    }
    None
}

fn urldecode(s: &str) -> String {
    let mut out = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                if let Ok(b) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    out.push(b);
                    i += 3;
                    continue;
                }
                out.push(bytes[i]);
                i += 1;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).to_string()
}

// ── Harness OAuth loopback (SLICE 3, wb-b9xv.7) ─────────────────────────────────────────────────
//
// `dock.oauth.loopback` — the GENERALIZATION of `workos_sign_in` into a provider-agnostic, PKCE-LESS
// primitive the in-wasm harness drives. The runtime relays the harness's request here over the desktop
// bridge; this opens the USER'S OWN BROWSER (their session, their IP — the BYO/no-pool core) to the
// harness-supplied authorize URL, captures the loopback `?code=`, and returns it.
//
// REUSED VERBATIM from workos_sign_in: the tiny_http 127.0.0.1:0 bind, the ephemeral-port read, the
// `open::that(authorize)`, and the single-request `server.recv()` for the redirect.
// DELETED vs workos_sign_in (the two map-mandated changes):
//   1. PKCE — no `pkce()` call here. The HARNESS makes the verifier + S256 challenge in WebCrypto and
//      sends only the CHALLENGE, so the verifier NEVER crosses the membrane. We just substitute the real
//      redirect_uri and forward the harness's `code_challenge`.
//   2. TOKEN EXCHANGE — no POST /v1/auth/exchange, no StoredSession parse. We END at returning the code;
//      the token exchange (and refresh) is the harness's own fetch through NetGuard (path c), so the
//      bearer is direct user→provider and this command stays provider-neutral.
#[derive(Deserialize)]
pub struct HarnessOauthParams {
    pub authorize_base: String,
    pub code_challenge: String,
    pub client_id: Option<String>,
    pub scope: Option<String>,
    pub state: Option<String>,
}

#[derive(Serialize)]
pub struct HarnessOauthResult {
    pub code: String,
    pub redirect_uri: String,
}

#[tauri::command]
pub fn harness_oauth_loopback(params: HarnessOauthParams) -> Result<HarnessOauthResult, String> {
    let server = tiny_http::Server::http("127.0.0.1:0").map_err(|e| e.to_string())?;
    let port = match server.server_addr() {
        tiny_http::ListenAddr::IP(addr) => addr.port(),
        _ => return Err("could not bind loopback".into()),
    };
    let redirect = format!("http://127.0.0.1:{port}/cb");

    // Build the authorize URL: harness-supplied base + challenge, host-substituted redirect_uri. No PKCE
    // verifier is generated or held here — only the challenge the harness already computed.
    let mut authorize = format!(
        "{}{}response_type=code&redirect_uri={}&code_challenge={}&code_challenge_method=S256",
        params.authorize_base,
        if params.authorize_base.contains('?') { "&" } else { "?" },
        urlencode(&redirect),
        urlencode(&params.code_challenge),
    );
    if let Some(cid) = &params.client_id {
        authorize.push_str(&format!("&client_id={}", urlencode(cid)));
    }
    if let Some(scope) = &params.scope {
        authorize.push_str(&format!("&scope={}", urlencode(scope)));
    }
    if let Some(state) = &params.state {
        authorize.push_str(&format!("&state={}", urlencode(state)));
    }

    open::that(&authorize).map_err(|e| e.to_string())?;

    // Block for the single redirect carrying ?code=… (the user's browser hits our loopback).
    let request = server.recv().map_err(|e| e.to_string())?;
    let url = request.url().to_string();
    let code = parse_query(&url, "code").ok_or("no authorization code in callback")?;
    let _ = request.respond(tiny_http::Response::from_string(
        "<html><body>You're signed in. You can close this tab.</body></html>",
    ));

    // END HERE — no token exchange. The harness exchanges `code` (+ its private verifier) itself.
    Ok(HarnessOauthResult { code, redirect_uri: redirect })
}

// Silence unused-import warning when no target uses Read directly.
#[allow(dead_code)]
fn _touch_read(mut r: impl Read) {
    let mut _b = [0u8; 0];
    let _ = r.read(&mut _b);
}
