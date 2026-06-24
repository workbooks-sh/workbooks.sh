//! A drop-in `yup-oauth2` shim whose token flows ride washy's `host_http` — Google OAuth without
//! hyper/tokio-net/ring. Patched in via `[patch.crates-io]` so a Google CLI (gws) compiles to
//! wasm32-wasip1 unmodified. The second shim alongside `reqwest`: between them, gws's two HTTP stacks
//! (API calls + auth) both route through the host. Write once, reused by every Google CLI.
//!
//! Runtime coverage:
//!   * **authorized-user** (refresh token) → real OAuth refresh over `host_http`.
//!   * **service-account** (JWT) → returns an error (RS256 signing isn't done in-sandbox; the BYO model
//!     supplies a pre-obtained access token instead — gws's token precedence uses it before auth).
//!   * **installed-flow** (interactive browser) → error (the user runs `gws auth login` on their machine).

use serde::{Deserialize, Serialize};
use std::future::Future;
use std::path::Path;
use std::pin::Pin;

// ── Error ───────────────────────────────────────────────────────────────────────────────────────
#[derive(Debug)]
pub struct Error(String);

impl Error {
    fn msg(s: impl Into<String>) -> Self {
        Error(s.into())
    }
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}
impl std::error::Error for Error {}

// ── Secrets (deserialized from Google's JSON) ─────────────────────────────────────────────────────
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ApplicationSecret {
    pub client_id: String,
    pub client_secret: String,
    #[serde(default)]
    pub token_uri: String,
    #[serde(default)]
    pub auth_uri: String,
    #[serde(default)]
    pub redirect_uris: Vec<String>,
    #[serde(default)]
    pub project_id: Option<String>,
    #[serde(default)]
    pub client_email: Option<String>,
    #[serde(default)]
    pub auth_provider_x509_cert_url: Option<String>,
    #[serde(default)]
    pub client_x509_cert_url: Option<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ServiceAccountKey {
    #[serde(rename = "type", default)]
    pub key_type: Option<String>,
    #[serde(default)]
    pub project_id: Option<String>,
    #[serde(default)]
    pub private_key_id: Option<String>,
    pub private_key: String,
    pub client_email: String,
    #[serde(default)]
    pub client_id: Option<String>,
    #[serde(default)]
    pub auth_uri: Option<String>,
    #[serde(default = "default_token_uri")]
    pub token_uri: String,
    #[serde(default)]
    pub auth_provider_x509_cert_url: Option<String>,
    #[serde(default)]
    pub client_x509_cert_url: Option<String>,
}

fn default_token_uri() -> String {
    "https://oauth2.googleapis.com/token".to_string()
}

pub mod authorized_user {
    use super::*;

    #[derive(Clone, Debug, Default, Serialize, Deserialize)]
    pub struct AuthorizedUserSecret {
        pub client_id: String,
        pub client_secret: String,
        pub refresh_token: String,
        #[serde(rename = "type", default)]
        pub key_type: String,
    }
}

// ── AccessToken ───────────────────────────────────────────────────────────────────────────────────
pub struct AccessToken {
    token: Option<String>,
}

impl AccessToken {
    /// The bearer token string (None if the response carried none).
    pub fn token(&self) -> Option<&str> {
        self.token.as_deref()
    }
}

// ── Token storage (gws implements this trait; the shim just satisfies the surface) ────────────────
pub mod storage {
    use super::*;

    #[derive(Clone, Debug, Default, Serialize, Deserialize)]
    pub struct TokenInfo {
        #[serde(default)]
        pub access_token: Option<String>,
        #[serde(default)]
        pub refresh_token: Option<String>,
        #[serde(default)]
        pub expires_at: Option<i64>,
        #[serde(default)]
        pub id_token: Option<String>,
    }

    #[derive(Debug)]
    pub enum TokenStorageError {
        Io(std::io::Error),
        Other(std::borrow::Cow<'static, str>),
    }

    impl std::fmt::Display for TokenStorageError {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            match self {
                TokenStorageError::Io(e) => write!(f, "I/O error: {e}"),
                TokenStorageError::Other(s) => write!(f, "{s}"),
            }
        }
    }
    impl std::error::Error for TokenStorageError {}
    impl From<std::io::Error> for TokenStorageError {
        fn from(e: std::io::Error) -> Self {
            TokenStorageError::Io(e)
        }
    }

    /// `#[async_trait]` trait — matches yup-oauth2 v12 exactly (dyn-safe), so gws's
    /// `#[async_trait::async_trait] impl TokenStorage for …` compiles verbatim against the shim.
    #[async_trait::async_trait]
    pub trait TokenStorage: Send + Sync {
        async fn set(&self, scopes: &[&str], token: TokenInfo) -> Result<(), TokenStorageError>;
        async fn get(&self, scopes: &[&str]) -> Option<TokenInfo>;
    }
}

pub mod authenticator_delegate {
    use super::*;

    pub trait InstalledFlowDelegate: Send + Sync {
        fn redirect_uri(&self) -> Option<&str> {
            None
        }

        fn present_user_url<'a>(
            &'a self,
            _url: &'a str,
            _need_code: bool,
        ) -> Pin<Box<dyn Future<Output = Result<String, String>> + Send + 'a>> {
            Box::pin(async { Err("interactive OAuth is not available in-sandbox".to_string()) })
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InstalledFlowReturnMethod {
    Interactive,
    HTTPRedirect,
    HTTPPortRedirect(u16),
}

// ── The built authenticator + its backends ────────────────────────────────────────────────────────
enum Backend {
    Refresh {
        token_uri: String,
        client_id: String,
        client_secret: String,
        refresh_token: String,
    },
    ServiceAccount,
    Installed,
}

pub struct Authenticator {
    backend: Backend,
}

impl Authenticator {
    /// Mint an access token for `scopes`. Generic over the scope element type so both `&[&str]` and
    /// `&[String]` work (matching yup-oauth2's `token<'a, T>`).
    pub async fn token<'a, T>(&'a self, _scopes: &'a [T]) -> Result<AccessToken, Error>
    where
        T: AsRef<str>,
    {
        match &self.backend {
            Backend::Refresh {
                token_uri,
                client_id,
                client_secret,
                refresh_token,
            } => {
                let token = refresh_access_token(token_uri, client_id, client_secret, refresh_token)?;
                Ok(AccessToken { token: Some(token) })
            }

            Backend::ServiceAccount => Err(Error::msg(
                "service-account JWT signing is not available in-sandbox; supply a pre-obtained access token",
            )),

            Backend::Installed => Err(Error::msg(
                "interactive login is not available in-sandbox; run `gws auth login` on your machine",
            )),
        }
    }
}

// ── Builders ──────────────────────────────────────────────────────────────────────────────────────
pub struct InstalledFlowAuthenticator;

impl InstalledFlowAuthenticator {
    pub fn builder(
        _secret: ApplicationSecret,
        _method: InstalledFlowReturnMethod,
    ) -> InstalledFlowAuthenticatorBuilder {
        InstalledFlowAuthenticatorBuilder
    }
}

pub struct InstalledFlowAuthenticatorBuilder;

impl InstalledFlowAuthenticatorBuilder {
    pub fn with_storage(self, _storage: Box<dyn storage::TokenStorage>) -> Self {
        self
    }
    pub fn force_account_selection(self, _v: bool) -> Self {
        self
    }
    pub fn flow_delegate(self, _d: Box<dyn authenticator_delegate::InstalledFlowDelegate>) -> Self {
        self
    }
    pub async fn build(self) -> Result<Authenticator, Error> {
        Ok(Authenticator { backend: Backend::Installed })
    }
}

pub struct AuthorizedUserAuthenticator;

impl AuthorizedUserAuthenticator {
    pub fn builder(secret: authorized_user::AuthorizedUserSecret) -> AuthorizedUserAuthenticatorBuilder {
        AuthorizedUserAuthenticatorBuilder { secret }
    }
}

pub struct AuthorizedUserAuthenticatorBuilder {
    secret: authorized_user::AuthorizedUserSecret,
}

impl AuthorizedUserAuthenticatorBuilder {
    pub fn with_storage(self, _storage: Box<dyn storage::TokenStorage>) -> Self {
        self
    }
    pub async fn build(self) -> Result<Authenticator, Error> {
        Ok(Authenticator {
            backend: Backend::Refresh {
                token_uri: default_token_uri(),
                client_id: self.secret.client_id,
                client_secret: self.secret.client_secret,
                refresh_token: self.secret.refresh_token,
            },
        })
    }
}

pub struct ServiceAccountAuthenticator;

impl ServiceAccountAuthenticator {
    pub fn builder(_key: ServiceAccountKey) -> ServiceAccountAuthenticatorBuilder {
        ServiceAccountAuthenticatorBuilder
    }
}

pub struct ServiceAccountAuthenticatorBuilder;

impl ServiceAccountAuthenticatorBuilder {
    pub fn with_storage(self, _storage: Box<dyn storage::TokenStorage>) -> Self {
        self
    }
    pub async fn build(self) -> Result<Authenticator, Error> {
        Ok(Authenticator { backend: Backend::ServiceAccount })
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────────────────────────
pub fn parse_service_account_key<S: AsRef<[u8]>>(key: S) -> std::io::Result<ServiceAccountKey> {
    serde_json::from_slice(key.as_ref())
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))
}

pub async fn read_authorized_user_secret<P: AsRef<Path>>(
    path: P,
) -> std::io::Result<authorized_user::AuthorizedUserSecret> {
    let bytes = std::fs::read(path)?;
    serde_json::from_slice(&bytes)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))
}

// ── The host-brokered OAuth refresh flow (no hyper/tokio-net) ─────────────────────────────────────
fn refresh_access_token(
    token_uri: &str,
    client_id: &str,
    client_secret: &str,
    refresh_token: &str,
) -> Result<String, Error> {
    let body = format!(
        "grant_type=refresh_token&client_id={}&client_secret={}&refresh_token={}",
        form_encode(client_id),
        form_encode(client_secret),
        form_encode(refresh_token),
    );

    let resp = host_http::request(
        "POST",
        token_uri,
        &[("Content-Type", "application/x-www-form-urlencoded")],
        body.as_bytes(),
    )
    .map_err(|_| Error::msg("no host transport (run lacks a network grant)"))?;

    if resp.status != 200 {
        return Err(Error::msg(format!(
            "token endpoint returned {}: {}",
            resp.status,
            String::from_utf8_lossy(&resp.body)
        )));
    }

    let v: serde_json::Value =
        serde_json::from_slice(&resp.body).map_err(|e| Error::msg(e.to_string()))?;
    v.get("access_token")
        .and_then(|t| t.as_str())
        .map(String::from)
        .ok_or_else(|| Error::msg("token response carried no access_token"))
}

fn form_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}
