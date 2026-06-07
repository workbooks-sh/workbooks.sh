// Substrate endpoint discovery via Bluesky records (wb-8fhk.28).
//
// For private sharing, two engines need to learn how to reach each
// other. Today we have multiple substrate backends (Radicle, R2,
// GitHub-mirror, in-engine git-host); each peer might run a different
// subset. Instead of a central directory, peers publish their reachable
// backends as `sh.workbooks.endpoint` records on their own PDS:
//
//     {
//       "$type": "sh.workbooks.endpoint",
//       "backend": "radicle" | "r2" | "github" | "local",
//       "addr":    "rad:z2..." | "https://r2.example/bucket" | "git@gh:org/repo",
//       "allowed_recipients": ["did:plc:..."]?,   // omit = public to all
//       "createdAt": "2026-06-03T..."
//     }
//
// Discovery: Alice fetches Bob's endpoints via the public listRecords
// API (no auth needed), filters to backends she also runs, then
// picks one. Allowed-recipients lets Bob restrict an endpoint to a
// known set of DIDs (the resulting record itself is still public on
// Bluesky — the filter is advisory; real access control lives in
// the backend's own auth, e.g. Radicle DID gating).

use anyhow::{anyhow, Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use time::OffsetDateTime;

use super::publish::{self, signed_post};
use super::session::Session;
use crate::cmd::bluesky_oauth::discover::resolve_pds_from_did;

pub const LEXICON_ID: &str = "sh.workbooks.endpoint";

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Endpoint {
    pub at_uri: String,
    pub backend: String,
    pub addr: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub allowed_recipients: Vec<String>,
    pub created_at: String,
}

pub async fn publish_endpoint(
    backend: &str,
    addr: &str,
    allowed_recipients: Vec<String>,
    rkey_hint: Option<&str>,
    json_out: bool,
) -> Result<()> {
    let session = publish::ensure_pds_resolved(Session::load()?).await?;
    let http = Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    let created_at = OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .context("formatting createdAt")?;
    let mut record = serde_json::Map::new();
    record.insert("$type".into(), Value::String(LEXICON_ID.into()));
    record.insert("backend".into(), Value::String(backend.into()));
    record.insert("addr".into(), Value::String(addr.into()));
    record.insert("createdAt".into(), Value::String(created_at));
    if !allowed_recipients.is_empty() {
        record.insert(
            "allowedRecipients".into(),
            Value::Array(allowed_recipients.iter().map(|d| Value::String(d.clone())).collect()),
        );
    }

    let mut body = serde_json::Map::new();
    body.insert("repo".into(), Value::String(session.did.clone()));
    body.insert("collection".into(), Value::String(LEXICON_ID.into()));
    body.insert("record".into(), Value::Object(record));
    if let Some(rkey) = rkey_hint {
        body.insert("rkey".into(), Value::String(rkey.into()));
    }

    let url = publish::endpoint(&session.pds_url, "com.atproto.repo.createRecord");
    let resp = signed_post(&http, &session, &url, &Value::Object(body)).await?;
    let status = resp.status();
    let payload: Value = resp.json().await.context("createRecord response not JSON")?;
    if !status.is_success() {
        return Err(anyhow!(
            "createRecord failed: HTTP {status}: {}",
            serde_json::to_string(&payload).unwrap_or_default()
        ));
    }

    let uri = payload["uri"].as_str().unwrap_or("?");
    let cid = payload["cid"].as_str().unwrap_or("?");
    if json_out {
        println!(
            r#"{{"uri":"{uri}","cid":"{cid}","backend":"{backend}","addr":"{addr}"}}"#
        );
    } else {
        println!("✓ endpoint published");
        println!("  uri:     {uri}");
        println!("  cid:     {cid}");
        println!("  backend: {backend}");
        println!("  addr:    {addr}");
        if !allowed_recipients.is_empty() {
            println!("  allowed_recipients ({}):", allowed_recipients.len());
            for d in &allowed_recipients {
                println!("    {d}");
            }
        }
    }
    Ok(())
}

pub async fn list_endpoints(
    did_override: Option<&str>,
    json_out: bool,
) -> Result<()> {
    let (did, pds) = resolve_did_and_pds(did_override).await?;
    if !json_out {
        eprintln!("→ listing endpoints for {did}");
        eprintln!("→ pds:                  {pds}");
    }

    let http = Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;
    let endpoints = fetch_all_endpoints(&http, &pds, &did).await?;

    if json_out {
        println!("{}", serde_json::to_string(&endpoints)?);
    } else {
        println!();
        println!("✓ {} endpoint{}", endpoints.len(), if endpoints.len() == 1 { "" } else { "s" });
        for e in &endpoints {
            let visibility = if e.allowed_recipients.is_empty() {
                "(public)".to_string()
            } else {
                format!("(restricted to {} DIDs)", e.allowed_recipients.len())
            };
            println!("  [{}] {} {} — {}", e.backend, e.addr, visibility, e.at_uri);
        }
    }
    Ok(())
}

pub async fn delete_endpoint(uri: &str, json_out: bool) -> Result<()> {
    // Delegates to the same generic deleteRecord path as workbook
    // deletes — endpoints are just records in a different collection.
    publish::delete_record(uri, json_out).await
}

// ── helpers ─────────────────────────────────────────────────────────

async fn resolve_did_and_pds(did_override: Option<&str>) -> Result<(String, String)> {
    match did_override {
        Some(did) => {
            let pds = resolve_pds_from_did(did).await?;
            Ok((did.into(), pds))
        }
        None => {
            let session = Session::load()?;
            let pds = if session.pds_url.contains("bsky.social") {
                resolve_pds_from_did(&session.did).await?
            } else {
                session.pds_url.clone()
            };
            Ok((session.did, pds))
        }
    }
}

async fn fetch_all_endpoints(http: &Client, pds: &str, did: &str) -> Result<Vec<Endpoint>> {
    let mut acc = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let url = format!("{}/xrpc/com.atproto.repo.listRecords", pds.trim_end_matches('/'));
        let mut req = http.get(&url).query(&[
            ("repo", did),
            ("collection", LEXICON_ID),
            ("limit", "100"),
        ]);
        if let Some(c) = &cursor {
            req = req.query(&[("cursor", c.as_str())]);
        }
        let resp = req.send().await.with_context(|| format!("GET {url}"))?;
        let status = resp.status();
        let body: Value = resp.json().await.context("listRecords response not JSON")?;
        if !status.is_success() {
            return Err(anyhow!(
                "listRecords failed: HTTP {status}: {}",
                serde_json::to_string(&body).unwrap_or_default()
            ));
        }
        if let Some(records) = body.get("records").and_then(Value::as_array) {
            for r in records {
                if let Some(e) = parse_endpoint_record(r) {
                    acc.push(e);
                }
            }
        }
        cursor = body.get("cursor").and_then(Value::as_str).map(String::from);
        if cursor.is_none() {
            break;
        }
    }
    Ok(acc)
}

fn parse_endpoint_record(record: &Value) -> Option<Endpoint> {
    let at_uri = record.get("uri")?.as_str()?.to_string();
    let value = record.get("value")?;
    let backend = value.get("backend")?.as_str()?.to_string();
    let addr = value.get("addr")?.as_str()?.to_string();
    let created_at = value
        .get("createdAt")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let allowed_recipients = value
        .get("allowedRecipients")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(String::from))
                .collect()
        })
        .unwrap_or_default();
    Some(Endpoint {
        at_uri,
        backend,
        addr,
        allowed_recipients,
        created_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_well_formed_endpoint() {
        let record = json!({
            "uri": "at://did:plc:alice/sh.workbooks.endpoint/3kabc",
            "cid": "bafy...",
            "value": {
                "$type": "sh.workbooks.endpoint",
                "backend": "radicle",
                "addr": "rad:z2example",
                "allowedRecipients": ["did:plc:bob", "did:plc:carol"],
                "createdAt": "2026-06-03T20:49:45Z"
            }
        });
        let e = parse_endpoint_record(&record).unwrap();
        assert_eq!(e.backend, "radicle");
        assert_eq!(e.addr, "rad:z2example");
        assert_eq!(e.allowed_recipients, vec!["did:plc:bob", "did:plc:carol"]);
        assert_eq!(e.created_at, "2026-06-03T20:49:45Z");
    }

    #[test]
    fn parse_skips_record_without_backend() {
        let record = json!({
            "uri": "at://did:plc:alice/sh.workbooks.endpoint/3kabc",
            "value": {"addr": "rad:..."}
        });
        assert!(parse_endpoint_record(&record).is_none());
    }

    #[test]
    fn parse_skips_record_without_addr() {
        let record = json!({
            "uri": "at://did:plc:alice/sh.workbooks.endpoint/3kabc",
            "value": {"backend": "radicle"}
        });
        assert!(parse_endpoint_record(&record).is_none());
    }

    #[test]
    fn parse_tolerates_missing_allowed_recipients_field() {
        let record = json!({
            "uri": "at://did:plc:alice/sh.workbooks.endpoint/3kabc",
            "value": {"backend": "r2", "addr": "https://x", "createdAt": "now"}
        });
        let e = parse_endpoint_record(&record).unwrap();
        assert!(e.allowed_recipients.is_empty());
    }
}
