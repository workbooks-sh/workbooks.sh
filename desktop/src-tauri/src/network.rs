// Workbooks Network — local identity + WorkOS sign-in + workspace packaging.
// All local-first: the ed25519 signing key lives in the OS keychain, only the
// public material + metadata hit identity.json. WorkOS sign-in is the RFC-8252
// loopback + PKCE flow; the resulting session bearer is stashed in the keychain.

use base64::Engine as _;
use ed25519_dalek::{Signer, SigningKey};
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

/// Load the ed25519 signing key from the keychain.
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

/// Bundle a workspace's folders into a single signed .html and write it under
/// app_data/packages/<ws>.html. Local-only: tangle+bundle via the kernel, then
/// append an ed25519 signature comment.
#[tauri::command]
pub fn workspace_package(workspace_name: String) -> Result<String, String> {
    // Concatenate the workspace's package folders' source into one org doc,
    // weave it through the embedded kernel, and sign the result.
    let pkg = crate::packages::package_load(workspace_name.clone())?;
    let mut org = String::new();
    for folder in &pkg.folders {
        for entry in walkdir::WalkDir::new(folder).into_iter().flatten() {
            if entry.path().extension().and_then(|e| e.to_str()) == Some("org") {
                if let Ok(s) = std::fs::read_to_string(entry.path()) {
                    org.push_str(&s);
                    org.push('\n');
                }
            }
        }
    }
    let html = crate::kernel::call("render", &org)?;

    // Sign the rendered HTML and append the signature as an HTML comment so the
    // artifact stays a valid standalone document.
    let signing = load_signing_key()?;
    let sig = signing.sign(html.as_bytes());
    let sig_b64 = base64::engine::general_purpose::STANDARD.encode(sig.to_bytes());
    let signed = format!("{html}\n<!-- wb-signature: {sig_b64} -->\n");

    let out_dir = crate::paths::ensure_dir(crate::paths::app_data_dir().join("packages"))
        .map_err(|e| e.to_string())?;
    let out = out_dir.join(format!("{workspace_name}.html"));
    std::fs::write(&out, signed).map_err(|e| e.to_string())?;
    Ok(out.to_string_lossy().to_string())
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
#[tauri::command]
pub fn workos_sign_in(broker_url: String) -> Result<StoredSession, String> {
    let server = tiny_http::Server::http("127.0.0.1:0").map_err(|e| e.to_string())?;
    let port = match server.server_addr() {
        tiny_http::ListenAddr::IP(addr) => addr.port(),
        _ => return Err("could not bind loopback".into()),
    };
    let redirect = format!("http://127.0.0.1:{port}/cb");
    let (verifier, challenge) = pkce();

    let authorize = format!(
        "{}/v1/auth/authorize?response_type=code&redirect_uri={}&code_challenge={}&code_challenge_method=S256",
        broker_url.trim_end_matches('/'),
        urlencode(&redirect),
        challenge,
    );
    open::that(&authorize).map_err(|e| e.to_string())?;

    // Block for the redirect carrying ?code=… (single request).
    let request = server.recv().map_err(|e| e.to_string())?;
    let url = request.url().to_string();
    let code = parse_query(&url, "code").ok_or("no authorization code in callback")?;
    let _ = request.respond(tiny_http::Response::from_string(
        "<html><body>You're signed in. You can close this tab.</body></html>",
    ));

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
