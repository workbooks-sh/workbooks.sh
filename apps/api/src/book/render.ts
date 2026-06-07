// Brand-book .org renderer.
//
// Implements a Mustache subset sufficient for the four brand-book templates.
// No external dependency — Workers bundle size matters.
//
// Supported tags:
//   {{var}}                  — scalar interpolation (string, number, undefined → "")
//   {{#section}}…{{/section}} — truthy / array iteration
//                               Arrays: body rendered once per item with the
//                               item as the local context. Items may be objects
//                               or scalars ({{.}} yields the scalar value).
//                               Non-array truthy values: body rendered once
//                               with the current context.
//   {{^section}}…{{/section}} — inverse: rendered when falsy or empty array
//   {{.}}                    — current scalar item inside an {{#array}} loop
//
// Special-character escaping: org-mode headline stars and bracket links
// are left as-is. The only escaping applied is replacing a bare `*` at the
// start of a value with a Unicode lookalike (U+2217 ∗) to avoid creating
// spurious org-mode headlines inside property drawer values.

import type {
  BrandInput,
  CategoryRecord,
  CompetitorInput,
  ProductsInput,
  TimelineInput,
} from "./types.js";
import {
  BRAND_TEMPLATE,
  COMPETITOR_TEMPLATE,
  PRODUCTS_TEMPLATE,
  TIMELINE_TEMPLATE,
} from "./templates.js";

// ── Core renderer ─────────────────────────────────────────────────────────────

type Context = Record<string, unknown>;

/**
 * Escape a scalar value before interpolation.
 *
 * - Converts undefined/null to empty string.
 * - Coerces numbers and booleans via String().
 * - Prevents a bare `*` at the very start of a value from opening an
 *   org-mode headline by replacing it with U+2217 (∗, ASTERISK OPERATOR).
 *   This only matters when the value lands at column 0 of a line; we
 *   apply it conservatively (all occurrences at start-of-line inside
 *   the value string).
 */
function escapeValue(v: unknown): string {
  if (v === null || v === undefined) return "";
  const s = String(v);
  // Replace a `*` that is at the start of any line inside the value.
  return s.replace(/^\*/gm, "∗");
}

/**
 * Minimal Mustache-subset renderer.
 *
 * Handles:
 *   {{var}}, {{#section}}…{{/section}}, {{^section}}…{{/section}}, {{.}}
 *
 * Context lookup is single-level only (no dotted paths). When rendering
 * inside an array loop the item is the local context; the parent context
 * is NOT searched (keep it simple, keep bundle size small).
 */
export function render(template: string, data: Context): string {
  return renderBlock(template, data);
}

function renderBlock(text: string, ctx: Context): string {
  // Process section tags first (they may contain scalar tags).
  // We use a recursive approach: find the outermost section, render it,
  // then recurse on the remainder.
  const sectionRe = /\{\{([#^])([\w.]+)\}\}([\s\S]*?)\{\{\/\2\}\}/g;

  let result = "";
  let lastIndex = 0;

  // Reset regex state before searching (necessary since we use exec in a loop).
  sectionRe.lastIndex = 0;

  let match: RegExpExecArray | null;
  // biome-ignore lint/suspicious/noAssignInExpressions: idiomatic exec loop
  while ((match = sectionRe.exec(text)) !== null) {
    // Append the literal text before this section tag.
    result += renderScalars(text.slice(lastIndex, match.index), ctx);

    const [, kind, key, body] = match as RegExpExecArray & [string, string, string, string];
    const value = ctx[key];
    const isInverse = kind === "^";

    if (isInverse) {
      // {{^section}} — render body when falsy or empty array
      if (!value || (Array.isArray(value) && value.length === 0)) {
        result += renderBlock(body, ctx);
      }
    } else {
      // {{#section}} — render body when truthy / per array item
      if (Array.isArray(value)) {
        for (const item of value) {
          const itemCtx: Context =
            item !== null && typeof item === "object"
              ? (item as Context)
              : { ".": item };
          result += renderBlock(body, itemCtx);
        }
      } else if (value) {
        result += renderBlock(body, ctx);
      }
    }

    lastIndex = match.index + match[0].length;
  }

  result += renderScalars(text.slice(lastIndex), ctx);
  return result;
}

/** Replace {{var}} and {{.}} tags with their escaped values. */
function renderScalars(text: string, ctx: Context): string {
  return text.replace(/\{\{([\w.]+)\}\}/g, (_, key: string) => {
    if (key === ".") return escapeValue(ctx["."]);
    return escapeValue(ctx[key]);
  });
}

// ── Typed render functions ────────────────────────────────────────────────────

/** Render the main brand book section (brand.org.template). */
export function renderBrand(input: BrandInput): string {
  const ctx: Context = {
    ...input,
    utc_iso: input.utc_iso ?? new Date().toISOString(),
    version: input.version ?? "0",
    legal_name: input.legal_name ?? "",
    founded_year: input.founded_year != null ? String(input.founded_year) : "",
    hq_city: input.hq_city ?? "",
    category: input.category ?? "",
    tagline: input.tagline ?? "",
    descriptors: input.descriptors ?? [],
    voice_notes: input.voice_notes ?? "",
    primary_hex: input.primary_hex ?? "",
    primary_name: input.primary_name ?? "",
    secondary_hex: input.secondary_hex ?? "",
    secondary_name: input.secondary_name ?? "",
    extended_colors: input.extended_colors ?? [],
    primary_font: input.primary_font ?? "",
    secondary_font: input.secondary_font ?? "",
    mono_font: input.mono_font ?? "",
    logo_primary_url: input.logo_primary_url ?? "",
    logo_on_light_url: input.logo_on_light_url ?? "",
    logo_on_dark_url: input.logo_on_dark_url ?? "",
    logo_svg_path: input.logo_svg_path ?? "",
    social: input.social ?? [],
    capture_verbs: input.capture_verbs ?? [],
  };
  return render(BRAND_TEMPLATE, ctx);
}

/** Render a competitor section (competitor.org.template). */
export function renderCompetitor(input: CompetitorInput): string {
  const ctx: Context = {
    ...input,
    utc_iso: input.utc_iso ?? new Date().toISOString(),
    category: input.category ?? "",
    snapshot_notes: input.snapshot_notes ?? "",
    palette_distance: input.palette_distance != null ? String(input.palette_distance) : "",
    tone_delta: input.tone_delta ?? "",
    delta_notes: input.delta_notes ?? "",
    ads: (input.ads ?? []).map((ad) => ({
      ad_headline: ad.ad_headline ?? "",
      ad_id: ad.ad_id ?? "",
      provider: ad.provider ?? "",
      first_seen: ad.first_seen ?? "",
      last_seen: ad.last_seen ?? "",
      platform: ad.platform ?? "",
      cta: ad.cta ?? "",
      landing_url: ad.landing_url ?? "",
      media_url: ad.media_url ?? "",
      media_type: ad.media_type ?? "",
      ad_body: ad.ad_body ?? "",
      theme: ad.theme ?? "",
      emotion: ad.emotion ?? "",
      hook: ad.hook ?? "",
    })),
  };
  return render(COMPETITOR_TEMPLATE, ctx);
}

/** Render the product catalog (products.org.template). */
export function renderProducts(input: ProductsInput): string {
  const normalizeProducts = (products: CategoryRecord["products"]) =>
    (products ?? []).map((p) => ({
      ...p,
      slug: p.slug ?? "",
      sku: p.sku ?? "",
      price: p.price != null ? String(p.price) : "",
      currency: p.currency ?? "",
      sizes_csv: p.sizes_csv ?? "",
      colors_csv: p.colors_csv ?? "",
      images_csv: p.images_csv ?? "",
      url: p.url ?? "",
      stock_status: p.stock_status ?? "",
      materials_csv: p.materials_csv ?? "",
      tags_csv: p.tags_csv ?? "",
      category_path: p.category_path ?? "",
      collection: p.collection ?? "",
      price_band: p.price_band ?? "",
      description: p.description ?? "",
    }));

  const ctx: Context = {
    brand_name: input.brand_name,
    utc_iso: input.utc_iso ?? new Date().toISOString(),
    product_count: input.product_count != null ? String(input.product_count) : "",
    category_count: input.category_count != null ? String(input.category_count) : "",
    categories: (input.categories ?? []).map((cat) => ({
      name: cat.name,
      subcategories: (cat.subcategories ?? []).map((sub) => ({
        name: sub.name,
        products: normalizeProducts(sub.products),
      })),
      products: normalizeProducts(cat.products),
    })),
    collections: (input.collections ?? []).map((col) => ({
      name: col.name,
      products: normalizeProducts(col.products),
    })),
    colors: (input.colors ?? []).map((c) => ({
      name: c.name,
      slug: c.slug ?? "",
      products: normalizeProducts(c.products),
    })),
    price_bands: (input.price_bands ?? []).map((pb) => ({
      name: pb.name,
      products: normalizeProducts(pb.products),
    })),
    stock_groups: (input.stock_groups ?? []).map((sg) => ({
      status: sg.status,
      products: normalizeProducts(sg.products),
    })),
  };
  return render(PRODUCTS_TEMPLATE, ctx);
}

/** Render the capture timeline (timeline.org.template). */
export function renderTimeline(input: TimelineInput): string {
  const ctx: Context = {
    brand_name: input.brand_name,
    utc_iso: input.utc_iso ?? new Date().toISOString(),
    events: (input.events ?? []).map((ev) => ({
      ts: ev.ts,
      verb_id: ev.verb_id,
      status: ev.status,
      duration_ms: ev.duration_ms != null ? String(ev.duration_ms) : "",
      vendor_cost_usd: ev.vendor_cost_usd != null ? String(ev.vendor_cost_usd) : "0.000000",
      customer_charge_usd:
        ev.customer_charge_usd != null ? String(ev.customer_charge_usd) : "0.000000",
      margin_usd: ev.margin_usd != null ? String(ev.margin_usd) : "0.000000",
      summary: ev.summary ?? "",
      // error is a {{^error}}…{{/error}} candidate — pass as falsy when absent
      error: ev.error ?? "",
    })),
  };
  return render(TIMELINE_TEMPLATE, ctx);
}
