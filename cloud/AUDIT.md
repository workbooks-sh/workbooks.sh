# Workbooks Cloud — production readiness audit

Verdict: **the UI shell is broad and the read paths are solid, but it is NOT production-ready.** The
monetization spine (billing + AI credits) is display-only, two backend surfaces have no UI at all, and
several surfaces are missing Update/Delete. Details below.

## 1. CRUD completeness per surface

Legend: ✅ done · ◑ partial · ✗ missing · — n/a

| Surface | Create | Read | Update | Delete | Notes |
|---|---|---|---|---|---|
| **Overview** | — | ✅ | — | — | read-only; **credits stat is `—` (not wired)** |
| **Agents** | ◑ | ✅ | ◑ | ◑ | provision needs Fly creds; lifecycle wired to `/machine/*`; **no agent detail view** |
| **Usage** | — | ◑ | — | — | capacity only; **AI usage (tokens/model/credits) missing entirely** |
| **Data** | ◑ | ◑ | ◑ | ◑ | **all demo/client-side** — no real store (registry + per-tenant path + codec, see DATA.md) |
| **Integrations** | ✅ | ✅ | — | ✅ | connect/disconnect LIVE; **no auth-config setup UI** (only gmail/github/slack connectable) |
| **Channels** | ✗ | ✗ | ✗ | ✗ | **no backend endpoints at all** (Telnyx unbuilt) — honest empty state |
| **Secrets** | ✅ | ✅ | ✗ | ✅ | `PATCH /env/:id` exists but **UI has no edit** (rotate = delete+add) |
| **Team** | ✅ | ✅ | ✗ | ✅ | invite/remove/revoke; **cannot change a member's role** (no endpoint + no UI) |
| **Billing** | ✗ | ◑ | ✗ | — | **display-only**: tiers list; no checkout, no plan change, no invoices, no card, no top-up |
| **Domains** | ✅ | ✅ | — | ✅ | full; add gated on a provisioned nexus |

## 2. Backend surfaces with NO UI (built, unreachable)

- **Workspaces** — `GET/POST/PATCH/DELETE /api/platform/workspaces` is full CRUD, but **there is no
  Workspaces page** in the dashboard. Either add it or consciously drop it.
- **CLI / API tokens** — `POST /tokens/mint`, `GET /tokens`, `DELETE /tokens/:id` exist (this is how the
  `work` CLI authenticates), but **no "API keys / CLI access" surface**. A real product needs this.

## 3. Limits / usage / billing — the biggest gap

The money boundary **exists and enforces** (`Nexus.Inference.Admission`: `enforce` switch, `balance`,
`monthly_cap`, kill-switch → `:insufficient_credit` / `:monthly_cap_exceeded`; `Channels.Admission` mirrors
it for phone). **But almost none of it is surfaced or linked:**

- ✗ **No read endpoint for credit balance / spend / caps.** `Admission` has no public `status/1`, and there's
  no `/credits` route — so the dashboard **cannot show** balance, spend-this-month, or the cap. (Overview's
  credits stat is hard-`—` for this reason.)
- ✗ **No top-up.** Nothing links a Polar payment to increasing `balance`. Credits can be *spent* (metered)
  but never *bought* through the product.
- ✗ **Billing → nothing.** `Nexus.Polar` (checkout/subscription/portal/webhook) is not wired to any button.
  Picking a plan does nothing; there is no subscription, invoice, or payment method.
- ✗ **Tier limits not enforced or shown.** `Polar.plan_limits` (per-tier RAM/storage/phone caps) isn't
  surfaced ("you're on Solo → 1 nexus, N GB") and provisioning isn't gated on a plan.
- ✗ **No usage alerts / near-cap UX.** `Capacity` computes "near capacity" but nothing warns the user.

**Net:** the product can *meter and gate* spend, but a customer cannot *buy, top up, or even see* what they
owe. That's the #1 production blocker — there is no working path from usage → money.

## 4. Production blockers, ranked

1. **Billing is not real.** No Polar checkout, plan change, invoice, card, or credit top-up. **No revenue path.**
2. **AI usage + credits not surfaced or linked** (§3) — add `Admission.status/1` + `GET /credits` + a top-up
   flow, and wire Overview/Usage/Billing to it. This is the core of the business.
3. **The onboarding spine is incomplete.** signup → org works, but **signup → pick a plan → subscribe →
   provision** doesn't (no checkout, no plan-gated provision). New users can't actually become customers.
4. **Provisioning + Domains + Channels need live creds/services** (Fly, Cloudflare, Telnyx). Provision is
   graceful-but-inert locally; Channels is entirely unbuilt.
5. **Data surface is a demo** — real tables need the registry + per-tenant read path + codec (DATA.md).
6. **Two surfaces missing UI** (Workspaces, CLI tokens, §2).

## 5. Smaller gaps + hardening

- **Secrets**: no in-place edit (PATCH unused).
- **Team**: no role change (needs `PATCH /members/:id` + UI).
- **Agents**: no per-agent detail (integrations/number/logs/usage for that agent).
- **Integrations**: no whitelabel **auth-config setup** UI (registering an OAuth client per toolkit), so only
  pre-registered toolkits are connectable; MCP URL not surfaced.
- **Error/empty/loading states**: present on the surfaces I built; unaudited on edge cases (401 refresh,
  network drop mid-action, optimistic rollback).
- **Security/ops**: dev uses an all-zeros `WB_ENV_MASTER_KEY` (prod needs a real one); no rate-limit/abuse
  view; no audit log surface; `require_admin_writes` gates mutations (good) but the UI doesn't always reflect
  role (Team/Secrets do; verify the rest).
- **No account settings** (profile, password change, delete account, sessions) — `/me` is read-only.

## 6. What IS solid

Auth + session + login gate; Secrets (CRUD-minus-edit, e2e-verified); Team (invite/remove/revoke,
e2e-verified); Integrations (live Composio, connect/disconnect e2e-verified); Domains CRUD; the storage/data
read path + charts; the shell (routing, roles, responsive, light-locked). The **read** half of the product is
real; the **write/money** half is where the work is.

## 7. Recommended order to close it

1. **Billing + credits** (§3): `Admission.status/1` → `GET /credits`; wire Polar checkout + a top-up that
   credits `balance`; show balance/spend/cap on Overview + Usage + Billing. *Unblocks revenue.*
2. **Onboarding spine**: signup → plan (Polar) → provision. *Unblocks new customers.*
3. **Missing surfaces**: Workspaces + CLI tokens (both already have backends — pure UI).
4. **Fill CRUD gaps**: Team role change, Secrets edit, agent detail.
5. **Channels** (Telnyx endpoints) + **Data** (the P0 foundations from DATA.md).
6. **Hardening**: account settings, audit log, near-cap alerts, edge states.
