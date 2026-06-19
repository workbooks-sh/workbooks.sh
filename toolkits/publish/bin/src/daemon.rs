// Engine discovery + HTTP client — the subset `wb-publish` needs.
//
// Same discovery contract as `wb` (cli/wb/src/daemon.rs is the
// reference copy): the Workhorse daemon writes its listening URL +
// bearer token to `~/Workbooks/Engine/listen.json`; env overrides
// cover the microVM + cloud-sandbox cases. Only the engine-bind verbs
// (`identity bluesky-login`, the non-standalone oauth flow,
// `identity bluesky-logout`) use this — everything else in this
// binary is engine-free.

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
pub struct Listen {
    pub url: String,
    pub token: String,
}

fn listen_path() -> Result<PathBuf> {
    if let Ok(p) = std::env::var("WORKHORSE_LISTEN_FILE") {
        return Ok(PathBuf::from(p));
    }
    let home = dirs::home_dir().ok_or_else(|| anyhow!("no home directory"))?;
    Ok(home.join("Workbooks").join("Engine").join("listen.json"))
}

pub fn read_listen() -> Result<Listen> {
    // Resolution order (first match wins) — mirrors `wb`:
    //   1. WB_DAEMON_URL + WB_DAEMON_TOKEN   (microVM override)
    //   2. listen.json discovery file        (desktop / launchd daemon)
    //   3. WB_ENGINE_URL + WB_ENGINE_BEARER  (cloud engine sandbox)
    //   4. http://127.0.0.1:4000 + WB_ENGINE_BEARER
    if let (Ok(url), Ok(token)) = (
        std::env::var("WB_DAEMON_URL"),
        std::env::var("WB_DAEMON_TOKEN"),
    ) {
        if !url.is_empty() && !token.is_empty() {
            return Ok(Listen { url, token });
        }
    }

    let path = listen_path()?;
    match std::fs::read(&path) {
        Ok(bytes) => {
            let listen: Listen = serde_json::from_slice(&bytes)
                .with_context(|| format!("malformed listen.json at {}", path.display()))?;
            Ok(listen)
        }
        Err(file_err) => {
            let bearer = std::env::var("WB_ENGINE_BEARER").unwrap_or_default();
            let engine_url = std::env::var("WB_ENGINE_URL")
                .ok()
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "http://127.0.0.1:4000".to_string());

            if !bearer.is_empty() {
                return Ok(Listen {
                    url: engine_url,
                    token: bearer,
                });
            }

            Err(file_err).with_context(|| {
                format!(
                    "Workhorse daemon not running — discovery file missing at {}, \
                     and no engine env (WB_ENGINE_BEARER) injected. Start the daemon \
                     (open the Workbooks Desktop app, or run the bundled engine binary), \
                     or use the --standalone flows which need no engine.",
                    path.display()
                )
            })
        }
    }
}

pub struct Client {
    pub http: reqwest::Client,
    pub url: String,
    pub token: String,
}

impl Client {
    pub fn connect() -> Result<Self> {
        let listen = read_listen()?;
        let http = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .context("build http client")?;
        Ok(Self {
            http,
            url: listen.url,
            token: listen.token,
        })
    }

    pub async fn post_json<T: for<'de> serde::Deserialize<'de>>(
        &self,
        path: &str,
        body: &serde_json::Value,
    ) -> Result<T> {
        let resp = self
            .http
            .post(format!("{}{path}", self.url))
            .bearer_auth(&self.token)
            .json(body)
            .send()
            .await
            .with_context(|| format!("POST {path}"))?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!("POST {path} failed ({status}): {text}"));
        }
        Ok(resp
            .json::<T>()
            .await
            .with_context(|| format!("parse JSON from POST {path}"))?)
    }

    pub async fn delete_json<T: for<'de> serde::Deserialize<'de>>(
        &self,
        path: &str,
    ) -> Result<T> {
        let resp = self
            .http
            .delete(format!("{}{path}", self.url))
            .bearer_auth(&self.token)
            .send()
            .await
            .with_context(|| format!("DELETE {path}"))?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!("DELETE {path} failed ({status}): {text}"));
        }
        Ok(resp
            .json::<T>()
            .await
            .with_context(|| format!("parse JSON from DELETE {path}"))?)
    }
}
