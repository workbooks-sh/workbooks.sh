// Friend graph via Bluesky follows (wb-8fhk.26).
//
// Source-of-truth: each account's own `app.bsky.graph.follow` records,
// readable via `com.atproto.repo.listRecords` (public, unauthed). Each
// record carries `{subject: did, createdAt: iso8601}` — `subject` is
// the DID being followed. That's the friend graph.
//
// Why listRecords + own records vs. an AppView aggregator
// (app.bsky.graph.getFollows): we want the canonical "self-declared"
// graph for whose follows we trust. AppView results are derived,
// indexed off the firehose, and may lag. listRecords against the data
// PDS gives the user's own truth at the cost of one HTTP page per 100
// follows (cursor-paginated).
//
// Used standalone today (`wb atproto follows`); will back a
// `Network.Friends` engine module that wraps the same lexicon when
// the engine wants in-process access.

use anyhow::{anyhow, Context, Result};
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::session::Session;
use crate::cmd::bluesky_oauth::discover::resolve_pds_from_did;

const FOLLOW_LEXICON: &str = "app.bsky.graph.follow";
const PAGE_SIZE: u32 = 100;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Follow {
    /// at://<did>/app.bsky.graph.follow/<rkey> — the follow record's URI.
    pub uri: String,
    /// The DID being followed (record.value.subject).
    pub subject_did: String,
    /// ISO 8601 timestamp (record.value.createdAt).
    pub created_at: String,
}

pub async fn list_follows(did_override: Option<&str>, json_out: bool) -> Result<()> {
    let (did, pds) = resolve_did_and_pds(did_override).await?;
    if !json_out {
        eprintln!("→ listing follows for {did}");
        eprintln!("→ pds:                {pds}");
    }

    let http = Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;

    let follows = fetch_all_follows(&http, &pds, &did).await?;

    if json_out {
        println!("{}", serde_json::to_string(&follows)?);
    } else {
        println!();
        println!("✓ {} follows", follows.len());
        for f in &follows {
            println!("  {} — followed {}", f.subject_did, f.created_at);
        }
    }
    Ok(())
}

// Resolve the DID + actual data PDS. If `did_override` is None, use the
// bound session. Otherwise resolve the PDS via plc.directory for the
// given DID (public read — works for any did:plc).
async fn resolve_did_and_pds(did_override: Option<&str>) -> Result<(String, String)> {
    match did_override {
        Some(did) => {
            let pds = resolve_pds_from_did(did).await?;
            Ok((did.to_string(), pds))
        }
        None => {
            let session = Session::load()?;
            // session.pds_url MAY be the AS (bsky.social) if the user
            // never published anything since OAuth — re-resolve to
            // guarantee we hit the data PDS.
            let pds = if looks_like_data_pds(&session.pds_url) {
                session.pds_url.clone()
            } else {
                resolve_pds_from_did(&session.did).await?
            };
            Ok((session.did, pds))
        }
    }
}

fn looks_like_data_pds(url: &str) -> bool {
    let host = url
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .split('/')
        .next()
        .unwrap_or("");
    host != "bsky.social"
}

/// Public entry point for callers that already know the (PDS, DID) and
/// just need the follow list — used by `feed::load_friend_set` to build
/// the friend-graph filter.
pub async fn fetch_did_follows(pds: &str, did: &str) -> Result<Vec<Follow>> {
    let http = Client::builder()
        .timeout(std::time::Duration::from_secs(30))
        .build()?;
    fetch_all_follows(&http, pds, did).await
}

async fn fetch_all_follows(http: &Client, pds: &str, did: &str) -> Result<Vec<Follow>> {
    let mut acc = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let page = fetch_page(http, pds, did, cursor.as_deref()).await?;
        acc.extend(page.records.into_iter().map(parse_follow_record));
        cursor = page.cursor;
        if cursor.is_none() {
            break;
        }
    }
    // Drop parse failures rather than aborting the whole list — atproto
    // records carry user-controllable shapes and a single malformed
    // record shouldn't poison the view.
    Ok(acc.into_iter().flatten().collect())
}

struct Page {
    records: Vec<Value>,
    cursor: Option<String>,
}

async fn fetch_page(
    http: &Client,
    pds: &str,
    did: &str,
    cursor: Option<&str>,
) -> Result<Page> {
    let url = format!("{}/xrpc/com.atproto.repo.listRecords", pds.trim_end_matches('/'));
    let mut req = http.get(&url).query(&[
        ("repo", did),
        ("collection", FOLLOW_LEXICON),
        ("limit", &PAGE_SIZE.to_string()),
    ]);
    if let Some(c) = cursor {
        req = req.query(&[("cursor", c)]);
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
    let records = body
        .get("records")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let cursor = body
        .get("cursor")
        .and_then(Value::as_str)
        .map(String::from);
    Ok(Page { records, cursor })
}

fn parse_follow_record(record: Value) -> Option<Follow> {
    let uri = record.get("uri")?.as_str()?.to_string();
    let value = record.get("value")?;
    let subject_did = value.get("subject")?.as_str()?.to_string();
    let created_at = value
        .get("createdAt")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Some(Follow {
        uri,
        subject_did,
        created_at,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_well_formed_follow_record() {
        let record = json!({
            "uri": "at://did:plc:alice/app.bsky.graph.follow/3kabc",
            "cid": "bafyrei...",
            "value": {
                "$type": "app.bsky.graph.follow",
                "subject": "did:plc:bob",
                "createdAt": "2026-06-03T20:49:45.736112Z"
            }
        });
        let f = parse_follow_record(record).unwrap();
        assert_eq!(f.uri, "at://did:plc:alice/app.bsky.graph.follow/3kabc");
        assert_eq!(f.subject_did, "did:plc:bob");
        assert_eq!(f.created_at, "2026-06-03T20:49:45.736112Z");
    }

    #[test]
    fn parse_skips_record_without_subject() {
        let record = json!({
            "uri": "at://did:plc:alice/app.bsky.graph.follow/3kabc",
            "value": {"$type": "app.bsky.graph.follow"}
        });
        assert!(parse_follow_record(record).is_none());
    }

    #[test]
    fn parse_skips_record_without_uri() {
        let record = json!({
            "value": {"subject": "did:plc:bob", "createdAt": "2026-06-03"}
        });
        assert!(parse_follow_record(record).is_none());
    }

    #[test]
    fn parse_tolerates_missing_created_at() {
        let record = json!({
            "uri": "at://did:plc:alice/app.bsky.graph.follow/3kabc",
            "value": {"subject": "did:plc:bob"}
        });
        let f = parse_follow_record(record).unwrap();
        assert_eq!(f.created_at, "");
    }

    #[test]
    fn looks_like_data_pds_distinguishes_as_from_pds() {
        assert!(!looks_like_data_pds("https://bsky.social"));
        assert!(looks_like_data_pds("https://phellinus.us-west.host.bsky.network"));
        assert!(looks_like_data_pds("https://self.example.dev"));
    }
}
