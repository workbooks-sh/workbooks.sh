// PDS discovery + Authorization Server metadata.
//
// Two lookups before the OAuth dance can start:
//
//   1. handle → PDS URL. Atproto handles resolve through PLC. We POST
//      handle to PLC's directory (`https://plc.directory/<did>`), pull
//      the DID document, find the `#atproto_pds` service endpoint, and
//      that's the PDS. The standard server (`https://bsky.social`) is
//      a safe fallback when the user doesn't pass a handle.
//
//   2. PDS → AS metadata. The AT Protocol AS publishes its OAuth
//      endpoints at `<pds>/.well-known/oauth-authorization-server`
//      (RFC 8414). We need `pushed_authorization_request_endpoint`,
//      `authorization_endpoint`, and `token_endpoint`.
//
// Both lookups are unauthenticated GETs over HTTPS — no credentials
// involved at this stage.
//
// wb-8fhk.22.

use anyhow::{anyhow, Context, Result};
use serde::Deserialize;

const DEFAULT_PDS: &str = "https://bsky.social";

/// OAuth Authorization Server metadata — RFC 8414 §3, slimmed to the
/// three fields we actually call into.
#[derive(Debug, Clone, Deserialize)]
pub struct AsMetadata {
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    pub pushed_authorization_request_endpoint: String,
}

/// Resolve a handle to its PDS URL via the PLC directory. Returns
/// `None` for handles that don't resolve (rare; usually a typo).
///
/// Two-step: handle → DID via `com.atproto.identity.resolveHandle`
/// (unauthed XRPC against the canonical Bluesky resolver), then
/// DID → PDS by GETting `https://plc.directory/<did>` and walking
/// the DID document's `service` array for the `#atproto_pds` entry.
pub async fn resolve_pds(handle: &str) -> Result<String> {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .context("build resolver http client")?;

    // Strip the leading @ users routinely paste.
    let handle = handle.trim_start_matches('@');

    // 1. handle → DID. `bsky.social` runs a public resolveHandle; the
    //    handle's own DNS-record path would also work but adds a
    //    failure mode we don't need at this layer.
    #[derive(Deserialize)]
    struct ResolveResp {
        did: String,
    }
    let resolve_url = format!(
        "https://bsky.social/xrpc/com.atproto.identity.resolveHandle?handle={}",
        url_encode(handle)
    );
    let resp = http
        .get(&resolve_url)
        .send()
        .await
        .with_context(|| format!("GET {resolve_url}"))?;
    if !resp.status().is_success() {
        return Err(anyhow!(
            "could not resolve @{handle} via bsky.social (HTTP {}). \
             Pass --pds-url to skip handle resolution.",
            resp.status()
        ));
    }
    let resolved: ResolveResp = resp
        .json()
        .await
        .context("parse resolveHandle response")?;
    let did = resolved.did;

    // 2. DID → DID document via PLC. did:web (a small minority of
    //    handles) would need a different path; for did:plc the PLC
    //    directory is canonical.
    if !did.starts_with("did:plc:") {
        return Err(anyhow!(
            "handle @{handle} resolved to {did}, which isn't did:plc — \
             OAuth via this path only supports PLC-rooted identities. \
             Pass --pds-url to bypass."
        ));
    }
    let plc_url = format!("https://plc.directory/{did}");
    let doc: serde_json::Value = http
        .get(&plc_url)
        .send()
        .await
        .with_context(|| format!("GET {plc_url}"))?
        .json()
        .await
        .context("parse PLC document")?;

    let pds = pds_from_did_doc(&doc).ok_or_else(|| {
        anyhow!(
            "PLC document for {did} has no #atproto_pds service entry — \
             malformed or migrated identity. Pass --pds-url to bypass."
        )
    })?;
    Ok(pds)
}

/// DID → PDS endpoint, via PLC directory. Used by `wb atproto *`
/// when we already know the user's DID (from a bound OAuth session)
/// and need the actual data PDS URL — which is NOT necessarily the
/// AS URL the OAuth flow used. Bluesky's prod splits these: AS is
/// `bsky.social`, PDS is one of the `*.host.bsky.network` shards.
pub async fn resolve_pds_from_did(did: &str) -> Result<String> {
    if !did.starts_with("did:plc:") {
        return Err(anyhow!(
            "DID {did} isn't did:plc — only PLC-rooted identities resolve via plc.directory"
        ));
    }
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .context("build PLC http client")?;
    let url = format!("https://plc.directory/{did}");
    let doc: serde_json::Value = http
        .get(&url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?
        .json()
        .await
        .context("parse PLC document")?;
    pds_from_did_doc(&doc).ok_or_else(|| {
        anyhow!("PLC document for {did} has no #atproto_pds service entry")
    })
}

/// Pull the PDS service endpoint URL out of a DID document. Pure —
/// unit-testable without network.
pub fn pds_from_did_doc(doc: &serde_json::Value) -> Option<String> {
    let services = doc.get("service")?.as_array()?;
    for s in services {
        let id = s.get("id").and_then(|v| v.as_str()).unwrap_or("");
        let ty = s.get("type").and_then(|v| v.as_str()).unwrap_or("");
        // Per atproto: id is `#atproto_pds`, type is `AtprotoPersonalDataServer`.
        // Match either marker — different implementations populate one or
        // the other; both are spec-legal.
        let is_pds = id.ends_with("#atproto_pds") || ty == "AtprotoPersonalDataServer";
        if is_pds {
            return s
                .get("serviceEndpoint")
                .and_then(|v| v.as_str())
                .map(String::from);
        }
    }
    None
}

/// Fetch the AS metadata document. Per atproto, it's published at
/// `<pds>/.well-known/oauth-authorization-server`. Returns the
/// three endpoints we use; ignores everything else in the doc.
pub async fn fetch_as_metadata(pds_url: &str) -> Result<AsMetadata> {
    let http = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(15))
        .build()
        .context("build metadata http client")?;
    let url = format!(
        "{}/.well-known/oauth-authorization-server",
        pds_url.trim_end_matches('/')
    );
    let resp = http
        .get(&url)
        .send()
        .await
        .with_context(|| format!("GET {url}"))?;
    if !resp.status().is_success() {
        return Err(anyhow!(
            "could not fetch AS metadata from {pds_url} (HTTP {}). \
             Is this a real atproto PDS?",
            resp.status()
        ));
    }
    let meta: AsMetadata = resp
        .json()
        .await
        .context("parse OAuth AS metadata JSON")?;
    Ok(meta)
}

/// "Just pick something" — the default Bluesky PDS for users who
/// don't pass `--handle` or `--pds-url`.
pub fn default_pds() -> &'static str {
    DEFAULT_PDS
}

fn url_encode(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, percent_encoding::NON_ALPHANUMERIC).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pds_from_did_doc_finds_atproto_pds_by_id_fragment() {
        let doc = serde_json::json!({
            "service": [
                {
                    "id": "#atproto_pds",
                    "type": "AtprotoPersonalDataServer",
                    "serviceEndpoint": "https://bsky.social"
                }
            ]
        });
        assert_eq!(
            pds_from_did_doc(&doc),
            Some("https://bsky.social".to_string())
        );
    }

    #[test]
    fn pds_from_did_doc_falls_back_to_type_match() {
        // Some PLC documents emit the full DID-qualified id rather than
        // the bare fragment — both are spec-legal.
        let doc = serde_json::json!({
            "service": [
                {
                    "id": "did:plc:alice#atproto_pds",
                    "type": "AtprotoPersonalDataServer",
                    "serviceEndpoint": "https://pds.example.com"
                }
            ]
        });
        assert_eq!(
            pds_from_did_doc(&doc),
            Some("https://pds.example.com".to_string())
        );
    }

    #[test]
    fn pds_from_did_doc_skips_unrelated_services() {
        let doc = serde_json::json!({
            "service": [
                { "id": "#bsky_appview",
                  "type": "BskyAppView",
                  "serviceEndpoint": "https://api.bsky.app" },
                { "id": "#atproto_pds",
                  "type": "AtprotoPersonalDataServer",
                  "serviceEndpoint": "https://pds.example" }
            ]
        });
        assert_eq!(
            pds_from_did_doc(&doc),
            Some("https://pds.example".to_string())
        );
    }

    #[test]
    fn pds_from_did_doc_returns_none_when_absent() {
        let doc = serde_json::json!({
            "service": [{
                "id": "#bsky_appview",
                "type": "BskyAppView",
                "serviceEndpoint": "https://api.bsky.app"
            }]
        });
        assert_eq!(pds_from_did_doc(&doc), None);

        let no_services = serde_json::json!({});
        assert_eq!(pds_from_did_doc(&no_services), None);
    }

    #[test]
    fn as_metadata_deserializes_realistic_payload() {
        // Mirrors the live https://bsky.social/.well-known/oauth-authorization-server
        // shape — extra fields ignored; the three we need decode cleanly.
        let raw = serde_json::json!({
            "issuer": "https://bsky.social",
            "authorization_endpoint": "https://bsky.social/oauth/authorize",
            "token_endpoint": "https://bsky.social/oauth/token",
            "pushed_authorization_request_endpoint": "https://bsky.social/oauth/par",
            "scopes_supported": ["atproto", "transition:generic"],
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"]
        });
        let meta: AsMetadata = serde_json::from_value(raw).unwrap();
        assert_eq!(meta.authorization_endpoint, "https://bsky.social/oauth/authorize");
        assert_eq!(meta.token_endpoint, "https://bsky.social/oauth/token");
        assert_eq!(
            meta.pushed_authorization_request_endpoint,
            "https://bsky.social/oauth/par"
        );
    }

    #[test]
    fn default_pds_is_bsky_social() {
        assert_eq!(default_pds(), "https://bsky.social");
    }
}
