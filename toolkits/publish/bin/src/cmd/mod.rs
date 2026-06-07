// Command-group modules for `wb-publish`.
//
//   `identity`      — export / import / show the Workbooks Network
//                     identity; bind/unbind a Bluesky identity; certs.
//   `bluesky_oauth` — the AT Protocol OAuth 2.0 dance (PKCE + PAR +
//                     DPoP) behind `identity bluesky-oauth-login`.
//   `atproto`       — publish / delete / discover records on any PDS,
//                     plus the verified feed + firehose subscribers.
//   `auth`          — workbooks.sh broker bearer (OAuth loopback +
//                     cache) behind `workbook publish`.

pub mod atproto;
pub mod auth;
pub mod bluesky_oauth;
pub mod identity;
