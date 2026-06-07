// Tests for the brand-book .org template renderer.
//
// Run with: bun test test/book-render.test.ts
// (from substrates/brandwork/apps/api/)

import { describe, expect, it } from "bun:test";
import { render, renderBrand, renderCompetitor, renderProducts, renderTimeline } from "../src/book/render.js";

// ── render() — core Mustache-subset engine ────────────────────────────────────

describe("render() — scalar interpolation", () => {
  it("replaces {{var}} with its string value", () => {
    expect(render("hello {{name}}", { name: "world" })).toBe("hello world");
  });

  it("coerces numbers to string", () => {
    expect(render("{{n}}", { n: 42 })).toBe("42");
  });

  it("replaces missing vars with empty string", () => {
    expect(render("{{missing}}", {})).toBe("");
  });

  it("replaces undefined values with empty string", () => {
    expect(render("{{x}}", { x: undefined })).toBe("");
  });

  it("replaces null values with empty string", () => {
    expect(render("{{x}}", { x: null })).toBe("");
  });

  it("escapes a leading * in a value to avoid spurious org headlines", () => {
    const result = render(":KEY: {{val}}", { val: "* danger" });
    expect(result).toContain(":KEY: ∗ danger");
    expect(result).not.toContain(":KEY: * danger");
  });

  it("leaves * mid-string unescaped", () => {
    const result = render("{{val}}", { val: "foo * bar" });
    expect(result).toBe("foo * bar");
  });
});

describe("render() — {{#section}} truthy / array iteration", () => {
  it("renders the body when a truthy scalar is provided", () => {
    const result = render("{{#show}}visible{{/show}}", { show: true });
    expect(result).toBe("visible");
  });

  it("suppresses the body when falsy", () => {
    const result = render("{{#show}}visible{{/show}}", { show: false });
    expect(result).toBe("");
  });

  it("suppresses the body when section is missing from context", () => {
    const result = render("{{#show}}visible{{/show}}", {});
    expect(result).toBe("");
  });

  it("iterates an array of objects, exposing each item's fields", () => {
    const result = render(
      "{{#items}}{{name}},{{/items}}",
      { items: [{ name: "a" }, { name: "b" }] },
    );
    expect(result).toBe("a,b,");
  });

  it("iterates an array of scalars, exposing {{.}}", () => {
    const result = render("{{#tags}}-{{.}}{{/tags}}", { tags: ["x", "y"] });
    expect(result).toBe("-x-y");
  });

  it("suppresses the body for an empty array", () => {
    const result = render("{{#items}}X{{/items}}", { items: [] });
    expect(result).toBe("");
  });
});

describe("render() — {{^section}} inverse", () => {
  it("renders when the value is falsy", () => {
    const result = render("{{^show}}hidden{{/show}}", { show: false });
    expect(result).toBe("hidden");
  });

  it("renders when the section is absent from context", () => {
    const result = render("{{^missing}}shown{{/missing}}", {});
    expect(result).toBe("shown");
  });

  it("renders when the array is empty", () => {
    const result = render("{{^items}}empty{{/items}}", { items: [] });
    expect(result).toBe("empty");
  });

  it("suppresses when the value is truthy", () => {
    const result = render("{{^show}}hidden{{/show}}", { show: true });
    expect(result).toBe("");
  });
});

// ── renderBrand() ─────────────────────────────────────────────────────────────

describe("renderBrand()", () => {
  const SAMPLE_BRAND = {
    brand_name: "Acme Corp",
    slug: "acme-corp",
    domain: "acme.com",
    utc_iso: "2026-05-28T00:00:00.000Z",
    version: "1.0.0",
    legal_name: "Acme Corporation LLC",
    founded_year: 1952,
    hq_city: "Phoenix, AZ",
    category: "Consumer Goods",
    tagline: "We make everything.",
    descriptors: ["reliable", "quirky", "accessible"],
    voice_notes: "Dry, self-aware humor with a Looney Tunes wink.",
    primary_hex: "#E63946",
    primary_name: "Acme Red",
    secondary_hex: "#457B9D",
    secondary_name: "Acme Blue",
    extended_colors: [
      { name: "Sand", hex: "#F1FAEE" },
      { name: "Night", hex: "#1D3557" },
    ],
    primary_font: "Futura",
    secondary_font: "Georgia",
    mono_font: "JetBrains Mono",
    logo_primary_url: "https://acme.com/logo.png",
    logo_on_light_url: "https://acme.com/logo-light.png",
    logo_on_dark_url: "https://acme.com/logo-dark.png",
    logo_svg_path: "assets/logo.svg",
    social: [
      { network: "twitter", handle: "@acme", url: "https://twitter.com/acme" },
    ],
    capture_verbs: [
      { verb: "brand.fetch", ts: "2026-05-28T00:00:00Z", summary: "Fetched logo + palette" },
    ],
  };

  it("includes the brand name as an org heading", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).toContain("* Acme Corp");
  });

  it("sets #+TITLE to brand name", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).toContain("#+TITLE: Acme Corp brand book");
  });

  it("includes domain in keyword and properties", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).toContain("#+DOMAIN: acme.com");
    expect(out).toContain(":DOMAIN:       acme.com");
  });

  it("emits :brand: tag on the top-level headline", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).toContain(":brand:");
  });

  it("PROPERTIES and END are balanced", () => {
    const out = renderBrand(SAMPLE_BRAND);
    const openCount = (out.match(/:PROPERTIES:/g) ?? []).length;
    const closeCount = (out.match(/:END:/g) ?? []).length;
    expect(openCount).toBeGreaterThan(0);
    expect(openCount).toBe(closeCount);
  });

  it("renders descriptors as a list", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).toContain("- reliable");
    expect(out).toContain("- quirky");
    expect(out).toContain("- accessible");
  });

  it("renders extended_colors", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).toContain("- Sand: #F1FAEE");
    expect(out).toContain("- Night: #1D3557");
  });

  it("renders social handles", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).toContain("- twitter: @acme (https://twitter.com/acme)");
  });

  it("renders capture_verbs", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).toContain("- brand.fetch@2026-05-28T00:00:00Z: Fetched logo + palette");
  });

  it("has no leftover {{…}} mustache tokens", () => {
    const out = renderBrand(SAMPLE_BRAND);
    expect(out).not.toMatch(/\{\{[^}]+\}\}/);
  });

  it("escapes a brand name that starts with * in property values", () => {
    const out = renderBrand({ ...SAMPLE_BRAND, tagline: "* Everything, all at once" });
    // The tagline value should not create a bare org headline
    expect(out).not.toContain(":TAGLINE:      * Everything");
    expect(out).toContain("∗ Everything");
  });

  it("handles a minimal input with only required fields", () => {
    const out = renderBrand({ brand_name: "Minimal", slug: "minimal", domain: "minimal.io" });
    expect(out).toContain("* Minimal");
    expect(out).not.toMatch(/\{\{[^}]+\}\}/);
  });
});

// ── renderCompetitor() ────────────────────────────────────────────────────────

describe("renderCompetitor()", () => {
  const SAMPLE = {
    competitor_name: "RivalCo",
    brand_name: "Acme Corp",
    slug: "rivalco",
    domain: "rivalco.com",
    utc_iso: "2026-05-28T00:00:00.000Z",
    category: "Consumer Goods",
    snapshot_notes: "RivalCo pivoted to B2B in 2024.",
    palette_distance: 0.72,
    tone_delta: "warmer",
    delta_notes: "Softer palette, more approachable tone.",
    ads: [
      {
        ad_headline: "RivalCo — built for builders",
        ad_id: "ad-001",
        provider: "meta",
        first_seen: "2026-01-15",
        last_seen: "2026-05-01",
        platform: "instagram",
        cta: "Shop Now",
        landing_url: "https://rivalco.com/shop",
        media_url: "https://rivalco.com/ad1.jpg",
        media_type: "image",
        ad_body: "Stop settling. Build better.",
        theme: "aspiration",
        emotion: "confidence",
        hook: "You deserve better tools.",
      },
    ],
  };

  it("includes competitor name as headline with :competitor: tag", () => {
    const out = renderCompetitor(SAMPLE);
    expect(out).toContain("* RivalCo");
    expect(out).toContain(":competitor:");
  });

  it("includes comparison target in title", () => {
    const out = renderCompetitor(SAMPLE);
    expect(out).toContain("competitor of Acme Corp");
  });

  it("renders the ad with its headline and :ad: tag", () => {
    const out = renderCompetitor(SAMPLE);
    expect(out).toContain("*** RivalCo — built for builders");
    expect(out).toContain(":ad:");
  });

  it("renders ad property drawer fields", () => {
    const out = renderCompetitor(SAMPLE);
    expect(out).toContain(":AD_ID:        ad-001");
    expect(out).toContain(":PROVIDER:     meta");
    expect(out).toContain(":PLATFORM:     instagram");
  });

  it("PROPERTIES and END are balanced", () => {
    const out = renderCompetitor(SAMPLE);
    const opens = (out.match(/:PROPERTIES:/g) ?? []).length;
    const closes = (out.match(/:END:/g) ?? []).length;
    expect(opens).toBe(closes);
  });

  it("has no leftover {{…}} mustache tokens", () => {
    const out = renderCompetitor(SAMPLE);
    expect(out).not.toMatch(/\{\{[^}]+\}\}/);
  });

  it("handles no ads gracefully", () => {
    const out = renderCompetitor({ ...SAMPLE, ads: [] });
    expect(out).not.toMatch(/\{\{[^}]+\}\}/);
    expect(out).toContain("* RivalCo");
  });
});

// ── renderProducts() ──────────────────────────────────────────────────────────

describe("renderProducts()", () => {
  const SAMPLE: Parameters<typeof renderProducts>[0] = {
    brand_name: "Acme Corp",
    utc_iso: "2026-05-28T00:00:00.000Z",
    product_count: 3,
    category_count: 1,
    categories: [
      {
        name: "Gadgets",
        subcategories: [
          {
            name: "Rockets",
            products: [
              {
                name: "ACME Rocket",
                slug: "acme-rocket",
                sku: "RKT-001",
                price: 299.99,
                currency: "USD",
                sizes_csv: "S,M,L",
                colors_csv: "Red,Silver",
                images_csv: "https://acme.com/rocket.jpg",
                url: "https://acme.com/rocket",
                stock_status: "in_stock",
                materials_csv: "steel,rubber",
                tags_csv: "fast,reliable",
                category_path: "Gadgets > Rockets",
                collection: "Classic",
                price_band: "premium",
                description: "Goes fast. Explodes rarely.",
              },
            ],
          },
        ],
      },
    ],
    collections: [
      {
        name: "Classic",
        products: [{ name: "ACME Rocket", slug: "acme-rocket" }],
      },
    ],
    colors: [
      {
        name: "Red",
        slug: "red",
        products: [{ name: "ACME Rocket", slug: "acme-rocket" }],
      },
    ],
    price_bands: [
      {
        name: "premium",
        products: [{ name: "ACME Rocket", slug: "acme-rocket", price: 299.99 }],
      },
    ],
    stock_groups: [
      {
        status: "in_stock",
        products: [{ name: "ACME Rocket", slug: "acme-rocket" }],
      },
    ],
  };

  it("includes #+PRODUCT_COUNT", () => {
    const out = renderProducts(SAMPLE);
    expect(out).toContain("#+PRODUCT_COUNT: 3");
  });

  it("renders by-category index heading", () => {
    const out = renderProducts(SAMPLE);
    expect(out).toContain("** by-category");
    expect(out).toContain(":index:category:");
  });

  it("renders a product as a ***** headline with :product: tag", () => {
    const out = renderProducts(SAMPLE);
    expect(out).toContain("***** ACME Rocket");
    expect(out).toContain(":product:");
  });

  it("renders product SKU and price in PROPERTIES drawer", () => {
    const out = renderProducts(SAMPLE);
    expect(out).toContain(":SKU:        RKT-001");
    expect(out).toContain(":PRICE:      299.99");
  });

  it("renders by-collection index with org id link", () => {
    const out = renderProducts(SAMPLE);
    expect(out).toContain("** by-collection");
    expect(out).toContain("[[id:acme-rocket][see canonical]]");
  });

  it("renders by-price-band index", () => {
    const out = renderProducts(SAMPLE);
    expect(out).toContain("** by-price-band");
    expect(out).toContain(":index:price-band:");
  });

  it("PROPERTIES and END are balanced", () => {
    const out = renderProducts(SAMPLE);
    const opens = (out.match(/:PROPERTIES:/g) ?? []).length;
    const closes = (out.match(/:END:/g) ?? []).length;
    expect(opens).toBe(closes);
  });

  it("has no leftover {{…}} mustache tokens", () => {
    const out = renderProducts(SAMPLE);
    expect(out).not.toMatch(/\{\{[^}]+\}\}/);
  });
});

// ── renderTimeline() ──────────────────────────────────────────────────────────

describe("renderTimeline()", () => {
  const SAMPLE: Parameters<typeof renderTimeline>[0] = {
    brand_name: "Acme Corp",
    utc_iso: "2026-05-28T00:00:00.000Z",
    events: [
      {
        ts: "2026-05-28T00:01:00Z",
        verb_id: "brand.fetch",
        status: "ok",
        duration_ms: 1234,
        vendor_cost_usd: 0.005,
        customer_charge_usd: 0.0075,
        margin_usd: 0.0025,
        summary: "Fetched logo, fonts, colors from acme.com.",
      },
      {
        ts: "2026-05-28T00:02:00Z",
        verb_id: "catalog.crawl",
        status: "error",
        duration_ms: 500,
        vendor_cost_usd: 0,
        customer_charge_usd: 0,
        margin_usd: 0,
        summary: "Shopify catalog crawl failed.",
        error: "rate_limited: 429 from api.shopify.com",
      },
    ],
  };

  it("includes #+TITLE with brand name", () => {
    const out = renderTimeline(SAMPLE);
    expect(out).toContain("#+TITLE: Acme Corp brand-book capture timeline");
  });

  it("renders event headlines with verb_id and status tag", () => {
    const out = renderTimeline(SAMPLE);
    expect(out).toContain("** 2026-05-28T00:01:00Z — brand.fetch");
    expect(out).toContain(":event:ok:");
  });

  it("renders event PROPERTIES drawer with cost fields", () => {
    const out = renderTimeline(SAMPLE);
    expect(out).toContain(":VERB:           brand.fetch");
    expect(out).toContain(":DURATION_MS:    1234");
    expect(out).toContain(":VENDOR_COST:    $0.005");
  });

  it("renders error events with the error message", () => {
    const out = renderTimeline(SAMPLE);
    expect(out).toContain(":event:error:");
    expect(out).toContain("ERROR: rate_limited: 429 from api.shopify.com");
  });

  it("PROPERTIES and END are balanced", () => {
    const out = renderTimeline(SAMPLE);
    const opens = (out.match(/:PROPERTIES:/g) ?? []).length;
    const closes = (out.match(/:END:/g) ?? []).length;
    expect(opens).toBe(closes);
  });

  it("has no leftover {{…}} mustache tokens", () => {
    const out = renderTimeline(SAMPLE);
    expect(out).not.toMatch(/\{\{[^}]+\}\}/);
  });

  it("handles empty event list", () => {
    const out = renderTimeline({ brand_name: "Acme Corp", events: [] });
    expect(out).not.toMatch(/\{\{[^}]+\}\}/);
    expect(out).toContain("* Capture log");
  });
});
