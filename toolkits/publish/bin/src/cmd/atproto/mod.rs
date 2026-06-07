// Standalone AT Protocol operations — publish / delete records to any
// PDS, without requiring the Workbooks runtime engine.
//
// Pairs with `wb identity bluesky-oauth-login --standalone` (which
// persists tokens to the canonical sidecar). This module reads from
// the same sidecar, does DPoP-signed HTTP to the PDS, and emits
// results to stdout.
//
// The engine isn't required for any of:
//   - sign in (`wb identity bluesky-oauth-login --standalone`)
//   - publish (`wb atproto publish <file>`)
//   - delete  (`wb atproto delete <at-uri>`)
//   - show    (`wb atproto status`)
//
// When the engine IS running, it reads the same sidecar, so a user
// who flips between standalone + engine modes never has to re-auth.
//
// wb-8fhk.29.

use anyhow::Result;

use crate::cli::AtprotoCmd;

mod endpoint;
mod feed;
mod firehose;
mod follows;
pub(crate) mod publish;
mod session;

use crate::cli::EndpointCmd;

pub async fn run(cmd: AtprotoCmd) -> Result<()> {
    match cmd {
        AtprotoCmd::Status => session::print_status(),
        AtprotoCmd::Publish { file, title, description, sign, json } => {
            publish::publish_workbook(&file, &title, description.as_deref(), sign, json).await
        }
        AtprotoCmd::Delete { uri, json } => publish::delete_record(&uri, json).await,
        AtprotoCmd::Follows { did, json } => follows::list_follows(did.as_deref(), json).await,
        AtprotoCmd::Firehose { relay, collection, limit, cursor, json } => {
            firehose::run(firehose::Opts {
                relay_url: relay,
                collection,
                limit,
                cursor,
                json,
            })
            .await
        }
        AtprotoCmd::Feed { relay, collection, limit, cursor, from_friends, json } => {
            feed::run(feed::Opts {
                relay_url: relay,
                collection,
                limit,
                cursor,
                from_friends,
                json,
            })
            .await
        }
        AtprotoCmd::Endpoint(sub) => match sub {
            EndpointCmd::Publish { backend, addr, allow, rkey, json } => {
                endpoint::publish_endpoint(&backend, &addr, allow, rkey.as_deref(), json).await
            }
            EndpointCmd::List { did, json } => {
                endpoint::list_endpoints(did.as_deref(), json).await
            }
            EndpointCmd::Delete { uri, json } => {
                endpoint::delete_endpoint(&uri, json).await
            }
        },
    }
}
