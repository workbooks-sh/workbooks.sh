# publish

AT Protocol publishing plus Workbooks Network identity: bind a Bluesky account, publish signed workbooks, and watch the verified (C2PA-checked) feed. The toolkit owns the `wb-publish` binary — the publish/identity stack lifted out of the `work` core so provider logic lives in a toolkit.

## When to reach for it

Reach for `publish` when a workbook should be published to the network with a verifiable identity — exporting/importing your did:key + Ed25519 keypair across machines, binding a Bluesky account, and signing artifacts for the verified feed.

## Example

```
cargo install --path toolkits/publish/bin
wb-publish identity bluesky-login        # bind a Bluesky account (or OAuth PKCE)
wb-publish atproto publish workbook.html # publish a signed sh.workbooks.workbook record
```

## What it grants

- `wb-publish identity`: did:key + Ed25519 keypair export/import, Bluesky binding (app-password or OAuth 2.0 PKCE + PAR + DPoP; `--standalone` needs no engine), X.509 cert for C2PA signing, CSR generation.
- `wb-publish atproto`: publish/delete `sh.workbooks.workbook` records on any PDS, advertise substrate endpoints, read follow graphs, stream the firehose, run the verified feed.
- Engine-bind verbs talk to the Workhorse daemon; everything else reads/writes the on-disk identity sidecar directly — no engine required.

## Maturity

Stable (v0.1.0). Requires the `wb-publish` binary (built from the toolkit's `bin/` crate).
