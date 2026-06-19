// Verified atproto feed: firehose → fetch → C2PA verify → emit
// (wb-8fhk.24, Layers 2 + 3).
//
// Live-streaming Layer 2 + 3 verification. For each firehose hit
// matching --collection:
//   2. fetch the record, decode the carried bytes, run workbooks-verify
//      --atproto-check (verifies the embedded C2PA manifest's signature
//      AND cross-checks record.repo == manifest.atproto.actor)
//   3. [optional, --from-friends] additionally require record.repo to
//      be in the bound DID's app.bsky.graph.follow set
//
// Standalone: no engine, no broker, no AppView. Bluesky's public relay
// + per-repo PDS reads do all the work.
//
// Persistence of the verified set (the "queryable index" half of .24)
// is a follow-up — that's engine-side because querying needs the OQL
// store. This module ships the live stream so the verification path
// can be exercised end-to-end before the persistence layer lands.

use anyhow::{Context, Result};
use serde::Serialize;
use std::collections::HashSet;
use std::process::Stdio;
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::Mutex;

use super::firehose::{self, FirehoseHit};
use super::follows;
use super::session::Session;
use crate::cmd::bluesky_oauth::discover::resolve_pds_from_did;

#[derive(Debug, Clone, Serialize)]
pub struct VerifiedHit {
    pub at_uri: String,
    pub repo: String,
    pub collection: String,
    pub action: String,
    pub time: String,
    pub seq: i64,
    /// "verified" | "rejected" | "skipped"
    pub status: &'static str,
    /// Why we rejected/skipped, if applicable. Empty for verified.
    pub reason: String,
}

pub struct Opts {
    pub relay_url: String,
    pub collection: String,
    pub limit: Option<usize>,
    pub from_friends: bool,
    pub cursor: Option<i64>,
    pub json: bool,
}

pub async fn run(opts: Opts) -> Result<()> {
    let verify_bin = resolve_verify_bin()?;
    let friends = if opts.from_friends {
        Some(load_friend_set().await?)
    } else {
        None
    };

    if !opts.json {
        eprintln!("→ relay:        {}", opts.relay_url);
        eprintln!("→ collection:   {}", opts.collection);
        eprintln!("→ verify bin:   {}", verify_bin.display());
        if let Some(set) = &friends {
            eprintln!("→ friend gate:  ON ({} DIDs in graph)", set.len());
        } else {
            eprintln!("→ friend gate:  off");
        }
        if let Some(n) = opts.limit {
            eprintln!("→ limit:        {n} verified hits");
        }
        eprintln!("→ Ctrl-C to stop.");
        eprintln!();
    }

    let emitted = Arc::new(Mutex::new(0usize));
    let limit = opts.limit;

    // The firehose runs as a single-process loop; we hook into it by
    // running an inline copy + dispatch on each hit. Sharing the
    // existing firehose::run plumbing would require a callback channel;
    // for now we open our own connection.
    let fopts = firehose::Opts {
        relay_url: opts.relay_url.clone(),
        collection: opts.collection.clone(),
        limit: None, // we count verified hits, not raw hits
        cursor: opts.cursor,
        json: false, // we own the output
    };
    let (tx, mut rx) = tokio::sync::mpsc::channel::<FirehoseHit>(64);
    let firehose_task = tokio::spawn(async move { firehose::run_with_sink(fopts, tx).await });

    while let Some(hit) = rx.recv().await {
        let result = verify_one(&verify_bin, &hit, friends.as_ref()).await;
        let verified = result.status == "verified";

        if opts.json {
            println!(
                "{}",
                serde_json::to_string(&result).unwrap_or_default()
            );
        } else {
            let mark = match result.status {
                "verified" => "✓",
                "rejected" => "✗",
                _ => "·",
            };
            println!(
                "{mark} {} {} {} {}",
                result.status, result.at_uri, result.action,
                if result.reason.is_empty() { "" } else { result.reason.as_str() }
            );
        }

        if verified {
            let mut n = emitted.lock().await;
            *n += 1;
            if let Some(l) = limit {
                if *n >= l {
                    break;
                }
            }
        }
    }

    firehose_task.abort();
    Ok(())
}

async fn verify_one(
    verify_bin: &std::path::Path,
    hit: &FirehoseHit,
    friends: Option<&HashSet<String>>,
) -> VerifiedHit {
    let base = |status: &'static str, reason: String| VerifiedHit {
        at_uri: hit.at_uri.clone(),
        repo: hit.repo.clone(),
        collection: hit.collection.clone(),
        action: hit.action.clone(),
        time: hit.time.clone(),
        seq: hit.seq,
        status,
        reason,
    };

    if hit.action == "delete" {
        return base("skipped", "delete op — nothing to verify".into());
    }

    if let Some(set) = friends {
        if !set.contains(&hit.repo) {
            return base("rejected", "not in friend graph".into());
        }
    }

    let pds = match resolve_pds_from_did(&hit.repo).await {
        Ok(p) => p,
        Err(e) => return base("rejected", format!("pds resolution: {e}")),
    };

    let output = Command::new(verify_bin)
        .arg("--atproto-check")
        .arg(&hit.at_uri)
        .arg("--pds")
        .arg(&pds)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .await;

    match output {
        Ok(o) if o.status.success() => base("verified", String::new()),
        Ok(o) => {
            let code = o.status.code().unwrap_or(-1);
            let stderr = String::from_utf8_lossy(&o.stderr).trim().to_string();
            let summary = match code {
                1 => "signature / hash mismatch",
                2 => "usage or IO error",
                3 => "atproto DID mismatch (record.repo != manifest.actor)",
                _ => "verify failed",
            };
            base(
                "rejected",
                format!(
                    "[exit {code}] {summary}{}",
                    if stderr.is_empty() {
                        String::new()
                    } else {
                        format!(" — {stderr}")
                    }
                ),
            )
        }
        Err(e) => base("rejected", format!("could not invoke verifier: {e}")),
    }
}

async fn load_friend_set() -> Result<HashSet<String>> {
    let session = Session::load().context(
        "--from-friends requires a bound session; run \
         `wb identity bluesky-oauth-login --standalone` first",
    )?;
    let pds = if !session.pds_url.is_empty() && !session.pds_url.contains("bsky.social") {
        session.pds_url.clone()
    } else {
        resolve_pds_from_did(&session.did).await?
    };
    let follows = follows::fetch_did_follows(&pds, &session.did).await?;
    Ok(follows
        .into_iter()
        .map(|f| f.subject_did)
        .collect::<HashSet<_>>())
}

fn resolve_verify_bin() -> Result<std::path::PathBuf> {
    if let Ok(p) = std::env::var("WB_C2PA_VERIFY_BIN") {
        if !p.is_empty() {
            return Ok(std::path::PathBuf::from(p));
        }
    }
    if let Ok(p) = which::which("workbooks-verify") {
        return Ok(p);
    }
    if let Some(exe) = std::env::current_exe().ok() {
        if let Some(dir) = exe.parent() {
            let candidate = dir.join("workbooks-verify");
            if candidate.is_file() {
                return Ok(candidate);
            }
        }
    }
    Err(anyhow::anyhow!(
        "workbooks-verify not found. Build it with: \
         cargo build -p workbooks-manifest --bin workbooks-verify. \
         Or set WB_C2PA_VERIFY_BIN."
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn synth_hit(repo: &str, action: &str) -> FirehoseHit {
        FirehoseHit {
            seq: 1,
            repo: repo.into(),
            time: "2026-06-03T20:49:45Z".into(),
            collection: "sh.workbooks.workbook".into(),
            rkey: "3kabc".into(),
            action: action.into(),
            at_uri: format!("at://{repo}/sh.workbooks.workbook/3kabc"),
        }
    }

    #[tokio::test]
    async fn verify_one_skips_delete_ops() {
        let hit = synth_hit("did:plc:alice", "delete");
        let result = verify_one(&std::path::PathBuf::from("/nonexistent"), &hit, None).await;
        assert_eq!(result.status, "skipped");
        assert!(result.reason.contains("delete op"));
    }

    #[tokio::test]
    async fn verify_one_rejects_non_friend_when_gate_on() {
        let hit = synth_hit("did:plc:stranger", "create");
        let mut friends = HashSet::new();
        friends.insert("did:plc:alice".to_string());
        let result =
            verify_one(&std::path::PathBuf::from("/nonexistent"), &hit, Some(&friends)).await;
        assert_eq!(result.status, "rejected");
        assert!(result.reason.contains("friend graph"));
    }
}
