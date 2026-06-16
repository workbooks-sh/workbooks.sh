
# Goal

  Sign a published Workbook ARTIFACT (HTML/bundle/image) with the tenant's
  identity so provenance travels with the bytes AFTER they leave the platform —
  the "artifact rail" of sharing. Per IDENTITY-GIT-MONOREPO.md: C2PA-sign the
  bytes with the `did:key` BEFORE the carrier; the C2PA manifest BINDS the
  did:key (signing) to a did:plc (ATproto carrier) later. Provenance, not authn.

# The bridge problem (known)

  C2PA's claim signature is COSE over an X.509 cert chain. Our identity is a raw
  Ed25519 `did:key` (`Workbooks.Git`, the same key the signed ledger uses).
  Raw key ≠ X.509 — they don't unify. The plan's answer holds: don't merge them,
  BIND them.

# Finding: feasible with c2patool 0.26 — confirmed

  - `c2patool --signer-path "<cmd>"`: an EXTERNAL signer. c2patool hands the
    claim bytes to the subprocess on stdin; the subprocess writes the signature
    to stdout. ⇒ we sign C2PA claims with OUR Ed25519 private key (the ledger
    key) — c2patool never holds it.
  - `alg: ed25519` is a valid C2PA signature algorithm. No RSA/EC detour.
  - `sign_cert` still required (C2PA mandates X.509 in the manifest). Answer: a
    SELF-SIGNED X.509 cert whose subject public key IS the tenant's Ed25519
    public key. The cert is just a standards-shaped carrier for the same key we
    already publish as `did:key:z6Mk…`. Self-signed is fine — C2PA **trust** (a
    trust list) is a separate, later concern; provenance binding works without it.
  - The `did:key` goes in the manifest as an assertion (CAWG identity assertion,
    `--identity-signer-path`, also signs with our key) so the artifact literally
    carries the DID. Verify = check the COSE sig against the cert's key AND that
    the cert key == the did:key's key.

# The build (next increment) — ~ one module + a signer subcommand

  1. `Workbooks.C2PA.ensure_cert(tenant)`: one-time self-signed Ed25519 X.509
     over the tenant pubkey. Cheapest path: write the priv as PKCS#8 PEM (Ed25519
     PKCS#8 = fixed prefix || 32-byte seed), then =openssl req -x509 -new
     -key key.pem -days N=. openssl signs ed25519 certs natively → far less code
     than hand-rolling ASN.1 in `:public_key`. Cache under `.workbooks/` (already
     gitignored — the cert's private half must stay host-only, same as the key).
  2. `wb _c2pa-sign <tenant>` (internal CLI subcommand): read stdin, Ed25519-sign
     with `Workbooks.Git.sign/2`, write raw sig to stdout. This IS the
     `--signer-path` target — reuses the ledger signer, so artifact + ledger are
     signed by one key.
  3. `Workbooks.C2PA.sign(tenant, asset, out)`: build the manifest JSON
     (`alg: ed25519`, `sign_cert` = the PEM, a did:key assertion), invoke
     =c2patool -m manifest.json --signer-path "wb _c2pa-sign <tenant>" asset
     -o out=. Returns the signed asset path.
  4. `Workbooks.C2PA.verify(asset)`: `c2patool asset --detailed` → parse the
     manifest, confirm the embedded did:key == the cert key == the ledger DID.

# Sub-forks to settle at build time

  - [ ] Cert gen: `openssl` shell (lean, dep on openssl present) vs pure
    `:public_key` ASN.1 (no external dep, more code). Lean → openssl.
  - [ ] What to assert: minimum = did:key + the run's ledger head (so the
    artifact points back to its signed provenance). Ties C2PA ↔ ledger.
  - [ ] Where it fires: on publish (the artifact rail) — wire into the publish
    path, not every run. Opt-in per deliverable.
  - [ ] Trust list: DEFERRED. Self-signed = provenance only; trust-listing is a
    distribution concern for later.

# Verdict

  No blocker — every piece (external signer, ed25519 alg, self-signed cert,
  identity assertion) exists in c2patool 0.26 and reuses the ledger key. This is
  a build, not a research question. Slot after the telemetry+ledger+JJ spine
  (now live). Pairs with ATproto publish (2d) as the two halves of the artifact
  rail.
