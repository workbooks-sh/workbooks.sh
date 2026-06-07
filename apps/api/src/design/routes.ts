// Design tokens — normalised aggregation of context.dev's brand /
// styleguide / fonts endpoints into a single design-tokens.json shape.
//
// Goal: give a creative agent (gamut, Claude Code, anyone) a flat,
// predictable structure they can use without re-learning context.dev's
// upstream schemas. The shape is intentionally adjacent to design-token
// conventions (W3C Design Tokens working draft) without locking onto
// any specific spec.
//
// What this endpoint returns is GROUND TRUTH for the brand's:
//   - palette (named primary/secondary/accent/neutrals + any gradients)
//   - typography (font families + their dominance + observed sizes)
//   - voice (slogan, descriptors)
//
// What it does NOT return YET (deferred to a Browser Rendering pass):
//   - corner radii observed across buttons/cards/inputs
//   - spacing rhythm (margin/padding histograms)
//   - explicit CSS custom properties (--color-*, etc.)
//
// Those require running headless Chromium against the brand's site,
// scraping computed styles, and aggregating. That's a follow-up
// (wb-5w9s.7.6's "v2 enrichment" phase) — the v1 endpoint here pulls
// what context.dev already returns synchronously, which covers the
// 80% case for brand grounding.

import { Hono } from "hono";
import { requireBearer } from "../auth/middleware.js";
import type { Bindings } from "../env.js";
import {
  type ContextBrandColor,
  getFonts,
  getScreenshot,
  getStyleguide,
  retrieveBrand,
} from "../scrape/context.js";
import { scrapeHomepageEvidence } from "../agent/homepage-scrape.js";
import { type Swatch, classifyUnion, unionBrandPalette } from "./palette.js";

const design = new Hono<{ Bindings: Bindings }>();
design.use("*", requireBearer);

function validateDomain(raw: string | undefined): string | null {
  if (!raw) return null;
  return /^[a-z0-9.-]+\.[a-z]{2,}$/i.test(raw) ? raw : null;
}

/**
 * Flat, agent-friendly design tokens for a brand.
 *
 * Field discipline:
 *   - `palette.*` are hex strings (no rgb()/rgba() — convert upstream).
 *   - `fonts[].dominance` is the fraction of observed words/elements
 *     this font carries (0..1). Highest-dominance font is the primary.
 *   - `slogan` and `descriptors.short` are plain text; consumers shape
 *     them however they need.
 *   - `null` is used liberally for "we don't know" — never an empty
 *     string or "unknown" placeholder.
 */
interface DesignTokens {
  domain: string;
  fetched_at: number;
  palette: {
    primary: string | null;
    secondary: string | null;
    accent: string | null;
    neutrals: string[];
    // Flat hex list — kept as string[] for the deterministic substrate builder
    // (substrate.ts unionPalette pushes these as raw hex strings).
    all: string[];
    // Richer named+role'd swatches from the union (vendor + theme-color + CSS
    // vars + dominant + vision). `all` is derived from these; richer consumers
    // can prefer `swatches`.
    swatches: Swatch[];
  };
  fonts: Array<{
    family: string;
    fallbacks: string[];
    dominance: number | null;
    uses: string[];
  }>;
  voice: {
    name: string | null;
    slogan: string | null;
    description: string | null;
  };
  // Reserved fields populated by the v2 Browser Rendering enrichment
  // pass; null in v1.
  radii: null;
  spacing_rhythm: null;
  gradients: null;
  // Pointers back to the upstream sources so consumers can drill in.
  sources: {
    brand: "context-dev/brand/retrieve";
    styleguide: "context-dev/brand/styleguide";
    fonts: "context-dev/brand/fonts";
  };
}

function pickHex(c: ContextBrandColor | undefined): string | null {
  if (!c) return null;
  if (!c.hex) return null;
  const h = c.hex.trim();
  return h.startsWith("#") ? h : `#${h}`;
}

/** Fallback vendor-only palette (no homepage/vision enrichment). Used only if
 *  the union path is somehow unavailable; the live handler builds the rich
 *  union below. `pickHex` is referenced here so TS keeps it. */
function classifyPaletteVendorOnly(
  colors: ContextBrandColor[] | undefined,
): DesignTokens["palette"] {
  if (!colors || colors.length === 0) {
    return { primary: null, secondary: null, accent: null, neutrals: [], all: [], swatches: [] };
  }
  const swatches: Swatch[] = [];
  const seen = new Set<string>();
  colors.forEach((c, i) => {
    const hex = pickHex(c);
    if (!hex || seen.has(hex)) return;
    seen.add(hex);
    swatches.push({
      hex,
      name: c.name ?? `brand ${i + 1}`,
      role: i === 0 ? "primary" : i === 1 ? "secondary" : i === 2 ? "accent" : undefined,
    });
  });
  return { ...classifyUnion(swatches), swatches };
}

design.get("/tokens/:domain", async (c) => {
  const domain = validateDomain(c.req.param("domain"));
  if (!domain) return c.json({ error: "invalid_domain" }, 400);
  const user = c.get("user");

  // Fire every upstream leg in parallel. context.dev tolerates concurrent
  // calls per tenant; the vendor layer caches each result for 24h so
  // subsequent design.tokens calls for the same domain hit the cache.
  //
  // The homepage scrape (theme-color + brand CSS vars + dominant colors) and
  // the screenshot (vision fallback input) are fanned out HERE so the palette
  // union below reaches >=6 swatches without any agent-discretion step — this
  // is the fix for the "3 distinct hexes" fault. Both degrade gracefully:
  // a homepage-scrape failure or missing screenshot just yields a thinner
  // (vendor-only) palette rather than an error.
  const [brandRes, styleguideRes, fontsRes, evidenceRes, screenshotRes] =
    await Promise.allSettled([
      retrieveBrand(c.env, domain, user.id, c.executionCtx),
      getStyleguide(c.env, domain, user.id, c.executionCtx),
      getFonts(c.env, domain, user.id, c.executionCtx),
      scrapeHomepageEvidence(domain, { browser: c.env.BROWSER }),
      getScreenshot(c.env, domain, user.id, c.executionCtx),
    ]);

  // If brand-retrieve totally failed, the rest don't matter — return a
  // clear "we couldn't find this brand" rather than a half-populated
  // skeleton. Styleguide/fonts failures degrade gracefully.
  if (brandRes.status === "rejected") {
    return c.json(
      { error: "vendor_error", message: brandRes.reason?.message ?? String(brandRes.reason) },
      502,
    );
  }

  const brand = brandRes.value.brand;
  if (!brand) {
    return c.json({ error: "not_found" }, 404);
  }

  const fontsData = fontsRes.status === "fulfilled" ? fontsRes.value : null;
  // Styleguide currently unused in v1 token shape; pulled to warm the
  // vendor cache so the follow-up enrichment pass doesn't refetch.
  // Reference it explicitly so TS doesn't flag it as unused.
  void styleguideRes;

  // Build the rich unioned palette: vendor colors + homepage theme-color +
  // brand CSS vars + dominant ranked + (if still < 6) vision-on-screenshot.
  const evidence = evidenceRes.status === "fulfilled" ? evidenceRes.value : null;
  const screenshotUrl =
    screenshotRes.status === "fulfilled" ? screenshotRes.value.screenshot ?? null : null;
  const union = await unionBrandPalette({
    vendorColors: brand.colors,
    evidence,
    screenshotUrl,
    brandName: brand.title ?? domain,
    openrouterApiKey: c.env.OPENROUTER_API_KEY,
  });
  // Defense-in-depth: if the union somehow yielded nothing (no vendor colors,
  // homepage scrape failed, no screenshot/vision), fall back to vendor-only.
  const palette =
    union.swatches.length > 0
      ? { ...classifyUnion(union.swatches), swatches: union.swatches }
      : classifyPaletteVendorOnly(brand.colors);

  const tokens: DesignTokens = {
    domain,
    fetched_at: Math.floor(Date.now() / 1000),
    palette,
    fonts: (fontsData?.fonts ?? []).map((f) => ({
      family: f.font,
      fallbacks: f.fallbacks ?? [],
      dominance: f.percent_words != null
        ? Math.round(f.percent_words * 100) / 10000
        : null,
      uses: f.uses ?? [],
    })),
    voice: {
      name: brand.title ?? null,
      slogan: brand.slogan ?? null,
      description: brand.description ?? null,
    },
    radii: null,
    spacing_rhythm: null,
    gradients: null,
    sources: {
      brand: "context-dev/brand/retrieve",
      styleguide: "context-dev/brand/styleguide",
      fonts: "context-dev/brand/fonts",
    },
  };

  return c.json(tokens);
});

export default design;
