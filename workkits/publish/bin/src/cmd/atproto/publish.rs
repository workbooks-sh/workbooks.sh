// publish + delete against any PDS, signed with the bound DPoP key
// (or Bearer for legacy app-password sessions). No engine required —
// reads tokens from the sidecar, talks directly to the PDS.
//
// Inline vs blob routing matches the Elixir Network.Atproto:
//   < 200KB  → bytes inlined as `content` in the record
//   ≥ 200KB  → com.atproto.repo.uploadBlob first, record carries a blob ref
//
// Refresh on expiry: if any call comes back 401 with `ExpiredToken`,
// we refresh via com.atproto.server.refreshSession + DPoP, update the
// sidecar, retry once. wb-8fhk.29.

use anyhow::{anyhow, Context, Result};
use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine as _;
use reqwest::{Client, Method, RequestBuilder, Response, StatusCode};
use serde_json::{json, Value};
use std::path::Path;
use time::OffsetDateTime;

use super::session::{AuthKind, Session};
use crate::cmd::bluesky_oauth::discover::resolve_pds_from_did;

const LEXICON_ID: &str = "sh.workbooks.workbook";
const INLINE_BYTE_LIMIT: usize = 200 * 1024;
const CONTENT_TYPE: &str = "application/gzip";

pub async fn publish_workbook(
    file: &Path,
    title: &str,
    description: Option<&str>,
    sign_c2pa: bool,
    json_out: bool,
) -> Result<()> {
    if sign_c2pa {
        return Err(anyhow!(
            "--sign not implemented in this slice; pre-sign with `wb seal` or \
             `workbooks-c2pa-sign` and pass the signed file"
        ));
    }

    let bytes = std::fs::read(file)
        .with_context(|| format!("reading workbook file {}", file.display()))?;
    if !json_out {
        eprintln!("→ workbook: {} ({} bytes)", file.display(), bytes.len());
    }

    let session = ensure_pds_resolved(Session::load()?).await?;
    if !json_out {
        eprintln!(
            "→ bound:   {} ({:?})\n→ pds:     {}",
            session.did, session.auth_kind, session.pds_url
        );
    }

    let http = Client::builder()
        .timeout(std::time::Duration::from_secs(60))
        .build()?;

    let result = do_publish(&http, &session, &bytes, title, description).await?;

    if json_out {
        println!("{}", serde_json::to_string(&result)?);
    } else {
        println!();
        println!("✓ published");
        println!("  uri: {}", result["uri"].as_str().unwrap_or("?"));
        println!("  cid: {}", result["cid"].as_str().unwrap_or("?"));
        println!();
        println!(
            "Verify from any machine (no creds needed):\n  workbooks-verify --atproto-check {}",
            result["uri"].as_str().unwrap_or("at://...")
        );
    }
    Ok(())
}

pub async fn delete_record(uri: &str, json_out: bool) -> Result<()> {
    let (did, collection, rkey) = parse_at_uri(uri)?;
    let session = ensure_pds_resolved(Session::load()?).await?;
    let http = Client::new();

    let url = endpoint(&session.pds_url, "com.atproto.repo.deleteRecord");
    let body = json!({"repo": did, "collection": collection, "rkey": rkey});

    let resp = signed_post(&http, &session, &url, &body).await?;
    let status = resp.status();

    if status.is_success() {
        if json_out {
            println!(r#"{{"ok": true, "uri": "{uri}"}}"#);
        } else {
            println!("✓ deleted {uri}");
        }
        Ok(())
    } else {
        let body = resp.text().await.unwrap_or_default();
        Err(anyhow!("delete failed: HTTP {status}: {body}"))
    }
}

async fn do_publish(
    http: &Client,
    session: &Session,
    bytes: &[u8],
    title: &str,
    description: Option<&str>,
) -> Result<Value> {
    let content_or_blob = prepare_content(http, session, bytes).await?;
    let record = build_record(title, description, &content_or_blob)?;
    let url = endpoint(&session.pds_url, "com.atproto.repo.createRecord");
    let body = json!({
        "repo": session.did,
        "collection": LEXICON_ID,
        "record": record
    });

    let resp = signed_post(http, session, &url, &body).await?;
    let status = resp.status();
    let payload: Value = resp.json().await.context("createRecord response not JSON")?;

    if !status.is_success() {
        return Err(anyhow!(
            "createRecord failed: HTTP {status}: {}",
            serde_json::to_string(&payload).unwrap_or_default()
        ));
    }

    Ok(json!({
        "uri": payload["uri"],
        "cid": payload["cid"],
    }))
}

enum Carrier {
    Inline(Vec<u8>),
    Blob(Value),
}

async fn prepare_content(http: &Client, session: &Session, bytes: &[u8]) -> Result<Carrier> {
    if bytes.len() < INLINE_BYTE_LIMIT {
        Ok(Carrier::Inline(bytes.to_vec()))
    } else {
        let blob = upload_blob(http, session, bytes).await?;
        Ok(Carrier::Blob(blob))
    }
}

async fn upload_blob(http: &Client, session: &Session, bytes: &[u8]) -> Result<Value> {
    let url = endpoint(&session.pds_url, "com.atproto.repo.uploadBlob");
    let req_builder = http
        .request(Method::POST, &url)
        .header("content-type", CONTENT_TYPE)
        .body(bytes.to_vec());
    let resp = with_dpop_retry(http, session, Method::POST, &url, req_builder).await?;

    let status = resp.status();
    let payload: Value = resp.json().await.context("uploadBlob response not JSON")?;
    if !status.is_success() {
        return Err(anyhow!(
            "uploadBlob failed: HTTP {status}: {}",
            serde_json::to_string(&payload).unwrap_or_default()
        ));
    }
    Ok(payload["blob"].clone())
}

fn build_record(title: &str, description: Option<&str>, carrier: &Carrier) -> Result<Value> {
    let created_at = OffsetDateTime::now_utc()
        .format(&time::format_description::well_known::Rfc3339)
        .context("formatting createdAt")?;

    let mut record = serde_json::Map::new();
    record.insert("$type".into(), Value::String(LEXICON_ID.into()));
    record.insert("title".into(), Value::String(title.into()));
    record.insert("createdAt".into(), Value::String(created_at));
    record.insert("contentType".into(), Value::String(CONTENT_TYPE.into()));

    if let Some(desc) = description {
        record.insert("description".into(), Value::String(desc.into()));
    }

    match carrier {
        Carrier::Inline(bytes) => {
            record.insert("content".into(), Value::String(B64.encode(bytes)));
        }
        Carrier::Blob(blob_ref) => {
            record.insert("blob".into(), blob_ref.clone());
        }
    }

    Ok(Value::Object(record))
}

pub(super) async fn signed_post(
    http: &Client,
    session: &Session,
    url: &str,
    body: &Value,
) -> Result<Response> {
    let req_builder = http.post(url).json(body);
    with_dpop_retry(http, session, Method::POST, url, req_builder).await
}

// Try the request with the current access JWT + a fresh DPoP proof.
// Retry policy:
//   - On 401 carrying `error="use_dpop_nonce"` (or just a fresh
//     `DPoP-Nonce` header), retry with the new nonce. bsky.network's
//     PDS rotates the nonce per request, so we loop up to MAX_NONCE_RETRIES.
//   - On 401 with `error="invalid_token"` / `ExpiredToken`, refresh
//     via com.atproto.server.refreshSession + DPoP, save the new
//     session atomically, retry once.
//   - Any other 401 surfaces the original body to the caller.
async fn with_dpop_retry(
    http: &Client,
    session: &Session,
    method: Method,
    url: &str,
    req_builder: RequestBuilder,
) -> Result<Response> {
    const MAX_NONCE_RETRIES: usize = 3;
    let mut nonce: Option<String> = None;

    for attempt in 0..=MAX_NONCE_RETRIES {
        let headers = auth_headers(session, &method, url, nonce.as_deref())?;
        let resp = clone_request_builder(req_builder.try_clone(), &headers)?
            .send()
            .await
            .with_context(|| format!("sending HTTP request (attempt {attempt})"))?;

        if resp.status() != StatusCode::UNAUTHORIZED {
            return Ok(resp);
        }

        let new_nonce = resp
            .headers()
            .get("DPoP-Nonce")
            .and_then(|v| v.to_str().ok())
            .map(String::from);
        let www_auth = resp
            .headers()
            .get("WWW-Authenticate")
            .and_then(|v| v.to_str().ok())
            .map(String::from)
            .unwrap_or_default();
        let body_text = resp.text().await.unwrap_or_default();

        // `use_dpop_nonce` is the explicit signal that the server
        // wants us to retry with the carried nonce. Some PDSes return
        // a fresh nonce on every 4xx, so we also retry whenever the
        // nonce we sent differs from the one we just received.
        let is_nonce_challenge = www_auth.contains("use_dpop_nonce")
            || (new_nonce.is_some() && new_nonce != nonce);

        if is_nonce_challenge && attempt < MAX_NONCE_RETRIES {
            nonce = new_nonce;
            continue;
        }

        // Token-expired path — refresh once, retry once. We use the
        // most recently observed nonce (from this very 401) for the
        // refresh's own DPoP proof.
        if www_auth.contains("invalid_token")
            || body_text.contains("ExpiredToken")
            || body_text.contains("expired")
        {
            let new_session = refresh_session(http, session, new_nonce.as_deref()).await?;
            new_session.save()?;
            let headers = auth_headers(&new_session, &method, url, new_nonce.as_deref())?;
            let resp = clone_request_builder(req_builder.try_clone(), &headers)?
                .send()
                .await
                .context("retry after token refresh")?;
            return Ok(resp);
        }

        return Err(anyhow!(
            "PDS rejected request: HTTP 401: {body_text} (WWW-Authenticate: {www_auth})"
        ));
    }

    Err(anyhow!(
        "DPoP nonce challenge exceeded {MAX_NONCE_RETRIES} retries — \
         server may be rejecting our key rather than just rotating nonces"
    ))
}

fn clone_request_builder(
    rb: Option<RequestBuilder>,
    headers: &[(String, String)],
) -> Result<RequestBuilder> {
    let mut rb = rb.ok_or_else(|| {
        anyhow!("RequestBuilder isn't clonable (streaming body?); can't retry")
    })?;
    for (k, v) in headers {
        rb = rb.header(k, v);
    }
    Ok(rb)
}

fn auth_headers(
    session: &Session,
    method: &Method,
    url: &str,
    nonce: Option<&str>,
) -> Result<Vec<(String, String)>> {
    match session.auth_kind {
        AuthKind::AppPassword => Ok(vec![(
            "Authorization".into(),
            format!("Bearer {}", session.access_jwt),
        )]),
        AuthKind::Oauth => {
            let key = session.dpop_key()?;
            let proof = key.proof(
                method.as_str(),
                url,
                Some(&session.access_jwt),
                nonce,
            )?;
            Ok(vec![
                ("Authorization".into(), format!("DPoP {}", session.access_jwt)),
                ("DPoP".into(), proof),
            ])
        }
    }
}

// Refresh dispatcher — picks the right protocol based on auth_kind.
//   - OAuth: POST to the AS's token_endpoint with grant_type=refresh_token
//     + DPoP proof + client_id (RFC 6749 §6 + atproto OAuth spec).
//   - App-password: POST to <pds>/xrpc/com.atproto.server.refreshSession
//     with Authorization: Bearer <refresh_jwt> (the legacy flow).
async fn refresh_session(
    http: &Client,
    session: &Session,
    nonce: Option<&str>,
) -> Result<Session> {
    match session.auth_kind {
        AuthKind::Oauth => refresh_oauth(http, session, nonce).await,
        AuthKind::AppPassword => refresh_app_password(http, session).await,
    }
}

async fn refresh_oauth(http: &Client, session: &Session, nonce: Option<&str>) -> Result<Session> {
    let session = ensure_oauth_endpoints(session).await?;
    let token_endpoint = session.token_endpoint.as_deref().ok_or_else(|| {
        anyhow!(
            "OAuth refresh requires session.token_endpoint — bound session was \
             written before wb-8fhk.23 added the field. Re-bind with \
             `wb identity bluesky-oauth-login --standalone`."
        )
    })?;
    let client_id = session.client_id.as_deref().ok_or_else(|| {
        anyhow!(
            "OAuth refresh requires session.client_id — bound session was \
             written before wb-8fhk.23 added the field. Re-bind with \
             `wb identity bluesky-oauth-login --standalone`."
        )
    })?;

    let key = session.dpop_key()?;
    // DPoP proof for the token endpoint — no `ath` (the refresh token
    // travels in the form body, not the Authorization header, so the
    // RFC 9449 `ath` claim is omitted).
    let mut nonce: Option<String> = nonce.map(String::from);

    for attempt in 0..3 {
        let proof = key.proof("POST", token_endpoint, None, nonce.as_deref())?;
        let form = vec![
            ("grant_type", "refresh_token".to_string()),
            ("refresh_token", session.refresh_jwt.clone()),
            ("client_id", client_id.to_string()),
        ];
        let resp = http
            .post(token_endpoint)
            .header("DPoP", proof)
            .form(&form)
            .send()
            .await
            .with_context(|| format!("POST {token_endpoint} (refresh attempt {attempt})"))?;

        let status = resp.status();
        let new_nonce = resp
            .headers()
            .get("DPoP-Nonce")
            .and_then(|v| v.to_str().ok())
            .map(String::from);

        if status.is_success() {
            let payload: Value = resp.json().await.context("refresh response not JSON")?;
            let mut new_session = session.clone();
            new_session.access_jwt = payload["access_token"]
                .as_str()
                .ok_or_else(|| anyhow!("refresh response missing access_token"))?
                .into();
            if let Some(refresh) = payload["refresh_token"].as_str() {
                new_session.refresh_jwt = refresh.into();
            }
            return Ok(new_session);
        }

        // 4xx with new nonce — retry with it. Bsky's AS rotates per request.
        if status.as_u16() == 400 || status.as_u16() == 401 {
            if let Some(n) = new_nonce {
                if nonce.as_deref() != Some(n.as_str()) {
                    nonce = Some(n);
                    continue;
                }
            }
        }

        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("OAuth refresh failed: HTTP {status}: {body}"));
    }
    Err(anyhow!("OAuth refresh exceeded 3 nonce retries"))
}

async fn refresh_app_password(http: &Client, session: &Session) -> Result<Session> {
    let url = endpoint(&session.pds_url, "com.atproto.server.refreshSession");
    let resp = http
        .post(&url)
        .header("Authorization", format!("Bearer {}", session.refresh_jwt))
        .send()
        .await
        .context("refreshSession HTTP")?;
    let status = resp.status();
    if !status.is_success() {
        let body = resp.text().await.unwrap_or_default();
        return Err(anyhow!("refreshSession failed: HTTP {status}: {body}"));
    }
    let payload: Value = resp.json().await.context("refresh response not JSON")?;
    let mut new_session = session.clone();
    new_session.access_jwt = payload["accessJwt"]
        .as_str()
        .ok_or_else(|| anyhow!("refresh response missing accessJwt"))?
        .into();
    if let Some(refresh) = payload["refreshJwt"].as_str() {
        new_session.refresh_jwt = refresh.into();
    }
    Ok(new_session)
}

// For OAuth sessions written before token_endpoint was persisted,
// auto-discover via PDS → AS metadata. Persist back so the next call
// skips this hop.
async fn ensure_oauth_endpoints(session: &Session) -> Result<Session> {
    if session.token_endpoint.is_some() {
        return Ok(session.clone());
    }
    let pds = if looks_like_data_pds(&session.pds_url) {
        session.pds_url.clone()
    } else {
        resolve_pds_from_did(&session.did).await?
    };
    let meta = crate::cmd::bluesky_oauth::discover::fetch_as_metadata(&pds).await?;
    let mut updated = session.clone();
    updated.token_endpoint = Some(meta.token_endpoint);
    let _ = updated.save();
    Ok(updated)
}

pub(super) fn endpoint(pds: &str, name: &str) -> String {
    format!("{}/xrpc/{name}", pds.trim_end_matches('/'))
}

// The OAuth flow records `pds_url` as the AS host (atproto allows the
// AS to be a different host from the PDS — Bluesky's prod splits them:
// AS is `bsky.social`, PDS is one of the `*.host.bsky.network` shards).
// For data-plane calls we need the actual PDS. If the recorded URL
// looks like the AS-only host, walk PLC to find the PDS, then persist
// the resolved endpoint back. Idempotent — second call is a no-op.
//
// Also opportunistically backfills the canonical handle if missing
// (wb-8fhk.22.1) — Bluesky's OAuth token exchange doesn't always
// surface the handle alongside the DID + tokens, so existing sessions
// can have handle = "". describeRepo against the PDS is the canonical
// resolution path and works for any did:plc.
pub(super) async fn ensure_pds_resolved(mut session: Session) -> Result<Session> {
    let mut dirty = false;

    if !looks_like_data_pds(&session.pds_url) {
        let resolved = resolve_pds_from_did(&session.did)
            .await
            .with_context(|| format!("resolving PDS for {}", session.did))?;
        if resolved != session.pds_url {
            session.pds_url = resolved;
            dirty = true;
        }
    }

    if session.handle.is_empty() {
        match describe_repo_handle(&session.pds_url, &session.did).await {
            Ok(h) if !h.is_empty() => {
                session.handle = h;
                dirty = true;
            }
            // Don't fail the publish if describeRepo doesn't carry a
            // handle — the DID is the authoritative identifier; handle
            // is cosmetic for our purposes.
            _ => {}
        }
    }

    if dirty {
        // Best-effort persist; non-fatal if the sidecar isn't writable —
        // we still have a usable session in-memory.
        let _ = session.save();
    }
    Ok(session)
}

// com.atproto.repo.describeRepo is a public read (no auth needed) and
// returns {handle, did, didDoc, collections, handleIsCorrect}. The
// `handleIsCorrect` flag guards against the spoofing case where a
// handle's DNS record no longer points back to this DID.
pub(crate) async fn describe_repo_handle(pds: &str, did: &str) -> Result<String> {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;
    let url = endpoint(pds, "com.atproto.repo.describeRepo");
    let body: Value = http
        .get(&url)
        .query(&[("repo", did)])
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .json()
        .await
        .context("parse describeRepo response")?;
    let handle = body
        .get("handle")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    // handleIsCorrect: bsky.social verifies the handle still points to
    // the DID. If it's false, the handle is stale — don't backfill a
    // misleading value.
    let valid = body
        .get("handleIsCorrect")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    if valid { Ok(handle) } else { Ok(String::new()) }
}

fn looks_like_data_pds(url: &str) -> bool {
    // bsky.social is the AS-only host; everything else (custom PDSes,
    // `*.host.bsky.network`, self-hosted instances) is a data PDS.
    let host = url
        .trim_start_matches("https://")
        .trim_start_matches("http://")
        .split('/')
        .next()
        .unwrap_or("");
    host != "bsky.social"
}

// at://did:plc:.../sh.workbooks.workbook/3kabc → (did, collection, rkey)
pub fn parse_at_uri(uri: &str) -> Result<(String, String, String)> {
    let rest = uri
        .strip_prefix("at://")
        .ok_or_else(|| anyhow!("not an at:// URI: {uri}"))?;
    let mut parts = rest.splitn(3, '/');
    let did = parts.next().ok_or_else(|| anyhow!("at:// missing did segment"))?;
    let collection = parts
        .next()
        .ok_or_else(|| anyhow!("at:// missing collection segment"))?;
    let rkey = parts.next().ok_or_else(|| anyhow!("at:// missing rkey segment"))?;
    Ok((did.into(), collection.into(), rkey.into()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_at_uri_round_trip() {
        let (did, coll, rkey) = parse_at_uri(
            "at://did:plc:yogbk7jn7ntuvpers73y6tjj/sh.workbooks.workbook/3mnfyhbat4727",
        )
        .unwrap();
        assert_eq!(did, "did:plc:yogbk7jn7ntuvpers73y6tjj");
        assert_eq!(coll, "sh.workbooks.workbook");
        assert_eq!(rkey, "3mnfyhbat4727");
    }

    #[test]
    fn parse_at_uri_rejects_non_at_scheme() {
        assert!(parse_at_uri("https://example.com/").is_err());
    }

    #[test]
    fn parse_at_uri_rejects_truncated() {
        assert!(parse_at_uri("at://did:plc:abc").is_err());
        assert!(parse_at_uri("at://did:plc:abc/app.bsky.feed.post").is_err());
    }

    #[test]
    fn looks_like_data_pds_distinguishes_as_from_pds() {
        // bsky.social is the AS-only host — must NOT be treated as a data PDS.
        assert!(!looks_like_data_pds("https://bsky.social"));
        assert!(!looks_like_data_pds("https://bsky.social/"));
        assert!(!looks_like_data_pds("http://bsky.social"));
        // Real data PDSes pass.
        assert!(looks_like_data_pds(
            "https://phellinus.us-west.host.bsky.network"
        ));
        assert!(looks_like_data_pds("https://pds.example.com"));
        assert!(looks_like_data_pds("https://self-hosted-pds.dev/"));
    }

    #[test]
    fn endpoint_strips_trailing_slash() {
        assert_eq!(
            endpoint("https://pds.example.com/", "com.atproto.repo.createRecord"),
            "https://pds.example.com/xrpc/com.atproto.repo.createRecord"
        );
        assert_eq!(
            endpoint("https://pds.example.com", "com.atproto.repo.createRecord"),
            "https://pds.example.com/xrpc/com.atproto.repo.createRecord"
        );
    }

    #[test]
    fn build_record_inline_includes_b64_content() {
        let record = build_record(
            "demo",
            Some("desc"),
            &Carrier::Inline(b"hello".to_vec()),
        )
        .unwrap();
        assert_eq!(record["$type"], LEXICON_ID);
        assert_eq!(record["title"], "demo");
        assert_eq!(record["description"], "desc");
        assert_eq!(record["contentType"], CONTENT_TYPE);
        // base64 of "hello" is "aGVsbG8="
        assert_eq!(record["content"], "aGVsbG8=");
        assert!(record["createdAt"].as_str().unwrap().contains("T"));
    }

    #[test]
    fn build_record_blob_carries_ref_not_content() {
        let blob = json!({
            "$type": "blob",
            "ref": {"$link": "bafy..."},
            "mimeType": "application/gzip",
            "size": 250000
        });
        let record = build_record("big", None, &Carrier::Blob(blob.clone())).unwrap();
        assert_eq!(record["blob"], blob);
        assert!(record.get("content").is_none());
        assert!(record.get("description").is_none());
    }
}
