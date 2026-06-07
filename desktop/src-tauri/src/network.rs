// Workbooks Network — Tauri ↔ oql-agent IPC bridge (wb-u2o0.9.1).
//
// Three concerns live in this file:
//   1. A small `call_internal` helper that wraps reqwest with the
//      sidecar URL + bearer token (mirrors the pattern in sidecar.rs).
//   2. Tauri commands the desktop UI invokes for Identity + Publisher.
//   3. Stubs for WorkOS sign-in (wb-u2o0.9.2) and workspace packager
//      (wb-u2o0.9.3) — those are full sub-tasks; the command shape +
//      registration land now so the UI can wire to it.

use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value as JsonValue;

use crate::sidecar;

// ── HTTP helper ────────────────────────────────────────────────────

/// HTTP-call the sidecar's `/internal/*` surface. Picks up the URL +
/// bearer token from `sidecar::instance()`. Errors as strings so
/// Tauri returns them straight to the frontend.
async fn call_internal(
    method: reqwest::Method,
    path: &str,
    body: Option<&JsonValue>,
) -> Result<JsonValue, String> {
    let s = sidecar::instance();
    let url = s
        .status
        .read()
        .await
        .url
        .clone()
        .ok_or_else(|| "sidecar not ready".to_string())?;
    let token = s
        .internal_token
        .read()
        .await
        .clone()
        .ok_or_else(|| "sidecar token unavailable".to_string())?;

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| format!("http client: {e}"))?;

    let full = format!("{url}{path}");
    let mut req = client
        .request(method, &full)
        .bearer_auth(&token)
        .header("Accept", "application/json");
    if let Some(b) = body {
        req = req.json(b);
    }

    let resp = req
        .send()
        .await
        .map_err(|e| format!("request failed: {e}"))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("read body: {e}"))?;

    if !status.is_success() {
        // Return the error body so the frontend can render structured detail.
        return Err(format!("HTTP {} — {}", status.as_u16(), text));
    }

    serde_json::from_str(&text)
        .map_err(|e| format!("json parse: {e} ({text})"))
}

// ── Identity ───────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IdentityView {
    pub did: String,
    pub handle: Option<String>,
    pub workos_user_id: Option<String>,
    pub public_key_b64: String,
}

#[tauri::command]
pub async fn network_identity_load() -> Result<Option<IdentityView>, String> {
    match call_internal(reqwest::Method::GET, "/internal/network/identity", None).await {
        Ok(v) => Ok(Some(serde_json::from_value(v).map_err(|e| format!("decode: {e}"))?)),
        Err(e) if e.starts_with("HTTP 404") => Ok(None),
        Err(e) => Err(e),
    }
}

#[tauri::command]
pub async fn network_identity_generate(
    handle: Option<String>,
    workos_user_id: Option<String>,
) -> Result<IdentityView, String> {
    let body = serde_json::json!({
        "handle":         handle,
        "workos_user_id": workos_user_id,
    });
    let v = call_internal(
        reqwest::Method::POST,
        "/internal/network/identity/generate",
        Some(&body),
    )
    .await?;
    serde_json::from_value(v).map_err(|e| format!("decode: {e}"))
}

#[tauri::command]
pub async fn network_identity_set_handle(handle: String) -> Result<IdentityView, String> {
    let body = serde_json::json!({ "handle": handle });
    let v = call_internal(
        reqwest::Method::PATCH,
        "/internal/network/identity",
        Some(&body),
    )
    .await?;
    serde_json::from_value(v).map_err(|e| format!("decode: {e}"))
}

#[tauri::command]
pub async fn network_identity_set_workos(
    workos_user_id: Option<String>,
) -> Result<IdentityView, String> {
    let body = serde_json::json!({ "workos_user_id": workos_user_id });
    let v = call_internal(
        reqwest::Method::PATCH,
        "/internal/network/identity",
        Some(&body),
    )
    .await?;
    serde_json::from_value(v).map_err(|e| format!("decode: {e}"))
}

// ── Publisher ──────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublishArgs {
    pub workbook_path: String,
    pub recipients: Vec<String>,
    #[serde(default = "default_workbook")]
    pub artifact_kind: String,
    #[serde(default = "default_friends")]
    pub posture: String,
    pub message: Option<String>,
    pub title: Option<String>,
    pub broker_url: String,
    pub broker_token: Option<String>,
}

fn default_workbook() -> String { "workbook".into() }
fn default_friends() -> String { "friends".into() }

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PublishResult {
    pub share_id: String,
    pub rid: String,
    pub signed_html_path: String,
}

#[tauri::command]
pub async fn network_publisher_publish(args: PublishArgs) -> Result<PublishResult, String> {
    let body = serde_json::to_value(&args).map_err(|e| format!("serialize args: {e}"))?;
    let v = call_internal(
        reqwest::Method::POST,
        "/internal/network/publisher/publish",
        Some(&body),
    )
    .await?;
    serde_json::from_value(v).map_err(|e| format!("decode: {e}"))
}

// ── WorkOS sign-in (RFC 8252 loopback + PKCE) ──────────────────────
//
// Native-desktop OAuth: open the user's SYSTEM BROWSER to WorkOS,
// catch the callback on a loopback port owned by this Tauri process,
// exchange code+PKCE-verifier for a bearer token, stash in the OS
// keychain. No webview, no cookies, no broker hop on the auth path.
//
// History: the webview/cookie-based flow that lived here through
// wb-u2o0.9.2 was unworkable cross-origin (SameSite=Lax blocks fetch,
// SameSite=None requires HTTPS + exact-origin CORS that fought every
// dev cycle, and stale WebKit cookies persistently wedged the next
// sign-in). The industry-standard pattern (gh CLI, Codex, Cursor)
// uses the system browser via loopback redirect — implemented in
// `auth_loopback.rs`. WorkOS supports this as a first-class flow
// (RFC 8252 loopback + PKCE) and the `http://localhost:*/callback`
// wildcard is already registered on the prod environment.

use crate::auth_loopback::{run_loopback_signin, LoopbackSignInResult};

const KEYCHAIN_SERVICE: &str = "sh.workbooks.desktop";
const KEYCHAIN_SESSION_ACCOUNT: &str = "broker-session-v1";

/// Stashed in the OS keychain under SERVICE/ACCOUNT as JSON. Reading
/// it back populates the auth store on next launch without a network
/// round trip. Mirrors the broker's `/v1/auth/exchange` response — the
/// bearer is what every subsequent broker call sends as
/// `Authorization: Bearer <bearer>`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StoredSession {
    pub bearer: String,
    pub expires_at: i64,
    pub sub: String,
    pub email: String,
    pub email_verified: bool,
    pub organization_id: Option<String>,
    /// WorkOS display name. `#[serde(default)]` so sessions written
    /// to the keychain before this field existed deserialize cleanly
    /// (null until the user signs in again).
    #[serde(default)]
    pub display_name: Option<String>,
    /// Profile picture URL. See LoopbackSignInResult::picture_url for
    /// the absolute-vs-relative semantics. Same back-compat caveat as
    /// `display_name`.
    #[serde(default)]
    pub picture_url: Option<String>,
}

impl From<LoopbackSignInResult> for StoredSession {
    fn from(r: LoopbackSignInResult) -> Self {
        Self {
            bearer: r.bearer,
            expires_at: r.expires_at,
            sub: r.sub,
            email: r.email,
            email_verified: r.email_verified,
            organization_id: r.organization_id,
            display_name: r.display_name,
            picture_url: r.picture_url,
        }
    }
}

fn session_keychain_entry() -> Result<keyring::Entry, String> {
    keyring::Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_SESSION_ACCOUNT)
        .map_err(|e| format!("keychain entry: {e}"))
}

fn write_session_to_keychain(session: &StoredSession) -> Result<(), String> {
    let json = serde_json::to_string(session)
        .map_err(|e| format!("serialize session: {e}"))?;
    session_keychain_entry()?
        .set_password(&json)
        .map_err(|e| format!("write keychain session: {e}"))
}

/// Run the broker-mediated loopback sign-in flow and stash the
/// resulting bearer in the OS keychain. Returns the session metadata
/// (sub, email, etc.) so the UI can flip to signed-in immediately.
#[tauri::command]
pub async fn network_workos_sign_in(
    broker_url: String,
) -> Result<StoredSession, String> {
    let result = run_loopback_signin(
        &broker_url,
        std::time::Duration::from_secs(300),
    )
    .await?;
    let stored: StoredSession = result.into();
    write_session_to_keychain(&stored)?;
    Ok(stored)
}

/// Read a previously-stored session from the OS keychain. Returns
/// `None` (as `null` in JS) when nothing's there — the auth store
/// treats that as signed-out and prompts the user to sign in.
#[tauri::command]
pub async fn network_workos_load_session() -> Result<Option<StoredSession>, String> {
    match session_keychain_entry()?.get_password() {
        Ok(json) => {
            let s: StoredSession = serde_json::from_str(&json)
                .map_err(|e| format!("decode session: {e}"))?;
            Ok(Some(s))
        }
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(format!("read keychain session: {e}")),
    }
}

/// Wipe the stored session. Used by sign-out — cookies aren't part
/// of this flow so a local wipe is all that's needed; future broker
/// session-revocation lives elsewhere.
#[tauri::command]
pub async fn network_workos_clear_session() -> Result<(), String> {
    match session_keychain_entry()?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(format!("delete keychain session: {e}")),
    }
}

// ── Workspace packager (wb-u2o0.9.3) ──────────────────────────────
//
// Bundles a workspace's folders into a single self-contained
// workbook `.html`. The result is what Publisher signs + ships through
// Radicle, so a recipient gets one file that carries the whole
// workspace (file tree + contents, base64-encoded).
//
// Bundle layout inside the HTML:
//   <script type="application/json" id="wb-bundle-manifest">{...}</script>
//   <script type="application/json" id="wb-bundle-files">[...]</script>
// A minimal inline JS renders the file list so opening the workbook
// in any browser shows what's in the bundle.
//
// Constraints (v1):
//   - 50 MB total cap (refuse larger workspaces with a clear error)
//   - Skip dot-files (.git, .DS_Store, .gitignore, etc.)
//   - .workbookignore (gitignore syntax) is a follow-up

use base64::Engine;

#[derive(Serialize)]
struct BundleManifest {
    name: String,
    file_count: usize,
    total_bytes: u64,
    folders: Vec<String>,
}

#[derive(Serialize)]
struct BundleFile {
    path: String,
    size: u64,
    b64: String,
}

const MAX_BUNDLE_BYTES: u64 = 50 * 1024 * 1024;

// ── Workbook fork (wb-u2o0.6.2) ────────────────────────────────────
//
// "Fork this workbook" path — clone the source RID into a fresh
// per-fork workspace + create a new RID for the fork + re-sign the
// workbook with a c2pa.action.forked assertion + extend the
// claim_chain referencing the upstream's current claim as parent.
//
// Phase 5 v1: stub that returns success after a 250ms simulated pause
// + a synthetic new RID. Real impl IPCs to oql-agent /internal/
// network/radicle/fork which does:
//   1. rad clone <source_rid> into the fork workspace
//   2. rad init --private (mint new RID)
//   3. Read source workbook → strip manifest
//   4. Add c2pa.action.forked assertion {actor: my_did, upstream_did,
//      upstream_rid}
//   5. Build prior ClaimRecord from source envelope's current claim
//   6. Re-sign with claim_chain = source.claim_chain + [source_current]
//   7. Write back + push to fork's RID

#[derive(Debug, Clone, Deserialize)]
pub struct WorkbookForkArgs {
    pub source_rid: String,
    // source_did + source_handle will be consumed when the stub
    // graduates to a real fork (chain extension references the
    // upstream's DID; UI surfaces the upstream handle). Stub today
    // doesn't read them; #[allow(dead_code)] until the real impl.
    #[allow(dead_code)]
    pub source_did: String,
    #[allow(dead_code)]
    pub source_handle: Option<String>,
    pub workspace: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct WorkbookForkResult {
    pub rid: String,
    pub fork_path: String,
}

#[tauri::command]
pub async fn network_workbook_fork(
    args: WorkbookForkArgs,
) -> Result<WorkbookForkResult, String> {
    tokio::time::sleep(Duration::from_millis(250)).await;

    // Deterministic-but-fake RID for the stub. Real impl returns the
    // Radicle-assigned RID after `rad init`.
    let suffix: String = args.source_rid.chars().rev().take(8).collect::<String>()
        .chars().rev().collect();
    let rid = format!("rad:zFORK{suffix}");

    let home = std::env::var_os("HOME").ok_or("no HOME env var")?;
    let fork_path = std::path::PathBuf::from(home)
        .join("Workbooks")
        .join("monorepo")
        .join("workspaces")
        .join(&args.workspace)
        .join("forks")
        .join(&rid)
        .to_string_lossy()
        .to_string();

    Ok(WorkbookForkResult { rid, fork_path })
}

// ── Workgate install hook (wb-u2o0.4.5) ────────────────────────────
//
// Executable-share install path. The desktop's PreviewPane shows the
// requested capabilities; on user confirm, this command runs:
//   1. (TODO real Workgate) prompt OS-level capability approval
//   2. Radicle.clone the rid into ~/Workbooks/monorepo/workspaces/<workspace>/.installed/<kind>/<rid>/
//   3. Run manifest verify on the freshly-cloned artifact
//   4. Register with policy.lua so the agent runtime picks it up
//
// Phase 3 v1: stub that returns success after a 200ms simulated
// pause. The IPC + verify steps land when wb-u2o0.X.Y wires the
// real Workgate prompt (separate task in the existing wb-i38o
// desktop epic).

#[derive(Debug, Clone, Deserialize)]
pub struct WorkgateInstallArgs {
    pub rid: String,
    pub workspace: String,
    /// Requested capabilities — fs/network/tools lists from the manifest.
    /// Stub doesn't enforce yet; #[allow(dead_code)] until the real
    /// Workgate prompt path lands and surfaces these to the user.
    #[allow(dead_code)]
    pub scopes: WorkgateScopes,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkgateScopes {
    #[serde(default)]
    pub fs: Vec<String>,
    #[serde(default)]
    pub net: Vec<String>,
    #[serde(default)]
    pub tools: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WorkgateInstallResult {
    pub installed: bool,
    pub install_path: String,
}

#[tauri::command]
pub async fn network_workgate_install(
    args: WorkgateInstallArgs,
) -> Result<WorkgateInstallResult, String> {
    // Stub: simulated approval + path return. Real impl IPCs to
    // Workgate (Tauri shell holds OS permissions per
    // docs/desktop/agent-sandbox.md), then issues the clone via
    // call_internal to oql-agent's /internal/network/radicle/clone
    // endpoint (which lands in a separate task).
    tokio::time::sleep(Duration::from_millis(200)).await;

    let home = std::env::var_os("HOME").ok_or("no HOME env var")?;
    let install_path = std::path::PathBuf::from(home)
        .join("Workbooks")
        .join("monorepo")
        .join("workspaces")
        .join(&args.workspace)
        .join(".installed")
        .join(&args.rid)
        .to_string_lossy()
        .to_string();

    Ok(WorkgateInstallResult {
        installed: true,
        install_path,
    })
}

#[tauri::command]
pub async fn network_workspace_package(workspace_name: String) -> Result<String, String> {
    // Load the workspace via the existing workspace.rs surface so
    // we honor its folder list, view mode, etc.
    let ws = crate::package::package_load(workspace_name.clone())
        .await
        .map_err(|e| format!("load workspace: {e}"))?;

    let mut files: Vec<BundleFile> = Vec::new();
    let mut total_bytes: u64 = 0;
    let mut folders_seen: Vec<String> = Vec::new();

    for folder in &ws.folders {
        folders_seen.push(folder.clone());
        walk_folder(std::path::Path::new(folder), folder, &mut files, &mut total_bytes)?;
        if total_bytes > MAX_BUNDLE_BYTES {
            return Err(format!(
                "workspace exceeds {} MB cap (bundled {} bytes so far). Trim files or share at the workbook level instead.",
                MAX_BUNDLE_BYTES / (1024 * 1024),
                total_bytes
            ));
        }
    }

    let manifest = BundleManifest {
        name: workspace_name.clone(),
        file_count: files.len(),
        total_bytes,
        folders: folders_seen,
    };

    // Stable bundle name per content: hash of workspace name + total
    // bytes + file count. Re-bundling unchanged content reuses the
    // same path — cheap idempotency.
    let bundle_id = stable_id(&workspace_name, total_bytes, files.len());

    let bundles_dir = bundles_dir()?;
    std::fs::create_dir_all(&bundles_dir)
        .map_err(|e| format!("create bundles dir: {e}"))?;
    let out_path = bundles_dir.join(format!("{bundle_id}.html"));

    let html = build_html(&manifest, &files)?;
    std::fs::write(&out_path, html.as_bytes())
        .map_err(|e| format!("write bundle: {e}"))?;

    Ok(out_path.to_string_lossy().to_string())
}

fn walk_folder(
    base: &std::path::Path,
    base_label: &str,
    files: &mut Vec<BundleFile>,
    total_bytes: &mut u64,
) -> Result<(), String> {
    let entries = std::fs::read_dir(base)
        .map_err(|e| format!("read_dir {}: {e}", base.display()))?;

    for entry in entries {
        let entry = entry.map_err(|e| format!("entry: {e}"))?;
        let path = entry.path();
        let name = entry.file_name();
        let name_str = name.to_string_lossy();

        // Skip dot-files at every level (.git, .DS_Store, .gitignore, …).
        if name_str.starts_with('.') {
            continue;
        }

        let ft = entry.file_type().map_err(|e| format!("file_type: {e}"))?;
        if ft.is_dir() {
            walk_folder(&path, base_label, files, total_bytes)?;
        } else if ft.is_file() {
            let bytes = std::fs::read(&path)
                .map_err(|e| format!("read {}: {e}", path.display()))?;
            *total_bytes += bytes.len() as u64;
            // Use a relative path under the base folder so the bundle
            // doesn't leak absolute paths from the sender's machine.
            let rel = path
                .strip_prefix(base)
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|_| path.to_string_lossy().to_string());
            let display = format!("{}/{rel}", base_label.trim_end_matches('/'));
            files.push(BundleFile {
                path: display,
                size: bytes.len() as u64,
                b64: base64::engine::general_purpose::STANDARD.encode(&bytes),
            });
        }
    }
    Ok(())
}

fn stable_id(name: &str, total_bytes: u64, file_count: usize) -> String {
    // Simple non-crypto hash — bundles are content-keyed but we don't
    // need collision resistance, just a stable string.
    let mut h: u64 = 0xcbf29ce484222325;
    for b in name.as_bytes().iter().chain(&total_bytes.to_le_bytes())
        .chain(&(file_count as u64).to_le_bytes())
    {
        h = h.wrapping_mul(0x100000001b3);
        h ^= *b as u64;
    }
    format!("wsbundle-{h:x}")
}

fn bundles_dir() -> Result<std::path::PathBuf, String> {
    let home = std::env::var_os("HOME").ok_or("no HOME env var")?;
    Ok(std::path::PathBuf::from(home)
        .join("Workbooks")
        .join("Engine")
        .join("tmp")
        .join("workspace-bundles"))
}

fn build_html(manifest: &BundleManifest, files: &[BundleFile]) -> Result<String, String> {
    let manifest_json = serde_json::to_string(manifest)
        .map_err(|e| format!("encode manifest: {e}"))?;
    let files_json = serde_json::to_string(files)
        .map_err(|e| format!("encode files: {e}"))?;

    // Minimal viewer — recipient gets a usable "what's in this bundle"
    // page even without a workbook runtime. The full workbook runtime
    // can later wrap this with richer browsing + per-file download.
    Ok(format!(
        r#"<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Workspace bundle: {name}</title>
  <meta name="workbook-bundle-version" content="1">
  <style>
    body {{ font: 14px/1.5 -apple-system, sans-serif; padding: 2rem; max-width: 720px; margin: 0 auto; color: #0f0f0f; }}
    h1 {{ margin: 0 0 .25rem; font-size: 1.2rem; letter-spacing: -.01em; }}
    .meta {{ color: #777; font-size: .85rem; margin-bottom: 1.5rem; }}
    ul {{ list-style: none; padding: 0; }}
    li {{ display: flex; justify-content: space-between; padding: .35rem .5rem; border-bottom: 1px solid #eee; }}
    li .size {{ color: #999; font-variant-numeric: tabular-nums; }}
    button {{ background: #0f0f0f; color: white; border: 0; padding: .4rem .9rem; border-radius: 6px; font: inherit; font-size: .85rem; cursor: pointer; }}
  </style>
</head>
<body>
  <h1>{name}</h1>
  <p class="meta">Workspace bundle · {file_count} file{plural} · {total_bytes} bytes</p>
  <ul id="files"></ul>

  <script type="application/json" id="wb-bundle-manifest">{manifest_json}</script>
  <script type="application/json" id="wb-bundle-files">{files_json}</script>

  <script>
  (function() {{
    const files = JSON.parse(document.getElementById('wb-bundle-files').textContent);
    const list = document.getElementById('files');
    function fmt(n) {{ return n.toLocaleString(); }}
    for (const f of files) {{
      const li = document.createElement('li');
      const name = document.createElement('span'); name.textContent = f.path;
      const size = document.createElement('span'); size.className = 'size'; size.textContent = fmt(f.size) + ' B';
      li.appendChild(name); li.appendChild(size);
      list.appendChild(li);
    }}
  }})();
  </script>
</body>
</html>
"#,
        name = manifest.name,
        file_count = manifest.file_count,
        plural = if manifest.file_count == 1 { "" } else { "s" },
        total_bytes = manifest.total_bytes,
        manifest_json = manifest_json,
        files_json = files_json,
    ))
}
