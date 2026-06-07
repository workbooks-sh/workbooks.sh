// `wb-publish` — Workbooks publish/identity toolkit CLI.
//
// Standalone home of the AT Protocol publishing + Workbooks Network
// identity stack, lifted out of the audited `wb` core (move
// M5-publish-to-toolkit). Same verbs, same on-disk formats, same
// engine contracts:
//
//   identity  — export / import / show / bluesky-login /
//               bluesky-oauth-login / certs / csr
//   atproto   — status / publish / delete / endpoint / follows /
//               feed / firehose
//
// `wb identity …` and `wb atproto …` exec this binary when it's on
// PATH, so existing muscle memory and scripts keep working.

#![forbid(unsafe_code)]

mod cli;
mod cmd;
mod daemon;

use anyhow::Result;
use clap::Parser;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let cli = cli::Cli::parse();
    cli::run(cli).await
}
