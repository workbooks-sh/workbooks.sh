// PKCE (RFC 7636) code verifier + S256 challenge.
//
// Atproto mandates PKCE with the S256 transform. The verifier is a
// 43-128 char base64url-encoded random string; the challenge is
// `base64url(sha256(verifier))`. We pick 64 bytes of entropy → 86
// chars after base64url, comfortably inside the legal range.
//
// wb-8fhk.22.

use base64::Engine;
use rand::RngCore;
use sha2::{Digest, Sha256};

/// A freshly-generated PKCE pair. The verifier stays in the CLI's
/// memory; the challenge goes out over the wire (PAR body).
#[derive(Debug, Clone)]
pub struct Pkce {
    /// Random secret — NEVER goes over the wire until the token-exchange
    /// step, where we send it back to the AS to prove we're the one who
    /// initiated the dance.
    pub verifier: String,
    /// `base64url(sha256(verifier))` — sent to the AS in the PAR body,
    /// echoed back when the AS issues the auth code.
    pub challenge: String,
}

impl Pkce {
    /// Generate a fresh verifier + S256 challenge.
    pub fn generate() -> Self {
        let mut buf = [0u8; 64];
        rand::thread_rng().fill_bytes(&mut buf);
        let verifier = base64_url(&buf);
        let challenge = s256_challenge(&verifier);
        Self { verifier, challenge }
    }

    /// The transform name the spec calls for — `S256`. Kept as an
    /// accessor (rather than a string-literal sprinkled at call sites)
    /// so a future migration to a different transform happens in one
    /// place.
    pub fn method() -> &'static str {
        "S256"
    }
}

/// `base64url(sha256(verifier))` — the wire form of the challenge.
fn s256_challenge(verifier: &str) -> String {
    let digest = Sha256::digest(verifier.as_bytes());
    base64_url(&digest)
}

/// Unpadded base64url encoding — what every JOSE / OAuth spec wants.
fn base64_url(bytes: &[u8]) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verifier_is_legal_length_and_charset() {
        // 64 bytes of entropy → 86 chars unpadded base64url, comfortably
        // inside RFC 7636's 43-128 char range.
        let p = Pkce::generate();
        assert!(
            p.verifier.len() >= 43 && p.verifier.len() <= 128,
            "verifier out of range: {} chars",
            p.verifier.len()
        );
        for c in p.verifier.chars() {
            assert!(
                c.is_ascii_alphanumeric() || c == '-' || c == '_',
                "illegal verifier char: {c:?}"
            );
        }
    }

    #[test]
    fn challenge_is_correct_s256_of_verifier() {
        // Self-consistency: rebuild the challenge from the verifier
        // and confirm it matches. This is the same check the AS does
        // at token-exchange time.
        let p = Pkce::generate();
        let rebuilt = s256_challenge(&p.verifier);
        assert_eq!(p.challenge, rebuilt);
    }

    #[test]
    fn rfc7636_appendix_b_test_vector() {
        // RFC 7636 Appendix B fixed-input vector — the only way to
        // catch a regression where someone "fixes" the base64
        // alphabet to standard. If this drifts, the AS rejects every
        // call we make.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        assert_eq!(
            s256_challenge(verifier),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        );
    }

    #[test]
    fn two_generations_yield_different_secrets() {
        // Catches a regression where someone seeds the RNG with a
        // constant — would make every login replay-attackable.
        let a = Pkce::generate();
        let b = Pkce::generate();
        assert_ne!(a.verifier, b.verifier);
        assert_ne!(a.challenge, b.challenge);
    }

    #[test]
    fn method_is_s256() {
        // Hard assert — if someone "upgrades" us to PLAIN, the AS
        // will reject the request and we want the test to be the
        // thing that catches it, not a 400 from Bluesky.
        assert_eq!(Pkce::method(), "S256");
    }
}
