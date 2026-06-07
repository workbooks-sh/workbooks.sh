// Load the bound Bluesky session from the canonical sidecar at
// <data_root>/Engine/network/identity/bluesky_session.json — same
// location the engine writes to, and same location the OAuth CLI
// writes when run with --standalone. Zero-migration whichever path
// the user took.
//
// On token expiry (HTTP 401 with `invalid_token`), refresh via
// `com.atproto.server.refreshSession` + DPoP, then atomically update
// the sidecar.

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use crate::cmd::bluesky_oauth::dpop::DpopKey;

/// On-disk shape — matches Network.Identity.bind_bluesky's writes.
/// `auth_kind` discriminates the two flavors: OAuth carries the DPoP
/// PEM + uses DPoP-bound auth headers; app-password carries neither.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    pub did: String,
    pub handle: String,
    pub access_jwt: String,
    pub refresh_jwt: String,
    #[serde(default)]
    pub auth_kind: AuthKind,
    pub pds_url: String,
    /// Only present when `auth_kind == Oauth`. PKCS#8 PEM-encoded
    /// ES256 (NIST P-256) private key. We re-parse it per-request
    /// (cheap — small key, no I/O), so the on-disk shape stays simple.
    pub dpop_key_pem: Option<String>,

    /// OAuth-only: the AS's token endpoint. Required for `refresh_token`
    /// grants. Auto-discovered via PDS's .well-known/oauth-protected-resource
    /// → AS's .well-known/oauth-authorization-server when missing.
    #[serde(default)]
    pub token_endpoint: Option<String>,

    /// OAuth-only: the client_id we used at bind time. Must match at
    /// refresh time per RFC 6749 §6 — the AS rejects a refresh from a
    /// different client. For atproto loopback clients this encodes
    /// redirect_uri + scope.
    #[serde(default)]
    pub client_id: Option<String>,
}

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum AuthKind {
    #[default]
    AppPassword,
    Oauth,
}

impl Session {
    /// Read the bound session from the canonical sidecar. Errors with
    /// `not_bound` when the file doesn't exist — caller surfaces a
    /// clear "run `wb identity bluesky-oauth-login --standalone` first."
    pub fn load() -> Result<Self> {
        let path = session_file()?;
        if !path.exists() {
            return Err(anyhow!(
                "not bound to Bluesky — run `wb identity bluesky-oauth-login --standalone` first"
            ));
        }
        let bytes = std::fs::read(&path)
            .with_context(|| format!("reading {}", path.display()))?;
        let session: Session = serde_json::from_slice(&bytes)
            .with_context(|| format!("parsing {}", path.display()))?;
        Ok(session)
    }

    /// Re-serialize + atomically write back to the sidecar with mode 0600.
    pub fn save(&self) -> Result<()> {
        let path = session_file()?;
        let json = serde_json::to_string(self)?;

        // Write to a temp file in the same dir, then rename — atomic
        // replace on POSIX. Avoids a half-written file if we crash.
        let tmp = path.with_extension("json.tmp");
        std::fs::write(&tmp, &json).with_context(|| format!("writing {}", tmp.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mut perms = std::fs::metadata(&tmp)?.permissions();
            perms.set_mode(0o600);
            let _ = std::fs::set_permissions(&tmp, perms);
        }

        std::fs::rename(&tmp, &path)
            .with_context(|| format!("rename {} → {}", tmp.display(), path.display()))?;
        Ok(())
    }

    /// Parse the DPoP key from the stored PEM. Required for OAuth
    /// sessions; errors for app-password (no DPoP key was generated).
    pub fn dpop_key(&self) -> Result<DpopKey> {
        match (self.auth_kind, &self.dpop_key_pem) {
            (AuthKind::Oauth, Some(pem)) => DpopKey::from_pkcs8_pem(pem),
            (AuthKind::Oauth, None) => Err(anyhow!(
                "session is OAuth-kind but has no dpop_key_pem — corrupted sidecar"
            )),
            (AuthKind::AppPassword, _) => Err(anyhow!(
                "session is app-password — no DPoP key. Re-login via oauth flow"
            )),
        }
    }
}

pub fn session_file() -> Result<PathBuf> {
    Ok(identity_dir()?.join("bluesky_session.json"))
}

fn identity_dir() -> Result<PathBuf> {
    let root = match std::env::var("WB_DATA_ROOT") {
        Ok(p) if !p.is_empty() => PathBuf::from(p),
        _ => {
            let home = dirs::home_dir().ok_or_else(|| anyhow!("no home directory"))?;
            home.join("Workbooks")
        }
    };
    Ok(root.join("Engine").join("network").join("identity"))
}

pub fn print_status() -> Result<()> {
    match Session::load() {
        Ok(s) => {
            println!("bound to Bluesky");
            println!("  did:        {}", s.did);
            println!(
                "  handle:     {}",
                if s.handle.is_empty() { "(empty — see wb-8fhk.22.1)" } else { s.handle.as_str() }
            );
            println!("  auth_kind:  {:?}", s.auth_kind);
            println!("  pds_url:    {}", s.pds_url);
            println!("  sidecar:    {}", session_file()?.display());
            Ok(())
        }
        Err(e) => {
            eprintln!("not bound: {e}");
            std::process::exit(1);
        }
    }
}
