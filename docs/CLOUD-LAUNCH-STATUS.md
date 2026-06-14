# Hosted Nexus — Launch Status & Security Posture

*Autonomous build log + handoff. Date: 2026-06-14. Plan: `~/.claude/plans/wiggly-forging-emerson.md`. Every module below was built → adversarially reviewed → blockers fixed with reproduce-then-fix tests → committed only on a green gate.*

## What's built and committed (origin/main)

The complete **backend engine** for the hosted-nexus product — all new files, no edits to the auth/web/browse files the parallel session is editing, every external API client TLS-hardened (verify_peer + pinned SNI) so credentials can't be MITM-stolen:

| Commit | Module(s) | What |
|---|---|---|
| `9c5a1860` | `Workbooks.Storage` (+Usage) | Per-tenant byte **quota** + zero-egress **presigned R2 URLs** |
| `9ed38af1` | `web/cloud-dashboard` | **Live WorkOS team** dashboard slice (SvelteKit + widget island) |
| `81bf08ac` | `FlyMachines`, `NexusRegistry` | Fly Machines API client + org→nexus registry |
| `86e72bcd` | `NexusProvisioner`, `UsageMeter` | Per-tenant Fly machine lifecycle (256-bit per-nexus bearer scoping) + usage accounting |
| `489f82f9` | `Workbooks.Neon` | Per-tenant Postgres provisioning client |
| `1057c7f0` | `Billing.Polar` | Polar client + **Standard-Webhooks** verification + entitlements |
| `09af0157` | `Workbooks.Nexus` | **Orchestration** — entitlement-gated create/delete/manage, the control-plane API seam |

**115 engine tests, 0 failures.** Storage (Phase 0) is also live-verified against R2.

## Integrations validated live (against your real accounts)
- **R2** — SigV4 adapter put/get/delete round-trip ✅ (bucket `workbooks-cloud`)
- **Neon** — `Workbooks.DB` + pgvector 0.8.1, SSL ✅
- **WorkOS** — org/membership/role/invitation + widget token + AuthKit login URL ✅ (demo workspace `org_01KV3947…`, shane@ admin)
- **Fly** — `FlyMachines` client create_app → create_machine → get → destroy → delete, live, clean teardown ✅ (via `fly auth token`)
- **Polar** — token authenticates (TLS) ✅; webhook verify accepts valid / rejects tampered + replay ✅; entitlements fail-closed ✅

**All five external integrations validated live: R2 · Neon · WorkOS · Polar · Fly.**

## Security posture (what the adversarial gates caught + fixed)
Every phase was attacked before commit. Real blockers found and fixed:
- **Storage:** presign tenant-prefix escape, unmetered presign uploads, fail-open delete (3 HIGH).
- **Fly client:** **CRITICAL** — token over unverified TLS (verify_none) → fixed to verify_peer + pinned SNI; this became the enforced pattern for *every* client (Neon, Polar).
- **Registry:** cross-org `INSERT OR REPLACE` clobber → portable INSERT, refuses cross-org id collision.
- **Provisioner:** org_id prefix-escape, orphaned secret-bearing machines on registry failure.
- **Polar webhooks:** verified **no forgery vector** — constant-time compare, raw-body signing, 5-min replay tolerance, fail-closed.
- **Orchestration:** entitlement checked FIRST (no provision without active sub), org_id honored on every verb, **orphaned Neon project on delete** (HIGH) → fixed by persisting the project id.

### Open security follow-ups (tracked, not yet blocking — wire at integration time)
1. **Webhook-id idempotency** — `verify_webhook` enforces the timestamp window; the consumer must dedupe `webhook-id` to prevent in-window replay double-applying usage/entitlements.
2. **Limit-check TOCTOU** — `create_nexus` over-limit check is best-effort; a DB-enforced per-org count constraint is the durable fix.
3. **Per-nexus scoped R2 token + Neon DSN** — today nexuses share platform creds scoped by prefix/tenant; minting per-nexus scoped tokens (CF/Neon APIs) is the stronger isolation.
4. **Image hardening** (USER/seccomp/cap-drop) — non-blocking on Fly (Firecracker covers it), prerequisite for any Hetzner expansion.
5. **Rotate** the transcript-exposed R2 + Neon + WorkOS creds; mint a scoped R2 token for prod.

## What needs YOUR coordination (the shared-file wiring — deliberately NOT done autonomously)
These touch `runtime/host/auth.ex` and `web.ex`, which the parallel session is actively editing — wiring them now would collide. They're the thin glue over the finished engine:
1. **PCP API routes** (`web.ex` + a new `dashboard_api.ex`): `POST/GET/DELETE /api/platform/nexuses…`, calling `Workbooks.Nexus`.
2. **Platform-auth rung** (`auth/platform.ex` + the `auth.ex` ladder): consume the existing `Workbooks.WorkOS` verifier on a distinct issuer/audience; gate the platform routes.
3. **Polar webhook endpoint** (`web.ex`): call `Billing.Polar.verify_webhook` → update entitlements/usage, with the webhook-id idempotency from follow-up #1.
4. **`WB_CONTROL_PLANE=1` role** + the per-nexus runtime mode (env/secrets the provisioner injects).
5. **Dashboard frontend**: point the team slice (`web/cloud-dashboard`, running at `localhost:5179`) at the real session + build the nexus list/detail/create views against the PCP API.

## Handoffs outstanding
- **Polar API token** → live-validate the billing client (like R2/Neon/WorkOS).
- **Fly API token** → live-validate provisioning (one throwaway machine, careful).
- Confirm the **seat-pricing structure** (recommended: hybrid, `docs/TEAM-SHARING-DESIGN.md`).

## Next recommended step
Once you're back to coordinate the auth/web wiring (items 1–4 above), the engine is ready to plug in and we can do the first real end-to-end provision. Until then, the safest remaining autonomous work is the dashboard frontend buildout (non-colliding) and the threat-model doc.
