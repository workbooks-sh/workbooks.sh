// /v1/book pipeline.
//
// Composite verb that turns a domain into an installable brand-book tar.gz.
// Orchestrates: resolve → brand fetch → ads search → catalog crawl →
// design palette → (optional) competitor fetch+ads → org rendering →
// workbook bundling → tar.gz assembly.
//
// Cost is accumulated across all sub-verbs into a single CostTracker.
// Video (--with-video) and media download (--link-only) are supported at
// the option level; video compression stub is TODO for wb-0wst.5.

import { CostTracker } from "../cost.js";
import type { Bindings } from "../env.js";
import { retrieveBrand } from "../scrape/context.js";
import { metaAdLibrarySearch } from "../scrape/scrapecreators.js";
import type { AdRecord, BrandInput, CompetitorInput, ProductsInput } from "./types.js";
import {
  renderBrand,
  renderCompetitor,
  renderProducts,
  renderTimeline,
} from "./render.js";
import type { TimelineEvent } from "./types.js";
import { bundleWorkbook } from "./book-bundle.js";
import type { WorkbookFile } from "./book-bundle.js";
import { composeBookData } from "./presentation-shell.js";
import { SEED_BRANDS, type SeedBrand } from "../agent/seed-brands.js";
import { curate } from "../agent/curate.js";
import { fetchLogo } from "../agent/logo-fetch.js";
import { homepageScreenshot } from "../agent/screenshot-fetch.js";
import { verifyStyleViaVision } from "../agent/vision-verify.js";
import { harvestBrand, type BrandSubstrate } from "./harvest.js";
import type { BookMetadata } from "./skill-md.js";
import { generateSkillMarkdown } from "./skill-md.js";
import { tarGz } from "./tar.js";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface BuildBookOptions {
  domain: string;
  competitors?: string[];
  with_video?: boolean;
  link_only?: boolean;
  force?: boolean;
  account_id: string;
  /** If set + known, replace vendor fetches with hand-verified seed data.
   *  Used for the 5 demo brands until full vendor wiring lands. */
  seed_slug?: string;
  /** Whether to also run the html through the standalone .html field. */
  visibility?: "public" | "private";
}

export interface BookManifest {
  domain: string;
  slug: string;
  generated_at: string;
  capture_cost_usd: number;
  product_count: number;
  category_count: number;
  collection_count: number;
  ad_count: number;
  ad_providers: string[];
  competitor_slugs: string[];
  has_video: boolean;
  file_count: number;
}

export interface BuildBookResult {
  tarGzBytes: Uint8Array;
  /** Standalone .html bytes (same file inside the tar). Suitable for direct R2 serving. */
  htmlBytes: Uint8Array;
  slug: string;
  cost: number;
  manifest: BookManifest;
  /** Whether curation came from Cerebras or fallback. */
  curate_source: "cerebras" | "fallback";
  /** Whether brand facts came from vendor calls, seed data, or a mix. */
  data_source: "vendor" | "seed" | "mixed";
}

// ── Slug helpers ──────────────────────────────────────────────────────────────

function domainToSlug(domain: string): string {
  return domain
    .toLowerCase()
    .replace(/^www\./, "")
    .split(".")[0]
    ?.replace(/[^a-z0-9-]/g, "-") ?? domain.replace(/\./g, "-");
}

function toTitleCase(slug: string): string {
  return slug.charAt(0).toUpperCase() + slug.slice(1);
}

// ── Brand fetch (thin in-process call) ───────────────────────────────────────

interface BrandFetchResult {
  brandInput: BrandInput;
  timelineEvent: TimelineEvent;
}
// ── Ads search ────────────────────────────────────────────────────────────────

interface AdsResult {
  adRecords: AdRecord[];
  adProviders: string[];
  timelineEvent: TimelineEvent;
}

// ── Catalog crawl (lightweight in-process, not streaming) ─────────────────────

interface CatalogResult {
  productsInput: ProductsInput;
  productCount: number;
  categoryCount: number;
  collectionCount: number;
  timelineEvent: TimelineEvent;
}

// ── Competitor fetch ──────────────────────────────────────────────────────────

interface CompetitorResult {
  input: CompetitorInput;
  slug: string;
}

async function fetchCompetitorData(
  env: Bindings,
  competitorDomain: string,
  primaryBrandName: string,
  tenant: string,
  ctx: ExecutionContext,
  cost: CostTracker,
): Promise<CompetitorResult> {
  const ts = new Date().toISOString();
  const slug = domainToSlug(competitorDomain);

  try {
    const [brandRes, adsRes] = await Promise.allSettled([
      retrieveBrand(env, competitorDomain, tenant, ctx),
      env.SCRAPECREATORS_API_KEY
        ? metaAdLibrarySearch(env, {
            query: toTitleCase(slug),
            country: "US",
            tenant,
            ctx,
          })
        : Promise.reject(new Error("scrapecreators not configured")),
    ]);
    cost.addOther("context-dev", 0.001, 1);
    if (adsRes.status === "fulfilled") cost.addOther("scrapecreators", 0.001, 1);

    const brand = brandRes.status === "fulfilled" ? brandRes.value.brand : undefined;
    const ads =
      adsRes.status === "fulfilled"
        ? adsRes.value.ads.map<AdRecord>((ad) => ({
            ad_headline: ad.snapshot?.page_name ?? "",
            ad_id: ad.ad_archive_id,
            provider: "meta",
            platform: "meta",
            landing_url: ad.snapshot?.page_profile_uri ?? "",
          }))
        : [];

    return {
      slug,
      input: {
        competitor_name: brand?.title ?? toTitleCase(slug),
        brand_name: primaryBrandName,
        slug,
        domain: competitorDomain,
        utc_iso: ts,
        category: brand?.industry?.name ?? "",
        snapshot_notes: brand?.description ?? "",
        ads,
      },
    };
  } catch {
    return {
      slug,
      input: {
        competitor_name: toTitleCase(slug),
        brand_name: primaryBrandName,
        slug,
        domain: competitorDomain,
        utc_iso: ts,
      },
    };
  }
}

// ── Media download stub ───────────────────────────────────────────────────────

/**
 * Stub for media collection. Currently records media URLs in the .org files
 * as external links. Full download + R2 storage is out of scope for v1.
 * Video compression (wb-0wst.5) is a TODO.
 */
async function collectMedia(
  _mediaUrls: string[],
  _linkOnly: boolean,
  _withVideo: boolean,
): Promise<void> {
  // TODO wb-0wst.5: download static images to R2 unless link_only.
  // TODO wb-0wst.5: if with_video, run video through Theater compression stub.
}

// ── Main pipeline ─────────────────────────────────────────────────────────────

export async function buildBook(
  env: Bindings,
  ctx: ExecutionContext,
  opts: BuildBookOptions,
): Promise<BuildBookResult> {
  // Seed path: hand-verified data + Cerebras curation. No vendor calls.
  // Used by the 5 demo brands and by anyone who passes a known seed_slug.
  if (opts.seed_slug && SEED_BRANDS[opts.seed_slug]) {
    return buildSeedBook(env, SEED_BRANDS[opts.seed_slug]!, opts);
  }

  const cost = new CostTracker();
  const generatedAt = new Date().toISOString();
  const timelineEvents: TimelineEvent[] = [];

  // ── STAGE 1: Brand Scout harvest ────────────────────────────────────────
  // Fan out EVERY data point (resolve → identity → company → catalog → social
  // → ads → media/R2), each VERIFIED + escalated + recorded loud into the
  // substrate's provenance. composeBookData then authors from the substrate
  // WITHOUT re-scraping. (Replaces the old inline brand/ads/catalog-stub gather.)
  const tHarvest = Date.now();
  const substrate = await harvestBrand(env, {
    domain: opts.domain,
    tenant: opts.account_id,
    competitors: opts.competitors,
    ctx,
  });
  cost.addOther("harvest", 0.01, 1);

  const slug = domainToSlug(opts.domain);
  const brandName = substrate.company.name ?? toTitleCase(slug);

  // Surface the harvest provenance into the book timeline so the editor (and
  // the .org files) see exactly which point won which tool, and which FAILED.
  for (const pv of substrate.provenance) {
    timelineEvents.push({
      ts: generatedAt,
      verb_id: `harvest.${pv.point}`,
      status: pv.status === "ok" ? "ok" : "error",
      duration_ms: 0,
      summary: `${pv.tool} · ${pv.attempts.slice(-1)[0] ?? ""}`.slice(0, 200),
      vendor_cost_usd: 0,
      ...(pv.status === "failed" && pv.error ? { error: pv.error } : {}),
    });
  }
  timelineEvents.push({
    ts: new Date(tHarvest).toISOString(),
    verb_id: "harvest.brand",
    status: "ok",
    duration_ms: Date.now() - tHarvest,
    summary: `${substrate.provenance.filter((p) => p.status === "ok").length}/${substrate.provenance.length} points ok · ${substrate.catalog.productCount} products · ${substrate.media.length} media mirrored`,
    vendor_cost_usd: 0,
  });

  // Adapt the substrate into the renderer/curator shapes (BrandInput + the
  // SeedBrand the presentation deck + curate() consume). No re-scraping.
  const brandResult: BrandFetchResult = {
    brandInput: substrateToBrandInput(substrate, slug, generatedAt),
    timelineEvent: {
      ts: generatedAt,
      verb_id: "brand.fetch",
      status: "ok",
      duration_ms: 0,
      vendor_cost_usd: 0,
    },
  };
  const adsResult: AdsResult = substrateToAdsResult(substrate);
  const catalogResult: CatalogResult = substrateToCatalogResult(substrate, brandName, generatedAt);

  // Competitors are still passed-in (auto-discovery deferred — design P2 #14).
  const competitorResults: CompetitorResult[] = [];
  if (opts.competitors && opts.competitors.length > 0) {
    const competitorFetches = opts.competitors.slice(0, 5).map((cDomain) =>
      fetchCompetitorData(env, cDomain, brandName, opts.account_id, ctx, cost),
    );
    const settled = await Promise.allSettled(competitorFetches);
    for (const s of settled) {
      if (s.status === "fulfilled") competitorResults.push(s.value);
    }
  }

  // Logo + screenshot come from the substrate (already mirrored to R2). Build
  // a screenshot descriptor compatible with the existing extras shape.
  const logoOutcome = {
    result: substrate.identity.logo
      ? { url: substrate.identity.logo.url, source: substrate.identity.logo.source, content_type: "image/*", bytes: null as number | null }
      : null,
    attempts: [] as Array<{ source: string; url: string; ok: boolean; reason?: string }>,
  };
  const screenshot = substrate.identity.screenshot_r2
    ? { url: substrate.identity.screenshot_r2, source: "harvest-r2", viewport: { width: 1280, height: 800 } }
    : homepageScreenshot(opts.domain, { width: 1280, height: 800 });

  const tLogo = tHarvest; // for the existing log entries below
  const curatedBook = await curate(
    env.CEREBRAS_API_KEY ?? "",
    vendorToSeedShape(brandResult.brandInput, brandName, opts.domain, adsResult.adRecords, competitorResults, undefined, substrate),
  );

  // Step 6.5: vision verification. A vision model looks at the harvested
  // homepage screenshot (already mirrored to R2) and either CONFIRMS or REVISES
  // Cerebras's style_signal, adding visual_notes (mood, composition, imagery
  // type) text-only Cerebras can't see.
  const tVision = Date.now();
  const visionEvidenceSummary =
    `${substrate.identity.palette.length} palette swatches · ${substrate.identity.fonts.length} fonts · ${substrate.identity.voice.length} voice notes`;
  const verdict = substrate.identity.screenshot_r2
    ? await verifyStyleViaVision({
        openrouterApiKey: env.OPENROUTER_API_KEY,
        screenshotUrl: substrate.identity.screenshot_r2,
        brand_name: brandName,
        domain: opts.domain,
        claimed_style_signal: curatedBook.style_signal,
        text_evidence_summary: visionEvidenceSummary,
      })
    : null;
  if (verdict) {
    const imageryNote = verdict.imagery_type !== "blank" && verdict.imagery_type !== "unknown"
      ? ` · imagery=${verdict.imagery_type}`
      : "";
    timelineEvents.push({
      ts: new Date(tVision).toISOString(),
      verb_id: "agent.vision_verify",
      status: verdict.agreed ? "confirmed" : "revised",
      duration_ms: verdict.latency_ms,
      summary: verdict.agreed
        ? `${verdict.model} agreed${imageryNote} · ${verdict.observed_colors.length} colors seen`
        : `${verdict.model} revised: "${verdict.style_signal_revised.slice(0, 60)}…" (${verdict.refutations.length} refutations)${imageryNote}`,
      vendor_cost_usd: 0,
    });
    if (!verdict.agreed) {
      curatedBook.style_signal = verdict.style_signal_revised;
      curatedBook.voice_notes = [...verdict.visual_notes, ...curatedBook.voice_notes].slice(0, 6);
    }
  } else {
    timelineEvents.push({
      ts: new Date(tVision).toISOString(),
      verb_id: "agent.vision_verify",
      status: env.OPENROUTER_API_KEY ? "error" : "skipped",
      duration_ms: 0,
      summary: env.OPENROUTER_API_KEY
        ? "vision call failed (network, model, or screenshot still rendering)"
        : "OPENROUTER_API_KEY not set — skipped vision pass",
      vendor_cost_usd: 0,
    });
  }
  timelineEvents.push({
    ts: new Date(tLogo).toISOString(),
    verb_id: "agent.logo",
    status: logoOutcome.result ? "ok" : "missing",
    duration_ms: Date.now() - tLogo,
    summary: logoOutcome.result
      ? `${logoOutcome.result.source} · ${logoOutcome.result.content_type}`
      : `${logoOutcome.attempts.length} sources tried, all failed`,
    vendor_cost_usd: 0,
  });
  timelineEvents.push({
    ts: new Date(tLogo).toISOString(),
    verb_id: "agent.screenshot",
    status: "ok",
    duration_ms: 0,
    summary: `${screenshot.source} · ${screenshot.viewport.width}×${screenshot.viewport.height}`,
    vendor_cost_usd: 0,
  });
  timelineEvents.push({
    ts: new Date(tLogo).toISOString(),
    verb_id: "agent.curate",
    status: curatedBook.source === "cerebras" ? "ok" : "fallback",
    duration_ms: curatedBook.meta.latency_ms,
    summary: curatedBook.source === "cerebras"
      ? `glm-4.7 · style: "${curatedBook.style_signal.slice(0, 60)}…"`
      : (curatedBook.warnings[0] ?? "fallback"),
    vendor_cost_usd: 0,
  });

  // Vendor's logo (if context.dev returned one) takes precedence ONLY if the
  // cascade didn't return something. The cascade is generally more reliable.
  const finalLogoUrl = logoOutcome.result?.url ?? brandResult.brandInput.logo_primary_url ?? "";
  if (logoOutcome.result?.url) {
    brandResult.brandInput.logo_primary_url = logoOutcome.result.url;
  }

  // Step 7: compose .org files
  const orgFiles: WorkbookFile[] = [];

  // brand.org
  const brandOrg = renderBrand(brandResult.brandInput);
  orgFiles.push({ path: "brand.org", content: brandOrg });

  // competitors/*.org
  for (const comp of competitorResults) {
    const compOrg = renderCompetitor(comp.input);
    orgFiles.push({ path: `competitors/${comp.slug}.org`, content: compOrg });
  }

  // catalog/products.org
  const productsOrg = renderProducts(catalogResult.productsInput);
  orgFiles.push({ path: "catalog/products.org", content: productsOrg });

  // timeline.org
  const timelineOrg = renderTimeline({
    brand_name: brandName,
    utc_iso: generatedAt,
    events: timelineEvents,
  });
  orgFiles.push({ path: "timeline.org", content: timelineOrg });

  // Step 8: media collection stub
  const allMediaUrls = adsResult.adRecords
    .map((a) => a.media_url)
    .filter((u): u is string => !!u);
  await collectMedia(allMediaUrls, opts.link_only ?? false, opts.with_video ?? false);

  // Step 9: compose BookData and bundle the workbook with the full Presentation.
  const vendorBrand = vendorToSeedShape(
    brandResult.brandInput,
    brandName,
    opts.domain,
    adsResult.adRecords,
    competitorResults,
    finalLogoUrl,
    substrate,
  );
  const bookData = composeBookData(vendorBrand, curatedBook, {
    slug,
    title: `${brandName} brand book`,
    generatedAt,
    dataSource: "vendor",
    timeline: timelineEvents,
    logoSource: logoOutcome.result?.source,
    extras: {
      homepage_screenshot: screenshot,
      style_signal: curatedBook.style_signal,
    },
  });
  const workbookHtml = await bundleWorkbook(
    {
      slug,
      title: `${brandName} brand book`,
      createdAt: generatedAt,
      generator: "brandnana-api",
      description: `Brand intelligence for ${opts.domain}`,
    },
    orgFiles,
    bookData,
  );

  // Build BookMetadata for SKILL.md
  const meta: BookMetadata = {
    slug,
    brand_name: brandName,
    domain: opts.domain,
    generated_at_iso: generatedAt,
    product_count: catalogResult.productCount,
    category_count: catalogResult.categoryCount,
    collection_count: catalogResult.collectionCount,
    competitor_slugs: competitorResults.map((c) => c.slug),
    ad_count: adsResult.adRecords.length,
    ad_providers: adsResult.adProviders,
    has_video: opts.with_video ?? false,
    brandnana_version: "1.0.0",
    capture_cost_usd: cost.totalAtCost(),
  };

  // Step 10: build tar.gz
  const encoder = new TextEncoder();
  const skillMd = generateSkillMarkdown(meta);
  const tarGzBytes = await tarGz([
    { path: "SKILL.md", bytes: encoder.encode(skillMd) },
    { path: `${slug}.html`, bytes: encoder.encode(workbookHtml) },
  ]);

  const manifest: BookManifest = {
    domain: opts.domain,
    slug,
    generated_at: generatedAt,
    capture_cost_usd: cost.totalAtCost(),
    product_count: catalogResult.productCount,
    category_count: catalogResult.categoryCount,
    collection_count: catalogResult.collectionCount,
    ad_count: adsResult.adRecords.length,
    ad_providers: adsResult.adProviders,
    competitor_slugs: competitorResults.map((c) => c.slug),
    has_video: opts.with_video ?? false,
    file_count: orgFiles.length,
  };

  return {
    tarGzBytes,
    htmlBytes: encoder.encode(workbookHtml),
    slug,
    cost: cost.totalAtCost(),
    manifest,
    curate_source: curatedBook.source,
    data_source: "vendor",
  };
}
// ── Vendor → SeedBrand adapter ────────────────────────────────────────────────
//
// composeBookData expects a SeedBrand shape (hand-curated facts for the
// presentation deck). The vendor pipeline produces BrandInput / AdRecord /
// CompetitorInput. This adapter shoehorns vendor data into SeedBrand so the
// same Presentation builders + curate() work for ad-hoc domains.

function vendorToSeedShape(
  b: BrandInput,
  brandName: string,
  domain: string,
  adRecords: AdRecord[],
  competitors: CompetitorResult[],
  logoOverride?: string,
  /** Stage-1 substrate — when present, the SOURCE OF TRUTH for products,
   *  palette, fonts, socials, and ad copy (the book's "full context"). */
  substrate?: BrandSubstrate,
): SeedBrand {
  const slug = domain.toLowerCase().replace(/^www\./, "").split(".")[0] ?? domain;

  // Palette: prefer the substrate's always-unioned + vision palette, then the
  // BrandInput's, then a neutral fallback so the deck always renders.
  const paletteRaw = substrate && substrate.identity.palette.length > 0
    ? substrate.identity.palette.map((c) => ({ hex: c.hex, name: c.name || c.hex }))
    : (b.extended_colors ?? []).filter((c) => c.hex).map((c) => ({ hex: c.hex, name: c.name || c.hex }));
  const palette = paletteRaw.length > 0
    ? paletteRaw
    : [
        { hex: "#111111", name: "Default Black" },
        { hex: "#ffffff", name: "Default Paper" },
        { hex: "#888888", name: "Default Gray" },
      ];

  const fonts = substrate && substrate.identity.fonts.length > 0
    ? substrate.identity.fonts.map((f) => f.family)
    : [b.primary_font, b.secondary_font];

  // Products: the deck wants { name, price, currency, category }. Map the
  // substrate's loosely-typed catalog rows defensively.
  const products = (substrate?.catalog.products ?? []).slice(0, 60).map((p) => {
    const name = typeof p.title === "string" ? p.title : (typeof p.name === "string" ? p.name : "");
    const priceRaw = (p.price ?? p.min_price ?? p.amount) as unknown;
    const price = typeof priceRaw === "number" ? priceRaw : typeof priceRaw === "string" ? parseFloat(priceRaw) || 0 : 0;
    const currency = typeof p.currency === "string" ? p.currency : "USD";
    const category = typeof p.product_type === "string" ? p.product_type : (typeof p.category === "string" ? p.category : "");
    return { name, price, currency, category };
  }).filter((p) => p.name);

  // Ads: prefer the substrate's normalized ad copy across all three legs.
  const subAds = substrate
    ? [...substrate.ads.meta, ...substrate.ads.google, ...substrate.ads.linkedin]
        .filter((a) => a.body)
        .slice(0, 8)
        .map((a) => ({ headline: a.body ?? "", platform: a.source, cta: a.cta ?? "Learn more" }))
    : [];
  const ads = subAds.length > 0
    ? subAds
    : adRecords.slice(0, 6).map((a) => ({ headline: a.ad_headline ?? "", platform: a.provider ?? "?", cta: "Learn more" }));

  const social = substrate && Object.keys(substrate.company.socials).length > 0
    ? Object.entries(substrate.company.socials).map(([network, url]) => ({ network, url }))
    : (b.social ?? []).map((s) => ({ network: s.network, url: s.url }));

  return {
    slug,
    domain,
    brand_name: brandName,
    category: substrate?.company.industry ?? b.category ?? "",
    tagline: substrate?.identity.slogan ?? substrate?.company.tagline ?? b.tagline ?? "",
    description: (substrate?.company.description ?? b.descriptors?.[0] ?? "").slice(0, 600) || `${brandName} (${domain})`,
    logo_svg_url: logoOverride ?? substrate?.identity.logo?.url ?? b.logo_primary_url ?? "",
    primary_hex: palette[0]?.hex ?? "#111111",
    primary_name: palette[0]?.name ?? "primary",
    secondary_hex: palette[1]?.hex ?? "#ffffff",
    secondary_name: palette[1]?.name ?? "secondary",
    palette,
    primary_font: fonts[0] || "system-ui",
    secondary_font: fonts[1] || "system-ui",
    products,
    ads,
    competitors: competitors.map((c) => ({ name: c.input.competitor_name, domain: c.input.domain })),
    social,
  };
}

// ── Substrate → renderer-shape adapters ──────────────────────────────────────
//
// The Stage-1 substrate is the single source of truth. These thin adapters
// reshape it into the legacy BrandInput / AdsResult / CatalogResult the .org
// renderers + SKILL.md metadata already consume — no re-scraping.

function substrateToBrandInput(s: BrandSubstrate, slug: string, ts: string): BrandInput {
  const fonts = s.identity.fonts;
  const colors = s.identity.palette.map((c) => ({ name: c.name, hex: c.hex }));
  return {
    brand_name: s.company.name ?? toTitleCase(slug),
    slug,
    domain: s.domain,
    utc_iso: ts,
    version: "1",
    legal_name: s.company.name ?? toTitleCase(slug),
    founded_year: s.company.founded ?? undefined,
    hq_city: s.company.city ?? undefined,
    tagline: s.identity.slogan ?? s.company.tagline ?? "",
    category: s.company.industry ?? "",
    descriptors: s.company.description ? [s.company.description] : [],
    voice_notes: s.identity.voice.join(" · "),
    primary_hex: colors[0]?.hex ?? "",
    primary_name: colors[0]?.name ?? "",
    secondary_hex: colors[1]?.hex ?? "",
    secondary_name: colors[1]?.name ?? "",
    extended_colors: colors,
    primary_font: fonts[0]?.family ?? "",
    secondary_font: fonts[1]?.family ?? "",
    mono_font: "",
    logo_primary_url: s.identity.logo?.url ?? "",
    social: Object.entries(s.company.socials).map(([network, url]) => ({
      network,
      handle: `@${slug}`,
      url,
    })),
    capture_verbs: [{ verb: "harvest.brand", ts, summary: `Stage-1 harvest of ${s.domain}` }],
  };
}

function substrateToAdsResult(s: BrandSubstrate): AdsResult {
  const all = [...s.ads.meta, ...s.ads.google, ...s.ads.linkedin];
  const providers = Array.from(new Set(all.map((a) => a.source)));
  return {
    adRecords: all.map((a) => ({
      ad_headline: a.body ?? "",
      ad_id: a.external_id,
      provider: a.source,
      platform: a.source,
      landing_url: a.url ?? "",
      media_url: a.creative_r2,
    })),
    adProviders: providers,
    timelineEvent: {
      ts: new Date().toISOString(),
      verb_id: "ads.search",
      status: all.length > 0 ? "ok" : "empty",
      duration_ms: 0,
      summary: `${all.length} ads via ${providers.join(", ") || "none"}`,
      vendor_cost_usd: 0,
    },
  };
}

function substrateToCatalogResult(s: BrandSubstrate, brandName: string, ts: string): CatalogResult {
  const cat = s.catalog;
  const categories = new Map<string, number>();
  for (const p of cat.products) {
    const c = typeof p.product_type === "string" ? p.product_type : (typeof p.category === "string" ? p.category : "");
    if (c) categories.set(c, (categories.get(c) ?? 0) + 1);
  }
  const productsInput: ProductsInput = {
    brand_name: brandName,
    utc_iso: ts,
    product_count: cat.productCount,
    category_count: categories.size,
    categories: Array.from(categories.keys()).map((name) => ({ name })),
    collections: [],
    colors: [],
    price_bands: [],
    stock_groups: [],
  };
  return {
    productsInput,
    productCount: cat.productCount,
    categoryCount: categories.size,
    collectionCount: 0,
    timelineEvent: {
      ts,
      verb_id: "catalog.crawl",
      status: cat.productCount > 0 ? "ok" : "empty",
      duration_ms: 0,
      summary: `${cat.productCount} products via ${cat.strategy}`,
      vendor_cost_usd: 0,
    },
  };
}

// ── Seed-data + LLM-curated path (no vendor calls) ───────────────────────────
//
// Hand-verified brand facts + Cerebras curation. Used by the 5 demo brands
// and any caller passing seed_slug. Bypasses every vendor adapter so it works
// without context.dev / scrapecreators / valyu / firecrawl keys.

async function buildSeedBook(
  env: Bindings,
  brand: SeedBrand,
  opts: BuildBookOptions,
): Promise<BuildBookResult> {
  const generatedAt = new Date().toISOString();
  const slug = brand.slug;
  const encoder = new TextEncoder();
  const timelineEvents: TimelineEvent[] = [];

  // Run logo cascade, screenshot capture, and Cerebras curation IN PARALLEL.
  const tLogo = Date.now();
  const tShot = Date.now();
  const tCurate = Date.now();

  const [logoOutcome, curated] = await Promise.all([
    fetchLogo(brand.domain, { logoDevToken: env.CONTEXT_DEV_API_KEY }),
    curate(env.CEREBRAS_API_KEY ?? "", brand),
  ]);

  // homepage screenshot — synthesizes a URL, no fetch needed (browser loads on render)
  const screenshot = homepageScreenshot(brand.domain, { width: 1280, height: 800 });

  // Per-verb provenance (wb-tmmw issue 1 fix — outcomes, not invocations).
  timelineEvents.push({
    ts: new Date(tLogo).toISOString(),
    verb_id: "agent.logo",
    status: logoOutcome.result ? "ok" : "missing",
    duration_ms: Date.now() - tLogo,
    summary: logoOutcome.result
      ? `${logoOutcome.result.source} · ${logoOutcome.result.content_type}${logoOutcome.result.bytes ? ` · ${logoOutcome.result.bytes}B` : ""}`
      : `tried ${logoOutcome.attempts.length} sources, all failed: ${logoOutcome.attempts.map((a) => `${a.source}=${a.reason}`).join(", ")}`,
    vendor_cost_usd: 0,
  });
  timelineEvents.push({
    ts: new Date(tShot).toISOString(),
    verb_id: "agent.screenshot",
    status: "ok",
    duration_ms: Date.now() - tShot,
    summary: `${screenshot.source} · ${screenshot.viewport.width}×${screenshot.viewport.height}`,
    vendor_cost_usd: 0,
  });
  timelineEvents.push({
    ts: new Date(tCurate).toISOString(),
    verb_id: "agent.curate",
    status: curated.source === "cerebras" ? "ok" : "fallback",
    duration_ms: Date.now() - tCurate,
    summary: curated.source === "cerebras"
      ? `glm-4.7 · ${curated.meta.completion_tokens}t out · style: "${curated.style_signal.slice(0, 50)}…"`
      : (curated.warnings[0] ?? "fallback narrative"),
    vendor_cost_usd: 0,
  });

  // Override seed logo URL with whatever the cascade returned (cascade may
  // pick something better, e.g. apple-touch-icon over the default Clearbit
  // hit for SaaS brands).
  const resolvedBrand: SeedBrand = {
    ...brand,
    logo_svg_url: logoOutcome.result?.url ?? brand.logo_svg_url,
  };

  // Step 2: compose the .org files (mirrors the vendor path's renderer shape).
  const brandInput: BrandInput = {
    brand_name: brand.brand_name,
    slug,
    domain: brand.domain,
    utc_iso: generatedAt,
    version: "1",
    legal_name: brand.brand_name,
    tagline: brand.tagline,
    category: brand.category,
    descriptors: [brand.description],
    voice_notes: curated.voice_notes.join(" · "),
    primary_hex: brand.primary_hex,
    primary_name: brand.primary_name,
    secondary_hex: brand.secondary_hex,
    secondary_name: brand.secondary_name,
    extended_colors: brand.palette,
    primary_font: brand.primary_font,
    secondary_font: brand.secondary_font,
    mono_font: "",
    logo_primary_url: resolvedBrand.logo_svg_url,
    social: brand.social.map((s) => ({
      network: s.network,
      handle: `@${slug}`,
      url: s.url,
    })),
    capture_verbs: [
      { verb: "seed.brand", ts: generatedAt, summary: `seed data for ${brand.domain}` },
      { verb: "agent.curate", ts: generatedAt, summary: `curated by ${curated.meta.model}` },
    ],
  };

  const orgFiles: WorkbookFile[] = [
    { path: "brand.org", content: renderBrand(brandInput) },
    {
      path: "catalog/products.org",
      content: renderProducts({
        brand_name: brand.brand_name,
        utc_iso: generatedAt,
        product_count: brand.products.length,
        category_count: new Set(brand.products.map((p) => p.category)).size,
        collections: [],
        categories: [],
        colors: [],
        price_bands: [],
        stock_groups: [],
      }),
    },
  ];
  for (const comp of brand.competitors) {
    orgFiles.push({
      path: `competitors/${comp.domain.replace(/[^a-z0-9-]/gi, "-")}.org`,
      content: renderCompetitor({
        competitor_name: comp.name,
        brand_name: brand.brand_name,
        slug: comp.domain.split(".")[0] ?? comp.domain,
        domain: comp.domain,
        utc_iso: generatedAt,
      }),
    });
  }
  orgFiles.push({
    path: "timeline.org",
    content: renderTimeline({
      brand_name: brand.brand_name,
      utc_iso: generatedAt,
      events: timelineEvents,
    }),
  });

  // Step 3: compose the BookData (drives the Presentation).
  const bookData = composeBookData(resolvedBrand, curated, {
    slug,
    title: `${brand.brand_name} brand book`,
    generatedAt,
    dataSource: "seed",
    timeline: timelineEvents,
    logoSource: logoOutcome.result?.source,
    extras: {
      homepage_screenshot: screenshot,
      style_signal: curated.style_signal,
    },
  });

  // Step 4: bundle into a self-contained Presentation .html.
  const workbookHtml = await bundleWorkbook(
    {
      slug,
      title: `${brand.brand_name} brand book`,
      createdAt: generatedAt,
      generator: "brandnana-api",
      description: `Brand intelligence for ${brand.domain}`,
    },
    orgFiles,
    bookData,
  );

  // Step 5: SKILL.md + tar.gz.
  const meta: BookMetadata = {
    slug,
    brand_name: brand.brand_name,
    domain: brand.domain,
    generated_at_iso: generatedAt,
    product_count: brand.products.length,
    category_count: new Set(brand.products.map((p) => p.category)).size,
    collection_count: 0,
    competitor_slugs: brand.competitors.map((c) => c.domain.split(".")[0] ?? c.domain),
    ad_count: brand.ads.length,
    ad_providers: ["seed"],
    has_video: false,
    brandnana_version: "1.0.0",
    capture_cost_usd: 0,
  };
  const skillMd = generateSkillMarkdown(meta);
  const htmlBytes = encoder.encode(workbookHtml);
  const tarGzBytes = await tarGz([
    { path: "SKILL.md", bytes: encoder.encode(skillMd) },
    { path: `${slug}.html`, bytes: htmlBytes },
  ]);

  const manifest: BookManifest = {
    domain: brand.domain,
    slug,
    generated_at: generatedAt,
    capture_cost_usd: 0,
    product_count: brand.products.length,
    category_count: new Set(brand.products.map((p) => p.category)).size,
    collection_count: 0,
    ad_count: brand.ads.length,
    ad_providers: ["seed"],
    competitor_slugs: brand.competitors.map((c) => c.domain.split(".")[0] ?? c.domain),
    has_video: false,
    file_count: orgFiles.length,
  };

  return {
    tarGzBytes,
    htmlBytes,
    slug,
    cost: 0,
    manifest,
    curate_source: curated.source,
    data_source: "seed",
  };
}
