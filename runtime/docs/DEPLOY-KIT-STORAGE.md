
# The goal

Deploy-kit is the EXTENSIBLE way to stand up a runtime. An operator should lock
in whatever backend they already run — Cloudflare R2, AWS S3, a Fly volume,
Postgres on CrunchyData / Fly / Railway / Neon / Supabase — in a **simple, clear**
way, without touching runtime code. Identity + user data stay secured by the
EXISTING BetterAuth → Guardian system regardless of which backend is plugged in.

The principle (same as the Browse provider slot, the auth knob): the runtime
talks to an INTERFACE; a backend is selected by config and implements a few
callbacks. Adding a provider = one adapter module + one config line, never a
fork.

# Two data classes (they want different backends)

- **Blobs / repos** — tenant git repos, self-contained workbook `.html`s (legacy
  `.wbundle`s too), signed artifacts, VFS files,
  sealed ledgers. Large, opaque, content-addressed. → object store (R2/S3) or a
  volume. Interface: `Workbooks.Storage`.
- **Structured / queryable** — vars, agent memory, the telemetry+ledger index, the
  command/package registry, tenant metadata. Small, relational, queried. →
  Postgres (BYO provider = just a URL) or local SQLite. This is the "BYOD
  database."

Keeping them separate is the point: you might put blobs on R2 and structured
data on Railway Postgres, or both on a Fly volume for a simple single-box deploy.

# The blob interface — `Workbooks.Storage`

A behaviour, tenant-scoped by construction (isolation can't be forgotten):
  - `put(tenant, key, bytes)`
  - `get(tenant, key) :: {:ok, bytes} | :error`
  - `list(tenant, prefix) :: [key]`
  - `delete(tenant, key)`
Adapters:
  - `Storage.Local` — filesystem under `WB_DATA` (default; a Fly volume is just
    this with a mount — durable with zero code change).
  - `Storage.S3` — S3 AND Cloudflare R2 (R2 is S3-compatible: same adapter, the
    endpoint + bucket are config). One adapter, two-plus providers.
Selected by =WB_STORAGE=local|s3=; creds/endpoint/bucket via secrets.

# The structured interface — BYO Postgres

The SQLite-backed stores (Vars / Memory / Ledger index / Registry) gain a Postgres
path when `WB_DATABASE_URL` is set (Ecto/Postgrex — already a dep). ANY Postgres
provider works because it's just a connection URL — CrunchyData, Fly PG, Railway,
Neon, Supabase are indistinguishable to the runtime. Absent the URL → local
SQLite (the simple single-box default). No URL parsing per-provider; one code path.

# Identity persistence (DONE — the precondition)

The Ed25519 signing key is restored deterministically from `WB_SIGNING_KEY` (a
Fly secret) so the tenant DID survives redeploys (`Workbooks.Git`). Before this,
every deploy minted a new DID and broke prior signatures. Per-tenant keys move
into the structured store when multi-tenant goes live.

# Auth + security — UNCHANGED, reaffirmed

- BetterAuth issues JWTs (login / OAuth / API keys); Guardian verifies via JWKS
  and scopes every request to `organizationId` = tenant. Stateless verify — no DB
  needed just to authenticate.
- **Every storage + db op takes the tenant as a first-class argument**, so tenant
  isolation is enforced ABOVE the backend — swapping R2 for a volume can't widen
  access. The access graph (`Workbooks.Library`) + Policy caps gate what a tenant
  may touch; the backend just stores it.
- All backend credentials (DB URL, S3 keys, signing seed) live in Fly Secrets /
  the platform secret store — never in the image or plaintext env.
- Privacy-by-default (`Workbooks.Private`) still strips session/personal data on
  every egress regardless of backend.
- Future hardening (noted, not yet): per-tenant at-rest blob encryption with a
  tenant data key; the libkrun/Firecracker microVM boundary for multi-tenant
  compute isolation.

# The deploy-kit knob (simple + clear)

A deploy profile sets, as secrets/env:
  - `WB_STORAGE` = `local` | `s3`            ; + `WB_S3_ENDPOINT/BUCKET/KEY/SECRET` (R2 = its endpoint)
  - `WB_DATABASE_URL` = postgres://…         ; optional; else SQLite
  - `WB_SIGNING_KEY` = base64 seed           ; identity continuity (done)
  - auth: BetterAuth issuer/JWKS (existing knob)
One screen of config picks the whole storage + identity posture; the runtime code
is identical across every deployment.

# Build order (the loop)

1. `Workbooks.Storage` behaviour + `Storage.Local` adapter + `WB_STORAGE` select.
2. Route blob writes (Bundle ship/pack outputs, published artifacts) through it.
3. `Storage.S3` adapter (S3/R2) — verify against a real bucket, clean up.
4. BYO Postgres for the structured stores (Vars/Memory/Ledger index) behind
   `WB_DATABASE_URL`; SQLite stays the default.
5. Deploy-kit profile + docs: the one-screen config, secrets list, per-provider
   notes (R2 endpoint, Railway/CrunchyData URL).
6. Verify tenant-scoping holds across every backend.
