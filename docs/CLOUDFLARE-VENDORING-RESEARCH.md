# Cloudflare Vendoring Research — hosting, domains, storage for hosted-nexus users

**Question:** Can we *vendor* Cloudflare's deploy + domain + storage to our cloud users
— at a small markup — so a user who publishes from a nexus gets (a) a shareable web link,
(b) a custom/forwarded domain, and (c) blob storage, all billed through us, **without**
forcing them into a Cloudflare integration they manage? BYO stays possible but is the
*non-default* path.

**Answer up front: yes, and the economics are unusually favorable.** Cloudflare's SaaS
primitives are priced as if built for exactly this resale model — 100 free custom hostnames
then **$0.10/mo each with SSL included**, **$0 R2 egress**, and a Worker request floor of
$5/mo for the whole fleet. Our markup is almost pure margin because our underlying CF cost
per user is cents. **Default = "use our Cloudflare." BYO-Cloudflare stays available for
large/compliance tenants only.**

As-of: **2026-06-14.** Cloudflare prices drift (custom hostnames dropped $2 → $0.10 in 2025;
Workers static-asset limits raised Sep-2025) — re-verify the three load-bearing numbers
(§A) before committing them to a billing meter.

---

## 0. How we deploy our OWN sites today (ground truth)

Already a Cloudflare-fronted shop — this is a build-on, not a new vendor relationship:

- **`web/publish.sh` / `web/deploy.sh`** ship the static site via `wrangler pages deploy`
  to the **`workbooks-shell`** Cloudflare **Pages** project (account
  `6d4b74aeb10f455fbf88141901e7595d`). The lander is published *manually* via wrangler
  (matches the memory note).
- **`web/_worker.js`** is a Pages Worker: edge serves the static copy first, falls back to
  a Fly origin (`wb-site.fly.dev`) only for CMS routes it doesn't have. So we *already*
  run the "CF edge in front, Fly origin behind" pattern.
- **`runtime/edge/cloudflare-worker.ts`** is a real Worker (KV-backed key-release broker) —
  we already author Workers, bind KV, and use `env.ASSETS`.
- **`web/deploy/fly.toml`** = the runtime origin on Fly. Compute lives on Fly; CF is the CDN/edge.
- **`toolkits/wrangler/`**, `web/toolkits/content/cloudflare.md`, the `cloudflare` toolkit:
  we already expose an **all-Cloudflare BYO path** to users (D1 + Workers AI + Pages on
  *their* `wrangler login`). That is the BYO lane this memo proposes to *demote* to optional.
- **Storage:** `docs/HOSTED-NEXUS-ECONOMICS.md` §4 already chose **R2 as the blob plane on
  every host** — `Workbooks.Storage` is a tenant-scoped SigV4 behaviour that serves S3 **and**
  R2 with config-only difference; `safe_key()` already prevents tenant-prefix escape. Litestream
  → R2 already wired for SQLite durability.

**Implication:** we have a CF account, a Pages project, Worker authoring experience, and an
R2-ready storage layer *today*. Vendoring is wiring the CF **API** per tenant on top of
infrastructure we already operate — not adopting a new provider.

---

## A. The three load-bearing prices (verify before metering)

| Primitive | Our cost | Source / as-of |
|---|---|---|
| **Custom hostname** (user's own domain on our infra, SSL auto-managed) | **first 100 free, then $0.10/mo each** | CF for SaaS plans page + community + 2025-05-19 changelog · 2026-06-14 |
| **R2 storage / egress** | **$0.015/GB-mo, $0 egress**, Class A $4.50/M, Class B $0.36/M | developers.cloudflare.com/r2/pricing · 2026-06-14 |
| **Workers Paid (whole fleet)** | **$5/mo** base: 10M req + 30M CPU-ms incl; +$0.30/M req, +$0.02/M CPU-ms; **static-asset requests free & unlimited** | developers.cloudflare.com/workers/platform/pricing · 2026-06-14 |

These three numbers are the entire COGS of the vendored offering. Everything below ranks
how to assemble them.

---

## 1. Hosting users' sites — **Workers Static Assets** (not Pages, not classic Workers)

**Decision: deploy user sites as a Worker with static assets (Workers Static Assets), one
Worker per tenant or a single Worker-for-Platforms dispatcher.** Skip Pages for *new* build.

Why:
- **As of Mar-2026 Workers has full feature parity with Pages** for static assets, SSR,
  and custom domains; **static-asset requests are free** (same as Pages); Cloudflare's own
  guidance is "new projects → Workers, skip Pages." Pages isn't dying but all new features
  land on Workers first/only.
- Workers gives the **full platform** behind the same deploy: KV, R2, D1, Durable Objects,
  Queues — which is exactly the set a user's "app built in a nexus" will want, and which Pages
  gates behind a Functions shim.
- **`wrangler deploy` + `wrangler.toml` asset config** is the same tooling we already run for
  `web/publish.sh` — minimal new surface.
- **Limits OK for our shape:** 100k static assets/Worker version (paid), 5-min CPU/invocation
  ceiling, 10M req/mo included on the $5 base. Per-page-view blob serving is **free static-asset
  traffic**, so the request meter barely ticks for typical sites.

**For true multi-tenant scale: Workers for Platforms (WfP) dispatch.** WfP lets *us* host
thousands of user Workers under one dispatcher Worker with per-tenant isolation and namespacing
— the canonical "we run a deploy platform for our users" primitive. Start with one-Worker-per-tenant
(simpler); graduate to WfP dispatch when tenant count or noisy-neighbor isolation demands it.

**Custom-domain support:** native on Workers (Custom Domains + the SaaS custom-hostname API in §3).

**Ranking:** Workers Static Assets > Workers-for-Platforms (at scale) > Pages (legacy/our existing
lander only) > classic compute-only Workers (no asset story).

---

## 2. Shareable links / preview URLs — `*.workbooks.app` subdomain-per-tenant

**The website-builder pattern (Vercel/Netlify/Framer):** every deploy gets a free,
instantly-shareable URL on *our* apex; custom domains are an upgrade layer on top.

**Mechanics:**
1. **Register an apex we own for user sites** — e.g. `workbooks.app` (keep `workbooks.sh`
   for our own marketing). Put it on our CF account.
2. **Wildcard DNS + wildcard route:** `*.workbooks.app` → our dispatcher Worker. The Worker
   reads the `Host` header (`alice.workbooks.app` → tenant `alice`) and serves that tenant's
   assets. One wildcard record + one Worker route covers unlimited tenants — **no per-subdomain
   provisioning, no per-subdomain cost.** A wildcard TLS cert (`*.workbooks.app`, advanced cert)
   covers them all.
3. **Per-deploy preview links:** `<deploy-hash>.workbooks.app` or
   `<branch>--<tenant>.workbooks.app` — same wildcard mechanism, the Worker maps the
   first label to a deploy artifact in R2/KV. This is the "share with your team before going
   live" link.
4. **Vanity tenant subdomain** (`alice.workbooks.app`) = the stable team-share link;
   **custom domain** (`app.alice.com`) = §3 upgrade.

**Cost of this tier: ~$0** beyond the single wildcard cert and the shared $5 Worker base.
This is the "free shareable link" every website builder gives away — give it away too.

---

## 3. Custom + forwarded domains — **THE primitive: Cloudflare for SaaS / Custom Hostnames**

This is the keystone and it maps almost 1:1 onto the founder's "manage domain services through
Cloudflare for our users" goal.

### Custom Hostnames (let a user point THEIR domain at OUR infra, auto-SSL)

- **What:** a user owns `app.theircompany.com`, adds a CNAME → our SaaS zone, and Cloudflare
  **issues + renews the TLS cert for their hostname automatically** and routes it to our origin.
  The user never touches our CF account; they only add one DNS record on their side (or we
  automate it if they delegate DNS — see Registrar below).
- **Availability:** Free, Pro, **and Business** plans (Enterprise for apex-proxying/BYOIP only).
  **We do not need Enterprise** for the core offering.
- **Cost:** **first 100 custom hostnames free, then $0.10/mo each, SSL included.** (Dropped from
  $2 → $0.10 in 2025.) Pay-as-you-go cap raised to 50,000 hostnames (May-2025).
- **API:** fully programmatic — `POST /zones/{zone}/custom_hostnames` creates a hostname +
  triggers cert issuance; poll/`webhook` for SSL status; `DELETE` to deprovision. This is the
  per-tenant automation hook.
- **Apex domains** (`theircompany.com` with no subdomain): standard mode needs a CNAME, which
  apex can't always do cleanly. CNAME-flattening or `CNAME`-at-apex works on CF-hosted zones;
  true apex-proxying for arbitrary external zones is the **Enterprise** add-on. **Mitigation:**
  steer users to a subdomain (`app.` / `www.`) for the custom-domain feature, or have them move
  the zone to us (Registrar, below) where apex flattening is native. Don't promise raw external-apex
  proxying on the non-Enterprise tier.

**This is the answer to "custom + forwarded domains."** "Forwarded" = the user keeps their
domain at their registrar and just CNAMEs in; "custom + managed" = they move the domain to us.

### Cloudflare Registrar (domains WE sell / manage for users)

- **What:** at-cost domain registration — **no markup, no add-on upsell.** `.com` true cost
  **$10.44/yr** ($10.26 registry + $0.18 ICANN) for registration **and** renewal.
- **Resale angle:** *we* register the domain on our CF account at cost, **set our own retail
  price** to the user (e.g. $14–18/yr `.com`), and pocket the spread — clean markup model, and
  the domain's zone is already on our CF so custom-hostname + apex flattening + DNS automation
  all "just work."
- **Hard constraint:** **Cloudflare Registrar requires the domain to use Cloudflare nameservers**
  — you cannot park it on Route53/etc. For our use that's a *feature* (the zone is on our infra,
  fully automatable), but it means Registrar is only for domains the user lets us host the DNS for.
- **API caveat:** the public docs did **not** confirm a self-serve Registrar *reseller* API as of
  2026-06-14 (registration automation is gated/partner-ish). **Flag:** verify Registrar API access
  for programmatic register-on-behalf before promising "buy a domain in one click" inside the nexus.
  If unavailable, MVP = "bring a domain you own" (custom hostname) and add sell-a-domain later.

### Decision matrix

| User wants | Primitive | Our cost | What we charge |
|---|---|---|---|
| A shareable link to show a teammate | `*.workbooks.app` subdomain (§2) | ~$0 | **free** (table stakes) |
| Use a domain they already own | **Custom Hostname** (CNAME in) | $0.10/mo (after 100 free) | bundled in plan, or **$2–5/mo** add-on |
| Buy/manage a new domain through us | **Registrar** (at-cost) + auto-zone | $10.44/yr `.com` | **$14–18/yr** retail (verify API) |

**Made explicit:** **Custom Hostnames is the load-bearing primitive — build it first.**
Registrar is a second-phase upsell (and gated on confirming the reseller API). Pages/Workers
hosting (§1) is the substrate both ride on.

---

## 4. Storage vendoring economics — charge for OUR R2 at a markup (the simple path)

§4 of the economics doc already chose R2 as the blob plane (zero-egress, no caps, no CDN
dependency; `Workbooks.Storage` is R2-ready by config flip). Two models:

- **(A) Vendor OUR R2 at a markup** *(recommended default).* One R2 bucket(s) on our account,
  tenant-namespaced `tenant_id/blobs/key` (already the §4 pattern), presigned PUT so bytes go
  **browser → R2 directly** (never touch compute), served via custom domain on R2 or presigned
  GET. We meter bytes-stored + Class-A/B ops and bill the user.
- **(B) Connect THEIR Cloudflare R2.** User brings R2 creds; we write to their bucket. Zero
  storage COGS for us, but: more user setup, their bill, harder support, breaks the "one bill"
  promise. **Keep for large/compliance tenants only.**

### The markup math

Our R2 cost: **$0.015/GB-mo storage + $0 egress.** Egress being free is the whole game — for a
website builder, *serving* is the cost center everywhere else (S3 would be ~$0.09/GB egress;
serving 10 TB/mo ≈ $891 on S3 vs ~$15 on R2). On R2, **a user serving heavy traffic costs us
essentially the storage line only.** Class A (writes/uploads) $4.50/M and Class B (reads) $0.36/M
are the only variable adders, both tiny for typical sites.

**What to charge (recommended):**
- **Include a generous free block in every nexus plan** — e.g. **5 GB stored + unlimited egress.**
  Our cost for 5 GB = **$0.075/mo.** Egress free. This is nearly free to give and kills the
  "do I have to set up storage?" friction. (Vercel/Netlify give ~100 GB *bandwidth*; on R2 we
  can give unlimited bandwidth and still win on COGS.)
- **Overage: $0.10–$0.15/GB-mo stored** (vs our $0.015 → **~7–10× markup**, still cheap vs every
  S3-egress-charging competitor because the user pays $0 for traffic). Round to **$0.10/GB-mo
  over the included block** — clean, defensible, ~6.7× our cost, covers Class-A/B ops noise.
- **Hard prerequisite (from §4):** `Workbooks.Storage` has **no per-tenant size quota** today.
  **Add a per-tenant blob quota + total-bytes accounting above the S3 adapter before opening a
  hosted upload store** — otherwise storage cost (and the bill we'd eat) is unbounded.

**BYO-R2 stays optional** for tenants who must keep data in their own account (compliance,
huge archives, existing CF contract). Default everyone else to vendored R2 at the markup above.

---

## 5. What we'd build, in order — and the gotchas

### Build order (ranked, smallest defensible increment first)

1. **Per-tenant subdomain serving** (`*.workbooks.app`). Register apex, wildcard DNS + wildcard
   cert, one dispatcher Worker routing `Host` → tenant assets in R2/KV. *Ships the free shareable
   link.* Reuses our existing wrangler/Worker tooling. **(Phase 1, week-scale.)**
2. **Per-tenant blob quota + accounting** above `Workbooks.Storage` (the §4 gap). Gate hosted
   uploads on it. *Unblocks vendored storage.* **(Phase 1, parallel.)**
3. **Custom Hostname provisioning** via the CF for SaaS API: on "add your domain," call
   `POST /custom_hostnames`, surface the CNAME for the user to add, poll SSL status, show
   verified/issued. Deprovision on removal. *Ships the custom-domain primitive — the keystone.*
   **(Phase 2.)**
4. **Billing meter:** count custom hostnames ($0.10 cost → plan/add-on price), R2 bytes-stored
   (overage), Worker requests if a tenant is compute-heavy. Wire into the existing nexus billing.
   **(Phase 2.)**
5. **Registrar resale** (sell/manage domains) — *only after confirming the Registrar API*.
   Register-on-behalf at cost, retail markup, auto-attach zone so custom-hostname/apex just work.
   **(Phase 3, gated.)**
6. **Workers-for-Platforms dispatch** — migrate from one-Worker-per-tenant to WfP namespaces when
   tenant count / isolation demands. **(Phase 3+, scale trigger.)**

### Gotchas (the risk column)

- **SSL issuance latency/failure:** custom-hostname certs need the user's CNAME live and domain-control
  validated (HTTP/TXT/CNAME DCV); issuance is async and can stall on misconfigured DNS or CAA records.
  **Build:** clear pending/failed UI, retry, and a "your CAA record blocks Cloudflare" diagnostic.
  Don't mark a domain "live" until SSL = active.
- **Subdomain takeover / dangling DNS:** if a tenant is deleted but its `*.workbooks.app` mapping or
  a custom hostname lingers, an attacker can claim it. **Build:** deprovision hostname + purge the
  routing entry atomically on tenant teardown; periodic sweep for orphaned mappings.
- **Abuse / phishing on user subdomains:** free `*.workbooks.app` subdomains and custom hostnames are
  catnip for phishing — and abuse lands on **our** apex reputation. **Build:** content scanning /
  Cloudflare's own abuse tooling, rate-limit subdomain creation, a takedown path, and **keep user
  sites on a separate apex (`workbooks.app`) from our brand (`workbooks.sh`)** so a blocklist hit
  doesn't poison our main domain.
- **Apex custom domains:** non-Enterprise can't proxy arbitrary external apex cleanly — steer to
  subdomain or move-the-zone-to-us. Don't over-promise.
- **Price drift:** the $0.10/hostname and Worker request rates have moved before; meter against a
  config value, re-verify quarterly (§A).
- **R2 unbounded cost** without the quota (item 2) — do not open uploads before it lands.
- **Registrar API uncertainty** — Phase 5 may be "bring-your-own-domain only" if no reseller API.

---

## 6. Bottom line / recommendation

**Offer the vendored "use our Cloudflare" path as the default, in three layers:**

1. **Free shareable link** — every nexus deploy gets `tenant.workbooks.app` + per-deploy preview
   URLs. Cost to us ~$0. Table stakes; give it away.
2. **Custom domain** (bring your own) — Cloudflare for SaaS **Custom Hostnames**, our cost
   **$0.10/mo** (first 100 free), auto-SSL. Bundle one custom domain into paid nexus tiers; charge
   **$2–5/mo** for additional domains. This is the keystone primitive — **build it first after the
   subdomain layer.**
3. **Vendored storage** — our R2, **5 GB + unlimited egress included**, overage **$0.10/GB-mo**
   stored (~6.7× our $0.015 cost; egress free makes us cheaper than every S3-egress competitor
   anyway). Gate on adding the per-tenant quota first.
4. **(Phase 3) Sell domains** — Cloudflare Registrar at cost ($10.44 `.com`), retail ~$14–18/yr.
   **Gated on confirming a programmatic Registrar API.**

**Keep BYO-Cloudflare optional** (the existing `cloudflare` toolkit / BYO-R2) for large or
compliance tenants who need data/domains in their own account — but it is **not** the default and
should not be the path we optimize for.

**Why this works:** our CF cost per user is *cents* (a custom hostname is $0.10, R2 egress is
$0, the Worker floor is $5 for the whole fleet), so almost any markup is margin, and the user gets
the website-builder experience (instant link → custom domain → storage, one bill) the founder wants
— on infrastructure we already operate.

---

## Sources (as-of 2026-06-14)

- Cloudflare Pages vs Workers parity & guidance — https://developers.cloudflare.com/workers/static-assets/migration-guides/migrate-from-pages/ ; https://www.morphllm.com/comparisons/cloudflare-pages-vs-workers ; https://dev.to/rickcogley/cloudflare-pages-vs-workers-in-2026-migration-guide-ka7
- Workers pricing & static-asset limits — https://developers.cloudflare.com/workers/platform/pricing/ ; https://developers.cloudflare.com/changelog/2025-09-02-increased-static-asset-limits/
- Cloudflare for SaaS / Custom Hostnames (overview, plans, $0.10/hostname, 100 free, 50k cap) — https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/ ; https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/plans/ ; https://developers.cloudflare.com/cloudflare-for-platforms/cloudflare-for-saas/domain-support/ ; https://developers.cloudflare.com/changelog/2025-05-19-paygo-updates/
- R2 pricing ($0.015/GB, $0 egress, Class A/B) — https://developers.cloudflare.com/r2/pricing/
- Cloudflare Registrar at-cost ($10.44 .com, CF-nameservers requirement) — https://www.cloudflare.com/learning/dns/what-is-cloudflare-registrar/ ; https://priceworld.com/domains/cloudflare/ ; https://startupowl.com/reviews/cloudflare-registrar
