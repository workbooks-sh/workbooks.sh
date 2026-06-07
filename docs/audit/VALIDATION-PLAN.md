# BRANDNANA — Validation & Remediation Plan

Audit date: 2026-06-03. Worker: `brandnana-api` at `https://api.brandnana.net`.
Canonical contract: `packages/schema/src/verbs.ts` (the `VERBS` catalog).
Routes mounted in `apps/api/src/index.ts:160-180`. All paths below are relative to
`/Users/shinyobjectz/Apps/workbooks/projects/brandnana` unless absolute.

This plan exists because the audit found two headline drift classes:

1. **Code expects a provider whose key is absent** — e.g. Exa (`scrape/exa.ts:37-39`
   throws; `EXA_API_KEY` intentionally absent), and stale `/health` probes for
   `EXA_API_KEY`, `E2B_API_KEY`, `CF_AI_GATEWAY_TOKEN`, `GITHUB_CLIENT_ID`.
2. **Key is set but no code consumes it** — orphan prod secrets `VALYU_API_KEY`,
   `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `THE_COMPANIES_API_KEY`, and `GROQ_API_KEY`
   (worker-orphan; consumed only by the local CLI in `apps/cli/src/commands/logo.ts`).

The trap the audit kept hitting is **silent degradation that returns HTTP 200**: a
swallowed `.catch(() => [])` (e.g. `ads/routes.ts:90`) or a `null`-coalescing wrapper
(`scrape/social.ts:28,44,47`) makes a dead vendor leg indistinguishable from a brand
that genuinely has no data. The validation harness below is designed specifically to
catch that — by classifying on **response shape + per-result `source`/`cost`**, not just
on HTTP status.

---

## 1. Reusable Endpoint-Validation Harness (DESIGN)

### 1.1 Goal

A single, repeatable script that walks the `VERBS` catalog, calls each verb's
`httpPath` with sample inputs using the live bearer key, and classifies each into
**pass / degraded / fail** — crucially distinguishing **`degraded-key-absent`**
(a vendor key is intentionally missing, so empty/null output is expected and honest)
from **`broken`** (the handler returns success-shaped output that hides a real
failure, throws a 5xx it shouldn't, or drifts from the catalog).

This is driven entirely off the catalog so it stays in sync: when a verb is added to
`verbs.ts`, the harness automatically covers it (and flags it if no sample input is
registered).

### 1.2 What makes classification trustworthy here

HTTP 200 is **not** sufficient evidence of "pass" in this codebase. The harness must
inspect the body:

- **`source` field** — `catalog.crawl`, `brand fetch`, ads, and book responses carry a
  `source` / `stats.source` / `x-brandnana-strategy` header indicating which vendor
  actually served the data. A 200 from `catalog.crawl` with `source: "context-dev"` and
  `product_count <= 12` when the domain is a known Shopify store is a **silent fallback**
  (`catalog/shopify.ts:136-148` swallows the probe failure → `routes.ts:57` routes to the
  inferior 12-product path). The harness flags `source` mismatch against an expected-source
  table.
- **`cost` / per-result cost ledger** — a leg that "ran" should have a non-zero cost when
  it hit a paid vendor. A `catalog.crawl` that charges `0.001` but returns
  `product_count: 0` (`book/pipeline.ts:334-364`) is a **stub charging for nothing** →
  `broken`.
- **`count: 0` + empty array on a discovery verb** — `ads.search` with `source=exa|all`
  returns `200 {count:0,ads:[]}` because the Exa throw is swallowed at `ads/routes.ts:90`.
  The harness treats *empty discovery output* as `degraded-key-absent` **only if** the
  vendor key for that leg is known-absent; otherwise it's `broken` (silent empty).
- **`warnings[]` / `errors[]` / timeline `status`** — book and brief responses surface
  degradation through these channels (`pipeline.ts:693-697` stamps `status:"fallback"`).
  A response whose data is degraded but whose `warnings[]`/`errors[]`/`status` is empty is
  **`broken`** (it lied about success). A response that is degraded *and says so* is
  `degraded`.

### 1.3 Classification decision tree

For each verb call, given the response `(httpStatus, body, headers, latency)`:

```
1. transport error / timeout / 5xx that is NOT an honest documented error
       → fail (broken)
2. 503 with a documented "<vendor>_not_configured" / "not_configured" code,
   AND that vendor's key is in the KNOWN_ABSENT set
       → degraded-key-absent  (expected, honest)
3. 502 "upstream_unavailable" / documented vendor error, key SET
       → degraded-upstream    (transient; re-run once, then degraded)
4. 200 but:
     a. response `source` ∈ EXPECTED_SOURCE[verb]  AND
        (cost ledger consistent: paid-vendor leg → cost>0, stub → flagged)
        AND (discovery verbs: count>0 OR a warnings/errors entry explains the 0)
            → pass
     b. response `source` ∈ INFERIOR_FALLBACK[verb]
        (e.g. context-dev when shopify expected) with NO warning/header signal
            → broken (silent fallback)
     c. discovery verb returns count:0/empty AND the leg's vendor key is KNOWN_ABSENT
        AND there is no warning field
            → broken (silent empty — should emit a "discovery_unavailable" warning)
            (downgrade to degraded-key-absent only once a warning is emitted)
     d. 200 with empty/null payload AND a populated warnings[]/errors[]/status:"fallback"
            → degraded
5. route in catalog but 404/405 at runtime  → broken (route↔catalog drift)
6. route live in index.ts but ABSENT from VERBS (book seed/seeds, /v1/agent,
   /v1/skills, /scrape/*)  → reported separately as "uncatalogued route"
```

The two distinct buckets the prompt asks for:

| Bucket | Meaning | Trigger |
| --- | --- | --- |
| `degraded-key-absent` | Vendor key intentionally missing; handler degrades **honestly** (503 `not_configured`, or empty + an explicit `warnings[]`/`errors[]` entry). | KNOWN_ABSENT key + honest signal |
| `broken` | Handler returns success-shaped output that hides the failure, or 5xx it shouldn't, or catalog/runtime drift. | silent fallback, silent empty, stub-charging, route drift |

### 1.4 Concrete scaffold — `apps/api/test/validate-endpoints.ts`

Create `projects/brandnana/apps/api/test/validate-endpoints.ts` (sibling of the existing
`apps/api/test/smoke.ts`). Run target (do NOT run now):
`bun run apps/api/test/validate-endpoints.ts --base https://api.brandnana.net`.

Core loop sketch:

```ts
// apps/api/test/validate-endpoints.ts
import { VERBS, type Verb } from "@brandnana/schema";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// Bearer: read ~/.brandnana/key. NEVER log/print it.
const BEARER = readFileSync(join(homedir(), ".brandnana", "key"), "utf8").trim();
const BASE = process.env.BASE_URL ?? "https://api.brandnana.net";

// Vendor keys intentionally absent in prod (per KNOWN PROD REALITY).
const KNOWN_ABSENT = new Set(["exa", "e2b", "google", "meta", "tiktok"]); // OAuth-deferred + dropped
// Vendor → key whose absence makes empty output honest-but-degraded.
const VENDOR_KEY_ABSENT = (vendors: string[] = []) =>
  vendors.some((v) => KNOWN_ABSENT.has(v));

// Per-verb sample inputs (keyed by verb.id). Verbs with no entry → "skipped:no-fixture".
const FIXTURES: Record<string, { params?: Record<string, string>; body?: unknown }> = {
  "brand.fetch": { params: { include: "fonts,screenshot" }, body: undefined }, // path arg = domain
  "social.instagram.profile": {},          // /social/instagram/nike
  "ads.search": { body: { query: "running shoes", source: "all", brand: "nike.com" } },
  "catalog.crawl": { body: { domain: "allbirds.com", strategy: "auto" } },
  "book.build": { body: { domain: "nike.com" } },
  // ...one entry per testable verb; discovery verbs MUST include a brand to exercise meta leg
};

// Expected primary source per verb (for silent-fallback detection).
const EXPECTED_SOURCE: Record<string, string[]> = {
  "catalog.crawl": ["shopify", "context-dev"], // shopify preferred; context-dev w/ <=12 = suspect
  "ads.search": ["scrapecreators", "meta"],
  "ads.google": ["scrapecreators+firecrawl"],
};
const INFERIOR_FALLBACK: Record<string, string[]> = {
  "catalog.crawl": ["context-dev"], // only "inferior" when shopify was expected & count<=12
};

type Verdict =
  | "pass" | "degraded" | "degraded-key-absent" | "degraded-upstream"
  | "broken" | "skipped:no-fixture" | "uncatalogued";

interface Result {
  verbId: string; httpPath: string; status: number; verdict: Verdict;
  source?: string; cost?: number; count?: number; reason: string;
}

function buildUrl(verb: Verb, fx?: { params?: Record<string, string> }): string {
  // Substitute :slug/:domain path params from the fixture (path-arg = first positional).
  let path = verb.httpPath;
  if (fx?.params?.__path) path = path.replace(/:[a-zA-Z]+/g, fx.params.__path);
  const q = fx?.params
    ? "?" + new URLSearchParams(
        Object.fromEntries(Object.entries(fx.params).filter(([k]) => k !== "__path")))
    : "";
  return `${BASE}${path}${q}`;
}

function classify(verb: Verb, status: number, body: any, headers: Headers): Result {
  const source = body?.source ?? body?.stats?.source ?? headers.get("x-brandnana-strategy") ?? undefined;
  const cost = body?.cost ?? body?.cost_usd ?? undefined;
  const count = body?.count ?? body?.product_count ?? (Array.isArray(body?.ads) ? body.ads.length : undefined);
  const warned = !!(body?.warnings?.length || body?.errors?.length || body?.status === "fallback");
  const keyAbsent = VENDOR_KEY_ABSENT(verb.vendors);
  const base = { verbId: verb.id, httpPath: verb.httpPath, status, source, cost, count };

  // honest config failure
  if (status === 503 && /not_configured/.test(JSON.stringify(body)))
    return { ...base, verdict: keyAbsent ? "degraded-key-absent" : "broken",
      reason: keyAbsent ? "503 not_configured, key known-absent (honest)" : "503 not_configured but key SHOULD be set" };
  if (status === 502) return { ...base, verdict: "degraded-upstream", reason: "502 upstream (retry once)" };
  if (status >= 500) return { ...base, verdict: "broken", reason: `unexpected ${status}` };
  if (status === 404 || status === 405) return { ...base, verdict: "broken", reason: "route↔catalog drift" };

  // 200 paths
  if (count === 0 && keyAbsent && !warned)
    return { ...base, verdict: "broken", reason: "silent empty: key absent, no warnings[] emitted" };
  if (count === 0 && keyAbsent && warned)
    return { ...base, verdict: "degraded-key-absent", reason: "empty but warned (honest)" };
  if (source && (INFERIOR_FALLBACK[verb.id] ?? []).includes(source) && !warned)
    return { ...base, verdict: "broken", reason: `silent fallback to inferior source=${source}` };
  if (cost && cost > 0 && count === 0)
    return { ...base, verdict: "broken", reason: "charged cost but produced 0 results (stub)" };
  if (warned) return { ...base, verdict: "degraded", reason: "200 with warnings[]/status:fallback" };
  return { ...base, verdict: "pass", reason: `source=${source ?? "n/a"} count=${count ?? "n/a"}` };
}

async function main() {
  const results: Result[] = [];
  // 1) catalogued verbs
  for (const verb of VERBS) {
    const fx = FIXTURES[verb.id];
    if (!fx) { results.push({ verbId: verb.id, httpPath: verb.httpPath, status: 0,
      verdict: "skipped:no-fixture", reason: "no sample input registered" }); continue; }
    const url = buildUrl(verb, fx);
    const init: RequestInit = { method: verb.httpMethod,
      headers: { authorization: `Bearer ${BEARER}`, "content-type": "application/json" },
      body: verb.httpMethod === "POST" ? JSON.stringify(fx.body ?? {}) : undefined };
    let res: Response, body: any;
    try { res = await fetch(url, init); body = await res.json().catch(() => ({})); }
    catch (e) { results.push({ verbId: verb.id, httpPath: verb.httpPath, status: 0,
      verdict: "broken", reason: `transport: ${(e as Error).message}` }); continue; }
    let r = classify(verb, res.status, body, res.headers);
    if (r.verdict === "degraded-upstream") { // single retry for transient 502
      const res2 = await fetch(url, init); const b2 = await res2.json().catch(() => ({}));
      r = classify(verb, res2.status, b2, res2.headers);
    }
    results.push(r);
  }
  // 2) uncatalogued live routes (drift): assert they 404 OR flag if live-but-absent.
  const UNCATALOGUED = ["/v1/book/seed/nike", "/v1/book/seeds", "/v1/agent",
    "/v1/skills", "/scrape/exa", "/scrape/firecrawl"];
  // ...probe each, mark verdict:"uncatalogued" with the observed status.

  // 3) report: group by verdict; non-zero exit if any "broken".
  const broken = results.filter((r) => r.verdict === "broken");
  console.table(results.map(({ verbId, verdict, status, source, count, reason }) =>
    ({ verbId, verdict, status, source, count, reason })));
  console.log(JSON.stringify({ total: results.length,
    broken: broken.length,
    degradedKeyAbsent: results.filter((r) => r.verdict === "degraded-key-absent").length,
    pass: results.filter((r) => r.verdict === "pass").length }, null, 2));
  process.exit(broken.length ? 1 : 0);
}
main();
```

**Notes for the implementer:**

- The bearer key is read from `~/.brandnana/key` and used only as a header — never logged,
  never included in the report rows.
- Fixtures must include a `brand`/`domain` for discovery verbs, because the meta ad-library
  leg only fires when a brand is supplied (`ads/routes.ts:98`); without it the meta leg never
  runs and the harness would mis-classify a no-brand empty as `broken`.
- `EXPECTED_SOURCE` / `INFERIOR_FALLBACK` tables encode the silent-fallback knowledge from the
  audit (Shopify→context-dev demotion). Extend them as new fallbacks are discovered.
- Run modes: `--only <verbId>` for a single verb, `--namespace social` to scope, `--dry`
  to print the request plan without calling (sanity-check fixtures before spending vendor budget).
- This is **read-mostly** but discovery/ads/book verbs spend real vendor credits — gate behind an
  explicit `--live` flag and default to `--dry`.

---

## 2. Prioritized Remediation Roadmap

Severity legend: **P0** = blocks correct behavior or actively lies about success in prod;
**P1** = real drift / dead code / honesty gaps that mislead operators; **P2** = cleanup that
prevents future silent breakage.

### P0 — Stop lying about success; repoint dead providers; fix config blindness

#### P0-1 — Wire Valyu `/v1/search` to replace Exa across resolve / ads / book
- **What:** Add a `valyuSearch()` client (`POST https://api.valyu.ai/v1/search`, header
  `x-api-key: VALYU_API_KEY`, body `{search_type:"web", fast_mode:true, max_num_results:1-20,
  max_price}` — floor 20 CPM; use **only** `/v1/search`, never `/v1/deepsearch` or DeepResearch).
  Repoint every `exaSearch()` call site to Valyu. Until repointed, where Exa is still the only
  leg, return an explicit `warnings:["discovery_unavailable"]` instead of a silent empty array.
- **Why:** `EXA_API_KEY` is intentionally absent; `exaSearch()` throws (`scrape/exa.ts:37-39`)
  and the throw is swallowed at `ads/routes.ts:90` (`.catch(() => [])`), so `ads.search` returns
  `200 {count:0,ads:[]}` with zero signal the primary discovery surface is dead. `VALYU_API_KEY`
  is SET in prod with zero consumers. This is the #1 "looks wired but isn't" trap.
- **Files touched:** new `apps/api/src/scrape/valyu.ts`; `apps/api/src/env.ts:35` (add
  `VALYU_API_KEY?: string`, mark `EXA_API_KEY` deprecated); 6 Exa call sites —
  `apps/api/src/ads/routes.ts:12,72`, `apps/api/src/resolve/routes.ts:24,243,247`,
  `apps/api/src/scrape/routes.ts:9,28`, `apps/api/src/scrape/google_ads.ts:17,70`,
  `apps/api/src/book/pipeline.ts:19,235,237`; `packages/schema/src/verbs.ts` (replace
  `vendors:["exa"]` with `["valyu"]` on `ads.search`, `brand.discover`, book verbs).
- **Acceptance:** harness `ads.search {source:"all",brand:"nike.com"}` returns `count>0` from
  Valyu+scrapecreators OR `count:0` **with** a `warnings:["discovery_unavailable"]` entry (no
  silent empty). `grep -rn "exaSearch" apps/api/src` returns only the deprecated client or zero
  hits. `/v1/search` calls observe the `max_price` floor of 20.

#### P0-2 — Wire `THE_COMPANIES_API_KEY` (firmographics) or delete the orphan secret
- **What:** Either build a `thecompaniesapi.com` enrichment consumer (used in resolve/brand to
  attach firmographics) reading `env.THE_COMPANIES_API_KEY`, OR remove the prod secret. Decide
  per product intent. If wired, add `vendors:["thecompaniesapi"]` to the affected verbs.
- **Why:** `THE_COMPANIES_API_KEY` is SET in prod with **zero** code consumers (`grep` across
  `apps/api/src` + `packages` = 0). A set-but-unused secret implies a capability that does not
  exist.
- **Files touched:** `apps/api/src/env.ts` (declare the binding); new
  `apps/api/src/enrich/thecompanies.ts` (if wiring); the resolve/brand handler that consumes it;
  `packages/schema/src/verbs.ts` (vendor tag). If deleting: `wrangler secret delete` +
  remove from `/health`.
- **Acceptance:** `grep -rn "THE_COMPANIES_API_KEY" apps/api/src` returns a real consumer (not
  just `env.ts`), OR the secret is gone from `wrangler secret list` and not referenced anywhere.

#### P0-3 — Fix `/health` secretKeys blindness (both directions)
- **What:** In `apps/api/src/index.ts:128-143`, **remove** the keys that are intentionally absent
  and read-missing-forever (`EXA_API_KEY`, `E2B_API_KEY`, `CF_AI_GATEWAY_TOKEN`,
  `GITHUB_CLIENT_ID`) and **add** the prod-critical/new keys the self-report is currently blind to:
  `CEREBRAS_API_KEY`, `CLERK_SECRET_KEY`, `FIRECRAWL_API_KEY`, plus the migration keys
  `VALYU_API_KEY`, `WORKOS_API_KEY`, `WORKOS_CLIENT_ID`, `GROQ_API_KEY`, `THE_COMPANIES_API_KEY`
  (added as their consumers land). Keep `META_*`/`TIKTOK_*`/`GOOGLE_CLIENT_*` as deferred.
- **Why:** `/health` is the operator's source of truth and it has drifted from prod reality: it
  reports `EXA`/`E2B` as "missing" (alarming but expected) while being completely blind to
  `CEREBRAS_API_KEY` (the live dispatcher LLM, `dispatcher.ts:183,237`) and `CLERK_SECRET_KEY`
  (the sole auth provider). The dashboard misreports gaps.
- **Files touched:** `apps/api/src/index.ts:128-143`.
- **Acceptance:** `GET /` returns `secrets.CEREBRAS_API_KEY:"set"`, `secrets.CLERK_SECRET_KEY:"set"`,
  no `EXA_API_KEY`/`E2B_API_KEY`/`CF_AI_GATEWAY_TOKEN`/`GITHUB_CLIENT_ID` entries.

#### P0-4 — Resolve Clerk-vs-WorkOS (decide, then make code match secrets)
- **What:** Make an explicit decision and land it in code: **(A)** keep Clerk — then remove the
  orphan `WORKOS_API_KEY`/`WORKOS_CLIENT_ID` prod secrets and the unused
  `apps/portal/package.json:10` `@workos/authkit-sveltekit` dependency; **OR (B)** start the
  WorkOS migration — replace `verifySessionJwt` in `auth/portal-keys.ts` + `auth/cli-flow.ts`
  with WorkOS AuthKit verification. **Regardless of A/B**, fix the auth-bypass defect: the current
  Clerk path decodes the JWT with `atob` and never verifies the signature
  (`portal-keys.ts:80-87`, `cli-flow.ts:48-50`), and the session check is skipped when the token
  has no `sid` — a forged unsigned JWT with a valid `sub` mints a live `adk_live_*` key. Add real
  signature verification (JWKS via `@clerk/backend`, or WorkOS's verifier).
- **Why:** Both WorkOS keys are pure orphans (auth is 100% Clerk), AND the live Clerk path is
  bypassable. This is a correctness + security P0, not just drift.
- **Files touched:** `apps/api/src/auth/portal-keys.ts:9,21,80-106,158,208,236`,
  `apps/api/src/auth/cli-flow.ts:48-65,158`; `apps/api/package.json` (add `@clerk/backend` or
  WorkOS SDK); `apps/portal/package.json:10`; `apps/api/src/env.ts` (declare or drop WORKOS_*).
- **Acceptance:** a forged/unsigned JWT is rejected with 401 (add a unit test); `grep -rni workos`
  is either 0 (Clerk kept, secrets deleted) or shows a real AuthKit consumer; `_unusedClerkMeVerify`
  dead export removed.

#### P0-5 — Fix toolkit manifest drift (logo cascade text + bin name + skill index)
- **What:** Three corrections in `toolkits/brandnana/`:
  (a) **logo cascade text** — `manifest.org` describes the cascade as
  `Clearbit → logo.dev → favicon → render`, and the README/overview claim a Clearbit/favicon
  ordering, but `apps/api/src/agent/logo-fetch.ts:89` runs Clearbit **first unconditionally** so
  context.dev (logo.dev) is never reached when Clearbit serves. Either reorder the code (context.dev
  BEFORE Clearbit — see P1) and update the doc to match, or correct the doc to the real order.
  Also fix `manifest.org` / `manifest.org:38` and `brand.org:33-34`/`overview.org:35-36` which still
  list `brandfetch.com` even though brandfetch is excluded from the live cascade (`logo.ts:356-360`).
  (b) **bin name** — confirm every doc/skill uses `brandnana` (the real bin per
  `apps/cli/package.json:7` and `manifest.org #+CLI_BIN: brandnana`); remove any pre-rename
  `brandwork-*`/`adalign` references.
  (c) **skill index** — `manifest.org` skill index lists 1 of the actual skill files; reconcile the
  index table with the files that ship under `toolkits/brandnana/skills/` and the strategist
  pipeline skills, and fix `ENV_KEYS` to include `LOGO_DEV_TOKEN`/`GROQ_API_KEY` only where actually
  read (note: `GROQ_API_KEY` is CLI-local via `apps/cli/src/commands/logo.ts`, not a worker key).
- **Why:** The toolkit manifest is the agent's contract for what the CLI can do; documenting a logo
  cascade and skill set that don't match reality is exactly the "looks wired but isn't" class an
  agent will act on.
- **Files touched:** `toolkits/brandnana/manifest.org`, `.../overview.org`, `.../brand.org`;
  cross-check `apps/api/src/agent/logo-fetch.ts:89-119`.
- **Acceptance:** manifest logo-cascade text matches `logo-fetch.ts` order exactly; no `brandfetch`
  in the cascade text; skill index row count == shipped skill files; `grep -rn brandwork toolkits/`
  = 0.

#### P0-6 — Remove all E2B references (dropped feature)
- **What:** Delete `apps/api/src/sandbox/index.ts` (empty `export {}` + TODO stub); drop
  `E2B_API_KEY` from `apps/api/src/env.ts:55`, from the `/health` list
  (`apps/api/src/index.ts:142`, covered by P0-3), from `dev.vars.example:33` and
  `wrangler.toml:55`. The executor's `catalog_crawl`/`ads_search` verbs that return
  `status:"skipped"` (`executor.ts:87-91`) should either be wired to the real path (catalog →
  context-dev/shopify, ads → scrapecreators/Valyu) or have the skip surfaced as a documented
  capability gap, not a silent skip.
- **Why:** E2B was dropped; `E2B_API_KEY` has zero reads and only pollutes config + `/health`.
- **Files touched:** delete `apps/api/src/sandbox/index.ts`; `apps/api/src/env.ts:55`;
  `apps/api/src/index.ts:142`; `dev.vars.example:33`; `wrangler.toml:55`;
  `apps/api/src/agent/executor.ts:87-91`.
- **Acceptance:** `grep -rni e2b apps/api/src` = 0; `/health` has no `E2B_API_KEY`; build passes.

### P1 — Honesty / drift fixes that mislead but don't silently fabricate prod success

- **P1-1 — Logo cascade ordering bug.** Reorder `apps/api/src/agent/logo-fetch.ts` so context.dev
  (`logoDevToken`) is tried **before** Clearbit; demote favicon/og-image to a flagged last-resort in
  `LogoResult.source`. *Why:* Clearbit pre-empts context.dev for every caller that passes the token
  (`executor.ts:72,82`; `concept-deck.ts:97`; `dispatcher.ts:296`; `book/pipeline.ts:560,963`).
  *Acceptance:* a domain Clearbit serves but with a better context.dev logo returns the context.dev
  source; `LogoResult.source` flags favicon/og as `last-resort`.
- **P1-2 — Reconcile the three OpenRouter clients + two browser-rendering clients.** Collapse
  `apps/api/src/llm.ts`, `apps/api/src/llm/openrouter.ts`, and the inline fetches in
  `vision-verify.ts`/`image-gen.ts` into one client. Reconcile `fetch-brand.ts:137` (`@cloudflare/puppeteer`,
  which is **not a dependency** of the API worker — `apps/api/package.json:14-22`) against
  `homepage-scrape.ts:185` / `multipage-text.ts:191` (POST to the **non-existent**
  `https://browser-rendering.cf/v1/content`). *Why:* the puppeteer import throws at runtime and the
  catch silently falls through to paid context-dev/firecrawl with `ok:true`. *Acceptance:* one browser
  client; missing-binding path returns a flagged degradation, not a silent `ok:true` from a different
  paid source; `@cloudflare/puppeteer` added to `apps/api/package.json` if that path is kept.
- **P1-3 — Fix stale vision-verify comments + decide GOOGLE_API_KEY.** Vision routes through
  **OpenRouter** (`vision-verify.ts:19` model `google/gemini-3.5-flash`), not `GOOGLE_API_KEY`. Fix the
  false comments at `env.ts:51-54` and `book/pipeline.ts:626`, and delete the phantom `GOOGLE_API_KEY`
  field (`env.ts:54`) since nothing reads it. *Acceptance:* no comment claims vision uses GOOGLE_API_KEY;
  `grep env.GOOGLE_API_KEY` = 0.
- **P1-4 — Decide Groq's worker role.** Either add `GROQ_API_KEY` to `env.ts` and wire it as a worker
  LLM provider in `llm.ts`, or delete the prod worker secret (it's consumed only by the local CLI in
  `apps/cli/src/commands/logo.ts:519`, which uses the developer's own env). Also delete the dead CF AI
  Gateway module `apps/api/src/gateway.ts` (zero callers) and its misleading "goes through AI Gateway"
  docstrings in `llm/openrouter.ts:1-6`. *Acceptance:* `GROQ_API_KEY` either has a real worker consumer
  or is deleted; `gateway.ts` removed or actually wired.
- **P1-5 — Fix the nightly smoke test contract.** `test/smoke.ts:66-72` hard-requires the absent
  `EXA_API_KEY` + `CF_AI_GATEWAY_TOKEN`, so `smoke.yml` is red-by-design. Set expected to
  `FIRECRAWL, CONTEXT_DEV, SCRAPECREATORS, CEREBRAS, OPENROUTER, CLERK`. *Acceptance:* scheduled
  `smoke.yml` goes green on a healthy worker.
- **P1-6 — Register or remove the 9 CLI-orphan verbs + uncatalogued routes.** 9 verbs declare a
  `cliCommand` the CLI never registers (`brand.styleguide`/`screenshot` `verbs.ts:130,158`,
  `catalog.status:328`, `social.linkedin.post:726`, `social.youtube.searchHashtag/shortsTrending:817,828`,
  `social.twitter.tweetTranscript:875`, `social.facebook.postComments:944`,
  `social.reddit.postComments:1005`) — MCP-callable but a shell "unknown command". Conversely,
  `/v1/book/seed/:slug`, `/v1/book/seeds`, `/v1/agent`, `/v1/skills`, `/scrape/*` are **live routes with
  no VERBS entry**. Register the CLI commands and add catalog entries for the live agent/skill/book-seed
  routes (the agent free-form `query → plan → execute → answer` capability is a headline feature absent
  from the contract). *Acceptance:* harness "uncatalogued route" list is empty; every `cliCommand`
  resolves in the CLI.

### P2 — Cleanup that prevents future silent breakage

- **P2-1 — Shopify probe retry.** Add a retry/backoff to `isShopify()` (`catalog/shopify.ts:136-148`)
  so a transient 429/5xx on the keyless `/products.json` probe does not silently demote a real Shopify
  store to the 12-product context-dev path (`routes.ts:57`). Add `shopify` to the `catalog.crawl`
  `vendors` array (`verbs.ts:325`, currently omits it despite being the preferred auto path).
- **P2-2 — Surface social/brief/book swallowed nulls.** `/brief` (`brief/routes.ts:81-92` — `settle()`
  catches throws only, social wrappers return null), `/ads/search` (`ads/routes.ts:90,118`), and
  `/book` (`book/pipeline.ts:256,282`) swallow vendor failures into empty payloads with an empty
  `errors[]`. Route these through the same loud `notFound()`/warning path the `/social/*` handlers use
  (`social/routes.ts:57-60`).
- **P2-3 — Finish the WORG_*→WB_* config rename** in `services/brandnana-agent/fly.toml:20-27` and
  `README.org`, and align the health endpoint (`/api/about` vs `/api/health`).
- **P2-4 — Pick one source of truth for the agent profile.** The shipped profile
  (`services/brandnana-agent/profile`, 2026-05-29) diverges from the canonical
  `substrates/brandnana/profile` (2026-06-03). Delete the shipped copy and `COPY substrates/...` in the
  Dockerfile, or add an rsync+CI-drift-fail step. (Substrate deploy blockers — `wb`/`brandnana`/`node`
  not installed in the Fly image, `WB_FORWARD_SECRETS` unset, memory path divergence — are tracked
  separately under the brandnana-agent service, not in this API plan.)
- **P2-5 — Update `dev.vars.example` + `wrangler.toml`.** Remove `E2B`/`LOGODEV`/`BRANDFETCH`; add the
  live keys so a clean `secrets-push.sh` yields a functional worker (`secrets-push.sh:45-46` skips
  empties).

---

## 3. End-to-End Smoke Sequence (run AFTER P0)

Run from `/Users/shinyobjectz/Apps/workbooks/projects/brandnana`. Bearer is read from
`~/.brandnana/key` (never echoed). Replace `$KEY` below with a shell read that does not print:
`KEY="$(cat ~/.brandnana/key)"`.

```bash
KEY="$(cat ~/.brandnana/key)"          # do NOT echo $KEY
BASE="https://api.brandnana.net"

# 0. Typecheck + unit must be green first (P0 touched env.ts, routes, verbs)
bun run -C apps/api tsc --noEmit        # expect 0 errors (was 11 — P0 must clear them)
bun test                                # api + cli unit suites

# 1. /health reflects prod reality (P0-3): CEREBRAS+CLERK set, no EXA/E2B/CF_AI_GATEWAY
curl -s "$BASE/" | jq '.secrets'        # assert CEREBRAS_API_KEY:"set", CLERK_SECRET_KEY:"set",
                                        # and NO EXA_API_KEY / E2B_API_KEY / CF_AI_GATEWAY_TOKEN keys

# 2. Social is the known-good baseline (must still pass — proves bearer + scrapecreators)
curl -s -H "authorization: Bearer $KEY" "$BASE/social/instagram/nike" | jq '{username,followers}'
# expect 200 with username=nike, followers>0  → PASS

# 3. ads.search discovery — the P0-1 fix. With a brand, meta+Valyu legs must fire.
curl -s -H "authorization: Bearer $KEY" -H "content-type: application/json" \
  -X POST "$BASE/ads/search" \
  -d '{"query":"running shoes","source":"all","brand":"nike.com"}' | jq '{count,source,warnings}'
# PASS: count>0 from valyu/scrapecreators/meta.
# ACCEPTABLE: count:0 ONLY IF warnings contains "discovery_unavailable" (NOT a silent empty).
# FAIL: count:0 with empty/absent warnings → P0-1 regressed.

# 4. Valyu repoint sanity (resolve leg) — confirm Exa is dead and Valyu serves discovery
curl -s -H "authorization: Bearer $KEY" -H "content-type: application/json" \
  -X POST "$BASE/v1/resolve" -d '{"query":"allbirds"}' | jq '{candidates:(.candidates|length),source}'
# expect candidates>0 with a valyu-backed source (was Exa, now repointed)

# 5. THE_COMPANIES wiring (P0-2) — if wired, firmographics present; if deleted, no claim
curl -s -H "authorization: Bearer $KEY" "$BASE/brand/nike.com?include=firmographics" | jq '.brand.firmographics'
# PASS: non-null firmographics object (wired) OR field simply absent (deleted, honest)

# 6. catalog.crawl source check (silent-fallback trap) — known Shopify store
curl -s -H "authorization: Bearer $KEY" -H "content-type: application/json" \
  -X POST "$BASE/catalog/crawl" -d '{"domain":"allbirds.com","strategy":"auto"}' \
  | jq '{source:.stats.source,product_count:.stats.product_count,cost}'
# PASS: source="shopify" with product_count>>12.
# FAIL: source="context-dev" with product_count<=12 (silent demotion — P2-1) OR
#       product_count:0 with cost>0 (stub-charging — book pipeline P0/P2).

# 7. Auth bypass guard (P0-4) — a forged unsigned JWT must be rejected
curl -s -o /dev/null -w "%{http_code}\n" -H "content-type: application/json" \
  -X POST "$BASE/v1/auth/portal/keys" \
  -d '{"session_jwt":"eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1c2VyXzEifQ."}'
# expect 401 (was: minted a live key). 200 here = P0-4 regressed.

# 8. Full catalog walk via the harness (DESIGN §1) — the authoritative pass/fail gate
bun run apps/api/test/validate-endpoints.ts --base "$BASE" --live
# expect: 0 "broken"; remaining empties classified as "degraded-key-absent" with warnings.
# non-zero exit (any "broken") blocks the release.
```

A release is **green** only when: typecheck + unit pass, `/health` matches prod reality,
steps 2–7 hit their PASS criteria, and step 8 reports **zero `broken`** verbs (all remaining
non-pass rows are `degraded-key-absent` with an honest warning signal).
