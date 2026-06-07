// Brand-fetch endpoint. Wraps context.dev's /brand/retrieve, normalises
// into the Brand shape from @brandnana/schema, and returns it to the CLI
// which writes the row into the user's local SQLite.
//
// We don't cache the *normalised* response in D1; the vendor layer
// already caches the raw upstream call for 24h, and tenants get
// per-tenant cache namespacing.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import {
  extractProduct,
  getFonts,
  getScreenshot,
  getStyleguide,
  retrieveBrand,
} from "../scrape/context.js";
import { fetchCompany } from "../scrape/thecompanies.js";
import { scrapeHomepageEvidence } from "../agent/homepage-scrape.js";
import { unionBrandPalette } from "../design/palette.js";

const brand = new Hono<{ Bindings: Bindings }>();
brand.use("*", requireBearer);

/**
 * Normalised core brand row written to the CLI's local SQLite.
 * `descriptors_json` packs everything sqlite-typed: fonts, socials,
 * colors, backdrops, industry, slogan. The optional `extras` returned
 * alongside (when ?include=…) carries fields the agent needs for
 * generation but that don't belong in the row (font CSS URLs,
 * full styleguide JSON, page screenshot, extracted product data).
 */
interface NormalisedBrand {
  id: string;
  domain: string;
  name: string | null;
  logo_url: string | null;
  palette_json: string | null;
  descriptors_json: string | null;
  fetched_at: number;
}

/**
 * Typed font surface for the director. `css_url` (when present) lets
 * scene HTML do `@font-face { src: url(css_url) }` directly, instead
 * of guessing the font name and falling back to system-ui.
 */
interface BrandFont {
  name: string;
  family: string;
  fallbacks: string[];
  css_url: string | null;
  usage: {
    percent_elements: number | null;
    percent_words: number | null;
  };
}

interface BrandExtras {
  fonts?: BrandFont[];
  styleguide?: unknown;
  screenshot_url?: string | null;
}

function pickLogo(
  logos: Array<{ url: string; type?: string; mode?: string }> | undefined,
): string | null {
  if (!logos || logos.length === 0) return null;
  // Prefer a light-mode icon, then any icon, then anything.
  const icon = logos.find((l) => l.type === "icon" && l.mode !== "dark");
  if (icon) return icon.url;
  const anyIcon = logos.find((l) => l.type === "icon");
  if (anyIcon) return anyIcon.url;
  return logos[0]?.url ?? null;
}

/**
 * Parse `?include=fonts,screenshot,styleguide` (CSV) into a set.
 * Anything unrecognised is dropped silently — additive evolution.
 */
function parseInclude(raw: string | null | undefined): Set<string> {
  if (!raw) return new Set();
  return new Set(
    raw
      .split(",")
      .map((s) => s.trim().toLowerCase())
      .filter(Boolean),
  );
}

/**
 * Normalise context.dev's font response into the typed BrandFont
 * shape. `fontLinks` is a free-form record on context.dev's side; we
 * try common keys to find a CSS @import URL per font family.
 */
function pickFontCss(
  family: string,
  fontLinks: Record<string, unknown> | undefined,
): string | null {
  if (!fontLinks) return null;
  const candidates = [family, family.toLowerCase(), family.replace(/\s+/g, "+")];
  for (const k of candidates) {
    const v = fontLinks[k];
    if (typeof v === "string" && v.startsWith("http")) return v;
    if (v && typeof v === "object") {
      const obj = v as { css?: string; url?: string; href?: string };
      const url = obj.css ?? obj.url ?? obj.href;
      if (typeof url === "string" && url.startsWith("http")) return url;
    }
  }
  return null;
}

brand.get("/:domain", async (c) => {
  const domain = c.req.param("domain");
  if (!domain || !/^[a-z0-9.-]+\.[a-z]{2,}$/i.test(domain)) {
    return c.json({ error: "invalid_domain" }, 400);
  }
  const include = parseInclude(c.req.query("include"));
  const user = c.get("user");

  try {
    const res = await retrieveBrand(c.env, domain, user.id, c.executionCtx);
    if (!res.brand) {
      return c.json({ error: "not_found" }, 404);
    }
    const b = res.brand;
    const normalised: NormalisedBrand = {
      id: crypto.randomUUID(),
      domain,
      name: b.title ?? null,
      logo_url: pickLogo(b.logos),
      palette_json: b.colors ? JSON.stringify(b.colors.map((c) => c.hex)) : null,
      descriptors_json: JSON.stringify({
        description: b.description ?? null,
        slogan: b.slogan ?? null,
        colors: b.colors ?? [],
        backdrops: b.backdrops ?? [],
        fonts: b.fonts ?? [],
        socials: b.socials ?? {},
        industry: b.industry ?? null,
      }),
      fetched_at: Date.now(),
    };

    // Fan out to side-quests if requested. Each is independent + tolerant
    // of upstream failure — a missing screenshot shouldn't break the core
    // brand record. Concurrent for latency.
    const extras: BrandExtras = {};
    const want = (k: string) => include.has(k) || include.has("all");
    const fetches: Promise<void>[] = [];

    if (want("fonts")) {
      fetches.push(
        getFonts(c.env, domain, user.id, c.executionCtx)
          .then((r) => {
            extras.fonts = (r.fonts ?? []).map((f) => ({
              name: f.font,
              family: f.font,
              fallbacks: f.fallbacks ?? [],
              css_url: pickFontCss(
                f.font,
                r.fontLinks as Record<string, unknown> | undefined,
              ),
              usage: {
                percent_elements: f.percent_elements ?? null,
                percent_words: f.percent_words ?? null,
              },
            }));
          })
          .catch(() => {
            extras.fonts = [];
          }),
      );
    }

    if (want("styleguide")) {
      fetches.push(
        getStyleguide(c.env, domain, user.id, c.executionCtx)
          .then((r) => {
            extras.styleguide = r.styleguide;
          })
          .catch(() => {
            extras.styleguide = null;
          }),
      );
    }

    if (want("screenshot")) {
      fetches.push(
        getScreenshot(c.env, domain, user.id, c.executionCtx)
          .then((r) => {
            extras.screenshot_url = r.screenshot ?? null;
          })
          .catch(() => {
            extras.screenshot_url = null;
          }),
      );
    }

    if (fetches.length > 0) await Promise.all(fetches);

    // Enrich palette_json with the SAME union design.tokens uses (vendor
    // colors + homepage theme-color + brand CSS vars + dominant ranked +
    // vision-on-screenshot if still < 6) so the SQLite brands row is rich on
    // its own — defense in depth for callers that run `brand fetch` but never
    // `design tokens`. This is the secondary fix for the "3 distinct hexes"
    // fault. Reuse the screenshot already fetched under ?include=screenshot
    // for the vision fallback; degrade to vendor-only on any failure.
    try {
      const evidence = await scrapeHomepageEvidence(domain, { browser: c.env.BROWSER }).catch(
        () => null,
      );
      const union = await unionBrandPalette({
        vendorColors: b.colors,
        evidence,
        screenshotUrl: extras.screenshot_url ?? null,
        brandName: b.title ?? domain,
        openrouterApiKey: c.env.OPENROUTER_API_KEY,
      });
      if (union.hexes.length > 0) {
        normalised.palette_json = JSON.stringify(union.hexes);
      }
    } catch {
      // Keep the vendor-only palette_json set at construction.
    }

    return c.json({
      brand: normalised,
      cached: false,
      ...(fetches.length > 0 ? { extras } : {}),
    });
  } catch (e) {
    const msg = (e as Error).message;
    if (msg.includes("not configured")) {
      return c.json({ error: "vendor_not_configured", message: msg }, 503);
    }
    return c.json({ error: "vendor_error", message: msg }, 502);
  }
});

// GET /brand/:domain/product?url=https://... — extract a single
// product page (name, price, images, features). The director uses
// this to pull product imagery + copy for hero shots / overlays.
brand.get("/:domain/product", async (c) => {
  const domain = validateDomain(c.req.param("domain"));
  if (!domain) return c.json({ error: "invalid_domain" }, 400);
  const url = c.req.query("url");
  if (!url || !/^https?:\/\//.test(url)) {
    return c.json({ error: "invalid_url" }, 400);
  }
  const user = c.get("user");
  try {
    const res = await extractProduct(c.env, url, user.id, c.executionCtx);
    return c.json(res);
  } catch (e) {
    return c.json({ error: "vendor_error", message: (e as Error).message }, 502);
  }
});

// GET /brand/:domain/company — firmographic enrichment via The Companies
// API (name, industry, NAICS/SIC, employee range, HQ, founded, socials,
// logo). Returns { company } or { company: null } when the provider has
// no record for the domain. The director uses this to ground the brand
// book in real firmographics instead of guesses.
brand.get("/:domain/company", async (c) => {
  const domain = validateDomain(c.req.param("domain"));
  if (!domain) return c.json({ error: "invalid_domain" }, 400);
  const user = c.get("user");
  try {
    const company = await fetchCompany(c.env, {
      domain,
      tenant: user.id,
      ctx: c.executionCtx,
    });
    // Honest "no firmographics" — distinct from an upstream failure.
    if (!company) return c.json({ company: null }, 404);
    return c.json({ company });
  } catch (e) {
    const msg = (e as Error).message;
    if (msg.includes("not configured")) {
      return c.json({ error: "vendor_not_configured", message: msg }, 503);
    }
    return c.json({ error: "vendor_error", message: msg }, 502);
  }
});

function validateDomain(domain: string | undefined): string | null {
  if (!domain) return null;
  return /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(domain) ? domain : null;
}

// GET /brand/:domain/styleguide — colors, typography, components, etc.
brand.get("/:domain/styleguide", async (c) => {
  const domain = validateDomain(c.req.param("domain"));
  if (!domain) return c.json({ error: "invalid_domain" }, 400);
  const user = c.get("user");
  try {
    const res = await getStyleguide(c.env, domain, user.id, c.executionCtx);
    return c.json(res);
  } catch (e) {
    return c.json({ error: "vendor_error", message: (e as Error).message }, 502);
  }
});

// GET /brand/:domain/fonts — font families + usage stats
brand.get("/:domain/fonts", async (c) => {
  const domain = validateDomain(c.req.param("domain"));
  if (!domain) return c.json({ error: "invalid_domain" }, 400);
  const user = c.get("user");
  try {
    const res = await getFonts(c.env, domain, user.id, c.executionCtx);
    return c.json(res);
  } catch (e) {
    return c.json({ error: "vendor_error", message: (e as Error).message }, 502);
  }
});

// GET /brand/:domain/screenshot — viewport screenshot URL (hosted by context.dev)
brand.get("/:domain/screenshot", async (c) => {
  const domain = validateDomain(c.req.param("domain"));
  if (!domain) return c.json({ error: "invalid_domain" }, 400);
  const user = c.get("user");
  try {
    const res = await getScreenshot(c.env, domain, user.id, c.executionCtx);
    return c.json(res);
  } catch (e) {
    return c.json({ error: "vendor_error", message: (e as Error).message }, 502);
  }
});

export default brand;
