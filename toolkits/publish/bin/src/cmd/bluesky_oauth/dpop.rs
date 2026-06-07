// DPoP — Demonstrating Proof of Possession (RFC 9449).
//
// Every OAuth-bound API call from this client to the AS / RS must
// carry a `DPoP` header containing a freshly-signed JWT proving the
// caller still holds the private key the token was bound to. The
// claims are:
//
//   { "htm": "POST",                # HTTP method
//     "htu": "https://...",         # HTTP URL (no query / fragment)
//     "iat": <unix-seconds>,        # issued-at
//     "jti": "<unique>",            # replay defense (random UUID)
//     "nonce": "<server-nonce>",    # if AS sent one in a prior 401
//     "ath": "<sha256(token)>" }    # access-token hash (RS calls only)
//
// JOSE header carries the JWK form of the public key so the verifier
// doesn't have to look it up:
//
//   { "alg": "ES256",
//     "typ": "dpop+jwt",
//     "jwk": { "kty": "EC", "crv": "P-256", "x": "...", "y": "..." } }
//
// We mint ES256 keypairs (NIST P-256). atproto's AS accepts Ed25519
// too, but ES256 is the lowest common denominator and avoids a "which
// curve does the verifier support" round trip.
//
// The PRIVATE KEY is exported as PKCS#8 PEM and persisted to the
// engine, which DPoP-wraps every subsequent atproto call on the
// caller's behalf. The CLI itself only holds the key for the duration
// of the OAuth dance.
//
// wb-8fhk.22.

use anyhow::{anyhow, Context, Result};
use base64::Engine;
use p256::{
    ecdsa::{signature::Signer, Signature, SigningKey},
    pkcs8::EncodePrivateKey,
};
// `ToEncodedPoint` is in scope via `VerifyingKey::to_encoded_point` —
// p256 re-exports it from elliptic_curve; no separate import needed.
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

/// An ES256 signing key plus its public JWK form. The JWK is cached
/// because we embed it in every DPoP JWT header — recomputing per
/// call would burn a SEC1 conversion for no reason.
pub struct DpopKey {
    signing: SigningKey,
    jwk: serde_json::Value,
}

impl DpopKey {
    /// Mint a fresh ES256 keypair. Use one keypair per OAuth session;
    /// rotating mid-session would invalidate the bound access token.
    pub fn generate() -> Self {
        let signing = SigningKey::random(&mut rand::thread_rng());
        let jwk = jwk_from_verifying_key(signing.verifying_key());
        Self { signing, jwk }
    }

    /// PKCS#8-PEM encoding of the private key — the wire form we hand
    /// the engine. Engine reads it with `:public_key.pem_decode/1`.
    pub fn to_pkcs8_pem(&self) -> Result<String> {
        let pem = self
            .signing
            .to_pkcs8_pem(p256::pkcs8::LineEnding::LF)
            .map_err(|e| anyhow!("encode P-256 private key as PKCS8 PEM: {e}"))?;
        Ok(pem.to_string())
    }

    /// Reconstruct a DpopKey from its PKCS#8 PEM. Inverse of
    /// `to_pkcs8_pem`. Used by `wb atproto *` to re-load the bound
    /// OAuth session's DPoP key from the sidecar file on each call.
    pub fn from_pkcs8_pem(pem: &str) -> Result<Self> {
        use p256::pkcs8::DecodePrivateKey;
        let signing = SigningKey::from_pkcs8_pem(pem)
            .map_err(|e| anyhow!("decode P-256 PKCS8 PEM: {e}"))?;
        let jwk = jwk_from_verifying_key(signing.verifying_key());
        Ok(Self { signing, jwk })
    }

    /// Build a DPoP proof JWT for an HTTP request.
    ///
    /// `access_token` is `Some(...)` only for RS calls (the token
    /// exchange itself doesn't need `ath`). `nonce` carries the
    /// server-issued DPoP nonce from a prior 401, if any — atproto's
    /// AS uses these to defend against replay across instances.
    pub fn proof(
        &self,
        method: &str,
        url: &str,
        access_token: Option<&str>,
        nonce: Option<&str>,
    ) -> Result<String> {
        let header = serde_json::json!({
            "alg": "ES256",
            "typ": "dpop+jwt",
            "jwk": self.jwk,
        });

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .context("system clock before UNIX epoch")?
            .as_secs();

        let mut payload = serde_json::json!({
            "htm": method.to_uppercase(),
            "htu": canonical_htu(url),
            "iat": now,
            "jti": uuid::Uuid::new_v4().to_string(),
        });

        if let Some(token) = access_token {
            payload["ath"] = serde_json::Value::String(sha256_b64url(token.as_bytes()));
        }
        if let Some(n) = nonce {
            payload["nonce"] = serde_json::Value::String(n.to_string());
        }

        sign_jwt(&self.signing, &header, &payload)
    }

}

/// Canonical `htu` per RFC 9449: strip query + fragment, keep
/// scheme + authority + path. The AS rebuilds the same form from the
/// incoming request URL and matches verbatim.
fn canonical_htu(url: &str) -> String {
    // We don't pull in `url` crate just for this — manual chop is
    // unambiguous (every URL we send through here is one we built,
    // never user-pasted).
    let no_frag = url.split('#').next().unwrap_or(url);
    let no_query = no_frag.split('?').next().unwrap_or(no_frag);
    no_query.to_string()
}

/// JWK projection of a P-256 public key. Per RFC 7517 + RFC 7518:
/// `kty=EC`, `crv=P-256`, `x` + `y` are unpadded base64url of the
/// affine coordinates (32 bytes each).
fn jwk_from_verifying_key(vk: &p256::ecdsa::VerifyingKey) -> serde_json::Value {
    let point = vk.to_encoded_point(false);
    let x = point.x().expect("uncompressed P-256 point has x");
    let y = point.y().expect("uncompressed P-256 point has y");
    serde_json::json!({
        "kty": "EC",
        "crv": "P-256",
        "x": b64url(x),
        "y": b64url(y),
    })
}

/// Sign `header.payload` with the ES256 key. The signature is the
/// raw 64-byte `r || s` form per RFC 7518 §3.4 — NOT the DER form
/// `to_der()` returns.
fn sign_jwt(
    signing: &SigningKey,
    header: &serde_json::Value,
    payload: &serde_json::Value,
) -> Result<String> {
    let header_b64 = b64url(serde_json::to_vec(header)?.as_slice());
    let payload_b64 = b64url(serde_json::to_vec(payload)?.as_slice());
    let signing_input = format!("{header_b64}.{payload_b64}");

    let sig: Signature = signing.sign(signing_input.as_bytes());
    let sig_bytes = sig.to_bytes(); // 64 bytes — r (32) || s (32)
    let sig_b64 = b64url(&sig_bytes);

    Ok(format!("{signing_input}.{sig_b64}"))
}

/// Unpadded base64url — what every JOSE spec demands.
fn b64url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

/// `base64url(sha256(bytes))` — the `ath` claim form.
fn sha256_b64url(bytes: &[u8]) -> String {
    b64url(&Sha256::digest(bytes))
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::{signature::Verifier, VerifyingKey};

    #[test]
    fn proof_jwt_has_three_segments_and_correct_alg() {
        let key = DpopKey::generate();
        let jwt = key
            .proof("POST", "https://bsky.social/oauth/token", None, None)
            .unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3, "JWT must be header.payload.sig");

        let header_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(parts[0])
            .unwrap();
        let header: serde_json::Value = serde_json::from_slice(&header_bytes).unwrap();
        assert_eq!(header["alg"], "ES256");
        assert_eq!(header["typ"], "dpop+jwt");
        assert_eq!(header["jwk"]["kty"], "EC");
        assert_eq!(header["jwk"]["crv"], "P-256");
    }

    #[test]
    fn proof_claims_carry_htm_htu_jti_iat() {
        let key = DpopKey::generate();
        let url = "https://bsky.social/oauth/token?ignored=1#also-ignored";
        let jwt = key.proof("post", url, None, None).unwrap();
        let payload = decode_payload(&jwt);

        assert_eq!(payload["htm"], "POST", "method must be uppercased");
        // Query + fragment stripped — canonical htu.
        assert_eq!(payload["htu"], "https://bsky.social/oauth/token");
        assert!(payload["jti"].is_string());
        assert!(payload["iat"].as_u64().is_some());
        assert!(
            payload.get("ath").is_none(),
            "no access token → no ath claim"
        );
        assert!(
            payload.get("nonce").is_none(),
            "no nonce → no nonce claim"
        );
    }

    #[test]
    fn proof_with_access_token_includes_ath_hash() {
        let key = DpopKey::generate();
        let token = "test-access-token";
        let jwt = key
            .proof("GET", "https://pds.example/xrpc/foo", Some(token), None)
            .unwrap();
        let payload = decode_payload(&jwt);
        let expected_ath = sha256_b64url(token.as_bytes());
        assert_eq!(payload["ath"], expected_ath);
    }

    #[test]
    fn proof_with_nonce_includes_nonce_claim() {
        let key = DpopKey::generate();
        let jwt = key
            .proof("POST", "https://x", None, Some("server-issued-nonce"))
            .unwrap();
        let payload = decode_payload(&jwt);
        assert_eq!(payload["nonce"], "server-issued-nonce");
    }

    #[test]
    fn signature_verifies_against_embedded_jwk() {
        // Round-trip: parse the JWK out of our own header, rebuild a
        // verifying key, and check the signature. If this passes the
        // AS will too — same RFC 7518 §3.4 conventions.
        let key = DpopKey::generate();
        let jwt = key
            .proof("POST", "https://bsky.social/oauth/token", None, None)
            .unwrap();
        let parts: Vec<&str> = jwt.split('.').collect();
        let signing_input = format!("{}.{}", parts[0], parts[1]);
        let sig_bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(parts[2])
            .unwrap();

        let header = decode_header(&jwt);
        let x = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(header["jwk"]["x"].as_str().unwrap())
            .unwrap();
        let y = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(header["jwk"]["y"].as_str().unwrap())
            .unwrap();
        let mut sec1 = vec![0x04u8]; // uncompressed-point tag
        sec1.extend_from_slice(&x);
        sec1.extend_from_slice(&y);
        let vk = VerifyingKey::from_sec1_bytes(&sec1).unwrap();
        let sig = Signature::from_slice(&sig_bytes).unwrap();
        vk.verify(signing_input.as_bytes(), &sig)
            .expect("freshly-minted proof must verify against its own JWK");
    }

    #[test]
    fn pkcs8_pem_round_trips_through_string() {
        // Engine reads this exact string back. If the PKCS8 envelope
        // shape ever changes (a `p256` major bump), the engine-side
        // test for `Oauth.dpop_proof/3` would catch it; this is the
        // CLI-side sanity check that we ARE producing PKCS8 PEM and
        // not some other PEM.
        let key = DpopKey::generate();
        let pem = key.to_pkcs8_pem().unwrap();
        assert!(pem.starts_with("-----BEGIN PRIVATE KEY-----\n"));
        assert!(pem.contains("-----END PRIVATE KEY-----"));
    }

    #[test]
    fn canonical_htu_strips_query_and_fragment() {
        assert_eq!(canonical_htu("https://x/y"), "https://x/y");
        assert_eq!(canonical_htu("https://x/y?a=1"), "https://x/y");
        assert_eq!(canonical_htu("https://x/y#frag"), "https://x/y");
        assert_eq!(canonical_htu("https://x/y?a=1#frag"), "https://x/y");
    }

    fn decode_payload(jwt: &str) -> serde_json::Value {
        let parts: Vec<&str> = jwt.split('.').collect();
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(parts[1])
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    fn decode_header(jwt: &str) -> serde_json::Value {
        let parts: Vec<&str> = jwt.split('.').collect();
        let bytes = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(parts[0])
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
}
