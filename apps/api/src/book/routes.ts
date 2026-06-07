// POST /v1/book — composite pipeline: domain → brand-book tar.gz
//
// Auth: existing bearer (same as /brand, /ads/search).
//
// Request body:
//   { domain, competitors?, with_video?, link_only?, force? }
//
// Response on success: application/gzip tar.gz containing:
//   SKILL.md + <slug>.html
//
// Idempotency: cache by (account_id, slug). If a book for the same slug was
// generated within the last hour and force=false, return the cached R2 tar.gz.
// On success, write to R2 at:
//   brand-books/<account_id>/<slug>/latest.tar.gz
//   brand-books/<account_id>/<slug>/<utc_iso>.tar.gz

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import { buildBook } from "./pipeline.js";
import { SEED_BRANDS, SEED_SLUGS } from "../agent/seed-brands.js";
import renderSlides from "./render-slides.js";
import publish from "./publish.js";

const book = new Hono<{ Bindings: Bindings }>();
book.use("*", requireBearer);

// POST /v1/book/publish — upload a PRE-COMPOSED deck .html so it is served at
// GET /books/<slug>.html (the key serve.ts reads). Lets the ENGINE strategist
// publish its locally-composed deck so render-slides + the public URL resolve.
book.route("/publish", publish);

// POST /v1/book/render-slides — VISUAL-REVIEW gate: render a published deck to
// per-slide PNGs (mirrored to R2) so the strategist can SEE each slide.
book.route("/render-slides", renderSlides);

// ── Domain validation ─────────────────────────────────────────────────────────

function validateDomain(domain: string | undefined): string | null {
  if (!domain) return null;
  return /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(domain) ? domain : null;
}

// ── Cache path helpers ────────────────────────────────────────────────────────

function latestPath(accountId: string, slug: string): string {
  return `brand-books/${accountId}/${slug}/latest.tar.gz`;
}

function timestampedPath(accountId: string, slug: string, utcIso: string): string {
  // Sanitize ISO string for safe use as an R2 key: replace colons + dots
  const safe = utcIso.replace(/[:.]/g, "-");
  return `brand-books/${accountId}/${slug}/${safe}.tar.gz`;
}

const CACHE_TTL_MS = 60 * 60 * 1000; // 1 hour

// ── Route ─────────────────────────────────────────────────────────────────────

book.post("/", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as {
    domain?: string;
    competitors?: string[];
    with_video?: boolean;
    link_only?: boolean;
    force?: boolean;
  };

  const domain = validateDomain(body.domain);
  if (!domain) {
    return c.json({ error: "invalid_domain", message: "domain is required (e.g. nike.com)" }, 400);
  }

  const competitors = (body.competitors ?? []).filter(
    (d): d is string => typeof d === "string" && /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(d),
  );
  const withVideo = body.with_video ?? false;
  const linkOnly = body.link_only ?? false;
  const force = body.force ?? false;

  const user = c.get("user");
  const accountId = user.id;

  // Derive slug for the cache key (best-effort: strip www + TLD)
  const slug = domain
    .toLowerCase()
    .replace(/^www\./, "")
    .split(".")[0]
    ?.replace(/[^a-z0-9-]/g, "-") ?? domain.replace(/\./g, "-");

  // ── Cache check (R2) ──────────────────────────────────────────────────────
  if (!force && c.env.ASSETS) {
    try {
      const cached = await c.env.ASSETS.get(latestPath(accountId, slug));
      if (cached) {
        // Check freshness via custom-time metadata
        const uploadedAt = cached.customMetadata?.uploaded_at;
        if (uploadedAt) {
          const age = Date.now() - Number(uploadedAt);
          if (age < CACHE_TTL_MS) {
            const bytes = new Uint8Array(await cached.arrayBuffer());
            return new Response(bytes, {
              status: 200,
              headers: {
                "content-type": "application/gzip",
                "content-disposition": `attachment; filename="${slug}-brand-book.tar.gz"`,
                "x-brandnana-book-slug": slug,
                "x-brandnana-book-cached": "true",
                "x-brandnana-book-cost-usd": cached.customMetadata?.cost_usd ?? "0",
              },
            });
          }
        }
      }
    } catch {
      // R2 check failure is non-fatal; proceed to build
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  let result: Awaited<ReturnType<typeof buildBook>>;
  try {
    result = await buildBook(c.env, c.executionCtx, {
      domain,
      competitors,
      with_video: withVideo,
      link_only: linkOnly,
      force,
      account_id: accountId,
    });
  } catch (e) {
    const msg = (e as Error).message;
    return c.json({ error: "pipeline_error", message: msg }, 502);
  }

  const { tarGzBytes, cost, manifest } = result;
  const utcIso = manifest.generated_at;

  // ── Store in R2 (best-effort via waitUntil) ────────────────────────────────
  if (c.env.ASSETS) {
    c.executionCtx.waitUntil(
      (async () => {
        try {
          const meta: Record<string, string> = {
            uploaded_at: String(Date.now()),
            cost_usd: String(cost),
            slug,
            domain,
          };
          await Promise.all([
            c.env.ASSETS.put(latestPath(accountId, slug), tarGzBytes, {
              httpMetadata: { contentType: "application/gzip" },
              customMetadata: meta,
            }),
            c.env.ASSETS.put(timestampedPath(accountId, slug, utcIso), tarGzBytes, {
              httpMetadata: { contentType: "application/gzip" },
              customMetadata: meta,
            }),
          ]);
        } catch {
          // R2 write failure is non-fatal
        }
      })(),
    );
  }

  // ── Respond ────────────────────────────────────────────────────────────────
  return new Response(tarGzBytes, {
    status: 200,
    headers: {
      "content-type": "application/gzip",
      "content-disposition": `attachment; filename="${slug}-brand-book.tar.gz"`,
      "x-brandnana-book-slug": slug,
      "x-brandnana-book-cost-usd": String(Math.round(cost * 1e6) / 1e6),
      "x-brandnana-book-cached": "false",
    },
  });
});

// ── Seed-brand build (writes to PUBLIC R2 path) ──────────────────────────────
//
// POST /v1/book/seed/:slug
//   Builds one of the five demo brand books using hand-verified seed data +
//   Cerebras curation. Uploads the standalone .html to brand-books/public/<slug>.html
//   so the lander iframe can load it without auth.
//
//   Still bearer-gated (so randos can't keep regenerating + churning Cerebras
//   spend), but the OUTPUT is world-readable.

book.post("/seed/:slug", async (c) => {
  const slug = c.req.param("slug").toLowerCase();
  if (!SEED_SLUGS.includes(slug)) {
    return c.json(
      { error: "unknown_seed", message: `unknown seed brand: ${slug}`, available: SEED_SLUGS },
      404,
    );
  }
  const brand = SEED_BRANDS[slug]!;
  const user = c.get("user");

  let result: Awaited<ReturnType<typeof buildBook>>;
  try {
    result = await buildBook(c.env, c.executionCtx, {
      domain: brand.domain,
      account_id: user.id,
      seed_slug: slug,
      visibility: "public",
    });
  } catch (e) {
    return c.json({ error: "build_failed", message: (e as Error).message }, 502);
  }

  // Write the standalone .html to the PUBLIC R2 path.
  const publicHtmlKey = `brand-books/public/${slug}.html`;
  const publicTarKey = `brand-books/public/${slug}.tar.gz`;
  try {
    await Promise.all([
      c.env.ASSETS.put(publicHtmlKey, result.htmlBytes, {
        httpMetadata: { contentType: "text/html; charset=utf-8" },
        customMetadata: {
          slug,
          brand_name: brand.brand_name,
          domain: brand.domain,
          generated_at: result.manifest.generated_at,
          visibility: "public",
          data_source: result.data_source,
          curate_source: result.curate_source,
        },
      }),
      c.env.ASSETS.put(publicTarKey, result.tarGzBytes, {
        httpMetadata: { contentType: "application/gzip" },
        customMetadata: { slug, visibility: "public" },
      }),
    ]);
  } catch (e) {
    return c.json({ error: "r2_write_failed", message: (e as Error).message }, 502);
  }

  return c.json({
    ok: true,
    slug,
    brand_name: brand.brand_name,
    domain: brand.domain,
    url: `https://api.brandnana.net/books/${slug}.html`,
    html_bytes: result.htmlBytes.length,
    targz_bytes: result.tarGzBytes.length,
    curate_source: result.curate_source,
    data_source: result.data_source,
    generated_at: result.manifest.generated_at,
  });
});

book.get("/seeds", (c) => {
  return c.json({
    seeds: SEED_SLUGS.map((slug) => {
      const b = SEED_BRANDS[slug]!;
      return {
        slug,
        brand_name: b.brand_name,
        domain: b.domain,
        category: b.category,
        tagline: b.tagline,
        url: `https://api.brandnana.net/books/${slug}.html`,
      };
    }),
  });
});

export default book;
