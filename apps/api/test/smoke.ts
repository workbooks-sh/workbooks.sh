#!/usr/bin/env bun
// End-to-end MVP smoke test.
//
// Runs against the live worker (or whatever BRANDNANA_BASE_URL points at)
// with an API key from BRANDNANA_API_KEY. Each step asserts a minimal
// invariant — we're checking "all the wiring is connected", not vendor
// quality. Costs ≈ 1 Exa call + 1 context.dev call + 1 Shopify crawl
// (free) + a few D1 reads per run. Cheap to run nightly.
//
// Usage:
//   BRANDNANA_API_KEY=adk_live_… bun apps/api/test/smoke.ts
//   BRANDNANA_BASE_URL=https://… BRANDNANA_API_KEY=…  bun apps/api/test/smoke.ts

const BASE = (process.env.BRANDNANA_BASE_URL ?? "https://brandnana-api.shane-6d4.workers.dev").replace(
  /\/+$/,
  "",
);
const KEY = process.env.BRANDNANA_API_KEY;

if (!KEY) {
  console.error("BRANDNANA_API_KEY must be set");
  process.exit(2);
}

const auth = { authorization: `Bearer ${KEY}` };
const jsonAuth = { ...auth, "content-type": "application/json" };

const results: Array<{ name: string; ok: boolean; ms: number; note?: string }> = [];

async function check(
  name: string,
  fn: () => Promise<{ ok: boolean; note?: string }>,
): Promise<void> {
  const t0 = Date.now();
  let res: { ok: boolean; note?: string };
  try {
    res = await fn();
  } catch (e) {
    res = { ok: false, note: (e as Error).message };
  }
  const ms = Date.now() - t0;
  results.push({ name, ...res, ms });
  const mark = res.ok ? "✓" : "✗";
  const detail = res.note ? ` — ${res.note}` : "";
  process.stdout.write(`${mark} ${name} (${ms}ms)${detail}\n`);
}

async function main() {
  process.stdout.write(
    `Brandnana smoke test\n  base: ${BASE}\n  key:  ${KEY?.slice(0, 17) ?? "<none>"}…\n\n`,
  );

  await check("GET /", async () => {
    const r = await fetch(`${BASE}/`);
    const j = (await r.json()) as { service?: string };
    return { ok: r.ok && j.service === "brandnana-api" };
  });

  await check("GET /health bindings all ok", async () => {
    const r = await fetch(`${BASE}/health`);
    const j = (await r.json()) as {
      bindings?: Record<string, string>;
      secrets?: Record<string, string>;
    };
    const bindingsOk = Object.values(j.bindings ?? {}).every((v) => v === "ok");
    const expected = [
      "CF_AI_GATEWAY_TOKEN",
      "EXA_API_KEY",
      "FIRECRAWL_API_KEY",
      "CONTEXT_DEV_API_KEY",
    ];
    const missing = expected.filter((k) => j.secrets?.[k] !== "set");
    return {
      ok: bindingsOk && missing.length === 0,
      note:
        missing.length > 0
          ? `missing secrets: ${missing.join(",")}`
          : `bindings=${JSON.stringify(j.bindings)}`,
    };
  });

  await check("GET /whoami (bearer accepted)", async () => {
    const r = await fetch(`${BASE}/whoami`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { user?: { id?: string } };
    return { ok: !!j.user?.id };
  });

  await check("POST /brand/allbirds.com (context.dev)", async () => {
    const r = await fetch(`${BASE}/brand/allbirds.com`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { brand?: { name?: string; palette_json?: string } };
    return {
      ok: !!j.brand?.name && !!j.brand?.palette_json,
      note: `name=${j.brand?.name}`,
    };
  });

  await check("POST /ads/search (Exa)", async () => {
    const r = await fetch(`${BASE}/ads/search`, {
      method: "POST",
      headers: jsonAuth,
      body: JSON.stringify({ query: "allbirds wool runner", source: "exa", limit: 3 }),
    });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { count?: number };
    return { ok: (j.count ?? 0) >= 1, note: `count=${j.count}` };
  });

  await check("POST /catalog/crawl allbirds.com (shopify path)", async () => {
    const r = await fetch(`${BASE}/catalog/crawl`, {
      method: "POST",
      headers: jsonAuth,
      body: JSON.stringify({ domain: "allbirds.com", strategy: "shopify", max_urls: 50 }),
    });
    if (!r.ok || !r.body) return { ok: false, note: `HTTP ${r.status}` };
    const strategy = r.headers.get("x-brandnana-strategy");
    let products = 0;
    let stats: { products?: number } | null = null;
    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl = buf.indexOf("\n");
      while (nl !== -1) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const row = JSON.parse(line);
          if (row.__type === "product") products++;
          if (row.__type === "stats") stats = row;
        }
        nl = buf.indexOf("\n");
      }
    }
    return {
      ok: strategy === "shopify" && products >= 1 && stats !== null,
      note: `strategy=${strategy} products=${products} stats.products=${stats?.products}`,
    };
  });

  await check("POST /catalog/crawl bombas.com (sitemap path)", async () => {
    const r = await fetch(`${BASE}/catalog/crawl`, {
      method: "POST",
      headers: jsonAuth,
      body: JSON.stringify({ domain: "bombas.com", strategy: "sitemap", max_urls: 20 }),
    });
    if (!r.ok || !r.body) return { ok: false, note: `HTTP ${r.status}` };
    const strategy = r.headers.get("x-brandnana-strategy");
    let products = 0;
    let stats: { products?: number; pages_fetched?: number } | null = null;
    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buf = "";
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      let nl = buf.indexOf("\n");
      while (nl !== -1) {
        const line = buf.slice(0, nl).trim();
        buf = buf.slice(nl + 1);
        if (line) {
          const row = JSON.parse(line);
          if (row.__type === "product") products++;
          if (row.__type === "stats") stats = row;
        }
        nl = buf.indexOf("\n");
      }
    }
    return {
      ok: strategy === "sitemap" && products >= 5 && stats !== null,
      note: `strategy=${strategy} products=${products} pages=${stats?.pages_fetched}`,
    };
  });

  await check("GET /social/instagram/allbirds?raw=true (envelope bypass)", async () => {
    const r = await fetch(`${BASE}/social/instagram/allbirds?raw=true`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { summary?: unknown; data?: { user?: unknown } };
    // With ?raw=true the envelope is bypassed: no `summary` key, raw
    // vendor shape (`data.user`) at the top level.
    return {
      ok: j.summary === undefined && !!j.data?.user,
      note: `summary=${j.summary === undefined ? "absent" : "present"} data.user=${!!j.data?.user}`,
    };
  });

  await check("GET /brief/allbirds.com resolved_handles_source", async () => {
    const r = await fetch(`${BASE}/brief/allbirds.com`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as {
      resolved_handles_source?: Record<string, string>;
    };
    const src = j.resolved_handles_source;
    if (!src) return { ok: false, note: "no resolved_handles_source field" };
    // Allbirds: IG/X/FB should resolve from brand_socials; TT/YT fall back
    // to domain_guess because brand.socials doesn't include them.
    return {
      ok:
        src.instagram === "brand_socials" &&
        src.facebook === "brand_socials" &&
        src.tiktok === "domain_guess",
      note: `ig=${src.instagram} fb=${src.facebook} tt=${src.tiktok}`,
    };
  });

  await check("GET /usage (rollup)", async () => {
    const r = await fetch(`${BASE}/usage?since_hours=1`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { totals?: { calls?: number }; providers?: unknown[] };
    return {
      ok: typeof j.totals?.calls === "number" && Array.isArray(j.providers),
      note: `calls=${j.totals?.calls}`,
    };
  });

  // Meta OAuth flow is verified live; we don't check the full callback
  // here because the dev META_GRAPH_TOKEN has a ~6h TTL and the smoke
  // key has no per-user OAuth connection. POST /auth/meta/start works
  // either way — that's the actual user-visible surface.
  await check("POST /auth/meta/start (OAuth scaffolding alive)", async () => {
    const r = await fetch(`${BASE}/auth/meta/start`, { method: "POST", headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { auth_url?: string; session_id?: string };
    return {
      ok: !!j.auth_url?.startsWith("https://www.facebook.com/") && !!j.session_id,
      note: j.session_id ? `session=${j.session_id.slice(0, 8)}…` : undefined,
    };
  });

  await check("GET /brand/allbirds.com/styleguide (context.dev)", async () => {
    const r = await fetch(`${BASE}/brand/allbirds.com/styleguide`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { status?: string; styleguide?: Record<string, unknown> };
    return {
      ok: j.status === "ok" && !!j.styleguide,
      note: `keys=${Object.keys(j.styleguide ?? {}).length}`,
    };
  });

  await check("GET /brand/allbirds.com/screenshot (context.dev)", async () => {
    const r = await fetch(`${BASE}/brand/allbirds.com/screenshot`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { screenshot?: string };
    return {
      ok: typeof j.screenshot === "string" && j.screenshot.startsWith("https://"),
    };
  });

  await check("GET /design/tokens/allbirds.com (aggregated tokens)", async () => {
    const r = await fetch(`${BASE}/design/tokens/allbirds.com`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as {
      domain?: string;
      palette?: { primary?: string | null; all?: string[] };
      fonts?: Array<{ family?: string }>;
      voice?: { name?: string | null };
    };
    const paletteOk = Array.isArray(j.palette?.all) && j.palette.all.length > 0;
    const fontsOk = Array.isArray(j.fonts) && j.fonts.length > 0;
    return {
      ok: j.domain === "allbirds.com" && paletteOk && fontsOk,
      note: `primary=${j.palette?.primary ?? "—"} fonts=${j.fonts?.length ?? 0} brand=${j.voice?.name ?? "—"}`,
    };
  });

  await check("POST /ads/google brand=allbirds (auto-discovery)", async () => {
    const r = await fetch(`${BASE}/ads/google`, {
      method: "POST",
      headers: jsonAuth,
      body: JSON.stringify({ brand: "allbirds" }),
    });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { advertiser_id?: string | null; source?: string };
    return {
      ok: typeof j.advertiser_id === "string" && j.advertiser_id.startsWith("AR"),
      note: `advertiser=${j.advertiser_id} via=${j.source}`,
    };
  });

  await check("POST /ads/search source=meta brand=allbirds", async () => {
    const r = await fetch(`${BASE}/ads/search`, {
      method: "POST",
      headers: jsonAuth,
      body: JSON.stringify({ query: "allbirds", source: "meta", brand: "allbirds", limit: 3 }),
    });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { count?: number; ads?: Array<{ source?: string }> };
    return {
      ok: (j.count ?? 0) >= 1 && j.ads?.[0]?.source === "meta",
      note: `count=${j.count}`,
    };
  });

  // The 5 profile routes now return {summary, raw} by default — assert
  // summary fields (normalized) rather than vendor-specific raw paths.
  type Envelope = { summary?: { username?: string; followers?: number | null } };

  await check("GET /social/instagram/allbirds", async () => {
    const r = await fetch(`${BASE}/social/instagram/allbirds`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as Envelope;
    return {
      ok: j.summary?.username === "allbirds" && typeof j.summary.followers === "number",
      note: `user=${j.summary?.username} followers=${j.summary?.followers}`,
    };
  });

  await check("GET /social/tiktok/allbirds", async () => {
    const r = await fetch(`${BASE}/social/tiktok/allbirds`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as Envelope;
    return {
      ok: typeof j.summary?.username === "string",
      note: `user=${j.summary?.username}`,
    };
  });

  await check("GET /social/youtube/MrBeast", async () => {
    const r = await fetch(`${BASE}/social/youtube/MrBeast`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as Envelope & { summary?: { followers?: number } };
    return {
      ok: typeof j.summary?.followers === "number" && j.summary.followers > 1_000_000,
      note: `subs=${j.summary?.followers}`,
    };
  });

  await check("GET /social/twitter/elonmusk", async () => {
    const r = await fetch(`${BASE}/social/twitter/elonmusk`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as Envelope;
    return {
      ok: typeof j.summary?.username === "string",
      note: `user=${j.summary?.username}`,
    };
  });

  await check("GET /social/facebook/weareallbirds", async () => {
    const r = await fetch(`${BASE}/social/facebook/weareallbirds`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { summary?: { display_name?: string; username?: string } };
    return {
      ok: typeof j.summary?.username === "string" && typeof j.summary.display_name === "string",
      note: `name=${j.summary?.display_name} id=${j.summary?.username}`,
    };
  });

  await check("GET /social/reddit/sneakers", async () => {
    const r = await fetch(`${BASE}/social/reddit/sneakers`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { success?: boolean; posts?: unknown[] };
    return {
      ok: j.success === true && Array.isArray(j.posts) && j.posts.length >= 1,
      note: `posts=${j.posts?.length}`,
    };
  });

  await check("GET /social/tiktok-shop/search?q=allbirds", async () => {
    const r = await fetch(`${BASE}/social/tiktok-shop/search?q=allbirds`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { success?: boolean; total_products?: number };
    return {
      ok: j.success === true && (j.total_products ?? 0) >= 1,
      note: `products=${j.total_products}`,
    };
  });

  await check("GET /social/threads/zuck", async () => {
    const r = await fetch(`${BASE}/social/threads/zuck`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { follower_count?: number; biography?: string };
    return {
      ok: typeof j.follower_count === "number",
      note: `followers=${j.follower_count}`,
    };
  });

  await check("GET /social/pinterest/search?q=sustainable+shoes", async () => {
    const r = await fetch(`${BASE}/social/pinterest/search?q=sustainable+shoes`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { success?: boolean; pins?: unknown[] };
    return {
      ok: j.success === true && Array.isArray(j.pins) && j.pins.length >= 1,
      note: `pins=${j.pins?.length}`,
    };
  });

  await check("GET /brief/allbirds.com (9-way fan-out)", async () => {
    const r = await fetch(`${BASE}/brief/allbirds.com`, { headers: auth });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as {
      brand?: { brand?: { name?: string } } | null;
      design?: { fonts?: string[]; components?: string[] };
      social?: { instagram?: { username?: string } | null };
      ads?: { google?: { advertiser_id?: string | null } | null };
      errors?: unknown[];
    };
    const brandOk = j.brand?.brand?.name === "Allbirds";
    const igOk = j.social?.instagram?.username === "allbirds";
    const googleOk = typeof j.ads?.google?.advertiser_id === "string";
    // Design block is "any of mode/fonts/components returned data" — context.dev
    // occasionally fails one leg transiently and we don't want flake on it.
    const designOk =
      !!j.design &&
      (j.design.mode !== null ||
        (j.design.fonts?.length ?? 0) > 0 ||
        (j.design.components?.length ?? 0) > 0);
    return {
      ok: brandOk && igOk && googleOk && designOk,
      note: `brand=${j.brand?.brand?.name} ig=${j.social?.instagram?.username} adv=${j.ads?.google?.advertiser_id} fonts=${j.design?.fonts?.length} errors=${j.errors?.length}`,
    };
  });

  await check("POST /mirror/images (R2 round-trip)", async () => {
    const r = await fetch(`${BASE}/mirror/images`, {
      method: "POST",
      headers: jsonAuth,
      body: JSON.stringify({ urls: ["https://httpbin.org/image/png"] }),
    });
    if (!r.ok) return { ok: false, note: `HTTP ${r.status}` };
    const j = (await r.json()) as { mapping?: Record<string, string> };
    const mirrored = Object.values(j.mapping ?? {})[0];
    if (!mirrored || !mirrored.includes("/assets/")) {
      return { ok: false, note: "no mirrored URL returned" };
    }
    // Fetch the mirrored URL — must serve the bytes back.
    const head = await fetch(mirrored, { method: "HEAD" });
    return {
      ok: head.ok && (head.headers.get("content-type") ?? "").includes("image"),
      note: `${head.status} ${head.headers.get("content-type")}`,
    };
  });

  const failed = results.filter((r) => !r.ok);
  process.stdout.write(`\n${results.length - failed.length}/${results.length} passed\n`);
  if (failed.length > 0) {
    process.stdout.write("\nfailures:\n");
    for (const f of failed) {
      process.stdout.write(`  ✗ ${f.name}${f.note ? ` — ${f.note}` : ""}\n`);
    }
    process.exit(1);
  }
}

main().catch((e) => {
  console.error("fatal:", e);
  process.exit(2);
});
