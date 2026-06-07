// AT Protocol OAuth 2.0 — CLI flow for binding a Bluesky identity to
// the engine via the modern auth path (replaces app-password). See
// https://atproto.com/specs/oauth for the spec we're implementing.
//
// The flow is non-standard OAuth in three ways:
//
//   * PAR (RFC 9126) — push the auth request to the AS before the
//     browser redirect; the redirect carries a `request_uri` instead
//     of the raw client params. Bluesky REQUIRES PAR.
//
//   * PKCE S256 — mandatory, not optional like in vanilla OAuth.
//
//   * DPoP (RFC 9449) — every API call AFTER the dance must carry a
//     fresh DPoP JWT proving possession of a private key the AS bound
//     the access token to. App-password tokens don't need this; OAuth
//     ones do. We mint an ES256 (NIST P-256) keypair locally, prove
//     possession at PAR + token-exchange, and hand the engine the
//     private key so it can keep DPoP-wrapping subsequent requests.
//
// Why ES256 and not Ed25519: atproto says either is fine, but the
// reference AS implementations interop more reliably with ES256
// today. The `p256` crate is already a transitive dep, so no weight
// added.
//
// Loopback callback model: per the atproto spec's loopback profile,
// `client_id` is itself an `http://localhost?redirect_uri=...&scope=...`
// URL. This sidesteps the requirement for a publicly-resolvable
// client metadata document during development. Production gets a
// proper https://workbooks.sh/.well-known/... URL later.
//
// Submodules:
//
//   client    — public entry point (`login`). Orchestrates the dance.
//   dpop      — ES256 keypair + DPoP JWT generation.
//   pkce      — code verifier + S256 challenge generation.
//   discover  — PDS resolution (handle → DID → PDS URL) + AS metadata
//               fetch (.well-known/oauth-authorization-server).
//   server    — loopback HTTP server for the OAuth callback.
//
// wb-8fhk.22.

pub mod client;
pub mod dpop;
pub mod pkce;
pub mod discover;
pub mod server;

// Re-export the single public entry point — `cmd::identity::run` calls
// this and nothing else.
pub use client::login;
pub use client::LoginOpts;
