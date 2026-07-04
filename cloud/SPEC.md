# Workbooks Cloud — product spec

> The **management plane** for the promises autopoet makes but can't keep alone.
> Autopoet-local is the embodied agent (chat, voice, avatar, integrations). Everything that is
> *always-on, costs money, needs central credentials, or needs an account* lives here.

Status: **ground-up rebuild.** v0 (`experiments/old-cloud-ui`, git `9400c5af`) set the *thesis* —
simple: your infra + your usage, no Studio bloat. This spec replaces it. Most backends already exist
(and several were verified green this session); the new work is design, the AI-usage migration, and the
business-logic wiring between them.

---

## 1. Principle

- **Simple, like v0.** Not the Slack-style Studio (that heavy SPA is being deprecated to `experiments/`).
- **A control panel, not an app.** You come here to provision, connect, top up, and check usage — then
  you leave and talk to your autopoet (desktop / phone / web).
- **Every surface is a thin UI over a real BEAM backend.** No new runtime logic in the UI; it calls the
  control-plane API the same way the `work` CLI does.

## 2. The eight surfaces

Each = *promise → what it manages → backend module (exists ✅ / partial ◐ / missing ✗) → new work*.

### 2.1 Your hosted autopoet(s) — "your autopoet is always on"
- Manages: provision / status / roll-to-new-image / suspend / kill your per-tenant autopoet-nexus.
- Backend: `Nexus.Cloud.provision/2`, `Nexus.Cloud.update_image/3`, `Nexus.Fly` (Machines API) ✅
- New: the machines list + a per-nexus detail view (region, state, image, uptime); the lifecycle UX.

### 2.2 AI usage & credits — "talk to it all day"  ← THE HEAVIEST, and the migration you named
- Manages: token/cost metering by model, credit balance, top-ups, monthly caps, provider routing.
- Backend: `Nexus.Llm` (**Cloudflare AI Gateway** default via `CF_AIG_URL`/`CF_AIG_TOKEN`; OpenRouter
  fallback), `Nexus.Inference.Admission` (the credit/monthly-cap/kill money boundary), `Inference.Pricing`
  (catalog pricing), `Nexus.Polar` (credit product / top-ups) ✅
- New: **migrate the AI-usage UI over from the newer (Cloudflare) cloud app** — the usage charts, the
  spend-by-model breakdown, the credit balance + top-up flow, the cap controls. This is its own workstream.

### 2.3 Integrations — "connect your tools"
- Manages: the Composio catalog, connect/disconnect accounts, whitelabel OAuth, MCP-per-user.
- Backend: `Autopoet.Composio` (toolkits/tools/connect/execute), `Nexus.Cloud.Composio` (whitelabel
  broker, `create_auth_config`) ✅
- New: the searchable catalog + per-integration connect UI; wiring the whitelabel auth-configs.

### 2.4 Channels — "text or call your autopoet"
- Manages: Telnyx phone-number provisioning, SMS/voice, entitlement + per-message metering, TF verification.
- Backend: `Nexus.Telnyx`, `Nexus.Channels.Admission` (money boundary), `Polar.plan_limits`
  (phone_channel/phone_numbers per tier) ✅ (epic **wb-h0pey**)
- New: self-serve provision UI + the toll-free verification flow + the STOP/HELP/link-your-phone UX.

### 2.5 Secrets / API keys — "bring your own keys, it's private"
- Manages: per-tenant encrypted store (BYO provider keys, integration creds, `nexus`-scoped runtime secrets).
- Backend: `Nexus.ControlPlane.Env` (AES-256-GCM at rest, org-scoped, nexus/user/workspace/package
  scopes) ✅ — **verified green this session** (was main-RED; fixed admin-gate + list `length` + nexus-scope).
- New: the secrets UI (add/reveal/rotate/delete, scope picker).

### 2.6 Auth & team — "sign in, invite your team"
- Manages: accounts (WorkOS SSO **or** native email/pass), orgs/tenants, members + roles, sessions, CLI PATs.
- Backend: `Nexus.Auth.Cloud` (session cookie **or** `wbk_` PAT), `Nexus.Auth.Jwt` (WorkOS SSO),
  `Nexus.Platform` (org/member/token API) ✅ — **SSO wiring fixed this session** (`configure_auth` now
  loads `WB_OIDC_*` → `jwks_url`, was always nil → every JWT 401'd).
- New: the account/team UI; the **login island already exists** (`dogfood/login`, the pastel card) and is good.

### 2.7 Billing — "pay for what you use"
- Manages: subscription tier, invoices, payment method, credit purchases, the customer portal link.
- Backend: `Nexus.Polar` (merchant-of-record: subscriptions, checkout, portal, webhook settlement),
  tiers `solo $12 / studio $32 / team $89 / scale $229` (`dogfood/index.work`) ✅
- New: billing UI + upgrade flow wired to Polar checkout.

### 2.8 Custom domains — "use your own domain"
- Manages: attach a customer domain to their hosted nexus (Cloudflare-for-SaaS custom hostnames).
- Backend: `Nexus.Cloudflare` (custom hostnames, per-hostname TLS, first 100 free) ✅
- New: the add-domain UI + DNS/CNAME instructions + verification.

## 3. The dominant gap: the connective tissue

Every *node* above exists. The **flow between them does not** — `cloud.ex` says it outright:
*"the account/OAuth provider is NOT here."* The spine to build:

```
sign up (2.6)  →  create org/tenant  →  pick a plan → Polar subscription (2.7)
   →  provision a Fly machine running autopoet (2.1)  →  autopoet is live
   →  connect integrations (2.3) + set secrets (2.5) + provision a number (2.4)
   →  every AI call meters against credits (2.2)  →  the dashboard shows it all
```
This orchestration — not the individual views — is the real build.

## 4. Information architecture — DECIDED: **A** (one rail, 8 sections)

Left rail: `Overview · Usage · Integrations · Channels · Secrets · Team · Billing · Domains`, each one
click deep. Most v0-faithful; each surface is already a discrete backend. (Options B/C kept below as the
rejected alternatives / rationale.)

- **A. One dashboard, sections (most v0-faithful).** Left rail: `Overview · Usage · Integrations ·
  Channels · Secrets · Team · Billing · Domains`. Everything one click deep. Simplest; scales to ~8 items.
- **B. Grouped areas.** Top-level: `Infra` (nexuses, domains) · `Usage & Billing` (usage, credits,
  plan) · `Integrations` (composio, channels, secrets) · `Team` (members, auth). Fewer top-level things,
  more nesting.
- **C. Nexus-centric.** The primary object is *your autopoet-nexus*; everything (usage, secrets, channels,
  domain) hangs off the nexus detail. A single-nexus-per-org model reads very simply.

Recommendation: **A** for v1 (matches the "simple, no studio" thesis; each surface is already a discrete
backend). Revisit C if the model stays strictly one-nexus-per-org.

## 5. Non-goals (explicitly not this)

- Not the Studio (chat, code-IDE, the app-store) — that's the embodied autopoet's job, not the control panel.
- No new runtime logic in the UI — it's a client of `/api/platform` + `/api/cloud`.
- Not a generic multi-app PaaS console — it manages *autopoet-nexuses*, period.

## 6. Build inventory

**Exists / verified green:** env-store secrets (2.5), SSO/auth config (2.6), the login island, provisioning
(`Cloud`/`Fly`), inference money boundary + Cloudflare gateway (2.2 backend), Polar (2.7), Composio (2.3),
Telnyx (2.4), Cloudflare domains (2.8).

**New:** the whole UI (ground-up design), the **AI-usage migration** from the Cloudflare app (2.2), and the
**§3 connective-tissue orchestration** (signup→tenant→subscribe→provision→meter).

## 7. Decisions — LOCKED (2026-07-03)

1. **IA: A** — one rail, 8 sections (§4).
2. **Design: pastel-aurora, light** — coherent with the `dogfood/login` card; the drifting pastel blobs
   are the through-line so login → dashboard reads as one product.
3. **Nexus model: one-per-org** — you have *one* autopoet; the whole product assumes it. (Enables the
   nexus-centric touches from IA-C inside the Overview without adopting C wholesale.)
4. **Extraction: later** — build the UI now as a `.work` surface under `cloud/` talking to `/api/platform`;
   extract the `cloud/` backend out of `nexus/lib` (RESTRUCTURE.md Phase 5) *after* the UI lands. No deploy
   risk (nothing live), and the UI doesn't care where the backend module lives.

## 8. Delivery plan — every step to full, confirmed completion

Confirmation spine: a surface is "done" only when a **real action through the UI moves real state in the
backend** (provision a machine, meter a token, connect a tool, settle a webhook), covered by a committed
test. Step 10 proves they compose; Step 11 proves it's safe; Step 12 is the owner's sign-off.

**Foundation**
- **0 · Decisions locked** — DONE (§7). Done when: zero open decisions block the build.
- **1 · Design system + shell** — the pastel-aurora tokens/type/components + the auth-gated shell (rail,
  layout, routing) with empty views. Done when: sign in → shell renders → every nav item opens a view;
  responsive; DAG-check green.
- **2 · Auth + account spine** (the "NOT here" gap) — signup → org/tenant → Polar plan → session → lands in
  the dashboard; login/logout/rotate; WorkOS SSO. Done when: a fresh signup creates a real tenant +
  subscription and lands on Overview, e2e-verified.

**Surfaces (value order)**
- **3 · Overview + hosted autopoet** (2.1) — provision / status / roll / suspend / kill via the UI. Done
  when: provision a real autopoet-nexus from the UI, see it live, roll, kill — e2e.
- **4 · AI usage + credits** (2.2, the Cloudflare migration, heaviest) — metering by model, balance, top-ups,
  caps, gateway routing. Done when: a real AI call meters against credits, spend-by-model shows, a top-up
  adds credits, a cap blocks overspend — proven with live inference.
- **5 · Secrets** (2.5) — add/reveal/rotate/delete per-tenant secrets. Done when: set a provider key, the
  hosted autopoet uses it, rotate it — e2e.
- **6 · Integrations** (2.3) — Composio catalog, connect/disconnect, whitelabel OAuth, MCP-per-user. Done
  when: connect a real integration and the autopoet uses that tool — e2e.
- **7 · Channels** (2.4) — Telnyx number provisioning, SMS/voice, entitlement + metering, TF verification.
  Done when: provision a number, text it, the autopoet replies, it meters — e2e.
- **8 · Billing** (2.7) — tier, invoices, card, credit purchases, upgrade via Polar. Done when: subscribe
  (sandbox) → invoice → upgrade → webhook settles — e2e.
- **9 · Custom domains** (2.8) — attach a domain (Cloudflare custom hostnames). Done when: add a domain,
  CNAME, verify, the nexus serves on it — e2e.

**Prove it whole**
- **10 · Connective-tissue e2e** (§3) — the full spine as one flow. Done when: a brand-new user goes
  signup → plan → provision → connect → secrets → number → AI-metered → dashboard-shows-it in one sitting,
  and a committed e2e script replays it green.
- **11 · Hardening** — tenant isolation / secret handling / money boundaries red-teamed; tests green; DAG
  green. Done when: full suite green + a red-team pass + a deploy smoke (`/health` + a real signup→provision).
- **12 · Cutover** — `/cloud` serves the new dashboard, Studio archived to `experiments/`, docs updated,
  owner runs it end-to-end and confirms.
