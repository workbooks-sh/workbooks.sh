//! A drop-in `reqwest` shim whose transport is washy's `host_http` import.
//!
//! The guest has no sockets, no TLS, no async reactor — so every request is a synchronous hand-off to
//! the host (which does TLS + egress, SSRF-guarded). The async surface is preserved by wrapping the
//! synchronous call in an immediately-ready future, so a CLI's `#[tokio::main]` + `.await` keep working
//! with tokio trimmed to `rt`/`macros`/`time` (no `net`). Patched in via `[patch.crates-io]` so a
//! reqwest-using CLI compiles to wasm32-wasip1 unmodified — write the shim once, every CLI reuses it.
//!
//! This covers the common surface (Client/RequestBuilder/Response, headers, bearer auth, body, json,
//! status). It grows toward full fidelity as real CLIs exercise more of it.

use std::collections::BTreeMap;
use std::fmt;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
pub struct Error {
    msg: String,
    status: Option<u16>,
}

impl Error {
    fn new(msg: impl Into<String>) -> Self {
        Error { msg: msg.into(), status: None }
    }
    pub fn status(&self) -> Option<StatusCode> {
        self.status.map(StatusCode)
    }
    pub fn is_status(&self) -> bool {
        self.status.is_some()
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "reqwest-shim: {}", self.msg)
    }
}
impl std::error::Error for Error {}

impl From<host_http::Error> for Error {
    fn from(_: host_http::Error) -> Self {
        Error::new("no host transport (run lacks a network grant)")
    }
}

/// HTTP status, mirroring `reqwest::StatusCode`'s commonly-used methods.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct StatusCode(pub u16);

impl StatusCode {
    pub fn as_u16(&self) -> u16 {
        self.0
    }
    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.0)
    }
    pub fn is_client_error(&self) -> bool {
        (400..500).contains(&self.0)
    }
    pub fn is_server_error(&self) -> bool {
        (500..600).contains(&self.0)
    }
}

impl fmt::Display for StatusCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Method {
    GET,
    POST,
    PUT,
    PATCH,
    DELETE,
    HEAD,
}

impl Method {
    fn as_str(&self) -> &'static str {
        match self {
            Method::GET => "GET",
            Method::POST => "POST",
            Method::PUT => "PUT",
            Method::PATCH => "PATCH",
            Method::DELETE => "DELETE",
            Method::HEAD => "HEAD",
        }
    }
}

/// A client. Cheap to clone; holds default headers only (no connection pool — the host owns transport).
#[derive(Clone, Default)]
pub struct Client {
    default_headers: BTreeMap<String, String>,
}

impl Client {
    pub fn new() -> Self {
        Client::default()
    }
    pub fn builder() -> ClientBuilder {
        ClientBuilder::default()
    }
    pub fn get(&self, url: impl Into<String>) -> RequestBuilder {
        self.request(Method::GET, url)
    }
    pub fn post(&self, url: impl Into<String>) -> RequestBuilder {
        self.request(Method::POST, url)
    }
    pub fn put(&self, url: impl Into<String>) -> RequestBuilder {
        self.request(Method::PUT, url)
    }
    pub fn patch(&self, url: impl Into<String>) -> RequestBuilder {
        self.request(Method::PATCH, url)
    }
    pub fn delete(&self, url: impl Into<String>) -> RequestBuilder {
        self.request(Method::DELETE, url)
    }
    pub fn request(&self, method: Method, url: impl Into<String>) -> RequestBuilder {
        RequestBuilder {
            method,
            url: url.into(),
            headers: self.default_headers.clone(),
            body: Vec::new(),
        }
    }
}

#[derive(Default)]
pub struct ClientBuilder {
    default_headers: BTreeMap<String, String>,
}

impl ClientBuilder {
    pub fn build(self) -> Result<Client> {
        Ok(Client { default_headers: self.default_headers })
    }
    pub fn default_headers(mut self, headers: BTreeMap<String, String>) -> Self {
        self.default_headers.extend(headers);
        self
    }
    // TLS / proxy / timeout knobs are no-ops — the host owns transport. Accept + ignore for fidelity.
    pub fn user_agent(self, _ua: impl Into<String>) -> Self {
        self
    }
    pub fn danger_accept_invalid_certs(self, _v: bool) -> Self {
        self
    }
}

pub struct RequestBuilder {
    method: Method,
    url: String,
    headers: BTreeMap<String, String>,
    body: Vec<u8>,
}

impl RequestBuilder {
    pub fn header(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.insert(key.into(), value.into());
        self
    }
    pub fn bearer_auth(mut self, token: impl fmt::Display) -> Self {
        self.headers.insert("Authorization".into(), format!("Bearer {}", token));
        self
    }
    pub fn body(mut self, body: impl Into<Vec<u8>>) -> Self {
        self.body = body.into();
        self
    }
    pub fn query(mut self, params: &[(&str, &str)]) -> Self {
        let q = params
            .iter()
            .map(|(k, v)| format!("{}={}", k, v))
            .collect::<Vec<_>>()
            .join("&");
        if !q.is_empty() {
            let sep = if self.url.contains('?') { '&' } else { '?' };
            self.url.push(sep);
            self.url.push_str(&q);
        }
        self
    }

    #[cfg(feature = "json")]
    pub fn json<T: serde::Serialize>(mut self, value: &T) -> Self {
        self.body = serde_json::to_vec(value).unwrap_or_default();
        self.headers.insert("Content-Type".into(), "application/json".into());
        self
    }

    /// Send the request through the host transport. Async by signature, synchronous underneath.
    pub async fn send(self) -> Result<Response> {
        let header_pairs: Vec<(&str, &str)> =
            self.headers.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        let r = host_http::request(self.method.as_str(), &self.url, &header_pairs, &self.body)?;
        Ok(Response { status: r.status, body: r.body })
    }
}

pub struct Response {
    status: u16,
    body: Vec<u8>,
}

impl Response {
    pub fn status(&self) -> StatusCode {
        StatusCode(self.status)
    }
    pub fn error_for_status(self) -> Result<Self> {
        if (200..400).contains(&self.status) {
            Ok(self)
        } else {
            Err(Error { msg: format!("HTTP {}", self.status), status: Some(self.status) })
        }
    }
    pub async fn text(self) -> Result<String> {
        Ok(String::from_utf8_lossy(&self.body).into_owned())
    }
    pub async fn bytes(self) -> Result<Vec<u8>> {
        Ok(self.body)
    }

    #[cfg(feature = "json")]
    pub async fn json<T: serde::de::DeserializeOwned>(self) -> Result<T> {
        serde_json::from_slice(&self.body).map_err(|e| Error::new(e.to_string()))
    }
}

/// `reqwest::get(url).await` — the free-function shortcut.
pub async fn get(url: impl Into<String>) -> Result<Response> {
    Client::new().get(url).send().await
}

/// The synchronous `reqwest::blocking` surface, for CLIs that use it.
#[cfg(feature = "blocking")]
pub mod blocking {
    use super::*;

    #[derive(Clone, Default)]
    pub struct Client {
        inner: super::Client,
    }

    impl Client {
        pub fn new() -> Self {
            Client::default()
        }
        pub fn get(&self, url: impl Into<String>) -> RequestBuilder {
            RequestBuilder { inner: self.inner.get(url) }
        }
        pub fn post(&self, url: impl Into<String>) -> RequestBuilder {
            RequestBuilder { inner: self.inner.post(url) }
        }
    }

    pub struct RequestBuilder {
        inner: super::RequestBuilder,
    }

    impl RequestBuilder {
        pub fn header(mut self, k: impl Into<String>, v: impl Into<String>) -> Self {
            self.inner = self.inner.header(k, v);
            self
        }
        pub fn bearer_auth(mut self, token: impl fmt::Display) -> Self {
            self.inner = self.inner.bearer_auth(token);
            self
        }
        pub fn body(mut self, body: impl Into<Vec<u8>>) -> Self {
            self.inner = self.inner.body(body);
            self
        }
        pub fn send(self) -> Result<Response> {
            let header_pairs: Vec<(&str, &str)> = self
                .inner
                .headers
                .iter()
                .map(|(k, v)| (k.as_str(), v.as_str()))
                .collect();
            let r = host_http::request(
                self.inner.method.as_str(),
                &self.inner.url,
                &header_pairs,
                &self.inner.body,
            )?;
            Ok(Response { status: r.status, body: r.body })
        }
    }

    pub struct Response {
        status: u16,
        body: Vec<u8>,
    }

    impl Response {
        pub fn status(&self) -> StatusCode {
            StatusCode(self.status)
        }
        pub fn text(self) -> Result<String> {
            Ok(String::from_utf8_lossy(&self.body).into_owned())
        }
        pub fn bytes(self) -> Result<Vec<u8>> {
            Ok(self.body)
        }
    }

    pub fn get(url: impl Into<String>) -> Result<Response> {
        Client::new().get(url).send()
    }
}
