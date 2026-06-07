// CLI surface for `wb-publish` — the publish/identity toolkit binary.
//
// Carries the Workbooks Network identity + AT Protocol publishing
// verbs that used to live inside `wb` (cmd/identity.rs, cmd/atproto/,
// cmd/bluesky_oauth/). The `wb` binary's identity/atproto verbs now
// pass through to this binary, so both spellings keep working:
//
//   wb-publish identity show
//   wb-publish identity bluesky-oauth-login --handle alice.bsky.social
//   wb-publish atproto publish dist/book.html --title "My book"
//
// Provider/integration logic belongs in toolkits (minimal-platform
// principle 5); this is the publish toolkit's CLI face.

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(name = "wb-publish", version, about, long_about = None)]
pub struct Cli {
    #[command(subcommand)]
    pub command: TopCommand,
}

#[derive(Debug, Subcommand)]
pub enum TopCommand {
    /// Identity — export / import / show the Workbooks Network identity
    /// (did:key + Ed25519 keypair + WorkOS binding). Use to move the
    /// same identity to a new machine without changing your DID + handle.
    /// Reads/writes the on-disk binding directly — no running engine
    /// required. See wb-8fhk.20.
    #[command(subcommand)]
    Identity(IdentityCmd),

    /// Atproto — publish / delete records to any AT Protocol PDS,
    /// signed with the bound Bluesky session. No engine required.
    /// Pair with `wb-publish identity bluesky-oauth-login --standalone`
    /// to bind first. See wb-8fhk.29.
    #[command(subcommand)]
    Atproto(AtprotoCmd),

    /// Auth — mint/cache the workbooks.sh broker bearer used by
    /// `workbook publish` (browser OAuth via loopback; cached at
    /// ~/.config/workbooks/auth.json). See wb-lcfa.22.
    #[command(subcommand)]
    Auth(AuthCmd),
}

pub async fn run(cli: Cli) -> Result<()> {
    match cli.command {
        TopCommand::Identity(cmd) => crate::cmd::identity::run(cmd).await,
        TopCommand::Atproto(cmd) => crate::cmd::atproto::run(cmd).await,
        TopCommand::Auth(cmd) => crate::cmd::auth::run(cmd).await,
    }
}

// ── Auth ───────────────────────────────────────────────────────────

#[derive(Debug, Subcommand)]
pub enum AuthCmd {
    /// Print a valid broker bearer token. Order: $WORKBOOKS_BEARER →
    /// cache → browser OAuth. stdout carries ONLY the token; progress
    /// goes to stderr — safe to capture from scripts.
    Bearer {
        /// Broker base URL (default: $WORKBOOKS_BROKER or
        /// https://auth.workbooks.sh).
        #[arg(long)]
        broker: Option<String>,
        /// Ignore the cached token and re-run the browser flow.
        #[arg(long)]
        force: bool,
    },
}

// ── Identity ───────────────────────────────────────────────────────

#[derive(Debug, Subcommand)]
pub enum IdentityCmd {
    /// Print the current identity binding (did + handle + public key).
    /// Never includes the private key.
    Show,

    /// Export the identity as a JSON envelope. Default is public-only
    /// (safe to share). Pass --include-private to bundle the Ed25519
    /// private key for cross-machine import — treat as a secret.
    Export {
        /// Write to this file instead of stdout. Refuses to overwrite.
        #[arg(long)]
        out: Option<std::path::PathBuf>,
        /// Include the Ed25519 private key in the export envelope.
        /// REQUIRED for cross-machine identity continuity; OMIT for
        /// "share my DID with a friend" use cases.
        #[arg(long = "include-private")]
        include_private: bool,
    },

    /// Import an identity from a JSON envelope. Refuses to overwrite
    /// an existing binding unless --force is given.
    Import {
        /// Path to the export envelope (produced by `wb-publish identity export --include-private`).
        file: std::path::PathBuf,
        /// Overwrite the existing binding (you'll lose the current
        /// did + private key permanently).
        #[arg(long)]
        force: bool,
    },

    /// Bind a Bluesky identity to this engine — sign in once, then
    /// the engine uses Bluesky as the identity provider for both
    /// public publish (atproto records) AND private share (@handle
    /// resolution → did:plc → substrate push). Requires a running
    /// engine (proxies through /api/network/atproto/bind).
    ///
    /// Reads the app password from --app-password, WB_BSKY_APP_PASSWORD
    /// env var, or stdin prompt (in that order).
    ///
    ///   wb-publish identity bluesky-login alice.bsky.social
    ///   echo "abcd-efgh-..." | wb-publish identity bluesky-login alice.bsky.social
    ///   WB_BSKY_APP_PASSWORD=abcd-... wb-publish identity bluesky-login alice.bsky.social
    BlueskyLogin {
        /// Your Bluesky handle (e.g. alice.bsky.social).
        handle: String,
        /// App password (mint at https://bsky.app/settings/app-passwords).
        /// NOT your account password. Prefer the env var or stdin to
        /// avoid the password ending up in shell history.
        #[arg(long = "app-password")]
        app_password: Option<String>,
        /// Override the PDS URL (default: https://bsky.social).
        #[arg(long = "pds-url")]
        pds_url: Option<String>,
    },

    /// Bind a Bluesky identity to this engine via the modern AT Protocol
    /// OAuth 2.0 flow (PKCE + PAR + DPoP). Opens your default browser to
    /// the Bluesky sign-in page; on consent, the local CLI receives the
    /// authorization code on a loopback port, exchanges it for an
    /// access + refresh token (DPoP-bound), then posts the bundle to
    /// the engine. No app password required.
    ///
    /// Coexists with `bluesky-login` (legacy app-password). Both write
    /// to the same on-disk binding; the new flow tags it `auth_kind:
    /// oauth` so the engine knows to emit DPoP headers on every call.
    ///
    /// Required: a running engine (this is the only side-effect the
    /// CLI doesn't perform locally). Optional: pass `--handle` to
    /// skip the "which PDS?" prompt — the resolver walks PLC to find
    /// your PDS automatically. wb-8fhk.22.
    ///
    ///   wb-publish identity bluesky-oauth-login --handle alice.bsky.social
    ///   wb-publish identity bluesky-oauth-login --pds-url https://my.pds.example
    BlueskyOauthLogin {
        /// Your Bluesky handle (e.g. alice.bsky.social). When set, the
        /// CLI resolves the PDS via the PLC directory; this is the
        /// "just sign me in" path and what 99% of users want.
        #[arg(long)]
        handle: Option<String>,
        /// PDS URL override. Use when you self-host a PDS or your
        /// handle's DID document can't be resolved via PLC. Defaults
        /// to https://bsky.social when neither --handle nor --pds-url
        /// are provided.
        #[arg(long = "pds-url")]
        pds_url: Option<String>,
        /// Loopback callback port. Random by default — set this only
        /// if your firewall pins specific ports. Range: 1024-65535.
        #[arg(long)]
        port: Option<u16>,
        /// Don't auto-open the browser; just print the auth URL to
        /// stdout. Useful when an agent (Claude Code, a CI runner)
        /// is driving the CLI and wants to present the URL to the
        /// user with its own framing. The loopback server still binds
        /// + waits for the callback as usual.
        #[arg(long = "no-open")]
        no_open: bool,
        /// Emit progress events as JSON lines (one event per line)
        /// instead of human-prose. Each line is a complete JSON object;
        /// safe to parse line-by-line. Final line is the result.
        /// Pair with --no-open for clean agent-driven use.
        #[arg(long)]
        json: bool,
        /// Persist tokens directly to <data_root>/Engine/network/identity/
        /// instead of POSTing to a running engine. Use this when you
        /// just want to publish to AT Protocol publicly and don't have
        /// (or want) the Workbooks runtime engine running. The session
        /// file format is identical, so if you later start the engine
        /// it picks up the same binding without migration. wb-8fhk.29.
        #[arg(long)]
        standalone: bool,
    },

    /// Forget the bound Bluesky identity (keeps the engine's did:key intact).
    BlueskyLogout,

    /// Mint (if absent) + cache the X.509 cert that wraps the engine's
    /// Ed25519 key for spec-conformant C2PA signing. Reads the bound
    /// key.b64, writes cert.pem mode 0600 next to it. Idempotent. See
    /// wb-8fhk.21.1.
    EnsureCert {
        /// Emit one-line JSON instead of human-readable text.
        #[arg(long)]
        json: bool,
    },

    /// Print the bound X.509 cert — subject, issuer, validity,
    /// algorithm, serial, fingerprint, key + extended key usage.
    /// Errors if no cert is cached; use `ensure-cert` first.
    ShowCert {
        /// Emit JSON instead of human-readable text.
        #[arg(long)]
        json: bool,
    },

    /// Force re-mint of the X.509 cert (overwrites the cached one).
    /// Use after rotating the underlying Ed25519 key, or to extend
    /// validity. The key itself is NOT touched — only the cert.
    RefreshCert {
        /// Emit JSON instead of human-readable text.
        #[arg(long)]
        json: bool,
    },

    /// Generate a PKCS#10 Certificate Signing Request for submission
    /// to a CAI-trusted parent CA (DigiCert / Sectigo / GlobalSign).
    /// The sub-CA bridge path to CAI Trust List inclusion — see
    /// runtime/docs/C2PA-CAI-PATH.org §2.b. Writes <data_root>/Engine/
    /// network/identity/csr.pem by default. wb-8fhk.21.3.
    GenerateCsr {
        /// Override the output path (default: csr.pem next to key.b64).
        #[arg(long)]
        out: Option<std::path::PathBuf>,
        /// Emit JSON instead of human-readable text.
        #[arg(long)]
        json: bool,
    },
}

// ── Atproto ────────────────────────────────────────────────────────

#[derive(Debug, Subcommand)]
pub enum AtprotoCmd {
    /// Print the bound Bluesky session — did, handle, PDS, auth kind.
    /// Never prints tokens.
    Status,

    /// Publish a workbook file to the bound Bluesky account as a
    /// `sh.workbooks.workbook` lexicon record. Inline-encoded when
    /// < 200KB, uploaded as a blob otherwise. Prints the at:// URI.
    Publish {
        /// Path to the workbook file (any bytes — typically a signed
        /// .html or .wb produced by `wb seal` / `workbooks-c2pa-sign`).
        file: std::path::PathBuf,

        /// Human-readable title shown in feeds and verifier output.
        #[arg(long)]
        title: String,

        /// Optional description (one paragraph).
        #[arg(long)]
        description: Option<String>,

        /// (Reserved) Sign with C2PA before publishing. Not implemented
        /// in this slice — pre-sign with `wb seal` / `workbooks-c2pa-sign`.
        #[arg(long)]
        sign: bool,

        /// Emit newline-delimited JSON to stdout instead of human-readable text.
        #[arg(long)]
        json: bool,
    },

    /// Delete a previously-published record by its at:// URI.
    Delete {
        /// at://did:plc:.../sh.workbooks.workbook/<rkey>
        uri: String,

        /// Emit JSON instead of human-readable text.
        #[arg(long)]
        json: bool,
    },

    /// Substrate endpoint discovery via sh.workbooks.endpoint records.
    /// Publish your reachable backends (Radicle/R2/GitHub/...) as
    /// public records so peers can discover them. See wb-8fhk.28.
    #[command(subcommand)]
    Endpoint(EndpointCmd),

    /// List the follows declared by an account — the source-of-truth
    /// friend graph from app.bsky.graph.follow records on the user's
    /// own PDS. Defaults to the bound session's DID; pass --did to
    /// query a different account (public read, no auth needed).
    /// See wb-8fhk.26.
    Follows {
        /// Override the bound session's DID. Useful for inspecting
        /// someone else's public follow graph.
        #[arg(long)]
        did: Option<String>,

        /// Emit JSON instead of human-readable text.
        #[arg(long)]
        json: bool,
    },

    /// Verified atproto feed — firehose → C2PA-verify → emit only
    /// records whose embedded manifest validates AND cross-checks
    /// against the record's repo DID. Optional --from-friends gate
    /// requires the publisher to be in the bound DID's app.bsky.graph.follow
    /// set. See wb-8fhk.24.
    Feed {
        /// WebSocket URL of the relay. Default is the public Bluesky
        /// relay (bsky.network); self-hosted relays work too.
        #[arg(long, default_value = "wss://bsky.network")]
        relay: String,

        /// Lexicon collection name to filter on.
        #[arg(long, default_value = "sh.workbooks.workbook")]
        collection: String,

        /// Stop after this many VERIFIED hits (rejected/skipped don't count).
        #[arg(long)]
        limit: Option<usize>,

        /// Resume from this seq (the last `seq` field you previously emitted).
        #[arg(long)]
        cursor: Option<i64>,

        /// Layer 3 gate — only verify records published by accounts the
        /// bound DID follows. Requires a bound session.
        #[arg(long)]
        from_friends: bool,

        /// Emit one JSON object per hit (verified or rejected), newline-delimited.
        #[arg(long)]
        json: bool,
    },

    /// Subscribe to the atproto firehose and stream commits whose
    /// ops touch records of `--collection`. Auto-reconnects with
    /// the last-seen seq on transient drops. Ctrl-C to stop.
    /// See wb-8fhk.23.
    Firehose {
        /// WebSocket URL of the relay. Default is the public Bluesky
        /// relay (bsky.network); self-hosted relays work too.
        #[arg(long, default_value = "wss://bsky.network")]
        relay: String,

        /// Lexicon collection name to filter on (exact match).
        /// Default surfaces only Workbooks records.
        #[arg(long, default_value = "sh.workbooks.workbook")]
        collection: String,

        /// Stop after this many matching hits (useful for one-shot
        /// validation / smoke tests). Omit to stream indefinitely.
        #[arg(long)]
        limit: Option<usize>,

        /// Resume from this seq (the last `seq` field you previously
        /// emitted). Omit to start at the relay's tail.
        #[arg(long)]
        cursor: Option<i64>,

        /// Emit one JSON object per matched op (newline-delimited).
        #[arg(long)]
        json: bool,
    },
}

// ── Atproto / Endpoint ─────────────────────────────────────────────

#[derive(Debug, Subcommand)]
pub enum EndpointCmd {
    /// Publish a sh.workbooks.endpoint record advertising a backend
    /// you can be reached on (Radicle node, R2 bucket, GitHub repo,
    /// in-engine git host, etc.). Anyone querying your PDS for
    /// endpoint records will see it. Use --allow to restrict the
    /// advisory recipient list (the record itself stays public —
    /// real access control lives in the backend's own auth).
    Publish {
        /// Backend identifier: radicle | r2 | github | local | <custom>.
        #[arg(long)]
        backend: String,

        /// Backend-specific reachability address — Radicle ID, R2
        /// bucket URL, git remote, etc.
        #[arg(long)]
        addr: String,

        /// Optional did:plc:... entries this endpoint advertises to.
        /// Repeat the flag for each. Omit = public to all.
        #[arg(long = "allow")]
        allow: Vec<String>,

        /// Optional rkey to use (default: TID-generated). Use a stable
        /// rkey like the backend name (`radicle`) to make
        /// updates upsert-style.
        #[arg(long)]
        rkey: Option<String>,

        #[arg(long)]
        json: bool,
    },

    /// List a DID's published endpoints. Defaults to the bound DID.
    List {
        #[arg(long)]
        did: Option<String>,

        #[arg(long)]
        json: bool,
    },

    /// Delete an endpoint record by its at:// URI.
    Delete {
        uri: String,

        #[arg(long)]
        json: bool,
    },
}
