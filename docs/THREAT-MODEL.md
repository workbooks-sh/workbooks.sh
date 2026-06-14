# Hosted Nexus — Threat Model & Attack Surface

*Date: 2026-06-14. Consolidates the per-module adversarial reviews into one attack-surface map: entry points, trust boundaries, threats, the mitigations already in place, and residual risks. Companion to `docs/CLOUD-LAUNCH-STATUS.md`.*

## Trust boundaries (the planes)
1. **Platform plane** — WorkOS-authenticated dashboard users; `org_id` is the ownership key. Owns nexuses, billing, team.
2. **App plane** — a tenant's deployed app authenticating its OWN end-users (BetterAuth/OIDC). Distinct issuer/audience → no cross-plane token replay.
3. **Host control plane (PCP)** — holds the master credentials (Fly API token, Neon API key, Polar token, R2 keys, WorkOS API key). The highest-value target.
4. **Per-tenant nexus** — one Fly Machine (Firecracker), single-tenant (`WB_TENANT=org`), per-nexus bearer + scoped storage prefix.
5. **WASM guest sandbox** — untrusted tenant code; wasmtime + NetGuard + Policy (the pre-existing Three Walls — out of scope here, already hardened).

## Attack surfaces & posture

| Surface | Top threats | Mitigations IN PLACE (tested) | Residual / follow-up |
|---|---|---|---|
| **External API clients** (Fly, Neon, Polar) | MITM steals the master token off the wire; token in logs/errors | **TLS `verify_peer` + cacerts + pinned SNI** on every client (the Phase-2a CRITICAL, now the enforced pattern); token added only in the private `do_request`, never in `build_request` output / logs / error tuples; fixed API host (no SSRF); 8 MB body cap | Rotate transcript-exposed creds; per-nexus scoped tokens (vs shared master) |
| **Polar webhook** (→ entitlements) | Forged webhook grants free unlimited provisioning; replay | **Standard Webhooks**: constant-time compare, raw-body signing, base64 secret, 5-min replay tolerance, **fail-closed** on every path — adversarial pass found **no forgery vector** | **webhook-id idempotency** in the consumer (dedupe within the window) — wire at endpoint time |
| **Nexus registry** (org→nexus) | Cross-org read/mutate/delete (IDOR); id-collision clobber | Every op `WHERE org_id = ?`; cross-org → `:not_found`; portable `INSERT` refuses cross-org id collision; nil/empty org fails closed; strict org_id shape | — |
| **Provisioner** (secret scoping) | Nexus A gets nexus B's secrets; shared bearer; orphaned secret-bearing machines | 256-bit **per-nexus** `WB_PUBLIC_BEARER` (distinct per provision); secrets only in the machine config, never in the registry/logs; unforgeable random app name; ownership-gated lifecycle verbs (no Fly call cross-org); **rollback** of orphaned machines on registry failure | `fly_org` pinned to config |
| **Storage** (per-tenant blobs) | Quota bypass; presigned-URL prefix escape; fail-open delete | Reserve-before-write **fail-closed** quota; presign is metered + signs Content-Length; **tenant scrubbed as the isolation boundary**; delete fails closed | Background reconcile (ledger vs backend); per-nexus scoped R2 token |
| **Orchestration** (`Workbooks.Nexus`) | Provision without active subscription; over-limit; cross-org; orphaned DB on delete | **Entitlement gate FIRST**, fail-closed; over-limit gate; org_id validated before any resource create; delegates ownership to gated collaborators; **persists Neon project id → releases it on delete** (no orphaned tenant Postgres) | Limit-check **TOCTOU** (needs DB-enforced count) |
| **Platform vs app auth** | Cross-plane token replay (a tenant's app JWT acting on the platform) | Design: distinct issuers/audiences/JWKS; `Workbooks.WorkOS` verifier separate from the app-plane Guardian path | **Not yet wired** — the platform rung + the cross-plane-rejection tests land with the auth coordination |
| **Dashboard** (web) | Secret exposure to the client; XSS | Widget token minted **server-side** (API key never reaches the browser); `.env` gitignored | Real session (vs dev-pinned org/user) wires in with the auth callback |

## Recurring discipline (applied to every module)
- **Fail closed** everywhere (missing/garbage input → deny, never allow).
- **TLS peer-verified** on every outbound credentialed call.
- **org_id is the boundary** — scoped in the SQL `WHERE`, validated for shape, nil = no access.
- **Reproduce-then-fix tests** — every security fix has a test verified to fail pre-fix, pass post-fix (via surgical revert).
- **Adversarial gate before commit** — 6 of the build phases had a HIGH/CRITICAL caught and fixed *before* landing.

## Test coverage
- **Adversarially tested:** storage quota/presign, Fly client (TLS/SSRF/token), registry isolation, provisioner secret-scoping + ownership, Neon client, Polar webhook forgery + entitlements, orchestration entitlement/ownership/rollback. **115 engine tests, 0 failures.**
- **NOT yet tested (needs integration + tokens):** end-to-end provision against live Fly; live Polar webhook delivery; the platform-auth rung + cross-plane rejection (lands with the auth wiring); the PCP API IDOR surface (lands with the routes).

## Top residual risks (ranked, for the launch checklist)
1. **Wire the platform-auth rung + cross-plane-rejection tests** — the one large untested boundary (gated on the auth-session coordination).
2. **Webhook-id idempotency** at the Polar endpoint — before billing goes live.
3. **Rotate** the transcript-exposed R2 / Neon / WorkOS creds; mint scoped per-tenant tokens.
4. **Limit-check TOCTOU** — DB-enforced per-org nexus count.
5. **Image hardening** (USER/seccomp/cap-drop) — before any Hetzner expansion (Fly Firecracker covers it for launch).
