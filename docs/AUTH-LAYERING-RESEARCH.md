# Auth Layering Research — Platform vs User-App Auth

**As-of:** 2026-06-14. Prices verified from `workos.com/pricing` on this date;
flag drift before quoting them downstream — WorkOS has reworked its pricing
several times.

## TL;DR recommendation

Ship the **two-layer model the founder confirmed**, and notice we have *already
mostly built it*:

1. **Platform auth = WorkOS AuthKit.** How Workbooks-cloud customers sign into
   the `workbooks.sh` dashboard / control plane. Already wired on the desktop
   side as a *swappable OIDC adapter* (`desktop/src/lib/rcp/providers/workos.ts`),
   explicitly framed there as "WorkOS is no longer the auth system — it's an
   adapter."
2. **User-app auth = BetterAuth (default) + integration surface.** The base auth
   layer baked into the runtime that a customer's own (possibly multi-tenant)
   app uses for *its* end-users. The runtime already verifies BetterAuth-issued
   RS256 JWTs against a JWKS endpoint and derives the tenant from the
   `organizationId` claim.
3. **Convex model:** ship a thin base layer, outsource enterprise/advanced auth
   via **integrations** (Clerk / WorkOS / Auth0 / any OIDC IdP). We already have
   the generic seam for this — `AUTH = trusted | betterauth | clerk | oidc` in
   the deploy config, all verified through one JWKS path. BYO-auth stays
   possible by construction.

**Net:** this is a wiring + productization job, not a new auth system. The hard
seam (tenant-from-verified-JWT, JWKS verification, capabilities advertisement of
the required auth rung) exists today.

---

## 0. What the runtime already does (codebase ground truth)

Files: `runtime/host/auth.ex`, `runtime/host/auth/guardian.ex`,
`runtime/host/auth/jwks.ex`, `runtime/host/auth/secret_fetcher.ex`,
`runtime/host/tenancy.ex`, `runtime/host/storage.ex`,
`runtime/host/web/capabilities.ex`, `runtime/host/deploy/config.ex`,
`desktop/src/lib/rcp/providers/workos.ts`.

**Auth ladder** (`Workbooks.Auth.call/2`, first match wins):

1. Public allowlist (`/health`, `/.well-known/*`, `/capabilities`) — always
   open; carries no tenant data so a client can read the required auth rung
   *before* it has a credential.
2. `WB_DESKTOP=1` + per-boot desktop token — local WebView.
3. `WB_PUBLIC_BEARER` shared secret — locked single-tenant cloud deploys; tenant
   from `WB_TENANT`. Missing/wrong bearer → 401, no dev fallback.
4. **BetterAuth/Guardian JWT** — the production multi-tenant path.
5. `x-tenant` dev header fallback — only when *not* locked and *not* multi-tenant.

**JWT verification** (`Workbooks.Auth.Guardian`): BetterAuth's `jwt` plugin signs
RS256 tokens; this runtime verifies them. Two modes resolved from env at boot:

- **RS256 via `WB_JWKS_URL`** (production) — keys fetched from the IdP's JWKS
  endpoint, cached in `persistent_term` with a 5-min TTL, selected by token
  `kid` (`Workbooks.Auth.JWKS` + `SecretFetcher`).
- **HS256 via `WB_AUTH_SECRET`** (local test, mint+verify with no live gateway).

**Tenant derivation** (`resource_from_claims`):
`tenant_id = organizationId || sub` (org for multi-tenant, falls back to the
user `sub` for solo). This is the single source of "who the tenant is."

**Isolation by construction** (`Workbooks.Storage`): every storage call takes
`tenant` as its first argument, so isolation lives *above* the backend — swapping
a Fly volume for R2 can't widen access. Moduledoc: *"Auth (BetterAuth→Guardian)
decides WHO the tenant is; this just stores their bytes under that scope."*

**Tenancy posture** (`Workbooks.Tenancy`, `WB_TENANCY_MODE`):

- `:single` — one tenant; `x-tenant`/anonymous fallback OK.
- `:multi` — per-tenant isolation enforced; a request MUST carry a verified
  identity (JWT whose org IS the tenant); `x-tenant` and the `dev` fallback are
  **rejected** — a tenant can't be spoofed.

**The generic IdP seam already exists** (`Workbooks.Deploy.Config`):

```
@auth ~w(trusted betterauth clerk oidc)
```

- `trusted` = no real auth (single-tenant only; validation *rejects* `multi` +
  `trusted` together).
- For any real provider, `ISSUER` → `WB_AUTH_ISSUER` + a derived JWKS URL:
  - BetterAuth (non-standard): `ISSUER/api/auth/jwks`
  - Generic OIDC/Clerk: `ISSUER/.well-known/jwks.json`
  - Explicit `JWKS_URL` overrides.

**Capabilities advertisement** (`web/capabilities.ex`): `GET
/.well-known/workbooks-runtime` (unauthenticated) tells a client the required
auth `rung` (`trusted` | `oidc-jwt`), the `issuer`, and the `jwks_url` *before*
it presents a credential. The rung is derived from tenancy: single → `trusted`
accepted; multi → `oidc-jwt` required.

**WorkOS is already an adapter, not the system** (`providers/workos.ts`): WorkOS
session (loopback + PKCE, keychain-stored) is reframed as one `OidcTokenSource`
behind a generic `OidcAdapter`. Comment: *"Swapping to BetterAuth/Clerk means
swapping this file's TokenSource, nothing else."* This is the platform-auth side.

> **Key insight:** the runtime's JWT path doesn't actually care *which* IdP
> minted the token — it only needs (a) a JWKS URL to verify RS256 and (b) an org
> claim to scope the tenant. So "integrate Clerk/WorkOS/Auth0 into the user's
> app" is already a config line + a claim-mapping detail, not new engine code.

---

## 1. WorkOS pricing cliffs (platform-auth cost map)

Source: <https://workos.com/pricing> (fetched 2026-06-14). **Price drift risk:
high — re-verify before committing to numbers in a deck or contract.**

### Free tier (AuthKit / User Management)

- **First 1,000,000 MAUs: free.** An MAU = a user who performs an action
  (sign-up / sign-in) in a calendar month.
- Free tier **includes**: email + password, social login, passkeys, **MFA**,
  magic auth, **and enterprise SSO** (the *feature* is in the free tier; the
  per-connection SSO charge below is separate).

### The cliffs (where WorkOS costs us real money as the platform)

| Feature | Price (as-of 2026-06-14) | When it bites us |
|---|---|---|
| **MAUs over 1M** | **$2,500/mo per additional 1M MAUs** | Only at huge scale. For the *platform dashboard* (our paying cloud customers, not their end-users) we will not approach 1M MAUs for a long time. Effectively free for platform auth. |
| **Enterprise SSO** (per connection) | **$125/conn/mo** (1–15); volume tiers → $100 (16–30), $80 (31–50), $65 (51–100), $50 (101–200), custom (201+) | Each *customer org* that wants SAML/OIDC SSO into our dashboard = one connection. This is the real per-customer cost. 10 enterprise customers on SSO ≈ **$1,250/mo**. |
| **Directory Sync / SCIM** (per connection) | **Same tiered schedule as SSO** ($125→$50/conn/mo) | Each org wanting SCIM provisioning = another priced connection, *on top of* its SSO connection. An enterprise customer on both ≈ **$250/mo** at list. |
| **Radar** (bot/fraud) | First 1,000 checks free; **$100/mo per additional 50K checks** | Scales with sign-in volume if we enable it. |
| **Custom domain** (CNAME on the auth pages) | **$99/mo flat** | One-time monthly if we white-label the hosted auth UI. |
| **Audit Logs** | Log streaming **$125/mo per SIEM connection**; event retention **$99/mo per 1M events** | Enterprise compliance asks. |
| **Support** | Standard free; **Scale $1,000/mo**; Enterprise custom | Optional. |

### Reading of the cliffs

- **MAU pricing is a non-issue for platform auth.** 1M free MAUs is enormous for
  "people who log into our control plane." WorkOS's value-add and cost live in
  the **enterprise connectors**, not the MAU meter.
- **The bill is per-enterprise-connection, and it stacks**: SSO + SCIM + audit-
  log streaming on a single demanding customer ≈ **$125 + $125 + $125 = $375/mo**
  at list before volume discounts. That is the "pay big bucks" zone — and it's
  exactly the cost we should **pass through / gate behind an enterprise plan**,
  not absorb.
- **Implication:** WorkOS is close-to-free for the common case (password/social/
  MFA login to our dashboard) and only costs money when an enterprise customer
  demands SSO/SCIM/audit — which is precisely when *we* are charging that
  customer an enterprise price anyway. The economics line up.

---

## 2. BetterAuth as the base user-app auth layer — trust & safety

Sources: BetterAuth security docs (`better-auth.com/docs/reference/security`),
SSO plugin docs (`better-auth.com/docs/plugins/sso`), GitHub
(`github.com/better-auth/better-auth`), WorkOS comparison
(`workos.com/blog/workos-vs-betterauth-vs-clerk`). All fetched 2026-06-14.

### Maturity

- Framework-agnostic TypeScript auth library; **~29k GitHub stars**, 350K+
  monthly npm downloads, active releases (1.5.x line as-of 2026), large Discord.
- **Recommended auth library by Next.js, Nuxt, Astro.** Used in production by YC
  companies and notable OSS (dokploy, zero, folo, …).
- Maturity verdict: **mature enough to be the default base layer.** It is not a
  toy. It is, however, a **library you run**, not a managed service — the
  operational and patch burden is *ours/the customer's*, not a vendor's.

### What BetterAuth handles for us (safe to lean on)

- **Password hashing:** `scrypt` by default (memory-hard, sound choice).
- **Sessions:** encrypted cookies, `httpOnly` + `Secure` + `SameSite=Lax` by
  default; 7-day expiry (configurable); **revocable**.
- **CSRF:** layered — origin validation, Fetch-Metadata checks, SameSite cookies,
  state/nonce on OAuth flows.
- **OAuth:** state + **PKCE** stored in verification storage or encrypted cookies.
- **Rate limiting:** built-in across routes (brute-force defense).
- **Account enumeration:** identical responses for existing/non-existing emails.
- **Token signing:** the `jwt` plugin issues RS256 + exposes a **JWKS endpoint**
  (`/api/auth/jwks`) — which is *exactly* what our runtime already verifies
  against. Supports non-destructive **key rotation** with fallback decryption.
- **MFA/2FA:** supported via plugin (TOTP, etc.).
- **Enterprise SSO:** there is now an **SSO plugin** supporting **SAML 2.0**
  (via `samlify`) **and OIDC** (via `jose`), multi-tenant (each org → its own
  IdP, domain-verified auto-linking), plus an **OIDC-provider plugin** (BetterAuth
  can itself *be* an IdP). This narrows the historical "no SAML/SCIM" gap, though
  it remains less turnkey than WorkOS and still has **no native SCIM directory
  sync**.

### What we (or the customer) are responsible for — be careful here

- **It's self-hosted → we own the security burden.** Every CVE, patch, and
  upgrade is on us. There is no third-party SOC2 boundary around the auth
  component itself (vs WorkOS's managed posture). The WorkOS comparison hammers
  this; discount the spin, but the substance is real.
- **`trustedOrigins` must be configured** or CSRF / open-redirect protection is
  incomplete. This is a *deployment* responsibility — in our model the runtime
  sets it, not the user.
- **Proxy / IP headers:** behind Fly's proxy we must set correct IP headers and
  only enable `trustedProxyHeaders` when the proxy chain is trustworthy, or rate
  limiting and logging mislead.
- **Key management:** the RS256 signing keys + JWKS rotation are now part of
  *our* operational surface (back them up, rotate them, never leak the private
  half).
- **SCIM / advanced directory provisioning:** not covered — route to an
  integration (WorkOS/Clerk) for customers who need it.
- **Compliance certifications & audit logging** of auth events: BetterAuth
  doesn't ship these; we build or integrate.

### Verdict

**Trustworthy enough to be the default user-app auth layer** — its primitives
(scrypt, secure cookies, PKCE, rate limiting, JWKS rotation) are correct and
modern, and we already verify its tokens. The risk is **operational, not
cryptographic**: we inherit the patch/CVE/key-management duty. Mitigate by (a)
pinning + monitoring BetterAuth releases, (b) owning `trustedOrigins`/proxy
config at the runtime layer so customers can't misconfigure it, (c) treating
SCIM/enterprise-directory + formal audit/compliance as **integration territory**,
not something we promise on the base layer.

---

## 3. The Convex model, concretely

Sources: `docs.convex.dev/auth`, `.../auth/advanced/custom-auth`,
`.../auth/auth0`, `labs.convex.dev/auth/faq`, `convex.dev/auth`. Fetched
2026-06-14.

Convex ships exactly the "thin base + outsource the rest" pattern we want:

1. **Convex Auth (the base layer):** a library that runs *on your Convex
   deployment*, storing all user/session data directly in the Convex DB — social
   login, OTP email/SMS, passwords. Explicitly **beta**, fewer features than the
   integrations. This is Convex's "BetterAuth-equivalent": good enough to start,
   not where enterprise lives.

2. **Integrations (the outsourced rest):** first-class guides + a generic
   abstraction (`ConvexProviderWithAuth`) for **Clerk, Auth0, WorkOS AuthKit**,
   and **any OIDC-compatible IdP** via the **Custom OIDC Provider** path. Mobile
   gets native Clerk↔Convex token sync (2026).

3. **The unifying mechanism = OIDC + JWT verification.** Convex's server verifies
   a **JWT against the IdP's JWKS**, reads `ctx.auth.getUserIdentity()`, and the
   app stores its own user record keyed to the token's `subject`. Integrations
   differ only in config (issuer, JWKS, claim mapping) — the *engine* is
   IdP-agnostic. **This is structurally identical to what our runtime already
   does** (`Guardian` + `JWKS` + `SecretFetcher`, tenant from `organizationId`).

**The equivalent for us:**

- Our "Convex Auth" = **BetterAuth baked into the runtime** (the default).
- Our "ConvexProviderWithAuth + custom OIDC" = the existing
  `AUTH = trusted | betterauth | clerk | oidc` + `ISSUER`/`JWKS_URL` config in
  `Workbooks.Deploy.Config`, plus a generic OIDC option for "any IdP."
- A customer plugs in **Clerk or WorkOS instead of / on top of BetterAuth** by
  pointing their deployment's `AUTH`/`ISSUER` at that provider; the runtime
  fetches that JWKS, verifies the token, and maps a claim to the tenant. No
  engine fork — same seam Convex uses.

---

## 4. Recommended architecture

### Two clean, non-overlapping auth planes

```
┌──────────────────────────────────────────────────────────────┐
│ PLATFORM PLANE  — "who is the Workbooks-cloud customer"        │
│ IdP: WorkOS AuthKit (as a swappable OIDC adapter)             │
│ Surface: workbooks.sh dashboard / control plane              │
│ Identity: WorkOS user + org → a Workbooks ACCOUNT/tenant-owner│
│ Cost: free for login; per-connection $ only for enterprise    │
│       SSO/SCIM (pass through to enterprise plan)              │
└──────────────────────────────────────────────────────────────┘
                         ▲  provisions / scopes
                         │  (separate trust domain)
                         ▼
┌──────────────────────────────────────────────────────────────┐
│ APP PLANE  — "who is an end-user of the CUSTOMER's app"       │
│ IdP: BetterAuth (default, baked into runtime)                │
│      OR integration: Clerk / WorkOS / Auth0 / any OIDC       │
│ Surface: the customer's deployed app (single- or multi-tenant)│
│ Identity: JWT verified via JWKS; tenant = organizationId      │
│ Isolation: Workbooks.Storage scopes every byte by tenant      │
└──────────────────────────────────────────────────────────────┘
```

### Tenant identity flow (app plane)

1. End-user authenticates against the app-plane IdP (BetterAuth by default).
2. IdP mints an **RS256 JWT** with `sub` (user), an **org claim** (`organizationId`
   for BetterAuth; map the equivalent for Clerk/WorkOS/Auth0), `sessionId`, `exp`,
   `iss`.
3. Runtime verifies the signature against the IdP's **JWKS** (`WB_JWKS_URL`,
   cached, `kid`-selected) — `Workbooks.Auth.Guardian` / `JWKS` /
   `SecretFetcher`.
4. `resource_from_claims` derives `tenant_id = org-claim || sub`.
5. Every `Workbooks.Storage` call carries that tenant — **isolation above the
   backend**.
6. In `:multi` mode the runtime **rejects** any request without a verified JWT
   (no `x-tenant`, no anonymous fallback).

### Integration surface to expose (so a customer wires Clerk/WorkOS into *their* app)

Generalize the existing `AUTH` provider list into a small, declarative
**app-auth provider config** on a deployment:

- `AUTH = builtin | clerk | workos | auth0 | oidc` (rename `betterauth`→`builtin`
  for the default; keep `oidc` as the catch-all).
- Required per provider: `ISSUER`, optional `JWKS_URL` override (default derived),
  and a **claim-mapping** (`tenant_claim`, default `organizationId`; `user_claim`,
  default `sub`) so non-BetterAuth IdPs that name the org differently still scope
  correctly. *(This claim-map is the one genuinely new bit — today the org claim
  name is hardcoded to `organizationId` in `guardian.ex`.)*
- The capabilities doc (`/.well-known/workbooks-runtime`) already advertises the
  rung/issuer/JWKS — keep that as the public contract a client reads first.
- Document the three modes plainly: **(a)** use built-in BetterAuth, **(b)**
  replace it with a hosted IdP, **(c)** BYO any OIDC IdP.

### Safety boundaries (hard rules)

1. **The two planes are separate trust domains.** A user-app JWT (app plane) must
   **never** be accepted by the platform control plane, and a WorkOS platform
   token must never scope app-plane tenant data. Enforce by **distinct issuers +
   distinct JWKS + distinct audiences**, and by *not* sharing a verifier between
   `workbooks.sh` dashboard auth and the runtime's app-auth.
2. **An app's auth can never assume another tenant's identity at the platform
   layer.** The tenant a runtime serves is fixed by *deployment* config
   (`WB_TENANT` / `WB_TENANCY_MODE` / the issuer it trusts), not by anything the
   end-user's token asserts about the platform. A multi-tenant runtime isolates
   tenants by the verified org claim; a customer cannot mint a token that crosses
   into *another customer's deployment* because each deployment trusts only its
   own configured issuer/JWKS.
3. **`trusted`/`x-tenant` stays single-tenant-only** (already enforced: config
   validation rejects `multi` + `trusted`; `Auth.no_bearer` rejects the header in
   multi-tenant). Do not relax this.
4. **The runtime owns `trustedOrigins`, proxy/IP headers, and JWKS key
   management** for the built-in BetterAuth layer — never the customer — so app-
   plane CSRF/rate-limit protections can't be misconfigured away.

---

## 5. Build cost & risks of offering the integration surface

### Build cost (small — the seam exists)

| Work item | Size | Notes |
|---|---|---|
| Generalize `@auth` list + add `tenant_claim`/`user_claim` mapping | **S** | Today `organizationId` is hardcoded in `guardian.ex`; make it config so Clerk/WorkOS/Auth0 org claims map. |
| Per-provider JWKS derivation (Clerk, Auth0, WorkOS) | **S** | Already have BetterAuth + generic `.well-known/jwks.json`; add the 2–3 known issuer→JWKS shapes. |
| Docs: 3 modes (builtin / hosted IdP / BYO-OIDC) + claim-mapping table | **S–M** | The real adoption surface. |
| Keep platform-plane (WorkOS) verifier strictly separate from app-plane | **S** | Mostly discipline + tests; the desktop already treats WorkOS as an adapter. |
| Tests: cross-plane token rejection, multi-tenant isolation, claim-map | **M** | Security-critical; worth a dedicated suite. |
| (Optional) hosted BetterAuth-gateway story for cloud customers | **M–L** | Running BetterAuth as a managed component for customers who don't want to operate it. |

Bulk of effort is **documentation + a security test suite**, not engine code.

### Risks

- **Claim-mapping drift / mis-scoping** is the sharpest risk: a wrong default
  tenant claim could merge two orgs into one tenant. Mitigate with explicit
  config + isolation tests; fail closed if the configured tenant claim is absent
  in `:multi` mode.
- **Cross-plane confusion:** if platform-WorkOS and app-WorkOS ever share an
  issuer/audience, a token could be replayed across planes. Mitigate with
  distinct audiences and never sharing a verifier.
- **BetterAuth operational burden** (our responsibility as the default): CVE
  patching, key rotation, `trustedOrigins`/proxy config. Mitigate by owning that
  config at the runtime layer and monitoring releases.
- **WorkOS price drift / per-connection stacking:** enterprise SSO+SCIM+audit can
  reach hundreds of $/mo per customer. Mitigate by gating those behind an
  enterprise plan and passing the cost through — never absorbing it on a base
  plan.
- **"Beta-grade base layer" perception** (the Convex-Auth critique applies to us
  too): be honest that the built-in layer is the *starting* layer and enterprise
  customers should integrate a hosted IdP — exactly the positioning to lean into,
  not hide.

---

## Sources (all fetched 2026-06-14)

- WorkOS pricing — <https://workos.com/pricing>
- WorkOS vs BetterAuth vs Clerk — <https://workos.com/blog/workos-vs-betterauth-vs-clerk>
- BetterAuth security reference — <https://www.better-auth.com/docs/reference/security>
- BetterAuth SSO plugin (SAML 2.0 + OIDC) — <https://better-auth.com/docs/plugins/sso>
- BetterAuth OIDC-provider plugin — <https://better-auth.com/docs/plugins/oidc-provider>
- BetterAuth GitHub — <https://github.com/better-auth/better-auth>
- Convex Authentication — <https://docs.convex.dev/auth>
- Convex Custom OIDC Provider — <https://docs.convex.dev/auth/advanced/custom-auth>
- Convex Auth (base layer) — <https://www.convex.dev/auth> · FAQ <https://labs.convex.dev/auth/faq>
- Convex & Auth0 — <https://docs.convex.dev/auth/auth0>

**Codebase:** `runtime/host/auth.ex`, `runtime/host/auth/guardian.ex`,
`runtime/host/auth/jwks.ex`, `runtime/host/auth/secret_fetcher.ex`,
`runtime/host/tenancy.ex`, `runtime/host/storage.ex`,
`runtime/host/web/capabilities.ex`, `runtime/host/deploy/config.ex`,
`desktop/src/lib/rcp/providers/workos.ts`.
