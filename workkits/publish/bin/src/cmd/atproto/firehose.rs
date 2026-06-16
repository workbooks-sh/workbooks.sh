// Firehose subscriber for com.atproto.sync.subscribeRepos (wb-8fhk.23).
//
// Each WebSocket message is two CBOR values concatenated:
//   1. Header  — {op: i64, t: "#commit" | "#identity" | "#account" | ...}
//   2. Body    — shape depends on `t`. For #commit, the most common:
//        {
//          seq:      i64,
//          repo:     "did:plc:...",
//          time:     "2026-06-03T...Z",
//          rev:      "abc...",
//          ops:      [{action: "create"|"update"|"delete",
//                      path:   "collection/rkey",
//                      cid:    {/.../}}, ...],
//          blocks:   <CAR bytes — the MST blocks for this commit>,
//          ...
//        }
//
// We filter by lexicon collection at the `ops[*].path` level — no CAR
// decode needed, because the operation list is fully self-describing.
// The actual record content is a follow-up getRecord call (the
// verifier can refetch out-of-band).
//
// Resume on disconnect: subscribeRepos accepts `?cursor=<seq>` to
// rewind. We track the last `seq` we saw and reconnect with it so
// nothing is missed across transient drops.

use anyhow::{anyhow, Result};
use ciborium::Value as CborValue;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::time::Duration;
use tokio_tungstenite::tungstenite::Message;

const RECONNECT_DELAY: Duration = Duration::from_secs(2);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FirehoseHit {
    pub seq: i64,
    pub repo: String,
    pub time: String,
    pub collection: String,
    pub rkey: String,
    pub action: String,
    pub at_uri: String,
}

pub struct Opts {
    pub relay_url: String,
    pub collection: String,
    pub limit: Option<usize>,
    pub json: bool,
    pub cursor: Option<i64>,
}

/// Variant of [`run`] that delivers hits to an mpsc sink instead of
/// writing to stdout. Used by `feed::run` to compose the firehose into
/// a verification pipeline.
pub async fn run_with_sink(
    opts: Opts,
    sink: tokio::sync::mpsc::Sender<FirehoseHit>,
) -> Result<()> {
    let url = build_subscribe_url(&opts.relay_url, opts.cursor);
    let mut current_url = url;
    let mut last_seq: Option<i64> = opts.cursor;
    let mut emitted = 0usize;

    'outer: loop {
        let (ws, _) = match tokio_tungstenite::connect_async(&current_url).await {
            Ok(x) => x,
            Err(_) => {
                tokio::time::sleep(RECONNECT_DELAY).await;
                continue;
            }
        };
        let (_, mut read) = ws.split();
        while let Some(msg) = read.next().await {
            let msg = match msg {
                Ok(m) => m,
                Err(_) => break,
            };
            let bytes = match msg {
                Message::Binary(b) => b,
                Message::Ping(_) | Message::Pong(_) => continue,
                Message::Close(_) => break,
                _ => continue,
            };
            let hits = match decode_commit_hits(&bytes, &opts.collection) {
                Ok(h) => h,
                Err(_) => continue,
            };
            for hit in hits {
                last_seq = Some(hit.seq);
                if sink.send(hit).await.is_err() {
                    // Receiver dropped — caller has stopped consuming.
                    return Ok(());
                }
                emitted += 1;
                if let Some(limit) = opts.limit {
                    if emitted >= limit {
                        break 'outer;
                    }
                }
            }
        }
        current_url = build_subscribe_url(&opts.relay_url, last_seq);
        tokio::time::sleep(RECONNECT_DELAY).await;
    }
    Ok(())
}

pub async fn run(opts: Opts) -> Result<()> {
    let url = build_subscribe_url(&opts.relay_url, opts.cursor);
    if !opts.json {
        eprintln!("→ relay:      {}", opts.relay_url);
        eprintln!("→ collection: {}", opts.collection);
        eprintln!("→ url:        {url}");
        if let Some(n) = opts.limit {
            eprintln!("→ limit:      {n} hits");
        }
        eprintln!("→ Ctrl-C to stop.");
        eprintln!();
    }

    let mut emitted = 0usize;
    let mut current_url = url;
    let mut last_seq: Option<i64> = opts.cursor;

    'outer: loop {
        let (ws, _) = match tokio_tungstenite::connect_async(&current_url).await {
            Ok(x) => x,
            Err(e) => {
                eprintln!("✗ connect failed: {e}. Retrying in {RECONNECT_DELAY:?}…");
                tokio::time::sleep(RECONNECT_DELAY).await;
                continue;
            }
        };
        let (_, mut read) = ws.split();

        while let Some(msg) = read.next().await {
            let msg = match msg {
                Ok(m) => m,
                Err(e) => {
                    eprintln!("✗ stream error: {e}. Reconnecting from seq={last_seq:?}…");
                    break;
                }
            };
            let bytes = match msg {
                Message::Binary(b) => b,
                Message::Ping(_) | Message::Pong(_) => continue,
                Message::Close(_) => {
                    eprintln!("✗ relay closed the connection. Reconnecting from seq={last_seq:?}…");
                    break;
                }
                // Text/frame messages aren't part of atproto firehose protocol.
                _ => continue,
            };

            let hits = match decode_commit_hits(&bytes, &opts.collection) {
                Ok(h) => h,
                Err(_) => continue,
            };

            for hit in hits {
                last_seq = Some(hit.seq);
                if opts.json {
                    println!("{}", serde_json::to_string(&hit).unwrap_or_default());
                } else {
                    println!(
                        "[{}] {} {} {}",
                        hit.time, hit.action, hit.repo, hit.at_uri
                    );
                }
                emitted += 1;
                if let Some(limit) = opts.limit {
                    if emitted >= limit {
                        break 'outer;
                    }
                }
            }
        }

        // Reconnect with the most recently observed seq so the relay
        // resends events we missed during the drop.
        current_url = build_subscribe_url(&opts.relay_url, last_seq);
        tokio::time::sleep(RECONNECT_DELAY).await;
    }

    if !opts.json {
        eprintln!();
        eprintln!(
            "✓ {emitted} hit{} for collection {} (last seq={:?})",
            if emitted == 1 { "" } else { "s" },
            opts.collection,
            last_seq
        );
    }
    Ok(())
}

fn build_subscribe_url(relay: &str, cursor: Option<i64>) -> String {
    let base = format!(
        "{}/xrpc/com.atproto.sync.subscribeRepos",
        relay.trim_end_matches('/')
    );
    match cursor {
        Some(c) => format!("{base}?cursor={c}"),
        None => base,
    }
}

// Decode one firehose frame: two consecutive CBOR values (header + body).
// If the header's `t` is "#commit", walk `body.ops` and yield any op
// matching `collection`. All other event types are silently skipped.
pub(crate) fn decode_commit_hits(bytes: &[u8], collection: &str) -> Result<Vec<FirehoseHit>> {
    let mut cur = Cursor::new(bytes);
    let header: CborValue = ciborium::de::from_reader(&mut cur)
        .map_err(|e| anyhow!("decode header: {e}"))?;
    let body: CborValue = ciborium::de::from_reader(&mut cur)
        .map_err(|e| anyhow!("decode body: {e}"))?;

    let t = cbor_str_field(&header, "t").unwrap_or_default();
    if t != "#commit" {
        return Ok(Vec::new());
    }

    let seq = cbor_int_field(&body, "seq").unwrap_or(0);
    let repo = cbor_str_field(&body, "repo").unwrap_or_default();
    let time = cbor_str_field(&body, "time").unwrap_or_default();
    let ops = cbor_array_field(&body, "ops").unwrap_or_default();

    let mut hits = Vec::new();
    for op in ops {
        let path = cbor_str_field(&op, "path").unwrap_or_default();
        let action = cbor_str_field(&op, "action").unwrap_or_default();
        let Some((c, rkey)) = split_path(&path) else { continue; };
        if c != collection {
            continue;
        }
        let at_uri = format!("at://{repo}/{c}/{rkey}");
        hits.push(FirehoseHit {
            seq,
            repo: repo.clone(),
            time: time.clone(),
            collection: c.to_string(),
            rkey: rkey.to_string(),
            action,
            at_uri,
        });
    }
    Ok(hits)
}

fn split_path(path: &str) -> Option<(&str, &str)> {
    let mut parts = path.splitn(2, '/');
    let c = parts.next()?;
    let rkey = parts.next()?;
    if c.is_empty() || rkey.is_empty() {
        return None;
    }
    Some((c, rkey))
}

// Tiny CBOR field accessors. We avoid full deserialization into a
// strongly-typed struct because the firehose protocol evolves
// (new event types, new fields per type) and we only care about a
// narrow slice of #commit frames.
fn cbor_str_field(v: &CborValue, key: &str) -> Option<String> {
    let map = v.as_map()?;
    for (k, val) in map {
        if k.as_text() == Some(key) {
            return val.as_text().map(String::from);
        }
    }
    None
}

fn cbor_int_field(v: &CborValue, key: &str) -> Option<i64> {
    let map = v.as_map()?;
    for (k, val) in map {
        if k.as_text() == Some(key) {
            return val.as_integer().and_then(|i| i.try_into().ok());
        }
    }
    None
}

fn cbor_array_field(v: &CborValue, key: &str) -> Option<Vec<CborValue>> {
    let map = v.as_map()?;
    for (k, val) in map {
        if k.as_text() == Some(key) {
            return val.as_array().cloned();
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use ciborium::cbor;

    fn encode_frame(header: CborValue, body: CborValue) -> Vec<u8> {
        let mut buf = Vec::new();
        ciborium::ser::into_writer(&header, &mut buf).unwrap();
        ciborium::ser::into_writer(&body, &mut buf).unwrap();
        buf
    }

    #[test]
    fn build_subscribe_url_omits_cursor_when_none() {
        assert_eq!(
            build_subscribe_url("wss://bsky.network", None),
            "wss://bsky.network/xrpc/com.atproto.sync.subscribeRepos"
        );
    }

    #[test]
    fn build_subscribe_url_appends_cursor_when_set() {
        assert_eq!(
            build_subscribe_url("wss://bsky.network/", Some(12345)),
            "wss://bsky.network/xrpc/com.atproto.sync.subscribeRepos?cursor=12345"
        );
    }

    #[test]
    fn split_path_returns_collection_and_rkey() {
        assert_eq!(
            split_path("sh.workbooks.workbook/3kabc"),
            Some(("sh.workbooks.workbook", "3kabc"))
        );
    }

    #[test]
    fn split_path_rejects_empty_components() {
        assert!(split_path("").is_none());
        assert!(split_path("nooomeaningfulrkey").is_none());
        assert!(split_path("/rkey-only").is_none());
        assert!(split_path("collection-only/").is_none());
    }

    #[test]
    fn decode_emits_hit_for_matching_collection() {
        let header = cbor!({ "op" => 1i64, "t" => "#commit" }).unwrap();
        let body = cbor!({
            "seq"  => 42i64,
            "repo" => "did:plc:alice",
            "time" => "2026-06-03T20:49:45Z",
            "ops"  => [
                { "action" => "create",
                  "path"   => "sh.workbooks.workbook/3kabc",
                  "cid"    => null },
                { "action" => "create",
                  "path"   => "app.bsky.feed.post/3mnzz",
                  "cid"    => null }
            ]
        })
        .unwrap();
        let bytes = encode_frame(header, body);

        let hits = decode_commit_hits(&bytes, "sh.workbooks.workbook").unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].repo, "did:plc:alice");
        assert_eq!(hits[0].rkey, "3kabc");
        assert_eq!(hits[0].action, "create");
        assert_eq!(
            hits[0].at_uri,
            "at://did:plc:alice/sh.workbooks.workbook/3kabc"
        );
        assert_eq!(hits[0].seq, 42);
        assert_eq!(hits[0].time, "2026-06-03T20:49:45Z");
    }

    #[test]
    fn decode_emits_nothing_for_non_commit_events() {
        let header = cbor!({ "op" => 1i64, "t" => "#identity" }).unwrap();
        let body = cbor!({ "did" => "did:plc:alice" }).unwrap();
        let bytes = encode_frame(header, body);
        let hits = decode_commit_hits(&bytes, "sh.workbooks.workbook").unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn decode_emits_nothing_when_no_op_matches_collection() {
        let header = cbor!({ "op" => 1i64, "t" => "#commit" }).unwrap();
        let body = cbor!({
            "seq"  => 1i64,
            "repo" => "did:plc:alice",
            "time" => "2026-06-03T20:49:45Z",
            "ops"  => [
                { "action" => "create",
                  "path"   => "app.bsky.feed.post/3mnzz" }
            ]
        })
        .unwrap();
        let bytes = encode_frame(header, body);
        let hits = decode_commit_hits(&bytes, "sh.workbooks.workbook").unwrap();
        assert!(hits.is_empty());
    }

    #[test]
    fn decode_handles_multiple_matching_ops_in_one_commit() {
        let header = cbor!({ "op" => 1i64, "t" => "#commit" }).unwrap();
        let body = cbor!({
            "seq"  => 7i64,
            "repo" => "did:plc:bob",
            "time" => "2026-06-03T20:49:45Z",
            "ops"  => [
                { "action" => "create",
                  "path"   => "sh.workbooks.workbook/r1" },
                { "action" => "update",
                  "path"   => "sh.workbooks.workbook/r2" },
                { "action" => "delete",
                  "path"   => "sh.workbooks.workbook/r3" }
            ]
        })
        .unwrap();
        let bytes = encode_frame(header, body);
        let hits = decode_commit_hits(&bytes, "sh.workbooks.workbook").unwrap();
        assert_eq!(hits.len(), 3);
        assert_eq!(hits[0].action, "create");
        assert_eq!(hits[1].action, "update");
        assert_eq!(hits[2].action, "delete");
    }
}
